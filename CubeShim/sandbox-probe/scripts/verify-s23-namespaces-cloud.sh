#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
expected_shim_sha=0b89ae6d33bbe5cb5e10a02ba490fc4d9aae56d768863c30de7712bac242a4d5
expected_agent_sha=b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
live_agent=/data/cubelet/s13-kubernetes/assets/agent
image_warm_mount=/run/cubesandbox-s23-image-warmup
default_pod=cubesandbox-s23-default
shared_pod=cubesandbox-s23-shared
hostnet_pod=cubesandbox-s23-hostnetwork
hostpid_pod=cubesandbox-s23-hostpid
hostipc_pod=cubesandbox-s23-hostipc
pods=("$default_pod" "$shared_pod" "$hostnet_pod" "$hostpid_pod" "$hostipc_pod")
evidence=/data/cubelet/s2.3-evidence/namespaces-$(date -u +%Y%m%dT%H%M%SZ)
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
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort \
    >"$evidence/cube-shims-$tag.txt"
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && /cube-runtime-reaper/ {print}' | sort \
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
  local tag=$1 attempt kind
  for attempt in $(seq 1 1200); do
    capture_state "$tag"
    if state_matches_baseline "$tag"; then
      printf 'S23_BASELINE_CLEAN case=%s wait_attempt=%s lease_records=%s\n' \
        "$tag" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep 0.1
  done
  capture_state "$tag"
  for kind in containers tasks sandboxes snapshots netns cube-shims cube-reapers vm-runtime resources; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" \
      >"$evidence/$kind-$tag.diff" 2>&1 || true
  done
  return 1
}

