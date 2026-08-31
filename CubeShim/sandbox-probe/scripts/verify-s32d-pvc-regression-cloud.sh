#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cleanup_kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=2s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
s32a=/opt/cubesandbox-s32d/diagnose-s32a-pvc-cloud.sh
s32b=/opt/cubesandbox-s32d/verify-s32b-rwo-persistence-cloud.sh
s32c=/opt/cubesandbox-s32d/verify-s32c-pvc-reclaim-cloud.sh
s32a_sha=e78947213a2464d956a7427e0d3e4249314c8d0680412162bf06fb3ca14e5269
s32b_sha=17ff8e9db7bf3922acc45245deb4dad2e574018ba7c0a68b204659b73be5b616
s32c_sha=9c2bd640164dc1fd3cc8e7522d448ff67f60b8796f9484ca6963fe3e0065f1ee
shim=/usr/local/bin/containerd-shim-cube-rs
shim_sha=4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14
harness=/opt/cubesandbox-s31b-runtime-artifacts-d7387f29-v1/s11-live-runtime-harness
harness_sha=7a525e8541eb774e6f80788819873c7c80fdf812eeb5b1f9d99fed20dcaf8b82
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
pv_parent=/data/cubelet/s3.2-pv
s32a_path=$pv_parent/s32a-local
s32b_path=$pv_parent/s32b-local
s32c_path=$pv_parent/s32c-local
component_evidence_root=/data/cubelet/s3.2-evidence
evidence=$component_evidence_root/s3.2d-regression-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
pv_parent_state_captured=false
pv_parent_existed_before=false
local_paths_confirmed_absent=false

count_entries() { if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi; }
count_files() { if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi; }
active_leases() {
  local count=0 record records
  records=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    jq -e '.active == null' "$record" >/dev/null || count=$((count + 1))
  done <<<"$records"
  echo "$count"
}
lease_records() { find "$runtime_state/leases" -type f -name '*.json' -printf '.\n' | wc -l; }
cleanup_record_count() { find "$containerd_state" -name cube-runtime-resource.json -type f -printf '.\n' | wc -l; }

shared_mount_count() {
  local table
  table=$(findmnt -rn -o TARGET) || return 1
  awk -v root="$shared/" 'index($1, root) == 1 {n++} END {print n+0}' <<<"$table"
}

capture_exact_state() {
  local tag=$1 path mounts adapter_count shared_count reaper_count cleanup_count active_count
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt"
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt"
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt"
  { if test -d /var/run/netns; then find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n'; fi; } | sort >"$evidence/netns-$tag.txt"
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort >"$evidence/cube-shims-$tag.txt"
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P\t%y\n'; fi; } | sort >"$evidence/vm-runtime-$tag.txt"
  adapter_count=$(count_files "$runtime_state/adapter") || return 1
  shared_count=$(count_entries "$shared") || return 1
  reaper_count=$(count_entries "$reaper") || return 1
  cleanup_count=$(cleanup_record_count) || return 1
  mounts=$(shared_mount_count) || return 1
  active_count=$(active_leases) || return 1
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s\n' \
    "$adapter_count" "$shared_count" "$reaper_count" "$cleanup_count" "$mounts" "$active_count" \
    >"$evidence/runtime-resources-$tag.txt"

  "${kube[@]}" get storageclass -o json | jq -r '.items[].metadata.name' | sort >"$evidence/storageclasses-$tag.txt"
  "${kube[@]}" get pv -o json | jq -r '.items[].metadata.name' | sort >"$evidence/pvs-$tag.txt"
  "${kube[@]}" get pvc -A -o json | jq -r '.items[] | [.metadata.namespace,.metadata.name] | @tsv' | sort >"$evidence/pvcs-$tag.txt"
  "${kube[@]}" get csidriver -o json | jq -r '.items[].metadata.name' | sort >"$evidence/csidrivers-$tag.txt"
  "${kube[@]}" get csinode -o json >"$evidence/csinodes-$tag.json"
  jq -r '.items[].metadata.name' "$evidence/csinodes-$tag.json" | sort >"$evidence/csinodes-$tag.txt"
  jq -r '.items[] as $node | ($node.spec.drivers // [])[] | [$node.metadata.name,.name,.nodeID] | @tsv' \
    "$evidence/csinodes-$tag.json" | sort >"$evidence/csinode-drivers-$tag.tsv"
  "${kube[@]}" get volumeattachment -o json | jq -r '.items[].metadata.name' | sort >"$evidence/volumeattachments-$tag.txt"
  : >"$evidence/local-paths-$tag.txt"
  for path in "$s32a_path" "$s32b_path" "$s32c_path"; do
    if test -e "$path" || test -L "$path"; then
      find "$path" -maxdepth 0 -printf '%p\t%y\n' >>"$evidence/local-paths-$tag.txt"
    else
      printf '%s\tabsent\n' "$path" >>"$evidence/local-paths-$tag.txt"
    fi
  done
}

state_matches_baseline() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime runtime-resources \
    storageclasses pvs pvcs csidrivers csinodes volumeattachments local-paths; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
  cmp -s "$evidence/csinode-drivers-before.tsv" "$evidence/csinode-drivers-$tag.tsv" || return 1
}

