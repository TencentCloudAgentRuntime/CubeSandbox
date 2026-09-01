#!/usr/bin/env bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
socket=/run/containerd/containerd.sock
namespace=k8s.io
node=vm-200-2-ubuntu
image='docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'
helper=/data/cubelet/s3.4-input/bin/s34-resource-evidence
traced_containerd=/data/cubelet/s3.4-input/bin/containerd-s34a-trace
artifact_manifest=/data/cubelet/s3.4-input/bin/SHA256SUMS
live_containerd=/usr/local/bin/containerd
expected_original_containerd=15e00263fed22c55e75ae2b0fb89c6a0862741d5ee82728a2d4ecb99a26fbf2d
backup=/opt/cubesandbox-s34a-predeploy-backup-v1
trace_root=/run/cubesandbox-s34-trace
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
token=s34a-$(date -u +%Y%m%dT%H%M%SZ)-$$
short=${token:0:24}
evidence=/data/cubelet/s3.4-evidence/$token
pods=(
  s34a-runc-besteffort s34a-runc-burstable s34a-runc-guaranteed
  s34a-cube-besteffort s34a-cube-burstable s34a-cube-guaranteed
)
lowlevel_ids=()
start_epoch=$(date +%s)
baseline_captured=false
cleanup_rc=0
trace_deployed=false
trace_root_owned=false
workloads_started=false
pod_uids_file=$evidence/owned-pod-uids.txt