delete_owned_one() {
  local pod=$1
  if "${kube[@]}" get pod "$pod" >/dev/null 2>&1; then
    test "$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.labels.cubesandbox\.io/s23-owned}')" = true \
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

sandbox_for_uid() {
  local ids count
  ids="$("${cri[@]}" pods -o json \
    | jq -r --arg uid "$1" '.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id')" \
    || return 1
  count="$(printf '%s\n' "$ids" | awk 'NF {count++} END {print count+0}')"
  test "$count" -eq 1 || return 1
  printf '%s\n' "$ids"
}

shim_pid_for_sandbox() {
  local pids count
  pids="$(ps -eo pid=,args= \
    | awk -v id="$1" '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {print $1}')" \
    || return 1
  count="$(printf '%s\n' "$pids" | awk 'NF {count++} END {print count+0}')"
  test "$count" -eq 1 || return 1
  printf '%s\n' "$pids"
}

active_rootfs() {
  local roots count
  roots="$(find "$shared" -mindepth 1 -maxdepth 1 -type d -print)" || return 1
  count="$(printf '%s\n' "$roots" | awk 'NF {count++} END {print count+0}')"
  test "$count" -eq 1 || return 1
  printf '%s/rootfs\n' "$roots"
}

assert_export() {
  test "$(find "$1" -mindepth 1 -maxdepth 1 -type d -name "$2-*" 2>/dev/null | wc -l)" -eq "$3"
}

namespace_row() {
  "${kube[@]}" exec "$1" -c "$2" -- sh -c \
    'for ns in net ipc uts pid mnt; do printf "%s " "$(readlink /proc/self/ns/$ns)"; done; hostname'
}

wait_rejection() {
  local pod=$1 expected=$2 out=$3 uid
  uid="$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.uid}')"
  test -n "$uid"
  for _ in $(seq 1 1200); do
    "${kube[@]}" get events --field-selector "involvedObject.name=$pod" -o json >"$out"
    if jq -r --arg uid "$uid" '.items[] | select(.involvedObject.uid == $uid) | .message' "$out" \
      | grep -Fq "$expected"; then return 0; fi
    sleep 0.1
  done
  return 1
}

save_diagnostics() {
  local pod
  for pod in "${pods[@]}"; do
    "${kube[@]}" get pod "$pod" -o json >"$evidence/$pod-final.json" 2>&1 || true
  done
  "${cri[@]}" pods >"$evidence/cri-pods.txt" 2>&1 || true
  "${cri[@]}" ps -a >"$evidence/cri-containers.txt" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
}

cleanup() {
  local rc=$? pod
  set +e
  save_diagnostics
  for pod in "${pods[@]}"; do delete_owned_one "$pod"; done
  if mountpoint -q "$image_warm_mount"; then
    "${ctr[@]}" images unmount --snapshotter overlayfs --rm "$image_warm_mount" >/dev/null 2>&1 || true
  fi
  rmdir "$image_warm_mount" >/dev/null 2>&1 || true
  wait_runtime_idle
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

systemctl is-active --quiet containerd
systemctl is-active --quiet cubesandbox-s13-runtime-resource.service
test "$(sha256sum /usr/local/bin/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
test "$(sha256sum "$live_agent" | awk '{print $1}')" = "$expected_agent_sha"
"${kube[@]}" get --raw=/readyz | grep -Fxq ok
"${kube[@]}" get node "$node" -o json \
  | jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' >/dev/null
for pod in "${pods[@]}"; do delete_owned_one "$pod"; done
wait_runtime_idle
# Make the immutable image layer snapshot part of the baseline. containerd
# keeps that layer after a Pod exits; only the per-container active snapshot
# must disappear. Mount/unmount --rm performs a local unpack without relying
# on registry access and removes the temporary view snapshot.
install -d -m 0755 "$image_warm_mount"
"${ctr[@]}" images mount --snapshotter overlayfs docker.io/library/busybox:1.36.1 "$image_warm_mount" \
  >"$evidence/image-warm-mount.txt"
"${ctr[@]}" images unmount --snapshotter overlayfs --rm "$image_warm_mount" \
  >"$evidence/image-warm-unmount.txt"
rmdir "$image_warm_mount"
capture_state before
leases_before="$(lease_records)"

"${kube[@]}" apply -f - >"$evidence/default-apply.txt" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $default_pod
  labels: {cubesandbox.io/s23-owned: "true"}
spec:
  runtimeClassName: cube
  nodeName: $node
  hostname: s23-default-host
  automountServiceAccountToken: false
  restartPolicy: Always
  terminationGracePeriodSeconds: 2
  containers:
  - name: alpha
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 701"]
  - name: beta
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 702"]
EOF
"${kube[@]}" wait --for=condition=Ready "pod/$default_pod" --timeout=300s >"$evidence/default-wait.txt"
"${kube[@]}" get pod "$default_pod" -o json >"$evidence/default.json"
default_uid="$(jq -r '.metadata.uid' "$evidence/default.json")"
default_ip="$(jq -r '.status.podIP' "$evidence/default.json")"
default_sandbox="$(sandbox_for_uid "$default_uid")"
default_shim="$(shim_pid_for_sandbox "$default_sandbox")"
test -d "$vm_runtime/$default_sandbox"
test -n "$default_ip"
test "$default_ip" != null
read -r da_net da_ipc da_uts da_pid da_mnt da_host < <(namespace_row "$default_pod" alpha | tee "$evidence/default-alpha-ns.txt")
read -r db_net db_ipc db_uts db_pid db_mnt db_host < <(namespace_row "$default_pod" beta | tee "$evidence/default-beta-ns.txt")
test "$da_net" = "$db_net"
test "$da_ipc" = "$db_ipc"
test "$da_uts" = "$db_uts"
test "$da_pid" != "$db_pid"
test "$da_mnt" != "$db_mnt"
test "$da_host" = s23-default-host
test "$db_host" = s23-default-host
"${kube[@]}" exec "$default_pod" -c alpha -- ps -o pid,comm,args >"$evidence/default-alpha-ps.txt"
"${kube[@]}" exec "$default_pod" -c beta -- ps -o pid,comm,args >"$evidence/default-beta-ps.txt"
grep -Fq 'sleep 701' "$evidence/default-alpha-ps.txt"
! grep -Fq 'sleep 702' "$evidence/default-alpha-ps.txt"
grep -Fq 'sleep 702' "$evidence/default-beta-ps.txt"
! grep -Fq 'sleep 701' "$evidence/default-beta-ps.txt"
"${kube[@]}" exec "$default_pod" -c alpha -- sh -c 'printf s23-shm-token >/dev/shm/s23-token'
"${kube[@]}" exec "$default_pod" -c beta -- cat /dev/shm/s23-token >"$evidence/default-shm.txt"
grep -Fxq s23-shm-token "$evidence/default-shm.txt"
printf 'S23_DEFAULT_OK sandbox=%s pod_ip=%s net_ipc_uts=shared pid=isolated mount=isolated hostname=ok shm=shared\n' \
  "$default_sandbox" "$default_ip" | tee -a "$evidence/summary.txt"
"${kube[@]}" delete pod "$default_pod" --wait=true >"$evidence/default-delete.txt"
assert_baseline after-default
test $(( $(lease_records) - leases_before )) -eq 1

"${kube[@]}" apply -f - >"$evidence/shared-apply.txt" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $shared_pod
  labels: {cubesandbox.io/s23-owned: "true"}
spec:
  runtimeClassName: cube
  nodeName: $node
  hostname: s23-shared-host
  shareProcessNamespace: true
  automountServiceAccountToken: false
  restartPolicy: Always
  terminationGracePeriodSeconds: 2
  containers:
  - name: alpha
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 711"]
    securityContext:
      capabilities:
        add: ["SYS_PTRACE"]
  - name: beta
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 712"]
EOF
"${kube[@]}" wait --for=condition=Ready "pod/$shared_pod" --timeout=300s >"$evidence/shared-wait.txt"
"${kube[@]}" get pod "$shared_pod" -o json >"$evidence/shared.json"
shared_uid="$(jq -r '.metadata.uid' "$evidence/shared.json")"
shared_ip="$(jq -r '.status.podIP' "$evidence/shared.json")"
shared_sandbox="$(sandbox_for_uid "$shared_uid")"
shared_shim="$(shim_pid_for_sandbox "$shared_sandbox")"
test -d "$vm_runtime/$shared_sandbox"
read -r sa_net sa_ipc sa_uts sa_pid sa_mnt sa_host < <(namespace_row "$shared_pod" alpha | tee "$evidence/shared-alpha-ns.txt")
read -r sb_net sb_ipc sb_uts sb_pid sb_mnt sb_host < <(namespace_row "$shared_pod" beta | tee "$evidence/shared-beta-ns.txt")
test "$sa_net" = "$sb_net"
test "$sa_ipc" = "$sb_ipc"
test "$sa_uts" = "$sb_uts"
test "$sa_pid" = "$sb_pid"
test "$sa_mnt" != "$sb_mnt"
test "$sa_host" = s23-shared-host
test "$sb_host" = s23-shared-host
"${kube[@]}" exec "$shared_pod" -c alpha -- ps -o pid,comm,args >"$evidence/shared-alpha-ps.txt"
"${kube[@]}" exec "$shared_pod" -c beta -- ps -o pid,comm,args >"$evidence/shared-beta-ps.txt"
for file in "$evidence/shared-alpha-ps.txt" "$evidence/shared-beta-ps.txt"; do
  grep -Fq 'sleep 711' "$file"
  grep -Fq 'sleep 712' "$file"
  grep -Eq '^ *1 +cube-pid-init +' "$file"
  for seconds in 711 712; do
    workload_pid="$(awk -v command="sleep $seconds" 'index($0, command) {print $1; exit}' "$file")"
    test -n "$workload_pid"
    test "$workload_pid" -gt 1
  done
done
holder_identity_before="$("${kube[@]}" exec "$shared_pod" -c alpha -- awk '{print $1, $2, $22}' /proc/1/stat)"
printf '%s\n' "$holder_identity_before" | tee "$evidence/shared-holder-identity-before.txt" | grep -Eq '^1 \(cube-pid-init\) [0-9]+$'
"${kube[@]}" exec "$shared_pod" -c alpha -- sh -ceu '
  test "$(awk "/^Uid:/ {print \$2, \$3, \$4, \$5}" /proc/1/status)" = "65534 65534 65534 65534"
  test "$(awk "/^Gid:/ {print \$2, \$3, \$4, \$5}" /proc/1/status)" = "65534 65534 65534 65534"
  test "$(awk "/^NoNewPrivs:/ {print \$2}" /proc/1/status)" = 1
  for field in CapInh CapPrm CapEff CapBnd CapAmb; do
    test "$(awk -v field="$field:" "\$1 == field {print \$2}" /proc/1/status)" = 0000000000000000
  done
  test "$(find /proc/1/root -mindepth 1 -maxdepth 1 -print -quit)" = ""
  test "$(find /proc/1/fd -mindepth 1 -maxdepth 1 | wc -l)" -eq 3
  holder_exe="$(readlink /proc/1/exe)"
  case "$holder_exe" in *cube-pidns-holder) ;; *) exit 1 ;; esac
