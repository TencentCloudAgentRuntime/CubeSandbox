#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
pod=cubesandbox-s21-multicontainer
node=vm-200-2-ubuntu
expected_shim_sha=39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s2.1-evidence/multicontainer-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch="$(date +%s)"

count_entries() {
  if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi
}

count_files() {
  if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi
}

active_leases() {
  local count=0 record
  while IFS= read -r record; do
    if ! jq -e '.active == null' "$record" >/dev/null; then count=$((count + 1)); fi
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
  local attempt tag=after
  for attempt in $(seq 1 1200); do
    capture_state "$tag"
    if state_matches_baseline "$tag"; then
      printf 'S21_BASELINE_CLEAN wait_attempt=%s lease_records=%s\n' \
        "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep 0.1
  done
  capture_state "$tag"
  for kind in containers tasks sandboxes snapshots netns cube-shims cube-reapers vm-runtime resources; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" \
      >"$evidence/$kind.diff" 2>&1 || true
  done
  return 1
}

delete_owned() {
  if "${kube[@]}" get pod "$pod" >/dev/null 2>&1; then
    test "$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.labels.cubesandbox\.io/s21-owned}')" = true \
      || { printf 'refusing to delete non-owned pod %s\n' "$pod" >&2; return 1; }
    "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null
  fi
  for _ in $(seq 1 1200); do
    if ! "${kube[@]}" get pod "$pod" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  return 1
}

wait_runtime_idle() {
  for _ in $(seq 1 1200); do
    if test "$(count_files "$runtime_state/adapter")" -eq 0 \
      && test "$(count_entries "$shared")" -eq 0 \
      && test "$(count_entries "$reaper")" -eq 0 \
      && test "$(count_entries "$vm_runtime")" -eq 0 \
      && test "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0 \
      && test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0 \
      && test "$(active_leases)" -eq 0 \
      && ! ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {found=1} END {exit !found}'; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

save_diagnostics() {
  "${kube[@]}" get pod "$pod" -o wide >"$evidence/pod-final.txt" 2>&1 || true
  "${cri[@]}" pods >"$evidence/cri-pods.txt" 2>&1 || true
  "${cri[@]}" ps -a >"$evidence/cri-containers.txt" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
}

cleanup() {
  rc=$?
  set +e
  save_diagnostics
  delete_owned
  wait_runtime_idle
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

systemctl is-active --quiet containerd
systemctl is-active --quiet cubesandbox-s13-runtime-resource.service
test "$(sha256sum /usr/local/bin/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
test "$(sha256sum /opt/cubesandbox-s14-runtime-artifacts-sandbox-spec-v1/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
"${kube[@]}" get --raw=/readyz | grep -Fxq ok
"${kube[@]}" get node "$node" -o json \
  | jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' >/dev/null
delete_owned
wait_runtime_idle
capture_state before
test "$(active_leases)" -eq 0
leases_before="$(lease_records)"

"${kube[@]}" apply -f - >"$evidence/apply.txt" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels:
    cubesandbox.io/s21-owned: "true"
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 2
  containers:
  - name: alpha
    image: docker.io/library/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "echo alpha-started; sleep 600"]
  - name: beta
    image: docker.io/library/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "echo beta-started; sleep 600"]
EOF
"${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=300s >"$evidence/wait.txt"
"${kube[@]}" get pod "$pod" -o json >"$evidence/pod-ready.json"
pod_ip="$(jq -r '.status.podIP' "$evidence/pod-ready.json")"
pod_uid="$(jq -r '.metadata.uid' "$evidence/pod-ready.json")"
test -n "$pod_ip"
test "$pod_ip" != null
test -n "$pod_uid"
test "$pod_uid" != null
"${kube[@]}" logs "$pod" -c alpha >"$evidence/alpha.log"
"${kube[@]}" logs "$pod" -c beta >"$evidence/beta.log"
grep -Fxq alpha-started "$evidence/alpha.log"
grep -Fxq beta-started "$evidence/beta.log"
"${kube[@]}" exec "$pod" -c alpha -- sh -c 'printf alpha-exec' >"$evidence/alpha.exec"
"${kube[@]}" exec "$pod" -c beta -- sh -c 'printf beta-exec' >"$evidence/beta.exec"
grep -Fxq alpha-exec "$evidence/alpha.exec"
grep -Fxq beta-exec "$evidence/beta.exec"

"${cri[@]}" pods -o json >"$evidence/cri-pods-running.json"
jq -r --arg uid "$pod_uid" \
  '.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id' \
  "$evidence/cri-pods-running.json" >"$evidence/sandbox-ids.txt"
