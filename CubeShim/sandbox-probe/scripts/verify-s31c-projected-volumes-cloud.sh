#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
pod_runc=cubesandbox-s31c-runc
pod_cube=cubesandbox-s31c-cube
pods=("$pod_runc" "$pod_cube")
config=cubesandbox-s31c-config
secret=cubesandbox-s31c-secret
config_volume=config
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.1-evidence/s3.1c-projected-$(date -u +%Y%m%dT%H%M%SZ)
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
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s lease_records=%s\n' \
    "$(count_files "$runtime_state/adapter")" "$(count_entries "$shared")" "$(count_entries "$reaper")" \
    "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" \
    "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" "$(active_leases)" "$(lease_records)" \
    >"$evidence/resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
  test "$(count_files "$runtime_state/adapter")" -eq 0 \
    && test "$(count_entries "$shared")" -eq 0 \
    && test "$(count_entries "$reaper")" -eq 0 \
    && test "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0 \
    && test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0 \
    && test "$(active_leases)" -eq 0
}

assert_baseline() {
  local tag=$1 attempt kind
  for attempt in $(seq 1 1200); do
    capture_state "$tag"
    if state_matches_baseline "$tag"; then
      printf 'S31C_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' "$tag" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep .1
  done
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime resources; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" >"$evidence/$kind-$tag.diff" 2>&1 || true
  done
  return 1
}

is_owned() {
  test "$("${kube[@]}" get "$1" "$2" -o jsonpath='{.metadata.labels.cubesandbox\.io/s31c-owned}' 2>/dev/null)" = true
}