count_entries() {
  local entries
  if test ! -d "$1"; then printf '0\n'; return 0; fi
  entries=$(find "$1" -mindepth 1 -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$entries"
}

snapshot_tree() {
  local root=$1 output=$2 entries
  : >"$output" || return 1
  test -d "$root" || return 0
  entries=$(find "$root" -mindepth 1 -printf '%P\t%y\n') || return 1
  LC_ALL=C sort <<<"$entries" >"$output" || return 1
}

snapshot_active_leases() {
  local output=$1 paths record relative sandbox rc
  : >"$output" || return 1
  paths=$(find "$runtime_state/leases" -type f -name '*.json' -print | LC_ALL=C sort) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    if jq -e '.active == null' "$record" >/dev/null; then
      continue
    else
      rc=$?
      test "$rc" -eq 1 || return "$rc"
    fi
    relative=${record#"$runtime_state/leases/"}
    sandbox=$(jq -er '.sandboxID' "$record") || return 1
    printf '%s\t%s\n' "$relative" "$sandbox" >>"$output" || return 1
  done <<<"$paths"
}

capture_state() {
  local tag=$1 mounts uid compact
  local -a capture_ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io --timeout 10s)
  local -a capture_kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=10s)
  "${capture_ctr[@]}" containers list -q | LC_ALL=C sort >"$evidence/containers-$tag.txt" || return 1
  "${capture_ctr[@]}" tasks list -q | LC_ALL=C sort >"$evidence/tasks-$tag.txt" || return 1
  "${capture_ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | LC_ALL=C sort >"$evidence/sandboxes-$tag.txt" || return 1
  "${capture_ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | LC_ALL=C sort >"$evidence/snapshots-$tag.txt" || return 1
  { test ! -d /var/run/netns || find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n'; } | LC_ALL=C sort >"$evidence/netns-$tag.txt" || return 1
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | LC_ALL=C sort >"$evidence/cube-shims-$tag.txt" || return 1
  snapshot_tree "$vm_runtime" "$evidence/vm-runtime-$tag.txt" || return 1
  snapshot_tree "$runtime_state/adapter" "$evidence/adapter-$tag.txt" || return 1
  snapshot_tree "$shared" "$evidence/shared-$tag.txt" || return 1
  snapshot_tree "$reaper" "$evidence/reaper-$tag.txt" || return 1
  find "$containerd_state" -type f -name cube-runtime-resource.json -printf '%P\t%y\n' | LC_ALL=C sort >"$evidence/cleanup-markers-$tag.txt" || return 1
  mounts=$(findmnt -rn -o TARGET) || return 1
  awk -v root="$shared/" 'index($1, root) == 1 {print $1}' <<<"$mounts" | LC_ALL=C sort >"$evidence/shared-mounts-$tag.txt" || return 1
  snapshot_active_leases "$evidence/active-leases-$tag.txt" || return 1
  { test ! -d /var/lib/kubelet/pods || find /var/lib/kubelet/pods -mindepth 1 -maxdepth 1 -printf '%f\n'; } | LC_ALL=C sort >"$evidence/kubelet-pod-dirs-$tag.txt" || return 1
  find /sys/fs/cgroup -mindepth 1 -type d \( -iname '*s34a*' -o -iname '*s34-low*' \) -printf '%p\n' 2>/dev/null >"$evidence/owned-cgroups-$tag.unsorted" || return 1
  while IFS= read -r uid; do
    test -n "$uid" || continue
    compact=${uid//-/}
    find /sys/fs/cgroup -mindepth 1 -type d \( -iname "*$uid*" -o -iname "*$compact*" \) -printf '%p\n' 2>/dev/null >>"$evidence/owned-cgroups-$tag.unsorted" || return 1
  done <"$pod_uids_file" || return 1
  LC_ALL=C sort -u "$evidence/owned-cgroups-$tag.unsorted" >"$evidence/owned-cgroups-$tag.txt" || return 1
  rm -f -- "$evidence/owned-cgroups-$tag.unsorted" || return 1
  timeout --signal=KILL 10s systemctl is-active containerd kubelet cubesandbox-s13-runtime-resource.service >"$evidence/services-$tag.txt" || return 1
  "${capture_kube[@]}" get node "$node" -o json | jq -S '{conditions: [.status.conditions[] | select(.type == "Ready" or .type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") | {type,status,reason}], capacity:.status.capacity, allocatable:.status.allocatable}' >"$evidence/node-health-$tag.json" || return 1
}

run_bounded_capture() {
  local tag=$1 budget=$2
  export evidence runtime_state shared reaper containerd_state vm_runtime node pod_uids_file
  export -f snapshot_tree snapshot_active_leases capture_state
  timeout --signal=KILL "${budget}s" bash -c 'set -Eeuo pipefail; capture_state "$1"' _ "$tag"
}

state_matches_before() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime adapter shared reaper cleanup-markers shared-mounts active-leases kubelet-pod-dirs owned-cgroups; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
}

wait_node_healthy() {
  local state
  for _ in $(seq 1 1200); do
    state=$("${kube[@]}" get node "$node" -o json | jq -r '[.status.conditions[] | select(.type == "Ready" or .type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") | (.type+"="+.status)] | sort | join(",")') || return 1
    if test "$state" = 'DiskPressure=False,MemoryPressure=False,PIDPressure=False,Ready=True'; then return 0; fi
    sleep .1
  done
  return 1
}

wait_baseline() {
  local tag=$1 deadline now remaining attempts=0 capture_errors=0
  deadline=$(($(date +%s) + 300))
  while :; do
    now=$(date +%s)
    remaining=$((deadline - now))
    test "$remaining" -gt 0 || break
    attempts=$((attempts + 1))
    if run_bounded_capture "$tag" "$remaining"; then
      if state_matches_before "$tag"; then
        printf 'result=matched attempts=%s capture_errors=%s\n' "$attempts" "$capture_errors" >"$evidence/baseline-wait-$tag.txt"
        return 0
      fi
    else
      capture_errors=$((capture_errors + 1))
    fi
    test "$(date +%s)" -lt "$deadline" || break
    sleep .2
  done
  printf 'result=timeout attempts=%s capture_errors=%s\n' "$attempts" "$capture_errors" >"$evidence/baseline-wait-$tag.txt"
  return 1
}

pod_json() {
  "${kube[@]}" get pod "$1" -o json
}

remember_pod_uid() {
  local candidate=$1
  test -n "$candidate" || return 1
  grep -Fxq "$candidate" "$pod_uids_file" || printf '%s\n' "$candidate" >>"$pod_uids_file"
}

record_owned_pod_uids() {
  local pod object uid result=0
  for pod in "${pods[@]}" s34a-hugepage-reject; do
    object=$("${kube[@]}" get pod "$pod" --ignore-not-found -o json) || { result=1; continue; }
    test -n "$object" || continue
    test "$(jq -r '.metadata.labels["cubesandbox.io/s34-owned"] // ""' <<<"$object")" = true || { result=1; continue; }
    uid=$(jq -er '.metadata.uid' <<<"$object") || { result=1; continue; }
    remember_pod_uid "$uid" || result=1
  done
  return "$result"
}

delete_owned_pods() {
  local pod object result=0
  for pod in "${pods[@]}" s34a-hugepage-reject; do
    object=$("${kube[@]}" get pod "$pod" --ignore-not-found -o json) || { result=1; continue; }
    test -n "$object" || continue
    test "$(jq -r '.metadata.labels["cubesandbox.io/s34-owned"] // ""' <<<"$object")" = true || { result=1; continue; }
    "${kube[@]}" delete pod "$pod" --wait=false >/dev/null || result=1
  done
  return "$result"
}

preflight_clean_runtime() {
  local current owned_pods lowlevel_containers
  current=$(sha256sum "$live_containerd" | awk '{print $1}') || return 1
  test "$current" = "$expected_original_containerd" || return 1
  if test -e "$trace_root" || test -L "$trace_root"; then return 1; fi
  timeout --signal=KILL 10s systemctl is-active --quiet containerd || return 1
  timeout --signal=KILL 10s systemctl is-active --quiet kubelet || return 1
  timeout --signal=KILL 10s systemctl is-active --quiet cubesandbox-s13-runtime-resource.service || return 1
  owned_pods=$(timeout --signal=KILL 15s kubectl --kubeconfig /etc/kubernetes/admin.conf --request-timeout=10s \
    get pods --all-namespaces -l cubesandbox.io/s34-owned=true -o name) || return 1
  test -z "$owned_pods" || return 1
  lowlevel_containers=$(ctr --address /run/containerd/containerd.sock --namespace k8s.io --timeout 10s containers list -q) || return 1
  if grep -Eq '^s34-(low|invalid)-' <<<"$lowlevel_containers"; then return 1; fi
}

restore_containerd() {
  local current original
  test -f "$backup/containerd" || return 1
  original=$(awk '{print $1}' "$backup/containerd.sha256") || return 1
  test "$original" = "$expected_original_containerd" || return 1
  current=$(sha256sum "$live_containerd" | awk '{print $1}') || return 1
  if test "$current" != "$original"; then
    install -m 0755 "$backup/containerd" "$backup/containerd.restore-new" || return 1
    mv -f "$backup/containerd.restore-new" "$live_containerd" || return 1
  fi
  systemctl restart containerd || return 1
  for _ in $(seq 1 600); do systemctl is-active --quiet containerd && break; sleep .1; done
  systemctl is-active --quiet containerd || return 1
  test "$(sha256sum "$live_containerd" | awk '{print $1}')" = "$original" || return 1
  wait_node_healthy || return 1
  trace_deployed=false
}

cleanup() {
  local rc=$? id original= current= traced_live=false pre_restore_ok=true
  trap - EXIT
  trap '' INT TERM
  set +e
  for id in "${lowlevel_ids[@]}"; do
    "$helper" delete "$socket" "$namespace" "$id" confirm-owned-s34-resource-probe >/dev/null 2>&1 || cleanup_rc=1
  done
  record_owned_pod_uids || cleanup_rc=1
  delete_owned_pods || cleanup_rc=1
  for _ in $(seq 1 1200); do
    if ! "${kube[@]}" get pod "${pods[@]}" s34a-hugepage-reject --ignore-not-found -o name 2>/dev/null | grep -q .; then break; fi
    sleep .1
  done
  if test -f "$backup/containerd" -a -f "$backup/containerd.sha256"; then
    original=$(awk '{print $1}' "$backup/containerd.sha256") || cleanup_rc=1
    current=$(sha256sum "$live_containerd" 2>/dev/null | awk '{print $1}') || cleanup_rc=1
    if test -n "$original" -a "$current" != "$original"; then traced_live=true; fi
  fi
  if test "$traced_live" = true && test "$trace_deployed" != true; then
    pre_restore_ok=false
    cleanup_rc=1
  elif test "$baseline_captured" = true && test "$traced_live" = true && test "$trace_deployed" = true && test "$workloads_started" = true; then
    pre_restore_ok=false
    if wait_baseline cleanup-pre-restore; then pre_restore_ok=true; else cleanup_rc=1; fi
  fi
  if test "$pre_restore_ok" = true; then
    if test "$trace_deployed" = true; then
      restore_containerd || cleanup_rc=1
    elif test -n "$original" && test "$current" = "$original" && ! systemctl is-active --quiet containerd; then
      restore_containerd || cleanup_rc=1
    fi
  else
    cleanup_rc=1
  fi
  current=$(sha256sum "$live_containerd" 2>/dev/null | awk '{print $1}') || cleanup_rc=1
  if test -n "$original" && test "$current" = "$original" && systemctl is-active --quiet containerd; then
    if test "$trace_root_owned" = true; then
      rm -rf -- "$trace_root"
      trace_root_owned=false
    fi
    if test "$baseline_captured" = true; then wait_baseline cleanup-final || cleanup_rc=1; fi
  else
    cleanup_rc=1
  fi
  systemctl is-active --quiet containerd || cleanup_rc=1
  systemctl is-active --quiet kubelet || cleanup_rc=1
  systemctl is-active --quiet cubesandbox-s13-runtime-resource.service || cleanup_rc=1
  wait_node_healthy || cleanup_rc=1
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1
  printf 'probe_rc=%s cleanup_rc=%s original_containerd=%s live_containerd=%s\n' "$rc" "$cleanup_rc" "$expected_original_containerd" "$(sha256sum "$live_containerd" 2>/dev/null | awk '{print $1}')" >"$evidence/final-status.txt"
  set -e
  if test "$cleanup_rc" -ne 0; then exit 1; fi
  exit "$rc"
}
on_signal() {
  local rc=$1
  trap - INT TERM
  exit "$rc"
}
preflight_clean_runtime
mkdir -p "$evidence"
: >"$pod_uids_file"
printf 'result=clean original_containerd=%s trace_root=absent owned_pods=absent lowlevel_containers=absent services=active\n' \
  "$expected_original_containerd" >"$evidence/preflight.txt"
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

capture_versions_and_node() {
  local tag=$1
  mkdir -p "$evidence/baseline-$tag"
  uname -a >"$evidence/baseline-$tag/host-kernel.txt"
  "${kube[@]}" version -o json >"$evidence/baseline-$tag/kubernetes-version.json"
  kubelet --version >"$evidence/baseline-$tag/kubelet-version.txt"
  containerd --version >"$evidence/baseline-$tag/containerd-version.txt"
  runc --version >"$evidence/baseline-$tag/runc-version.txt"
  crictl --version >"$evidence/baseline-$tag/crictl-version.txt"
  sha256sum "$live_containerd" /usr/local/bin/containerd-shim-cube-rs /data/cubelet/s13-kubernetes/assets/agent "$helper" "$traced_containerd" >"$evidence/baseline-$tag/artifact-sha256.txt"
  "${kube[@]}" get node "$node" -o json >"$evidence/baseline-$tag/node.json"
  "${kube[@]}" get runtimeclass -o json >"$evidence/baseline-$tag/runtimeclasses.json"
  cat /proc/swaps >"$evidence/baseline-$tag/host-swaps.txt"
  grep -E '^(MemTotal|SwapTotal|HugePages_|Hugepagesize):' /proc/meminfo >"$evidence/baseline-$tag/host-meminfo.txt"
  findmnt -J -t cgroup2 >"$evidence/baseline-$tag/host-cgroup2-mount.json"
  find /sys/fs/cgroup -maxdepth 2 -type f \( -name cgroup.controllers -o -name cgroup.subtree_control \) -print -exec sh -c 'printf "="; cat "$1"' sh {} \; >"$evidence/baseline-$tag/host-cgroup-delegation.txt"
  "${kube[@]}" get --raw /api/v1/nodes/"$node"/proxy/configz | jq -S '{kubeletconfig:.kubeletconfig | {featureGates,cgroupDriver,cpuManagerPolicy,memoryManagerPolicy,topologyManagerPolicy,topologyManagerScope,memorySwap,failSwapOn,podPidsLimit}}' >"$evidence/baseline-$tag/kubelet-resource-config.json"
  systemctl show containerd kubelet cubesandbox-s13-runtime-resource.service -p Id -p ActiveState -p SubState -p ControlGroup >"$evidence/baseline-$tag/systemd-services.txt"
  containerd config dump | awk '/shim_cgroup|SystemdCgroup|disable_hugetlb_controller|tolerate_missing_hugetlb_controller|io.containerd.cube.rs|io.containerd.runc.v2|sandboxer|runtime_path/ {print}' >"$evidence/baseline-$tag/containerd-resource-config.txt"
  "$helper" schema >"$evidence/baseline-$tag/helper-schema.txt"
}

container_cgroup_capture_body() {
  cat <<'EOF'
printf 'uname='; uname -a
printf 'proc_cgroup='; cat /proc/self/cgroup
cgroup_count=0
cgroup_path=
while IFS= read -r cgroup_line; do
  case "$cgroup_line" in
    0::*)
      if test "$cgroup_count" != 0; then exit 1; fi
      cgroup_count=1
      cgroup_path=${cgroup_line#0::}
      ;;
  esac
done </proc/self/cgroup
if test "$cgroup_count" != 1 || test -z "$cgroup_path"; then exit 1; fi
test "$(printf '%s\n' "$cgroup_path" | wc -l)" -eq 1
case "$cgroup_path" in /*) ;; *) exit 1 ;; esac
IFS=' ' read -r self_pid _ </proc/self/stat
case "$self_pid" in ''|*[!0-9]*) exit 1 ;; esac
printf 'self_pid=%s\n' "$self_pid"
mount_count=0
while IFS=' ' read -r mount_id parent_id major_minor mount_root mount_point mount_rest; do
  case " $mount_rest " in
    *" - cgroup2 "*)
      test "$mount_count" = 0
      mount_count=1
      cgroup_mount_root=$mount_root
      cgroup_mount_point=$mount_point
      ;;
  esac
done </proc/self/mountinfo
if test "$mount_count" = 0; then
  if test "${S34_CGROUP2_MOUNT_OPTIONAL:-}" = runc-lowlevel; then
    printf 'cgroup_path_resolution=cgroup2-mount-absent\n'
    printf 'cgroup_mount_count=0\n'
    exit 0
  fi
  exit 1
fi
test "$mount_count" = 1
case "$cgroup_mount_root" in /*) ;; *) exit 1 ;; esac
case "$cgroup_mount_point" in /*) ;; *) exit 1 ;; esac
if test "$cgroup_mount_root" = /; then
  relative=$cgroup_path
elif test "$cgroup_path" = "$cgroup_mount_root"; then
  relative=/
else
  case "$cgroup_path" in "$cgroup_mount_root"/*) relative=${cgroup_path#"$cgroup_mount_root"} ;; *) exit 1 ;; esac
fi
case "$relative" in /*) ;; *) exit 1 ;; esac
if test "$relative" = /; then dir=$cgroup_mount_point; else dir=$cgroup_mount_point$relative; fi
test -f "$dir/cgroup.procs"
grep -Fxq "$self_pid" "$dir/cgroup.procs"
resolution=mount-root-relative
printf 'cgroup_dir=%s\n' "$dir"
printf 'cgroup_path_resolution=%s\n' "$resolution"
printf 'cgroup_mount_count=1\n'
printf 'cgroup_mount_root=%s\n' "$cgroup_mount_root"
printf 'cgroup_mount_point=%s\n' "$cgroup_mount_point"
printf 'cgroup_mount_relative=%s\n' "$relative"
printf 'cgroup2_mountinfo='; grep ' - cgroup2 ' /proc/self/mountinfo
for name in cgroup.controllers cgroup.subtree_control cpu.max cpu.weight cpuset.cpus cpuset.cpus.effective cpuset.mems cpuset.mems.effective memory.max memory.low memory.swap.max memory.oom.group pids.max; do
  if test -f "$dir/$name"; then value=$(cat "$dir/$name"); printf '%s=%s\n' "$name" "$value"; else printf '%s=ABSENT\n' "$name"; fi
done
for file in "$dir"/hugetlb.*.max; do
  test -e "$file" || continue
  printf '%s=' "${file##*/}"; cat "$file"
done
EOF
}

