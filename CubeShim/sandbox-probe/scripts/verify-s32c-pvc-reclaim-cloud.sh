#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=15s)
cleanup_kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=2s)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
sc=cubesandbox-s32c-local
pv=cubesandbox-s32c-local-pv
pvc_first=cubesandbox-s32c-first-pvc
pvc_second=cubesandbox-s32c-second-pvc
pod_failure=cubesandbox-s32c-failure
pod_recovery=cubesandbox-s32c-recovery
pod_rebind=cubesandbox-s32c-rebind
pods=("$pod_failure" "$pod_recovery" "$pod_rebind")
pvcs=("$pvc_first" "$pvc_second")
pv_parent=/data/cubelet/s3.2-pv
pv_path=$pv_parent/s32c-local
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.2-evidence/s3.2c-reclaim-failure-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
pv_parent_state_captured=false
pv_parent_existed_before=false
first_pvc_uid=
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
      printf 'S32C_RUNTIME_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
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
      printf 'S32C_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
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
  test "$(jq -r '.metadata.labels["cubesandbox.io/s32c-owned"] // ""' <<<"$object")" = true || return 1
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
  local rc=0 name
  for name in "${pods[@]}"; do object_absent pod "$name" || rc=1; done
  for name in "${pvcs[@]}"; do object_absent pvc "$name" || rc=1; done
  object_absent pv "$pv" || rc=1
  object_absent storageclass "$sc" || rc=1
  return "$rc"
}

