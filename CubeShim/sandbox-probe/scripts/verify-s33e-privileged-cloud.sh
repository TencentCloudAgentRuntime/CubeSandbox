#!/usr/bin/env bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
vm_runtime=/run/vc/vm
fragment=/etc/containerd/conf.d/95-cubesandbox-s33e-privileged.toml
image='docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'
node=vm-200-2-ubuntu
token=s33e-final-$(date -u +%Y%m%dT%H%M%SZ)-$$
evidence=/data/cubelet/s3.3-evidence/$token
pods=(
  cubesandbox-s33e-off-normal
  cubesandbox-s33e-off-privileged
  cubesandbox-s33e-on-normal
  cubesandbox-s33e-on-privileged
  cubesandbox-s33e-host-dev
)
cleanup_rc=0
mkdir -m 0700 "$evidence"

count_entries() {
  local entries
  if test ! -d "$1"; then printf '0\n'; return 0; fi
  entries=$(find "$1" -mindepth 1 -printf '.\n') || return 1
  printf '%s\n' "$entries" | awk 'NF {n++} END {print n+0}'
}

count_files() {
  local entries
  entries=$(find "$1" -type f -name "$2" -printf '.\n') || return 1
  printf '%s\n' "$entries" | awk 'NF {n++} END {print n+0}'
}

active_leases() {
  local paths record count=0 rc
  paths=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    if jq -e '.active == null' "$record" >/dev/null; then
      :
    else
      rc=$?
      test "$rc" -eq 1 || return 1
      count=$((count + 1))
    fi
  done <<<"$paths"
  printf '%s\n' "$count"
}

shared_mounts() {
  local mounts
  mounts=$(findmnt -rn -o TARGET) || return 1
  awk -v root="$shared/" 'index($1, root) == 1 {n++} END {print n+0}' <<<"$mounts"
}

cube_pod_count() {
  local pods
  pods=$("${kube[@]}" get pods -A -o json) || return 1
  jq -er '[.items[] | select(.spec.runtimeClassName=="cube")] | length' <<<"$pods"
}

