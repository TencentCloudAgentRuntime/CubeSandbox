#!/usr/bin/env python3
"""从已脱敏 Pi 事件、验证结果和 Pod 快照生成一条可重算的样本记录。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def ns_duration(start: int | None, end: int | None) -> int | None:
    return end - start if isinstance(start, int) and isinstance(end, int) else None


parser = argparse.ArgumentParser()
parser.add_argument("--artifacts", type=Path, required=True)
parser.add_argument("--mode", required=True)
parser.add_argument("--task", required=True)
parser.add_argument("--round", type=int, required=True)
parser.add_argument("--pod-json", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--controller-e2e-start-monotonic-ns", type=int, required=True)
parser.add_argument("--controller-e2e-end-monotonic-ns", type=int, required=True)
parser.add_argument("--controller-trial-start-monotonic-ns", type=int, required=True)
parser.add_argument("--controller-trial-end-monotonic-ns", type=int, required=True)
args = parser.parse_args()

agent = load_json(args.artifacts / "agent-result.json")
verify = load_json(args.artifacts / "verify-result.json")
events = []
for line in (args.artifacts / "pi-events.jsonl").read_text(encoding="utf-8").splitlines():
    try:
        events.append(json.loads(line))
    except json.JSONDecodeError:
        pass

tool_start: dict[str, int] = {}
tool_ns = 0
tool_calls = 0
llm_ns = 0
response_ids: list[str] = []
usage: dict = {}
for event in events:
    observed = event.get("observed_at_unix_ns")
    if event.get("type") == "tool_execution_start":
        tool_calls += 1
        if isinstance(observed, int):
            tool_start[event.get("toolCallId", "")] = observed
    elif event.get("type") == "tool_execution_end" and isinstance(observed, int):
        started = tool_start.get(event.get("toolCallId", ""))
        if started is not None:
            tool_ns += observed - started
    message = event.get("message")
    if isinstance(message, dict) and message.get("role") == "assistant":
        if message.get("responseId"):
            if message["responseId"] not in response_ids:
                response_ids.append(message["responseId"])
        if isinstance(message.get("usage"), dict):
            usage = message["usage"]

pod = load_json(args.pod_json)
statuses = {item["name"]: item for item in pod.get("status", {}).get("containerStatuses", [])}
agent_status = statuses.get("agent", {}).get("state", {}).get("terminated", {})
record = {
    "task": args.task,
    "mode": args.mode,
    "round": args.round,
    "agent_exit_code": agent.get("exit_code"),
    "verify_exit_code": verify.get("exit_code"),
    "success": agent.get("exit_code") == 0 and verify.get("exit_code") == 0,
    "t_agent_ns": agent.get("duration_ns"),
    "t_verify_official_ns": verify.get("duration_ns"),
    "t_trial_observed_ns": ns_duration(
        args.controller_trial_start_monotonic_ns,
        args.controller_trial_end_monotonic_ns,
    ),
    "t_e2e_observed_ns": ns_duration(
        args.controller_e2e_start_monotonic_ns,
        args.controller_e2e_end_monotonic_ns,
    ),
    "t_tool_exec_ns_observed": tool_ns,
    "tool_call_count": tool_calls,
    "usage": usage,
    "response_ids": response_ids,
    "pod_created_at": pod.get("metadata", {}).get("creationTimestamp"),
    "agent_started_at": agent_status.get("startedAt"),
    "agent_finished_at": agent_status.get("finishedAt"),
    "image_id": statuses.get("agent", {}).get("imageID"),
    "pi_version": agent.get("pi_version"),
    "provider": agent.get("provider"),
    "model": agent.get("model"),
}
args.output.write_text(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
