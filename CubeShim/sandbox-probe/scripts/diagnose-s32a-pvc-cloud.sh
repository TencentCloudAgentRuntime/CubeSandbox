#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=15s)
cleanup_kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=2s)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
sc=cubesandbox-s32a-local
pv=cubesandbox-s32a-local-pv
pvc=cubesandbox-s32a-local-pvc
pod_runc=cubesandbox-s32a-runc
pod_cube=cubesandbox-s32a-cube
pv_parent=/data/cubelet/s3.2-pv
pv_path=$pv_parent/s32a-local
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.2-evidence/s3.2a-pvc-diagnostic-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
runc_uid=
cube_uid=
pv_parent_state_captured=false
pv_parent_existed_before=false

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
      printf 'S32A_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
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
  test "$(jq -r '.metadata.labels["cubesandbox.io/s32a-owned"] // ""' <<<"$object")" = true || return 1
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

delete_owned_objects() {
  local rc=0
  delete_if_owned pod "$pod_runc" || rc=1
  delete_if_owned pod "$pod_cube" || rc=1
  wait_absent pod "$pod_runc" || rc=1
  wait_absent pod "$pod_cube" || rc=1
  delete_if_owned pvc "$pvc" || rc=1
  wait_absent pvc "$pvc" || rc=1
  delete_if_owned pv "$pv" || rc=1
  wait_absent pv "$pv" || rc=1
  delete_if_owned storageclass "$sc" || rc=1
  wait_absent storageclass "$sc" || rc=1
  fixed_objects_absent || rc=1
  return "$rc"
}

fixed_objects_absent() {
  local rc=0
  object_absent pod "$pod_runc" || rc=1
  object_absent pod "$pod_cube" || rc=1
  object_absent pvc "$pvc" || rc=1
  object_absent pv "$pv" || rc=1
  object_absent storageclass "$sc" || rc=1
  return "$rc"
}

remove_pv_path() {
  local mount_refs
  mount_refs=$(findmnt -rn -o TARGET,SOURCE | awk -v path="$pv_path" 'index($1, path) || index($2, path) {n++} END {print n+0}')
  test "$mount_refs" -eq 0
  if test -d "$pv_path"; then
    rm -f "$pv_path/runc-marker" "$pv_path/cube-marker"
    rmdir "$pv_path"
  fi
  if test "$pv_parent_state_captured" = true && test "$pv_parent_existed_before" = false && test -d "$pv_parent"; then
    rmdir "$pv_parent"
  fi
}

container_id() {
  "${kube[@]}" get pod "$1" -o json | jq -r '.status.containerStatuses[] | select(.name == "app" and .state.running != null) | .containerID | sub("^containerd://"; "")'
}

capture_mount_input() {
  local runtime=$1 id=$2 uid=$3 source
  "${cri[@]}" inspect "$id" >"$evidence/cri-$runtime.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$runtime.json"
  jq -r '(.info.runtimeSpec.mounts // [])[] | select(.destination == "/pvc") | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/cri-$runtime.json" >"$evidence/mount-$runtime-cri.tsv"
  jq -r '(.Spec.mounts // [])[] | select(.destination == "/pvc") | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/ctr-$runtime.json" >"$evidence/mount-$runtime-ctr.tsv"
  cmp "$evidence/mount-$runtime-cri.tsv" "$evidence/mount-$runtime-ctr.tsv"
  test "$(wc -l <"$evidence/mount-$runtime-cri.tsv")" -eq 1
  source=$(awk -F '\t' '$1 == "/pvc" && $2 == "bind" && ("," $4 ",") !~ /,ro,/ {print $3}' "$evidence/mount-$runtime-cri.tsv")
  test -n "$source" && test -d "$source"
  case "$source" in
    "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~local-volume/$pv") ;;
    *) return 1 ;;
  esac
  findmnt -rn -M "$source" -o TARGET,SOURCE,FSTYPE,OPTIONS >"$evidence/findmnt-$runtime-pvc.txt"
  test -s "$evidence/findmnt-$runtime-pvc.txt"
  printf '%s\n' "$source"
}

