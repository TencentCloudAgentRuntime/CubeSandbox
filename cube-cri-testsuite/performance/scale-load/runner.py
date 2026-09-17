#!/usr/bin/env python3

import copy
import http.client
import json
import math
import os
import pathlib
import queue
import socket
import ssl
import sys
import threading
import time
import urllib.parse


TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def required_env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def env_int(name, default, minimum=0):
    value = int(os.environ.get(name, str(default)))
    if value < minimum:
        raise SystemExit(f"{name} must be >= {minimum}")
    return value


def percentile(values, quantile):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(quantile * len(ordered)) - 1)]


def metric(values):
    return {
        "count": len(values),
        "p50Ms": percentile(values, 0.50),
        "p95Ms": percentile(values, 0.95),
        "p99Ms": percentile(values, 0.99),
        "minMs": min(values) if values else None,
        "maxMs": max(values) if values else None,
    }


class KubernetesAPI:
    def __init__(self, timeout=60):
        self.host = required_env("KUBERNETES_SERVICE_HOST")
        self.port = int(required_env("KUBERNETES_SERVICE_PORT_HTTPS"))
        self.timeout = timeout
        self.context = ssl.create_default_context(cafile=CA_PATH)
        self.token = pathlib.Path(TOKEN_PATH).read_text().strip()
        self.connection = None

    def close(self):
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def connect(self):
        self.close()
        self.connection = http.client.HTTPSConnection(
            self.host, self.port, context=self.context, timeout=self.timeout
        )

    def request(self, method, path, body=None):
        if self.connection is None:
            self.connect()
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        encoded = None
        if body is not None:
            encoded = json.dumps(body, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
        try:
            self.connection.request(method, path, body=encoded, headers=headers)
            response = self.connection.getresponse()
            payload = response.read()
            return response.status, payload
        except Exception:
            self.close()
            raise

    def watch(self, path):
        self.connect()
        self.connection.request(
            "GET",
            path,
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/json"},
        )
        return self.connection.getresponse()


class LoadRun:
    def __init__(self):
        self.run_id = required_env("RUN_ID")
        self.namespaces = [x for x in required_env("TARGET_NAMESPACES").split(",") if x]
        self.count = env_int("POD_COUNT", 1, 1)
        self.qps = env_int("CREATE_QPS", 1, 1)
        self.workers = min(self.count, env_int("CREATE_WORKERS", 1, 1))
        self.timeout = env_int("TIMEOUT_SECONDS", 1800, 1)
        self.stable_seconds = env_int("STABLE_SECONDS", 0, 0)
        self.target_node = os.environ.get("TARGET_NODE", "").strip()
        self.workload_profile = required_env("WORKLOAD_PROFILE")
        self.stage = required_env("STAGE")
        self.snapshotter_profile = required_env("SNAPSHOTTER_PROFILE")
        self.load_image = required_env("LOAD_IMAGE")
        self.cube_template_mode = required_env("CUBE_TEMPLATE_MODE")
        self.output = pathlib.Path(os.environ.get("OUTPUT_DIR", "/output"))
        self.template = json.loads(pathlib.Path(required_env("TEMPLATE_PATH")).read_text())
        self.lock = threading.Condition()
        self.records = {}
        self.errors = []
        self.watch_reconnects = 0
        self.watch_ready = {namespace: threading.Event() for namespace in self.namespaces}
        self.done = threading.Event()
        self.stop = threading.Event()
        self.create_queue = queue.Queue(maxsize=max(1, self.workers * 4))
        self.start_mono_ns = None
        self.start_wall_ns = None

        for index in range(self.count):
            namespace = self.namespaces[index % len(self.namespaces)]
            name = f"cube-cri-{self.run_id}-{index:05d}"
            self.records[(namespace, name)] = {
                "index": index,
                "namespace": namespace,
                "name": name,
                "created": False,
                "phase": "",
                "node": "",
                "error": "",
                "observed": {},
                "server": {},
                "restartCount": 0,
                "readyLost": False,
                "images": [],
                "workloadShape": {},
            }

    def add_error(self, message):
        with self.lock:
            self.errors.append(message)
            self.lock.notify_all()

    def pod_manifest(self, record):
        pod = copy.deepcopy(self.template)
        metadata = pod.setdefault("metadata", {})
        metadata["name"] = record["name"]
        metadata["namespace"] = record["namespace"]
        labels = metadata.setdefault("labels", {})
        labels["load-test-batch"] = self.run_id
        labels["load-test-index"] = str(record["index"])
        if self.target_node:
            pod.setdefault("spec", {}).setdefault("nodeSelector", {})[
                "kubernetes.io/hostname"
            ] = self.target_node
        return pod

    def observe(self, pod, observed_ns, observed_wall_ns):
        metadata = pod.get("metadata", {})
        key = (metadata.get("namespace", ""), metadata.get("name", ""))
        record = self.records.get(key)
        if record is None:
            return
        status = pod.get("status", {})
        conditions = {item.get("type"): item for item in status.get("conditions", [])}
        with self.lock:
            record["uid"] = metadata.get("uid", record.get("uid", ""))
            record["resourceVersion"] = metadata.get("resourceVersion", "")
            record["phase"] = status.get("phase", "")
            record["node"] = pod.get("spec", {}).get("nodeName", "")
            record["reason"] = status.get("reason", "")
            record["message"] = status.get("message", "")
            record["podIP"] = status.get("podIP", "")
            spec = pod.get("spec", {})
            containers = spec.get("containers", [])
            init_containers = spec.get("initContainers", [])
            record["workloadShape"] = {
                "serviceAccountName": spec.get("serviceAccountName", ""),
                "automountServiceAccountToken": spec.get("automountServiceAccountToken"),
                "containerCount": len(containers),
                "initContainerCount": len(init_containers),
                "volumeCount": len(spec.get("volumes", [])),
                "probeCount": sum(
                    probe in container
                    for container in containers + init_containers
                    for probe in ("startupProbe", "readinessProbe", "livenessProbe")
                ),
            }
            if metadata.get("creationTimestamp"):
                record["server"].setdefault("created", metadata["creationTimestamp"])
            if record["node"]:
                record["observed"].setdefault("scheduled", observed_ns)
            for condition_type, key_name in (("Initialized", "initialized"), ("Ready", "ready")):
                condition = conditions.get(condition_type, {})
                if condition.get("status") == "True":
                    record["observed"].setdefault(key_name, observed_ns)
                    if condition.get("lastTransitionTime"):
                        record["server"].setdefault(key_name, condition["lastTransitionTime"])
                elif key_name == "ready" and "ready" in record["observed"]:
                    record["readyLost"] = True
            container_statuses = status.get("containerStatuses", [])
            init_container_statuses = status.get("initContainerStatuses", [])
            record["images"] = sorted(
                [
                    {
                        "name": item.get("name", ""),
                        "image": item.get("image", ""),
                        "imageID": item.get("imageID", ""),
                        "init": is_init,
                    }
                    for is_init, statuses in (
                        (False, container_statuses),
                        (True, init_container_statuses),
                    )
                    for item in statuses
                ],
                key=lambda item: (item["init"], item["name"]),
            )
            expected_containers = len(pod.get("spec", {}).get("containers", []))
            started = [
                item.get("state", {}).get("running", {}).get("startedAt")
                for item in container_statuses
            ]
            if expected_containers and len(started) == expected_containers and all(started):
                record["observed"].setdefault("containersStarted", observed_ns)
                record["server"].setdefault("containersStarted", max(started))
            record["restartCount"] = sum(item.get("restartCount", 0) for item in container_statuses)
            record["lastObservedWallNs"] = observed_wall_ns
            if record["phase"] in ("Failed", "Succeeded") and "ready" not in record["observed"]:
                self.errors.append(
                    f"pod {record['namespace']}/{record['name']} terminated before Ready: "
                    f"phase={record['phase']} reason={record['reason']} message={record['message']}"
                )
            ready_count = sum("ready" in item["observed"] for item in self.records.values())
            if ready_count == self.count:
                self.done.set()
            self.lock.notify_all()

    def watch_namespace(self, namespace):
        api = KubernetesAPI(timeout=90)
        selector = urllib.parse.quote(f"load-test-batch={self.run_id}")
        base_path = f"/api/v1/namespaces/{urllib.parse.quote(namespace)}/pods"
        resource_version = ""
        initialized = False
        try:
            while not self.stop.is_set():
                if not initialized:
                    code, body = api.request("GET", f"{base_path}?labelSelector={selector}")
                    if code != 200:
                        raise RuntimeError(f"list pods in {namespace}: HTTP {code}: {body[:512]!r}")
                    listing = json.loads(body)
                    if listing.get("items"):
                        raise RuntimeError(f"namespace {namespace} already contains this batch")
                    resource_version = listing["metadata"]["resourceVersion"]
                    initialized = True
                    self.watch_ready[namespace].set()
                query = urllib.parse.urlencode(
                    {
                        "watch": "1",
                        "allowWatchBookmarks": "true",
                        "timeoutSeconds": "60",
                        "resourceVersion": resource_version,
                        "labelSelector": f"load-test-batch={self.run_id}",
                    }
                )
                try:
                    response = api.watch(f"{base_path}?{query}")
                    if response.status != 200:
                        payload = response.read()
                        raise RuntimeError(f"watch pods in {namespace}: HTTP {response.status}: {payload[:512]!r}")
                    for raw_line in response:
                        if self.stop.is_set():
                            return
                        line = raw_line.strip()
                        if not line:
                            continue
                        event = json.loads(line)
                        if event.get("type") == "ERROR":
                            obj = event.get("object", {})
                            if obj.get("code") == 410:
                                initialized = False
                                break
                            raise RuntimeError(f"watch error in {namespace}: {obj}")
                        pod = event.get("object", {})
                        resource_version = pod.get("metadata", {}).get(
                            "resourceVersion", resource_version
                        )
                        if event.get("type") != "BOOKMARK":
                            self.observe(pod, time.monotonic_ns(), time.time_ns())
                    with self.lock:
                        self.watch_reconnects += 1
                except (socket.timeout, TimeoutError, http.client.RemoteDisconnected, ConnectionError):
                    with self.lock:
                        self.watch_reconnects += 1
                    api.close()
        except Exception as error:
            self.watch_ready[namespace].set()
            self.add_error(f"watch {namespace}: {error!r}")
        finally:
            api.close()

    def create_worker(self):
        api = KubernetesAPI(timeout=120)
        while True:
            item = self.create_queue.get()
            try:
                if item is None:
                    return
                record, planned_ns = item
                now = time.monotonic_ns()
                if now < planned_ns:
                    time.sleep((planned_ns - now) / 1_000_000_000)
                start_ns = time.monotonic_ns()
                start_wall_ns = time.time_ns()
                with self.lock:
                    record["plannedCreateNs"] = planned_ns
                    record["createStartNs"] = start_ns
                    record["createStartWallNs"] = start_wall_ns
                path = f"/api/v1/namespaces/{urllib.parse.quote(record['namespace'])}/pods"
                try:
                    code, body = api.request("POST", path, self.pod_manifest(record))
                    return_ns = time.monotonic_ns()
                    return_wall_ns = time.time_ns()
                    with self.lock:
                        record["createReturnNs"] = return_ns
                        record["createReturnWallNs"] = return_wall_ns
                        record["createStatus"] = code
                        if code == 201:
                            created = json.loads(body)
                            record["created"] = True
                            record["uid"] = created.get("metadata", {}).get("uid", "")
                            record["server"].setdefault(
                                "created", created.get("metadata", {}).get("creationTimestamp", "")
                            )
                        else:
                            record["error"] = body[:1024].decode(errors="replace")
                            self.errors.append(
                                f"create {record['namespace']}/{record['name']}: HTTP {code}: {record['error']}"
                            )
                        self.lock.notify_all()
                except Exception as error:
                    with self.lock:
                        record["createReturnNs"] = time.monotonic_ns()
                        record["createReturnWallNs"] = time.time_ns()
                        record["error"] = repr(error)
                        self.errors.append(
                            f"create {record['namespace']}/{record['name']}: {error!r}"
                        )
                        self.lock.notify_all()
            finally:
                self.create_queue.task_done()
        api.close()

    def write_results(self):
        self.output.mkdir(parents=True, exist_ok=True)
        records = sorted(self.records.values(), key=lambda item: item["index"])
        metric_values = {
            "create_schedule_delay_ms": [],
            "create_request_ms": [],
            "create_start_to_scheduled_observed_ms": [],
            "create_start_to_initialized_observed_ms": [],
            "create_start_to_containers_started_observed_ms": [],
            "create_start_to_ready_observed_ms": [],
            "scheduled_to_ready_observed_ms": [],
            "containers_started_to_ready_observed_ms": [],
        }
        for record in records:
            start_ns = record.get("createStartNs")
            return_ns = record.get("createReturnNs")
            observed = record["observed"]
            planned_ns = record.get("plannedCreateNs")
            if planned_ns and start_ns:
                metric_values["create_schedule_delay_ms"].append((start_ns - planned_ns) / 1_000_000)
            if start_ns and return_ns:
                metric_values["create_request_ms"].append((return_ns - start_ns) / 1_000_000)
            for observed_key, metric_name in (
                ("scheduled", "create_start_to_scheduled_observed_ms"),
                ("initialized", "create_start_to_initialized_observed_ms"),
                ("containersStarted", "create_start_to_containers_started_observed_ms"),
                ("ready", "create_start_to_ready_observed_ms"),
            ):
                if start_ns and observed_key in observed:
                    metric_values[metric_name].append((observed[observed_key] - start_ns) / 1_000_000)
            if "scheduled" in observed and "ready" in observed:
                metric_values["scheduled_to_ready_observed_ms"].append(
                    (observed["ready"] - observed["scheduled"]) / 1_000_000
                )
            if "containersStarted" in observed and "ready" in observed:
                metric_values["containers_started_to_ready_observed_ms"].append(
                    (observed["ready"] - observed["containersStarted"]) / 1_000_000
                )

        create_starts = [x.get("createStartNs") for x in records if x.get("createStartNs")]
        create_returns = [x.get("createReturnNs") for x in records if x.get("createReturnNs")]
        scheduled = [x["observed"].get("scheduled") for x in records if x["observed"].get("scheduled")]
        started = [x["observed"].get("containersStarted") for x in records if x["observed"].get("containersStarted")]
        ready = [x["observed"].get("ready") for x in records if x["observed"].get("ready")]
        first_start = min(create_starts) if create_starts else None
        last_start = max(create_starts) if create_starts else None
        expected_digest = self.load_image.partition("@")[2]
        image_identity_mismatches = 0
        simple_shape_violations = 0
        for record in records:
            images = record["images"]
            if expected_digest and (
                not images or any(not item["imageID"].endswith(expected_digest) for item in images)
            ):
                image_identity_mismatches += 1
            if self.workload_profile == "simple":
                shape = record["workloadShape"]
                if (
                    shape.get("serviceAccountName") != "cube-cri-load"
                    or shape.get("automountServiceAccountToken") is not False
                    or shape.get("containerCount") != 1
                    or shape.get("initContainerCount") != 0
                    or shape.get("volumeCount") != 0
                    or shape.get("probeCount") != 0
                ):
                    simple_shape_violations += 1

        def from_first(values):
            return (max(values) - first_start) / 1_000_000 if first_start and values else None

        summary = {
            "runId": self.run_id,
            "namespaces": self.namespaces,
            "count": self.count,
            "createQPS": self.qps,
            "workers": self.workers,
            "workloadProfile": self.workload_profile,
            "stage": self.stage,
            "stableSeconds": self.stable_seconds,
            "targetNode": self.target_node,
            "snapshotterProfile": self.snapshotter_profile,
            "loadImage": self.load_image,
            "cubeTemplateMode": self.cube_template_mode,
            "created": sum(item["created"] for item in records),
            "scheduled": len(scheduled),
            "containersStarted": len(started),
            "ready": len(ready),
            "restartCount": sum(item["restartCount"] for item in records),
            "readyLost": sum(item["readyLost"] for item in records),
            "imageIdentityMismatches": image_identity_mismatches,
            "workloadShapeViolations": simple_shape_violations,
            "watchReconnects": self.watch_reconnects,
            "errors": self.errors,
            "batch": {
                "submitMs": (
                    (max(create_returns) - min(create_starts)) / 1_000_000
                    if create_returns and create_starts
                    else None
                ),
                "actualCreateStartQPS": (
                    ((len(create_starts) - 1) * 1_000_000_000 / (last_start - first_start))
                    if len(create_starts) > 1 and last_start > first_start
                    else None
                ),
                "allScheduledMs": from_first(scheduled),
                "allContainersStartedMs": from_first(started),
                "allReadyMs": from_first(ready),
            },
            "metrics": {name: metric(values) for name, values in metric_values.items()},
        }
        summary["success"] = (
            not self.errors
            and summary["created"] == self.count
            and summary["scheduled"] == self.count
            and summary["containersStarted"] == self.count
            and summary["ready"] == self.count
            and summary["readyLost"] == 0
            and summary["imageIdentityMismatches"] == 0
            and summary["workloadShapeViolations"] == 0
        )
        with (self.output / "pods.jsonl").open("w") as output:
            for record in records:
                output.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        (self.output / "batch-summary.json").write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n"
        )
        print("SUMMARY_JSON=" + json.dumps(summary, sort_keys=True), flush=True)
        return summary

    def run(self):
        if self.template.get("kind") != "Pod" or self.template.get("apiVersion") != "v1":
            raise SystemExit("template must be a core/v1 Pod")
        if self.template.get("spec", {}).get("nodeName"):
            raise SystemExit("template must not set spec.nodeName")

        watch_threads = []
        for namespace in self.namespaces:
            thread = threading.Thread(target=self.watch_namespace, args=(namespace,), daemon=True)
            thread.start()
            watch_threads.append(thread)
        for namespace, ready in self.watch_ready.items():
            if not ready.wait(60):
                self.add_error(f"watch did not start for {namespace}")
        if self.errors:
            return self.write_results()

        workers = []
        for _ in range(self.workers):
            thread = threading.Thread(target=self.create_worker, daemon=True)
            thread.start()
            workers.append(thread)

        self.start_mono_ns = time.monotonic_ns()
        self.start_wall_ns = time.time_ns()
        records = sorted(self.records.values(), key=lambda item: item["index"])
        for index, record in enumerate(records):
            planned_ns = self.start_mono_ns + (index * 1_000_000_000 // self.qps)
            now = time.monotonic_ns()
            if now < planned_ns:
                time.sleep((planned_ns - now) / 1_000_000_000)
            self.create_queue.put((record, planned_ns))
        for _ in workers:
            self.create_queue.put(None)
        self.create_queue.join()

        deadline = time.monotonic() + self.timeout
        while not self.done.is_set() and not self.errors and time.monotonic() < deadline:
            self.done.wait(1)
        if not self.done.is_set() and not self.errors:
            self.add_error(f"timed out after {self.timeout}s waiting for all Pods Ready")
        if self.done.is_set() and self.stable_seconds:
            deadline = time.monotonic() + self.stable_seconds
            while time.monotonic() < deadline and not self.errors:
                time.sleep(min(1, deadline - time.monotonic()))
                if any(item["readyLost"] or item["restartCount"] for item in self.records.values()):
                    self.add_error("Pod readiness regressed or a container restarted during stability window")
        self.stop.set()
        return self.write_results()


def main():
    summary = LoadRun().run()
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    sys.exit(main())
