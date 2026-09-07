#!/usr/bin/env python3

import argparse
import csv
import json
import math
import pathlib
import re
import statistics


FIELD_RE = re.compile(r'([A-Za-z0-9_-]+)=("[^"]*"|[^ \t"]*)')
REQUIRED_CONTAINERD_PHASES = (
    "cri-receive",
    "id-generated",
    "cni-setup",
    "controller-create-begin",
    "shim-manager-start-begin",
    "binary-start-begin",
    "shim-bootstrap-process",
    "shim-connect",
    "shim-create-rpc",
    "controller-create",
    "cri-return",
)


def parse_fields(line):
    marker = line.find("cube_perf ")
    if marker < 0:
        return None
    fields = {}
    for key, value in FIELD_RE.findall(line[marker:]):
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        fields[key] = value
    for key in ("ts_mono_us", "duration_us"):
        if key in fields:
            fields[key] = int(fields[key])
    return fields


def read_events(path, component):
    events = []
    for line_number, line in enumerate(pathlib.Path(path).read_text(errors="replace").splitlines(), 1):
        fields = parse_fields(line)
        if not fields or fields.get("component") != component:
            continue
        if not fields.get("phase") or not fields.get("ts_mono_us"):
            continue
        fields["_line"] = line_number
        events.append(fields)
    return events


def nearest_rank(values, quantile):
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[max(0, math.ceil(quantile * len(ordered)) - 1)]


def distribution(values):
    return {
        "count": len(values),
        "min": min(values) if values else None,
        "mean": statistics.fmean(values) if values else None,
        "p50": nearest_rank(values, 0.50),
        "p95": nearest_rank(values, 0.95),
        "p99": nearest_rank(values, 0.99),
        "max": max(values) if values else None,
    }


def unique_phase_map(events, required, identity):
    grouped = {}
    for event in events:
        grouped.setdefault(event["phase"], []).append(event)
    duplicates = sorted(phase for phase, rows in grouped.items() if len(rows) != 1)
    missing = sorted(set(required) - set(grouped))
    if duplicates or missing:
        raise ValueError(
            f"invalid phase inventory for {identity}: missing={missing} duplicates={duplicates}"
        )
    return {phase: rows[0] for phase, rows in grouped.items()}


def begin(event):
    return event["ts_mono_us"] - event.get("duration_us", 0)


