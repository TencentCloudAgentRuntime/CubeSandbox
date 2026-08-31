#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
pod=cubesandbox-s31b-volume
failure_pod=cubesandbox-s31b-volume-failure
pods=("$pod" "$failure_pod")
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.1-evidence/s3.1b-writable-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
probe_id=

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
      printf 'S31B_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' "$tag" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
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
  test "$("${kube[@]}" get pod "$1" -o jsonpath='{.metadata.labels.cubesandbox\.io/s31b-owned}' 2>/dev/null)" = true
}

delete_owned() {
  local name=$1
  if "${kube[@]}" get pod "$name" >/dev/null 2>&1; then
    is_owned "$name" || return 1
    "${kube[@]}" delete pod "$name" --grace-period=0 --force --wait=false >/dev/null
  fi
  for _ in $(seq 1 1200); do
    if ! "${kube[@]}" get pod "$name" >/dev/null 2>&1; then return 0; fi
    sleep .1
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

container_id() {
  local name=$1 section=$2
  "${kube[@]}" get pod "$pod" -o json | jq -r --arg name "$name" --arg section "$section" '
    if $section == "init" then .status.initContainerStatuses else .status.containerStatuses end
    | .[] | select(.name == $name) | .containerID | sub("^containerd://"; "")
  '
}

capture_mount_input() {
  local name=$1 id=$2
  "${cri[@]}" inspect "$id" >"$evidence/cri-$name.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$name.json"
  jq -r '(.info.runtimeSpec.mounts // [])[] | select((.destination // "") | startswith("/vol/")) | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/cri-$name.json" | sort >"$evidence/mounts-$name-cri.tsv"
  jq -r '(.Spec.mounts // [])[] | select((.destination // "") | startswith("/vol/")) | [.destination,.type,.source,((.options // [])|join(","))] | @tsv' \
    "$evidence/ctr-$name.json" | sort >"$evidence/mounts-$name-ctr.tsv"
  cmp -s "$evidence/mounts-$name-cri.tsv" "$evidence/mounts-$name-ctr.tsv"
}

cleanup() {
  local rc=$? name
  set +e
  if test -n "$probe_id"; then "${cri[@]}" rm -f "$probe_id" >/dev/null 2>&1 || true; fi
  for name in "${pods[@]}"; do
    "${kube[@]}" get pod "$name" -o json >"$evidence/$name-final.json" 2>&1 || true
  done
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  for name in "${pods[@]}"; do delete_owned "$name"; done
  wait_runtime_idle
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT
for name in "${pods[@]}"; do delete_owned "$name"; done
wait_runtime_idle
capture_state before
leases_before=$(lease_records)

"${kube[@]}" apply -f - >"$evidence/apply-main.txt" <<'POD_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s31b-volume
  labels: {cubesandbox.io/s31b-owned: "true"}
spec:
  runtimeClassName: cube
  nodeName: vm-200-2-ubuntu
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 2
  initContainers:
  - name: regular-init
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "printf init-disk >/vol/work/from-init; printf init-memory >/vol/ram/from-init"]
    volumeMounts:
    - {name: work, mountPath: /vol/work}
    - {name: ram, mountPath: /vol/ram}
  - name: sidecar
    image: docker.io/library/busybox:1.36.1
    restartPolicy: Always
    startupProbe:
      exec: {command: ["sh", "-c", "test -f /vol/work/from-sidecar && test -f /vol/ram/from-sidecar"]}
      periodSeconds: 1
      failureThreshold: 30
    command:
    - sh
    - -c
    - |
      test "$(cat /vol/work/from-init)" = init-disk
      test "$(cat /vol/ram/from-init)" = init-memory
      printf sidecar-disk >/vol/work/from-sidecar
      printf sidecar-memory >/vol/ram/from-sidecar
      exec sleep 1000
    volumeMounts:
    - {name: work, mountPath: /vol/work}
    - {name: ram, mountPath: /vol/ram}
  containers:
  - name: app
    image: docker.io/library/busybox:1.36.1
    command:
    - sh
    - -c
    - |
      test "$(cat /vol/work/from-init)" = init-disk
      test "$(cat /vol/ram/from-init)" = init-memory
      test "$(cat /vol/work/from-sidecar)" = sidecar-disk
      test "$(cat /vol/ram/from-sidecar)" = sidecar-memory
      exec sleep 1000
    volumeMounts:
    - {name: work, mountPath: /vol/work}
    - {name: work, mountPath: /vol/work-ro, readOnly: true}
    - {name: ram, mountPath: /vol/ram}
  volumes:
  - {name: work, emptyDir: {}}
  - {name: ram, emptyDir: {medium: Memory}}
POD_EOF
"${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=300s >"$evidence/wait-main.txt"
"${kube[@]}" get pod "$pod" -o json >"$evidence/pod-main.json"
jq -e '.status.initContainerStatuses[] | select(.name == "regular-init" and .state.terminated.exitCode == 0)' "$evidence/pod-main.json" >/dev/null
jq -e '.status.initContainerStatuses[] | select(.name == "sidecar" and .started == true and .ready == true)' "$evidence/pod-main.json" >/dev/null
uid=$(jq -r '.metadata.uid' "$evidence/pod-main.json")
sandbox=$(sandbox_for_uid "$uid")
shared_root=$(find "$shared" -mindepth 1 -maxdepth 1 -type d -print)
test "$(printf '%s\n' "$shared_root" | awk 'NF {n++} END {print n+0}')" -eq 1
volume_inode=$(stat -Lc '%d:%i' "$shared_root/volumes")

sidecar_id=$(container_id sidecar init)
app_id=$(container_id app app)
test -n "$sidecar_id" && test -n "$app_id"
capture_mount_input sidecar "$sidecar_id"
capture_mount_input app "$app_id"
work_source=$(awk -F '\t' '$1 == "/vol/work" {print $3}' "$evidence/mounts-app-cri.tsv")
work_ro_source=$(awk -F '\t' '$1 == "/vol/work-ro" {print $3}' "$evidence/mounts-app-cri.tsv")
test "$work_source" = "$work_ro_source"
test "$(awk -F '\t' '$1 == "/vol/work" {print "," $4 ","}' "$evidence/mounts-app-cri.tsv" | grep -Fc ',ro,' || true)" -eq 0
test "$(awk -F '\t' '$1 == "/vol/work-ro" {print "," $4 ","}' "$evidence/mounts-app-cri.tsv" | grep -Fc ',ro,' || true)" -eq 1

"${kube[@]}" exec "$pod" -c app -- sh -c 'printf app-disk >/vol/work/from-app; printf app-memory >/vol/ram/from-app'
test "$("${kube[@]}" exec "$pod" -c sidecar -- cat /vol/work/from-app | tr -d '\r\n')" = app-disk
test "$("${kube[@]}" exec "$pod" -c sidecar -- cat /vol/ram/from-app | tr -d '\r\n')" = app-memory
test "$("${kube[@]}" exec "$pod" -c app -- cat /vol/work-ro/from-app | tr -d '\r\n')" = app-disk
if "${kube[@]}" exec "$pod" -c app -- sh -c 'printf forbidden >/vol/work-ro/forbidden' >"$evidence/read-only-write.txt" 2>&1; then
  echo 'read-only alias unexpectedly accepted a write' >&2
  exit 1
fi
"${kube[@]}" exec "$pod" -c app -- cat /proc/self/mountinfo >"$evidence/guest-mountinfo-app.txt"
grep -E ' /vol/(work|ram) .* - virtiofs cubeVolumes ' "$evidence/guest-mountinfo-app.txt" >"$evidence/guest-volume-mounts.txt"
test "$(wc -l <"$evidence/guest-volume-mounts.txt")" -eq 2
awk '$5 == "/vol/work" || $5 == "/vol/ram" {if ($6 !~ /(^|,)rw(,|$)/) exit 1; found++} END {exit found != 2}' "$evidence/guest-mountinfo-app.txt"
awk '$5 == "/vol/work-ro" {if ($6 !~ /(^|,)ro(,|$)/) exit 1; found++} END {exit found != 1}' "$evidence/guest-mountinfo-app.txt"
awk '$5 == "/" && $6 ~ /(^|,)ro(,|$)/ && $0 ~ / - overlay overlay2 / && $0 ~ /lowerdir=\/run\/cube-containers\/shared\/containers\/[^/]+\/rootfs\// {print}' \
  "$evidence/guest-mountinfo-app.txt" >"$evidence/guest-rootfs-share.txt"
test -s "$evidence/guest-rootfs-share.txt"

find "$shared_root" -mindepth 1 -printf '%P\t%y\t%m\n' | sort >"$evidence/shared-tree-active.tsv"
findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS | awk -v root="$shared_root/" 'index($1, root) == 1' >"$evidence/host-shared-mounts-active.txt"
test -s "$evidence/host-shared-mounts-active.txt"
awk -v root="$shared_root/volumes/" 'index($1, root) == 1 {found++} END {exit found == 0}' "$evidence/host-shared-mounts-active.txt"
awk -v root="$shared_root/rootfs/" 'index($1, root) == 1 && index($1, "/volumes/") {bad++} END {exit bad != 0}' "$evidence/host-shared-mounts-active.txt"
test "$(stat -Lc '%d:%i' "$shared_root/volumes")" = "$volume_inode"

# Create and remove one more CRI container inside the live Pod sandbox. CRI
# CreateContainer only records container metadata; StartContainer creates the
# Task. Check both sides of that boundary so the fixed virtiofs export inode is
# proven across a real task generation rather than two adjacent stat calls.
generations_before_probe=$(find "$shared_root/rootfs" "$shared_root/volumes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
mounts_before_probe=$(findmnt -rn -o TARGET | awk -v root="$shared_root/" 'index($1, root) == 1 {n++} END {print n+0}')
jq -n --arg host "$work_source" '{
  metadata: {name: "s31b-inode-probe", attempt: 0},
  image: {image: "docker.io/library/busybox:1.36.1"},
  command: ["sh"],
  args: ["-c", "test \"$(cat /vol/work/from-app)\" = app-disk"],
  mounts: [{container_path: "/vol/work", host_path: $host, readonly: false}],
  log_path: "s31b-inode-probe.log"
}' >"$evidence/inode-probe-container.json"
jq -n --arg name "$pod" --arg uid "$uid" '{
  metadata: {name: $name, uid: $uid, namespace: "default", attempt: 0},
  linux: {}
}' >"$evidence/inode-probe-sandbox.json"
probe_id=$("${cri[@]}" create "$sandbox" "$evidence/inode-probe-container.json" "$evidence/inode-probe-sandbox.json")
test -n "$probe_id"
generations_after_create=$(find "$shared_root/rootfs" "$shared_root/volumes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
mounts_after_create=$(findmnt -rn -o TARGET | awk -v root="$shared_root/" 'index($1, root) == 1 {n++} END {print n+0}')
test "$generations_after_create" -eq "$generations_before_probe"
test "$mounts_after_create" -eq "$mounts_before_probe"
test "$(stat -Lc '%d:%i' "$shared_root/volumes")" = "$volume_inode"
"${cri[@]}" start "$probe_id" >"$evidence/inode-probe-start.txt"
for _ in $(seq 1 300); do
  generations_after_start=$(find "$shared_root/rootfs" "$shared_root/volumes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  mounts_after_start=$(findmnt -rn -o TARGET | awk -v root="$shared_root/" 'index($1, root) == 1 {n++} END {print n+0}')
  if test "$generations_after_start" -gt "$generations_before_probe" && test "$mounts_after_start" -gt "$mounts_before_probe"; then break; fi
  sleep .1
done
test "$generations_after_start" -gt "$generations_before_probe"
test "$mounts_after_start" -gt "$mounts_before_probe"
test "$(stat -Lc '%d:%i' "$shared_root/volumes")" = "$volume_inode"
for _ in $(seq 1 300); do
  "${cri[@]}" inspect "$probe_id" >"$evidence/inode-probe-inspect.json"
  if jq -e '.status.state == "CONTAINER_EXITED" and .status.exitCode == 0' "$evidence/inode-probe-inspect.json" >/dev/null; then break; fi
  sleep .1
done
jq -e '.status.state == "CONTAINER_EXITED" and .status.exitCode == 0' "$evidence/inode-probe-inspect.json" >/dev/null
"${cri[@]}" rm "$probe_id" >"$evidence/inode-probe-remove.txt"
probe_id=
for _ in $(seq 1 300); do
  generations_after_probe=$(find "$shared_root/rootfs" "$shared_root/volumes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  mounts_after_probe=$(findmnt -rn -o TARGET | awk -v root="$shared_root/" 'index($1, root) == 1 {n++} END {print n+0}')
  if test "$generations_after_probe" -eq "$generations_before_probe" && test "$mounts_after_probe" -eq "$mounts_before_probe"; then break; fi
  sleep .1
done
test "$generations_after_probe" -eq "$generations_before_probe"
test "$mounts_after_probe" -eq "$mounts_before_probe"
test "$(stat -Lc '%d:%i' "$shared_root/volumes")" = "$volume_inode"
printf 'S31B_RW_OK sandbox=%s init_to_sidecar=ok sidecar_to_app=ok app_to_sidecar=ok disk=rw memory=rw readonly_alias=ro volume_inode=%s\n' \
  "$sandbox" "$volume_inode" | tee -a "$evidence/summary.txt"

delete_owned "$pod"
assert_baseline after-main

"${kube[@]}" apply -f - >"$evidence/apply-failure.txt" <<'FAILURE_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s31b-volume-failure
  labels: {cubesandbox.io/s31b-owned: "true"}
spec:
  runtimeClassName: cube
  nodeName: vm-200-2-ubuntu
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
  - name: app
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "sleep 1000"]
    volumeMounts: [{name: bad, mountPath: /vol/bad}]
  volumes:
  - name: bad
    hostPath: {path: /dev/kvm, type: CharDevice}
FAILURE_EOF
for _ in $(seq 1 1200); do
  "${kube[@]}" get pod "$failure_pod" -o json >"$evidence/pod-failure.json"
  if jq -e '.status.containerStatuses[]? | select(.name == "app") |
    select(
      (.state.waiting.reason == "CreateContainerError" and (.state.waiting.message | contains("neither file nor directory"))) or
      (.state.terminated.reason == "StartError" and .state.terminated.exitCode == 128 and (.state.terminated.message | contains("neither file nor directory")))
    )' "$evidence/pod-failure.json" >/dev/null; then break; fi
  sleep .1
done
jq -e '.status.containerStatuses[] | select(.name == "app") |
  select(
    (.state.waiting.reason == "CreateContainerError" and (.state.waiting.message | contains("neither file nor directory"))) or
    (.state.terminated.reason == "StartError" and .state.terminated.exitCode == 128 and (.state.terminated.message | contains("neither file nor directory")))
  )' \
  "$evidence/pod-failure.json" >/dev/null
failure_uid=$(jq -r '.metadata.uid' "$evidence/pod-failure.json")
failure_sandbox=$(sandbox_for_uid "$failure_uid")
failure_shared_root=$(find "$shared" -mindepth 1 -maxdepth 1 -type d -print)
test "$(printf '%s\n' "$failure_shared_root" | awk 'NF {n++} END {print n+0}')" -eq 1
test -d "$vm_runtime/$failure_sandbox"
for _ in $(seq 1 300); do
  failed_generations=$(find "$failure_shared_root/rootfs" "$failure_shared_root/volumes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  failed_mounts=$(findmnt -rn -o TARGET | awk -v root="$failure_shared_root/" 'index($1, root) == 1 {n++} END {print n+0}')
  if test "$failed_generations" -eq 0 && test "$failed_mounts" -eq 0; then break; fi
  sleep .1
done
find "$failure_shared_root" -mindepth 1 -printf '%P\t%y\t%m\n' | sort >"$evidence/failed-task-tree-before-pod-delete.tsv"
findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS | awk -v root="$failure_shared_root/" 'index($1, root) == 1' >"$evidence/failed-task-mounts-before-pod-delete.txt"
test "$failed_generations" -eq 0
test "$failed_mounts" -eq 0
test -d "$vm_runtime/$failure_sandbox"
printf 'S31B_FAILED_TASK_CLEAN sandbox=%s generations=0 mounts=0 vm=alive\n' "$failure_sandbox" | tee -a "$evidence/summary.txt"
delete_owned "$failure_pod"
assert_baseline after-failure
test $(( $(lease_records) - leases_before )) -eq 2
printf 'S31B_FAILURE_CLEANUP_OK sandbox=%s active_leases=0 durable_tombstone_delta=2 evidence=%s\n' \
  "$failure_sandbox" "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
