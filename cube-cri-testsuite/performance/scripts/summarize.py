#!/usr/bin/env python3
"""汇总 JSONL 原始记录；固定 seed 的 bootstrap 使结论可重算。"""
import argparse
import json
import math
import random
import statistics
from collections import defaultdict
from pathlib import Path


def nearest_rank(values, percentile):
    return values[max(0, math.ceil(len(values) * percentile) - 1)]


def bootstrap_median_ci(values, seed, samples=5000):
    rng = random.Random(seed)
    n = len(values)
    medians = sorted(statistics.median(rng.choices(values, k=n)) for _ in range(samples))
    return nearest_rank(medians, 0.025), nearest_rank(medians, 0.975)


def relative(cube, baseline, higher_is_better):
    # 原始指标变化。保留“越高/越低越好”供报告解释，不能把吞吐增益写成
    # 超过 -100% 的“负损耗”。
    return None if baseline == 0 else cube / baseline - 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20260909)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    groups = defaultdict(list)
    for line in args.input.read_text().splitlines():
        record = json.loads(line)
        groups[(record["test"], record["mode"])].append(record)

    summaries = []
    for (test, mode), records in sorted(groups.items()):
        values = sorted(float(record["value"]) for record in records)
        first = records[0]
        ci_low, ci_high = bootstrap_median_ci(values, args.seed)
        extras = {}
        # fio 主指标是 IOPS，但带宽和完成延迟同样是预注册指标；按每轮结果
        # 取中位数及 CI，不能从已聚合 IOPS 反推。
        for field in ("bandwidth_bytes_per_second", "clat_p99_ns", "retransmits"):
            extra_values = sorted(float(record[field]) for record in records
                                  if record.get(field) is not None)
            if len(extra_values) == len(records):
                low, high = bootstrap_median_ci(extra_values, args.seed)
                extras[field] = {
                    "n": len(extra_values),
                    "median": statistics.median(extra_values),
                    "median_ci95": [low, high],
                }
        summaries.append({
            "test": test,
            "mode": mode,
            "tool": first["tool"],
            "metric": first["metric"],
            "unit": first["unit"],
            "higher_is_better": first["higher_is_better"],
            "n": len(values),
            "median": statistics.median(values),
            "p05": nearest_rank(values, 0.05),
            "p95": nearest_rank(values, 0.95),
            "min": values[0],
            "max": values[-1],
            "median_ci95": [ci_low, ci_high],
            "extras": extras,
        })

    by_test = defaultdict(dict)
    for summary in summaries:
        by_test[summary["test"]][summary["mode"]] = summary
    comparisons = []
    for test, modes in sorted(by_test.items()):
        if not {"host", "runc", "cube"}.issubset(modes):
            continue
        host, runc, cube = modes["host"], modes["runc"], modes["cube"]
        comparisons.append({
            "test": test,
            "unit": cube["unit"],
            "higher_is_better": cube["higher_is_better"],
            "cube_vs_host_relative_change": relative(cube["median"], host["median"], cube["higher_is_better"]),
            "cube_vs_runc_relative_change": relative(cube["median"], runc["median"], cube["higher_is_better"]),
            "host": host,
            "runc": runc,
            "cube": cube,
        })

    (args.output_dir / "summary.json").write_text(json.dumps({
        "bootstrap_seed": args.seed, "samples": summaries, "comparisons": comparisons,
    }, ensure_ascii=False, indent=2) + "\n")
    lines = ["# Cube CRI PVM 性能结果", "", "仅纳入成功的正式样本；CI 为 5000 次 bootstrap 中位数 95% 区间。", "",
             "| 测试 | Host 中位数 [CI] | runc 中位数 [CI] | Cube 中位数 [CI] | Cube/Host 指标变化 | Cube/runc 指标变化 |",
             "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for item in comparisons:
        def value(summary):
            low, high = summary["median_ci95"]
            return f'{summary["median"]:.4g} [{low:.4g}, {high:.4g}] {summary["unit"]}'
        direction = "↑好" if item["higher_is_better"] else "↓好"
        def percentage(change):
            return "不可计算（基线为 0）" if change is None else f"{change:+.2%}"
        lines.append("| {test} ({direction}) | {host} | {runc} | {cube} | {h} | {r} |".format(
            test=item["test"], host=value(item["host"]), runc=value(item["runc"]), cube=value(item["cube"]),
            h=percentage(item["cube_vs_host_relative_change"]), r=percentage(item["cube_vs_runc_relative_change"]), direction=direction,
        ))
    extra_path_summaries = [summary for summary in summaries
                            if summary["mode"] not in ("host", "runc", "cube")]
    if extra_path_summaries:
        lines += ["", "## 附加路径", "", "这些路径不与 Host/runc/Cube 三方主表合并。", "",
                  "| 测试 | 路径 | 中位数 [CI] |", "| --- | --- | ---: |"]
        for summary in extra_path_summaries:
            low, high = summary["median_ci95"]
            lines.append(f'| {summary["test"]} | {summary["mode"]} | '
                         f'{summary["median"]:.4g} [{low:.4g}, {high:.4g}] {summary["unit"]} |')
    fio_items = [item for item in comparisons if item["test"].startswith("fio-")]
    for field, title, unit, divisor in (
        ("bandwidth_bytes_per_second", "fio 带宽", "MiB/s", 1024 * 1024),
        ("clat_p99_ns", "fio 完成延迟 P99", "us", 1000),
    ):
        items = [item for item in fio_items if all(field in item[mode]["extras"]
                                                    for mode in ("host", "runc", "cube"))]
        if not items:
            continue
        lines += ["", f"## {title}", "",
                  "每轮对应指标的中位数；CI 为同一 5000 次 bootstrap 95% 区间。", "",
                  "| 测试 | Host | runc | Cube |", "| --- | ---: | ---: | ---: |"]
        for item in items:
            def extra(mode):
                data = item[mode]["extras"][field]
                low, high = data["median_ci95"]
                return f'{data["median"] / divisor:.4g} [{low / divisor:.4g}, {high / divisor:.4g}] {unit}'
            lines.append(f'| {item["test"]} | {extra("host")} | {extra("runc")} | {extra("cube")} |')
    retransmit_summaries = [summary for summary in summaries if "retransmits" in summary["extras"]]
    if retransmit_summaries:
        lines += ["", "## iperf TCP 重传", "", "每轮 TCP 重传次数的中位数；0 表示中位数为零。", "",
                  "| 测试 | 路径 | 重传中位数 [CI] |", "| --- | --- | ---: |"]
        for summary in retransmit_summaries:
            data = summary["extras"]["retransmits"]
            low, high = data["median_ci95"]
            lines.append(f'| {summary["test"]} | {summary["mode"]} | '
                         f'{data["median"]:.4g} [{low:.4g}, {high:.4g}] |')
    if not comparisons:
        lines += ["", "没有包含完整 Host/runc/Cube 三组的测试，无法形成直接损耗结论。"]
    (args.output_dir / "report.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