test "$(wc -l <"$evidence/sandbox-ids.txt")" -eq 1
sandbox_id="$(cat "$evidence/sandbox-ids.txt")"
test -n "$sandbox_id"
"${cri[@]}" ps -o json >"$evidence/cri-running.json"
jq -r --arg uid "$pod_uid" \
  '.containers[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | [.metadata.name,.id,.state,.podSandboxId] | @tsv' \
  "$evidence/cri-running.json" | sort >"$evidence/containers-running.tsv"
test "$(wc -l <"$evidence/containers-running.tsv")" -eq 2
awk -v sid="$sandbox_id" '$3 != "CONTAINER_RUNNING" || $4 != sid {exit 1}' \
  "$evidence/containers-running.tsv"
alpha_id="$(awk '$1 == "alpha" {print $2}' "$evidence/containers-running.tsv")"
beta_id="$(awk '$1 == "beta" {print $2}' "$evidence/containers-running.tsv")"
test -n "$alpha_id"
test -n "$beta_id"
grep -Fxq "$alpha_id" < <("${ctr[@]}" tasks list -q)
grep -Fxq "$beta_id" < <("${ctr[@]}" tasks list -q)
test -d "$vm_runtime/$sandbox_id"
test "$(ps -eo args= | awk -v id="$sandbox_id" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {count++} END {print count+0}')" -eq 1
shim_pid="$(ps -eo pid=,args= | awk -v id="$sandbox_id" '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {print $1}')"
test -n "$shim_pid"
test "$(count_files "$runtime_state/adapter")" -eq 1
test "$(find "$shared" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1
sandbox_shared="$(find "$shared" -mindepth 1 -maxdepth 1 -type d -print -quit)"
test -n "$sandbox_shared"
rootfs_dir="$sandbox_shared/rootfs"
test -d "$rootfs_dir"
test "$(find "$rootfs_dir" -mindepth 1 -maxdepth 1 -type d -name "$alpha_id-*" | wc -l)" -eq 1
test "$(find "$rootfs_dir" -mindepth 1 -maxdepth 1 -type d -name "$beta_id-*" | wc -l)" -eq 1
printf 'S21_TWO_RUNNING_OK sandbox=%s pod_ip=%s alpha=%s beta=%s shared_root=%s shim_count=1\n' \
  "$sandbox_id" "$pod_ip" "$alpha_id" "$beta_id" "$(basename "$sandbox_shared")" \
  | tee -a "$evidence/summary.txt"

"${cri[@]}" stop --timeout 10 "$alpha_id" >"$evidence/alpha.stop"
for _ in $(seq 1 300); do
  "${cri[@]}" inspect "$alpha_id" >"$evidence/alpha-stopped.json"
  alpha_state="$(jq -r '.status.state' "$evidence/alpha-stopped.json")"
  test "$alpha_state" = CONTAINER_EXITED && break
  sleep 0.1
done
test "$alpha_state" = CONTAINER_EXITED
alpha_exit="$(jq -r '.status.exitCode' "$evidence/alpha-stopped.json")"
test "$alpha_exit" -eq 137
"${cri[@]}" inspect "$beta_id" | jq -e '.status.state == "CONTAINER_RUNNING"' >/dev/null
"${kube[@]}" exec "$pod" -c beta -- sh -c 'printf beta-survived-alpha-stop' >"$evidence/beta-after-stop.exec"
grep -Fxq beta-survived-alpha-stop "$evidence/beta-after-stop.exec"
test -d "$vm_runtime/$sandbox_id"
test "$("${kube[@]}" get pod "$pod" -o jsonpath='{.status.podIP}')" = "$pod_ip"

"${cri[@]}" rm "$alpha_id" >"$evidence/alpha.rm"
for _ in $(seq 1 300); do
  if ! "${cri[@]}" inspect "$alpha_id" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
! "${cri[@]}" inspect "$alpha_id" >/dev/null 2>&1
replacement_alpha_id=
for _ in $(seq 1 600); do
  "${cri[@]}" ps -o json >"$evidence/cri-after-alpha-delete.json"
  replacement_alpha_id="$(jq -r --arg uid "$pod_uid" --arg old "$alpha_id" \
    '.containers[] | select(.labels["io.kubernetes.pod.uid"] == $uid and .metadata.name == "alpha" and .id != $old and .state == "CONTAINER_RUNNING") | .id' \
    "$evidence/cri-after-alpha-delete.json" | head -n1)"
  test -n "$replacement_alpha_id" && break
  sleep 0.1
