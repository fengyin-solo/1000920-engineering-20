"""检测报告业务规则：状态流转、字段校验与筛选口径都收在这里。

签发链路固定为：待编制 → 待审核 → 待签发 → 已签发，三个动作分别对应
编制、审核、签发三段，不允许跳段；审核人、签发人在对应动作落库，
报告结论随编制动作写入，签发后只读核对。
"""
from __future__ import annotations

from typing import Any

from app.store import store

MODULE = "report"
REQUIRED_FIELDS = ["报告编号", "关联任务", "编制人"]
OPTIONAL_FIELDS = ["报告日期", "报告类型", "报告结论", "审核人", "签发人"]
STATUS_ORDER = ["待编制", "待审核", "待签发", "已签发"]
# 动作：(前置状态, 目标状态)；前置状态不符一律拦下，禁止跨段流转。
ACTION_FLOW = {
    "编制报告": ("待编制", "待审核"),
    "审核通过": ("待审核", "待签发"),
    "签发报告": ("待签发", "已签发"),
}
# 动作执行时允许一并写入的人员字段。
ACTION_PERSON_FIELD = {"审核通过": "审核人", "签发报告": "签发人"}
# 编制动作允许补齐的报告内容字段。
ACTION_CONTENT_FIELDS = {"编制报告": ["报告结论", "报告日期", "报告类型"]}
NEGATIVE_ACTIONS = []


class ReportService:
    def list_entries(
        self,
        *,
        keyword: str | None = None,
        status: str | None = None,
        page: int = 1,
        size: int = 20,
    ) -> tuple[list[dict[str, Any]], int]:
        rows = store.rows(MODULE)
        if keyword:
            rows = [row for row in rows if keyword in str(row.get("报告编号", ""))]
        if status:
            rows = [row for row in rows if row.get("status") == status]
        total = len(rows)
        start = max(page - 1, 0) * size
        return rows[start:start + size], total

    def get_entry(self, entry_id: int) -> dict[str, Any] | None:
        return store.find(MODULE, entry_id)

    def create_entry(self, values: dict[str, Any]) -> tuple[dict[str, Any] | None, list[str]]:
        missing = [field for field in REQUIRED_FIELDS if not str(values.get(field) or "").strip()]
        if missing:
            return None, missing
        rows = store.rows(MODULE)
        entry: dict[str, Any] = {"id": max((int(row.get("id", 0)) for row in rows), default=0) + 1}
        entry.update({field: values.get(field) for field in REQUIRED_FIELDS})
        for field in OPTIONAL_FIELDS:
            entry[field] = values.get(field, "")
        entry["status"] = STATUS_ORDER[0]
        entry["pending"] = True
        entry["abnormal"] = False
        rows.append(entry)
        return entry, []

    def run_action(
        self,
        entry_id: int,
        action: str,
        values: dict[str, Any] | None = None,
    ) -> tuple[dict[str, Any] | None, str]:
        values = values or {}
        entry = store.find(MODULE, entry_id)
        if entry is None:
            return None, f"检测报告 {entry_id} 不存在或已归档"
        if action not in ACTION_FLOW:
            return None, f"动作「{action}」不属于检测报告可执行范围"
        required_status, target = ACTION_FLOW[action]
        current = str(entry.get("status") or "")
        if current != required_status:
            return None, (
                f"报告当前为「{current}」，只有「{required_status}」状态才能执行{action}，"
                "请按编制 → 审核 → 签发顺序流转"
            )
        person_field = ACTION_PERSON_FIELD.get(action)
        if person_field is not None:
            person = str(values.get(person_field) or "").strip()
            if person:
                entry[person_field] = person
            if not str(entry.get(person_field) or "").strip():
                return None, f"{action}前必须填写{person_field}"
        for field in ACTION_CONTENT_FIELDS.get(action, []):
            value = values.get(field)
            if value is not None and str(value).strip():
                entry[field] = value
        entry["status"] = target
        entry["pending"] = target != STATUS_ORDER[-1]
        entry["abnormal"] = action in NEGATIVE_ACTIONS
        return entry, f"检测报告已{action}"