delete_owned_objects() {
  local rc=0 name
  for name in "${pods[@]}"; do
    delete_if_owned pod "$name" || rc=1
    wait_absent pod "$name" || rc=1
  done
  for name in "${pvcs[@]}"; do
    delete_if_owned pvc "$name" || rc=1
    wait_absent pvc "$name" || rc=1
  done
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
    rm -f "$pv_path/admin-seed" "$pv_path/recovery-marker" "$pv_path/rebind-marker"
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

active_shared_root() {
  local roots count
  roots=$(find "$shared" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
  count=$(printf '%s\n' "$roots" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1
  printf '%s\n' "$roots"
}

task_generation_count() {
  local root entries current total=0
  for root in "$1/rootfs" "$1/volumes"; do
    if test -d "$root"; then
      if entries=$(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%p\n'); then
        current=$(awk 'NF {n++} END {print n+0}' <<<"$entries")
        total=$((total + current))
      elif ! test -e "$root" && ! test -L "$root"; then
        continue
      else
        return 1
      fi
    elif test -e "$root" || test -L "$root"; then
      return 1
    fi
  done
  echo "$total"
}

container_id() {
  local pod=$1 name=$2
  "${kube[@]}" get pod "$pod" -o json | jq -r --arg name "$name" \
    '.status.containerStatuses[] | select(.name == $name and .state.running != null) | .containerID | sub("^containerd://"; "")'
}

capture_mount_input() {
  local tag=$1 id=$2 uid=$3 source
  "${cri[@]}" inspect "$id" >"$evidence/cri-$tag.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$tag.json"
  jq -r '(.info.runtimeSpec.mounts // [])[] | select(.destination == "/pvc") | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/cri-$tag.json" >"$evidence/mount-$tag-cri.tsv"
  jq -r '(.Spec.mounts // [])[] | select(.destination == "/pvc") | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/ctr-$tag.json" >"$evidence/mount-$tag-ctr.tsv"
  cmp "$evidence/mount-$tag-cri.tsv" "$evidence/mount-$tag-ctr.tsv"
  test "$(wc -l <"$evidence/mount-$tag-cri.tsv")" -eq 1
  source=$(awk -F '\t' '$1 == "/pvc" && $2 == "bind" && ("," $4 ",") !~ /,ro,/ {print $3}' "$evidence/mount-$tag-cri.tsv")
  test -n "$source" && test -d "$source"
  case "$source" in
    "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~local-volume/$pv") ;;
    *) return 1 ;;
  esac
  findmnt -rn -M "$source" -o TARGET,SOURCE,FSTYPE,OPTIONS >"$evidence/findmnt-$tag.txt"
  test -s "$evidence/findmnt-$tag.txt"
  printf '%s\n' "$source"
}

capture_failure_mount_input() {
  local id=$1 uid=$2 pvc_index bad_index pvc_source
  "${cri[@]}" inspect "$id" >"$evidence/cri-failure.candidate.json" || return 1
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-failure.candidate.json" || return 1
  jq -r '
    (.info.runtimeSpec.mounts // []) | to_entries[] |
    select(.value.destination == "/pvc" or .value.destination == "/bad") |
    [.key,.value.destination,.value.type,.value.source,((.value.options // [])|join(","))] | @tsv
  ' "$evidence/cri-failure.candidate.json" >"$evidence/mount-failure-cri.candidate.tsv" || return 1
  jq -r '
    (.Spec.mounts // []) | to_entries[] |
    select(.value.destination == "/pvc" or .value.destination == "/bad") |
    [.key,.value.destination,.value.type,.value.source,((.value.options // [])|join(","))] | @tsv
  ' "$evidence/ctr-failure.candidate.json" >"$evidence/mount-failure-ctr.candidate.tsv" || return 1
  cmp -s "$evidence/mount-failure-cri.candidate.tsv" "$evidence/mount-failure-ctr.candidate.tsv" || return 1
  test "$(wc -l <"$evidence/mount-failure-cri.candidate.tsv")" -eq 2 || return 1
  pvc_index=$(awk -F '\t' '$2 == "/pvc" && $3 == "bind" && ("," $5 ",") !~ /,ro,/ {print $1}' "$evidence/mount-failure-cri.candidate.tsv")
  bad_index=$(awk -F '\t' '$2 == "/bad" && $3 == "bind" && $4 == "/dev/kvm" {print $1}' "$evidence/mount-failure-cri.candidate.tsv")
  pvc_source=$(awk -F '\t' '$2 == "/pvc" {print $4}' "$evidence/mount-failure-cri.candidate.tsv")
  test -n "$pvc_index" && test -n "$bad_index" && test "$pvc_index" -lt "$bad_index" || return 1
  case "$pvc_source" in
    "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~local-volume/$pv") ;;
    *) return 1 ;;
  esac
  mv "$evidence/cri-failure.candidate.json" "$evidence/cri-failure.json"
  mv "$evidence/ctr-failure.candidate.json" "$evidence/ctr-failure.json"
  mv "$evidence/mount-failure-cri.candidate.tsv" "$evidence/mount-failure-cri.tsv"
  mv "$evidence/mount-failure-ctr.candidate.tsv" "$evidence/mount-failure-ctr.tsv"
}

assert_bound() {
  local pvc=$1 tag=$2 expected_uid=$3
  "${kube[@]}" get pvc "$pvc" -o json >"$evidence/pvc-$tag.json"
  "${kube[@]}" get pv "$pv" -o json >"$evidence/pv-$tag.json"
  test "$(jq -r '.metadata.uid' "$evidence/pvc-$tag.json")" = "$expected_uid"
  test "$(jq -r '.metadata.uid' "$evidence/pv-$tag.json")" = "$pv_uid"
  jq -e --arg pv "$pv" '.status.phase == "Bound" and .spec.volumeName == $pv' "$evidence/pvc-$tag.json" >/dev/null
  jq -e --arg pvc "$pvc" --arg uid "$expected_uid" '
    .status.phase == "Bound" and
    .spec.claimRef.namespace == "default" and
    .spec.claimRef.name == $pvc and
    .spec.claimRef.uid == $uid and
    .spec.persistentVolumeReclaimPolicy == "Retain"
  ' "$evidence/pv-$tag.json" >/dev/null
}

write_healthy_pod() {
  local name=$1 claim=$2 target=$3
  cat >"$target" <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels: {cubesandbox.io/s32c-owned: "true"}
spec:
  runtimeClassName: cube
  nodeSelector: {kubernetes.io/hostname: $node}
  tolerations:
  - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
    volumeMounts: [{name: data, mountPath: /pvc}]
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: $claim}
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
printf admin-seed >"$pv_path/admin-seed"
cat >"$evidence/storage-first.yaml" <<STORAGE_EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $sc
  labels: {cubesandbox.io/s32c-owned: "true"}
provisioner: kubernetes.io/no-provisioner
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $pv
  labels: {cubesandbox.io/s32c-owned: "true"}
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
  name: $pvc_first
  labels: {cubesandbox.io/s32c-owned: "true"}
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: $sc
  resources:
    requests: {storage: 64Mi}
STORAGE_EOF
"${kube[@]}" apply -f "$evidence/storage-first.yaml" >"$evidence/apply-storage-first.txt"
"${kube[@]}" get storageclass "$sc" -o json >"$evidence/storageclass-live.json"
"${kube[@]}" get pods -A -o json >"$evidence/pods-before-cases.json"
jq -e '
  .provisioner == "kubernetes.io/no-provisioner" and
  .reclaimPolicy == "Retain" and
  .volumeBindingMode == "WaitForFirstConsumer"
' "$evidence/storageclass-live.json" >/dev/null
jq -e '[
  .items[] |
  ((.spec.initContainers // []) + (.spec.containers // []))[] |
  (((.image // "") + " " + ((.command // []) | join(" ")) + " " + ((.args // []) | join(" "))) |
    select(test("local-(volume|static)-provisioner"; "i")))
] | length == 0' "$evidence/pods-before-cases.json" >/dev/null

cat >"$evidence/pod-failure.yaml" <<FAILURE_EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod_failure
  labels: {cubesandbox.io/s32c-owned: "true"}
spec:
  runtimeClassName: cube
  nodeSelector: {kubernetes.io/hostname: $node}
  tolerations:
  - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
    volumeMounts:
    - {name: data, mountPath: /pvc}
    - {name: bad, mountPath: /bad}
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: $pvc_first}
  - name: bad
    hostPath: {path: /dev/kvm, type: CharDevice}
FAILURE_EOF
"${kube[@]}" create -f "$evidence/pod-failure.yaml" >"$evidence/create-failure.txt"
failure_mount_captured=false
expected_failure='host bind mount source is neither file nor directory: /dev/kvm'
for _ in $(seq 1 1800); do
  "${kube[@]}" get pod "$pod_failure" -o json >"$evidence/pod-failure.json"
  failure_uid=$(jq -r '.metadata.uid' "$evidence/pod-failure.json")
  sandbox_ids=$("${cri[@]}" pods -o json | jq -r --arg uid "$failure_uid" '.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id')
  if test "$(printf '%s\n' "$sandbox_ids" | awk 'NF {n++} END {print n+0}')" -eq 1; then
    failure_sandbox=$sandbox_ids
    if test "$failure_mount_captured" = false; then
      "${cri[@]}" ps -a -o json >"$evidence/failure-containers.candidate.json"
      failure_container_ids=$(jq -r --arg sandbox "$failure_sandbox" '
        .containers[]? | select(.podSandboxId == $sandbox and .metadata.name == "app") | .id
      ' "$evidence/failure-containers.candidate.json")
      if test "$(printf '%s\n' "$failure_container_ids" | awk 'NF {n++} END {print n+0}')" -eq 1; then
        failure_container_id=$failure_container_ids
        if capture_failure_mount_input "$failure_container_id" "$failure_uid"; then
          mv "$evidence/failure-containers.candidate.json" "$evidence/failure-containers.json"
          failure_mount_captured=true
        fi
      fi
    fi
  fi
  if test "$failure_mount_captured" = true && jq -e --arg expected "$expected_failure" '.status.containerStatuses[]? | select(.name == "app") |
    select(
      (.state.waiting.reason == "CreateContainerError" and ((.state.waiting.message // "") | contains($expected))) or
      (.state.terminated.reason == "StartError" and .state.terminated.exitCode == 128 and ((.state.terminated.message // "") | contains($expected)))
    )' "$evidence/pod-failure.json" >/dev/null; then break; fi
  sleep .1
done
test "$failure_mount_captured" = true
jq -e --arg expected "$expected_failure" '.status.containerStatuses[] | select(.name == "app") |
  select(
    (.state.waiting.reason == "CreateContainerError" and ((.state.waiting.message // "") | contains($expected))) or
    (.state.terminated.reason == "StartError" and .state.terminated.exitCode == 128 and ((.state.terminated.message // "") | contains($expected)))
  )' "$evidence/pod-failure.json" >/dev/null
test "$(sandbox_for_uid "$failure_uid")" = "$failure_sandbox"
failure_shared_root=$(active_shared_root)
test -d "$vm_runtime/$failure_sandbox"
"${kube[@]}" get pvc "$pvc_first" -o json >"$evidence/pvc-failure.json"
"${kube[@]}" get pv "$pv" -o json >"$evidence/pv-failure.json"
first_pvc_uid=$(jq -r '.metadata.uid' "$evidence/pvc-failure.json")
pv_uid=$(jq -r '.metadata.uid' "$evidence/pv-failure.json")
test -n "$first_pvc_uid" && test "$first_pvc_uid" != null
test -n "$pv_uid" && test "$pv_uid" != null
assert_bound "$pvc_first" failure "$first_pvc_uid"
zero_samples=0
for _ in $(seq 1 600); do
  if test -e "$failure_shared_root" || test -L "$failure_shared_root"; then
    test -d "$failure_shared_root"
  fi
  test -d "$vm_runtime/$failure_sandbox"
  failed_generations=$(task_generation_count "$failure_shared_root")
  failed_mounts=$(findmnt -rn -o TARGET | awk -v root="$failure_shared_root/" 'index($1, root) == 1 {n++} END {print n+0}')
  if test "$failed_generations" -eq 0 && test "$failed_mounts" -eq 0; then
    zero_samples=$((zero_samples + 1))
    test "$zero_samples" -lt 30 || break
  else
    zero_samples=0
  fi
  sleep .1
done
test "$zero_samples" -ge 30
: >"$evidence/failed-task-tree-before-delete.tsv"
: >"$evidence/failed-shared-root-before-delete.tsv"
if test -d "$failure_shared_root"; then
  if shared_entries=$(find "$failure_shared_root" -mindepth 1 -printf '%P\t%y\t%m\n'); then
    printf 'shared\tpresent\n' >>"$evidence/failed-shared-root-before-delete.tsv"
    printf '%s' "$shared_entries" >>"$evidence/failed-task-tree-before-delete.tsv"
    test -z "$shared_entries" || printf '\n' >>"$evidence/failed-task-tree-before-delete.tsv"
  elif ! test -e "$failure_shared_root" && ! test -L "$failure_shared_root"; then
    printf 'shared\tabsent-cleaned\n' >>"$evidence/failed-shared-root-before-delete.tsv"
  else
    exit 1
  fi
elif test -e "$failure_shared_root" || test -L "$failure_shared_root"; then
  exit 1
else
  printf 'shared\tabsent-cleaned\n' >>"$evidence/failed-shared-root-before-delete.tsv"
fi
sort -o "$evidence/failed-task-tree-before-delete.tsv" "$evidence/failed-task-tree-before-delete.tsv"
: >"$evidence/failed-task-generations-before-delete.txt"
: >"$evidence/failed-task-roots-before-delete.tsv"
for root_name in rootfs volumes; do
  root="$failure_shared_root/$root_name"
  if test -d "$root"; then
    if root_entries=$(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%p\n'); then
      printf '%s\tpresent-empty\n' "$root_name" >>"$evidence/failed-task-roots-before-delete.tsv"
      printf '%s' "$root_entries" >>"$evidence/failed-task-generations-before-delete.txt"
      test -z "$root_entries" || printf '\n' >>"$evidence/failed-task-generations-before-delete.txt"
    elif ! test -e "$root" && ! test -L "$root"; then
      printf '%s\tabsent-cleaned\n' "$root_name" >>"$evidence/failed-task-roots-before-delete.tsv"
    else
      exit 1
    fi
  else
    test ! -e "$root" && test ! -L "$root"
    printf '%s\tabsent-cleaned\n' "$root_name" >>"$evidence/failed-task-roots-before-delete.tsv"
  fi
done
sort -o "$evidence/failed-task-generations-before-delete.txt" "$evidence/failed-task-generations-before-delete.txt"
findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS | awk -v root="$failure_shared_root/" 'index($1, root) == 1' >"$evidence/failed-task-mounts-before-delete.txt"
test ! -s "$evidence/failed-task-generations-before-delete.txt"
test ! -s "$evidence/failed-task-mounts-before-delete.txt"
find "$vm_runtime/$failure_sandbox" -maxdepth 0 -type d -printf '%p\t%y\t%m\n' >"$evidence/failed-vm-before-delete.tsv"
test "$(wc -l <"$evidence/failed-vm-before-delete.tsv")" -eq 1
test "$(cat "$pv_path/admin-seed")" = admin-seed
printf 'S32C_FAILED_TASK_CLEAN sandbox=%s container=%s pvc_before_bad=true expected_error=dev-kvm generations=0 shared_root=present-or-absent-cleaned roots=present-empty-or-absent-cleaned mounts=0 zero_samples=30 vm=alive data=preserved\n' \
  "$failure_sandbox" "$failure_container_id" | tee -a "$evidence/summary.txt"

delete_if_owned pod "$pod_failure"
wait_absent pod "$pod_failure"
for _ in $(seq 1 1200); do test ! -e "/var/lib/kubelet/pods/$failure_uid" && break; sleep .1; done
test ! -e "/var/lib/kubelet/pods/$failure_uid"
wait_runtime_idle
assert_runtime_baseline after-failure
assert_bound "$pvc_first" after-failure "$first_pvc_uid"

write_healthy_pod "$pod_recovery" "$pvc_first" "$evidence/pod-recovery.yaml"
"${kube[@]}" create -f "$evidence/pod-recovery.yaml" >"$evidence/create-recovery.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod_recovery" --timeout=300s >"$evidence/wait-recovery.txt"
"${kube[@]}" get pod "$pod_recovery" -o json >"$evidence/pod-recovery.json"
recovery_uid=$(jq -r '.metadata.uid' "$evidence/pod-recovery.json")
recovery_id=$(container_id "$pod_recovery" app)
recovery_source=$(capture_mount_input recovery "$recovery_id" "$recovery_uid")
"${kube[@]}" exec "$pod_recovery" -c app -- sh -c 'test "$(cat /pvc/admin-seed)" = admin-seed; printf recovery-marker >/pvc/recovery-marker; sync'
test "$(cat "$pv_path/recovery-marker")" = recovery-marker
assert_bound "$pvc_first" recovery "$first_pvc_uid"
delete_if_owned pod "$pod_recovery"
wait_absent pod "$pod_recovery"
for _ in $(seq 1 1200); do test ! -e "/var/lib/kubelet/pods/$recovery_uid" && break; sleep .1; done
test ! -e "/var/lib/kubelet/pods/$recovery_uid"
wait_runtime_idle
assert_runtime_baseline after-recovery
assert_bound "$pvc_first" after-recovery "$first_pvc_uid"

delete_if_owned pvc "$pvc_first"
wait_absent pvc "$pvc_first"
for _ in $(seq 1 1200); do
  "${kube[@]}" get pv "$pv" -o json >"$evidence/pv-released-first.json"
  jq -e --arg uid "$first_pvc_uid" '.status.phase == "Released" and .spec.claimRef.uid == $uid' "$evidence/pv-released-first.json" >/dev/null && break
  sleep .1
done
jq -e --arg pvc "$pvc_first" --arg uid "$first_pvc_uid" '
  .status.phase == "Released" and
  .spec.persistentVolumeReclaimPolicy == "Retain" and
  .spec.claimRef.namespace == "default" and
  .spec.claimRef.name == $pvc and
  .spec.claimRef.uid == $uid
' "$evidence/pv-released-first.json" >/dev/null
test "$(cat "$pv_path/admin-seed")" = admin-seed
test "$(cat "$pv_path/recovery-marker")" = recovery-marker

cat >"$evidence/pvc-second.yaml" <<PVC_EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc_second
  labels: {cubesandbox.io/s32c-owned: "true"}
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: $sc
  volumeName: $pv
  resources:
    requests: {storage: 64Mi}
PVC_EOF
"${kube[@]}" create -f "$evidence/pvc-second.yaml" >"$evidence/create-pvc-second.txt"
write_healthy_pod "$pod_rebind" "$pvc_second" "$evidence/pod-rebind.yaml"
"${kube[@]}" create -f "$evidence/pod-rebind.yaml" >"$evidence/create-rebind.txt"
gate_samples=0
for _ in $(seq 1 100); do
  "${kube[@]}" get pvc "$pvc_second" -o json >"$evidence/pvc-second-before-reclaim.json"
  "${kube[@]}" get pv "$pv" -o json >"$evidence/pv-before-reclaim.json"
  "${kube[@]}" get pod "$pod_rebind" -o json >"$evidence/pod-rebind-before-reclaim.json"
  if jq -e --arg pv "$pv" '.status.phase == "Pending" and .spec.volumeName == $pv' "$evidence/pvc-second-before-reclaim.json" >/dev/null \
    && jq -e --arg uid "$first_pvc_uid" '.status.phase == "Released" and .spec.claimRef.uid == $uid' "$evidence/pv-before-reclaim.json" >/dev/null \
    && jq -e '.status.phase == "Pending" and (.spec.nodeName == null)' "$evidence/pod-rebind-before-reclaim.json" >/dev/null; then
    gate_samples=$((gate_samples + 1))
    test "$gate_samples" -lt 30 || break
  else
    gate_samples=0
  fi
  sleep .1
done
test "$gate_samples" -ge 30
second_pvc_uid=$(jq -r '.metadata.uid' "$evidence/pvc-second-before-reclaim.json")
rebind_uid=$(jq -r '.metadata.uid' "$evidence/pod-rebind-before-reclaim.json")
test -n "$second_pvc_uid" && test "$second_pvc_uid" != null
test "$second_pvc_uid" != "$first_pvc_uid"
jq -e --arg pv "$pv" '.status.phase == "Pending" and .spec.volumeName == $pv' "$evidence/pvc-second-before-reclaim.json" >/dev/null
jq -e --arg uid "$first_pvc_uid" '.status.phase == "Released" and .spec.claimRef.uid == $uid' "$evidence/pv-before-reclaim.json" >/dev/null
jq -e '.status.phase == "Pending" and (.spec.nodeName == null)' "$evidence/pod-rebind-before-reclaim.json" >/dev/null
"${cri[@]}" pods -o json >"$evidence/sandboxes-before-reclaim.json"
jq -e --arg uid "$rebind_uid" '[.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid)] | length == 0' "$evidence/sandboxes-before-reclaim.json" >/dev/null
"${kube[@]}" get events --field-selector "involvedObject.uid=$second_pvc_uid" -o json >"$evidence/pvc-second-events-before-reclaim.json"
"${kube[@]}" get events --field-selector "involvedObject.uid=$rebind_uid" -o json >"$evidence/pod-rebind-events-before-reclaim.json"

"${kube[@]}" patch pv "$pv" --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]' >"$evidence/patch-remove-claimref.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod_rebind" --timeout=300s >"$evidence/wait-rebind.txt"
"${kube[@]}" get pod "$pod_rebind" -o json >"$evidence/pod-rebind.json"
assert_bound "$pvc_second" rebound "$second_pvc_uid"
rebind_id=$(container_id "$pod_rebind" app)
rebind_source=$(capture_mount_input rebind "$rebind_id" "$rebind_uid")
test "$rebind_source" != "$recovery_source"
"${kube[@]}" exec "$pod_rebind" -c app -- sh -c '
  test "$(cat /pvc/admin-seed)" = admin-seed
  test "$(cat /pvc/recovery-marker)" = recovery-marker
  printf rebind-marker >/pvc/rebind-marker
  sync
'
test "$(cat "$pv_path/rebind-marker")" = rebind-marker

delete_if_owned pod "$pod_rebind"
wait_absent pod "$pod_rebind"
for _ in $(seq 1 1200); do test ! -e "/var/lib/kubelet/pods/$rebind_uid" && break; sleep .1; done
test ! -e "/var/lib/kubelet/pods/$rebind_uid"
wait_runtime_idle
assert_runtime_baseline after-rebind
assert_bound "$pvc_second" after-rebind "$second_pvc_uid"
for marker in admin-seed recovery-marker rebind-marker; do test "$(cat "$pv_path/$marker")" = "$marker"; done
(cd "$pv_path" && sha256sum admin-seed recovery-marker rebind-marker) >"$evidence/data-before-final-cleanup.sha256"
test "$(wc -l <"$evidence/data-before-final-cleanup.sha256")" -eq 3
test $(( $(lease_records) - leases_before )) -eq 3

printf 'backend\tprovisioner\treclaim_policy\tstatus\tevidence\n' >"$evidence/reclaim-support.tsv"
printf 'static-local\tkubernetes.io/no-provisioner\tRetain\tSUPPORTED_MANUAL\tReleased claimRef gate; admin claimRef removal; new PVC UID rebound with data\n' >>"$evidence/reclaim-support.tsv"
printf 'static-local\tkubernetes.io/no-provisioner\tDelete\tNOT_APPLICABLE_WITHOUT_DELETER\tno dynamic or external local provisioner is installed; not claimed\n' >>"$evidence/reclaim-support.tsv"
printf 'S32C_RETAIN_REBIND_OK pv_uid=%s first_pvc_uid=%s second_pvc_uid=%s released_gate=true pending_has_no_sandbox=true pending_no_sandbox_evidence=true admin_claimref_remove=true data_preserved=true data_hashes=3 delete_backend=not-applicable-without-deleter\n' \
  "$pv_uid" "$first_pvc_uid" "$second_pvc_uid" | tee -a "$evidence/summary.txt"

delete_if_owned pvc "$pvc_second"
wait_absent pvc "$pvc_second"
for _ in $(seq 1 1200); do
  "${kube[@]}" get pv "$pv" -o json >"$evidence/pv-released-second.json"
  jq -e --arg uid "$second_pvc_uid" '.status.phase == "Released" and .spec.claimRef.uid == $uid' "$evidence/pv-released-second.json" >/dev/null && break
  sleep .1
done
jq -e --arg uid "$second_pvc_uid" '.status.phase == "Released" and .spec.claimRef.uid == $uid and .spec.persistentVolumeReclaimPolicy == "Retain"' "$evidence/pv-released-second.json" >/dev/null
for marker in admin-seed recovery-marker rebind-marker; do test "$(cat "$pv_path/$marker")" = "$marker"; done
delete_if_owned pv "$pv"
wait_absent pv "$pv"
delete_if_owned storageclass "$sc"
wait_absent storageclass "$sc"
remove_pv_path
assert_baseline after
test $(( $(lease_records) - leases_before )) -eq 3
printf 'S32C_DONE active_leases=0 durable_tombstone_delta=3 kubelet_pod_dirs=removed evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1
journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1
trap - ERR EXIT
