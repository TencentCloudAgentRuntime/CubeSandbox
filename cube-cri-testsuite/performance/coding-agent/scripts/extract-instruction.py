#!/usr/bin/env python3
"""从 Terminal-Bench task.yaml 读取 instruction 字段。"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

try:
    import yaml
except ImportError as error:
    raise SystemExit("缺少 PyYAML，无法解析 task.yaml") from error


parser = argparse.ArgumentParser()
parser.add_argument("task_yaml", type=Path)
args = parser.parse_args()

try:
    task = yaml.safe_load(args.task_yaml.read_text(encoding="utf-8"))
except yaml.YAMLError as error:
    raise SystemExit(f"解析 task.yaml 失败：{error}") from error

if not isinstance(task, dict):
    raise SystemExit("task.yaml 顶层必须是 YAML mapping")

instruction = task.get("instruction")
if not isinstance(instruction, str) or not instruction:
    raise SystemExit("task.yaml 缺少非空字符串 instruction 字段")

sys.stdout.write(instruction)
