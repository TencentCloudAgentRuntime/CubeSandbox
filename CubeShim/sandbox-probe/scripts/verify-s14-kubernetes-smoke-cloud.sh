#!/bin/bash
set -Eeuo pipefail

kubeconfig=/etc/kubernetes/admin.conf
kube=(kubectl --kubeconfig "$kubeconfig")
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
label_yaml='cubesandbox.io/s14-owned: "true"'
label_selector='cubesandbox.io/s14-owned=true'
node=vm-200-2-ubuntu
expected_shim_sha=39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd
oci_spec_type_url=types.containerd.io/opencontainers/runtime-spec/1/Spec
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s1.4-evidence/smoke-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch="$(date +%s)"
resource_service_pid=

count_entries() {
  if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi
}

count_files() {
  if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi
}

active_leases() {
  local count=0 record
  while IFS= read -r record; do
    if ! jq -e '.active == null' "$record" >/dev/null; then
      count=$((count + 1))
    fi
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print 2>/dev/null)
  echo "$count"
}

lease_records() {
  find "$runtime_state/leases" -type f -name '*.json' 2>/dev/null | wc -l
}

capture_state() {
  local tag=$1
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt"
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt"
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt"
  find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n' 2>/dev/null \
    | sort >"$evidence/netns-$tag.txt"
  ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort \
    >"$evidence/cube-shims-$tag.txt"
  ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ && /cube-runtime-reaper/ {print}' | sort \
    >"$evidence/cube-reapers-$tag.txt"
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P %y\n' 2>/dev/null || true; fi; } \
    | sort >"$evidence/vm-runtime-$tag.txt"
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s lease_records=%s\n' \
    "$(count_files "$runtime_state/adapter")" "$(count_entries "$shared")" \
    "$(count_entries "$reaper")" \
    "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" \
    "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" \
    "$(active_leases)" "$(lease_records)" >"$evidence/resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1
  cmp -s "$evidence/containers-before.txt" "$evidence/containers-$tag.txt" \
    && cmp -s "$evidence/tasks-before.txt" "$evidence/tasks-$tag.txt" \
    && cmp -s "$evidence/sandboxes-before.txt" "$evidence/sandboxes-$tag.txt" \
    && cmp -s "$evidence/snapshots-before.txt" "$evidence/snapshots-$tag.txt" \
    && cmp -s "$evidence/netns-before.txt" "$evidence/netns-$tag.txt" \
    && cmp -s "$evidence/cube-shims-before.txt" "$evidence/cube-shims-$tag.txt" \
    && cmp -s "$evidence/cube-reapers-before.txt" "$evidence/cube-reapers-$tag.txt" \
    && cmp -s "$evidence/vm-runtime-before.txt" "$evidence/vm-runtime-$tag.txt" \
    && test "$(count_files "$runtime_state/adapter")" -eq 0 \
    && test "$(count_entries "$shared")" -eq 0 \
    && test "$(count_entries "$reaper")" -eq 0 \
    && test "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0 \
    && test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0 \
    && test "$(active_leases)" -eq 0
}

assert_baseline() {
  local name=$1 attempt tag="after-$1"
  for attempt in $(seq 1 900); do
    capture_state "$tag"
    if state_matches_baseline "$tag"; then
      printf 'BASELINE_OK case=%s wait_attempt=%s lease_records=%s\n' \
        "$name" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep 0.1
  done
  capture_state "$tag"
  for kind in containers tasks sandboxes snapshots netns cube-shims cube-reapers vm-runtime resources; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" \
      >"$evidence/$kind-$name.diff" 2>&1 || true
  done
  return 1
}

