#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
image=registry.k8s.io/e2e-test-images/agnhost@sha256:2c5b5b056076334e4cf431d964d102e44cbca8f1e6b16ac1e477a0ffbe6caac4
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.3-evidence/s3.3c-invalid-capability-baseline-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
pods=(cubesandbox-s33c-runc-invalid-cap cubesandbox-s33c-cube-invalid-cap)
pod_uids=()
baseline_captured=false

count_entries() {
  if test -d "$1"; then find "$1" -mindepth 1 -printf '.\n' | wc -l; else printf '0\n'; fi
}

active_leases() {
  local record count=0 rc
  while IFS= read -r record; do
    test -n "$record" || continue
    if jq -e '.active == null' "$record" >/dev/null; then :; else
      rc=$?
      test "$rc" -eq 1 || return 1
      count=$((count + 1))
    fi
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print)
  printf '%s\n' "$count"
}

shared_mounts() {
  findmnt -rn -o TARGET | awk -v root="$shared/" 'index($1, root) == 1 {n++} END {print n+0}'
}

capture_state() {
  local tag=$1
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt"
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt"
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt"
  { if test -d /var/run/netns; then find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n'; fi; } | sort >"$evidence/netns-$tag.txt"
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort >"$evidence/cube-shims-$tag.txt"
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P\t%y\n'; fi; } | sort >"$evidence/vm-runtime-$tag.txt"
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s\n' \
    "$(find "$runtime_state/adapter" -type f -printf '.\n' | wc -l)" \
    "$(count_entries "$shared")" "$(count_entries "$reaper")" \
    "$(find /run/containerd -name cube-runtime-resource.json -type f -printf '.\n' | wc -l)" \
    "$(shared_mounts)" "$(active_leases)" >"$evidence/runtime-resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime runtime-resources; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
}

is_owned() {
  test "$("${kube[@]}" get pod "$1" -o jsonpath='{.metadata.labels.cubesandbox\.io/s33c-diagnostic-owned}')" = true
}

record_uid() {
  local uid=$1 existing
  test -n "$uid" || return 1
  for existing in "${pod_uids[@]}"; do test "$existing" != "$uid" || return 0; done
  pod_uids+=("$uid")
}

collect_uids() {
  local pod json uid
  for pod in "${pods[@]}"; do
    json=$("${kube[@]}" get pod "$pod" --ignore-not-found -o json)
    test -n "$json" || continue
    test "$(jq -r '.metadata.labels["cubesandbox.io/s33c-diagnostic-owned"] // ""' <<<"$json")" = true || return 1
    uid=$(jq -er '.metadata.uid | strings | select(length > 0)' <<<"$json")
    record_uid "$uid"
  done
}

delete_owned() {
  local pod result
  for pod in "${pods[@]}"; do
    result=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name)
    test -n "$result" || continue
    test "$result" = "pod/$pod" && is_owned "$pod"
    "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null
  done
}

wait_cleanup() {
  local uid clean
  for _ in $(seq 1 1800); do
    clean=true
    for uid in "${pod_uids[@]}"; do
      if test -e "/var/lib/kubelet/pods/$uid" || test -L "/var/lib/kubelet/pods/$uid"; then clean=false; break; fi
    done
    if test "$clean" = true \
      && test "$(active_leases)" -eq 0 \
      && test "$(find "$runtime_state/adapter" -type f -printf '.\n' | wc -l)" -eq 0 \
      && test "$(count_entries "$shared")" -eq 0 \
      && test "$(count_entries "$reaper")" -eq 0 \
      && test "$(count_entries "$vm_runtime")" -eq 0 \
      && test "$(shared_mounts)" -eq 0; then
      capture_state cleanup
      state_matches_baseline cleanup && return 0
    fi
    sleep .1
  done
  return 1
}

collect_runtime_records() {
  local pod=$1 uid=$2 container_ids sandbox_ids id
  "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-$pod.json" 2>&1 || true
  "${kube[@]}" describe pod "$pod" >"$evidence/describe-$pod.txt" 2>&1 || true
  sandbox_ids=$("${cri[@]}" pods -o json | jq -r --arg uid "$uid" '.items[]? | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id')
  container_ids=$("${cri[@]}" ps -a -o json | jq -r --arg uid "$uid" '.containers[]? | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id')
  printf '%s\n' "$sandbox_ids" | awk 'NF' >"$evidence/sandboxes-$pod.txt"
  printf '%s\n' "$container_ids" | awk 'NF' >"$evidence/containers-$pod.txt"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-observed-$pod.txt"
  comm -12 \
    <(sort "$evidence/containers-$pod.txt") \
    "$evidence/tasks-observed-$pod.txt" >"$evidence/workload-running-tasks-$pod.txt"
  while IFS= read -r id; do
    test -n "$id" || continue
    "${cri[@]}" inspect "$id" >"$evidence/cri-$pod-$id.json" 2>&1 || true
    "${ctr[@]}" containers info "$id" >"$evidence/ctr-$pod-$id.json" 2>&1 || true
  done <"$evidence/containers-$pod.txt"
}

