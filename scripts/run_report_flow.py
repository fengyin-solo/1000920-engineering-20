#!/usr/bin/env python3
"""签发链路数据驱动脚本：通过真实 HTTP 接口把一份报告从「待编制」推进到「已签发」。

数据口径（报告编号、编制人、审核人、签发人、报告结论等）来自
scripts/report-flow.json，验证脚本读同一份文件，保证两边期望值单一来源、
可复现。脚本幂等：服务重启（内存库重置）后重跑会重新建档；库里已存在同编号
报告时会根据当前状态续跑或直接判定已完成，重复执行不会造脏数据。

用法：
    python3 scripts/run_report_flow.py [--base-url URL] [--manifest PATH] [--out PATH]

退出码：0 成功（含已是签发完成状态）；非 0 链路被后端拒绝，输出具体原因。
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_MANIFEST = Path(__file__).with_name("report-flow.json")
# 状态序列，与 backend/app/services/report.py 保持一致。
STATUS_ORDER = ["待编制", "待审核", "待签发", "已签发"]


class ApiError(RuntimeError):
    pass


def request_json(base_url: str, method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        f"{base_url}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json; charset=utf-8"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise ApiError(f"HTTP {exc.code} {method} {path}：{detail}") from exc
    except urllib.error.URLError as exc:
        raise ApiError(f"连不上后端 {base_url}：{exc.reason}") from exc


def find_report(base_url: str, report_no: str) -> dict | None:
    result = request_json(base_url, "GET", f"/api/report?keyword={urllib.request.quote(report_no)}&size=200")
    for item in result.get("items", []):
        if item.get("报告编号") == report_no:
            return item
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="驱动检测报告 编制→审核→签发 全链路")
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--out", type=Path, default=None, help="把最终签发记录写到该 JSON 文件")
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    report_no = manifest["报告编号"]
    base_url = args.base_url.rstrip("/")

    print(f"[flow] 目标报告：{report_no}（{base_url}）")
    report = find_report(base_url, report_no)

    if report is None:
        create_values = {
            key: manifest[key]
            for key in ("报告编号", "关联任务", "编制人", "报告类型", "报告日期", "报告结论")
        }
        result = request_json(base_url, "POST", "/api/report", {"values": create_values})
        if not result.get("ok"):
            print(f"[flow] 登记报告被拒：{result.get('message')}", file=sys.stderr)
            return 1
        report = result["entry"]
        print(f"[flow] 已登记报告 id={report['id']}，状态={report['status']}")
    else:
        print(f"[flow] 发现已有报告 id={report['id']}，状态={report['status']}，按当前状态续跑")

    current = report.get("status")
    if current not in STATUS_ORDER:
        print(f"[flow] 报告状态「{current}」不在链路状态里，无法继续", file=sys.stderr)
        return 1

    for step in manifest["flow"]:
        action = step["action"]
        target_status = {"编制报告": "待审核", "审核通过": "待签发", "签发报告": "已签发"}[action]
        if STATUS_ORDER.index(current) >= STATUS_ORDER.index(target_status):
            print(f"[flow] 跳过动作「{action}」：当前状态 {current} 已不早于 {target_status}")
            continue
        payload = {"values": {"action": action, **step.get("payload", {})}}
        result = request_json(base_url, "POST", f"/api/report/{report['id']}/actions", payload)
        if not result.get("ok"):
            print(f"[flow] 动作「{action}」被后端拒绝：{result.get('message')}", file=sys.stderr)
            return 1
        report = result["entry"]
        current = report["status"]
        print(f"[flow] {action} → {current}（message: {result.get('message')}）")

    if report.get("status") != "已签发":
        print(f"[flow] 链路结束后状态为「{report.get('status')}」，期望「已签发」", file=sys.stderr)
        return 1

    print(
        "[flow] 签发完成："
        f"编号={report.get('报告编号')} 编制人={report.get('编制人')} "
        f"审核人={report.get('审核人')} 签发人={report.get('签发人')}"
    )
    print(f"[flow] 报告结论：{report.get('报告结论')}")

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"[flow] 最终记录已写入 {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
