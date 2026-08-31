#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cleanup_kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=2s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
s31b=/opt/cubesandbox-s31d/verify-s31b-writable-volumes-cloud.sh
s31c=/opt/cubesandbox-s31d/verify-s31c-projected-volumes-cloud.sh
s31b_sha=1133a645267a37c479dc37d5e729e84f76fcdb3b7d63ed2fd6b173c058d2972e
s31c_sha=a31fdce8c89bc15705a87c2fd4064ca54abddc68b2e22d0f8d41f87599da4bb7
shim_sha=4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14
harness=/opt/cubesandbox-s31b-runtime-artifacts-d7387f29-v1/s11-live-runtime-harness
harness_sha=7a525e8541eb774e6f80788819873c7c80fdf812eeb5b1f9d99fed20dcaf8b82
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.1-evidence/s3.1d-regression-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)

count_entries() { if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi; }
count_files() { if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi; }
active_leases() {
  local count=0 record
  while IFS= read -r record; do
    jq -e '.active == null' "$record" >/dev/null || count=$((count + 1))
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print 2>/dev/null)
  echo "$count"
}
lease_records() { find "$runtime_state/leases" -type f -name '*.json' 2>/dev/null | wc -l; }

capture_state() {
  local tag=$1
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt"
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt"
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt"
  find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n' 2>/dev/null | sort >"$evidence/netns-$tag.txt"
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort >"$evidence/cube-shims-$tag.txt"
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P %y\n' 2>/dev/null || true; fi; } | sort >"$evidence/vm-runtime-$tag.txt"
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s\n' \
    "$(count_files "$runtime_state/adapter")" "$(count_entries "$shared")" "$(count_entries "$reaper")" \
    "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" \
    "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" "$(active_leases)" \
    >"$evidence/resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime resources; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
}

wait_runtime_idle() {
  local attempt
  for attempt in $(seq 1 1200); do
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
    sleep .1
  done
  return 1
}

assert_baseline() {
  local tag=$1 attempt kind
  for attempt in $(seq 1 1200); do
    capture_state "$tag"
    if state_matches_baseline "$tag"; then
      printf 'S31D_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
        "$tag" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep .1
  done
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime resources; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" >"$evidence/$kind-$tag.diff" 2>&1 || true
  done
  return 1
}

latest_evidence() {
  local pattern=$1
  find /data/cubelet/s3.1-evidence -mindepth 1 -maxdepth 1 -type d -name "$pattern" -printf '%T@ %p\n' \
    | sort -n | tail -n 1 | cut -d' ' -f2-
}

run_component() {
  local name=$1 script=$2 pattern=$3 active_limit=$4 wall_limit=$5 previous current rc
  previous=$(latest_evidence "$pattern" || true)
  set +e
  # The 30-second TERM cleanup grace is included in the advertised wall-clock
  # deadline: 870+30=900 for S3.1b and 570+30=600 for S3.1c.
  timeout --signal=TERM --kill-after=30s "$active_limit" "$script" >"$evidence/$name.log" 2>&1
  rc=$?
  set -e
  printf '%s\t%s\t%s\n' "$name" "$rc" "$wall_limit" >>"$evidence/component-exit-codes.tsv"
  test "$rc" -eq 0
  current=$(latest_evidence "$pattern")
  test -n "$current" && test "$current" != "$previous"
  test ! -s "$current/trace.log"
  printf '%s\t%s\n' "$name" "$current" >>"$evidence/component-evidence.tsv"
  printf '%s\n' "$current"
}

delete_if_owned() {
  local kind=$1 name=$2 label=$3 object
  if ! object=$("${cleanup_kube[@]}" get "$kind" "$name" -o json 2>&1); then
    grep -F '(NotFound)' <<<"$object" >/dev/null
    return $?
  fi
  if test "$(jq -r --arg label "$label" '.metadata.labels[$label] // ""' <<<"$object")" = true; then
    "${cleanup_kube[@]}" delete "$kind" "$name" --grace-period=0 --force --wait=false --timeout=10s >/dev/null 2>&1
  fi
}