delete_owned() {
  "${kube[@]}" delete deployment -l "$label_selector" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  "${kube[@]}" delete job -l "$label_selector" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  "${kube[@]}" delete pod -l "$label_selector" --ignore-not-found --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
  for _ in $(seq 1 900); do
    if test -z "$("${kube[@]}" get pod,job,deployment -l "$label_selector" -o name 2>/dev/null)"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

save_diagnostics() {
  "${kube[@]}" get pod,job,deployment -A -l "$label_selector" -o wide \
    >"$evidence/owned-objects.txt" 2>&1 || true
  "${cri[@]}" pods >"$evidence/cri-pods.txt" 2>&1 || true
  "${cri[@]}" ps -a >"$evidence/cri-containers.txt" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
}

cleanup() {
  rc=$?
  set +e
  if test -n "$resource_service_pid"; then kill -CONT "$resource_service_pid" >/dev/null 2>&1 || true; fi
  save_diagnostics
  delete_owned
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

systemctl is-active --quiet containerd
systemctl is-active --quiet cubesandbox-s13-runtime-resource.service
test "$(sha256sum /usr/local/bin/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
test "$(sha256sum /opt/cubesandbox-s14-runtime-artifacts-sandbox-spec-v1/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
resource_service_pid="$(systemctl show -p MainPID --value cubesandbox-s13-runtime-resource.service)"
test "$resource_service_pid" -gt 1
"${kube[@]}" get --raw=/readyz | grep -Fxq ok
"${kube[@]}" get node "$node" -o json \
  | jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' >/dev/null
"${kube[@]}" get runtimeclass cube -o json | jq -e '.handler == "cube"' >/dev/null
"${cri[@]}" info >"$evidence/cri-info.json"
jq -e '.config.containerd.defaultRuntimeName == "runc"' "$evidence/cri-info.json" >/dev/null
jq -e '.config.containerd.runtimes.runc.runtimeType == "io.containerd.runc.v2"' "$evidence/cri-info.json" >/dev/null
jq -e '.config.containerd.runtimes.cube.runtimeType == "io.containerd.cube.rs" and .config.containerd.runtimes.cube.sandboxer == "shim"' "$evidence/cri-info.json" >/dev/null

delete_owned
capture_state before
test "$(active_leases)" -eq 0

# A Pod without runtimeClassName must stay on the configured default runc path.
"${kube[@]}" apply -f - >"$evidence/runc.apply" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s14-runc
  labels:
    $label_yaml
spec:
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
  - name: main
    image: docker.io/library/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "echo s14-runc-started; sleep 600"]
EOF
"${kube[@]}" wait --for=condition=Ready pod/cubesandbox-s14-runc --timeout=180s \
  >"$evidence/runc.wait"
runc_sid="$("${cri[@]}" pods --name cubesandbox-s14-runc -q | head -n1)"
test -n "$runc_sid"
"${ctr[@]}" sandboxes info "$runc_sid" >"$evidence/runc-sandbox.json"
jq -e '.Runtime.Name == "io.containerd.runc.v2" and .Sandboxer == "podsandbox"' \
  "$evidence/runc-sandbox.json" >/dev/null
ps -eo args= >"$evidence/runc-processes.txt"
awk -v id="$runc_sid" '$1 ~ /(^|\/)containerd-shim-runc-v2$/ && index($0,id) {found=1} END {exit !found}' \
  "$evidence/runc-processes.txt"
awk -v id="$runc_sid" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {found=1} END {exit found}' \
  "$evidence/runc-processes.txt"
"${kube[@]}" delete pod cubesandbox-s14-runc --grace-period=0 --force --wait=true \
  >"$evidence/runc.delete"
assert_baseline runc
printf 'S14_RUNC_DEFAULT_OK sandbox=%s runtime=io.containerd.runc.v2\n' "$runc_sid" \
  | tee -a "$evidence/summary.txt"

# Job proves the naturally exiting CRI/container lifecycle.
"${kube[@]}" apply -f - >"$evidence/job.apply" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: cubesandbox-s14-job
  labels:
    $label_yaml
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        $label_yaml
    spec:
      runtimeClassName: cube
      nodeName: $node
      automountServiceAccountToken: false
      restartPolicy: Never
      containers:
      - name: main
        image: docker.io/library/busybox:1.36.1
        imagePullPolicy: IfNotPresent
        command: ["sh", "-c", "echo s14-job-complete"]
EOF
"${kube[@]}" wait --for=condition=Complete job/cubesandbox-s14-job --timeout=240s \
  >"$evidence/job.wait"
job_pod="$("${kube[@]}" get pod -l job-name=cubesandbox-s14-job -o jsonpath='{.items[0].metadata.name}')"
job_sid="$("${cri[@]}" pods --name "$job_pod" -q | head -n1)"
test -n "$job_sid"
"${ctr[@]}" sandboxes info "$job_sid" >"$evidence/job-sandbox.json"
jq -e --arg type "$oci_spec_type_url" \
  '.Runtime.Name == "io.containerd.cube.rs" and .Sandboxer == "shim" and .Spec.type_url == $type' \
  "$evidence/job-sandbox.json" >/dev/null
jq -r '.Spec.value' "$evidence/job-sandbox.json" | base64 -d >"$evidence/job-oci-spec.json"
jq -e --arg name "$job_pod" \
  '.ociVersion != "" and .annotations["io.kubernetes.cri.sandbox-name"] == $name' \
  "$evidence/job-oci-spec.json" >/dev/null
"${cri[@]}" inspectp "$job_sid" >"$evidence/job-cri-inspect.json"
"${kube[@]}" logs job/cubesandbox-s14-job >"$evidence/job.log"
grep -Fxq s14-job-complete "$evidence/job.log"
"${kube[@]}" delete job cubesandbox-s14-job --wait=true >"$evidence/job.delete"
assert_baseline job
printf 'S14_JOB_OK completion=success logs=ok\n' | tee -a "$evidence/summary.txt"

# Deployment proves controller-owned Running Pod creation and deletion.
"${kube[@]}" apply -f - >"$evidence/deployment.apply" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cubesandbox-s14-deployment
  labels:
    $label_yaml
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cubesandbox-s14-deployment
  template:
    metadata:
      labels:
        app: cubesandbox-s14-deployment
        $label_yaml
    spec:
      runtimeClassName: cube
      nodeName: $node
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 1
      containers:
      - name: main
        image: docker.io/library/busybox:1.36.1
        imagePullPolicy: IfNotPresent
        command: ["sh", "-c", "echo s14-deployment-started; sleep 600"]
EOF
"${kube[@]}" wait --for=condition=Available deployment/cubesandbox-s14-deployment --timeout=240s \
  >"$evidence/deployment.wait"
deployment_pod="$("${kube[@]}" get pod -l app=cubesandbox-s14-deployment -o jsonpath='{.items[0].metadata.name}')"
test -n "$deployment_pod"
"${kube[@]}" logs "$deployment_pod" >"$evidence/deployment.log"
grep -Fxq s14-deployment-started "$evidence/deployment.log"
"${kube[@]}" exec "$deployment_pod" -- sh -c 'printf s14-deployment-exec' \
  >"$evidence/deployment.exec"
grep -Fxq s14-deployment-exec "$evidence/deployment.exec"
"${kube[@]}" delete deployment cubesandbox-s14-deployment --wait=true \
  >"$evidence/deployment.delete"
for _ in $(seq 1 900); do
  test -z "$("${kube[@]}" get pod -l app=cubesandbox-s14-deployment -o name 2>/dev/null)" && break
  sleep 0.1
done
test -z "$("${kube[@]}" get pod -l app=cubesandbox-s14-deployment -o name 2>/dev/null)"
assert_baseline deployment
printf 'S14_DEPLOYMENT_OK replicas=1 logs=ok exec=ok\n' | tee -a "$evidence/summary.txt"

# Force deletion bypasses the normal Pod grace period.
"${kube[@]}" apply -f - >"$evidence/force.apply" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s14-force
  labels:
    $label_yaml
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 30
  containers:
  - name: main
    image: docker.io/library/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "trap '' TERM; echo s14-force-started; sleep 600"]