def analyze(containerd_events, shim_events, expected_uids, mode):
    expected_uids = set(expected_uids)
    expected = len(expected_uids)
    if not expected_uids or "" in expected_uids:
        raise ValueError("expected Pod UID inventory must be non-empty")
    by_uid = {}
    for event in containerd_events:
        uid = event.get("pod_uid", "")
        if uid in expected_uids:
            by_uid.setdefault(uid, []).append(event)
    if set(by_uid) != expected_uids:
        missing = sorted(expected_uids - set(by_uid))
        extra = sorted(set(by_uid) - expected_uids)
        raise ValueError(f"containerd UID inventory mismatch: missing={missing} extra={extra}")

    shim_by_sid = {}
    for event in shim_events:
        if (
            event.get("operation") == "create"
            and event.get("phase") == "ttrpc-total"
            and event.get("sandbox_id")
        ):
            shim_by_sid.setdefault(event["sandbox_id"], []).append(event)

    samples = []
    for uid, events in sorted(by_uid.items()):
        phases = unique_phase_map(events, REQUIRED_CONTAINERD_PHASES, uid)
        sandbox_ids = {event.get("sandbox_id") for event in events if event.get("sandbox_id")}
        if len(sandbox_ids) != 1:
            raise ValueError(f"sandbox inventory for {uid} is {sorted(sandbox_ids)}")
        sandbox_id = next(iter(sandbox_ids))
        shim_create_rows = shim_by_sid.get(sandbox_id, [])
        if len(shim_create_rows) != 1:
            raise ValueError(
                f"Shim create inventory for {sandbox_id} is {len(shim_create_rows)}, expected 1"
            )

        receive = phases["cri-receive"]["ts_mono_us"]
        cni_begin = begin(phases["cni-setup"])
        cni_end = phases["cni-setup"]["ts_mono_us"]
        controller_begin = phases["controller-create-begin"]["ts_mono_us"]
        manager_begin = phases["shim-manager-start-begin"]["ts_mono_us"]
        binary_begin = phases["binary-start-begin"]["ts_mono_us"]
        bootstrap_begin = begin(phases["shim-bootstrap-process"])
        bootstrap_end = phases["shim-bootstrap-process"]["ts_mono_us"]
        rpc_begin = begin(phases["shim-create-rpc"])
        shim_begin = begin(shim_create_rows[0])

        ordered = (
            receive,
            cni_begin,
            cni_end,
            controller_begin,
            manager_begin,
            binary_begin,
            bootstrap_begin,
            bootstrap_end,
            rpc_begin,
            shim_begin,
        )
        if any(left > right for left, right in zip(ordered, ordered[1:])):
            raise ValueError(f"non-monotonic pre-Shim timeline for {uid}: {ordered}")

        sample = {
            "pod_uid": uid,
            "sandbox_id": sandbox_id,
            "cri_to_shim_create_begin_us": shim_begin - receive,
            "cri_to_cni_begin_us": cni_begin - receive,
            "cni_setup_us": cni_end - cni_begin,
            "cni_end_to_controller_begin_us": controller_begin - cni_end,
            "controller_to_manager_begin_us": manager_begin - controller_begin,
            "manager_to_binary_begin_us": binary_begin - manager_begin,
            "binary_to_bootstrap_begin_us": bootstrap_begin - binary_begin,
            "shim_bootstrap_process_us": bootstrap_end - bootstrap_begin,
            "bootstrap_end_to_rpc_begin_us": rpc_begin - bootstrap_end,
            "ttrpc_dispatch_us": shim_begin - rpc_begin,
            "shim_connect_us": phases["shim-connect"].get("duration_us", 0),
            "shim_create_rpc_us": phases["shim-create-rpc"].get("duration_us", 0),
        }
        components = (
            "cri_to_cni_begin_us",
            "cni_setup_us",
            "cni_end_to_controller_begin_us",
            "controller_to_manager_begin_us",
            "manager_to_binary_begin_us",
            "binary_to_bootstrap_begin_us",
            "shim_bootstrap_process_us",
            "bootstrap_end_to_rpc_begin_us",
            "ttrpc_dispatch_us",
        )
        sample["pre_shim_component_sum_us"] = sum(sample[key] for key in components)
        sample["pre_shim_residual_us"] = (
            sample["cri_to_shim_create_begin_us"] - sample["pre_shim_component_sum_us"]
        )
        samples.append(sample)

    unique_sandboxes = len({sample["sandbox_id"] for sample in samples})
    if unique_sandboxes != expected:
        raise ValueError(f"unique sandbox inventory is {unique_sandboxes}, expected {expected}")
    if any(sample["pre_shim_residual_us"] != 0 for sample in samples):
        raise ValueError("non-overlap component residual is not zero")

    metric_names = sorted(key for key in samples[0] if key.endswith("_us"))
    distributions = {
        key: distribution([sample[key] for sample in samples]) for key in metric_names
    }
    target = 80_000 if mode == "serial" else 150_000
    return {
        "mode": mode,
        "expected": expected,
        "correlated": len(samples),
        "unique_pod_uids": len(by_uid),
        "unique_sandbox_ids": unique_sandboxes,
        "method": {
            "clock": "Linux CLOCK_MONOTONIC shared by containerd and CubeShim",
            "percentile": "nearest-rank",
            "pre_shim": "CRI receive through CubeShim ttrpc create handler begin",
            "non_overlap": "nine adjacent intervals; residual must equal zero per Pod",
        },
        "target_us": target,
        "gate_pass": distributions["cri_to_shim_create_begin_us"]["p95"] <= target,
        "distributions": distributions,
        "samples": samples,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--containerd-log", required=True)
    parser.add_argument("--shim-log", required=True)
    parser.add_argument("--pods-csv", required=True)
    parser.add_argument("--expected", required=True, type=int)
    parser.add_argument("--mode", choices=("serial", "concurrent"), required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    with pathlib.Path(args.pods_csv).open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    pod_uids = [row.get("uid", "") for row in rows]
    if len(pod_uids) != args.expected or len(set(pod_uids)) != args.expected:
        raise ValueError(
            f"pods.csv UID inventory count={len(pod_uids)} unique={len(set(pod_uids))}"
            f" expected={args.expected}"
        )

    result = analyze(
        read_events(args.containerd_log, "containerd"),
        read_events(args.shim_log, "shim"),
        pod_uids,
        args.mode,
    )
    output = pathlib.Path(args.output)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    primary = result["distributions"]["cri_to_shim_create_begin_us"]
    print(
        "S55D1_TRACE_ANALYSIS"
        f" mode={result['mode']} correlated={result['correlated']}"
        f" unique_uids={result['unique_pod_uids']}"
        f" unique_sandboxes={result['unique_sandbox_ids']}"
        f" pre_shim_p95_us={primary['p95']} target_us={result['target_us']}"
        f" gate_pass={str(result['gate_pass']).lower()}"
    )
    for key, values in result["distributions"].items():
        print(
            f"S55D1_DIST metric={key} count={values['count']}"
            f" p50={values['p50']} p95={values['p95']} p99={values['p99']}"
            f" max={values['max']}"
        )


if __name__ == "__main__":
    main()