create_pod_input() {
  local pod=$1 runtime=$2 qos=$3 output=$4 runtime_class annotations classic_resources sidecar_resources app_resources classic_command
  runtime_class=null
  annotations='{}'
  if test "$runtime" = cube; then
    runtime_class='"cube"'
    annotations='{"cube.vmmres":"{\"cpu\":2,\"memory\":1024}"}'
  fi
  case "$qos" in
    besteffort)
      classic_resources='{}'; sidecar_resources='{}'; app_resources='{}'
      ;;
    burstable)
      classic_resources='{"requests":{"cpu":"50m","memory":"32Mi","ephemeral-storage":"2Mi"}}'
      sidecar_resources='{"requests":{"cpu":"100m","memory":"64Mi","ephemeral-storage":"2Mi"}}'
      app_resources='{"requests":{"cpu":"100m","memory":"64Mi","ephemeral-storage":"4Mi"},"limits":{"ephemeral-storage":"16Mi"}}'
      ;;
    guaranteed)
      classic_resources='{"requests":{"cpu":"200m","memory":"128Mi","ephemeral-storage":"2Mi"},"limits":{"cpu":"200m","memory":"128Mi","ephemeral-storage":"8Mi"}}'
      sidecar_resources='{"requests":{"cpu":"100m","memory":"64Mi","ephemeral-storage":"2Mi"},"limits":{"cpu":"100m","memory":"64Mi","ephemeral-storage":"8Mi"}}'
      app_resources='{"requests":{"cpu":"200m","memory":"128Mi","ephemeral-storage":"4Mi"},"limits":{"cpu":"200m","memory":"128Mi","ephemeral-storage":"16Mi"}}'
      ;;
    *) return 1 ;;
  esac
  classic_command=$'set -eu\nexec > /evidence/classic.txt\n'
  classic_command+=$(container_cgroup_capture_body)
  classic_command+=$'\nwhile test ! -f /evidence/release; do sleep 0.2; done'
  jq -n \
    --arg pod "$pod" --arg node "$node" --arg image "$image" --arg run "$token" \
    --argjson runtimeClassName "$runtime_class" --argjson annotations "$annotations" --arg classicCommand "$classic_command" \
    --argjson classicResources "$classic_resources" --argjson sidecarResources "$sidecar_resources" --argjson appResources "$app_resources" '
    {
      apiVersion:"v1", kind:"Pod",
      metadata:{name:$pod,labels:{"cubesandbox.io/s34-owned":"true","cubesandbox.io/s34-run":$run},annotations:$annotations},
      spec:{nodeName:$node,runtimeClassName:$runtimeClassName,terminationGracePeriodSeconds:0,restartPolicy:"Never",
        volumes:[{name:"evidence",emptyDir:{sizeLimit:"16Mi"}}],
        initContainers:[
          {name:"classic",image:$image,imagePullPolicy:"IfNotPresent",resources:$classicResources,
           command:["sh","-c",$classicCommand],
           volumeMounts:[{name:"evidence",mountPath:"/evidence"}]},
          {name:"sidecar",image:$image,imagePullPolicy:"IfNotPresent",restartPolicy:"Always",resources:$sidecarResources,
           resizePolicy:[{resourceName:"cpu",restartPolicy:"NotRequired"},{resourceName:"memory",restartPolicy:"NotRequired"}],
           command:["sh","-c","exec sleep 3600"],volumeMounts:[{name:"evidence",mountPath:"/evidence"}]}
        ],
        containers:[
          {name:"app",image:$image,imagePullPolicy:"IfNotPresent",resources:$appResources,
           resizePolicy:[{resourceName:"cpu",restartPolicy:"NotRequired"},{resourceName:"memory",restartPolicy:"NotRequired"}],
           command:["sh","-c","dd if=/dev/zero of=/evidence/ephemeral.bin bs=1M count=1 2>/dev/null; dd if=/dev/zero of=/writable-layer.bin bs=1M count=1 2>/dev/null; echo s34a-ephemeral-log; exec sleep 3600"],
           volumeMounts:[{name:"evidence",mountPath:"/evidence"}]}
        ]
      }
    }' >"$output"
}

wait_container_state() {
  local pod=$1 role=$2 state=$3 jsonpath
  if test "$role" = app; then
    jsonpath='.status.containerStatuses[]? | select(.name == "app")'
  else
    jsonpath='.status.initContainerStatuses[]? | select(.name == $role)'
  fi
  for _ in $(seq 1 1800); do
    if pod_json "$pod" | jq -e --arg role "$role" --arg state "$state" "$jsonpath | .state[\$state] != null" >/dev/null; then return 0; fi
    sleep .2
  done
  return 1
}

container_id() {
  local pod=$1 role=$2
  pod_json "$pod" | jq -er --arg role "$role" '
    ([.status.initContainerStatuses[]?,.status.containerStatuses[]?] | flatten[] | select(.name == $role) | .containerID) |
    sub("^containerd://"; "")'
}

sandbox_id() {
  local pod=$1
  "${cri[@]}" pods --name "$pod" -o json | jq -er --arg pod "$pod" '.items[] | select(.metadata.name == $pod and .state == "SANDBOX_READY") | .id' | head -1
}

capture_container_input() {
  local pod=$1 role=$2 phase=$3 mode=${4:-live} id output metadata_key metadata_prefix helper_command
  id=$(container_id "$pod" "$role")
  output=$evidence/kubernetes/$pod/$role-$phase
  mkdir -p "$output"
  printf '%s\n' "$id" >"$output/container-id.txt"
  case "$mode" in
    live) helper_command=dump-container ;;
    persisted) helper_command=dump-container-persisted ;;
    *) return 1 ;;
  esac
  "$helper" "$helper_command" "$socket" "$namespace" "$id" "$output/raw-containerd"
  metadata_key=$(jq -er '
    [.Extensions | to_entries[] | select(.value.type_url == "github.com/containerd/cri/pkg/store/container/Metadata") | .key] |
    if length == 1 then .[0] else error("expected exactly one CRI container metadata extension") end
  ' "$output/raw-containerd/container-info.json")
  case "$metadata_key" in
    io.cri-containerd.container.metadata) metadata_prefix=extension-io-cri-containerd-container-metadata ;;
    io.containerd.cri.container.metadata) metadata_prefix=extension-io-containerd-cri-container-metadata ;;
    *) return 1 ;;
  esac
  test "$(cat "$output/raw-containerd/$metadata_prefix.type-url.txt")" = 'github.com/containerd/cri/pkg/store/container/Metadata'
  printf '%s\n' "$metadata_key" >"$output/container-metadata-key.txt"
  printf '%s\n' "$metadata_prefix" >"$output/container-metadata-prefix.txt"
  "${cri[@]}" inspect "$id" >"$output/crictl-inspect.json"
  "${ctr[@]}" containers info "$id" >"$output/ctr-info.json"
}

capture_sandbox_input() {
  local pod=$1 sid output
  sid=$(sandbox_id "$pod")
  output=$evidence/kubernetes/$pod/sandbox
  mkdir -p "$output"
  printf '%s\n' "$sid" >"$output/sandbox-id.txt"
  "$helper" dump-sandbox "$socket" "$namespace" "$sid" "$output/raw-containerd"
  test "$(cat "$output/raw-containerd/extension-metadata.type-url.txt")" = 'github.com/containerd/cri/pkg/store/sandbox/Metadata'
  "${cri[@]}" inspectp "$sid" >"$output/crictl-inspectp.json"
  "${ctr[@]}" sandboxes info "$sid" >"$output/ctr-info.json"
}