EOF
"${kube[@]}" wait --for=condition=Ready pod/cubesandbox-s14-force --timeout=180s \
  >"$evidence/force.wait"
force_start_ms="$(date +%s%3N)"
"${kube[@]}" delete pod cubesandbox-s14-force --grace-period=0 --force --wait=true \
  >"$evidence/force.delete"
force_ms=$(( $(date +%s%3N) - force_start_ms ))
printf '%s\n' "$force_ms" >"$evidence/force-delete-ms"
test "$force_ms" -lt 15000
assert_baseline force
printf 'S14_FORCE_DELETE_OK elapsed_ms=%s\n' "$force_ms" | tee -a "$evidence/summary.txt"

# Suspend the PoC RuntimeResource endpoint so RunPodSandbox deterministically
# remains in controller Create, then delete the Kubernetes Pod and resume the
# endpoint. This exercises kubelet cancellation without a timing race.
cancel_name=cubesandbox-s14-cancel
kill -STOP "$resource_service_pid"
"${kube[@]}" apply -f - >"$evidence/cancel.apply" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $cancel_name
  labels:
    $label_yaml
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
  - name: main
    image: docker.io/library/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "sleep 600"]
EOF
cancel_sid=
cancel_state=CONTROLLER_CREATE_INFLIGHT
for _ in $(seq 1 3000); do
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort \
    >"$evidence/sandboxes-cancel-inflight.txt"
  cancel_sid="$(comm -13 "$evidence/sandboxes-before.txt" "$evidence/sandboxes-cancel-inflight.txt" | head -n1)"
  test -n "$cancel_sid" && break
  sleep 0.01
done
test -n "$cancel_sid"
if inspect_json="$("${cri[@]}" inspectp "$cancel_sid" 2>/dev/null)"; then
  cancel_state="$(jq -r '.status.state // "CONTROLLER_CREATE_INFLIGHT"' <<<"$inspect_json")"
fi
test "$cancel_state" != SANDBOX_READY
"${kube[@]}" delete pod "$cancel_name" --grace-period=0 --force --wait=true \
  >"$evidence/cancel.delete"
kill -CONT "$resource_service_pid"
assert_baseline cancel
printf 'S14_CREATE_CANCEL_OK sandbox=%s observed_state=%s fault=runtime-resource-stop-cont\n' \
  "$cancel_sid" "$cancel_state" | tee -a "$evidence/summary.txt"

save_diagnostics
warning_count="$(grep -Fc 'failed to unmarshal sandbox spec' "$evidence/containerd.journal" || true)"
test "$warning_count" -eq 0
printf 'S14_SMOKE_MATRIX_OK evidence=%s active_leases=0 lease_records=%s vm_runtime=baseline sandbox_spec=ok warnings=0 shim_sha256=%s\n' \
  "$evidence" "$(lease_records)" "$expected_shim_sha" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