fixed_objects_absent() {
  local target kind name output
  for target in \
    pod/cubesandbox-s31b-volume \
    pod/cubesandbox-s31b-volume-failure \
    pod/cubesandbox-s31c-runc \
    pod/cubesandbox-s31c-cube \
    configmap/cubesandbox-s31c-config \
    secret/cubesandbox-s31c-secret; do
    kind=${target%%/*}
    name=${target#*/}
    if output=$("${cleanup_kube[@]}" get "$kind" "$name" -o name 2>&1); then return 1; fi
    grep -F '(NotFound)' <<<"$output" >/dev/null || return 1
  done
}

wait_fixed_objects_absent() {
  local deadline=$((SECONDS + 180))
  while test "$SECONDS" -lt "$deadline"; do
    if fixed_objects_absent; then return 0; fi
    sleep 1
  done
  fixed_objects_absent
}

cleanup() {
  local rc=$? cleanup_rc=0 objects_absent=false runtime_idle=false
  trap - ERR EXIT
  set +e
  delete_if_owned pod cubesandbox-s31b-volume 'cubesandbox.io/s31b-owned' || cleanup_rc=1
  delete_if_owned pod cubesandbox-s31b-volume-failure 'cubesandbox.io/s31b-owned' || cleanup_rc=1
  delete_if_owned pod cubesandbox-s31c-runc 'cubesandbox.io/s31c-owned' || cleanup_rc=1
  delete_if_owned pod cubesandbox-s31c-cube 'cubesandbox.io/s31c-owned' || cleanup_rc=1
  delete_if_owned configmap cubesandbox-s31c-config 'cubesandbox.io/s31c-owned' || cleanup_rc=1
  delete_if_owned secret cubesandbox-s31c-secret 'cubesandbox.io/s31c-owned' || cleanup_rc=1
  if wait_fixed_objects_absent; then objects_absent=true; else cleanup_rc=1; fi
  if wait_runtime_idle; then runtime_idle=true; else cleanup_rc=1; fi
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  printf 'cleanup_rc=%s fixed_objects_absent=%s runtime_idle=%s\n' \
    "$cleanup_rc" "$objects_absent" "$runtime_idle" \
    >"$evidence/cleanup-result.txt"
  if test "$cleanup_rc" -ne 0 && test "$rc" -eq 0; then rc=1; fi
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

test "$(sha256sum "$s31b" | awk '{print $1}')" = "$s31b_sha"
test "$(sha256sum "$s31c" | awk '{print $1}')" = "$s31c_sha"
test "$(sha256sum /usr/local/bin/containerd-shim-cube-rs | awk '{print $1}')" = "$shim_sha"
test "$(sha256sum "$harness" | awk '{print $1}')" = "$harness_sha"
bash -n "$s31b"
bash -n "$s31c"
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False
"${kube[@]}" get node "$node" -o json >"$evidence/node-before.json"
jq -r '[.metadata.uid,.status.nodeInfo.kubeletVersion,([.status.addresses[] | select(.type == "InternalIP") | .address] | sort | join(","))] | @tsv' \
  "$evidence/node-before.json" >"$evidence/node-identity-before.tsv"
df -P / >"$evidence/root-disk-before.txt"

wait_runtime_idle
capture_state before
leases_before=$(lease_records)

s31b_evidence=$(run_component s31b "$s31b" 's3.1b-writable-*' 870s 900s)
grep -F 'S31B_RW_OK ' "$s31b_evidence/summary.txt" >/dev/null
grep -F 'S31B_FAILED_TASK_CLEAN ' "$s31b_evidence/summary.txt" >/dev/null
grep -F 'S31B_FAILURE_CLEANUP_OK ' "$s31b_evidence/summary.txt" >/dev/null
grep -F 'durable_tombstone_delta=2' "$s31b_evidence/summary.txt" >/dev/null

s31c_evidence=$(run_component s31c "$s31c" 's3.1c-projected-*' 570s 600s)
grep -F 'S31C_PROJECTED_OK ' "$s31c_evidence/summary.txt" >/dev/null
grep -F 'pod_uid_ip=stable' "$s31c_evidence/summary.txt" >/dev/null
grep -F 'host_mount_ids=stable' "$s31c_evidence/summary.txt" >/dev/null
grep -F 'S31C_DONE active_leases=0 durable_tombstone_delta=1 kubelet_pod_dirs=removed' "$s31c_evidence/summary.txt" >/dev/null

assert_baseline after
fixed_objects_absent
test $(( $(lease_records) - leases_before )) -eq 3
"${kube[@]}" get node "$node" -o json >"$evidence/node-after.json"
jq -r '[.metadata.uid,.status.nodeInfo.kubeletVersion,([.status.addresses[] | select(.type == "InternalIP") | .address] | sort | join(","))] | @tsv' \
  "$evidence/node-after.json" >"$evidence/node-identity-after.tsv"
cmp "$evidence/node-identity-before.tsv" "$evidence/node-identity-after.tsv"
test "$(jq -r '.status.conditions[] | select(.type == "Ready") | .status' "$evidence/node-after.json")" = True
test "$(jq -r '.status.conditions[] | select(.type == "DiskPressure") | .status' "$evidence/node-after.json")" = False
df -P / >"$evidence/root-disk-after.txt"
root_use=$(awk 'NR == 2 {gsub(/%/, "", $5); print $5}' "$evidence/root-disk-after.txt")
test "$root_use" -lt 80

printf 'capability\tstatus\tsemantics\tevidence\n' >"$evidence/support-matrix.tsv"
printf 'emptyDir-disk\tSUPPORTED\trw; init/native-sidecar/app share\t%s\n' "$s31b_evidence" >>"$evidence/support-matrix.tsv"
printf 'emptyDir-memory\tSUPPORTED\trw; init/native-sidecar/app share\t%s\n' "$s31b_evidence" >>"$evidence/support-matrix.tsv"
printf 'same-source-ro-rw\tSUPPORTED\tper OCI mount ro/rw preserved\t%s\n' "$s31b_evidence" >>"$evidence/support-matrix.tsv"
printf 'read-only-rootfs\tSUPPORTED\trootfs remains ro while volume share is writable\t%s\n' "$s31b_evidence" >>"$evidence/support-matrix.tsv"
printf 'ConfigMap\tSUPPORTED\tstartup mode and atomic-writer dynamic update\t%s\n' "$s31c_evidence" >>"$evidence/support-matrix.tsv"
printf 'Secret\tSUPPORTED\tstartup mode and atomic-writer dynamic update\t%s\n' "$s31c_evidence" >>"$evidence/support-matrix.tsv"
printf 'projected\tSUPPORTED\tConfigMap Secret downwardAPI sources update atomically\t%s\n' "$s31c_evidence" >>"$evidence/support-matrix.tsv"
printf 'downwardAPI\tSUPPORTED\tstartup fields and label update\t%s\n' "$s31c_evidence" >>"$evidence/support-matrix.tsv"
printf 'subPath-file\tSUPPORTED_STATIC\tvalue and inode fixed after Pod start\t%s\n' "$s31c_evidence" >>"$evidence/support-matrix.tsv"
printf 'failed-CreateTask-rollback\tSUPPORTED\tTask generation and mounts removed while VM survives\t%s\n' "$s31b_evidence" >>"$evidence/support-matrix.tsv"
printf 'filesystem-PVC\tDEFERRED_S3.2\tnot claimed by S3.1\t-\n' >>"$evidence/support-matrix.tsv"
printf 'hostPath-file-directory\tNOT_VALIDATED\tnot claimed by S3.1\t-\n' >>"$evidence/support-matrix.tsv"
printf 'device-hostPath\tOUT_OF_SCOPE\tonly failure cleanup is validated\t%s\n' "$s31b_evidence" >>"$evidence/support-matrix.tsv"
printf 'raw-block-mountPropagation\tOUT_OF_SCOPE\tnot claimed by PoC first version\t-\n' >>"$evidence/support-matrix.tsv"

printf 'S31D_REGRESSION_OK s31b=%s s31c=%s pod_uid_ip=stable sandbox_shim_vm=stable global_baseline=stable durable_tombstone_delta=3 node_ready=true disk_pressure=false root_use=%s%%\n' \
  "$s31b_evidence" "$s31c_evidence" "$root_use" | tee -a "$evidence/summary.txt"
printf 'S31D_DONE support_matrix=%s evidence=%s\n' "$evidence/support-matrix.tsv" "$evidence" | tee -a "$evidence/summary.txt"
journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1
journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1
trap - ERR EXIT