' >"$evidence/shared-holder-hardening.txt"
# A normal workload without SYS_PTRACE must not traverse the non-dumpable
# holder root; the capability-enabled alpha above proves the root is empty.
"${kube[@]}" exec "$shared_pod" -c beta -- sh -ceu '! ls /proc/1/root/ >/dev/null 2>&1'
shared_alpha="$(jq -r '.status.containerStatuses[] | select(.name == "alpha") | .containerID | sub("^containerd://"; "")' "$evidence/shared.json")"
shared_beta="$(jq -r '.status.containerStatuses[] | select(.name == "beta") | .containerID | sub("^containerd://"; "")' "$evidence/shared.json")"
shared_rootfs="$(active_rootfs)"
assert_export "$shared_rootfs" "$shared_alpha" 1
assert_export "$shared_rootfs" "$shared_beta" 1
"${cri[@]}" stop --timeout 0 "$shared_alpha" >"$evidence/shared-alpha-stop.txt"
for _ in $(seq 1 300); do
  if "${cri[@]}" inspect "$shared_alpha" | jq -e '.status.state == "CONTAINER_EXITED"' >/dev/null 2>&1; then break; fi
  sleep 0.1
done
"${cri[@]}" inspect "$shared_alpha" | jq -e '.status.state == "CONTAINER_EXITED" and .status.exitCode == 137' >/dev/null
"${cri[@]}" inspect "$shared_beta" | jq -e '.status.state == "CONTAINER_RUNNING"' >/dev/null
"${cri[@]}" rm "$shared_alpha" >"$evidence/shared-alpha-rm.txt"
shared_alpha_new=
for _ in $(seq 1 1200); do
  "${kube[@]}" get pod "$shared_pod" -o json >"$evidence/shared-after-restart.json"
  shared_alpha_new="$(jq -r --arg old "$shared_alpha" '.status.containerStatuses[]? | select(.name == "alpha" and .state.running != null) | .containerID | sub("^containerd://"; "") | select(. != $old)' "$evidence/shared-after-restart.json")"
  if test -n "$shared_alpha_new" \
    && jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' "$evidence/shared-after-restart.json" >/dev/null; then break; fi
  sleep 0.1
