#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=15s)
cleanup_kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=2s)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
sc=cubesandbox-s32b-local
pv=cubesandbox-s32b-local-pv
pvc=cubesandbox-s32b-local-pvc
pod=cubesandbox-s32b-cube
pv_parent=/data/cubelet/s3.2-pv
pv_path=$pv_parent/s32b-local
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.2-evidence/s3.2b-rwo-persistence-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
pv_parent_state_captured=false
pv_parent_existed_before=false
pvc_uid=
pv_uid=

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
  "${kube[@]}" get storageclass -o json | jq -r '.items[].metadata.name' | sort >"$evidence/storageclasses-$tag.txt"
  "${kube[@]}" get pv -o json | jq -r '.items[].metadata.name' | sort >"$evidence/pvs-$tag.txt"
  "${kube[@]}" get pvc -A -o json | jq -r '.items[] | [.metadata.namespace,.metadata.name] | @tsv' | sort >"$evidence/pvcs-$tag.txt"
  { test -e "$pv_parent" && stat -Lc 'parent\t%d:%i\t%a' "$pv_parent" || true; test -e "$pv_path" && stat -Lc 'path\t%d:%i\t%a' "$pv_path" || true; } \
    >"$evidence/local-paths-$tag.txt"
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s\n' \
    "$(count_files "$runtime_state/adapter")" "$(count_entries "$shared")" "$(count_entries "$reaper")" \
    "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" \
    "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" "$(active_leases)" \
    >"$evidence/resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime storageclasses pvs pvcs local-paths resources; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
}