wait_runtime_idle() {
  local attempt mounts adapter_count shared_count reaper_count vm_count cleanup_count active_count
  for attempt in $(seq 1 1800); do
    adapter_count=$(count_files "$runtime_state/adapter") || return 1
    shared_count=$(count_entries "$shared") || return 1
    reaper_count=$(count_entries "$reaper") || return 1
    vm_count=$(count_entries "$vm_runtime") || return 1
    cleanup_count=$(cleanup_record_count) || return 1
    mounts=$(shared_mount_count) || return 1
    active_count=$(active_leases) || return 1
    if test "$adapter_count" -eq 0 \
      && test "$shared_count" -eq 0 \
      && test "$reaper_count" -eq 0 \
      && test "$vm_count" -eq 0 \
      && test "$cleanup_count" -eq 0 \
      && test "$mounts" -eq 0 \
      && test "$active_count" -eq 0 \
      && ! ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {found=1} END {exit !found}'; then
      return 0
    fi
    sleep .1
  done
  return 1
}

assert_baseline() {
  local tag=$1 attempt kind leases
  for attempt in $(seq 1 1800); do
    capture_exact_state "$tag"
    if state_matches_baseline "$tag"; then
      leases=$(lease_records) || return 1
      printf 'S32D_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
        "$tag" "$attempt" "$leases" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep .1
  done
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime runtime-resources \
    storageclasses pvs pvcs csidrivers csinodes volumeattachments local-paths; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" >"$evidence/$kind-$tag.diff" 2>&1 || true
  done
  diff -u "$evidence/csinode-drivers-before.tsv" "$evidence/csinode-drivers-$tag.tsv" \
    >"$evidence/csinode-drivers-$tag.diff" 2>&1 || true
  return 1
}

delete_if_owned() {
  local kind=$1 name=$2 label=$3 object
  if ! object=$("${cleanup_kube[@]}" get "$kind" "$name" -o json 2>&1); then
    grep -F '(NotFound)' <<<"$object" >/dev/null
    return $?
  fi
  test "$(jq -r --arg label "$label" '.metadata.labels[$label] // ""' <<<"$object")" = true || return 1
  "${cleanup_kube[@]}" delete "$kind" "$name" --grace-period=0 --force --wait=false --timeout=10s >/dev/null 2>&1
}

fixed_objects_absent() {
  local target kind name output
  for target in \
    pod/cubesandbox-s32a-runc pod/cubesandbox-s32a-cube \
    pvc/cubesandbox-s32a-local-pvc pv/cubesandbox-s32a-local-pv storageclass/cubesandbox-s32a-local \
    pod/cubesandbox-s32b-cube pvc/cubesandbox-s32b-local-pvc \
    pv/cubesandbox-s32b-local-pv storageclass/cubesandbox-s32b-local \
    pod/cubesandbox-s32c-failure pod/cubesandbox-s32c-recovery pod/cubesandbox-s32c-rebind \
    pvc/cubesandbox-s32c-first-pvc pvc/cubesandbox-s32c-second-pvc \
    pv/cubesandbox-s32c-local-pv storageclass/cubesandbox-s32c-local; do
    kind=${target%%/*}
    name=${target#*/}
    if output=$("${cleanup_kube[@]}" get "$kind" "$name" -o name 2>&1); then return 1; fi
    grep -F '(NotFound)' <<<"$output" >/dev/null || return 1
  done
}

wait_fixed_objects_absent() {
  local deadline=$((SECONDS + 240))
  while test "$SECONDS" -lt "$deadline"; do
    if fixed_objects_absent; then return 0; fi
    sleep 1
  done
  fixed_objects_absent
}