done
test -n "$shared_alpha_new"
test "$shared_alpha_new" != "$shared_alpha"
test "$(jq -r '.status.containerStatuses[] | select(.name == "beta") | .containerID | sub("^containerd://"; "")' "$evidence/shared-after-restart.json")" = "$shared_beta"
test "$(jq -r '.metadata.uid' "$evidence/shared-after-restart.json")" = "$shared_uid"
test "$(jq -r '.status.podIP' "$evidence/shared-after-restart.json")" = "$shared_ip"
test "$(sandbox_for_uid "$shared_uid")" = "$shared_sandbox"
test "$(shim_pid_for_sandbox "$shared_sandbox")" = "$shared_shim"
read -r sr_net sr_ipc sr_uts sr_pid sr_mnt sr_host < <(namespace_row "$shared_pod" alpha | tee "$evidence/shared-alpha-restarted-ns.txt")
test "$sr_net" = "$sa_net"
test "$sr_ipc" = "$sa_ipc"
test "$sr_uts" = "$sa_uts"
test "$sr_pid" = "$sa_pid"
test "$sr_mnt" != "$sb_mnt"
test "$sr_host" = s23-shared-host
"${kube[@]}" exec "$shared_pod" -c beta -- ps -o pid,comm,args >"$evidence/shared-beta-after-restart-ps.txt"
grep -Fq 'sleep 711' "$evidence/shared-beta-after-restart-ps.txt"
grep -Fq 'sleep 712' "$evidence/shared-beta-after-restart-ps.txt"
grep -Eq '^ *1 +cube-pid-init +' "$evidence/shared-beta-after-restart-ps.txt"
for seconds in 711 712; do
  workload_pid="$(awk -v command="sleep $seconds" 'index($0, command) {print $1; exit}' "$evidence/shared-beta-after-restart-ps.txt")"
  test -n "$workload_pid"
  test "$workload_pid" -gt 1