write_pod_manifest() {
  local name=$1 runtime_class=$2 target=$3
  cat >"$target" <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels: {cubesandbox.io/s32a-owned: "true"}
spec:
${runtime_class}
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
"${kube[@]}" get storageclass,csidriver,pv -o yaml >"$evidence/storage-api-before.yaml"
"${kube[@]}" get csinode -o yaml >"$evidence/csinodes-before.yaml"
"${kube[@]}" get volumeattachment -o yaml >"$evidence/volumeattachments-before.yaml"
{ if test -d /var/lib/kubelet/plugins_registry; then find /var/lib/kubelet/plugins_registry -mindepth 1 -maxdepth 2 -printf '%P\t%y\n'; fi; } \
  | sort >"$evidence/plugin-registry-before.tsv"
{ if test -d /var/lib/kubelet/plugins; then find /var/lib/kubelet/plugins -mindepth 1 -maxdepth 3 -printf '%P\t%y\n'; fi; } \
  | sort >"$evidence/plugins-before.tsv"

install -d -m 0777 "$pv_path"
cat >"$evidence/storage.yaml" <<STORAGE_EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $sc
  labels: {cubesandbox.io/s32a-owned: "true"}
provisioner: kubernetes.io/no-provisioner
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $pv
  labels: {cubesandbox.io/s32a-owned: "true"}
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
  labels: {cubesandbox.io/s32a-owned: "true"}
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: $sc
  resources:
    requests: {storage: 64Mi}
STORAGE_EOF
"${kube[@]}" apply -f "$evidence/storage.yaml" >"$evidence/apply-storage.txt"
"${kube[@]}" get storageclass "$sc" -o json >"$evidence/storageclass-live.json"
prebind_deadline=$((SECONDS + 60))
while test "$SECONDS" -lt "$prebind_deadline"; do
  "${kube[@]}" get pv "$pv" -o json >"$evidence/pv-before-consumer.json"
  "${kube[@]}" get pvc "$pvc" -o json >"$evidence/pvc-before-consumer.json"
  if jq -e '.status.phase == "Available" and (.spec.claimRef == null)' "$evidence/pv-before-consumer.json" >/dev/null \
    && jq -e '.status.phase == "Pending" and ((.spec.volumeName // "") == "")' "$evidence/pvc-before-consumer.json" >/dev/null; then
    break
  fi
  sleep .1
done
jq -e '
  .provisioner == "kubernetes.io/no-provisioner" and
  .volumeBindingMode == "WaitForFirstConsumer" and
  .reclaimPolicy == "Retain"
' "$evidence/storageclass-live.json" >/dev/null
jq -e --arg path "$pv_path" --arg sc "$sc" --arg node "$node" '
  .status.phase == "Available" and
  .spec.local.path == $path and
  .spec.storageClassName == $sc and
  .spec.persistentVolumeReclaimPolicy == "Retain" and
  .spec.volumeMode == "Filesystem" and
  .spec.accessModes == ["ReadWriteOnce"] and
  .spec.capacity.storage == "1Gi" and
  (.spec.claimRef == null) and
  any(.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?;
    .key == "kubernetes.io/hostname" and .operator == "In" and .values == [$node])
' "$evidence/pv-before-consumer.json" >/dev/null
jq -e --arg sc "$sc" '
  .status.phase == "Pending" and
  .spec.storageClassName == $sc and
  .spec.volumeMode == "Filesystem" and
  .spec.accessModes == ["ReadWriteOnce"] and
  .spec.resources.requests.storage == "64Mi" and
  ((.spec.volumeName // "") == "")
' "$evidence/pvc-before-consumer.json" >/dev/null

write_pod_manifest "$pod_runc" "" "$evidence/pod-runc.yaml"
"${kube[@]}" apply -f "$evidence/pod-runc.yaml" >"$evidence/apply-runc.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod_runc" --timeout=300s >"$evidence/wait-runc.txt"
"${kube[@]}" get pod "$pod_runc" -o json >"$evidence/pod-runc.json"
"${kube[@]}" get pvc "$pvc" -o json >"$evidence/pvc-bound-runc.json"
"${kube[@]}" get pv "$pv" -o json >"$evidence/pv-bound-runc.json"
jq -e --arg pv "$pv" '.status.phase == "Bound" and .spec.volumeName == $pv' "$evidence/pvc-bound-runc.json" >/dev/null
jq -e --arg node "$node" '.spec.nodeName == $node and .status.phase == "Running"' "$evidence/pod-runc.json" >/dev/null
pvc_uid=$(jq -r '.metadata.uid' "$evidence/pvc-bound-runc.json")
test -n "$pvc_uid" && test "$pvc_uid" != null
jq -e --arg pv "$pv" '
  .status.phase == "Bound" and
  .spec.volumeName == $pv
' "$evidence/pvc-bound-runc.json" >/dev/null
jq -e --arg pvc "$pvc" --arg uid "$pvc_uid" '
  .status.phase == "Bound" and
  .spec.claimRef.namespace == "default" and
  .spec.claimRef.name == $pvc and
  .spec.claimRef.uid == $uid
' "$evidence/pv-bound-runc.json" >/dev/null
runc_uid=$(jq -r '.metadata.uid' "$evidence/pod-runc.json")
runc_id=$(container_id "$pod_runc")
runc_source=$(capture_mount_input runc "$runc_id" "$runc_uid")
"${kube[@]}" exec "$pod_runc" -c app -- sh -c 'printf runc-persist >/pvc/runc-marker; test "$(cat /pvc/runc-marker)" = runc-persist'
test "$(cat "$pv_path/runc-marker")" = runc-persist

delete_if_owned pod "$pod_runc"
wait_absent pod "$pod_runc"
for _ in $(seq 1 1200); do test ! -e "/var/lib/kubelet/pods/$runc_uid" && break; sleep .1; done
test ! -e "/var/lib/kubelet/pods/$runc_uid"
test "$("${kube[@]}" get pvc "$pvc" -o jsonpath='{.status.phase}')" = Bound
test "$("${kube[@]}" get pv "$pv" -o jsonpath='{.status.phase}')" = Bound

write_pod_manifest "$pod_cube" "  runtimeClassName: cube" "$evidence/pod-cube.yaml"
"${kube[@]}" apply -f "$evidence/pod-cube.yaml" >"$evidence/apply-cube.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod_cube" --timeout=300s >"$evidence/wait-cube.txt"
"${kube[@]}" get pod "$pod_cube" -o json >"$evidence/pod-cube.json"
cube_uid=$(jq -r '.metadata.uid' "$evidence/pod-cube.json")
jq -e --arg node "$node" '.spec.nodeName == $node and .status.phase == "Running"' "$evidence/pod-cube.json" >/dev/null
cube_id=$(container_id "$pod_cube")
cube_source=$(capture_mount_input cube "$cube_id" "$cube_uid")
"${kube[@]}" exec "$pod_cube" -c app -- sh -c 'test "$(cat /pvc/runc-marker)" = runc-persist; printf cube-persist >/pvc/cube-marker'
test "$(cat "$pv_path/cube-marker")" = cube-persist
"${kube[@]}" exec "$pod_cube" -c app -- cat /proc/self/mountinfo >"$evidence/guest-mountinfo-cube.txt"
awk '$5 == "/pvc" && $6 ~ /(^|,)rw(,|$)/ && $0 ~ / - virtiofs cubeVolumes / {found++} END {exit found != 1}' "$evidence/guest-mountinfo-cube.txt"
"${kube[@]}" get pvc "$pvc" -o json >"$evidence/pvc-bound-cube.json"
"${kube[@]}" get pv "$pv" -o json >"$evidence/pv-bound-cube.json"
jq -e --arg pv "$pv" '.status.phase == "Bound" and .spec.volumeName == $pv' "$evidence/pvc-bound-cube.json" >/dev/null
jq -e --arg uid "$pvc_uid" '.metadata.uid == $uid and .status.phase == "Bound"' "$evidence/pvc-bound-cube.json" >/dev/null
jq -e --arg pvc "$pvc" --arg uid "$pvc_uid" '
  .status.phase == "Bound" and
  .spec.claimRef.namespace == "default" and
  .spec.claimRef.name == $pvc and
  .spec.claimRef.uid == $uid
' "$evidence/pv-bound-cube.json" >/dev/null

printf 'runtime\tuid\tcontainer_id\toci_source\n' >"$evidence/runtime-inputs.tsv"
printf 'runc\t%s\t%s\t%s\n' "$runc_uid" "$runc_id" "$runc_source" >>"$evidence/runtime-inputs.tsv"
printf 'cube\t%s\t%s\t%s\n' "$cube_uid" "$cube_id" "$cube_source" >>"$evidence/runtime-inputs.tsv"

delete_if_owned pod "$pod_cube"
wait_absent pod "$pod_cube"
for _ in $(seq 1 1200); do test ! -e "/var/lib/kubelet/pods/$cube_uid" && break; sleep .1; done
test ! -e "/var/lib/kubelet/pods/$cube_uid"
wait_runtime_idle
test "$(cat "$pv_path/runc-marker")" = runc-persist
test "$(cat "$pv_path/cube-marker")" = cube-persist
test $(( $(lease_records) - leases_before )) -eq 1

delete_if_owned pvc "$pvc"
wait_absent pvc "$pvc"
for _ in $(seq 1 1200); do
  "${kube[@]}" get pv "$pv" -o json >"$evidence/pv-after-pvc-delete.json"
  jq -e '.status.phase == "Released"' "$evidence/pv-after-pvc-delete.json" >/dev/null && break
  sleep .1
done
jq -e '.status.phase == "Released" and .spec.persistentVolumeReclaimPolicy == "Retain"' "$evidence/pv-after-pvc-delete.json" >/dev/null
test "$(cat "$pv_path/runc-marker")" = runc-persist
test "$(cat "$pv_path/cube-marker")" = cube-persist
delete_if_owned pv "$pv"
wait_absent pv "$pv"
delete_if_owned storageclass "$sc"
wait_absent storageclass "$sc"
remove_pv_path
assert_baseline after
test $(( $(lease_records) - leases_before )) -eq 1
printf 'S32A_PVC_INPUT_OK backend=static-local filesystem=true access=RWO binding=WaitForFirstConsumer cri_oci_match=true runc_rw=true cube_rw=true cross_runtime_persist=true guest=virtiofs-cubeVolumes reclaim=Retain standard_bind=true\n' | tee -a "$evidence/summary.txt"
printf 'S32A_DONE active_leases=0 durable_tombstone_delta=1 kubelet_pod_dirs=removed evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1
journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1
trap - ERR EXIT