done
test -n "$replacement_alpha_id"
test "$replacement_alpha_id" != "$alpha_id"
! grep -Fxq "$alpha_id" < <("${ctr[@]}" tasks list -q)
"${cri[@]}" ps -o json >"$evidence/cri-after-replacement.json"
jq -r --arg uid "$pod_uid" \
  '.containers[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | [.metadata.name,.id,.state,.podSandboxId] | @tsv' \
  "$evidence/cri-after-replacement.json" | sort >"$evidence/containers-after-replacement.tsv"
test "$(wc -l <"$evidence/containers-after-replacement.tsv")" -eq 2
awk -v sid="$sandbox_id" '$3 != "CONTAINER_RUNNING" || $4 != sid {exit 1}' \
  "$evidence/containers-after-replacement.tsv"
test "$(awk '$1 == "alpha" {print $2}' "$evidence/containers-after-replacement.tsv")" = "$replacement_alpha_id"
test "$(awk '$1 == "beta" {print $2}' "$evidence/containers-after-replacement.tsv")" = "$beta_id"
"${cri[@]}" inspect "$beta_id" | jq -e '.status.state == "CONTAINER_RUNNING"' >/dev/null
grep -Fxq "$beta_id" < <("${ctr[@]}" tasks list -q)
grep -Fxq "$replacement_alpha_id" < <("${ctr[@]}" tasks list -q)
"${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=120s >"$evidence/wait-after-replacement.txt"
"${kube[@]}" get pod "$pod" -o json >"$evidence/pod-after-replacement.json"
test "$(jq -r '.metadata.uid' "$evidence/pod-after-replacement.json")" = "$pod_uid"
jq -r '.status.containerStatuses[] | [.name, (.containerID | sub("^containerd://"; "")), (.ready | tostring), ((.state.running != null) | tostring)] | @tsv' \
  "$evidence/pod-after-replacement.json" | sort >"$evidence/container-statuses-after-replacement.tsv"
test "$(wc -l <"$evidence/container-statuses-after-replacement.tsv")" -eq 2
awk '$3 != "true" || $4 != "true" {exit 1}' "$evidence/container-statuses-after-replacement.tsv"
test "$(awk '$1 == "alpha" {print $2}' "$evidence/container-statuses-after-replacement.tsv")" = "$replacement_alpha_id"
test "$(awk '$1 == "beta" {print $2}' "$evidence/container-statuses-after-replacement.tsv")" = "$beta_id"
"${kube[@]}" logs "$pod" -c alpha >"$evidence/alpha-replacement.log"
grep -Fxq alpha-started "$evidence/alpha-replacement.log"
"${kube[@]}" exec "$pod" -c beta -- sh -c 'printf beta-survived-alpha-delete' >"$evidence/beta-after-delete.exec"
grep -Fxq beta-survived-alpha-delete "$evidence/beta-after-delete.exec"
test -d "$vm_runtime/$sandbox_id"
test "$("${kube[@]}" get pod "$pod" -o jsonpath='{.status.podIP}')" = "$pod_ip"
"${cri[@]}" pods -o json >"$evidence/cri-pods-after-replacement.json"
test "$(jq -r --arg uid "$pod_uid" '.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id' "$evidence/cri-pods-after-replacement.json")" = "$sandbox_id"
test "$(ps -eo args= | awk -v id="$sandbox_id" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {count++} END {print count+0}')" -eq 1
test "$(ps -eo pid=,args= | awk -v id="$sandbox_id" '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {print $1}')" = "$shim_pid"
test "$(find "$rootfs_dir" -mindepth 1 -maxdepth 1 -type d -name "$alpha_id-*" 2>/dev/null | wc -l)" -eq 0
test "$(find "$rootfs_dir" -mindepth 1 -maxdepth 1 -type d -name "$replacement_alpha_id-*" | wc -l)" -eq 1
test "$(find "$rootfs_dir" -mindepth 1 -maxdepth 1 -type d -name "$beta_id-*" | wc -l)" -eq 1
printf 'S21_ONE_DELETE_ISOLATED_OK sandbox=%s pod_ip=%s deleted=%s replacement=%s survivor=%s alpha_exit=%s\n' \
  "$sandbox_id" "$pod_ip" "$alpha_id" "$replacement_alpha_id" "$beta_id" "$alpha_exit" \
  | tee -a "$evidence/summary.txt"

"${kube[@]}" delete pod "$pod" --wait=true >"$evidence/delete.txt"
assert_baseline
leases_after="$(lease_records)"
test $((leases_after - leases_before)) -eq 1
save_diagnostics
printf 'S21_MULTICONTAINER_OK sandbox=%s pod_ip=%s containers=2 isolated_delete=ok active_leases=0 durable_tombstone_delta=1 vm_runtime=baseline shim_sha256=%s evidence=%s\n' \
  "$sandbox_id" "$pod_ip" "$expected_shim_sha" "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