done
holder_identity_after="$("${kube[@]}" exec "$shared_pod" -c alpha -- awk '{print $1, $2, $22}' /proc/1/stat)"
printf '%s\n' "$holder_identity_after" | tee "$evidence/shared-holder-identity-after.txt"
test "$holder_identity_after" = "$holder_identity_before"
! grep -Fxq "$shared_alpha" < <("${ctr[@]}" tasks list -q)
grep -Fxq "$shared_alpha_new" < <("${ctr[@]}" tasks list -q)
grep -Fxq "$shared_beta" < <("${ctr[@]}" tasks list -q)
assert_export "$shared_rootfs" "$shared_alpha" 0
assert_export "$shared_rootfs" "$shared_alpha_new" 1
assert_export "$shared_rootfs" "$shared_beta" 1
printf 'S23_SHARED_PID_OK sandbox=%s pod_ip=%s pid=%s holder_pid1=ok holder_hardened=ok restart_join=ok survivor=ok\n' \
  "$shared_sandbox" "$shared_ip" "$sa_pid" | tee -a "$evidence/summary.txt"
"${kube[@]}" delete pod "$shared_pod" --wait=true >"$evidence/shared-delete.txt"
assert_baseline after-shared
test $(( $(lease_records) - leases_before )) -eq 2

for case in \
  "$hostnet_pod:hostNetwork:hostNetwork is not supported by RuntimeClass cube" \
  "$hostpid_pod:hostPID:hostPID is not supported by RuntimeClass cube" \
  "$hostipc_pod:hostIPC:hostIPC is not supported by RuntimeClass cube"; do
  IFS=: read -r pod field expected <<<"$case"
  "${kube[@]}" apply -f - >"$evidence/$field-apply.txt" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels: {cubesandbox.io/s23-owned: "true"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 2
  $field: true
  containers:
  - name: app
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 721"]
EOF
  wait_rejection "$pod" "$expected" "$evidence/$field-events.json"
  "${kube[@]}" get pod "$pod" -o json >"$evidence/$field-pod.json"
  jq -e '.status.phase == "Pending" and ([.status.containerStatuses[]? | select(.containerID != null)] | length) == 0' \
    "$evidence/$field-pod.json" >/dev/null
  test $(( $(lease_records) - leases_before )) -eq 2
  delete_owned_one "$pod"
  assert_baseline "after-$field"
  test $(( $(lease_records) - leases_before )) -eq 2
  printf 'S23_HOST_NAMESPACE_REJECT_OK field=%s message=%s resources=baseline\n' \
    "$field" "$expected" | tee -a "$evidence/summary.txt"
done

save_diagnostics
printf 'S23_NAMESPACES_OK default_pid=isolated shared_pid=ok shared_restart=ok host_rejections=3 active_leases=0 durable_tombstone_delta=2 vm_runtime=baseline shim_sha256=%s agent_sha256=%s evidence=%s\n' \
  "$expected_shim_sha" "$expected_agent_sha" "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