capture_runtime_state() {
  local tag=$1 adapter shared_count reaper_count cleanup_count mount_count lease_count shim_count vm_count pod_count
  adapter=$(count_files "$runtime_state/adapter" '*') || return 1
  shared_count=$(count_entries "$shared") || return 1
  reaper_count=$(count_entries "$reaper") || return 1
  cleanup_count=$(count_files /run/containerd cube-runtime-resource.json) || return 1
  mount_count=$(shared_mounts) || return 1
  lease_count=$(active_leases) || return 1
  shim_count=$(ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {n++} END {print n+0}') || return 1
  vm_count=$(count_entries "$vm_runtime") || return 1
  pod_count=$(cube_pod_count) || return 1
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s cube_shims=%s vm_entries=%s cube_pods=%s\n' \
    "$adapter" "$shared_count" "$reaper_count" "$cleanup_count" "$mount_count" "$lease_count" \
    "$shim_count" "$vm_count" "$pod_count" >"$evidence/runtime-state-$tag.txt"
}

assert_baseline() {
  local tag=$1
  for _ in $(seq 1 1800); do
    if capture_runtime_state "$tag" && cmp -s "$evidence/runtime-state-before.txt" "$evidence/runtime-state-$tag.txt"; then
      return 0
    fi
    sleep .1
  done
  capture_runtime_state "$tag"
  cmp "$evidence/runtime-state-before.txt" "$evidence/runtime-state-$tag.txt"
}

pods_absent() {
  local pod
  for pod in "${pods[@]}"; do
    test -z "$("${kube[@]}" get pod "$pod" --ignore-not-found -o name)" || return 1
  done
}

delete_owned_pods() {
  local pod object owner run delete_rc=0
  for pod in "${pods[@]}"; do
    object=$("${kube[@]}" get pod "$pod" --ignore-not-found -o json 2>/dev/null || true)
    test -n "$object" || continue
    owner=$(jq -r '.metadata.labels["cubesandbox.io/s33e-owner"]//""' <<<"$object")
    run=$(jq -r '.metadata.labels["cubesandbox.io/s33e-run"]//""' <<<"$object")
    if test "$owner" = true && test "$run" = "$token"; then
      "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null || delete_rc=1
    else
      printf 'refuse to delete unowned pod %s owner=%s run=%s\n' "$pod" "$owner" "$run" >&2
      delete_rc=1
    fi
  done
  return "$delete_rc"
}

wait_quiescent() {
  local shims
  for _ in $(seq 1 1800); do
    shims=$(ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {n++} END {print n+0}')
    if pods_absent && test "$shims" -eq 0 && test "$(active_leases)" -eq 0; then return 0; fi
    sleep .1
  done
  return 1
}

wait_node_ready() {
  for _ in $(seq 1 1200); do
    if test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True; then return 0; fi
    sleep .1
  done
  return 1
}

set_switch() {
  local value=$1
  test "$value" = true || test "$value" = false
  test "$(grep -Ec 'CUBE_ALLOW_PRIVILEGED=(true|false)' "$fragment")" -eq 1
  sed -i -E "s/CUBE_ALLOW_PRIVILEGED=(true|false)/CUBE_ALLOW_PRIVILEGED=$value/" "$fragment"
  grep -Fxq "  env = ['CUBE_ALLOW_PRIVILEGED=$value']" "$fragment"
  systemctl restart containerd
  for _ in $(seq 1 300); do systemctl is-active --quiet containerd && break; sleep .1; done
  systemctl is-active --quiet containerd
  wait_node_ready
  containerd config dump >"$evidence/containerd-config-switch-$value.toml"
  grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=$value']" "$evidence/containerd-config-switch-$value.toml"
}

wait_failed_with() {
  local pod=$1 needle=$2 object message reason
  for _ in $(seq 1 1200); do
    object=$("${kube[@]}" get pod "$pod" -o json)
    reason=$(jq -r '.status.containerStatuses[0].state.waiting.reason//.status.containerStatuses[0].state.terminated.reason//""' <<<"$object")
    message=$(jq -r '.status.containerStatuses[0].state.waiting.message//.status.containerStatuses[0].state.terminated.message//""' <<<"$object")
    if [[ "$reason" == *Error* ]] && [[ "$message" == *"$needle"* ]]; then
      printf '%s\n' "$object" >"$evidence/pod-$pod.json"
      printf 'reason=%s\nmessage=%s\n' "$reason" "$message" >"$evidence/error-$pod.txt"
      "${kube[@]}" describe pod "$pod" >"$evidence/describe-$pod.txt"
      return 0
    fi
    sleep .25
  done
  "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-$pod-timeout.json"
  "${kube[@]}" describe pod "$pod" >"$evidence/describe-$pod-timeout.txt"
  return 1
}

container_id_for_uid() {
  local uid=$1
  "${cri[@]}" ps -a -o json | jq -er --arg uid "$uid" \
    '[.containers[] | select(.labels["io.kubernetes.pod.uid"]==$uid)] | sort_by(.createdAt) | last | .id'
}

collect_positive() {
  local mode=$1 pod=cubesandbox-s33e-on-$1 uid cid
  "${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=300s >"$evidence/wait-$mode.txt"
  "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-$mode.json"
  uid=$(jq -er '.metadata.uid' "$evidence/pod-$mode.json")
  for _ in $(seq 1 600); do
    if cid=$(container_id_for_uid "$uid" 2>/dev/null); then break; fi
    sleep .1
  done
  test -n "${cid:-}"
  "${cri[@]}" inspect "$cid" >"$evidence/cri-$mode.json" 2>"$evidence/cri-$mode.stderr"
  jq -S '.info.runtimeSpec' "$evidence/cri-$mode.json" >"$evidence/oci-$mode.json"
  "${kube[@]}" logs "$pod" >"$evidence/guest-$mode.txt"
}

collect_shim_env() {
  local pid count=0
  : >"$evidence/shim-environments.txt"
  while IFS= read -r pid; do
    test -n "$pid" || continue
    tr '\0' '\n' <"/proc/$pid/environ" | grep '^CUBE_ALLOW_PRIVILEGED=' >>"$evidence/shim-environments.txt"
    count=$((count + 1))
  done < <(ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print $1}')
  test "$count" -eq 2
  test "$(grep -Fxc 'CUBE_ALLOW_PRIVILEGED=true' "$evidence/shim-environments.txt")" -eq 2
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e
  delete_owned_pods || cleanup_rc=1
  wait_quiescent || cleanup_rc=1
  if grep -Fq 'CUBE_ALLOW_PRIVILEGED=true' "$fragment"; then set_switch false || cleanup_rc=1; fi
  systemctl is-active --quiet containerd || cleanup_rc=1
  systemctl is-active --quiet kubelet || cleanup_rc=1
  wait_node_ready || cleanup_rc=1
  if test -f "$evidence/runtime-state-before.txt"; then
    assert_baseline cleanup || cleanup_rc=1
  else
    cleanup_rc=1
  fi
  printf 'original_rc=%s cleanup_rc=%s switch=false pods_absent=%s active_leases=%s\n' \
    "$rc" "$cleanup_rc" "$(pods_absent && echo true || echo false)" "$(active_leases 2>/dev/null || echo unknown)" \
    >"$evidence/cleanup-result.txt"
  if test "$cleanup_rc" -ne 0; then exit 1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$("${kube[@]}" get node "$node" -o name)" = "node/$node"
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
"${kube[@]}" get nodes -o wide >"$evidence/nodes-before.txt"
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False
test -f "$fragment"
test ! -L "$fragment"
grep -Fxq "  env = ['CUBE_ALLOW_PRIVILEGED=false']" "$fragment"
test "$(grep -Ec 'CUBE_ALLOW_PRIVILEGED=(true|false)' "$fragment")" -eq 1
pods_absent
wait_quiescent
capture_runtime_state before
grep -Fxq 'adapter=0 shared=0 reaper=0 cleanup=0 mounts=0 active_leases=0 cube_shims=0 vm_entries=0 cube_pods=0' "$evidence/runtime-state-before.txt"

containerd config dump >"$evidence/containerd-config-initial.toml"
grep -Fq 'privileged_without_host_devices = true' "$evidence/containerd-config-initial.toml"
grep -Fq 'privileged_without_host_devices_all_devices_allowed = true' "$evidence/containerd-config-initial.toml"
grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=false']" "$evidence/containerd-config-initial.toml"

cat >"$evidence/off.yaml" <<PODS
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s33e-off-normal
  labels: {cubesandbox.io/s33e-owner: "true", cubesandbox.io/s33e-run: "$token"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", "echo ORDINARY=ready; exec sleep 600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s33e-off-privileged
  labels: {cubesandbox.io/s33e-owner: "true", cubesandbox.io/s33e-run: "$token"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", "exec sleep 600"]
    securityContext: {privileged: true}
PODS
"${kube[@]}" create -f "$evidence/off.yaml" >"$evidence/create-off.txt"
"${kube[@]}" wait --for=condition=Ready pod/cubesandbox-s33e-off-normal --timeout=300s >"$evidence/wait-off-normal.txt"
"${kube[@]}" logs cubesandbox-s33e-off-normal >"$evidence/guest-off-normal.txt"
grep -Fxq ORDINARY=ready "$evidence/guest-off-normal.txt"
wait_failed_with cubesandbox-s33e-off-privileged 'CUBE_ALLOW_PRIVILEGED=true is required'
off_uid=$(jq -er '.metadata.uid' "$evidence/pod-cubesandbox-s33e-off-privileged.json")
"${cri[@]}" ps -o json >"$evidence/cri-running-off.json"
test "$(jq --arg uid "$off_uid" '[.containers[] | select(.labels["io.kubernetes.pod.uid"]==$uid)] | length' "$evidence/cri-running-off.json")" -eq 0
delete_owned_pods
wait_quiescent
assert_baseline after-off

set_switch true
cat >"$evidence/on.yaml" <<PODS
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s33e-on-normal
  labels: {cubesandbox.io/s33e-owner: "true", cubesandbox.io/s33e-run: "$token"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", "grep -E '^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp):' /proc/self/status; printf 'DEV_KVM=%s\\n' \"\$(test -e /dev/kvm && echo present || echo absent)\"; if mount -t tmpfs tmpfs /mnt 2>/dev/null; then echo MOUNT=unexpected-success; umount /mnt; else echo MOUNT=denied; fi; if test -e /sys/fs/cgroup/cgroup.controllers; then echo CGROUP_MODE=v2; else echo CGROUP_MODE=v1; fi; if test -r /sys/fs/cgroup/devices/devices.list; then sed 's/^/DEVICE_RULE=/' /sys/fs/cgroup/devices/devices.list; else echo DEVICE_LIST=missing; fi; exec sleep 600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s33e-on-privileged
  labels: {cubesandbox.io/s33e-owner: "true", cubesandbox.io/s33e-run: "$token"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", "grep -E '^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp):' /proc/self/status; printf 'DEV_KVM=%s\\n' \"\$(test -e /dev/kvm && echo present || echo absent)\"; mkdir -p /mnt/priv-test; mount -t tmpfs tmpfs /mnt/priv-test; echo MOUNT=allowed; umount /mnt/priv-test; if test -e /sys/fs/cgroup/cgroup.controllers; then echo CGROUP_MODE=v2; else echo CGROUP_MODE=v1; fi; if test -r /sys/fs/cgroup/devices/devices.list; then sed 's/^/DEVICE_RULE=/' /sys/fs/cgroup/devices/devices.list; else echo DEVICE_LIST=missing; fi; exec sleep 600"]
    securityContext: {privileged: true}
PODS
"${kube[@]}" create -f "$evidence/on.yaml" >"$evidence/create-on.txt"
collect_positive normal
collect_positive privileged
collect_shim_env

test "$(jq '.linux.devices//[]|length' "$evidence/oci-privileged.json")" -eq 0
test "$(jq '.linux.resources.devices//[]|length' "$evidence/oci-privileged.json")" -eq 1
test "$(jq '[.linux.resources.devices[]?|select(.allow==true and (.type==null) and (.major==null) and (.minor==null) and .access=="rwm")]|length' "$evidence/oci-privileged.json")" -eq 1
test "$(jq '[.mounts[]?|select((.source//"")|startswith("/dev"))]|length' "$evidence/oci-privileged.json")" -eq 0
test "$(jq '.linux.resources.devices//[]|length' "$evidence/oci-normal.json")" -eq 1
test "$(jq '[.linux.resources.devices[]?|select(.allow==true and (.type==null) and (.major==null) and (.minor==null) and .access=="rwm")]|length' "$evidence/oci-normal.json")" -eq 0
test "$(jq '.process.capabilities.bounding|length' "$evidence/oci-privileged.json")" -eq 41

grep -Eq '^CapEff:[[:space:]]+000001ffffffffff$' "$evidence/guest-privileged.txt"
grep -Eq '^CapPrm:[[:space:]]+000001ffffffffff$' "$evidence/guest-privileged.txt"
grep -Eq '^CapBnd:[[:space:]]+000001ffffffffff$' "$evidence/guest-privileged.txt"
grep -Eq '^CapInh:[[:space:]]+0000000000000000$' "$evidence/guest-privileged.txt"
grep -Eq '^CapAmb:[[:space:]]+0000000000000000$' "$evidence/guest-privileged.txt"
grep -Fxq DEV_KVM=absent "$evidence/guest-privileged.txt"
grep -Fxq MOUNT=allowed "$evidence/guest-privileged.txt"
grep -Eq '^CapEff:[[:space:]]+00000000a80425fb$' "$evidence/guest-normal.txt"
grep -Eq '^CapPrm:[[:space:]]+00000000a80425fb$' "$evidence/guest-normal.txt"
grep -Eq '^CapBnd:[[:space:]]+00000000a80425fb$' "$evidence/guest-normal.txt"
grep -Eq '^CapInh:[[:space:]]+0000000000000000$' "$evidence/guest-normal.txt"
grep -Eq '^CapAmb:[[:space:]]+0000000000000000$' "$evidence/guest-normal.txt"
grep -Fxq DEV_KVM=absent "$evidence/guest-normal.txt"
grep -Fxq MOUNT=denied "$evidence/guest-normal.txt"
if grep -Fxq CGROUP_MODE=v2 "$evidence/guest-privileged.txt"; then
    grep -Fxq CGROUP_MODE=v2 "$evidence/guest-normal.txt"
    grep -Fxq DEVICE_LIST=missing "$evidence/guest-privileged.txt"
    grep -Fxq DEVICE_LIST=missing "$evidence/guest-normal.txt"
    guest_device_e2e='unobservable-cgroup-v2,agent-wildcard-unit=passed-separately'
else
    grep -Fxq CGROUP_MODE=v1 "$evidence/guest-privileged.txt"
    grep -Fxq CGROUP_MODE=v1 "$evidence/guest-normal.txt"
    if grep -Fxq DEVICE_LIST=missing "$evidence/guest-privileged.txt"; then exit 1; fi
    if grep -Fxq DEVICE_LIST=missing "$evidence/guest-normal.txt"; then exit 1; fi
    grep -q '^DEVICE_RULE=' "$evidence/guest-privileged.txt"
    grep -q '^DEVICE_RULE=' "$evidence/guest-normal.txt"
    grep -Fxq 'DEVICE_RULE=a *:* rwm' "$evidence/guest-privileged.txt"
    if grep -Fxq 'DEVICE_RULE=a *:* rwm' "$evidence/guest-normal.txt"; then exit 1; fi
    guest_device_e2e='devices-list-all-devices'
fi

delete_owned_pods
wait_quiescent
assert_baseline after-on

cat >"$evidence/host-dev.yaml" <<PODS
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s33e-host-dev
  labels: {cubesandbox.io/s33e-owner: "true", cubesandbox.io/s33e-run: "$token"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  volumes:
  - name: host-dev
    hostPath: {path: /dev, type: Directory}
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", "exec sleep 600"]
    securityContext: {privileged: true}
    volumeMounts:
    - {name: host-dev, mountPath: /host-dev}
PODS
"${kube[@]}" create -f "$evidence/host-dev.yaml" >"$evidence/create-host-dev.txt"
wait_failed_with cubesandbox-s33e-host-dev 'Host /dev mount source'
dev_uid=$(jq -er '.metadata.uid' "$evidence/pod-cubesandbox-s33e-host-dev.json")
"${cri[@]}" ps -o json >"$evidence/cri-running-host-dev.json"
test "$(jq --arg uid "$dev_uid" '[.containers[] | select(.labels["io.kubernetes.pod.uid"]==$uid)] | length' "$evidence/cri-running-host-dev.json")" -eq 0
if dev_cid=$(container_id_for_uid "$dev_uid" 2>/dev/null); then
  "${cri[@]}" inspect "$dev_cid" >"$evidence/cri-host-dev.json" 2>"$evidence/cri-host-dev.stderr"
  jq -S '.info.runtimeSpec' "$evidence/cri-host-dev.json" >"$evidence/oci-host-dev.json"
  test "$(jq '[.mounts[]?|select((.source//"")|startswith("/dev"))]|length' "$evidence/oci-host-dev.json")" -ge 1
fi
delete_owned_pods
wait_quiescent
assert_baseline after-host-dev

set_switch false
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False
assert_baseline final
printf 'switch_off=ordinary-ready,privileged-rejected switch_on=ordinary-confined,privileged-guest-only guest_device_e2e=%s host_dev=rejected exact_runtime_baseline=true\n' "$guest_device_e2e" >"$evidence/summary.txt"
cat "$evidence/summary.txt"
printf 'S33E_FINAL_E2E_OK evidence=%s\n' "$evidence"
