#!/usr/bin/env python3
"""以固定频率采集容器可见资源；不读取环境变量或 Agent 输入。"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import time


def read(path: str) -> str | None:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None


def sample() -> dict[str, object]:
    return {
        "observed_at_unix_ns": time.time_ns(),
        "visible_cpus": os.cpu_count(),
        "kernel": read("/proc/sys/kernel/osrelease"),
        "cpu_stat": read("/sys/fs/cgroup/cpu.stat"),
        "cpu_max": read("/sys/fs/cgroup/cpu.max"),
        "memory_current": read("/sys/fs/cgroup/memory.current"),
        "memory_max": read("/sys/fs/cgroup/memory.max"),
        "memory_events": read("/sys/fs/cgroup/memory.events"),
        "pids_current": read("/sys/fs/cgroup/pids.current"),
        "pids_max": read("/sys/fs/cgroup/pids.max"),
        "scaling_cur_freq_khz": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"),
    }


parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--interval-seconds", type=float, default=1.0)
args = parser.parse_args()
with open(args.output, "a", encoding="utf-8", buffering=1) as output:
    while True:
        output.write(json.dumps(sample(), separators=(",", ":")) + "\n")
        time.sleep(args.interval_seconds)
