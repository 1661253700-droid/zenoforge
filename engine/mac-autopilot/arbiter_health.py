"""Supervisor arbitration scorecard definitions and fixed 24-hour ledger counts."""
from datetime import timedelta


CRITERIA = {
    "supervisor.arbiter_dispatches_24h": ("supervisor", "arbiter dispatches in 24 h", 48, 120, False),
    # The sentinel bounds (healthy 0, unhealthy -1, higher is better) leave any measured count OK.
    "supervisor.cap_default_24h": ("supervisor", "supervisor-cap-default decisions in 24 h (measured, no bound)", 0, -1, True),
}

MEANING = {
    "supervisor.arbiter_dispatches_24h": "24 小时内派出的 supervisor 仲裁 run 数（supervisor-arbiter 历史，固定滚动 24h）。高 = 仲裁在空转：单元反复升级而裁决不收敛；单单元总量由 supervisor_arbiter.unit_cap 终身上限约束。",
    "supervisor.cap_default_24h": "24 小时内触顶后由调度器按默认决定（obsolete/recut/park）收尾的单元数。只测量不设界：每个默认决定都省下一次模型 run，也无人被问到。",
}

SOURCE = {
    "supervisor.arbiter_dispatches_24h": "units.json（含 units-archive.json 退休行）的 supervisor-arbiter 历史事件，固定滚动 24h（不看 --hours 窗口）",
    "supervisor.cap_default_24h": "units.json（含 units-archive.json 退休行）的 supervisor-cap-default 历史事件，固定滚动 24h",
}


def ledger_metrics(units, now, timestamp):
    """Count arbitration dispatches and defaults over a fixed rolling 24-hour window."""
    day = now - timedelta(hours=24)
    counts = {"supervisor.arbiter_dispatches_24h": 0, "supervisor.cap_default_24h": 0}
    stages = {"supervisor-arbiter": "supervisor.arbiter_dispatches_24h",
              "supervisor-cap-default": "supervisor.cap_default_24h"}
    for unit in units:
        for event in unit.get("history") or []:
            metric = stages.get(event.get("stage"))
            at = timestamp(event.get("at")) if metric else None
            if at is not None and day <= at <= now:
                counts[metric] += 1
    return counts