runtime_matches_baseline() {
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

assert_runtime_baseline() {
  local tag=$1 attempt kind
  for attempt in $(seq 1 1200); do
    capture_state "$tag"
    if runtime_matches_baseline "$tag"; then
      printf 'S32B_RUNTIME_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
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

assert_baseline() {
  local tag=$1 attempt kind
  for attempt in $(seq 1 1200); do
    capture_state "$tag"
    if state_matches_baseline "$tag"; then
      printf 'S32B_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
        "$tag" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep .1
  done
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime storageclasses pvs pvcs local-paths resources; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" >"$evidence/$kind-$tag.diff" 2>&1 || true
  done
  return 1
}

get_object() {
  "${cleanup_kube[@]}" get "$1" "$2" -o json 2>&1
}

delete_if_owned() {
  local kind=$1 name=$2 object
  if ! object=$(get_object "$kind" "$name"); then
    grep -F '(NotFound)' <<<"$object" >/dev/null
    return $?
  fi
  test "$(jq -r '.metadata.labels["cubesandbox.io/s32b-owned"] // ""' <<<"$object")" = true || return 1
  if test "$kind" = pod; then
    "${cleanup_kube[@]}" delete "$kind" "$name" --grace-period=0 --force --wait=false --timeout=10s >/dev/null
  else
    "${cleanup_kube[@]}" delete "$kind" "$name" --wait=false --timeout=10s >/dev/null
  fi
}

object_absent() {
  local output
  if output=$(get_object "$1" "$2"); then return 1; fi
  grep -F '(NotFound)' <<<"$output" >/dev/null
}

wait_absent() {
  local kind=$1 name=$2 deadline=$((SECONDS + 180))
  while test "$SECONDS" -lt "$deadline"; do
    if object_absent "$kind" "$name"; then return 0; fi
    sleep 1
  done
  object_absent "$kind" "$name"
}

fixed_objects_absent() {
  local rc=0
  object_absent pod "$pod" || rc=1
  object_absent pvc "$pvc" || rc=1
  object_absent pv "$pv" || rc=1
  object_absent storageclass "$sc" || rc=1
  return "$rc"
}

delete_owned_objects() {
  local rc=0
  delete_if_owned pod "$pod" || rc=1
  wait_absent pod "$pod" || rc=1
  delete_if_owned pvc "$pvc" || rc=1
  wait_absent pvc "$pvc" || rc=1
  delete_if_owned pv "$pv" || rc=1
  wait_absent pv "$pv" || rc=1
  delete_if_owned storageclass "$sc" || rc=1
  wait_absent storageclass "$sc" || rc=1
  fixed_objects_absent || rc=1
  return "$rc"
}

remove_pv_path() {
  local mount_refs
  mount_refs=$(findmnt -rn -o TARGET,SOURCE | awk -v path="$pv_path" 'index($1, path) || index($2, path) {n++} END {print n+0}')
  test "$mount_refs" -eq 0
  if test -d "$pv_path"; then
    rm -f "$pv_path/first-writer" "$pv_path/first-peer" "$pv_path/second-writer" "$pv_path/second-peer"
    rmdir "$pv_path"
  fi
  if test "$pv_parent_state_captured" = true && test "$pv_parent_existed_before" = false && test -d "$pv_parent"; then
    rmdir "$pv_parent"
  fi
}

sandbox_for_uid() {
  local ids count
  ids=$("${cri[@]}" pods -o json | jq -r --arg uid "$1" '.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id')
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1
  printf '%s\n' "$ids"
}

shim_pid_for_sandbox() {
  local pids count
  pids=$(ps -eo pid=,args= | awk -v id="$1" '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {print $1}')
  count=$(printf '%s\n' "$pids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1
  printf '%s\n' "$pids"
}

active_shared_root() {
  local roots count
  roots=$(find "$shared" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
  count=$(printf '%s\n' "$roots" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1
  printf '%s\n' "$roots"
}

container_id() {
  "${kube[@]}" get pod "$pod" -o json | jq -r --arg name "$1" \
    '.status.containerStatuses[] | select(.name == $name and .state.running != null) | .containerID | sub("^containerd://"; "")'
}

capture_active_lease() {
  local sandbox=$1 target=$2 record matches=()
  while IFS= read -r record; do
    if jq -e --arg id "$sandbox" '.sandboxID == $id and .active != null and .active.phase == "READY"' "$record" >/dev/null; then
      matches+=("$record")
    fi
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print 2>/dev/null)
  test "${#matches[@]}" -eq 1
  jq 'if .active != null then .active.handoffToken = "<redacted>" else . end' "${matches[0]}" >"$target"
  jq -r '.active.leaseID' "$target"
}

capture_mount_input() {
  local tag=$1 id=$2 uid=$3 destination=$4 source
  "${cri[@]}" inspect "$id" >"$evidence/cri-$tag.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$tag.json"
  jq -r --arg destination "$destination" '(.info.runtimeSpec.mounts // [])[] | select(.destination == $destination) | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/cri-$tag.json" >"$evidence/mount-$tag-cri.tsv"
  jq -r --arg destination "$destination" '(.Spec.mounts // [])[] | select(.destination == $destination) | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/ctr-$tag.json" >"$evidence/mount-$tag-ctr.tsv"
  cmp "$evidence/mount-$tag-cri.tsv" "$evidence/mount-$tag-ctr.tsv"
  test "$(wc -l <"$evidence/mount-$tag-cri.tsv")" -eq 1
  source=$(awk -F '\t' '$2 == "bind" && ("," $4 ",") !~ /,ro,/ {print $3}' "$evidence/mount-$tag-cri.tsv")
  test -n "$source" && test -d "$source"
  case "$source" in
    "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~local-volume/$pv") ;;
    *) return 1 ;;
  esac
  findmnt -rn -M "$source" -o TARGET,SOURCE,FSTYPE,OPTIONS >"$evidence/findmnt-$tag.txt"
  test -s "$evidence/findmnt-$tag.txt"
  printf '%s\n' "$source"
}

assert_guest_mount() {
  local run=$1 container=$2 destination=$3
  "${kube[@]}" exec "$pod" -c "$container" -- cat /proc/self/mountinfo >"$evidence/guest-mountinfo-$run-$container.txt"
  awk -v destination="$destination" '$5 == destination && $6 ~ /(^|,)rw(,|$)/ && $0 ~ / - virtiofs cubeVolumes / {found++} END {exit found != 1}' \
    "$evidence/guest-mountinfo-$run-$container.txt"
}

assert_binding() {
  local tag=$1 actual_pvc_uid actual_pv_uid
  "${kube[@]}" get pvc "$pvc" -o json >"$evidence/pvc-$tag.json"
  "${kube[@]}" get pv "$pv" -o json >"$evidence/pv-$tag.json"
  actual_pvc_uid=$(jq -r '.metadata.uid' "$evidence/pvc-$tag.json")
  actual_pv_uid=$(jq -r '.metadata.uid' "$evidence/pv-$tag.json")
  if test -z "$pvc_uid"; then pvc_uid=$actual_pvc_uid; fi
  if test -z "$pv_uid"; then pv_uid=$actual_pv_uid; fi
  test "$actual_pvc_uid" = "$pvc_uid"
  test "$actual_pv_uid" = "$pv_uid"
  jq -e --arg pv "$pv" '.status.phase == "Bound" and .spec.volumeName == $pv' "$evidence/pvc-$tag.json" >/dev/null
  jq -e --arg pvc "$pvc" --arg uid "$pvc_uid" '
    .status.phase == "Bound" and
    .spec.claimRef.namespace == "default" and
    .spec.claimRef.name == $pvc and
    .spec.claimRef.uid == $uid
  ' "$evidence/pv-$tag.json" >/dev/null
}

write_pod_manifest() {
  local run=$1 target=$2
  cat >"$target" <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels:
    cubesandbox.io/s32b-owned: "true"
    cubesandbox.io/s32b-run: "$run"
spec:
  runtimeClassName: cube
  nodeSelector: {kubernetes.io/hostname: $node}
  tolerations:
  - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: writer
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
    volumeMounts: [{name: data, mountPath: /writer}]
  - name: peer
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
    volumeMounts: [{name: data, mountPath: /peer}]
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: $pvc}
POD_EOF
}

cleanup() {
  local rc=$? cleanup_rc=0
  trap - ERR EXIT
  set +e
  delete_owned_objects || cleanup_rc=1
  wait_runtime_idle || cleanup_rc=1
  remove_pv_path || cleanup_rc=1
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  printf 'cleanup_rc=%s\n' "$cleanup_rc" >"$evidence/cleanup-result.txt"
  if test "$cleanup_rc" -ne 0 && test "$rc" -eq 0; then rc=1; fi
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

delete_owned_objects
wait_runtime_idle
remove_pv_path
pv_parent_state_captured=true
if test -d "$pv_parent"; then pv_parent_existed_before=true; fi
capture_state before
leases_before=$(lease_records)

install -d -m 0777 "$pv_path"
cat >"$evidence/storage.yaml" <<STORAGE_EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $sc
  labels: {cubesandbox.io/s32b-owned: "true"}
provisioner: kubernetes.io/no-provisioner
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $pv
  labels: {cubesandbox.io/s32b-owned: "true"}
spec:
  capacity: {storage: 1Gi}
  volumeMode: Filesystem
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: $sc
  local: {path: $pv_path}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: kubernetes.io/hostname, operator: In, values: [$node]}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc
  labels: {cubesandbox.io/s32b-owned: "true"}
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: $sc
  resources:
    requests: {storage: 64Mi}
STORAGE_EOF
"${kube[@]}" apply -f "$evidence/storage.yaml" >"$evidence/apply-storage.txt"

write_pod_manifest first "$evidence/pod-first.yaml"
"${kube[@]}" create -f "$evidence/pod-first.yaml" >"$evidence/create-first.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=300s >"$evidence/wait-first.txt"
"${kube[@]}" get pod "$pod" -o json >"$evidence/pod-first.json"
first_uid=$(jq -r '.metadata.uid' "$evidence/pod-first.json")
first_ip=$(jq -r '.status.podIP' "$evidence/pod-first.json")
test -n "$first_uid" && test "$first_uid" != null
test -n "$first_ip" && test "$first_ip" != null
first_sandbox=$(sandbox_for_uid "$first_uid")
first_shim=$(shim_pid_for_sandbox "$first_sandbox")
test -d "$vm_runtime/$first_sandbox"
first_shared_root=$(active_shared_root)
first_vm_inode=$(stat -Lc '%d:%i' "$vm_runtime/$first_sandbox")
first_lease=$(capture_active_lease "$first_sandbox" "$evidence/lease-first.json")
"${cri[@]}" inspectp "$first_sandbox" >"$evidence/sandbox-first.json"
assert_binding first

first_writer_id=$(container_id writer)
first_peer_id=$(container_id peer)
test -n "$first_writer_id" && test -n "$first_peer_id"
first_writer_source=$(capture_mount_input first-writer "$first_writer_id" "$first_uid" /writer)
first_peer_source=$(capture_mount_input first-peer "$first_peer_id" "$first_uid" /peer)
test "$first_writer_source" = "$first_peer_source"
assert_guest_mount first writer /writer
assert_guest_mount first peer /peer

"${kube[@]}" exec "$pod" -c writer -- sh -c 'printf first-writer >/writer/first-writer; sync; test "$(cat /writer/first-writer)" = first-writer'
test "$("${kube[@]}" exec "$pod" -c peer -- cat /peer/first-writer | tr -d '\r\n')" = first-writer
"${kube[@]}" exec "$pod" -c peer -- sh -c 'printf first-peer >/peer/first-peer; sync'
test "$("${kube[@]}" exec "$pod" -c writer -- cat /writer/first-peer | tr -d '\r\n')" = first-peer
test "$(cat "$pv_path/first-writer")" = first-writer
test "$(cat "$pv_path/first-peer")" = first-peer
sha256sum "$pv_path/first-writer" "$pv_path/first-peer" >"$evidence/data-after-first.sha256"

delete_if_owned pod "$pod"
wait_absent pod "$pod"
for _ in $(seq 1 1200); do test ! -e "/var/lib/kubelet/pods/$first_uid" && break; sleep .1; done
test ! -e "/var/lib/kubelet/pods/$first_uid"
wait_runtime_idle
assert_runtime_baseline after-first
test ! -e "$vm_runtime/$first_sandbox"
test ! -e "$first_shared_root"
test "$("${cri[@]}" pods -o json | jq -r --arg id "$first_sandbox" '[.items[] | select(.id == $id)] | length')" -eq 0
assert_binding after-first
test "$(cat "$pv_path/first-writer")" = first-writer
test "$(cat "$pv_path/first-peer")" = first-peer

write_pod_manifest second "$evidence/pod-second.yaml"
"${kube[@]}" create -f "$evidence/pod-second.yaml" >"$evidence/create-second.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=300s >"$evidence/wait-second.txt"
"${kube[@]}" get pod "$pod" -o json >"$evidence/pod-second.json"
second_uid=$(jq -r '.metadata.uid' "$evidence/pod-second.json")
second_ip=$(jq -r '.status.podIP' "$evidence/pod-second.json")
test -n "$second_uid" && test "$second_uid" != null
test -n "$second_ip" && test "$second_ip" != null
second_sandbox=$(sandbox_for_uid "$second_uid")
second_shim=$(shim_pid_for_sandbox "$second_sandbox")
test -d "$vm_runtime/$second_sandbox"
second_shared_root=$(active_shared_root)
second_vm_inode=$(stat -Lc '%d:%i' "$vm_runtime/$second_sandbox")
second_lease=$(capture_active_lease "$second_sandbox" "$evidence/lease-second.json")
"${cri[@]}" inspectp "$second_sandbox" >"$evidence/sandbox-second.json"
test "$second_uid" != "$first_uid"
test "$second_sandbox" != "$first_sandbox"
test "$second_lease" != "$first_lease"
test ! -e "$vm_runtime/$first_sandbox"
assert_binding second

second_writer_id=$(container_id writer)
second_peer_id=$(container_id peer)
test -n "$second_writer_id" && test -n "$second_peer_id"
second_writer_source=$(capture_mount_input second-writer "$second_writer_id" "$second_uid" /writer)
second_peer_source=$(capture_mount_input second-peer "$second_peer_id" "$second_uid" /peer)
test "$second_writer_source" = "$second_peer_source"
test "$second_writer_source" != "$first_writer_source"
assert_guest_mount second writer /writer
assert_guest_mount second peer /peer

test "$("${kube[@]}" exec "$pod" -c writer -- cat /writer/first-writer | tr -d '\r\n')" = first-writer
test "$("${kube[@]}" exec "$pod" -c writer -- cat /writer/first-peer | tr -d '\r\n')" = first-peer
test "$("${kube[@]}" exec "$pod" -c peer -- cat /peer/first-writer | tr -d '\r\n')" = first-writer
test "$("${kube[@]}" exec "$pod" -c peer -- cat /peer/first-peer | tr -d '\r\n')" = first-peer
"${kube[@]}" exec "$pod" -c writer -- sh -c 'printf second-writer >/writer/second-writer; sync'
test "$("${kube[@]}" exec "$pod" -c peer -- cat /peer/second-writer | tr -d '\r\n')" = second-writer
"${kube[@]}" exec "$pod" -c peer -- sh -c 'printf second-peer >/peer/second-peer; sync'
test "$("${kube[@]}" exec "$pod" -c writer -- cat /writer/second-peer | tr -d '\r\n')" = second-peer
sha256sum "$pv_path/first-writer" "$pv_path/first-peer" "$pv_path/second-writer" "$pv_path/second-peer" >"$evidence/data-after-second.sha256"

printf 'run\tpod_uid\tpod_ip\tsandbox\tshim_pid\tvm_path\tvm_inode\tlease_id\twriter_source\n' >"$evidence/runtime-identities.tsv"
printf 'first\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$first_uid" "$first_ip" "$first_sandbox" "$first_shim" "$vm_runtime/$first_sandbox" "$first_vm_inode" "$first_lease" "$first_writer_source" \
  >>"$evidence/runtime-identities.tsv"
printf 'second\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$second_uid" "$second_ip" "$second_sandbox" "$second_shim" "$vm_runtime/$second_sandbox" "$second_vm_inode" "$second_lease" "$second_writer_source" \
  >>"$evidence/runtime-identities.tsv"

delete_if_owned pod "$pod"
wait_absent pod "$pod"
for _ in $(seq 1 1200); do test ! -e "/var/lib/kubelet/pods/$second_uid" && break; sleep .1; done
test ! -e "/var/lib/kubelet/pods/$second_uid"
wait_runtime_idle
assert_runtime_baseline after-second
test ! -e "$vm_runtime/$second_sandbox"
test ! -e "$second_shared_root"
assert_binding after-second
for marker in first-writer first-peer second-writer second-peer; do test "$(cat "$pv_path/$marker")" = "$marker"; done
test $(( $(lease_records) - leases_before )) -eq 2

printf 'S32B_RWO_PERSIST_OK pvc_uid=%s pv_uid=%s first_uid=%s second_uid=%s first_sandbox=%s second_sandbox=%s first_vm_removed=true second_vm_new=true writer_peer=rw pod_rebuild=persist binding=stable backend=static-local\n' \
  "$pvc_uid" "$pv_uid" "$first_uid" "$second_uid" "$first_sandbox" "$second_sandbox" | tee -a "$evidence/summary.txt"

delete_if_owned pvc "$pvc"
wait_absent pvc "$pvc"
delete_if_owned pv "$pv"
wait_absent pv "$pv"
delete_if_owned storageclass "$sc"
wait_absent storageclass "$sc"
remove_pv_path
assert_baseline after
test $(( $(lease_records) - leases_before )) -eq 2
printf 'S32B_DONE active_leases=0 durable_tombstone_delta=2 kubelet_pod_dirs=removed evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1
journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1
trap - ERR EXIT
