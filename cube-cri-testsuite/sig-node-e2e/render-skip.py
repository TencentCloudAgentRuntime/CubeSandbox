#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys


def load_skip_list(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise ValueError("skip list must contain an entries array")
    return entries


def enabled_entries(entries):
    result = []
    seen = set()
    for index, entry in enumerate(entries):
        if not entry.get("enabled", True):
            continue
        entry_id = entry.get("id")
        pattern = entry.get("pattern")
        reason = entry.get("reason")
        source = entry.get("source")
        exit_criteria = entry.get("exitCriteria")
        if not entry_id or not isinstance(entry_id, str):
            raise ValueError(f"entry #{index} must have a non-empty id")
        if entry_id in seen:
            raise ValueError(f"duplicate entry id: {entry_id}")
        seen.add(entry_id)
        if not pattern or not isinstance(pattern, str):
            raise ValueError(f"{entry_id}: pattern must be non-empty")
        if not reason or not isinstance(reason, str):
            raise ValueError(f"{entry_id}: reason must be non-empty")
        if not source or not isinstance(source, str):
            raise ValueError(f"{entry_id}: source must be non-empty")
        if not exit_criteria or not isinstance(exit_criteria, str):
            raise ValueError(f"{entry_id}: exitCriteria must be non-empty")
        try:
            re.compile(pattern)
        except re.error as exc:
            raise ValueError(f"{entry_id}: invalid regex: {exc}") from exc
        result.append(entry)
    return result


def combined_regex(entries):
    return "|".join(f"(?:{entry['pattern']})" for entry in entries)


def print_markdown(entries):
    print("| ID | Regex | 原因 | 退出条件 |")
    print("| --- | --- | --- | --- |")
    for entry in entries:
        pattern = entry["pattern"].replace("|", "\\|")
        reason = entry["reason"].replace("|", "\\|")
        exit_criteria = entry["exitCriteria"].replace("|", "\\|")
        print(f"| `{entry['id']}` | `{pattern}` | {reason} | {exit_criteria} |")


def main():
    default_path = os.path.join(os.path.dirname(__file__), "skip-list.json")
    parser = argparse.ArgumentParser(description="Render Cube CRI SIG Node e2e skip regex from the maintained skip list.")
    parser.add_argument("--list", default=default_path, help="skip-list.json path")
    parser.add_argument("--format", choices=("regex", "arg", "markdown", "count"), default="regex")
    parser.add_argument("--base-skip", default="", help="existing ginkgo skip regex to prepend")
    args = parser.parse_args()

    try:
        entries = enabled_entries(load_skip_list(args.list))
    except Exception as exc:
        print(f"invalid skip list: {exc}", file=sys.stderr)
        return 2

    regex = combined_regex(entries)
    if args.base_skip and regex:
        regex = f"(?:{args.base_skip})|(?:{regex})"
    elif args.base_skip:
        regex = args.base_skip

    if args.format == "regex":
        print(regex)
    elif args.format == "arg":
        print(f"--ginkgo.skip={regex}")
    elif args.format == "markdown":
        print_markdown(entries)
    elif args.format == "count":
        print(len(entries))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