mount_references() {
  local path=$1 table
  table=$(findmnt -rn -o TARGET,SOURCE) || return 1
  awk -v root="$path" '
    $1 == root || index($1, root "/") == 1 || $2 == root || index($2, root "/") == 1 {n++}
    END {print n+0}
  ' <<<"$table"
}

safe_remove_local_path() {
  local path=$1 allowed=$2 base total=0 expected=0 refs
  if ! test -e "$path" && ! test -L "$path"; then return 0; fi
  test -d "$path" && test ! -L "$path"
  refs=$(mount_references "$path") || return 1
  test "$refs" -eq 0
  if ! total=$(find "$path" -mindepth 1 -maxdepth 1 -printf '.\n' | wc -l); then return 1; fi
  for base in $allowed; do
    if test -e "$path/$base" || test -L "$path/$base"; then
      test -f "$path/$base" && test ! -L "$path/$base" || return 1
      expected=$((expected + 1))
    fi
  done
  test "$total" -eq "$expected"
  for base in $allowed; do rm -f -- "$path/$base" || return 1; done
  rmdir "$path"
}

cleanup() {
  local rc=$? cleanup_rc=0 objects_absent=false runtime_idle=false local_paths_clean=false
  trap - ERR EXIT
  set +e
  delete_if_owned pod cubesandbox-s32a-runc cubesandbox.io/s32a-owned || cleanup_rc=1
  delete_if_owned pod cubesandbox-s32a-cube cubesandbox.io/s32a-owned || cleanup_rc=1
  delete_if_owned pod cubesandbox-s32b-cube cubesandbox.io/s32b-owned || cleanup_rc=1
  delete_if_owned pod cubesandbox-s32c-failure cubesandbox.io/s32c-owned || cleanup_rc=1
  delete_if_owned pod cubesandbox-s32c-recovery cubesandbox.io/s32c-owned || cleanup_rc=1
  delete_if_owned pod cubesandbox-s32c-rebind cubesandbox.io/s32c-owned || cleanup_rc=1
  delete_if_owned pvc cubesandbox-s32a-local-pvc cubesandbox.io/s32a-owned || cleanup_rc=1
  delete_if_owned pvc cubesandbox-s32b-local-pvc cubesandbox.io/s32b-owned || cleanup_rc=1
  delete_if_owned pvc cubesandbox-s32c-first-pvc cubesandbox.io/s32c-owned || cleanup_rc=1
  delete_if_owned pvc cubesandbox-s32c-second-pvc cubesandbox.io/s32c-owned || cleanup_rc=1
  delete_if_owned pv cubesandbox-s32a-local-pv cubesandbox.io/s32a-owned || cleanup_rc=1
  delete_if_owned pv cubesandbox-s32b-local-pv cubesandbox.io/s32b-owned || cleanup_rc=1
  delete_if_owned pv cubesandbox-s32c-local-pv cubesandbox.io/s32c-owned || cleanup_rc=1
  delete_if_owned storageclass cubesandbox-s32a-local cubesandbox.io/s32a-owned || cleanup_rc=1
  delete_if_owned storageclass cubesandbox-s32b-local cubesandbox.io/s32b-owned || cleanup_rc=1
  delete_if_owned storageclass cubesandbox-s32c-local cubesandbox.io/s32c-owned || cleanup_rc=1
  if wait_fixed_objects_absent; then objects_absent=true; else cleanup_rc=1; fi
  if wait_runtime_idle; then runtime_idle=true; else cleanup_rc=1; fi
  if test "$local_paths_confirmed_absent" = true; then
    safe_remove_local_path "$s32a_path" 'runc-marker cube-marker' || cleanup_rc=1
    safe_remove_local_path "$s32b_path" 'first-writer first-peer second-writer second-peer' || cleanup_rc=1
    safe_remove_local_path "$s32c_path" 'admin-seed recovery-marker rebind-marker' || cleanup_rc=1
    if test "$pv_parent_state_captured" = true && test "$pv_parent_existed_before" = false; then
      if test -e "$pv_parent" || test -L "$pv_parent"; then
        test -d "$pv_parent" && test ! -L "$pv_parent" && rmdir "$pv_parent" 2>/dev/null || cleanup_rc=1
      fi
    fi
    if ! test -e "$s32a_path" && ! test -L "$s32a_path" \
      && ! test -e "$s32b_path" && ! test -L "$s32b_path" \
      && ! test -e "$s32c_path" && ! test -L "$s32c_path"; then local_paths_clean=true; else cleanup_rc=1; fi
  fi
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  printf 'cleanup_rc=%s fixed_objects_absent=%s runtime_idle=%s local_paths_clean=%s\n' \
    "$cleanup_rc" "$objects_absent" "$runtime_idle" "$local_paths_clean" >"$evidence/cleanup-result.txt"
  if test "$cleanup_rc" -ne 0 && test "$rc" -eq 0; then rc=1; fi
  exit "$rc"
}

