#!/usr/bin/env python3

import collections
import json
import os
import pathlib
import re


ROOT = pathlib.Path(os.environ.get("S53B_GINKGO_ROOT", "/tmp/s53b-final-ginkgo"))
SHARDS = {
    "lifecycle": (r"/e2e_node/container_lifecycle_test\.go$", 1, 99999),
    "storage-a": (r"/e2e/common/storage/(empty_dir|configmap_volume|projected_configmap)\.go$", 1, 99999),
    "storage-b": (r"/e2e/common/storage/(downwardapi_volume|host_path|projected_combined|projected_downwardapi|projected_secret|secrets_volume)\.go$", 1, 99999),
    "probes": (r"/e2e/common/node/container_probe\.go$", 1, 99999),
    "common-lifecycle": (r"/e2e/common/node/(lifecycle_hook|security_context|runtime|pods)\.go$", 1, 99999),
    "common-misc": (r"/e2e/common/node/(pod_hostnameoverride|downwardapi|kubelet|sysctl|runtimeclass|init_container|containers|expansion|configmap|secrets|ephemeral_containers|privileged|pod_admission|kubelet_etc_hosts)\.go$", 1, 99999),
    "network": (r"/e2e/common/(network/networking|node/node_lease)\.go$|/e2e_node/(deleted_pods_test|pod_conditions_test|pod_ips|pod_host_ips|endpoints_test)\.go$", 1, 99999),
    "system-a": (r"/e2e_node/(mirror_pod_test|mirror_pod_grace_period_test|static_pod_test|swap_test|oomkiller_linux_test|mount_rro_linux_test|security_context_test|apparmor_test|proc_mount_test|kubelet_tls_test|kubelet_server_tls_test)\.go$", 1, 99999),
    "system-b": (r"/e2e_node/(device_plugin_failures_test|summary_test|pods_container_manager_test|podresources_test|garbage_collector_test|log_path_test|image_gc_test|volume_manager_test|terminate_pods_test|runtime_conformance_test|runtimeclass_test|pods_lifecycle_termination_test|device_plugin_test|cpu_manager_test|container_metrics_test|pod_hostnamefqdn_test)\.go$", 1, 99999),
}
SOURCES = {
    "lifecycle": ["lifecycle", "lifecycle-serial", "lifecycle-start-order"],
    "storage-a": ["storage-a"],
    "storage-b": ["storage-b"],
    "probes": ["probes"],
    "common-lifecycle": ["common-lifecycle", "common-lifecycle-image-pull"],
    "common-misc": ["common-misc", "common-misc-privileged"],
    "network": ["network", "network-endpoints"],
    "system-a": ["system-a", "system-a-privileged-targeted"],
    "system-b": ["system-b", "system-b-runtimeclass", "system-b-device"],
}
FAILURE_STATES = {"failed", "panicked", "timedout", "interrupted"}
SKIP_STATES = {"skipped", "pending"}


def load(label):
    with (ROOT / f"{label}.json").open(encoding="utf-8") as source:
        return json.load(source)


def reports(label):
    for suite in load(label):
        for report in suite["SpecReports"]:
            if report.get("LeafNodeType") == "It" and report.get("LeafNodeText"):
                yield report


def key(report):
    location = report.get("LeafNodeLocation") or {}
    return (
        location.get("FileName", ""),
        int(location.get("LineNumber", 0)),
        report.get("LeafNodeText", ""),
        tuple(report.get("ContainerHierarchyTexts") or []),
    )


def observed(report):
    state = report.get("State", "")
    if state not in SKIP_STATES:
        return True
    failure = report.get("Failure") or {}
    return (
        int(report.get("NumAttempts") or 0) > 0
        or float(report.get("RunTime") or 0) > 0
        or bool(failure.get("Message"))
    )


baseline = {}
for report in reports("dryrun"):
    if report.get("State") == "skipped":
        continue
    report_key = key(report)
    if report_key in baseline:
        raise RuntimeError(f"duplicate dryrun key: {report_key}")
    baseline[report_key] = report
if len(baseline) != 477:
    raise RuntimeError(f"expected 477 dryrun specs, got {len(baseline)}")

assignments = {}
for report_key in baseline:
    filename, line, _, _ = report_key
    matched = [
        shard
        for shard, (pattern, first, last) in SHARDS.items()
        if re.search(pattern, filename) and first <= line <= last
    ]
    if len(matched) != 1:
        raise RuntimeError(f"expected one shard for {report_key}, got {matched}")
    assignments[report_key] = matched[0]

source_maps = {}
for label in {label for labels in SOURCES.values() for label in labels}:
    source_maps[label] = {key(report): report for report in reports(label) if observed(report)}

final = {}
for report_key, shard in assignments.items():
    for label in SOURCES[shard]:
        report = source_maps[label].get(report_key)
        if report is not None:
            final[report_key] = (label, report)
if len(final) != 477:
    missing = sorted(set(baseline) - set(final))
    raise RuntimeError(f"final reports cover {len(final)}/477; missing={missing[:20]}")

overall = collections.Counter()
by_shard = collections.defaultdict(collections.Counter)
failures = []
skips = []
for report_key, shard in sorted(assignments.items()):
    label, report = final[report_key]
    state = report.get("State", "unknown")
    category = "failed" if state in FAILURE_STATES else "skipped" if state in SKIP_STATES else state
    overall[category] += 1
    by_shard[shard][category] += 1
    record = {
        "source": label,
        "file": report_key[0],
        "line": report_key[1],
        "name": report_key[2],
        "hierarchy": list(report_key[3]),
        "message": ((report.get("Failure") or {}).get("Message") or "").splitlines()[0:1],
    }
    if category == "failed":
        failures.append(record)
    elif category == "skipped":
        skips.append(record)

print("OVERALL\t" + "\t".join(f"{name}={overall[name]}" for name in ["passed", "failed", "skipped"]))
for shard in SHARDS:
    counts = by_shard[shard]
    total = sum(counts.values())
    print(
        "SHARD\t"
        + shard
        + "\t"
        + "\t".join(
            [f"total={total}", f"passed={counts['passed']}", f"failed={counts['failed']}", f"skipped={counts['skipped']}"]
        )
    )
for record in failures:
    print("FAIL\t" + json.dumps(record, ensure_ascii=False, sort_keys=True))
for record in skips:
    print("SKIP\t" + json.dumps(record, ensure_ascii=False, sort_keys=True))
