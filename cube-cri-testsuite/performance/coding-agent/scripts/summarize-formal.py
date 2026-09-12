#!/usr/bin/env python3
"""离线汇总 runc/Cube 配对；所有 bootstrap 仅表示小样本敏感度。"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import statistics


def percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    index = (len(ordered) - 1) * q
    low, high = math.floor(index), math.ceil(index)
    return ordered[low] if low == high else ordered[low] + (ordered[high] - ordered[low]) * (index - low)


def summary(values: list[float], seed: int) -> dict[str, float | int]:
    rng = random.Random(seed)
    bootstrap = [statistics.median([rng.choice(values) for _ in values]) for _ in range(5000)]
    return {
        "n": len(values),
        "median": statistics.median(values),
        "p25": percentile(values, 0.25),
        "p75": percentile(values, 0.75),
        "bootstrap_p2_5": percentile(bootstrap, 0.025),
        "bootstrap_p97_5": percentile(bootstrap, 0.975),
    }


def seed_for(seed: int, name: str) -> int:
    return seed + int(hashlib.sha256(name.encode()).hexdigest()[:8], 16)


parser = argparse.ArgumentParser()
parser.add_argument("--cases", type=Path, required=True)
parser.add_argument("--seed", type=int, required=True)
parser.add_argument("--output-dir", type=Path, required=True)
parser.add_argument("--title", default="Terminal-Bench Pi Runtime 统计")
args = parser.parse_args()

records: list[dict] = []
for path in sorted(args.cases.glob("*/result.json")):
    try:
        records.append(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError):
        continue

formal = [record for record in records if record.get("round", -1) > 0]
by_pair: dict[tuple[str, int], dict[str, dict]] = {}
for record in formal:
    by_pair.setdefault((record.get("task", ""), record.get("round", -1)), {})[record.get("mode", "")] = record

paired: dict[tuple[str, int], dict[str, dict]] = {}
unpaired: list[dict] = []
for key, modes in sorted(by_pair.items()):
    if set(modes) == {"runc", "cube"} and all(item.get("success") for item in modes.values()):
        paired[key] = modes
    else:
        unpaired.append({"task": key[0], "round": key[1], "modes": {mode: value.get("success") for mode, value in modes.items()}})

metrics: dict[str, object] = {}
for metric in ("t_agent_ns", "t_verify_official_ns", "t_trial_observed_ns", "t_e2e_observed_ns"):
    by_mode = {
        mode: [float(modes[mode][metric]) for modes in paired.values() if modes[mode].get(metric) is not None]
        for mode in ("runc", "cube")
    }
    pair_rows = []
    ratios = []
    differences = []
    for (task, round_number), modes in paired.items():
        runc = modes["runc"].get(metric)
        cube = modes["cube"].get(metric)
        if not isinstance(runc, (int, float)) or not isinstance(cube, (int, float)) or runc <= 0:
            continue
        ratio = cube / runc - 1
        difference = cube - runc
        ratios.append(ratio)
        differences.append(difference)
        pair_rows.append({"task": task, "round": round_number, "runc_ns": runc, "cube_ns": cube, "cube_minus_runc_ns": difference, "cube_over_runc_minus_1": ratio})
    metrics[metric] = {
        "unit": "ns",
        "by_mode": {mode: summary(values, seed_for(args.seed, metric + mode)) for mode, values in by_mode.items() if values},
        "paired_relative_change": summary(ratios, seed_for(args.seed, metric + "ratio")) if ratios else None,
        "paired_absolute_change_ns": summary(differences, seed_for(args.seed, metric + "difference")) if differences else None,
        "pairs": pair_rows,
    }

report = {
    "formal_records": len(formal),
    "paired_successes": len(paired),
    "unpaired": unpaired,
    "metrics": metrics,
    "interpretation": "bootstrap 分位数是固定种子下的小样本经验重采样敏感度，不是可泛化置信区间。",
}
args.output_dir.mkdir(parents=True, exist_ok=True)
(args.output_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

lines = [f"# {args.title}", "", f"正式记录：{len(formal)}；runc/Cube 成功配对：{len(paired)}。", ""]
if not paired:
    lines.append("尚无可用于比较的正式配对样本；不得据此作运行时结论。")
if unpaired:
    lines += ["", "## 未进入配对统计的样本", "", "| 任务 | 轮次 | runc | Cube |", "| --- | ---: | --- | --- |"]
    for row in unpaired:
        lines.append(f"| {row['task']} | {row['round']} | {row['modes'].get('runc', '缺失')} | {row['modes'].get('cube', '缺失')} |")
for metric, item in metrics.items():
    if not item["by_mode"]:
        continue
    lines += ["", f"## {metric}", "", "| 运行时 | n | 中位数(ns) | P25 | P75 | bootstrap P2.5–P97.5 |", "| --- | ---: | ---: | ---: | ---: | --- |"]
    for mode in ("runc", "cube"):
        value = item["by_mode"].get(mode)
        if value:
            lines.append(f"| {mode} | {value['n']} | {value['median']:.0f} | {value['p25']:.0f} | {value['p75']:.0f} | [{value['bootstrap_p2_5']:.0f}, {value['bootstrap_p97_5']:.0f}] |")
    relative = item["paired_relative_change"]
    absolute = item["paired_absolute_change_ns"]
    if relative and absolute:
        lines += ["", f"Cube/runc 中位相对变化：{relative['median'] * 100:.2f}%（bootstrap P2.5–P97.5：[{relative['bootstrap_p2_5'] * 100:.2f}%, {relative['bootstrap_p97_5'] * 100:.2f}%]）。", f"Cube-runc 中位绝对差：{absolute['median']:.0f} ns。"]
lines += ["", "bootstrap 分位数仅反映本批配对的经验重采样敏感度，不是可泛化置信区间。"]
(args.output_dir / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