capture_evidence_set() {
  local pattern=$1 target=$2
  find "$component_evidence_root" -mindepth 1 -maxdepth 1 -type d -name "$pattern" -printf '%f\n' | sort >"$target"
}

run_component() {
  local name=$1 script=$2 pattern=$3 done_token=$4 active_limit=$5 wall_limit=$6 rc current_name current
  capture_evidence_set "$pattern" "$evidence/$name-evidence-before.txt"
  set +e
  timeout --signal=TERM --kill-after=30s "$active_limit" bash "$script" >"$evidence/$name.log" 2>&1
  rc=$?
  set -e
  printf '%s\t%s\t%s\n' "$name" "$rc" "$wall_limit" >>"$evidence/component-exit-codes.tsv"
  test "$rc" -eq 0
  capture_evidence_set "$pattern" "$evidence/$name-evidence-after.txt"
  comm -13 "$evidence/$name-evidence-before.txt" "$evidence/$name-evidence-after.txt" >"$evidence/$name-evidence-new.txt"
  test "$(wc -l <"$evidence/$name-evidence-new.txt")" -eq 1
  current_name=$(cat "$evidence/$name-evidence-new.txt")
  current=$component_evidence_root/$current_name
  test -d "$current"
  test ! -e "$current/trace.log"
  test ! -e "$current/cleanup-result.txt"
  grep -F "$done_token" "$current/summary.txt" | grep -F "evidence=$current" >/dev/null
  printf '%s\t%s\n' "$name" "$current" >>"$evidence/component-evidence.tsv"
}

component_evidence() { awk -F '\t' -v name="$1" '$1 == name {print $2}' "$evidence/component-evidence.tsv"; }

lease_record_count_for_sandbox() {
  local sandbox=$1 inactive=$2
  if test "$inactive" = true; then
    find "$runtime_state/leases" -type f -name '*.json' -exec jq -r --arg sandbox "$sandbox" \
      'select(.sandboxID == $sandbox and .active == null) | .sandboxID' {} \; | wc -l
  else
    find "$runtime_state/leases" -type f -name '*.json' -exec jq -r --arg sandbox "$sandbox" \
      'select(.sandboxID == $sandbox) | .sandboxID' {} \; | wc -l
  fi
}