capture_ephemeral_evidence() {
  local pod=$1 uid pod_dir empty_dir role metadata metadata_prefix log_path link_manifest id
  uid=$(jq -er '.metadata.uid' "$evidence/kubernetes/$pod/ready-pod.json")
  pod_dir=/var/lib/kubelet/pods/$uid
  empty_dir=$pod_dir/volumes/kubernetes.io~empty-dir/evidence
  for _ in $(seq 1 300); do
    if test -f "$empty_dir/ephemeral.bin" && "${kube[@]}" exec "$pod" -c app -- test -f /writable-layer.bin; then break; fi
    sleep .1
  done
  test -f "$empty_dir/ephemeral.bin"
  "${kube[@]}" exec "$pod" -c app -- test -f /writable-layer.bin
  stat -c 'path=%n size=%s inode=%i mode=%a uid=%u gid=%g' "$pod_dir" >"$evidence/kubernetes/$pod/kubelet-pod-dir.stat.txt"
  du -sb "$pod_dir" >"$evidence/kubernetes/$pod/kubelet-pod-dir.du.txt"
  stat -c 'path=%n size=%s inode=%i mode=%a uid=%u gid=%g' "$empty_dir" >"$evidence/kubernetes/$pod/emptydir.stat.txt"
  du -sb "$empty_dir" >"$evidence/kubernetes/$pod/emptydir.du.txt"
  stat -c 'path=%n size=%s inode=%i mode=%a uid=%u gid=%g' "$empty_dir/ephemeral.bin" >"$evidence/kubernetes/$pod/emptydir-file.stat.txt"
  "${kube[@]}" exec "$pod" -c app -- stat -c 'path=%n size=%s inode=%i mode=%a uid=%u gid=%g' /writable-layer.bin \
    >"$evidence/kubernetes/$pod/app-writable-layer.stat.txt"
  id=$(container_id "$pod" app)
  "${cri[@]}" stats -o json "$id" >"$evidence/kubernetes/$pod/app-crictl-stats.json"

  for role in classic sidecar app; do
    metadata_prefix=$(cat "$evidence/kubernetes/$pod/$role-create/container-metadata-prefix.txt")
    metadata=$evidence/kubernetes/$pod/$role-create/raw-containerd/$metadata_prefix.decoded.json
    log_path=$(jq -er '.Metadata.LogPath' "$metadata")
    case "$log_path" in /var/log/pods/default_"$pod"_"$uid"/"$role"/*.log) ;; *) return 1 ;; esac
    printf '%s\n' "$log_path" >"$evidence/kubernetes/$pod/$role-node-log.path.txt"
    for _ in $(seq 1 300); do test -e "$log_path" && break; sleep .1; done
    test -e "$log_path"
    stat -Lc 'path=%n size=%s inode=%i mode=%a uid=%u gid=%g' "$log_path" >"$evidence/kubernetes/$pod/$role-node-log.stat.txt"
    sha256sum "$log_path" >"$evidence/kubernetes/$pod/$role-node-log.sha256.txt"
    cp "$log_path" "$evidence/kubernetes/$pod/$role-node-log.content.txt"
    link_manifest=$evidence/kubernetes/$pod/$role-container-log-symlinks.txt
    find /var/log/containers -maxdepth 1 -type l -name "${pod}_default_${role}-*.log" -printf '%p\t%l\n' | LC_ALL=C sort >"$link_manifest"
    test -s "$link_manifest"
  done
  for _ in $(seq 1 300); do
    grep -Fq 's34a-ephemeral-log' "$evidence/kubernetes/$pod/app-node-log.content.txt" && break
    sleep .1
    cp "$(cat "$evidence/kubernetes/$pod/app-node-log.path.txt")" "$evidence/kubernetes/$pod/app-node-log.content.txt"
  done
  stat -Lc 'path=%n size=%s inode=%i mode=%a uid=%u gid=%g' "$(cat "$evidence/kubernetes/$pod/app-node-log.path.txt")" >"$evidence/kubernetes/$pod/app-node-log.stat.txt"
  sha256sum "$(cat "$evidence/kubernetes/$pod/app-node-log.path.txt")" >"$evidence/kubernetes/$pod/app-node-log.sha256.txt"
  grep -Fq 's34a-ephemeral-log' "$evidence/kubernetes/$pod/app-node-log.content.txt"
}

assert_cgroup_capture() {
  local capture=$1 name
  grep -Fxq 'cgroup_path_resolution=mount-root-relative' "$capture" || return 1
  grep -Fxq 'cgroup_mount_count=1' "$capture" || return 1
  grep -Eq '^cgroup_mount_root=/' "$capture" || return 1
  grep -Eq '^cgroup_mount_point=/' "$capture" || return 1
  grep -Eq '^cgroup_mount_relative=/' "$capture" || return 1
  for name in cgroup.controllers cgroup.subtree_control cpu.max cpu.weight cpuset.cpus cpuset.cpus.effective cpuset.mems cpuset.mems.effective memory.max memory.low memory.swap.max memory.oom.group pids.max; do
    grep -q "^$name=" "$capture" || return 1
  done
  if grep -q '=ABSENT$' "$capture"; then return 1; fi
  return 0
}

capture_required_value() {
  local capture=$1 name=$2
  awk -v key="$name=" '
    index($0, key) == 1 {found++; value=substr($0, length(key)+1)}
    END {if (found != 1) exit 1; print value}
  ' "$capture"
}

assert_host_cgroup_capture() {
  local expected_pid=$1 capture=$2 recorded_pid cgroup_count proc_cgroup path dir membership name value
  case "$expected_pid" in ''|*[!0-9]*) return 1 ;; esac
  test "$expected_pid" -gt 0 || return 1
  recorded_pid=$(capture_required_value "$capture" host_pid) || return 1
  test "$recorded_pid" = "$expected_pid" || return 1
  cgroup_count=$(capture_required_value "$capture" host_cgroup_count) || return 1
  test "$cgroup_count" = 1 || return 1
  proc_cgroup=$(capture_required_value "$capture" host_proc_cgroup) || return 1
  path=$(capture_required_value "$capture" host_cgroup_path) || return 1
  test -n "$path" || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  test "$proc_cgroup" = "0::$path" || return 1
  dir=$(capture_required_value "$capture" host_leaf_directory) || return 1
  test "$dir" = "/sys/fs/cgroup$path" || return 1
  membership=$(capture_required_value "$capture" host_leaf_pid_membership) || return 1
  test "$membership" = "$expected_pid" || return 1
  for name in cgroup.controllers cgroup.subtree_control cpu.max cpu.weight cpuset.cpus cpuset.cpus.effective cpuset.mems cpuset.mems.effective memory.max memory.low memory.swap.max memory.oom.group pids.max; do
    value=$(capture_required_value "$capture" "leaf.$name") || return 1
    test "$value" != ABSENT || return 1
  done
  return 0
}

assert_lowlevel_cgroup_capture() {
  local runtime=$1 capture=$2 host_capture=$3 expected_pid=$4 name
  assert_host_cgroup_capture "$expected_pid" "$host_capture" || return 1
  if test "$runtime" != runc || ! grep -Fxq 'cgroup_path_resolution=cgroup2-mount-absent' "$capture"; then
    assert_cgroup_capture "$capture"
    return
  fi
  test "$(wc -l <"$capture")" -eq 5 || return 1
  grep -Eq '^uname=.+' "$capture" || return 1
  grep -Eq '^proc_cgroup=0::/.+' "$capture" || return 1
  grep -Eq '^self_pid=[1-9][0-9]*$' "$capture" || return 1
  grep -Fxq 'cgroup_path_resolution=cgroup2-mount-absent' "$capture" || return 1
  grep -Fxq 'cgroup_mount_count=0' "$capture" || return 1
  for name in cgroup_dir cgroup_mount_root cgroup_mount_point cgroup_mount_relative cgroup2_mountinfo cgroup.controllers cgroup.subtree_control cpu.max cpu.weight cpuset.cpus cpuset.cpus.effective cpuset.mems cpuset.mems.effective memory.max memory.low memory.swap.max memory.oom.group pids.max; do
    if grep -q "^$name=" "$capture"; then return 1; fi
  done
  return 0
}

cgroup_capture_optional_value() {
  local capture=$1 name=$2
  awk -v key="$name=" '
    index($0, key) == 1 {found++; value=substr($0, length(key)+1)}
    END {if (found > 1) exit 1; if (found == 0) print "ABSENT"; else print value}
  ' "$capture"
}

host_leaf_cgroup_value() {
  local capture=$1 name=$2 value
  value=$(capture_required_value "$capture" "leaf.$name") || return 1
  test "$value" != ABSENT || return 1
  printf '%s\n' "$value"
}

guest_cgroup() {
  local pod=$1 role=$2 output=$3 command
  command=$'set -eu\n'
  command+=$(container_cgroup_capture_body)
  "${kube[@]}" exec "$pod" -c "$role" -- sh -c "$command" | tr -d '\r' >"$output"
  assert_cgroup_capture "$output"
}

capture_host_pid() {
  local pid=$1 output=$2 cgroup_count cgroup_line path dir parent file hugepage_file tid value is_leaf
  : >"$output"
  ps -p "$pid" -o pid=,ppid=,comm=,args= >>"$output"
  printf 'host_pid=%s\n' "$pid" >>"$output"
  cgroup_count=0
  path=
  while IFS= read -r cgroup_line; do
    case "$cgroup_line" in
      0::*)
        if test "$cgroup_count" != 0; then return 1; fi
        cgroup_count=1
        path=${cgroup_line#0::}
        printf 'host_proc_cgroup=%s\n' "$cgroup_line" >>"$output"
        ;;
    esac
  done <"/proc/$pid/cgroup"
  if test "$cgroup_count" != 1 || test -z "$path"; then return 1; fi
  test "$(printf '%s\n' "$path" | wc -l)" -eq 1 || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  printf 'host_cgroup_count=1\n' >>"$output"
  printf 'host_cgroup_path=%s\n' "$path" >>"$output"
  dir=/sys/fs/cgroup$path
  test -d "$dir" || return 1
  test -f "$dir/cgroup.procs" || return 1
  grep -Fxq "$pid" "$dir/cgroup.procs" || return 1
  printf 'host_leaf_directory=%s\n' "$dir" >>"$output"
  printf 'host_leaf_pid_membership=%s\n' "$pid" >>"$output"
  for tid in /proc/"$pid"/task/*; do
    test -d "$tid" || continue
    printf 'thread=%s comm=' "${tid##*/}" >>"$output"
    cat "$tid/comm" >>"$output"
    cat "$tid/cgroup" >>"$output"
  done
  is_leaf=true
  while :; do
    printf 'directory=%s\n' "$dir" >>"$output"
    for file in cpu.max cpu.weight cpuset.cpus cpuset.cpus.effective cpuset.mems cpuset.mems.effective memory.max memory.low memory.swap.max memory.oom.group pids.max cgroup.controllers cgroup.subtree_control; do
      value=ABSENT
      if test -f "$dir/$file"; then
        value=$(cat "$dir/$file")
        test "$(printf '%s\n' "$value" | wc -l)" -eq 1 || return 1
      fi
      printf '%s=%s\n' "$file" "$value" >>"$output"
      if test "$is_leaf" = true; then printf 'leaf.%s=%s\n' "$file" "$value" >>"$output"; fi
    done
    for hugepage_file in "$dir"/hugetlb.*.max; do
      test -e "$hugepage_file" || continue
      value=$(cat "$hugepage_file")
      test "$(printf '%s\n' "$value" | wc -l)" -eq 1 || return 1
      printf '%s=%s\n' "${hugepage_file##*/}" "$value" >>"$output"
      if test "$is_leaf" = true; then printf 'leaf.%s=%s\n' "${hugepage_file##*/}" "$value" >>"$output"; fi
    done
    is_leaf=false
    test "$dir" != /sys/fs/cgroup || break
    parent=${dir%/*}; test -n "$parent" || parent=/sys/fs/cgroup; dir=$parent
  done
  assert_host_cgroup_capture "$pid" "$output"
}

capture_descendants() {
  local root=$1 output=$2 current child
  local -a queue=("$root") seen=()
  : >"$output"
  while test "${#queue[@]}" -gt 0; do
    current=${queue[0]}
    queue=("${queue[@]:1}")
    seen+=("$current")
    ps -p "$current" -o pid=,ppid=,comm=,args= >>"$output" 2>/dev/null || continue
    if test -r "/proc/$current/cgroup"; then
      printf 'pid=%s cgroup=' "$current" >>"$output"
      tr '\n' ';' <"/proc/$current/cgroup" >>"$output"
      printf '\n' >>"$output"
    fi
    while IFS= read -r child; do
      test -n "$child" || continue
      queue+=("$child")
    done < <(pgrep -P "$current" 2>/dev/null || true)
  done
}

capture_pod_host_topology() {
  local pod=$1 runtime=$2 phase=${3:-before} sid pid cid role output
  sid=$(sandbox_id "$pod")
  output=$evidence/kubernetes/$pod/host-topology-$phase
  mkdir -p "$output"
  if test "$runtime" = cube; then
    pid=$(ps -eo pid=,args= | awk -v id="$sid" '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {print $1; exit}')
    test -n "$pid"
    capture_host_pid "$pid" "$output/shim.txt"
    capture_descendants "$pid" "$output/process-tree.txt"
  else
    for role in sidecar app; do
      cid=$(container_id "$pod" "$role")
      pid=$("${ctr[@]}" tasks list | awk -v id="$cid" '$1 == id {print $2}')
      test -n "$pid"
      capture_host_pid "$pid" "$output/$role.txt"
    done
  fi
}

wait_pod_ready() {
  "${kube[@]}" wait --for=condition=Ready "pod/$1" --timeout=360s >/dev/null
}

install_trace_containerd() {
  test -x "$helper" -a -x "$traced_containerd" -a -f "$artifact_manifest"
  (cd "$(dirname "$artifact_manifest")" && sha256sum -c "$(basename "$artifact_manifest")") >"$evidence/artifact-manifest.verify"
  test "$(sha256sum "$live_containerd" | awk '{print $1}')" = "$expected_original_containerd"
  mkdir -p "$backup"
  if test ! -f "$backup/containerd"; then
    cp -a "$live_containerd" "$backup/containerd"
    sha256sum "$backup/containerd" >"$backup/containerd.sha256"
  fi
  test "$(sha256sum "$backup/containerd" | awk '{print $1}')" = "$expected_original_containerd"
  mkdir "$trace_root"
  trace_root_owned=true
  : >"$trace_root/ids"
  install -m 0755 "$traced_containerd" "$backup/containerd.s34-new"
  trace_deployed=true
  mv -f "$backup/containerd.s34-new" "$live_containerd"
  systemctl restart containerd
  for _ in $(seq 1 600); do systemctl is-active --quiet containerd && break; sleep .1; done
  systemctl is-active --quiet containerd
  test "$(sha256sum "$live_containerd" | awk '{print $1}')" = "$(sha256sum "$traced_containerd" | awk '{print $1}')"
  wait_node_healthy
}

trace_count() {
  local id=$1 kind=$2
  if test ! -d "$trace_root/$id"; then printf '0\n'; return 0; fi
  find "$trace_root/$id" -type f -name "*-$kind.pb" -printf '.\n' | awk 'NF {n++} END {print n+0}'
}

prove_trace_health() {
  local pod id before_cri before_task after_cri after_task phase=$1
  for pod in s34a-runc-besteffort s34a-cube-besteffort; do
    id=$(container_id "$pod" app)
    before_cri=$(trace_count "$id" cri-update)
    before_task=$(trace_count "$id" task-update)
    date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$evidence/trace-health-$phase-$pod.start"
    "${cri[@]}" update --cpu-share 2 "$id" >"$evidence/trace-health-$phase-$pod.response.txt" 2>&1
    date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$evidence/trace-health-$phase-$pod.end"
    after_cri=$(trace_count "$id" cri-update)
    after_task=$(trace_count "$id" task-update)
    test "$after_cri" -eq $((before_cri + 1))
    test "$after_task" -eq $((before_task + 1))
    printf 'id=%s cri=%s->%s task=%s->%s\n' "$id" "$before_cri" "$after_cri" "$before_task" "$after_task" >"$evidence/trace-health-$phase-$pod.txt"
  done
}

resize_guaranteed_pod() {
  local pod=$1 phase=$2 app sidecar classic
  app=$(container_id "$pod" app)
  sidecar=$(container_id "$pod" sidecar)
  classic=$(container_id "$pod" classic)
  date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$evidence/kubernetes/$pod/resize-$phase.start"
  "${kube[@]}" patch pod "$pod" --subresource=resize --type=json -p '[
    {"op":"replace","path":"/spec/containers/0/resources/requests/cpu","value":"300m"},
    {"op":"replace","path":"/spec/containers/0/resources/limits/cpu","value":"300m"},
    {"op":"replace","path":"/spec/containers/0/resources/requests/memory","value":"160Mi"},
    {"op":"replace","path":"/spec/containers/0/resources/limits/memory","value":"160Mi"},
    {"op":"replace","path":"/spec/initContainers/1/resources/requests/cpu","value":"150m"},
    {"op":"replace","path":"/spec/initContainers/1/resources/limits/cpu","value":"150m"},
    {"op":"replace","path":"/spec/initContainers/1/resources/requests/memory","value":"80Mi"},
    {"op":"replace","path":"/spec/initContainers/1/resources/limits/memory","value":"80Mi"}
  ]' >"$evidence/kubernetes/$pod/resize-$phase.response.txt"
  for _ in $(seq 1 1800); do
    pod_json "$pod" >"$evidence/kubernetes/$pod/resize-$phase.status.json"
    if jq -e --arg classic "containerd://$classic" '
      (.status.containerStatuses[] | select(.name == "app") | .allocatedResources.cpu == "300m" and .allocatedResources.memory == "160Mi" and .restartCount == 0) and
      (.status.initContainerStatuses[] | select(.name == "sidecar") | .allocatedResources.cpu == "150m" and .allocatedResources.memory == "80Mi" and .restartCount == 0) and
      (.spec.initContainers[] | select(.name == "classic") |
        .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
        .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
        .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
      (.status.initContainerStatuses[] | select(.name == "classic") |
        .containerID == $classic and .state.terminated.exitCode == 0 and .restartCount == 0 and
        .allocatedResources.cpu == "250m" and .allocatedResources.memory == "128Mi" and
        .allocatedResources["ephemeral-storage"] == "2Mi" and
        .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
        .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
        .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
      ([.status.conditions[]? | select(.type == "PodResizeInProgress" or .type == "PodResizePending")] | length == 0)
    ' "$evidence/kubernetes/$pod/resize-$phase.status.json" >/dev/null; then break; fi
    sleep .2
  done
  jq -e --arg classic "containerd://$classic" '
    (.status.containerStatuses[] | select(.name == "app") | .allocatedResources.cpu == "300m" and .allocatedResources.memory == "160Mi" and .restartCount == 0) and
    (.status.initContainerStatuses[] | select(.name == "sidecar") | .allocatedResources.cpu == "150m" and .allocatedResources.memory == "80Mi" and .restartCount == 0) and
    (.spec.initContainers[] | select(.name == "classic") |
      .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
      .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
      .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
    (.status.initContainerStatuses[] | select(.name == "classic") |
      .containerID == $classic and .state.terminated.exitCode == 0 and .restartCount == 0 and
      .allocatedResources.cpu == "250m" and .allocatedResources.memory == "128Mi" and
      .allocatedResources["ephemeral-storage"] == "2Mi" and
      .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
      .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
      .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
    ([.status.conditions[]? | select(.type == "PodResizeInProgress" or .type == "PodResizePending")] | length == 0)
  ' "$evidence/kubernetes/$pod/resize-$phase.status.json" >/dev/null
  date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$evidence/kubernetes/$pod/resize-$phase.end"
  test "$(trace_count "$app" cri-update)" -ge 1
  test "$(trace_count "$app" task-update)" -ge 1
  test "$(trace_count "$sidecar" cri-update)" -ge 1
  test "$(trace_count "$sidecar" task-update)" -ge 1
}

classic_resize_updates_kubelet_accounting_only() {
  local pod=$1 classic before_cri after_cri before_task after_task rc allocated status_resources before_allocated
  classic=$(container_id "$pod" classic)
  jq -e --arg classic "containerd://$classic" '
    (.status.initContainerStatuses[] | select(.name == "classic") |
      .containerID == $classic and .state.terminated.exitCode == 0 and .restartCount == 0 and
      .allocatedResources.cpu == "200m" and .allocatedResources.memory == "128Mi" and
      .allocatedResources["ephemeral-storage"] == "2Mi" and
      .resources.requests.cpu == "200m" and .resources.limits.cpu == "200m" and
      .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
      .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi")
  ' "$evidence/kubernetes/$pod/ready-pod.json" >/dev/null
  before_allocated=$(jq -er '.status.initContainerStatuses[] | select(.name == "classic") | .allocatedResources.cpu' "$evidence/kubernetes/$pod/ready-pod.json")
  test "$before_allocated" = 200m
  before_cri=$(trace_count "$classic" cri-update)
  before_task=$(trace_count "$classic" task-update)
  date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$evidence/kubernetes/$pod/classic-resize.start"
  set +e
  "${kube[@]}" patch pod "$pod" --subresource=resize --type=json -p '[{"op":"replace","path":"/spec/initContainers/0/resources/requests/cpu","value":"250m"},{"op":"replace","path":"/spec/initContainers/0/resources/limits/cpu","value":"250m"}]' >"$evidence/kubernetes/$pod/classic-resize.response.txt" 2>&1
  rc=$?
  set -e
  test "$rc" -eq 0
  grep -Fxq "pod/$pod patched" "$evidence/kubernetes/$pod/classic-resize.response.txt"
  pod_json "$pod" >"$evidence/kubernetes/$pod/classic-resize.first-status.json"
  for _ in $(seq 1 300); do
    pod_json "$pod" >"$evidence/kubernetes/$pod/classic-resize.status.json"
    if jq -e --arg classic "containerd://$classic" '
      (.spec.initContainers[] | select(.name == "classic") |
        .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
        .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
        .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
      (.status.initContainerStatuses[] | select(.name == "classic") |
        .containerID == $classic and .state.terminated.exitCode == 0 and .restartCount == 0 and
        .allocatedResources.cpu == "250m" and .allocatedResources.memory == "128Mi" and
        .allocatedResources["ephemeral-storage"] == "2Mi" and
        .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
        .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
        .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
      ([.status.conditions[]? | select(.type == "PodResizeInProgress" or .type == "PodResizePending")] | length == 0)
    ' "$evidence/kubernetes/$pod/classic-resize.status.json" >/dev/null; then break; fi
    sleep .2
  done
  jq -e --arg classic "containerd://$classic" '
    (.spec.initContainers[] | select(.name == "classic") |
      .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
      .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
      .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
    (.status.initContainerStatuses[] | select(.name == "classic") |
      .containerID == $classic and .state.terminated.exitCode == 0 and
      .restartCount == 0 and
      .allocatedResources.cpu == "250m" and .allocatedResources.memory == "128Mi" and
      .allocatedResources["ephemeral-storage"] == "2Mi" and
      .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
      .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
      .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
    ([.status.conditions[]? | select(.type == "PodResizeInProgress" or .type == "PodResizePending")] | length == 0)
  ' "$evidence/kubernetes/$pod/classic-resize.status.json" >/dev/null
  date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$evidence/kubernetes/$pod/classic-resize.end"
  after_cri=$(trace_count "$classic" cri-update)
  after_task=$(trace_count "$classic" task-update)
  test "$after_cri" -eq "$before_cri"
  test "$after_task" -eq "$before_task"
  allocated=$(jq -er '.status.initContainerStatuses[] | select(.name == "classic") | .allocatedResources.cpu' "$evidence/kubernetes/$pod/classic-resize.status.json")
  status_resources=$(jq -er '.status.initContainerStatuses[] | select(.name == "classic") | .resources.requests.cpu' "$evidence/kubernetes/$pod/classic-resize.status.json")
  test "$before_allocated" = 200m
  test "$allocated" = 250m
  test "$status_resources" = 250m
  capture_container_input "$pod" classic post-accounting persisted
  cmp "$evidence/kubernetes/$pod/classic-create/raw-containerd/container-spec.value" \
    "$evidence/kubernetes/$pod/classic-post-accounting/raw-containerd/container-spec.value"
  printf 'exit=%s spec_cpu=250m status_allocated_cpu=%s status_resources_cpu=%s classic_cri_trace=%s->%s classic_task_trace=%s->%s classification=api-spec-and-kubelet-accounting-only-terminated-task\n' \
    "$rc" "$allocated" "$status_resources" "$before_cri" "$after_cri" "$before_task" "$after_task" >"$evidence/kubernetes/$pod/classic-resize.result.txt"
}

write_resource_json() {
  local case_name=$1 phase=$2 output=$3
  case "$case_name:$phase" in
    cpu:initial) printf '%s\n' '{"cpu":{"shares":512,"quota":50000,"period":100000}}' ;;
    cpu:update) printf '%s\n' '{"cpu":{"shares":1024,"quota":75000,"period":100000}}' ;;
    memory-limit:initial) printf '%s\n' '{"memory":{"limit":268435456}}' ;;
    memory-limit:update) printf '%s\n' '{"memory":{"limit":402653184}}' ;;
    memory-reservation:initial) printf '%s\n' '{"memory":{"limit":536870912,"reservation":134217728}}' ;;
    memory-reservation:update) printf '%s\n' '{"memory":{"reservation":268435456}}' ;;
    swap:initial) printf '%s\n' '{"memory":{"limit":268435456,"swap":402653184}}' ;;
    swap:update) printf '%s\n' '{"memory":{"limit":268435456,"swap":536870912}}' ;;
    cpuset:initial) printf '%s\n' '{"cpu":{"cpus":"0","mems":"0"}}' ;;
    cpuset:update) printf '%s\n' '{"cpu":{"cpus":"1","mems":"0"}}' ;;
    pids:initial) printf '%s\n' '{"pids":{"limit":128}}' ;;
    pids:update) printf '%s\n' '{"pids":{"limit":64}}' ;;
    hugepage-create:initial) printf '%s\n' '{"hugepageLimits":[{"pageSize":"2MB","limit":0}]}' ;;
    hugepage-create:update) printf '%s\n' '{"hugepageLimits":[{"pageSize":"2MB","limit":2097152}]}' ;;
    hugepage-update:initial) printf '%s\n' '{}' ;;
    hugepage-update:update) printf '%s\n' '{"hugepageLimits":[{"pageSize":"2MB","limit":2097152}]}' ;;
    unified:initial) printf '%s\n' '{"unified":{"memory.oom.group":"0"}}' ;;
    unified:update) printf '%s\n' '{"unified":{"memory.oom.group":"1"}}' ;;
    *) return 1 ;;
  esac >"$output"
}

run_lowlevel_case() {
  local runtime=$1 case_name=$2 sandbox=$3 runtime_name id dir create_rc update_rc delete_rc host_pid update_classification before_value after_value
  runtime_name=io.containerd.runc.v2
  if test "$runtime" = cube; then runtime_name=io.containerd.cube.rs; fi
  id="s34-low-$runtime-${case_name//-/_}-${short//-/_}"
  id=${id:0:63}
  lowlevel_ids+=("$id")
  dir=$evidence/lowlevel/$runtime/$case_name
  mkdir -p "$dir"
  write_resource_json "$case_name" initial "$dir/initial.json"
  write_resource_json "$case_name" update "$dir/update.json"
  set +e
  "$helper" create "$socket" "$namespace" "$runtime_name" "$sandbox" "$image" "$id" "$dir/initial.json" "$dir/create" confirm-owned-s34-resource-probe >"$dir/create.stdout" 2>"$dir/create.stderr"
  create_rc=$?
  set -e
  printf '%s\n' "$create_rc" >"$dir/create.exit"
  case "$case_name" in
    hugepage-create)
      jq -e '. == {"hugepageLimits":[{"pageSize":"2MB","limit":0}]}' "$dir/initial.json" >/dev/null
      jq -e '.linux.resources.hugepageLimits == [{"pageSize":"2MB","limit":0}]' "$dir/create/container-spec.decoded.json" >/dev/null
      ;;
    hugepage-update)
      jq -e '. == {}' "$dir/initial.json" >/dev/null
      jq -e '(.linux.resources | has("hugepageLimits")) | not' "$dir/create/container-spec.decoded.json" >/dev/null
      ;;
  esac
  if test "$create_rc" -ne 0; then
    test "$runtime" = cube
    test "$case_name" = hugepage-create
    test -s "$dir/create/container-spec.any.pb"
    grep -Eq '^error=.+' "$dir/create/create.result.txt"
    grep -Fq 'hugetlb..max' "$dir/create/create.result.txt"
    grep -Eqi 'ENOENT|No such file' "$dir/create/create.result.txt"
    test -z "$(find "$dir" -maxdepth 1 -name 'update-request*' -print -quit)"
    set +e
    "$helper" delete "$socket" "$namespace" "$id" confirm-owned-s34-resource-probe >"$dir/delete-after-reject.stdout" 2>"$dir/delete-after-reject.stderr"
    delete_rc=$?
    set -e
    printf '%s\n' "$delete_rc" >"$dir/delete-after-reject.exit"
    test "$delete_rc" -eq 0
    printf 'runtime=cube case=hugepage-create create=rejected update=not-attempted reason=invalid-guest-cgroup-file-hugetlb..max\n' >"$dir/classification.txt"
    return 0
  fi
  host_pid=$(cat "$dir/create/task-pid.txt")
  capture_host_pid "$host_pid" "$dir/host-before.txt"
  "$helper" cgroup "$socket" "$namespace" "$id" "$dir/cgroup-before.txt"
  assert_lowlevel_cgroup_capture "$runtime" "$dir/cgroup-before.txt" "$dir/host-before.txt" "$host_pid"
  set +e
  "$helper" update "$socket" "$namespace" "$id" "$dir/update.json" "$dir/update-request" >"$dir/update.stdout" 2>"$dir/update.stderr"
  update_rc=$?
  set -e
  printf '%s\n' "$update_rc" >"$dir/update.exit"
  test -s "$dir/update-request.request.pb"
  test -s "$dir/update-request.result.txt"
  case "$case_name" in
    hugepage-create|hugepage-update)
      jq -e '. == {"hugepageLimits":[{"pageSize":"2MB","limit":2097152}]}' "$dir/update.json" >/dev/null
      jq -e '.hugepageLimits == [{"pageSize":"2MB","limit":2097152}]' "$dir/update-request.resources.decoded.json" >/dev/null
      ;;
  esac
  if test "$runtime" = runc; then test "$update_rc" -eq 0; fi
  capture_host_pid "$host_pid" "$dir/host-after.txt"
  "$helper" cgroup "$socket" "$namespace" "$id" "$dir/cgroup-after.txt"
  assert_lowlevel_cgroup_capture "$runtime" "$dir/cgroup-after.txt" "$dir/host-after.txt" "$host_pid"
  update_classification=rejected
  if test "$update_rc" -eq 0; then
    update_classification=accepted
    case "$case_name" in
      hugepage-create|hugepage-update)
        update_classification=accepted-unapplied
        if test "$runtime" = runc; then
          before_value=$(host_leaf_cgroup_value "$dir/host-before.txt" hugetlb.2MB.max)
          after_value=$(host_leaf_cgroup_value "$dir/host-after.txt" hugetlb.2MB.max)
          if test "$case_name" = hugepage-create; then
            test "$before_value" = 0
          else
            test "$before_value" != 2097152
          fi
          if test "$after_value" = 2097152; then
            update_classification=accepted-applied
          else
            test "$after_value" = "$before_value"
          fi
        else
          before_value=$(cgroup_capture_optional_value "$dir/cgroup-before.txt" hugetlb.2MB.max)
          after_value=$(cgroup_capture_optional_value "$dir/cgroup-after.txt" hugetlb.2MB.max)
          if test "$before_value" != 2097152 && test "$after_value" = 2097152; then
            update_classification=accepted-applied
          else
            test "$after_value" = "$before_value"
          fi
        fi
        ;;
    esac
  fi
  printf 'runtime=%s case=%s create=accepted update=%s update_exit=%s\n' \
    "$runtime" "$case_name" "$update_classification" "$update_rc" >"$dir/classification.txt"
  "$helper" dump-container "$socket" "$namespace" "$id" "$dir/container-after"
  "$helper" delete "$socket" "$namespace" "$id" confirm-owned-s34-resource-probe
}

run_invalid_unified_case() {
  local runtime=$1 sandbox=$2 runtime_name id dir update_rc host_pid classification
  runtime_name=io.containerd.runc.v2
  if test "$runtime" = cube; then runtime_name=io.containerd.cube.rs; fi
  id="s34-invalid-$runtime-${short//-/_}"
  id=${id:0:63}
  lowlevel_ids+=("$id")
  dir=$evidence/lowlevel/$runtime/invalid-unified
  mkdir -p "$dir"
  printf '%s\n' '{}' >"$dir/initial.json"
  printf '%s\n' '{"unified":{"memory.this_controller_does_not_exist":"1"}}' >"$dir/update.json"
  "$helper" create "$socket" "$namespace" "$runtime_name" "$sandbox" "$image" "$id" "$dir/initial.json" "$dir/create" confirm-owned-s34-resource-probe \
    >"$dir/create.stdout" 2>"$dir/create.stderr"
  printf '0\n' >"$dir/create.exit"
  host_pid=$(cat "$dir/create/task-pid.txt")
  capture_host_pid "$host_pid" "$dir/host-before.txt"
  "$helper" cgroup "$socket" "$namespace" "$id" "$dir/cgroup-before.txt"
  assert_lowlevel_cgroup_capture "$runtime" "$dir/cgroup-before.txt" "$dir/host-before.txt" "$host_pid"
  set +e
  "$helper" update "$socket" "$namespace" "$id" "$dir/update.json" "$dir/update-request" >"$dir/update.stdout" 2>"$dir/update.stderr"
  update_rc=$?
  set -e
  printf '%s\n' "$update_rc" >"$dir/update.exit"
  test -s "$dir/update-request.request.pb"
  test -s "$dir/update-request.result.txt"
  if test "$update_rc" -eq 0; then
    classification=accepted-unapplied
    grep -Fxq success "$dir/update-request.result.txt"
  else
    classification=rejected
    grep -Eq '^error=.+' "$dir/update-request.result.txt"
  fi
  if test "$runtime" = runc; then
    test "$update_rc" -ne 0
    test "$classification" = rejected
  fi
  printf 'runtime=%s classification=%s update_exit=%s invalid_key=memory.this_controller_does_not_exist\n' \
    "$runtime" "$classification" "$update_rc" >"$dir/classification.txt"
  capture_host_pid "$host_pid" "$dir/host-after.txt"
  "$helper" cgroup "$socket" "$namespace" "$id" "$dir/cgroup-after.txt"
  assert_lowlevel_cgroup_capture "$runtime" "$dir/cgroup-after.txt" "$dir/host-after.txt" "$host_pid"
  "$helper" dump-container "$socket" "$namespace" "$id" "$dir/container-after"
  "$helper" delete "$socket" "$namespace" "$id" confirm-owned-s34-resource-probe
}

capture_versions_and_node before
run_bounded_capture before 300
baseline_captured=true
for pod in "${pods[@]}" s34a-hugepage-reject; do
  test -z "$("${kube[@]}" get pod "$pod" --ignore-not-found -o name)"
done
test "$(sha256sum "$live_containerd" | awk '{print $1}')" = "$expected_original_containerd"
install_trace_containerd

mkdir -p "$evidence/kubernetes"
workloads_started=true
for runtime in runc cube; do
  for qos in besteffort burstable guaranteed; do
    pod=s34a-$runtime-$qos
    mkdir -p "$evidence/kubernetes/$pod"
    create_pod_input "$pod" "$runtime" "$qos" "$evidence/kubernetes/$pod/input.json"
    "${kube[@]}" apply -f "$evidence/kubernetes/$pod/input.json" >"$evidence/kubernetes/$pod/apply.txt"
    uid=$(pod_json "$pod" | jq -er '.metadata.uid')
    remember_pod_uid "$uid"
    printf '%s\n' "$uid" >"$evidence/kubernetes/$pod/pod-uid.txt"
  done
done

for pod in "${pods[@]}"; do
  wait_container_state "$pod" classic running
  pod_json "$pod" >"$evidence/kubernetes/$pod/classic-running-pod.json"
  uid=$(jq -er '.metadata.uid' "$evidence/kubernetes/$pod/classic-running-pod.json")
  remember_pod_uid "$uid"
  capture_sandbox_input "$pod"
  capture_container_input "$pod" classic create
  "${kube[@]}" exec "$pod" -c classic -- touch /evidence/release
done

for pod in "${pods[@]}"; do
  wait_pod_ready "$pod"
  runtime=$(cut -d- -f2 <<<"$pod")
  qos=$(cut -d- -f3 <<<"$pod")
  pod_json "$pod" >"$evidence/kubernetes/$pod/ready-pod.json"
  case "$qos" in besteffort) expected_qos=BestEffort;; burstable) expected_qos=Burstable;; guaranteed) expected_qos=Guaranteed;; esac
  test "$(jq -r '.status.qosClass' "$evidence/kubernetes/$pod/ready-pod.json")" = "$expected_qos"
  "${kube[@]}" get events --field-selector "involvedObject.name=$pod" -o json >"$evidence/kubernetes/$pod/events.json"
  "${kube[@]}" exec "$pod" -c app -- cat /evidence/classic.txt >"$evidence/kubernetes/$pod/classic-cgroup.txt"
  assert_cgroup_capture "$evidence/kubernetes/$pod/classic-cgroup.txt"
  for role in sidecar app; do
    capture_container_input "$pod" "$role" create
    guest_cgroup "$pod" "$role" "$evidence/kubernetes/$pod/$role-cgroup-before.txt"
  done
  capture_pod_host_topology "$pod" "$runtime"
  "${cri[@]}" statsp "$(sandbox_id "$pod")" >"$evidence/kubernetes/$pod/crictl-statsp.json"
  capture_ephemeral_evidence "$pod"
done

{
  for pod in "${pods[@]}"; do
    container_id "$pod" classic
    container_id "$pod" sidecar
    container_id "$pod" app
  done
} | LC_ALL=C sort -u >"$trace_root/ids"
cp "$trace_root/ids" "$evidence/trace-allowlist.txt"
prove_trace_health before-resize

classic_resize_updates_kubelet_accounting_only s34a-runc-guaranteed
classic_resize_updates_kubelet_accounting_only s34a-cube-guaranteed
resize_guaranteed_pod s34a-runc-guaranteed runc
resize_guaranteed_pod s34a-cube-guaranteed cube

for pod in s34a-runc-guaranteed s34a-cube-guaranteed; do
  runtime=$(cut -d- -f2 <<<"$pod")
  capture_container_input "$pod" classic post-pod-resize persisted
  cmp "$evidence/kubernetes/$pod/classic-create/raw-containerd/container-spec.value" \
    "$evidence/kubernetes/$pod/classic-post-pod-resize/raw-containerd/container-spec.value"
  for role in sidecar app; do
    capture_container_input "$pod" "$role" update
    guest_cgroup "$pod" "$role" "$evidence/kubernetes/$pod/$role-cgroup-after.txt"
  done
  capture_pod_host_topology "$pod" "$runtime" after
done
cat >"$evidence/kubernetes/hugepage-input.json" <<EOF
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"s34a-hugepage-reject","labels":{"cubesandbox.io/s34-owned":"true","cubesandbox.io/s34-run":"$token"}},"spec":{"nodeName":"$node","runtimeClassName":"cube","restartPolicy":"Never","containers":[{"name":"app","image":"$image","resources":{"requests":{"cpu":"10m","memory":"16Mi","hugepages-2Mi":"2Mi"},"limits":{"cpu":"10m","memory":"16Mi","hugepages-2Mi":"2Mi"}},"command":["sh","-c","sleep 60"]}]}}
EOF
"${kube[@]}" apply -f "$evidence/kubernetes/hugepage-input.json" >"$evidence/kubernetes/hugepage-apply.txt"
uid=$(pod_json s34a-hugepage-reject | jq -er '.metadata.uid')
remember_pod_uid "$uid"
printf '%s\n' "$uid" >"$evidence/kubernetes/hugepage-pod-uid.txt"
for _ in $(seq 1 300); do
  "${kube[@]}" get pod s34a-hugepage-reject -o json >"$evidence/kubernetes/hugepage-pod.json"
  "${kube[@]}" get events --field-selector involvedObject.name=s34a-hugepage-reject -o json >"$evidence/kubernetes/hugepage-events.json"
  if jq -e '
    .status.phase == "Failed" and
    .status.reason == "OutOfhugepages-2Mi" and
    ((.status.message // "") | test("hugepages-2Mi"; "i"))
  ' "$evidence/kubernetes/hugepage-pod.json" >/dev/null && jq -e --arg uid "$uid" '
    [.items[] | select(
      .involvedObject.uid == $uid and
      .type == "Warning" and
      .reason == "OutOfhugepages-2Mi" and
      ((.message // "") | test("hugepages-2Mi"; "i"))
    )] | length >= 1
  ' "$evidence/kubernetes/hugepage-events.json" >/dev/null; then break; fi
  sleep .2
done
jq -e --arg uid "$uid" --arg node "$node" --arg token "$token" '
  .metadata.name == "s34a-hugepage-reject" and
  .metadata.uid == $uid and
  .metadata.labels["cubesandbox.io/s34-owned"] == "true" and
  .metadata.labels["cubesandbox.io/s34-run"] == $token and
  .spec.nodeName == $node and
  .spec.runtimeClassName == "cube" and
  .spec.containers[0].resources.requests == {"cpu":"10m","hugepages-2Mi":"2Mi","memory":"16Mi"} and
  .spec.containers[0].resources.limits == {"cpu":"10m","hugepages-2Mi":"2Mi","memory":"16Mi"} and
  .status.phase == "Failed" and
  .status.reason == "OutOfhugepages-2Mi" and
  ((.status.message // "") | test("hugepages-2Mi"; "i"))
' "$evidence/kubernetes/hugepage-pod.json" >/dev/null
jq -e --arg uid "$uid" '
  [.items[] | select(
    .involvedObject.uid == $uid and
    .type == "Warning" and
    .reason == "OutOfhugepages-2Mi" and
    ((.message // "") | test("hugepages-2Mi"; "i"))
  )] | length >= 1
' "$evidence/kubernetes/hugepage-events.json" >/dev/null
"${cri[@]}" pods --name s34a-hugepage-reject -o json >"$evidence/kubernetes/hugepage-sandboxes.json"
jq -e --arg uid "$uid" '
  [.items[] | select(.metadata.name == "s34a-hugepage-reject" and .metadata.uid == $uid)] | length == 0
' "$evidence/kubernetes/hugepage-sandboxes.json" >/dev/null

cube_lowlevel_sandbox=$(sandbox_id s34a-cube-besteffort)
for runtime in runc cube; do
  low_sandbox=-
  if test "$runtime" = cube; then low_sandbox=$cube_lowlevel_sandbox; fi
  for case_name in cpu memory-limit memory-reservation swap cpuset pids hugepage-create hugepage-update unified; do
    run_lowlevel_case "$runtime" "$case_name" "$low_sandbox"
  done
  run_invalid_unified_case "$runtime" "$low_sandbox"
done

for pod in s34a-runc-guaranteed s34a-cube-guaranteed; do
  classic=$(cat "$evidence/kubernetes/$pod/classic-create/container-id.txt")
  pod_json "$pod" >"$evidence/kubernetes/$pod/classic-tail.status.json"
  jq -e --arg classic "containerd://$classic" '
    (.spec.initContainers[] | select(.name == "classic") |
      .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
      .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
      .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
    (.status.initContainerStatuses[] | select(.name == "classic") |
      .containerID == $classic and .state.terminated.exitCode == 0 and .restartCount == 0 and
      .allocatedResources.cpu == "250m" and .allocatedResources.memory == "128Mi" and
      .allocatedResources["ephemeral-storage"] == "2Mi" and
      .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m" and
      .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
      .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
    ([.status.conditions[]? | select(.type == "PodResizeInProgress" or .type == "PodResizePending")] | length == 0)
  ' "$evidence/kubernetes/$pod/classic-tail.status.json" >/dev/null
done

capture_versions_and_node after
run_bounded_capture active 300
printf 'trace_health=runc+cube raw_create=metadata+oci raw_update=cri+task lowlevel_started=17 expected_create_reject=1 invalid_unified=2 cleanup=pending\n' >"$evidence/summary.txt"

delete_owned_pods
for _ in $(seq 1 1200); do
  if ! "${kube[@]}" get pod "${pods[@]}" s34a-hugepage-reject --ignore-not-found -o name | grep -q .; then break; fi
  sleep .1
done
wait_baseline pre-restore
cp -a "$trace_root" "$evidence/scoped-update-trace"
while IFS= read -r trace; do
  relative=${trace#"$trace_root/"}
  output=$evidence/scoped-update-decoded/${relative%.pb}
  mkdir -p "$(dirname "$output")"
  case "$trace" in
    *-cri-update.pb) "$helper" decode-update cri "$trace" "$output" ;;
    *-task-update.pb) "$helper" decode-update task "$trace" "$output" ;;
    *) false ;;
  esac
done < <(find "$trace_root" -type f -name '*.pb' | LC_ALL=C sort)
restore_containerd
if test "$trace_root_owned" = true; then
  rm -rf -- "$trace_root"
  trace_root_owned=false
fi
wait_baseline final
capture_versions_and_node final
printf 'trace_health=runc+cube raw_create=metadata+oci raw_update=cri+task lowlevel_started=17 expected_create_reject=1 invalid_unified=2 cleanup=exact\n' >"$evidence/summary.txt"
printf '%s\n' "$evidence" > /data/cubelet/s3.4-evidence/S34A_LATEST

printf 'S34A_DIAGNOSE_OK evidence=%s traced_containerd=%s helper=%s highlevel=6 lowlevel_started=17 expected_create_reject=1 cleanup=exact\n' \
  "$evidence" "$(sha256sum "$traced_containerd" | awk '{print $1}')" "$(sha256sum "$helper" | awk '{print $1}')"