summarize_pod() {
  local pod=$1 uid=$2 phase reason message marker=false container_count sandbox_count running_task_count
  phase=$(jq -r '.status.phase // "missing"' "$evidence/pod-$pod.json")
  reason=$(jq -r '[.status.containerStatuses[]?.state.waiting.reason, .status.containerStatuses[]?.state.terminated.reason] | map(select(. != null)) | join(",")' "$evidence/pod-$pod.json")
  message=$(jq -r '[.status.containerStatuses[]?.state.waiting.message, .status.containerStatuses[]?.state.terminated.message] | map(select(. != null)) | join(" | ")' "$evidence/pod-$pod.json" | tr '\n\t' '  ')
  container_count=$(awk 'NF {n++} END {print n+0}' "$evidence/containers-$pod.txt")
  sandbox_count=$(awk 'NF {n++} END {print n+0}' "$evidence/sandboxes-$pod.txt")
  running_task_count=$(awk 'NF {n++} END {print n+0}' "$evidence/workload-running-tasks-$pod.txt")
  if test -f "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~empty-dir/evidence/marker"; then marker=true; fi
  printf 'pod=%s uid=%s phase=%s reason=%s marker=%s containers=%s sandboxes=%s running_workload_tasks=%s message=%s\n' \
    "$pod" "$uid" "$phase" "$reason" "$marker" "$container_count" "$sandbox_count" "$running_task_count" "$message" | tee -a "$evidence/summary.txt"
}

cleanup() {
  local original_rc=$? cleanup_rc=0
  set +e
  collect_uids || cleanup_rc=1
  "${cri[@]}" pods -o json >"$evidence/cri-pods-final.json" 2>&1 || true
  "${cri[@]}" ps -a -o json >"$evidence/cri-containers-final.json" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  delete_owned || cleanup_rc=1
  wait_cleanup || cleanup_rc=1
  printf 'original_rc=%s cleanup_rc=%s exact_baseline=%s active_leases=%s\n' \
    "$original_rc" "$cleanup_rc" "$([ "$cleanup_rc" -eq 0 ] && echo true || echo false)" "$(active_leases)" >"$evidence/cleanup-result.txt"
  if test "$original_rc" -ne 0; then exit "$original_rc"; fi
  exit "$cleanup_rc"
}

mkdir -p "$evidence"
chmod 0700 "$evidence"
trap cleanup EXIT

test "$(cat /proc/sys/kernel/cap_last_cap)" -ge 40
test "$(active_leases)" -eq 0
for pod in "${pods[@]}"; do test -z "$("${kube[@]}" get pod "$pod" --ignore-not-found -o name)"; done
"${cri[@]}" pull "$image" >"$evidence/image-pull.txt"
capture_state before
baseline_captured=true

for runtime in runc cube; do
  pod=cubesandbox-s33c-${runtime}-invalid-cap
  runtime_class=''
  if test "$runtime" = cube; then runtime_class='  runtimeClassName: cube'; fi
  "${kube[@]}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels:
    cubesandbox.io/s33c-diagnostic-owned: "true"
spec:
  nodeName: $node
$runtime_class
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", "printf started > /evidence/marker; sleep 600"]
    securityContext:
      capabilities:
        drop: ["ALL"]
        add: ["NOT_A_CAPABILITY"]
    volumeMounts:
    - name: evidence
      mountPath: /evidence
  volumes:
  - name: evidence
    emptyDir: {}
EOF
  uid=$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.uid}')
  record_uid "$uid"
done

sleep 45
for pod in "${pods[@]}"; do
  uid=$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.uid}')
  collect_runtime_records "$pod" "$uid"
  summarize_pod "$pod" "$uid"
done
runc_pod=cubesandbox-s33c-runc-invalid-cap
runc_uid=$("${kube[@]}" get pod "$runc_pod" -o jsonpath='{.metadata.uid}')
test -f "/var/lib/kubelet/pods/$runc_uid/volumes/kubernetes.io~empty-dir/evidence/marker"
test "$(jq -r '.status.phase' "$evidence/pod-$runc_pod.json")" = Running
test -s "$evidence/workload-running-tasks-$runc_pod.txt"
printf 'S33C_INVALID_RUNC_CONTROL_RUNNING pod=%s uid=%s running_workload_tasks=%s marker=true\n' \
  "$runc_pod" "$runc_uid" \
  "$(awk 'NF {n++} END {print n+0}' "$evidence/workload-running-tasks-$runc_pod.txt")" | tee -a "$evidence/summary.txt"
cube_pod=cubesandbox-s33c-cube-invalid-cap
cube_uid=$("${kube[@]}" get pod "$cube_pod" -o jsonpath='{.metadata.uid}')
test ! -f "/var/lib/kubelet/pods/$cube_uid/volumes/kubernetes.io~empty-dir/evidence/marker"
test "$(jq -r '.status.phase' "$evidence/pod-$cube_pod.json")" != Running
test ! -s "$evidence/workload-running-tasks-$cube_pod.txt"
jq -r '[.status.containerStatuses[]?.state.waiting.message, .status.containerStatuses[]?.state.terminated.message] | map(select(. != null)) | join(" | ")' \
  "$evidence/pod-$cube_pod.json" >"$evidence/cube-error.txt"
grep -q 'CAP_NOT_A_CAPABILITY' "$evidence/cube-error.txt"
grep -q 'invalid OCI Linux capability' "$evidence/cube-error.txt"
grep -q 'host Shim spec-validation' "$evidence/cube-error.txt"
printf 'S33C_INVALID_SHIM_FAIL_CLOSED pod=%s uid=%s running_workload_tasks=0 marker=false\n' \
  "$cube_pod" "$cube_uid" | tee -a "$evidence/summary.txt"
printf 'S33C_INVALID_DIAGNOSTIC_CAPTURED evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