assert_matrix_row() {
  local capability=$1 status=$2
  test "$(awk -F '\t' -v capability="$capability" -v status="$status" \
    '$1 == capability && $2 == status {n++} END {print n+0}' "$evidence/support-matrix.tsv")" -eq 1
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

test "$(sha256sum "$s32a" | awk '{print $1}')" = "$s32a_sha"
test "$(sha256sum "$s32b" | awk '{print $1}')" = "$s32b_sha"
test "$(sha256sum "$s32c" | awk '{print $1}')" = "$s32c_sha"
test "$(sha256sum "$shim" | awk '{print $1}')" = "$shim_sha"
test "$(sha256sum "$harness" | awk '{print $1}')" = "$harness_sha"
bash -n "$s32a"
bash -n "$s32b"
bash -n "$s32c"
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False
fixed_objects_absent
pv_parent_state_captured=true
if test -d "$pv_parent"; then pv_parent_existed_before=true; fi
for path in "$s32a_path" "$s32b_path" "$s32c_path"; do test ! -e "$path" && test ! -L "$path"; done
local_paths_confirmed_absent=true

"${kube[@]}" version -o json >"$evidence/kubernetes-version.json"
containerd --version >"$evidence/containerd-version.txt"
uname -srmo >"$evidence/kernel.txt"
test -c /dev/kvm
server_minor=$(jq -r '.serverVersion.minor | sub("\\+.*$"; "")' "$evidence/kubernetes-version.json")
test "$server_minor" -ge 36
grep -F 'containerd github.com/containerd/containerd/v2 v2.3.4' "$evidence/containerd-version.txt" >/dev/null
test "$(uname -m)" = x86_64

"${kube[@]}" get node "$node" -o json >"$evidence/node-before.json"
jq -r '[.metadata.uid,.status.nodeInfo.kubeletVersion,([.status.addresses[] | select(.type == "InternalIP") | .address] | sort | join(","))] | @tsv' \
  "$evidence/node-before.json" >"$evidence/node-identity-before.tsv"
df -P / >"$evidence/root-disk-before.txt"
root_use_before=$(awk 'NR == 2 {gsub(/%/, "", $5); print $5}' "$evidence/root-disk-before.txt")
test "$root_use_before" -lt 80
"${kube[@]}" get pods -A -o json >"$evidence/pods-before-cases.json"
jq -e '[
  .items[] |
  ((.spec.initContainers // []) + (.spec.containers // []))[] |
  (((.image // "") + " " + ((.command // []) | join(" ")) + " " + ((.args // []) | join(" "))) |
    select(test("local-(volume|static)-provisioner"; "i")))
] | length == 0' "$evidence/pods-before-cases.json" >/dev/null

wait_runtime_idle
capture_exact_state before
test ! -s "$evidence/storageclasses-before.txt"
test ! -s "$evidence/pvs-before.txt"
test ! -s "$evidence/pvcs-before.txt"
test ! -s "$evidence/csidrivers-before.txt"
test ! -s "$evidence/csinode-drivers-before.tsv"
test ! -s "$evidence/volumeattachments-before.txt"
leases_before=$(lease_records)

run_component s32a "$s32a" 's3.2a-pvc-diagnostic-*' 'S32A_DONE active_leases=0 durable_tombstone_delta=1 kubelet_pod_dirs=removed' 870s 900s
s32a_evidence=$(component_evidence s32a)
grep -F 'S32A_PVC_INPUT_OK backend=static-local filesystem=true access=RWO binding=WaitForFirstConsumer cri_oci_match=true runc_rw=true cube_rw=true cross_runtime_persist=true guest=virtiofs-cubeVolumes reclaim=Retain standard_bind=true' "$s32a_evidence/summary.txt" >/dev/null
assert_baseline after-s32a
fixed_objects_absent
leases_after_s32a=$(lease_records)
test $(( leases_after_s32a - leases_before )) -eq 1

run_component s32b "$s32b" 's3.2b-rwo-persistence-*' 'S32B_DONE active_leases=0 durable_tombstone_delta=2 kubelet_pod_dirs=removed' 870s 900s
s32b_evidence=$(component_evidence s32b)
grep -F 'writer_peer=rw pod_rebuild=persist binding=stable backend=static-local' "$s32b_evidence/summary.txt" >/dev/null
assert_baseline after-s32b
fixed_objects_absent
leases_after_s32b=$(lease_records)
test $(( leases_after_s32b - leases_before )) -eq 3

run_component s32c "$s32c" 's3.2c-reclaim-failure-*' 'S32C_DONE active_leases=0 durable_tombstone_delta=3 kubelet_pod_dirs=removed' 870s 900s
s32c_evidence=$(component_evidence s32c)
grep -F 'pvc_before_bad=true expected_error=dev-kvm generations=0' "$s32c_evidence/summary.txt" >/dev/null
grep -F 'released_gate=true pending_has_no_sandbox=true pending_no_sandbox_evidence=true admin_claimref_remove=true data_preserved=true data_hashes=3 delete_backend=not-applicable-without-deleter' "$s32c_evidence/summary.txt" >/dev/null
assert_baseline after-s32c
fixed_objects_absent
leases_after_s32c=$(lease_records)
test $(( leases_after_s32c - leases_before )) -eq 6

printf 'component\tsandbox_id\n' >"$evidence/component-sandboxes.tsv"
printf 's32a\t%s\n' "$(jq -r '.info.sandboxID' "$s32a_evidence/cri-cube.json")" >>"$evidence/component-sandboxes.tsv"
awk -F '\t' 'NR > 1 {print "s32b\t" $4}' "$s32b_evidence/runtime-identities.tsv" >>"$evidence/component-sandboxes.tsv"
printf 's32c-failure\t%s\n' "$(jq -r '.info.sandboxID' "$s32c_evidence/cri-failure.json")" >>"$evidence/component-sandboxes.tsv"
printf 's32c-recovery\t%s\n' "$(jq -r '.info.sandboxID' "$s32c_evidence/cri-recovery.json")" >>"$evidence/component-sandboxes.tsv"
printf 's32c-rebind\t%s\n' "$(jq -r '.info.sandboxID' "$s32c_evidence/cri-rebind.json")" >>"$evidence/component-sandboxes.tsv"
test "$(wc -l <"$evidence/component-sandboxes.tsv")" -eq 7
test "$(awk -F '\t' 'NR > 1 {print $2}' "$evidence/component-sandboxes.tsv" | sort -u | wc -l)" -eq 6
while IFS=$'\t' read -r component sandbox; do
  total_records=0
  inactive_records=0
  test "$component" != component
  test -n "$sandbox" && test "$sandbox" != null
  total_records=$(lease_record_count_for_sandbox "$sandbox" false)
  inactive_records=$(lease_record_count_for_sandbox "$sandbox" true)
  test "$total_records" -eq 1
  test "$inactive_records" -eq 1
done < <(tail -n +2 "$evidence/component-sandboxes.tsv")

"${kube[@]}" get node "$node" -o json >"$evidence/node-after.json"
jq -r '[.metadata.uid,.status.nodeInfo.kubeletVersion,([.status.addresses[] | select(.type == "InternalIP") | .address] | sort | join(","))] | @tsv' \
  "$evidence/node-after.json" >"$evidence/node-identity-after.tsv"
cmp "$evidence/node-identity-before.tsv" "$evidence/node-identity-after.tsv"
test "$(jq -r '.status.conditions[] | select(.type == "Ready") | .status' "$evidence/node-after.json")" = True
test "$(jq -r '.status.conditions[] | select(.type == "DiskPressure") | .status' "$evidence/node-after.json")" = False
df -P / >"$evidence/root-disk-after.txt"
root_use=$(awk 'NR == 2 {gsub(/%/, "", $5); print $5}' "$evidence/root-disk-after.txt")
test "$root_use" -lt 80
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active

printf 'capability\tstatus\tsemantics\tevidence\n' >"$evidence/support-matrix.tsv"
printf 'standard-filesystem-pvc-bind\tSUPPORTED_POC\tstatic-local runtime baseline only; kubelet CRI/OCI bind input\t%s\n' "$s32a_evidence" >>"$evidence/support-matrix.tsv"
printf 'runc-to-cube-persistence\tSUPPORTED_POC\tstatic-local runtime baseline only; sequential readers and writers\t%s\n' "$s32a_evidence" >>"$evidence/support-matrix.tsv"
printf 'pod-multicontainer-rwo-persistence\tSUPPORTED_POC\tstatic-local runtime baseline only; shared source across Pod containers\t%s\n' "$s32b_evidence" >>"$evidence/support-matrix.tsv"
printf 'pod-rebuild-rwo-persistence\tSUPPORTED_POC\tstatic-local runtime baseline only; data survives Pod UID and Sandbox replacement\t%s\n' "$s32b_evidence" >>"$evidence/support-matrix.tsv"
printf 'failed-create-task-pvc-rollback\tSUPPORTED_POC\tstatic-local runtime baseline only; failed Task generations and mounts removed\t%s\n' "$s32c_evidence" >>"$evidence/support-matrix.tsv"
printf 'retain-manual-rebind\tSUPPORTED_MANUAL_POC\tstatic-local runtime baseline only; Released claimRef requires administrator removal\t%s\n' "$s32c_evidence" >>"$evidence/support-matrix.tsv"
printf 'static-local-delete\tNOT_APPLICABLE_WITHOUT_DELETER\tno local or static provisioner is installed; automatic backend deletion is not claimed\t%s\n' "$s32c_evidence" >>"$evidence/support-matrix.tsv"
printf 'generic-rwo-exclusivity\tNOT_VALIDATED\tstatic-local single-node tests do not prove generic RWO exclusivity\t-\n' >>"$evidence/support-matrix.tsv"
printf 'hostpath-file-directory\tNOT_VALIDATED\tnot claimed by S3.2\t-\n' >>"$evidence/support-matrix.tsv"
printf 'csi-filesystem-rwo\tNOT_VALIDATED\tno CSI driver is installed in the test cluster\t-\n' >>"$evidence/support-matrix.tsv"
printf 'dynamic-provisioning\tNOT_VALIDATED\tno dynamic provisioner is installed in the test cluster\t-\n' >>"$evidence/support-matrix.tsv"
printf 'tencent-cbs\tNOT_VALIDATED\tcloud block backend not exercised\t-\n' >>"$evidence/support-matrix.tsv"
printf 'tencent-cfs\tNOT_VALIDATED\tcloud filesystem backend not exercised\t-\n' >>"$evidence/support-matrix.tsv"
printf 'tencent-cosfs\tNOT_VALIDATED\tobject-backed filesystem not exercised\t-\n' >>"$evidence/support-matrix.tsv"
printf 'filesystem-rwx\tNOT_VALIDATED\tRWX backend not exercised\t-\n' >>"$evidence/support-matrix.tsv"
printf 'cross-node-attach\tNOT_VALIDATED\tsingle-node static-local path cannot prove attach semantics\t-\n' >>"$evidence/support-matrix.tsv"
printf 'volume-expansion\tNOT_VALIDATED\texpansion path not exercised\t-\n' >>"$evidence/support-matrix.tsv"
printf 'raw-block\tOUT_OF_SCOPE_POC\tnot claimed by PoC first version\t-\n' >>"$evidence/support-matrix.tsv"
printf 'mount-propagation\tOUT_OF_SCOPE_POC\tnot claimed by PoC first version\t-\n' >>"$evidence/support-matrix.tsv"
printf 'volume-snapshot\tDEFERRED_S6\tSnapshot and Restore CRD is a second-phase capability\t-\n' >>"$evidence/support-matrix.tsv"

test "$(wc -l <"$evidence/support-matrix.tsv")" -eq 21
test "$(awk -F '\t' 'NR > 1 {print $1}' "$evidence/support-matrix.tsv" | sort -u | wc -l)" -eq 20
test "$(awk -F '\t' 'NR > 1 && $2 !~ /^(SUPPORTED_POC|SUPPORTED_MANUAL_POC|NOT_APPLICABLE_WITHOUT_DELETER|NOT_VALIDATED|OUT_OF_SCOPE_POC|DEFERRED_S6)$/ {n++} END {print n+0}' "$evidence/support-matrix.tsv")" -eq 0
test "$(awk -F '\t' 'NR > 1 && $2 ~ /^SUPPORTED/ && ($3 !~ /^static-local runtime baseline only;/ || $4 !~ /^\/data\/cubelet\/s3\.2-evidence\//) {n++} END {print n+0}' "$evidence/support-matrix.tsv")" -eq 0
assert_matrix_row standard-filesystem-pvc-bind SUPPORTED_POC
assert_matrix_row runc-to-cube-persistence SUPPORTED_POC
assert_matrix_row pod-multicontainer-rwo-persistence SUPPORTED_POC
assert_matrix_row pod-rebuild-rwo-persistence SUPPORTED_POC
assert_matrix_row failed-create-task-pvc-rollback SUPPORTED_POC
assert_matrix_row retain-manual-rebind SUPPORTED_MANUAL_POC
assert_matrix_row static-local-delete NOT_APPLICABLE_WITHOUT_DELETER
assert_matrix_row generic-rwo-exclusivity NOT_VALIDATED
assert_matrix_row hostpath-file-directory NOT_VALIDATED
assert_matrix_row csi-filesystem-rwo NOT_VALIDATED
assert_matrix_row dynamic-provisioning NOT_VALIDATED
assert_matrix_row tencent-cbs NOT_VALIDATED
assert_matrix_row tencent-cfs NOT_VALIDATED
assert_matrix_row tencent-cosfs NOT_VALIDATED
assert_matrix_row filesystem-rwx NOT_VALIDATED
assert_matrix_row cross-node-attach NOT_VALIDATED
assert_matrix_row volume-expansion NOT_VALIDATED
assert_matrix_row raw-block OUT_OF_SCOPE_POC
assert_matrix_row mount-propagation OUT_OF_SCOPE_POC
assert_matrix_row volume-snapshot DEFERRED_S6

printf 'S32D_REGRESSION_OK s32a=%s s32b=%s s32c=%s exact_baseline=stable lease_delta=6 sandbox_records=6 static_local_only=true node_ready=true disk_pressure=false root_use=%s%%\n' \
  "$s32a_evidence" "$s32b_evidence" "$s32c_evidence" "$root_use" | tee -a "$evidence/summary.txt"
printf 'S32D_DONE support_matrix=%s evidence=%s\n' "$evidence/support-matrix.tsv" "$evidence" | tee -a "$evidence/summary.txt"
