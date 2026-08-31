#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
pod_runc=cubesandbox-s31a-runc
pod_cube=cubesandbox-s31a-cube
config=cubesandbox-s31a-config
secret=cubesandbox-s31a-secret
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
warm_mount=/run/cubesandbox-s31a-image-warmup
evidence=/data/cubelet/s3.1-evidence/s3.1a-diagnostic-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
event_pid=
runc_uid=
cube_uid=
cube_sandbox=
cube_shim=
cube_shim_start=
cube_vm_inode=
OBS_RC=
OBS_OUT=

count_entries() { if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi; }
count_files() { if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi; }
active_leases() {
  local n=0 record
  while IFS= read -r record; do
    if ! jq -e '.active == null' "$record" >/dev/null; then n=$((n + 1)); fi
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print 2>/dev/null)
  echo "$n"
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
    "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" "$(active_leases)" "$(lease_records)" >"$evidence/resources-$tag.txt"
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
      printf 'S31A_BASELINE_CLEAN wait_attempt=%s lease_records=%s\n' "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
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
  local kind=$1 name=$2
  test "$("${kube[@]}" get "$kind" "$name" -o jsonpath='{.metadata.labels.cubesandbox\.io/s31a-owned}' 2>/dev/null)" = true
}

delete_owned_objects() {
  local name kind
  for name in "$pod_runc" "$pod_cube"; do
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
  local pod=$1 container=$2
  "${kube[@]}" get pod "$pod" -o json | jq -r --arg name "$container" \
    '.status.containerStatuses[] | select(.name == $name and .state.running != null) | .containerID | sub("^containerd://"; "")'
}

observe_case() {
  local runtime=$1 case_name=$2 pod=$3 container=$4 command=$5 raw
  raw="$evidence/case-$runtime-$case_name.txt"
  set +e
  OBS_OUT=$("${kube[@]}" exec "$pod" -c "$container" -- sh -c "$command" 2>&1)
  OBS_RC=$?
  set -e
  printf '%s\n' "$OBS_OUT" >"$raw"
  printf '%s\t%s\t%s\t%s\n' "$runtime" "$case_name" "$OBS_RC" "${raw#$evidence/}" >>"$evidence/io-matrix.tsv"
}

read_path() {
  local pod=$1 path=$2
  "${kube[@]}" exec "$pod" -c writer -- cat "$path" 2>/dev/null | tr -d '\r\n'
}

