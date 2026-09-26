"""检测报告业务规则：状态流转、字段校验与筛选口径都收在这里。

签发链路固定为三段，不允许跳步：

    待编制 --编制报告--> 待审核 --审核通过--> 待签发 --签发报告--> 已签发

编制/审核/签发分别落「编制人」「审核人」「签发人」字段；签发时必须带报告结论，
结论随明细、列表、导出接口原样返回，供联调检查脚本逐口比对。
"""
from __future__ import annotations

from typing import Any

from app.store import store

MODULE = "report"
REQUIRED_FIELDS = ["报告编号", "关联任务", "编制人"]
OPTIONAL_FIELDS = ["审核人", "签发人", "报告日期", "报告类型", "报告结论"]
STATUS_ORDER = ["待编制", "待审核", "待签发", "已签发"]
ACTION_RULES = {"编制报告": "待审核", "审核通过": "待签发", "签发报告": "已签发"}
# 每个动作只在对应状态下可执行，保证三段链路不能跳步。
ACTION_BY_STATUS = {
    "待编制": "编制报告",
    "待审核": "审核通过",
    "待签发": "签发报告",
}
# 动作执行时要落到记录上的经办人字段；签发动作额外落报告结论。
ACTION_PERSON_FIELD = {
    "编制报告": "编制人",
    "审核通过": "审核人",
    "签发报告": "签发人",
}
CONCLUSION_FIELD = "报告结论"
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
        entry = {"id": max((int(row.get("id", 0)) for row in rows), default=0) + 1}
        entry.update({field: values.get(field) for field in REQUIRED_FIELDS})
        for field in OPTIONAL_FIELDS:
            if str(values.get(field) or "").strip():
                entry[field] = values[field]
        entry.setdefault("审核人", "")
        entry.setdefault("签发人", "")
        entry.setdefault(CONCLUSION_FIELD, "")
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
        if action not in ACTION_RULES:
            return None, f"动作「{action}」不属于检测报告可执行范围"
        current = str(entry.get("status") or "")
        expected = ACTION_BY_STATUS.get(current)
        if expected is None:
            return None, f"报告当前为「{current}」，三段签发链路已结束，不能再执行动作"
        if expected != action:
            return None, f"报告当前为「{current}」，应先执行「{expected}」，不能跳步执行「{action}」"

        person_field = ACTION_PERSON_FIELD[action]
        person = str(values.get(person_field) or entry.get(person_field) or "").strip()
        if not person:
            return None, f"缺少{person_field}，无法完成「{action}」"
        entry[person_field] = person

        target = ACTION_RULES[action]
        if action == "签发报告":
            conclusion = str(values.get(CONCLUSION_FIELD) or entry.get(CONCLUSION_FIELD) or "").strip()
            if not conclusion:
                return None, "缺少报告结论，无法签发报告"
            entry[CONCLUSION_FIELD] = conclusion

        entry["status"] = target
        entry["pending"] = target != STATUS_ORDER[-1]
        entry["abnormal"] = action in NEGATIVE_ACTIONS
        return entry, f"检测报告已{action}"