delete_owned_objects() {
  local name kind
  for name in "${pods[@]}"; do
    if "${kube[@]}" get pod "$name" >/dev/null 2>&1; then
      is_owned pod "$name" || return 1
      "${kube[@]}" delete pod "$name" --grace-period=0 --force --wait=false >/dev/null
    fi
  done
  for _ in $(seq 1 1200); do
    if ! "${kube[@]}" get pod "$pod_runc" >/dev/null 2>&1 && ! "${kube[@]}" get pod "$pod_cube" >/dev/null 2>&1; then break; fi
    sleep .1
  done
  ! "${kube[@]}" get pod "$pod_runc" >/dev/null 2>&1
  ! "${kube[@]}" get pod "$pod_cube" >/dev/null 2>&1
  for kind in configmap secret; do
    name=$config
    test "$kind" = secret && name=$secret
    if "${kube[@]}" get "$kind" "$name" >/dev/null 2>&1; then
      is_owned "$kind" "$name" || return 1
      "${kube[@]}" delete "$kind" "$name" --wait=true >/dev/null
    fi
  done
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
    sleep .1
  done
  return 1
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

container_id() {
  "${kube[@]}" get pod "$1" -o json | jq -r --arg name "$2" \
    '.status.containerStatuses[] | select(.name == $name and .state.running != null) | .containerID | sub("^containerd://"; "")'
}

read_path() {
  "${kube[@]}" exec "$1" -c "$2" -- cat "$3" 2>/dev/null | tr -d '\r\n'
}

assert_stat() {
  local actual
  actual=$("${kube[@]}" exec "$1" -c "$2" -- stat -L -c '%a:%u:%g' "$3" | tr -d '\r\n')
  test "$actual" = "$4:0:0"
}

capture_atomic_guest() {
  "${kube[@]}" exec "$2" -c writer -- sh -c '
    for entry in config:/vol/config secret:/vol/secret projected:/vol/projected downward:/vol/downward; do
      name=${entry%%:*}; path=${entry#*:}
      printf "%s\t%s\t%s\n" "$name" "$(readlink "$path/..data")" "$(stat -L -c "%d:%i" "$path/..data")"
    done
  ' | tr -d '\r' >"$evidence/atomic-guest-$1-$3.tsv"
}

capture_cube_mount_input() {
  local name=$1 id=$2
  "${cri[@]}" inspect "$id" >"$evidence/cri-cube-$name.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-cube-$name.json"
  jq -r '(.info.runtimeSpec.mounts // [])[] | select((.destination // "") | startswith("/vol/") or startswith("/peer/")) | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/cri-cube-$name.json" | sort >"$evidence/mounts-cube-$name-cri.tsv"
  jq -r '(.Spec.mounts // [])[] | select((.destination // "") | startswith("/vol/") or startswith("/peer/")) | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/ctr-cube-$name.json" | sort >"$evidence/mounts-cube-$name-ctr.tsv"
  cmp "$evidence/mounts-cube-$name-cri.tsv" "$evidence/mounts-cube-$name-ctr.tsv"
}

capture_atomic_host() {
  local tag=$1 name destination source
  : >"$evidence/atomic-host-$tag.tsv"
  for name in config secret projected downward; do
    destination=/vol/$name
    source=$(awk -F '\t' -v destination="$destination" '$1 == destination {print $3}' "$evidence/mounts-cube-writer-cri.tsv")
    test -d "$source"
    printf '%s\t%s\t%s\n' "$name" "$(readlink "$source/..data")" "$(stat -L -c '%d:%i' "$source/..data")" >>"$evidence/atomic-host-$tag.tsv"
  done
}

capture_host_mounts() {
  local tag=$1
  findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS \
    | awk -v root="$shared_root/" 'index($1, root) == 1' \
    | sort >"$evidence/host-mounts-$tag.txt"
  findmnt -rn -o ID,TARGET,FSTYPE,OPTIONS \
    | awk -v root="$shared_root/" 'index($2, root) == 1' \
    | sort >"$evidence/host-mount-identities-$tag.txt"
}

assert_host_mounts_continuous() {
  local deleted_count allowed_deleted_count
  cmp "$evidence/host-mount-identities-before.txt" "$evidence/host-mount-identities-after.txt"

  # The Cube Pod's ConfigMap subPath bind keeps the old inode by design. Once
  # kubelet's atomic writer removes that old generation, findmnt renders the
  # same source with a //deleted suffix even though the mount ID and mount
  # properties did not change. Allow exactly that source-only transition.
  deleted_count=$(awk '$2 ~ /\/\/deleted\]$/ {n++} END {print n+0}' "$evidence/host-mounts-after.txt")
  allowed_deleted_count=$(awk -v expected="/var/lib/kubelet/pods/$cube_uid/volumes/kubernetes.io~configmap/$config_volume/" '
    $2 ~ /\/key\.txt\/\/deleted\]$/ && index($2, "[" expected) > 0 {n++}
    END {print n+0}
  ' "$evidence/host-mounts-after.txt")
  test "$deleted_count" -eq 1
  test "$allowed_deleted_count" -eq 1
  sed 's#//deleted]#]#' "$evidence/host-mounts-after.txt" >"$evidence/host-mounts-after-normalized.txt"
  cmp "$evidence/host-mounts-before.txt" "$evidence/host-mounts-after-normalized.txt"
}

assert_atomic_changed() {
  local before=$1 after=$2 name old_target old_inode new_target new_inode
  while IFS=$'\t' read -r name old_target old_inode; do
    new_target=$(awk -F '\t' -v name="$name" '$1 == name {print $2}' "$after")
    new_inode=$(awk -F '\t' -v name="$name" '$1 == name {print $3}' "$after")
    test -n "$new_target" && test -n "$new_inode"
    test "$new_target" != "$old_target"
    test "$new_inode" != "$old_inode"
  done <"$before"
}

projection_updated() {
  local pod=$1
  "${kube[@]}" exec "$pod" -c writer -- sh -c '
    test "$(cat /vol/config/key.txt)" = config-v2 &&
    test "$(cat /vol/config/mode.txt)" = config-mode-v2 &&
    test "$(cat /vol/secret/secret.txt)" = secret-v2 &&
    test "$(cat /vol/secret/mode.txt)" = secret-mode-v2 &&
    test "$(cat /vol/projected/config.txt)" = config-v2 &&
    test "$(cat /vol/projected/secret.txt)" = secret-v2 &&
    grep -F '\''cubesandbox.io/volume-generation="v2"'\'' /vol/projected/labels >/dev/null &&
    grep -F '\''cubesandbox.io/volume-generation="v2"'\'' /vol/downward/labels >/dev/null
  ' >/dev/null 2>&1 || return 1
  "${kube[@]}" exec "$pod" -c peer -- sh -c '
    test "$(cat /peer/config/key.txt)" = config-v2 &&
    test "$(cat /peer/config/mode.txt)" = config-mode-v2 &&
    test "$(cat /peer/secret/secret.txt)" = secret-v2 &&
    test "$(cat /peer/secret/mode.txt)" = secret-mode-v2 &&
    test "$(cat /peer/projected/config.txt)" = config-v2 &&
    test "$(cat /peer/projected/secret.txt)" = secret-v2 &&
    test "$(cat /peer/downward/podname)" = "$1" &&
    grep -F '\''cubesandbox.io/volume-generation="v2"'\'' /peer/projected/labels >/dev/null &&
    grep -F '\''cubesandbox.io/volume-generation="v2"'\'' /peer/downward/labels >/dev/null
  ' sh "$pod" >/dev/null 2>&1
}

write_pod_manifest() {
  local name=$1 runtime_class=$2 target=$3
  cat >"$target" <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    cubesandbox.io/s31c-owned: "true"
    cubesandbox.io/volume-generation: "v1"
spec:
${runtime_class}
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: writer
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
    volumeMounts:
    - {name: config, mountPath: /vol/config, readOnly: true}
    - {name: secret, mountPath: /vol/secret, readOnly: true}
    - {name: projected, mountPath: /vol/projected, readOnly: true}
    - {name: downward, mountPath: /vol/downward, readOnly: true}
    - {name: config, mountPath: /vol/sub/config-key, subPath: key.txt, readOnly: true}
  - name: peer
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
    volumeMounts:
    - {name: config, mountPath: /peer/config, readOnly: true}
    - {name: secret, mountPath: /peer/secret, readOnly: true}
    - {name: projected, mountPath: /peer/projected, readOnly: true}
    - {name: downward, mountPath: /peer/downward, readOnly: true}
  volumes:
  - name: config
    configMap:
      name: $config
      defaultMode: 0444
      items:
      - {key: key.txt, path: key.txt}
      - {key: mode.txt, path: mode.txt, mode: 0420}
  - name: secret
    secret:
      secretName: $secret
      defaultMode: 0400
      items:
      - {key: secret.txt, path: secret.txt}
      - {key: mode.txt, path: mode.txt, mode: 0440}
  - name: projected
    projected:
      defaultMode: 0440
      sources:
      - configMap:
          name: $config
          items: [{key: key.txt, path: config.txt, mode: 0404}]
      - secret:
          name: $secret
          items: [{key: secret.txt, path: secret.txt}]
      - downwardAPI:
          items:
          - path: labels
            mode: 0444
            fieldRef: {fieldPath: metadata.labels}
  - name: downward
    downwardAPI:
      defaultMode: 0444
      items:
      - path: podname
        fieldRef: {fieldPath: metadata.name}
      - path: labels
        fieldRef: {fieldPath: metadata.labels}
POD_EOF
}

cleanup() {
  local rc=$?
  set +e
  for name in "${pods[@]}"; do "${kube[@]}" get pod "$name" -o json >"$evidence/$name-final.json" 2>&1 || true; done
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  delete_owned_objects
  wait_runtime_idle
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT
delete_owned_objects
wait_runtime_idle
capture_state before
leases_before=$(lease_records)

"${kube[@]}" apply -f - >"$evidence/apply-resources.txt" <<RESOURCE_EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $config
  labels: {cubesandbox.io/s31c-owned: "true"}
data:
  key.txt: config-v1
  mode.txt: config-mode-v1
---
apiVersion: v1
kind: Secret
metadata:
  name: $secret
  labels: {cubesandbox.io/s31c-owned: "true"}
type: Opaque
stringData:
  secret.txt: secret-v1
  mode.txt: secret-mode-v1
RESOURCE_EOF

write_pod_manifest "$pod_runc" "" "$evidence/pod-runc.yaml"
write_pod_manifest "$pod_cube" "  runtimeClassName: cube" "$evidence/pod-cube.yaml"
"${kube[@]}" apply -f "$evidence/pod-runc.yaml" >"$evidence/apply-pod-runc.txt"
"${kube[@]}" apply -f "$evidence/pod-cube.yaml" >"$evidence/apply-pod-cube.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod_runc" --timeout=180s >"$evidence/wait-runc.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod_cube" --timeout=300s >"$evidence/wait-cube.txt"
"${kube[@]}" get pod "$pod_runc" -o json >"$evidence/pod-runc-initial.json"
"${kube[@]}" get pod "$pod_cube" -o json >"$evidence/pod-cube-initial.json"
runc_uid=$(jq -r '.metadata.uid' "$evidence/pod-runc-initial.json")
cube_uid=$(jq -r '.metadata.uid' "$evidence/pod-cube-initial.json")
cube_sandbox=$(sandbox_for_uid "$cube_uid")
cube_shim=$(shim_pid_for_sandbox "$cube_sandbox")
cube_shim_start=$(awk '{print $22}' "/proc/$cube_shim/stat")
cube_vm_inode=$(stat -Lc '%d:%i' "$vm_runtime/$cube_sandbox")
shared_root=$(find "$shared" -mindepth 1 -maxdepth 1 -type d -print)
test "$(printf '%s\n' "$shared_root" | awk 'NF {n++} END {print n+0}')" -eq 1
volume_inode=$(stat -Lc '%d:%i' "$shared_root/volumes")
find "$shared_root/rootfs" "$shared_root/volumes" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' 2>/dev/null | sort >"$evidence/task-generations-before.txt"
capture_host_mounts before

cube_writer_id=$(container_id "$pod_cube" writer)
cube_peer_id=$(container_id "$pod_cube" peer)
capture_cube_mount_input writer "$cube_writer_id"
capture_cube_mount_input peer "$cube_peer_id"
test "$(wc -l <"$evidence/mounts-cube-writer-cri.tsv")" -eq 5
test "$(wc -l <"$evidence/mounts-cube-peer-cri.tsv")" -eq 4
for destination in /vol/config /vol/secret /vol/projected /vol/downward /vol/sub/config-key; do
  test "$(awk -F '\t' -v destination="$destination" '$1 == destination && $2 == "bind" && ("," $4 ",") ~ /,ro,/ {n++} END {print n+0}' "$evidence/mounts-cube-writer-cri.tsv")" -eq 1
done
for name in config secret projected downward; do
  writer_source=$(awk -F '\t' -v destination="/vol/$name" '$1 == destination {print $3}' "$evidence/mounts-cube-writer-cri.tsv")
  peer_source=$(awk -F '\t' -v destination="/peer/$name" '$1 == destination && $2 == "bind" && ("," $4 ",") ~ /,ro,/ {print $3}' "$evidence/mounts-cube-peer-cri.tsv")
  test -n "$writer_source" && test "$peer_source" = "$writer_source"
done
"${kube[@]}" exec "$pod_cube" -c writer -- cat /proc/self/mountinfo >"$evidence/mountinfo-cube-writer.txt"
"${kube[@]}" exec "$pod_cube" -c peer -- cat /proc/self/mountinfo >"$evidence/mountinfo-cube-peer.txt"
for destination in /vol/config /vol/secret /vol/projected /vol/downward /vol/sub/config-key; do
  awk -v destination="$destination" '$5 == destination && $6 ~ /(^|,)ro(,|$)/ && $0 ~ / - virtiofs cubeVolumes / {found++} END {exit found != 1}' "$evidence/mountinfo-cube-writer.txt"
done
for destination in /peer/config /peer/secret /peer/projected /peer/downward; do
  awk -v destination="$destination" '$5 == destination && $6 ~ /(^|,)ro(,|$)/ && $0 ~ / - virtiofs cubeVolumes / {found++} END {exit found != 1}' "$evidence/mountinfo-cube-peer.txt"
done

for runtime in runc cube; do
  pod=$pod_runc
  test "$runtime" = cube && pod=$pod_cube
  test "$(read_path "$pod" writer /vol/config/key.txt)" = config-v1
  test "$(read_path "$pod" writer /vol/config/mode.txt)" = config-mode-v1
  test "$(read_path "$pod" writer /vol/secret/secret.txt)" = secret-v1
  test "$(read_path "$pod" writer /vol/secret/mode.txt)" = secret-mode-v1
  test "$(read_path "$pod" writer /vol/projected/config.txt)" = config-v1
  test "$(read_path "$pod" writer /vol/projected/secret.txt)" = secret-v1
  test "$(read_path "$pod" writer /vol/downward/podname)" = "$pod"
  test "$(read_path "$pod" writer /vol/sub/config-key)" = config-v1
  test "$(read_path "$pod" peer /peer/config/key.txt)" = config-v1
  test "$(read_path "$pod" peer /peer/config/mode.txt)" = config-mode-v1
  test "$(read_path "$pod" peer /peer/secret/secret.txt)" = secret-v1
  test "$(read_path "$pod" peer /peer/secret/mode.txt)" = secret-mode-v1
  test "$(read_path "$pod" peer /peer/projected/config.txt)" = config-v1
  test "$(read_path "$pod" peer /peer/projected/secret.txt)" = secret-v1
  test "$(read_path "$pod" peer /peer/downward/podname)" = "$pod"
  "${kube[@]}" exec "$pod" -c writer -- grep -F 'cubesandbox.io/volume-generation="v1"' /vol/projected/labels >/dev/null
  "${kube[@]}" exec "$pod" -c writer -- grep -F 'cubesandbox.io/volume-generation="v1"' /vol/downward/labels >/dev/null
  "${kube[@]}" exec "$pod" -c peer -- grep -F 'cubesandbox.io/volume-generation="v1"' /peer/projected/labels >/dev/null
  "${kube[@]}" exec "$pod" -c peer -- grep -F 'cubesandbox.io/volume-generation="v1"' /peer/downward/labels >/dev/null
  assert_stat "$pod" writer /vol/config/key.txt 444
  assert_stat "$pod" writer /vol/config/mode.txt 420
  assert_stat "$pod" writer /vol/secret/secret.txt 400
  assert_stat "$pod" writer /vol/secret/mode.txt 440
  assert_stat "$pod" writer /vol/projected/config.txt 404
  assert_stat "$pod" writer /vol/projected/secret.txt 440
  assert_stat "$pod" writer /vol/projected/labels 444
  assert_stat "$pod" writer /vol/downward/podname 444
  assert_stat "$pod" writer /vol/downward/labels 444
  assert_stat "$pod" writer /vol/sub/config-key 444
  assert_stat "$pod" peer /peer/config/key.txt 444
  assert_stat "$pod" peer /peer/config/mode.txt 420
  assert_stat "$pod" peer /peer/secret/secret.txt 400
  assert_stat "$pod" peer /peer/secret/mode.txt 440
  assert_stat "$pod" peer /peer/projected/config.txt 404
  assert_stat "$pod" peer /peer/projected/secret.txt 440
  assert_stat "$pod" peer /peer/projected/labels 444
  assert_stat "$pod" peer /peer/downward/podname 444
  assert_stat "$pod" peer /peer/downward/labels 444
  for readonly_path in /vol/config/key.txt /vol/secret/secret.txt /vol/projected/config.txt /vol/downward/labels /vol/sub/config-key; do
    readonly_name=$(printf '%s' "$readonly_path" | tr '/' '-')
    if "${kube[@]}" exec "$pod" -c writer -- sh -c 'printf forbidden >"$1"' sh "$readonly_path" >"$evidence/readonly-write-$runtime$readonly_name.txt" 2>&1; then
      echo "$runtime projected path unexpectedly accepted a write: $readonly_path" >&2
      exit 1
    fi
  done
  capture_atomic_guest "$runtime" "$pod" before
done
capture_atomic_host before
runc_subpath_value_before=$(read_path "$pod_runc" writer /vol/sub/config-key)
cube_subpath_value_before=$(read_path "$pod_cube" writer /vol/sub/config-key)
runc_subpath_inode_before=$("${kube[@]}" exec "$pod_runc" -c writer -- stat -L -c '%d:%i' /vol/sub/config-key | tr -d '\r\n')
cube_subpath_inode_before=$("${kube[@]}" exec "$pod_cube" -c writer -- stat -L -c '%d:%i' /vol/sub/config-key | tr -d '\r\n')
test "$runc_subpath_value_before" = config-v1
test "$cube_subpath_value_before" = config-v1

"${kube[@]}" patch configmap "$config" --type merge -p '{"data":{"key.txt":"config-v2","mode.txt":"config-mode-v2"}}' >"$evidence/patch-config.txt"
"${kube[@]}" patch secret "$secret" --type merge -p '{"stringData":{"secret.txt":"secret-v2","mode.txt":"secret-mode-v2"}}' >"$evidence/patch-secret.txt"
"${kube[@]}" label pod "$pod_runc" cubesandbox.io/volume-generation=v2 --overwrite >"$evidence/label-runc.txt"
"${kube[@]}" label pod "$pod_cube" cubesandbox.io/volume-generation=v2 --overwrite >"$evidence/label-cube.txt"

export -f projection_updated
set +e
# GNU timeout owns the complete polling process group and uses a monotonic timer;
# SIGKILL makes 300 seconds a hard bound even when kubectl exec is stuck.
timeout --signal=KILL 300s bash -c '
  set -Eeuo pipefail
  kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
  pod_runc=$1
  pod_cube=$2
  result=$3
  runc_updated=false
  cube_updated=false
  runc_latency=-1
  cube_latency=-1
  update_start=$(date +%s)
  while :; do
    for runtime in runc cube; do
      if test "$runtime" = runc && test "$runc_updated" = true; then continue; fi
      if test "$runtime" = cube && test "$cube_updated" = true; then continue; fi
      pod=$pod_runc
      test "$runtime" = cube && pod=$pod_cube
      if projection_updated "$pod"; then
        elapsed=$(( $(date +%s) - update_start ))
        if test "$runtime" = runc; then runc_updated=true; runc_latency=$elapsed; fi
        if test "$runtime" = cube; then cube_updated=true; cube_latency=$elapsed; fi
      fi
    done
    if test "$runc_updated" = true && test "$cube_updated" = true; then
      printf "runc\t%s\ncube\t%s\n" "$runc_latency" "$cube_latency" >"$result"
      exit 0
    fi
    sleep 1
  done
' bash "$pod_runc" "$pod_cube" "$evidence/update-latencies.tsv"
update_rc=$?
set -e
printf 'update_poll_rc=%s\n' "$update_rc" >"$evidence/update-poll-result.txt"
test "$update_rc" -eq 0
runc_latency=$(awk -F '\t' '$1 == "runc" {print $2}' "$evidence/update-latencies.tsv")
cube_latency=$(awk -F '\t' '$1 == "cube" {print $2}' "$evidence/update-latencies.tsv")
test "$runc_latency" -ge 0 && test "$runc_latency" -le 300
test "$cube_latency" -ge 0 && test "$cube_latency" -le 300

printf 'runtime\tconfig\tconfig_mode_value\tsecret\tsecret_mode_value\tprojected_config\tprojected_secret\tprojected_labels\tdownward_labels\tpeer_config\tpeer_config_mode_value\tpeer_secret\tpeer_secret_mode_value\tpeer_projected_config\tpeer_projected_secret\tpeer_projected_labels\tpeer_downward_labels\tpeer_podname\tsubpath\tlatency_seconds\n' >"$evidence/update-matrix.tsv"
for runtime in runc cube; do
  pod=$pod_runc
  latency=$runc_latency
  test "$runtime" = cube && pod=$pod_cube && latency=$cube_latency
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$runtime" \
    "$(read_path "$pod" writer /vol/config/key.txt)" \
    "$(read_path "$pod" writer /vol/config/mode.txt)" \
    "$(read_path "$pod" writer /vol/secret/secret.txt)" \
    "$(read_path "$pod" writer /vol/secret/mode.txt)" \
    "$(read_path "$pod" writer /vol/projected/config.txt)" \
    "$(read_path "$pod" writer /vol/projected/secret.txt)" \
    "$("${kube[@]}" exec "$pod" -c writer -- grep -o 'cubesandbox.io/volume-generation="[^"]*"' /vol/projected/labels | tr -d '\r\n')" \
    "$("${kube[@]}" exec "$pod" -c writer -- grep -o 'cubesandbox.io/volume-generation="[^"]*"' /vol/downward/labels | tr -d '\r\n')" \
    "$(read_path "$pod" peer /peer/config/key.txt)" \
    "$(read_path "$pod" peer /peer/config/mode.txt)" \
    "$(read_path "$pod" peer /peer/secret/secret.txt)" \
    "$(read_path "$pod" peer /peer/secret/mode.txt)" \
    "$(read_path "$pod" peer /peer/projected/config.txt)" \
    "$(read_path "$pod" peer /peer/projected/secret.txt)" \
    "$("${kube[@]}" exec "$pod" -c peer -- grep -o 'cubesandbox.io/volume-generation="[^"]*"' /peer/projected/labels | tr -d '\r\n')" \
    "$("${kube[@]}" exec "$pod" -c peer -- grep -o 'cubesandbox.io/volume-generation="[^"]*"' /peer/downward/labels | tr -d '\r\n')" \
    "$(read_path "$pod" peer /peer/downward/podname)" \
    "$(read_path "$pod" writer /vol/sub/config-key)" \
    "$latency" >>"$evidence/update-matrix.tsv"
  capture_atomic_guest "$runtime" "$pod" after
  assert_atomic_changed "$evidence/atomic-guest-$runtime-before.tsv" "$evidence/atomic-guest-$runtime-after.tsv"
done
capture_atomic_host after
assert_atomic_changed "$evidence/atomic-host-before.tsv" "$evidence/atomic-host-after.tsv"
test "$(read_path "$pod_runc" writer /vol/sub/config-key)" = "$runc_subpath_value_before"
test "$(read_path "$pod_cube" writer /vol/sub/config-key)" = "$cube_subpath_value_before"
test "$("${kube[@]}" exec "$pod_runc" -c writer -- stat -L -c '%d:%i' /vol/sub/config-key | tr -d '\r\n')" = "$runc_subpath_inode_before"
test "$("${kube[@]}" exec "$pod_cube" -c writer -- stat -L -c '%d:%i' /vol/sub/config-key | tr -d '\r\n')" = "$cube_subpath_inode_before"

for pod in "$pod_runc" "$pod_cube"; do
  assert_stat "$pod" writer /vol/config/key.txt 444
  assert_stat "$pod" writer /vol/config/mode.txt 420
  assert_stat "$pod" writer /vol/secret/secret.txt 400
  assert_stat "$pod" writer /vol/secret/mode.txt 440
  assert_stat "$pod" writer /vol/projected/config.txt 404
  assert_stat "$pod" writer /vol/projected/secret.txt 440
  assert_stat "$pod" writer /vol/projected/labels 444
  assert_stat "$pod" writer /vol/downward/labels 444
  assert_stat "$pod" peer /peer/config/key.txt 444
  assert_stat "$pod" peer /peer/config/mode.txt 420
  assert_stat "$pod" peer /peer/secret/secret.txt 400
  assert_stat "$pod" peer /peer/secret/mode.txt 440
  assert_stat "$pod" peer /peer/projected/config.txt 404
  assert_stat "$pod" peer /peer/projected/secret.txt 440
  assert_stat "$pod" peer /peer/projected/labels 444
  assert_stat "$pod" peer /peer/downward/podname 444
  assert_stat "$pod" peer /peer/downward/labels 444
done

test "$(sandbox_for_uid "$cube_uid")" = "$cube_sandbox"
test "$(shim_pid_for_sandbox "$cube_sandbox")" = "$cube_shim"
test "$(awk '{print $22}' "/proc/$cube_shim/stat")" = "$cube_shim_start"
test "$(stat -Lc '%d:%i' "$vm_runtime/$cube_sandbox")" = "$cube_vm_inode"
test "$(stat -Lc '%d:%i' "$shared_root/volumes")" = "$volume_inode"
test "$(container_id "$pod_cube" writer)" = "$cube_writer_id"
test "$(container_id "$pod_cube" peer)" = "$cube_peer_id"
find "$shared_root/rootfs" "$shared_root/volumes" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' 2>/dev/null | sort >"$evidence/task-generations-after.txt"
capture_host_mounts after
cmp "$evidence/task-generations-before.txt" "$evidence/task-generations-after.txt"
assert_host_mounts_continuous
printf 'S31C_PROJECTED_OK cube_sandbox=%s runc_latency=%ss cube_latency=%ss startup_modes=ok atomic_host=changed atomic_guest=changed multi_container_updates=ok subpath_value=v1 subpath_inode=stable host_mount_ids=stable shim=stable vm=stable volume_inode=%s\n' \
  "$cube_sandbox" "$runc_latency" "$cube_latency" "$volume_inode" | tee -a "$evidence/summary.txt"

delete_owned_objects
for _ in $(seq 1 1200); do
  test ! -e "/var/lib/kubelet/pods/$runc_uid" && test ! -e "/var/lib/kubelet/pods/$cube_uid" && break
  sleep .1
done
test ! -e "/var/lib/kubelet/pods/$runc_uid"
test ! -e "/var/lib/kubelet/pods/$cube_uid"
assert_baseline after
test $(( $(lease_records) - leases_before )) -eq 1
printf 'S31C_DONE active_leases=0 durable_tombstone_delta=1 kubelet_pod_dirs=removed evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
