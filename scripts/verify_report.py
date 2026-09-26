#!/usr/bin/env python3
"""签发链路可复现检查：核对「报告结论与接口返回一致」。

从 scripts/report-flow.json 取期望值（与 run_report_flow.py 同源），依次核对：
  1. 后端 /api/report/{id} 详情：状态=已签发，编号/编制人/审核人/签发人/结论与清单一致；
  2. 后端 /api/report 列表（keyword 过滤）里同一条记录字段一致；
  3. 默认再经前端 vite 代理（5173）请求一遍，确认构建后的前端链路也能拿到一致数据，
     即「报告结论与接口返回一致」在前后端两侧都成立。

用法：
    python3 scripts/verify_report.py [--backend URL] [--frontend URL] [--manifest PATH]

退出码：全部断言通过 0；任一不符 1 并打印差异。可在服务运行期间反复执行。
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_MANIFEST = Path(__file__).with_name("report-flow.json")
EXPECTED_STATUS = "已签发"
EXPECT_FIELDS = ["报告编号", "编制人", "审核人", "签发人", "报告结论", "报告类型", "报告日期"]


def get_json(url: str) -> dict:
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise AssertionError(f"GET {url} 返回 HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise AssertionError(f"GET {url} 连不上：{exc.reason}") from exc


def assert_record(label: str, record: dict, expected: dict) -> list[str]:
    diffs: list[str] = []
    if record.get("status") != EXPECTED_STATUS:
        diffs.append(f"{label}: status={record.get('status')!r}，期望 {EXPECTED_STATUS!r}")
    if record.get("pending") is not False:
        diffs.append(f"{label}: pending={record.get('pending')!r}，期望 False（已签发不应再待处理）")
    for field in EXPECT_FIELDS:
        actual = record.get(field)
        want = expected[field]
        if actual != want:
            diffs.append(f"{label}: 字段「{field}」={actual!r}，期望 {want!r}")
    return diffs


def main() -> int:
    parser = argparse.ArgumentParser(description="核对已签发报告的结论与接口返回是否一致")
    parser.add_argument("--backend", default="http://127.0.0.1:8000")
    parser.add_argument("--frontend", default="http://127.0.0.1:5173")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--skip-frontend", action="store_true", help="只核后端，不经前端代理核对")
    args = parser.parse_args()

    expected = json.loads(args.manifest.read_text(encoding="utf-8"))
    report_no = expected["报告编号"]
    backend = args.backend.rstrip("/")
    diffs: list[str] = []

    print(f"[verify] 期望报告 {report_no} 处于「{EXPECTED_STATUS}」，结论：{expected['报告结论']}")

    # 1) keyword 列表里找到目标报告，拿到 id（同时覆盖列表接口口径）。
    listing = get_json(f"{backend}/api/report?keyword={urllib.request.quote(report_no)}&size=200")
    matches = [item for item in listing.get("items", []) if item.get("报告编号") == report_no]
    if len(matches) != 1:
        diffs.append(f"列表接口按编号过滤应命中 1 条，实际 {len(matches)} 条")
        print("[verify] " + "\n[verify] ".join(diffs))
        print("[verify] 结果：FAIL")
        return 1
    listed = matches[0]
    report_id = listed["id"]
    diffs += assert_record("列表接口", listed, expected)

    # 2) 详情接口。
    detail = get_json(f"{backend}/api/report/{report_id}")
    diffs += assert_record("详情接口", detail, expected)

    # 3) 导出接口也应包含一致记录。
    exported = get_json(f"{backend}/api/report/export")
    export_match = next((item for item in exported.get("items", []) if item.get("报告编号") == report_no), None)
    if export_match is None:
        diffs.append("导出接口未包含目标报告")
    else:
        diffs += assert_record("导出接口", export_match, expected)

    # 4) 经前端构建产物的 dev/preview 代理再核一遍：确认跨前后端返回一致。
    if not args.skip_frontend:
        frontend = args.frontend.rstrip("/")
        try:
            via_frontend = get_json(
                f"{frontend}/api/report/{report_id}"
            )
            diffs += assert_record("经前端代理的详情接口", via_frontend, expected)
        except AssertionError as exc:
            diffs.append(f"前端代理核对失败：{exc}")

    if diffs:
        print("[verify] 发现以下不一致：")
        for diff in diffs:
            print(f"  - {diff}")
        print("[verify] 结果：FAIL（报告结论或接口返回与期望不一致）")
        return 1

    print(f"[verify] 编号/编制人/审核人/签发人/报告结论 在列表、详情、导出及前端代理四处一致")
    print(f"[verify] 报告结论（接口返回）：{detail.get('报告结论')}")
    print("[verify] 结果：PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
