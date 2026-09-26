#!/usr/bin/env python3
"""检测报告签发链路 · 可复现检查脚本。

做两件事：

1. 端到端跑通三段链路：调后端接口新建一份「待编制」报告，依次执行
   编制报告 → 审核通过 → 签发报告，断言每一步状态、经办人字段都符合预期，
   且跳步/缺结论等非法动作会被拒绝；
2. 签发完成后，分别从「明细 GET /api/report/{id}」「列表 GET /api/report」
   「导出 GET /api/report/export」三个接口取回这份报告，逐字段比对报告结论、
   状态、编制人、签发人是否一致；若后端不是经前端代理访问，还会额外通过
   前端 /api 代理再取一次，确认前后端联调链路一致。

只依赖 Python 标准库。服务需已由 scripts/dev-up.sh（或手工）拉起。

用法：
    scripts/check_report_chain.py
    scripts/check_report_chain.py --backend http://127.0.0.1:8000 \
                                  --frontend http://127.0.0.1:5173

退出码 0 表示全部一致，非 0 表示链路有问题，失败原因打印到 stderr。
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

EDITOR = "李编制"
REVIEWER = "王审核"
ISSUER = "周签发"
# 固定结论，保证每次检查可复现：三个接口回出的必须与这份一字不差。
CONCLUSION = "所检项目结果符合 GB/T 5750.4-2006 限值要求，报告结论：合格。"
TASK_NO = "TASK-CHECK-LINK"

STATUSES = ["待编制", "待审核", "待签发", "已签发"]


class CheckFailure(RuntimeError):
    """检查断言失败：消息直接展示给联调同学。"""


def request(method: str, url: str, payload: dict[str, Any] | None = None) -> tuple[int, Any]:
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, {"detail": raw}


def wait_health(base_url: str, label: str, timeout: float = 30.0) -> None:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        try:
            status, body = request("GET", f"{base_url}/api/health")
            if status == 200 and isinstance(body, dict) and body.get("ok") is True:
                return
            last = f"HTTP {status}: {body}"
        except Exception as exc:  # noqa: BLE001 - 启动期任何异常都继续等
            last = str(exc)
        time.sleep(0.5)
    raise CheckFailure(f"{label}健康检查未通过（{base_url}/api/health）：{last}")


def action(base_url: str, report_id: int, name: str, extra: dict[str, str] | None = None) -> dict[str, Any]:
    values: dict[str, str] = {"action": name}
    if extra:
        values.update(extra)
    status, body = request("POST", f"{base_url}/api/report/{report_id}/actions", {"values": values})
    if status != 200:
        raise CheckFailure(f"动作「{name}」请求失败：HTTP {status} {body}")
    if not body.get("ok"):
        raise CheckFailure(f"动作「{name}」被后端拒绝：{body.get('message')}")
    entry = body.get("entry") or {}
    print(f"  ✓ {name} -> {entry.get('status')}（{body.get('message')}）")
    return entry


def assert_rejected(base_url: str, report_id: int, values: dict[str, str], reason: str) -> None:
    """非法动作必须被拒绝（ok=false 且状态不变），否则链路约束形同虚设。"""
    status, body = request("POST", f"{base_url}/api/report/{report_id}/actions", {"values": values})
    if status != 200 or not isinstance(body, dict):
        raise CheckFailure(f"{reason}：期望业务拒绝，实际 HTTP {status} {body}")
    if body.get("ok"):
        raise CheckFailure(f"{reason}：期望被拒绝，后端却返回成功 {body}")
    print(f"  ✓ 非法动作已被拦截：{body.get('message')}")


def find_in_list(base_url: str, report_id: int) -> dict[str, Any]:
    status, body = request("GET", f"{base_url}/api/report?size=200")
    if status != 200:
        raise CheckFailure(f"列表接口异常：HTTP {status}")
    for row in body.get("items", []):
        if int(row.get("id", -1)) == report_id:
            return row
    raise CheckFailure(f"列表接口找不到报告 id={report_id}")


def find_in_export(base_url: str, report_id: int) -> dict[str, Any]:
    status, body = request("GET", f"{base_url}/api/report/export")
    if status != 200:
        raise CheckFailure(f"导出接口异常：HTTP {status} {body}")
    for row in body.get("items", []):
        if int(row.get("id", -1)) == report_id:
            return row
    raise CheckFailure(f"导出接口找不到报告 id={report_id}")


def compare(actual: dict[str, Any], expected: dict[str, Any], source: str) -> None:
    diffs = [f"{key}: 期望「{expected[key]}」实际「{actual.get(key)}」"
             for key in expected if str(actual.get(key, "")) != str(expected[key])]
    if diffs:
        raise CheckFailure(f"{source}返回与预期不一致：" + "；".join(diffs))


def main() -> int:
    parser = argparse.ArgumentParser(description="检测报告签发链路可复现检查")
    parser.add_argument("--backend", default="http://127.0.0.1:8000", help="后端地址（直连）")
    parser.add_argument(
        "--frontend",
        default="http://127.0.0.1:5173",
        help="前端地址，用于验证 /api 代理；传空字符串可跳过",
    )
    args = parser.parse_args()
    backend = args.backend.rstrip("/")
    frontend = args.frontend.rstrip("/") if args.frontend else ""

    print(f"[1/4] 健康检查：后端 {backend}")
    wait_health(backend, "后端")
    print("  ✓ 后端 /api/health 正常")
    frontend_alive = False
    if frontend:
        try:
            wait_health(frontend, "前端代理", timeout=10)
            frontend_alive = True
            print(f"  ✓ 前端代理 {frontend}/api/health 正常")
        except CheckFailure as exc:
            print(f"  ! 跳过前端代理校验：{exc}")

    print("[2/4] 检查示例数据是否覆盖完整签发状态")
    for status_name in STATUSES:
        url = f"{backend}/api/report?status={urllib.parse.quote(status_name)}&size=200"
        code, body = request("GET", url)
        if code != 200 or not body.get("items"):
            raise CheckFailure(f"示例数据缺少「{status_name}」状态的报告，无法联调完整链路")
    seeded = find_in_list(backend, 4)
    if seeded.get("status") != "已签发" or not seeded.get("签发人"):
        raise CheckFailure("已签发示例报告缺少签发人字段，示例数据不完整")
    print(f"  ✓ 四种状态示例齐全；已签发样例：{seeded.get('报告编号')} / 签发人 {seeded.get('签发人')}")

    print("[3/4] 新建报告并逐段推进：待编制 → 待审核 → 待签发 → 已签发")
    code, body = request("POST", f"{backend}/api/report", {
        "values": {
            "报告编号": f"REPO-CHECK-{int(time.time())}",
            "关联任务": TASK_NO,
            "编制人": EDITOR,
            "报告类型": "联调自检报告",
        }
    })
    if code != 200 or not body.get("ok"):
        raise CheckFailure(f"创建自检报告失败：HTTP {code} {body}")
    rid = int(body["entry"]["id"])
    print(f"  ✓ 已创建自检报告 id={rid}，初始状态 待编制")

    # 链路约束：不能跳步（待编制直接签发必须被拦），签发不能缺结论。
    assert_rejected(backend, rid, {"action": "签发报告"}, "跳步签发")
    action(backend, rid, "编制报告", {"编制人": EDITOR})
    assert_rejected(backend, rid, {"action": "签发报告"}, "跳过审核")
    action(backend, rid, "审核通过", {"审核人": REVIEWER})
    assert_rejected(
        backend, rid,
        {"action": "签发报告", "签发人": ISSUER},
        "缺结论签发",
    )
    entry = action(backend, rid, "签发报告", {"签发人": ISSUER, "报告结论": CONCLUSION})
    if entry.get("status") != "已签发" or entry.get("pending") is not False:
        raise CheckFailure(f"签发后状态异常：{entry}")
    if entry.get("编制人") != EDITOR or entry.get("审核人") != REVIEWER or entry.get("签发人") != ISSUER:
        raise CheckFailure(f"签发后经办人字段不完整：{entry}")
    print("  ✓ 全链路推进完成，编制人/审核人/签发人均已落字段")

    print("[4/4] 比对明细 / 列表 / 导出（及前端代理）返回的报告结论")
    expected = {
        "status": "已签发",
        "报告编号": body["entry"]["报告编号"],
        "编制人": EDITOR,
        "审核人": REVIEWER,
        "签发人": ISSUER,
        "报告结论": CONCLUSION,
    }
    code, detail = request("GET", f"{backend}/api/report/{rid}")
    if code != 200:
        raise CheckFailure(f"明细接口异常：HTTP {code}")
    compare(detail, expected, "明细接口")
    print("  ✓ GET /api/report/{id} 明细一致")
    compare(find_in_list(backend, rid), expected, "列表接口")
    print("  ✓ GET /api/report 列表一致")
    compare(find_in_export(backend, rid), expected, "导出接口")
    print("  ✓ GET /api/report/export 导出一致")
    if frontend_alive:
        code, proxy_detail = request("GET", f"{frontend}/api/report/{rid}")
        if code != 200:
            raise CheckFailure(f"经前端代理取明细失败：HTTP {code}")
        compare(proxy_detail, expected, "前端代理明细")
        print("  ✓ 经前端 /api 代理取回的明细一致")

    print("\n全部检查通过：报告已按 待编制→待审核→待签发→已签发 签发，"
          "报告结论在明细/列表/导出接口返回一致。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CheckFailure as exc:
        print(f"\n检查失败：{exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # noqa: BLE001 - 检查脚本顶层兜底，给联调同学完整信息
        print(f"\n检查脚本异常：{type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(2)