capture_container_input() {
  local runtime=$1 name=$2 id=$3
  "${cri[@]}" inspect "$id" >"$evidence/cri-$runtime-$name.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$runtime-$name.json"
  jq -r '
    (.info.runtimeSpec.mounts // [])[] |
    select((.destination // "") | startswith("/vol/") or startswith("/peer/")) |
    [.destination, (.type // ""), (.source // ""), ((.options // []) | join(","))] | @tsv
  ' "$evidence/cri-$runtime-$name.json" | sort >"$evidence/mounts-$runtime-$name-cri.tsv"
  jq -r '
    (.Spec.mounts // [])[] |
    select((.destination // "") | startswith("/vol/") or startswith("/peer/")) |
    [.destination, (.type // ""), (.source // ""), ((.options // []) | join(","))] | @tsv
  ' "$evidence/ctr-$runtime-$name.json" | sort >"$evidence/mounts-$runtime-$name-ctr.tsv"
}

validate_container_input() {
  local runtime=$1 name=$2 cri_mounts ctr_mounts expected actual destination source options
  cri_mounts="$evidence/mounts-$runtime-$name-cri.tsv"
  ctr_mounts="$evidence/mounts-$runtime-$name-ctr.tsv"
  expected="$evidence/mounts-$runtime-$name-expected-destinations.txt"
  actual="$evidence/mounts-$runtime-$name-actual-destinations.txt"
  if test "$name" = writer; then
    printf '%s\n' /vol/config /vol/downward /vol/projected /vol/ram /vol/secret /vol/sub/config-key /vol/work /vol/work-ro >"$expected"
  else
    printf '%s\n' /peer/config /peer/ram /peer/work >"$expected"
  fi
  cmp -s "$cri_mounts" "$ctr_mounts"
  cut -f1 "$cri_mounts" >"$actual"
  cmp -s "$expected" "$actual"
  while IFS= read -r destination; do
    test "$(awk -F '\t' -v destination="$destination" '$1 == destination {count++} END {print count+0}' "$cri_mounts")" -eq 1
    test "$(awk -F '\t' -v destination="$destination" '$1 == destination {print $2}' "$cri_mounts")" = bind
    source=$(awk -F '\t' -v destination="$destination" '$1 == destination {print $3}' "$cri_mounts")
    test "${source#/}" != "$source"
  done <"$expected"
  if test "$name" = writer; then
    test "$(awk -F '\t' '$1 == "/vol/work" {print $3}' "$cri_mounts")" = \
      "$(awk -F '\t' '$1 == "/vol/work-ro" {print $3}' "$cri_mounts")"
    options=$(awk -F '\t' '$1 == "/vol/work" {print "," $4 ","}' "$cri_mounts")
    test "${options#*,ro,}" = "$options"
    options=$(awk -F '\t' '$1 == "/vol/work-ro" {print "," $4 ","}' "$cri_mounts")
    test "${options#*,ro,}" != "$options"
    for destination in /vol/config /vol/secret /vol/projected /vol/downward /vol/sub/config-key; do
      options=$(awk -F '\t' -v destination="$destination" '$1 == destination {print "," $4 ","}' "$cri_mounts")
      test "${options#*,ro,}" != "$options"
    done
  fi
}

capture_owned_host_mounts() {
  local tag=$1
  awk -v runc_uid="$runc_uid" -v cube_uid="$cube_uid" -v shared="$shared/" \
    'index($0, runc_uid) || index($0, cube_uid) || index($0, shared)' \
    /proc/self/mountinfo >"$evidence/host-owned-mountinfo-$tag.txt"
  findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS | \
    awk -v runc_uid="$runc_uid" -v cube_uid="$cube_uid" -v shared="$shared/" \
      'index($0, runc_uid) || index($0, cube_uid) || index($0, shared)' \
      >"$evidence/host-owned-findmnt-$tag.txt"
}

capture_guest_mounts() {
  local runtime=$1 pod=$2 container=$3
  "${kube[@]}" exec "$pod" -c "$container" -- cat /proc/self/mountinfo >"$evidence/mountinfo-$runtime-$container.txt"
  "${kube[@]}" exec "$pod" -c "$container" -- sh -c \
    'for p in /vol/work /vol/work-ro /vol/ram /vol/config /vol/secret /vol/projected /vol/downward /vol/sub/config-key /peer/work /peer/ram /peer/config; do if test -e "$p"; then stat -c "%n type=%F mode=%a uid=%u gid=%g" "$p"; fi; done' \
    >"$evidence/stat-$runtime-$container.txt"
}

stop_observers() {
  if test -n "$event_pid"; then
    kill -TERM "$event_pid" >/dev/null 2>&1 || true
    wait "$event_pid" >/dev/null 2>&1 || true
    event_pid=
  fi
}

cleanup() {
  local rc=$?
  set +e
  stop_observers
  "${kube[@]}" get pod "$pod_runc" -o json >"$evidence/pod-runc-final.json" 2>&1 || true
  "${kube[@]}" get pod "$pod_cube" -o json >"$evidence/pod-cube-final.json" 2>&1 || true
  "${cri[@]}" ps -a >"$evidence/cri-containers-final.txt" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  delete_owned_objects
  if mountpoint -q "$warm_mount"; then "${ctr[@]}" images unmount --snapshotter overlayfs --rm "$warm_mount" >/dev/null 2>&1 || true; fi
  rmdir "$warm_mount" >/dev/null 2>&1 || true
  wait_runtime_idle
  exit "$rc"
}

install -d -m 0700 "$evidence"
printf 'runtime\tcase\trc\traw_output\n' >"$evidence/io-matrix.tsv"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT
delete_owned_objects
wait_runtime_idle
install -d -m 0755 "$warm_mount"
"${ctr[@]}" images mount --snapshotter overlayfs docker.io/library/busybox:1.36.1 "$warm_mount" >"$evidence/image-warm-mount.txt"
"${ctr[@]}" images unmount --snapshotter overlayfs --rm "$warm_mount" >"$evidence/image-warm-unmount.txt"
rmdir "$warm_mount"
capture_state before
leases_before=$(lease_records)
timeout 1800s "${ctr[@]}" events >"$evidence/events.txt" 2>"$evidence/events.stderr" & event_pid=$!

cat >"$evidence/resources.yaml" <<'RESOURCE_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cubesandbox-s31a-config
  labels:
    cubesandbox.io/s31a-owned: "true"
data:
  key.txt: config-v1
---
apiVersion: v1
kind: Secret
metadata:
  name: cubesandbox-s31a-secret
  labels:
    cubesandbox.io/s31a-owned: "true"
type: Opaque
stringData:
  secret.txt: secret-v1
RESOURCE_EOF
"${kube[@]}" apply -f "$evidence/resources.yaml" >"$evidence/apply-resources.txt"

write_pod_manifest() {
  local name=$1 runtime_class=$2 target=$3
  cat >"$target" <<POD_EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    cubesandbox.io/s31a-owned: "true"
    cubesandbox.io/volume-generation: "v1"
spec:
${runtime_class}
  nodeName: vm-200-2-ubuntu
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: writer
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
    resources:
      limits: {cpu: 100m, memory: 64Mi}
    volumeMounts:
    - {name: work, mountPath: /vol/work}
    - {name: work, mountPath: /vol/work-ro, readOnly: true}
    - {name: ram, mountPath: /vol/ram}
    - {name: config, mountPath: /vol/config, readOnly: true}
    - {name: secret, mountPath: /vol/secret, readOnly: true}
    - {name: projected, mountPath: /vol/projected, readOnly: true}
    - {name: downward, mountPath: /vol/downward, readOnly: true}
    - {name: config, mountPath: /vol/sub/config-key, subPath: key.txt, readOnly: true}
  - name: peer
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
    resources:
      limits: {cpu: 100m, memory: 64Mi}
    volumeMounts:
    - {name: work, mountPath: /peer/work}
    - {name: ram, mountPath: /peer/ram}
    - {name: config, mountPath: /peer/config, readOnly: true}
  volumes:
  - name: work
    emptyDir: {}
  - name: ram
    emptyDir: {medium: Memory}
  - name: config
    configMap:
      name: cubesandbox-s31a-config
      defaultMode: 0444
  - name: secret
    secret:
      secretName: cubesandbox-s31a-secret
      defaultMode: 0400
  - name: projected
    projected:
      defaultMode: 0440
      sources:
      - configMap:
          name: cubesandbox-s31a-config
          items: [{key: key.txt, path: config.txt}]
      - secret:
          name: cubesandbox-s31a-secret
          items: [{key: secret.txt, path: secret.txt}]
      - downwardAPI:
          items:
          - path: labels
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

write_pod_manifest "$pod_runc" "" "$evidence/pod-runc.yaml"
write_pod_manifest "$pod_cube" "  runtimeClassName: cube" "$evidence/pod-cube.yaml"
"${kube[@]}" apply -f "$evidence/pod-runc.yaml" >"$evidence/apply-pod-runc.txt"
"${kube[@]}" apply -f "$evidence/pod-cube.yaml" >"$evidence/apply-pod-cube.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod_runc" --timeout=180s >"$evidence/wait-runc.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod_cube" --timeout=240s >"$evidence/wait-cube.txt"
"${kube[@]}" get pod "$pod_runc" -o json >"$evidence/pod-runc-initial.json"
"${kube[@]}" get pod "$pod_cube" -o json >"$evidence/pod-cube-initial.json"
runc_uid=$(jq -r '.metadata.uid' "$evidence/pod-runc-initial.json")
cube_uid=$(jq -r '.metadata.uid' "$evidence/pod-cube-initial.json")
test -n "$runc_uid" && test "$runc_uid" != null
test -n "$cube_uid" && test "$cube_uid" != null
cube_sandbox=$(sandbox_for_uid "$cube_uid")
cube_shim=$(shim_pid_for_sandbox "$cube_sandbox")
cube_shim_start=$(awk '{print $22}' "/proc/$cube_shim/stat")
cube_vm_inode=$(stat -Lc '%d:%i' "$vm_runtime/$cube_sandbox")

for runtime in runc cube; do
  pod=$pod_runc
  test "$runtime" = cube && pod=$pod_cube
  writer_id=$(container_id "$pod" writer)
  peer_id=$(container_id "$pod" peer)
  test -n "$writer_id" && test -n "$peer_id"
  capture_container_input "$runtime" writer "$writer_id"
  capture_container_input "$runtime" peer "$peer_id"
  validate_container_input "$runtime" writer
  validate_container_input "$runtime" peer
  capture_guest_mounts "$runtime" "$pod" writer
  capture_guest_mounts "$runtime" "$pod" peer
done
find "$shared" -mindepth 1 -printf '%P\t%y\t%m\t%u\t%g\n' | sort >"$evidence/shared-tree-active.tsv"
capture_owned_host_mounts active
grep -F "$runc_uid" "$evidence/host-owned-mountinfo-active.txt" >/dev/null
grep -F "$cube_uid" "$evidence/host-owned-mountinfo-active.txt" >/dev/null
grep -F "$shared/" "$evidence/host-owned-mountinfo-active.txt" >/dev/null
findmnt -rn -o TARGET | awk -v shared="$shared/" 'index($0, shared) == 1' | sort -u >"$evidence/cube-shared-targets-active.txt"
test -s "$evidence/cube-shared-targets-active.txt"
find "$runtime_state" -type f -maxdepth 3 -print -exec sed -n '1,240p' {} \; >"$evidence/runtime-resource-active.txt"

for runtime in runc cube; do
  pod=$pod_runc
  test "$runtime" = cube && pod=$pod_cube
  test "$(read_path "$pod" /vol/config/key.txt)" = config-v1
  test "$(read_path "$pod" /vol/secret/secret.txt)" = secret-v1
  test "$(read_path "$pod" /vol/projected/config.txt)" = config-v1
  test "$(read_path "$pod" /vol/projected/secret.txt)" = secret-v1
  test "$(read_path "$pod" /vol/downward/podname)" = "$pod"
  test "$(read_path "$pod" /vol/sub/config-key)" = config-v1
  "${kube[@]}" exec "$pod" -c writer -- grep -F 'cubesandbox.io/volume-generation="v1"' /vol/projected/labels >/dev/null
  "${kube[@]}" exec "$pod" -c writer -- grep -F 'cubesandbox.io/volume-generation="v1"' /vol/downward/labels >/dev/null
done

observe_case runc disk-write "$pod_runc" writer 'printf runc-disk > /vol/work/from-writer'
test "$OBS_RC" -eq 0
observe_case runc disk-readonly-alias-read "$pod_runc" writer 'cat /vol/work-ro/from-writer'
test "$OBS_RC" -eq 0 && test "$OBS_OUT" = runc-disk
observe_case runc disk-cross-read "$pod_runc" peer 'cat /peer/work/from-writer'
test "$OBS_RC" -eq 0 && test "$OBS_OUT" = runc-disk
observe_case runc disk-peer-write "$pod_runc" peer 'printf runc-peer > /peer/work/from-peer'
test "$OBS_RC" -eq 0
observe_case runc disk-writer-read "$pod_runc" writer 'cat /vol/work/from-peer'
test "$OBS_RC" -eq 0 && test "$OBS_OUT" = runc-peer
observe_case runc memory-write "$pod_runc" writer 'printf runc-memory > /vol/ram/from-writer'
test "$OBS_RC" -eq 0
observe_case runc memory-cross-read "$pod_runc" peer 'cat /peer/ram/from-writer'
test "$OBS_RC" -eq 0 && test "$OBS_OUT" = runc-memory
observe_case runc explicit-readonly-write "$pod_runc" writer 'printf forbidden > /vol/work-ro/forbidden'
test "$OBS_RC" -ne 0
observe_case runc projected-readonly-write "$pod_runc" writer 'printf forbidden > /vol/config/key.txt'
test "$OBS_RC" -ne 0

observe_case cube disk-write "$pod_cube" writer 'printf cube-disk > /vol/work/from-writer'
test "$OBS_RC" -ne 0
grep -F 'Read-only file system' "$evidence/case-cube-disk-write.txt" >/dev/null
observe_case cube disk-peer-write "$pod_cube" peer 'printf cube-peer > /peer/work/from-peer'
test "$OBS_RC" -ne 0
grep -F 'Read-only file system' "$evidence/case-cube-disk-peer-write.txt" >/dev/null
observe_case cube memory-write "$pod_cube" writer 'printf cube-memory > /vol/ram/from-writer'
test "$OBS_RC" -ne 0
grep -F 'Read-only file system' "$evidence/case-cube-memory-write.txt" >/dev/null
observe_case cube explicit-readonly-write "$pod_cube" writer 'printf forbidden > /vol/work-ro/forbidden'
test "$OBS_RC" -ne 0
observe_case cube projected-readonly-write "$pod_cube" writer 'printf forbidden > /vol/config/key.txt'
test "$OBS_RC" -ne 0

"${kube[@]}" patch configmap "$config" --type merge -p '{"data":{"key.txt":"config-v2"}}' >"$evidence/patch-config.txt"
"${kube[@]}" patch secret "$secret" --type merge -p '{"stringData":{"secret.txt":"secret-v2"}}' >"$evidence/patch-secret.txt"
"${kube[@]}" label pod "$pod_runc" cubesandbox.io/volume-generation=v2 --overwrite >"$evidence/label-runc.txt"
"${kube[@]}" label pod "$pod_cube" cubesandbox.io/volume-generation=v2 --overwrite >"$evidence/label-cube.txt"

runc_updated=false
cube_updated=false
update_start=$(date +%s)
for _ in $(seq 1 90); do
  if "${kube[@]}" exec "$pod_runc" -c writer -- sh -c \
    'test "$(cat /vol/config/key.txt)" = config-v2 && test "$(cat /vol/secret/secret.txt)" = secret-v2 && test "$(cat /vol/projected/config.txt)" = config-v2 && test "$(cat /vol/projected/secret.txt)" = secret-v2 && grep -F '\''cubesandbox.io/volume-generation="v2"'\'' /vol/projected/labels >/dev/null && grep -F '\''cubesandbox.io/volume-generation="v2"'\'' /vol/downward/labels >/dev/null' \
    >/dev/null 2>&1; then runc_updated=true; fi
  if "${kube[@]}" exec "$pod_cube" -c writer -- sh -c \
    'test "$(cat /vol/config/key.txt)" = config-v2 && test "$(cat /vol/secret/secret.txt)" = secret-v2 && test "$(cat /vol/projected/config.txt)" = config-v2 && test "$(cat /vol/projected/secret.txt)" = secret-v2 && grep -F '\''cubesandbox.io/volume-generation="v2"'\'' /vol/projected/labels >/dev/null && grep -F '\''cubesandbox.io/volume-generation="v2"'\'' /vol/downward/labels >/dev/null' \
    >/dev/null 2>&1; then cube_updated=true; fi
  test "$runc_updated" = true && test "$cube_updated" = true && break
  sleep 2
done
update_wait_seconds=$(( $(date +%s) - update_start ))
test "$runc_updated" = true
printf 'runtime\tconfig\tsecret\tprojected_config\tprojected_secret\tprojected_labels\tdownward_labels\tsubpath\n' >"$evidence/update-matrix.tsv"
for runtime in runc cube; do
  pod=$pod_runc
  test "$runtime" = cube && pod=$pod_cube
  config_value=$(read_path "$pod" /vol/config/key.txt || true)
  secret_value=$(read_path "$pod" /vol/secret/secret.txt || true)
  projected_config=$(read_path "$pod" /vol/projected/config.txt || true)
  projected_secret=$(read_path "$pod" /vol/projected/secret.txt || true)
  projected_labels=$("${kube[@]}" exec "$pod" -c writer -- grep -o 'cubesandbox.io/volume-generation="[^"]*"' /vol/projected/labels 2>/dev/null | tr -d '\r\n' || true)
  downward_labels=$("${kube[@]}" exec "$pod" -c writer -- grep -o 'cubesandbox.io/volume-generation="[^"]*"' /vol/downward/labels 2>/dev/null | tr -d '\r\n' || true)
  subpath_value=$(read_path "$pod" /vol/sub/config-key || true)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$runtime" "$config_value" "$secret_value" "$projected_config" "$projected_secret" "$projected_labels" "$downward_labels" "$subpath_value" >>"$evidence/update-matrix.tsv"
  test "$subpath_value" = config-v1
done

test "$(sandbox_for_uid "$cube_uid")" = "$cube_sandbox"
test "$(shim_pid_for_sandbox "$cube_sandbox")" = "$cube_shim"
test "$(awk '{print $22}' "/proc/$cube_shim/stat")" = "$cube_shim_start"
test "$(stat -Lc '%d:%i' "$vm_runtime/$cube_sandbox")" = "$cube_vm_inode"
"${kube[@]}" exec "$pod_cube" -c writer -- true
"${kube[@]}" exec "$pod_cube" -c peer -- true
printf 'S31A_DIAGNOSTIC_OK cube_sandbox=%s startup_injection=ok runc_disk_rw=ok runc_memory_rw=ok cube_disk_rw=EROFS cube_memory_rw=EROFS runc_updates=%s cube_updates=%s subpath_stable=v1 update_wait_seconds=%s shim_identity=stable vm_inode=stable\n' \
  "$cube_sandbox" "$runc_updated" "$cube_updated" "$update_wait_seconds" | tee -a "$evidence/summary.txt"

stop_observers
delete_owned_objects
for _ in $(seq 1 1200); do
  test ! -e "/var/lib/kubelet/pods/$runc_uid" && test ! -e "/var/lib/kubelet/pods/$cube_uid" && break
  sleep .1
done
test ! -e "/var/lib/kubelet/pods/$runc_uid"
test ! -e "/var/lib/kubelet/pods/$cube_uid"
capture_owned_host_mounts after
test ! -s "$evidence/host-owned-mountinfo-after.txt"
test ! -s "$evidence/host-owned-findmnt-after.txt"
while IFS= read -r target; do
  ! findmnt -rn -o TARGET | grep -Fx "$target" >/dev/null
done <"$evidence/cube-shared-targets-active.txt"
assert_baseline after
test $(( $(lease_records) - leases_before )) -eq 1
printf 'S31A_DONE active_leases=0 durable_tombstone_delta=1 kubelet_pod_dirs=removed evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
