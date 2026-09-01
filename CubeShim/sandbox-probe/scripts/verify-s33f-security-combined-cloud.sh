#!/usr/bin/env bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
ordinary_image='registry.k8s.io/e2e-test-images/agnhost@sha256:2c5b5b056076334e4cf431d964d102e44cbca8f1e6b16ac1e477a0ffbe6caac4'
privileged_image='docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'
shim=/usr/local/bin/containerd-shim-cube-rs
agent=/data/cubelet/s13-kubernetes/assets/agent
expected_shim=3c7156524fb62bd595840fd9e4cb306682a98f56b28c96a37623be76fa2770f3
expected_agent=87bac7a6cc620595ece5fa5dfa046da8d7b0a6afe63193d7990c6f535b6e6873
fragment=/etc/containerd/conf.d/95-cubesandbox-s33e-privileged.toml
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
token=s33f-$(date -u +%Y%m%dT%H%M%SZ)-$$
evidence=/data/cubelet/s3.3-evidence/$token
configmap=cubesandbox-s33f-probe
pods=(
  cubesandbox-s33f-runc-strict
  cubesandbox-s33f-cube-off-strict
  cubesandbox-s33f-runc-merge
  cubesandbox-s33f-cube-off-merge
  cubesandbox-s33f-cube-off-privileged
  cubesandbox-s33f-cube-on-strict
  cubesandbox-s33f-cube-mixed
  cubesandbox-s33f-cube-host-dev
  cubesandbox-s33f-runc-invalid-cap
  cubesandbox-s33f-cube-invalid-cap
  cubesandbox-s33f-runc-nonroot-zero
  cubesandbox-s33f-cube-nonroot-zero
)
pod_uids=()
baseline_captured=false
configmap_uid=
configmap_name=
cleanup_rc=0
switch_restore_needed=false

count_entries() {
  local entries
  if test ! -d "$1"; then printf '0\n'; return 0; fi
  entries=$(find "$1" -mindepth 1 -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$entries" || return 1
}

count_files() {
  local entries
  entries=$(find "$1" -type f -name "$2" -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$entries" || return 1
}

lease_records() {
  count_files "$runtime_state/leases" '*.json'
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
      test "$rc" -eq 1 || return "$rc"
      count=$((count + 1))
    fi
  done <<<"$paths"
  printf '%s\n' "$count"
}

inactive_lease_count_for_sandbox() {
  local sandbox=$1 paths record record_sandbox count=0 rc
  paths=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    record_sandbox=$(jq -er '.sandboxID' "$record") || return 1
    test "$record_sandbox" = "$sandbox" || continue
    if jq -e '.active == null' "$record" >/dev/null; then
      count=$((count + 1))
    else
      rc=$?
      test "$rc" -eq 1 || return "$rc"
    fi
  done <<<"$paths"
  printf '%s\n' "$count"
}

shared_mounts() {
  local mounts
  mounts=$(findmnt -rn -o TARGET) || return 1
  awk -v root="$shared/" 'index($1, root) == 1 {n++} END {print n+0}' <<<"$mounts" || return 1
}

snapshot_tree_names() {
  local root=$1 output=$2 entries
  : >"$output" || return 1
  test -d "$root" || return 0
  entries=$(find "$root" -mindepth 1 -printf '%P\t%y\n') || return 1
  LC_ALL=C sort <<<"$entries" >"$output" || return 1
}

snapshot_cleanup_names() {
  local output=$1 entries
  entries=$(find "$containerd_state" -type f -name cube-runtime-resource.json -printf '%P\t%y\n') || return 1
  LC_ALL=C sort <<<"$entries" >"$output" || return 1
}

snapshot_shared_mount_names() {
  local output=$1 mounts
  mounts=$(findmnt -rn -o TARGET) || return 1
  awk -v root="$shared/" 'index($1, root) == 1 {print $1}' <<<"$mounts" | LC_ALL=C sort >"$output" || return 1
}

snapshot_active_lease_names() {
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
  local tag=$1 adapter shared_count reaper_count cleanup_count mount_count lease_count
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt" || return 1
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt" || return 1
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt" || return 1
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt" || return 1
  { if test -d /var/run/netns; then find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n' || return 1; fi; } | sort >"$evidence/netns-$tag.txt" || return 1
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort >"$evidence/cube-shims-$tag.txt" || return 1
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P\t%y\n' || return 1; fi; } | sort >"$evidence/vm-runtime-$tag.txt" || return 1
  snapshot_tree_names "$runtime_state/adapter" "$evidence/adapter-$tag.txt" || return 1
  snapshot_tree_names "$shared" "$evidence/shared-$tag.txt" || return 1
  snapshot_tree_names "$reaper" "$evidence/reaper-$tag.txt" || return 1
  snapshot_cleanup_names "$evidence/cleanup-markers-$tag.txt" || return 1
  snapshot_shared_mount_names "$evidence/shared-mounts-$tag.txt" || return 1
  snapshot_active_lease_names "$evidence/active-leases-$tag.txt" || return 1
  adapter=$(count_files "$runtime_state/adapter" '*') || return 1
  shared_count=$(count_entries "$shared") || return 1
  reaper_count=$(count_entries "$reaper") || return 1
  cleanup_count=$(count_files "$containerd_state" cube-runtime-resource.json) || return 1
  mount_count=$(shared_mounts) || return 1
  lease_count=$(active_leases) || return 1
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s\n' \
    "$adapter" "$shared_count" "$reaper_count" "$cleanup_count" "$mount_count" "$lease_count" \
    >"$evidence/runtime-resources-$tag.txt" || return 1
}

state_matches_before() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime adapter shared reaper cleanup-markers shared-mounts active-leases runtime-resources; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
}

assert_baseline() {
  local tag=$1
  for _ in $(seq 1 1800); do
    capture_state "$tag" || return 1
    if state_matches_before "$tag"; then return 0; fi
    sleep .1
  done
  capture_state "$tag" || return 1
  state_matches_before "$tag" || return 1
}

wait_node_ready() {
  local ready
  for _ in $(seq 1 1200); do
    ready=$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') || return 1
    if test "$ready" = True; then return 0; fi
    sleep .1
  done
  return 1
}

set_switch() {
  local value=$1
  if test "$value" != true && test "$value" != false; then return 1; fi
  test "$(grep -Ec 'CUBE_ALLOW_PRIVILEGED=(true|false)' "$fragment")" -eq 1 || return 1
  sed -i -E "s/CUBE_ALLOW_PRIVILEGED=(true|false)/CUBE_ALLOW_PRIVILEGED=$value/" "$fragment" || return 1
  grep -Fxq "  env = ['CUBE_ALLOW_PRIVILEGED=$value']" "$fragment" || return 1
  systemctl restart containerd || return 1
  for _ in $(seq 1 300); do systemctl is-active --quiet containerd && break; sleep .1; done
  systemctl is-active --quiet containerd || return 1
  wait_node_ready || return 1
  containerd config dump >"$evidence/containerd-config-switch-$value.toml" || return 1
  grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=$value']" "$evidence/containerd-config-switch-$value.toml" || return 1
}

fixed_pods_absent() {
  local pod object
  for pod in "${pods[@]}"; do
    object=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name) || return 1
    test -z "$object" || return 1
  done
}

remember_uid() {
  local uid=$1 existing
  for existing in "${pod_uids[@]}"; do test "$existing" != "$uid" || return 0; done
  pod_uids+=("$uid")
  printf '%s\n' "$uid" >>"$evidence/pod-uids.txt"
}

remember_pod_uid() {
  local uid
  uid=$(pod_uid "$1") || return 1
  remember_uid "$uid" || return 1
}

collect_existing_owned_uids() {
  local pod object uid result=0
  for pod in "${pods[@]}"; do
    if ! object=$("${kube[@]}" get pod "$pod" --ignore-not-found -o json); then result=1; continue; fi
    test -n "$object" || continue
    if ! test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-owned"] // ""' <<<"$object")" = true; then result=1; continue; fi
    if ! test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-run"] // ""' <<<"$object")" = "$token"; then result=1; continue; fi
    if ! uid=$(jq -er '.metadata.uid' <<<"$object"); then result=1; continue; fi
    remember_uid "$uid" || result=1
  done
  return "$result"
}

delete_owned_pods() {
  local pod object result=0
  for pod in "${pods[@]}"; do
    if ! object=$("${kube[@]}" get pod "$pod" --ignore-not-found -o json); then result=1; continue; fi
    test -n "$object" || continue
    if ! test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-owned"] // ""' <<<"$object")" = true; then result=1; continue; fi
    if ! test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-run"] // ""' <<<"$object")" = "$token"; then result=1; continue; fi
    "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null || result=1
  done
  return "$result"
}

delete_owned_configmap() {
  local object
  object=$("${kube[@]}" get configmap "$configmap" --ignore-not-found -o json) || return 1
  test -n "$object" || return 0
  test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-owned"] // ""' <<<"$object")" = true || return 1
  test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-run"] // ""' <<<"$object")" = "$token" || return 1
  if test -n "$configmap_uid"; then test "$(jq -er '.metadata.uid' <<<"$object")" = "$configmap_uid" || return 1; fi
  "${kube[@]}" delete configmap "$configmap" --wait=true >/dev/null || return 1
}

pods_absent() {
  fixed_pods_absent
}

wait_pods_absent() {
  local pod object all_absent
  for _ in $(seq 1 1200); do
    all_absent=true
    for pod in "${pods[@]}"; do
      object=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name) || return 1
      if test -n "$object"; then all_absent=false; fi
    done
    test "$all_absent" = false || return 0
    sleep .1
  done
  return 1
}

wait_pod_dirs_absent() {
  local uid
  for uid in "${pod_uids[@]}"; do
    for _ in $(seq 1 1200); do
      test ! -e "/var/lib/kubelet/pods/$uid" && test ! -L "/var/lib/kubelet/pods/$uid" && break
      sleep .1
    done
    test ! -e "/var/lib/kubelet/pods/$uid" && test ! -L "/var/lib/kubelet/pods/$uid" || return 1
  done
}

cleanup() {
  local rc=$? exact=false absent=false dirs=false leases=false switch=false
  trap - EXIT INT TERM HUP
  set +e
  collect_existing_owned_uids || cleanup_rc=1
  delete_owned_pods || cleanup_rc=1
  if test "$switch_restore_needed" = true; then
    if set_switch false; then switch_restore_needed=false; else cleanup_rc=1; fi
  fi
  if grep -Fxq "  env = ['CUBE_ALLOW_PRIVILEGED=false']" "$fragment" &&
     containerd config dump >"$evidence/containerd-config-cleanup.toml" &&
     grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=false']" "$evidence/containerd-config-cleanup.toml"; then
    switch=true
  else
    cleanup_rc=1
  fi
  if wait_pods_absent && pods_absent; then absent=true; else cleanup_rc=1; fi
  if wait_pod_dirs_absent; then dirs=true; else cleanup_rc=1; fi
  if test "$(active_leases 2>/dev/null)" = 0; then leases=true; else cleanup_rc=1; fi
  if test "$baseline_captured" = true && assert_baseline cleanup; then exact=true; else cleanup_rc=1; fi
  delete_owned_configmap || cleanup_rc=1
  printf 'original_rc=%s cleanup_rc=%s switch_false=%s pods_absent=%s pod_dirs_absent=%s active_leases_zero=%s exact_baseline=%s\n' \
    "$rc" "$cleanup_rc" "$switch" "$absent" "$dirs" "$leases" "$exact" >"$evidence/cleanup-result.txt" || cleanup_rc=1
  test -s "$evidence/cleanup-result.txt" || cleanup_rc=1
  test "$cleanup_rc" -eq 0 || exit 1
  exit "$rc"
}

pod_uid() {
  local pod=$1 object uid
  object=$("${kube[@]}" get pod "$pod" -o json) || return 1
  test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-owned"] // ""' <<<"$object")" = true || return 1
  test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-run"] // ""' <<<"$object")" = "$token" || return 1
  uid=$(jq -er '.metadata.uid' <<<"$object") || return 1
  printf '%s\n' "$uid" || return 1
}

sandbox_for_uid_optional() {
  local uid=$1 ids count
  ids=$("${cri[@]}" pods -o json | jq -r --arg uid "$uid" '.items[]? | select(.labels["io.kubernetes.pod.uid"]==$uid) | .id') || return 1
  count=$(awk 'NF {n++} END {print n+0}' <<<"$ids") || return 1
  test "$count" -le 1 || return 1
  printf '%s\n' "$ids" || return 1
}

record_cube_sandbox_optional() {
  local phase=$1 pod=$2 uid sandbox
  uid=$(pod_uid "$pod") || return 1
  sandbox=$(sandbox_for_uid_optional "$uid") || return 1
  test -n "$sandbox" || return 0
  if awk -F '\t' -v id="$sandbox" 'NR>1 && $3==id {found=1} END {exit !found}' "$evidence/cube-sandboxes.tsv"; then return 1; else
    local rc=$?
    test "$rc" -eq 1 || return "$rc"
  fi
  printf '%s\t%s\t%s\n' "$phase" "$pod" "$sandbox" >>"$evidence/cube-sandboxes.tsv" || return 1
}

container_for_uid_name() {
  local uid=$1 name=$2 ids count
  ids=$("${cri[@]}" ps -a -o json | jq -r --arg uid "$uid" --arg name "$name" \
    '.containers[]? | select(.labels["io.kubernetes.pod.uid"]==$uid and .metadata.name==$name) | .id') || return 1
  count=$(awk 'NF {n++} END {print n+0}' <<<"$ids") || return 1
  test "$count" -eq 1 || return 1
  printf '%s\n' "$ids" || return 1
}

wait_failure() {
  local pod=$1 reason=$2 needle=$3 object actual_reason message
  for _ in $(seq 1 1200); do
    object=$("${kube[@]}" get pod "$pod" -o json)
    actual_reason=$(jq -r '.status.containerStatuses[0].state as $s | ($s.waiting // $s.terminated // {}).reason // ""' <<<"$object")
    message=$(jq -r '.status.containerStatuses[0].state as $s | ($s.waiting // $s.terminated // {}).message // ""' <<<"$object")
    if test "$actual_reason" = "$reason" && [[ "$message" == *"$needle"* ]]; then
      printf '%s\n' "$object" >"$evidence/pod-$pod.json"
      printf 'reason=%s\nmessage=%s\n' "$actual_reason" "$message" >"$evidence/failure-$pod.txt"
      return 0
    fi
    sleep .25
  done
  printf '%s\n' "$object" >"$evidence/pod-$pod-timeout.json"
  return 1
}

normalize_spec() {
  local input=$1 root=$2 output=$3
  jq -S --arg root "$root" '
    def caps: {
      bounding:(.bounding//[]|sort), effective:(.effective//[]|sort),
      inheritable:(.inheritable//[]|sort), permitted:(.permitted//[]|sort), ambient:(.ambient//[]|sort)
    };
    def sec:
      if . == null then null else {
        architectures:(.architectures//[]|sort), defaultAction:.defaultAction, flags:(.flags//[]|sort),
        syscalls:(.syscalls//[] | map({names:(.names//[]|sort),action:.action,args:(.args//[]|sort_by(.index,.op,.value,.valueTwo)),errnoRet:(.errnoRet//null)}) | sort_by(.action,(.names|join(","))))
      } end;
    getpath($root|split(".")) as $s |
    {
      processUser:{uid:$s.process.user.uid,gid:$s.process.user.gid,additionalGids:($s.process.user.additionalGids//[]|sort)},
      capabilities:(($s.process.capabilities//{})|caps),
      noNewPrivileges:($s.process.noNewPrivileges//false),
      rootReadonly:($s.root.readonly//false),
      seccomp:(($s.linux.seccomp//null)|sec),
      devices:(($s.linux.devices//[])|map({path,type,major,minor,fileMode,uid,gid})|sort_by(.path)),
      deviceRules:(($s.linux.resources.devices//[])|map({allow,type,major,minor,access})|sort_by(.allow,.type,.major,.minor,.access)),
      mounts:(($s.mounts//[])|map({destination,type,options:(.options//[]|sort)})|sort_by(.destination,.type))
    }
  ' "$input" >"$output"
}

field() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

proc_field() {
  awk -F: -v key="$2" '$1==key {gsub(/^[[:space:]]+/,"",$2); print $2}' "$1" | tail -n 1
}

normalize_guest() {
  local input=$1 output=$2 groups filters
  groups=$(field "$input" GROUPS | tr ' ' '\n' | awk 'NF' | sort -n | paste -sd, -)
  filters=$(proc_field "$input" Seccomp_filters)
  test -n "$filters" || filters=0
  jq -n -S \
    --arg uid "$(field "$input" UID)" --arg gid "$(field "$input" GID)" --arg groups "$groups" \
    --arg capinh "$(proc_field "$input" CapInh)" --arg capprm "$(proc_field "$input" CapPrm)" \
    --arg capeff "$(proc_field "$input" CapEff)" --arg capbnd "$(proc_field "$input" CapBnd)" \
    --arg capamb "$(proc_field "$input" CapAmb)" --arg nnp "$(proc_field "$input" NoNewPrivs)" \
    --arg seccomp "$(proc_field "$input" Seccomp)" --arg filters "$filters" \
    --arg rootMode "$(field "$input" ROOT_MODE)" --arg rootWrite "$(field "$input" ROOT_WRITE)" \
    --arg volumeGid "$(field "$input" VOLUME_GID)" --arg volumeWrite "$(field "$input" VOLUME_WRITE)" \
    --arg devKvm "$(field "$input" DEV_KVM)" --arg mountResult "$(field "$input" MOUNT_RESULT)" \
    --arg cgroupMode "$(field "$input" CGROUP_MODE)" --arg deviceList "$(field "$input" DEVICE_LIST)" \
    '{uid:$uid,gid:$gid,groups:$groups,capabilities:{inheritable:$capinh,permitted:$capprm,effective:$capeff,bounding:$capbnd,ambient:$capamb},noNewPrivileges:$nnp,seccompMode:$seccomp,seccompFiltered:(($filters|tonumber)>0),rootMode:$rootMode,rootWrite:$rootWrite,volumeGid:$volumeGid,volumeWrite:$volumeWrite,devKvm:$devKvm,mountResult:$mountResult,cgroupMode:$cgroupMode,deviceList:$deviceList}' \
    >"$output"
}

capture_container() {
  local phase=$1 pod=$2 name=$3 uid id tag sandbox
  uid=$(pod_uid "$pod") || return 1
  id=$(container_for_uid_name "$uid" "$name") || return 1
  tag=$phase-$pod-$name
  if grep -Fxq "$id" "$evidence/container-ids.txt"; then return 1; else
    local rc=$?
    test "$rc" -eq 1 || return "$rc"
  fi
  printf '%s\n' "$id" >>"$evidence/container-ids.txt" || return 1
  "${cri[@]}" inspect "$id" >"$evidence/cri-$tag.json" || return 1
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$tag.json" || return 1
  normalize_spec "$evidence/cri-$tag.json" info.runtimeSpec "$evidence/input-$tag-cri.json" || return 1
  normalize_spec "$evidence/ctr-$tag.json" Spec "$evidence/input-$tag-ctr.json" || return 1
  cmp "$evidence/input-$tag-cri.json" "$evidence/input-$tag-ctr.json" || return 1
  "${kube[@]}" logs "$pod" -c "$name" >"$evidence/guest-$tag.txt" || return 1
  normalize_guest "$evidence/guest-$tag.txt" "$evidence/guest-semantic-$tag.json" || return 1
  test "$(jq -er '.status.labels["io.kubernetes.pod.uid"]' "$evidence/cri-$tag.json")" = "$uid" || return 1
  test "$(jq -er '.status.metadata.name' "$evidence/cri-$tag.json")" = "$name" || return 1
  sandbox=$(sandbox_for_uid_optional "$uid") || return 1
  test -n "$sandbox" || return 1
  test "$(jq -er '.info.sandboxID' "$evidence/cri-$tag.json")" = "$sandbox" || return 1
}

capture_shim_env_for_pods() {
  local phase=$1 expected=$2 pod uid sandbox pid count=0
  : >"$evidence/shim-env-$phase.txt"
  shift 2
  for pod in "$@"; do
    uid=$(pod_uid "$pod") || return 1
    sandbox=$(sandbox_for_uid_optional "$uid") || return 1
    test -n "$sandbox" || return 1
    pid=$(ps -eo pid=,args= | awk -v id="$sandbox" '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {print $1}') || return 1
    test "$(awk 'NF {n++} END {print n+0}' <<<"$pid")" -eq 1 || return 1
    tr '\0' '\n' <"/proc/$pid/environ" | grep '^CUBE_ALLOW_PRIVILEGED=' >>"$evidence/shim-env-$phase.txt" || return 1
    count=$((count + 1))
  done
  test "$(grep -Fxc "CUBE_ALLOW_PRIVILEGED=$expected" "$evidence/shim-env-$phase.txt")" -eq "$count" || return 1
}

write_probe_configmap() {
  cat >"$evidence/probe.sh" <<'PROBE'
#!/bin/sh
set -eu
name=$1
lifecycle=$2
root_write=$3
mount_mode=$4
root_options=$(awk '$5=="/" {print $6; exit}' /proc/self/mountinfo)
case ",$root_options," in *,ro,*) root_mode=ro;; *,rw,*) root_mode=rw;; *) root_mode=unknown;; esac
groups=$(id -G)
if printf '%s\n' "$name" >"/evidence/$name.marker"; then volume_write=ok; else volume_write=failed; fi
volume_gid=$(stat -c %g /evidence)
root_result=not-attempted
if test "$root_write" = yes; then
  set +e
  printf root-write >/.cubesandbox-s33f-root 2>/evidence/root-write.stderr
  root_rc=$?
  set -e
  if test "$root_rc" -eq 0; then root_result=ok; rm -f /.cubesandbox-s33f-root; elif grep -Fq 'Read-only file system' /evidence/root-write.stderr; then root_result=erofs; else root_result=denied; fi
fi
mount_result=not-attempted
mkdir -p "/evidence/$name-mount"
if test "$mount_mode" != skip; then
  if mount -t tmpfs tmpfs "/evidence/$name-mount" 2>/dev/null; then mount_result=allowed; umount "/evidence/$name-mount"; else mount_result=denied; fi
fi
if test -e /sys/fs/cgroup/cgroup.controllers; then cgroup_mode=v2; else cgroup_mode=v1; fi
if test -r /sys/fs/cgroup/devices/devices.list; then device_list=present; else device_list=missing; fi
printf 'NAME=%s\nUID=%s\nGID=%s\nGROUPS=%s\nROOT_MODE=%s\nROOT_WRITE=%s\nVOLUME_GID=%s\nVOLUME_WRITE=%s\nDEV_KVM=%s\nMOUNT_RESULT=%s\nCGROUP_MODE=%s\nDEVICE_LIST=%s\n' \
  "$name" "$(id -u)" "$(id -g)" "$groups" "$root_mode" "$root_result" "$volume_gid" "$volume_write" \
  "$(test -e /dev/kvm && echo present || echo absent)" "$mount_result" "$cgroup_mode" "$device_list"
grep -E '^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp|Seccomp_filters):' /proc/self/status
if test "$lifecycle" = sleep; then exec sleep 600; fi
PROBE
  "${kube[@]}" create configmap "$configmap" --from-file=probe.sh="$evidence/probe.sh" --dry-run=client -o json |
    jq --arg token "$token" '.metadata.labels={"cubesandbox.io/s33f-owned":"true","cubesandbox.io/s33f-run":$token}' \
      >"$evidence/configmap.json"
  "${kube[@]}" create -f "$evidence/configmap.json" -o json >"$evidence/configmap-created.json"
  configmap_uid=$(jq -er '.metadata.uid' "$evidence/configmap-created.json")
}

emit_strict_pod() {
  local name=$1 runtime=$2 runtime_line=
  test "$runtime" != cube || runtime_line='  runtimeClassName: cube'
  cat <<POD
apiVersion: v1
kind: Pod
metadata: {name: $name, labels: {cubesandbox.io/s33f-owned: "true", cubesandbox.io/s33f-run: "$token", cubesandbox.io/s33f-case: strict}}
spec:
$runtime_line
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: 1000, runAsGroup: 3000, supplementalGroups: [4000], fsGroup: 2000, supplementalGroupsPolicy: Strict}
  initContainers:
  - name: classic-init
    image: $ordinary_image
    command: ["sh", "/probe/probe.sh", "classic-init", "exit", "no", "skip"]
    securityContext: {runAsUser: 1100, runAsGroup: 3100, readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, seccompProfile: {type: RuntimeDefault}, capabilities: {drop: ["ALL"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  - name: sidecar
    image: $ordinary_image
    restartPolicy: Always
    command: ["sh", "/probe/probe.sh", "sidecar", "sleep", "no", "skip"]
    securityContext: {runAsUser: 1200, runAsGroup: 3200, readOnlyRootFilesystem: true, allowPrivilegeEscalation: true, seccompProfile: {type: Unconfined}, capabilities: {drop: ["ALL"], add: ["NET_BIND_SERVICE"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  containers:
  - name: app
    image: $ordinary_image
    command: ["sh", "/probe/probe.sh", "app", "sleep", "no", "ordinary"]
    securityContext: {readOnlyRootFilesystem: false, allowPrivilegeEscalation: false, seccompProfile: {type: RuntimeDefault}, capabilities: {drop: ["ALL"], add: ["NET_RAW"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  volumes: [{name: evidence, emptyDir: {}}, {name: probe, configMap: {name: $configmap}}]
POD
}

emit_merge_pod() {
  local name=$1 runtime=$2 runtime_line=
  test "$runtime" != cube || runtime_line='  runtimeClassName: cube'
  cat <<POD
apiVersion: v1
kind: Pod
metadata: {name: $name, labels: {cubesandbox.io/s33f-owned: "true", cubesandbox.io/s33f-run: "$token", cubesandbox.io/s33f-case: merge}}
spec:
$runtime_line
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: 1000, runAsGroup: 3000, supplementalGroups: [4000], fsGroup: 2000, supplementalGroupsPolicy: Merge}
  containers:
  - name: identity
    image: $ordinary_image
    command: ["sh", "/probe/probe.sh", "identity", "sleep", "no", "skip"]
    securityContext: {readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, seccompProfile: {type: RuntimeDefault}, capabilities: {drop: ["ALL"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  - name: boundary
    image: $ordinary_image
    command: ["sh", "/probe/probe.sh", "boundary", "sleep", "yes", "skip"]
    securityContext: {runAsUser: 0, runAsGroup: 0, readOnlyRootFilesystem: false, allowPrivilegeEscalation: true, seccompProfile: {type: Unconfined}, capabilities: {drop: ["ALL"], add: ["CHECKPOINT_RESTORE"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  volumes: [{name: evidence, emptyDir: {}}, {name: probe, configMap: {name: $configmap}}]
POD
}

write_off_manifest() {
  : >"$evidence/off.yaml"
  emit_strict_pod cubesandbox-s33f-runc-strict runc >>"$evidence/off.yaml"; printf '%s\n' '---' >>"$evidence/off.yaml"
  emit_strict_pod cubesandbox-s33f-cube-off-strict cube >>"$evidence/off.yaml"; printf '%s\n' '---' >>"$evidence/off.yaml"
  emit_merge_pod cubesandbox-s33f-runc-merge runc >>"$evidence/off.yaml"; printf '%s\n' '---' >>"$evidence/off.yaml"
  emit_merge_pod cubesandbox-s33f-cube-off-merge cube >>"$evidence/off.yaml"; printf '%s\n' '---' >>"$evidence/off.yaml"
  cat >>"$evidence/off.yaml" <<POD
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33f-cube-off-privileged, labels: {cubesandbox.io/s33f-owned: "true", cubesandbox.io/s33f-run: "$token", cubesandbox.io/s33f-case: privileged-off}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $privileged_image
    command: ["sh", "/probe/probe.sh", "privileged", "sleep", "yes", "privileged"]
    securityContext: {privileged: true, runAsUser: 0, runAsGroup: 0, readOnlyRootFilesystem: false, allowPrivilegeEscalation: true, seccompProfile: {type: Unconfined}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  volumes: [{name: evidence, emptyDir: {}}, {name: probe, configMap: {name: $configmap}}]
POD
}

write_on_manifest() {
  : >"$evidence/on.yaml"
  emit_strict_pod cubesandbox-s33f-cube-on-strict cube >>"$evidence/on.yaml"; printf '%s\n' '---' >>"$evidence/on.yaml"
  cat >>"$evidence/on.yaml" <<POD
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33f-cube-mixed, labels: {cubesandbox.io/s33f-owned: "true", cubesandbox.io/s33f-run: "$token", cubesandbox.io/s33f-case: mixed}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext: {runAsUser: 1000, runAsGroup: 3000, supplementalGroups: [4000], fsGroup: 2000, supplementalGroupsPolicy: Strict}
  containers:
  - name: ordinary
    image: $ordinary_image
    command: ["sh", "/probe/probe.sh", "ordinary", "sleep", "no", "ordinary"]
    securityContext: {readOnlyRootFilesystem: false, allowPrivilegeEscalation: false, seccompProfile: {type: RuntimeDefault}, capabilities: {drop: ["ALL"], add: ["NET_RAW"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  - name: privileged
    image: $privileged_image
    command: ["sh", "/probe/probe.sh", "privileged", "sleep", "yes", "privileged"]
    securityContext: {privileged: true, runAsUser: 0, runAsGroup: 0, readOnlyRootFilesystem: false, allowPrivilegeEscalation: true, seccompProfile: {type: Unconfined}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  volumes: [{name: evidence, emptyDir: {}}, {name: probe, configMap: {name: $configmap}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33f-cube-host-dev, labels: {cubesandbox.io/s33f-owned: "true", cubesandbox.io/s33f-run: "$token", cubesandbox.io/s33f-case: host-dev}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  volumes: [{name: host-dev, hostPath: {path: /dev, type: Directory}}]
  containers:
  - name: app
    image: $privileged_image
    command: ["sh", "-c", "exec sleep 600"]
    securityContext: {privileged: true}
    volumeMounts: [{name: host-dev, mountPath: /host-dev}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33f-runc-invalid-cap, labels: {cubesandbox.io/s33f-owned: "true", cubesandbox.io/s33f-run: "$token", cubesandbox.io/s33f-case: invalid-cap-runc}}
spec:
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $privileged_image
    command: ["sh", "/probe/probe.sh", "invalid-runc", "sleep", "no", "skip"]
    securityContext: {capabilities: {add: ["NOT_A_CAPABILITY"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  volumes: [{name: evidence, emptyDir: {}}, {name: probe, configMap: {name: $configmap}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33f-cube-invalid-cap, labels: {cubesandbox.io/s33f-owned: "true", cubesandbox.io/s33f-run: "$token", cubesandbox.io/s33f-case: invalid-cap-cube}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $privileged_image
    command: ["sh", "/probe/probe.sh", "invalid-cube", "sleep", "no", "skip"]
    securityContext: {capabilities: {add: ["NOT_A_CAPABILITY"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  volumes: [{name: evidence, emptyDir: {}}, {name: probe, configMap: {name: $configmap}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33f-runc-nonroot-zero, labels: {cubesandbox.io/s33f-owned: "true", cubesandbox.io/s33f-run: "$token", cubesandbox.io/s33f-case: nonroot-zero-runc}}
spec:
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $privileged_image
    command: ["sh", "-c", "exec sleep 600"]
    securityContext: {runAsNonRoot: true, runAsUser: 0}
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33f-cube-nonroot-zero, labels: {cubesandbox.io/s33f-owned: "true", cubesandbox.io/s33f-run: "$token", cubesandbox.io/s33f-case: nonroot-zero-cube}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $privileged_image
    command: ["sh", "-c", "exec sleep 600"]
    securityContext: {runAsNonRoot: true, runAsUser: 0}
POD
}

assert_ordinary_semantics() {
  local phase=$1 pod=$2 name=$3 uid=$4 gid=$5 groups=$6 caps=$7 ro=$8 nnp=$9 seccomp=${10}
  local guest=$evidence/guest-semantic-$phase-$pod-$name.json input=$evidence/input-$phase-$pod-$name-cri.json
  jq -e --argjson uid "$uid" --argjson gid "$gid" --arg groups "$groups" --argjson caps "$caps" --argjson ro "$ro" --argjson nnp "$nnp" --argjson seccomp "$seccomp" '
    .processUser.uid==$uid and .processUser.gid==$gid and (.processUser.additionalGids|map(tostring)|join(","))==$groups and
    .capabilities.bounding==$caps and .capabilities.effective==$caps and .capabilities.permitted==$caps and
    (.capabilities.inheritable|length)==0 and (.capabilities.ambient|length)==0 and
    .rootReadonly==$ro and .noNewPrivileges==$nnp and
    (if $seccomp then .seccomp!=null else .seccomp==null end) and
    ([.deviceRules[]|select(.allow==true and .type==null and .major==null and .minor==null and .access=="rwm")]|length)==0
  ' "$input" >/dev/null
  jq -e --arg uid "$uid" --arg gid "$gid" --arg groups "$groups" --argjson nnp "$nnp" --argjson seccomp "$seccomp" '
    .uid==$uid and .gid==$gid and .groups==$groups and .volumeGid=="2000" and .volumeWrite=="ok" and .devKvm=="absent" and
    .noNewPrivileges==($nnp|if . then "1" else "0" end) and
    (if $seccomp then .seccompMode=="2" and .seccompFiltered else .seccompMode=="0" and (.seccompFiltered|not) end)
  ' "$guest" >/dev/null
}

assert_guest_caps() {
  local phase=$1 pod=$2 name=$3 bounding=$4 permitted=$5 effective=$6
  local guest=$evidence/guest-semantic-$phase-$pod-$name.json
  jq -e --arg bounding "$bounding" --arg permitted "$permitted" --arg effective "$effective" \
    '.capabilities.permitted==$permitted and .capabilities.effective==$effective and .capabilities.bounding==$bounding and .capabilities.inheritable=="0000000000000000" and .capabilities.ambient=="0000000000000000"' \
    "$guest" >/dev/null
}

capture_strict() {
  local phase=$1 pod=$2
  capture_container "$phase" "$pod" classic-init
  capture_container "$phase" "$pod" sidecar
  capture_container "$phase" "$pod" app
  jq -e '.status.state=="CONTAINER_EXITED" and .status.exitCode==0' "$evidence/cri-$phase-$pod-classic-init.json" >/dev/null
  jq -e '.status.state=="CONTAINER_RUNNING"' "$evidence/cri-$phase-$pod-sidecar.json" >/dev/null
  jq -e '.status.state=="CONTAINER_RUNNING"' "$evidence/cri-$phase-$pod-app.json" >/dev/null
  assert_ordinary_semantics "$phase" "$pod" classic-init 1100 3100 2000,3100,4000 '[]' true true true
  assert_ordinary_semantics "$phase" "$pod" sidecar 1200 3200 2000,3200,4000 '["CAP_NET_BIND_SERVICE"]' true false false
  assert_ordinary_semantics "$phase" "$pod" app 1000 3000 2000,3000,4000 '["CAP_NET_RAW"]' false true true
  assert_guest_caps "$phase" "$pod" classic-init 0000000000000000 0000000000000000 0000000000000000
  assert_guest_caps "$phase" "$pod" sidecar 0000000000000400 0000000000000000 0000000000000000
  assert_guest_caps "$phase" "$pod" app 0000000000002000 0000000000000000 0000000000000000
  jq -e '.rootMode=="ro"' "$evidence/guest-semantic-$phase-$pod-classic-init.json" >/dev/null
  jq -e '.rootMode=="ro"' "$evidence/guest-semantic-$phase-$pod-sidecar.json" >/dev/null
  jq -e '.rootMode=="rw" and .mountResult=="denied"' "$evidence/guest-semantic-$phase-$pod-app.json" >/dev/null
}

capture_merge() {
  local phase=$1 pod=$2
  capture_container "$phase" "$pod" identity
  capture_container "$phase" "$pod" boundary
  jq -e '.status.state=="CONTAINER_RUNNING"' "$evidence/cri-$phase-$pod-identity.json" >/dev/null
  jq -e '.status.state=="CONTAINER_RUNNING"' "$evidence/cri-$phase-$pod-boundary.json" >/dev/null
  assert_ordinary_semantics "$phase" "$pod" identity 1000 3000 2000,3000,4000,50000 '[]' true true true
  assert_ordinary_semantics "$phase" "$pod" boundary 0 0 0,1,2,3,4,6,10,11,20,26,27,2000,4000 '["CAP_CHECKPOINT_RESTORE"]' false false false
  assert_guest_caps "$phase" "$pod" identity 0000000000000000 0000000000000000 0000000000000000
  assert_guest_caps "$phase" "$pod" boundary 0000010000000000 0000010000000000 0000010000000000
  jq -e '.rootMode=="ro"' "$evidence/guest-semantic-$phase-$pod-identity.json" >/dev/null
  jq -e '.rootMode=="rw" and .rootWrite=="ok"' "$evidence/guest-semantic-$phase-$pod-boundary.json" >/dev/null
}

compare_container_semantics() {
  local phase_a=$1 pod_a=$2 name_a=$3 runtime_a=$4 phase_b=$5 pod_b=$6 name_b=$7 runtime_b=$8
  local input_a=$evidence/input-$phase_a-$pod_a-$name_a-cri.json input_b=$evidence/input-$phase_b-$pod_b-$name_b-cri.json
  local security_a=$evidence/compare-security-$phase_a-$pod_a-$name_a.json security_b=$evidence/compare-security-$phase_b-$pod_b-$name_b.json
  local mounts_a=$evidence/compare-common-mounts-$phase_a-$pod_a-$name_a.json mounts_b=$evidence/compare-common-mounts-$phase_b-$pod_b-$name_b.json
  assert_mount_partition "$input_a" "$runtime_a" || return 1
  assert_mount_partition "$input_b" "$runtime_b" || return 1
  jq -S 'del(.mounts)' "$input_a" >"$security_a" || return 1
  jq -S 'del(.mounts)' "$input_b" >"$security_b" || return 1
  cmp "$security_a" "$security_b" || return 1
  jq -S '{mounts:[.mounts[]|select(.destination!="/dev/shm" and .destination!="/etc/hostname" and .destination!="/etc/resolv.conf")]}' "$input_a" >"$mounts_a" || return 1
  jq -S '{mounts:[.mounts[]|select(.destination!="/dev/shm" and .destination!="/etc/hostname" and .destination!="/etc/resolv.conf")]}' "$input_b" >"$mounts_b" || return 1
  cmp "$mounts_a" "$mounts_b" || return 1
  if test "$runtime_a" = "$runtime_b"; then cmp "$input_a" "$input_b" || return 1; fi
  cmp "$evidence/guest-semantic-$phase_a-$pod_a-$name_a.json" "$evidence/guest-semantic-$phase_b-$pod_b-$name_b.json" || return 1
}

assert_mount_partition() {
  local input=$1 runtime=$2
  jq -e '
    ([.mounts[].destination]|length)==([.mounts[].destination]|unique|length) and
    any(.mounts[]; .destination=="/evidence" and .type=="bind" and .options==["rbind","rprivate","rw"]) and
    any(.mounts[]; .destination=="/probe" and .type=="bind" and .options==["rbind","ro","rprivate"]) and
    any(.mounts[]; .destination=="/etc/hosts" and .type=="bind") and
    any(.mounts[]; .destination=="/proc" and .type=="proc") and
    any(.mounts[]; .destination=="/sys" and .type=="sysfs") and
    any(.mounts[]; .destination=="/sys/fs/cgroup" and .type=="cgroup")
  ' "$input" >/dev/null || return 1
  if test "$runtime" = runc; then
    jq -e '
      any(.mounts[]; .destination=="/dev/shm" and .type=="bind" and .options==["rbind","rprivate","rw"]) and
      (if .rootReadonly then
        ([.mounts[]|select(.destination=="/etc/hostname" and .type=="bind" and .options==["rbind","ro","rprivate"])]|length)==1 and
        ([.mounts[]|select(.destination=="/etc/resolv.conf" and .type=="bind" and .options==["rbind","ro","rprivate"])]|length)==1
      else
        ([.mounts[]|select(.destination=="/etc/hostname" and .type=="bind" and .options==["rbind","rprivate","rw"])]|length)==1 and
        ([.mounts[]|select(.destination=="/etc/resolv.conf" and .type=="bind" and .options==["rbind","rprivate","rw"])]|length)==1
      end)
    ' "$input" >/dev/null || return 1
  elif test "$runtime" = cube; then
    jq -e '
      any(.mounts[]; .destination=="/dev/shm" and .type=="tmpfs" and .options==["mode=1777","nodev","noexec","nosuid","size=65536k"]) and
      ([.mounts[]|select(.destination=="/etc/hostname" or .destination=="/etc/resolv.conf")]|length)==0
    ' "$input" >/dev/null || return 1
  else
    return 1
  fi
}

capture_exec() {
  local phase=$1 pod=$2 groups
  local output=$evidence/exec-$phase-$pod-app.txt normalized=$evidence/exec-semantic-$phase-$pod-app.json
  "${kube[@]}" exec "$pod" -c app -- sh -c 'printf "UID=%s\nGID=%s\nGROUPS=%s\nVOLUME_GID=%s\n" "$(id -u)" "$(id -g)" "$(id -G)" "$(stat -c %g /evidence)"; grep -E "^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp|Seccomp_filters):" /proc/self/status' >"$output"
  groups=$(field "$output" GROUPS | tr ' ' '\n' | awk 'NF' | sort -n | paste -sd, -)
  jq -n -S --arg uid "$(field "$output" UID)" --arg gid "$(field "$output" GID)" --arg groups "$groups" --arg volume "$(field "$output" VOLUME_GID)" \
    --arg capinh "$(proc_field "$output" CapInh)" --arg capprm "$(proc_field "$output" CapPrm)" --arg capeff "$(proc_field "$output" CapEff)" --arg capbnd "$(proc_field "$output" CapBnd)" --arg capamb "$(proc_field "$output" CapAmb)" \
    --arg nnp "$(proc_field "$output" NoNewPrivs)" --arg seccomp "$(proc_field "$output" Seccomp)" '{uid:$uid,gid:$gid,groups:$groups,volumeGid:$volume,capabilities:{inheritable:$capinh,permitted:$capprm,effective:$capeff,bounding:$capbnd,ambient:$capamb},noNewPrivileges:$nnp,seccompMode:$seccomp}' >"$normalized"
  jq -e '.uid=="1000" and .gid=="3000" and .groups=="2000,3000,4000" and .volumeGid=="2000" and .capabilities.permitted=="0000000000000000" and .capabilities.effective=="0000000000000000" and .capabilities.bounding=="0000000000002000" and .capabilities.inheritable=="0000000000000000" and .capabilities.ambient=="0000000000000000" and .noNewPrivileges=="1" and .seccompMode=="2"' "$normalized" >/dev/null
}

capture_failed_workload() {
  local pod=$1 record_policy=$2 uid logs_rc ids id count sandbox record_state
  uid=$(pod_uid "$pod") || return 1
  "${cri[@]}" ps -o json >"$evidence/cri-running-$pod.json" || return 1
  "${cri[@]}" ps -a -o json >"$evidence/cri-all-$pod.json" || return 1
  "${ctr[@]}" tasks list -q | sort >"$evidence/ctr-tasks-$pod.txt" || return 1
  "${ctr[@]}" containers list -q | sort >"$evidence/ctr-containers-$pod.txt" || return 1
  test "$(jq -er --arg uid "$uid" '[.containers[]? | select(.labels["io.kubernetes.pod.uid"]==$uid)] | length' "$evidence/cri-running-$pod.json")" -eq 0 || return 1
  ids=$(jq -r --arg uid "$uid" '.containers[]? | select(.labels["io.kubernetes.pod.uid"]==$uid) | .id' "$evidence/cri-all-$pod.json") || return 1
  count=$(awk 'NF {n++} END {print n+0}' <<<"$ids") || return 1
  printf '%s\n' "$ids" >"$evidence/cri-container-ids-$pod.txt" || return 1
  printf 'pod=%s\nuid=%s\ncri_container_records=%s\n' "$pod" "$uid" "$count" >"$evidence/failed-workload-$pod.txt" || return 1
  if test "$record_policy" = no-record; then
    test "$count" -eq 0 || return 1
    sandbox=
  elif test "$record_policy" = start-error; then
    test "$count" -ge 1 || return 1
    sandbox=$(sandbox_for_uid_optional "$uid") || return 1
    test -n "$sandbox" || return 1
  else
    return 1
  fi
  while IFS= read -r id; do
    test -n "$id" || continue
    if grep -Fxq "$id" "$evidence/ctr-tasks-$pod.txt"; then return 1; fi
    "${cri[@]}" inspect "$id" >"$evidence/cri-failed-$pod-$id.json" || return 1
    test "$(jq -er '.status.labels["io.kubernetes.pod.uid"]' "$evidence/cri-failed-$pod-$id.json")" = "$uid" || return 1
    test "$(jq -er '.status.metadata.name' "$evidence/cri-failed-$pod-$id.json")" = app || return 1
    record_state=$(jq -er '.status.state' "$evidence/cri-failed-$pod-$id.json") || return 1
    test "$record_state" != CONTAINER_RUNNING || return 1
    test "$record_policy" = start-error || return 1
    test "$(jq -er '.info.sandboxID' "$evidence/cri-failed-$pod-$id.json")" = "$sandbox" || return 1
    normalize_spec "$evidence/cri-failed-$pod-$id.json" info.runtimeSpec "$evidence/input-failed-$pod-$id-cri.json" || return 1
    if grep -Fxq "$id" "$evidence/ctr-containers-$pod.txt"; then
      "${ctr[@]}" containers info "$id" >"$evidence/ctr-failed-$pod-$id.json" 2>"$evidence/ctr-failed-$pod-$id.stderr" || return 1
      normalize_spec "$evidence/ctr-failed-$pod-$id.json" Spec "$evidence/input-failed-$pod-$id-ctr.json" || return 1
      cmp "$evidence/input-failed-$pod-$id-cri.json" "$evidence/input-failed-$pod-$id-ctr.json" || return 1
      printf 'ctr_record=%s\n' "$id" >>"$evidence/failed-workload-$pod.txt" || return 1
    else
      printf 'ctr_record_absent=%s\n' "$id" >>"$evidence/failed-workload-$pod.txt" || return 1
    fi
  done <<<"$ids"
  set +e
  "${kube[@]}" logs "$pod" -c app >"$evidence/logs-$pod.stdout" 2>"$evidence/logs-$pod.stderr"
  logs_rc=$?
  set -e
  printf 'logs_rc=%s\n' "$logs_rc" >>"$evidence/failed-workload-$pod.txt" || return 1
  test ! -s "$evidence/logs-$pod.stdout" || return 1
}

capture_pod_json() {
  local phase=$1 pod=$2
  "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-$phase-$pod.json"
  jq -e --arg token "$token" --arg pod "$pod" \
    '.metadata.name==$pod and .metadata.labels["cubesandbox.io/s33f-owned"]=="true" and .metadata.labels["cubesandbox.io/s33f-run"]==$token' \
    "$evidence/pod-$phase-$pod.json" >/dev/null
}

snapshot_leases() {
  local tag=$1 record paths
  : >"$evidence/leases-$tag.jsonl"
  paths=$(find "$runtime_state/leases" -type f -name '*.json' -print | sort) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    jq -cS . "$record" >>"$evidence/leases-$tag.jsonl" || return 1
  done <<<"$paths"
}

mkdir -m 0700 "$evidence"
: >"$evidence/pod-uids.txt"
: >"$evidence/container-ids.txt"
printf 'phase\tpod\tsandbox\n' >"$evidence/cube-sandboxes.tsv"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fixed_pods_absent
configmap_name=$("${kube[@]}" get configmap "$configmap" --ignore-not-found -o name)
test -z "$configmap_name"
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.features.supplementalGroupsPolicy}')" = true
test "$(sha256sum "$shim" | awk '{print $1}')" = "$expected_shim"
test "$(sha256sum "$agent" | awk '{print $1}')" = "$expected_agent"
test "$(active_leases)" -eq 0
test -f "$fragment"; test ! -L "$fragment"
grep -Fxq "  env = ['CUBE_ALLOW_PRIVILEGED=false']" "$fragment"
"${cri[@]}" pull "$ordinary_image" >"$evidence/pull-ordinary.txt"
"${cri[@]}" pull "$privileged_image" >"$evidence/pull-privileged.txt"
capture_state before
baseline_captured=true
leases_before=$(lease_records)
printf '%s\n' "$leases_before" >"$evidence/lease-count-before.txt"
snapshot_leases before
write_probe_configmap
containerd config dump >"$evidence/containerd-config-initial.toml"
grep -Fq 'privileged_without_host_devices = true' "$evidence/containerd-config-initial.toml"
grep -Fq 'privileged_without_host_devices_all_devices_allowed = true' "$evidence/containerd-config-initial.toml"
grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=false']" "$evidence/containerd-config-initial.toml"
switch_restore_needed=true
cat >"$evidence/prior-fixed-evidence.txt" <<'PRIOR'
s33b=inv-384315g7di,audit=inv-a843e8g0wv
s33c=inv-6846wbgtiv,audit=inv-6847cm06pi
s33d_script_sha256=79aba88c3a46e4f7f6d0d3834f44ddf6152bc779a9a4503bdc4d8f055b04658a,e2e=inv-b849phgapi
s33d_audit_sha256=4baeaf7699a1f721d88ad74d77d21c44072d053e712a8f8ed787a87b9dbb3bd6,audit=inv-3849tjgnmx
s33e=inv-084cdrgc1k,audit=inv-384cpa0n8v
PRIOR

write_off_manifest
"${kube[@]}" create -f "$evidence/off.yaml" >"$evidence/create-off.txt"
for pod in cubesandbox-s33f-runc-strict cubesandbox-s33f-cube-off-strict cubesandbox-s33f-runc-merge cubesandbox-s33f-cube-off-merge; do
  "${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=360s >"$evidence/wait-$pod.txt"
done
wait_failure cubesandbox-s33f-cube-off-privileged StartError 'CUBE_ALLOW_PRIVILEGED=true is required'
for pod in cubesandbox-s33f-runc-strict cubesandbox-s33f-cube-off-strict cubesandbox-s33f-runc-merge cubesandbox-s33f-cube-off-merge cubesandbox-s33f-cube-off-privileged; do remember_pod_uid "$pod"; done
for pod in cubesandbox-s33f-runc-strict cubesandbox-s33f-cube-off-strict cubesandbox-s33f-runc-merge cubesandbox-s33f-cube-off-merge; do capture_pod_json off "$pod"; done
"${cri[@]}" pods -o json >"$evidence/cri-pods-off.json"
for pod in cubesandbox-s33f-cube-off-strict cubesandbox-s33f-cube-off-merge cubesandbox-s33f-cube-off-privileged; do record_cube_sandbox_optional off "$pod"; done
capture_shim_env_for_pods off false cubesandbox-s33f-cube-off-strict cubesandbox-s33f-cube-off-merge
capture_strict off cubesandbox-s33f-runc-strict
capture_strict off cubesandbox-s33f-cube-off-strict
capture_merge off cubesandbox-s33f-runc-merge
capture_merge off cubesandbox-s33f-cube-off-merge
capture_exec off cubesandbox-s33f-runc-strict
capture_exec off cubesandbox-s33f-cube-off-strict
for name in classic-init sidecar app; do compare_container_semantics off cubesandbox-s33f-runc-strict "$name" runc off cubesandbox-s33f-cube-off-strict "$name" cube; done
for name in identity boundary; do compare_container_semantics off cubesandbox-s33f-runc-merge "$name" runc off cubesandbox-s33f-cube-off-merge "$name" cube; done
cmp "$evidence/exec-semantic-off-cubesandbox-s33f-runc-strict-app.json" "$evidence/exec-semantic-off-cubesandbox-s33f-cube-off-strict-app.json"
capture_failed_workload cubesandbox-s33f-cube-off-privileged start-error
delete_owned_pods
wait_pods_absent
assert_baseline after-off

set_switch true
write_on_manifest
"${kube[@]}" create -f "$evidence/on.yaml" >"$evidence/create-on.txt"
for pod in cubesandbox-s33f-cube-on-strict cubesandbox-s33f-cube-mixed cubesandbox-s33f-runc-invalid-cap; do
  "${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=360s >"$evidence/wait-$pod.txt"
done
wait_failure cubesandbox-s33f-cube-host-dev StartError 'Host /dev mount source'
wait_failure cubesandbox-s33f-cube-invalid-cap StartError 'CAP_NOT_A_CAPABILITY'
wait_failure cubesandbox-s33f-runc-nonroot-zero CreateContainerConfigError 'non-root'
wait_failure cubesandbox-s33f-cube-nonroot-zero CreateContainerConfigError 'non-root'
for pod in cubesandbox-s33f-cube-on-strict cubesandbox-s33f-cube-mixed cubesandbox-s33f-cube-host-dev cubesandbox-s33f-runc-invalid-cap cubesandbox-s33f-cube-invalid-cap cubesandbox-s33f-runc-nonroot-zero cubesandbox-s33f-cube-nonroot-zero; do remember_pod_uid "$pod"; done
for pod in cubesandbox-s33f-cube-on-strict cubesandbox-s33f-cube-mixed cubesandbox-s33f-runc-invalid-cap; do capture_pod_json on "$pod"; done
"${cri[@]}" pods -o json >"$evidence/cri-pods-on.json"
for pod in cubesandbox-s33f-cube-on-strict cubesandbox-s33f-cube-mixed cubesandbox-s33f-cube-host-dev cubesandbox-s33f-cube-invalid-cap cubesandbox-s33f-cube-nonroot-zero; do record_cube_sandbox_optional on "$pod"; done
capture_shim_env_for_pods on true cubesandbox-s33f-cube-on-strict cubesandbox-s33f-cube-mixed
capture_strict on cubesandbox-s33f-cube-on-strict
capture_exec on cubesandbox-s33f-cube-on-strict
for name in classic-init sidecar app; do compare_container_semantics off cubesandbox-s33f-cube-off-strict "$name" cube on cubesandbox-s33f-cube-on-strict "$name" cube; done
cmp "$evidence/exec-semantic-off-cubesandbox-s33f-cube-off-strict-app.json" "$evidence/exec-semantic-on-cubesandbox-s33f-cube-on-strict-app.json"

capture_container on cubesandbox-s33f-cube-mixed ordinary
capture_container on cubesandbox-s33f-cube-mixed privileged
assert_ordinary_semantics on cubesandbox-s33f-cube-mixed ordinary 1000 3000 2000,3000,4000 '["CAP_NET_RAW"]' false true true
assert_guest_caps on cubesandbox-s33f-cube-mixed ordinary 0000000000002000 0000000000000000 0000000000000000
jq -e '.rootMode=="rw" and .mountResult=="denied" and .devKvm=="absent"' "$evidence/guest-semantic-on-cubesandbox-s33f-cube-mixed-ordinary.json" >/dev/null
compare_container_semantics off cubesandbox-s33f-cube-off-strict app cube on cubesandbox-s33f-cube-mixed ordinary cube
priv_input=$evidence/input-on-cubesandbox-s33f-cube-mixed-privileged-cri.json
priv_guest=$evidence/guest-semantic-on-cubesandbox-s33f-cube-mixed-privileged.json
jq -e '
  .processUser.uid==0 and .processUser.gid==0 and
  (.capabilities.bounding|length)==41 and (.capabilities.effective|length)==41 and (.capabilities.permitted|length)==41 and
  (.capabilities.inheritable|length)==0 and (.capabilities.ambient|length)==0 and
  .noNewPrivileges==false and .rootReadonly==false and .seccomp==null and
  (.devices|length)==0 and ([.mounts[]|select(.destination=="/host-dev")]|length)==0 and
  ([.deviceRules[]|select(.allow==true and .type==null and .major==null and .minor==null and .access=="rwm")]|length)==1 and (.deviceRules|length)==1
' "$priv_input" >/dev/null
jq -e '.uid=="0" and .gid=="0" and .capabilities.permitted=="000001ffffffffff" and .capabilities.effective=="000001ffffffffff" and .capabilities.bounding=="000001ffffffffff" and .capabilities.inheritable=="0000000000000000" and .capabilities.ambient=="0000000000000000" and .noNewPrivileges=="0" and .seccompMode=="0" and .rootMode=="rw" and .rootWrite=="ok" and .mountResult=="allowed" and .devKvm=="absent" and .cgroupMode=="v2" and .deviceList=="missing"' "$priv_guest" >/dev/null
mixed_uid=$(pod_uid cubesandbox-s33f-cube-mixed)
mixed_ordinary_sandbox=$(jq -er '.info.sandboxID' "$evidence/cri-on-cubesandbox-s33f-cube-mixed-ordinary.json")
mixed_privileged_sandbox=$(jq -er '.info.sandboxID' "$evidence/cri-on-cubesandbox-s33f-cube-mixed-privileged.json")
test "$mixed_ordinary_sandbox" = "$mixed_privileged_sandbox"
mixed_pod_sandbox=$(sandbox_for_uid_optional "$mixed_uid")
test "$mixed_ordinary_sandbox" = "$mixed_pod_sandbox"

capture_container on cubesandbox-s33f-runc-invalid-cap app
capture_failed_workload cubesandbox-s33f-cube-host-dev start-error
capture_failed_workload cubesandbox-s33f-cube-invalid-cap start-error
capture_failed_workload cubesandbox-s33f-runc-nonroot-zero no-record
capture_failed_workload cubesandbox-s33f-cube-nonroot-zero no-record
jq -e '.spec.runtimeClassName=="cube" and .spec.containers[0].securityContext.privileged==true and any(.spec.volumes[]?; .name=="host-dev" and .hostPath.path=="/dev") and any(.spec.containers[0].volumeMounts[]?; .name=="host-dev" and .mountPath=="/host-dev")' "$evidence/pod-cubesandbox-s33f-cube-host-dev.json" >/dev/null

delete_owned_pods
wait_pods_absent
set_switch false
switch_restore_needed=false
assert_baseline after-on
wait_pod_dirs_absent
leases_after=$(lease_records)
printf '%s\n' "$leases_after" >"$evidence/lease-count-after.txt"
snapshot_leases after
sandbox_count=$(awk -F '\t' 'NR>1 {n++} END {print n+0}' "$evidence/cube-sandboxes.tsv")
test "$((leases_after - leases_before))" -eq "$sandbox_count"
while IFS=$'\t' read -r phase pod sandbox; do
  test "$phase" != phase || continue
  test "$(inactive_lease_count_for_sandbox "$sandbox")" -eq 1
done <"$evidence/cube-sandboxes.tsv"
test "$(active_leases)" -eq 0

cat >"$evidence/support-matrix.tsv" <<'MATRIX'
feature	status	boundary_or_evidence
numeric UID/GID + Strict supplemental groups + fsGroup	VERIFIED_THIS_RUN	runc/Cube paired multi-container OCI and Guest semantics
supplementalGroupsPolicy Merge + image implicit group	VERIFIED_THIS_RUN	runc/Cube paired identity container includes gid 50000
classic init + restartable sidecar + app in one Cube VM	VERIFIED_THIS_RUN	one sandbox; per-container identity/security semantics
workload OCI runtime-specific mounts	VERIFIED_THIS_RUN	common normalized destinations/options match; runc workload binds hostname/resolv/shm, Cube workload omits hostname/resolv and uses tmpfs shm
capability drop ALL + NET_BIND_SERVICE + NET_RAW	VERIFIED_THIS_RUN	runc/Cube paired OCI five-set; non-root Guest bounding retains add while permitted/effective clear
CAP_CHECKPOINT_RESTORE (cap 40)	VERIFIED_THIS_RUN	runc/Cube paired uid-0 boundary keeps permitted/effective/bounding
readonly and writable rootfs	VERIFIED_THIS_RUN	RO mount plus root RW write by uid 0 boundary
allowPrivilegeEscalation=false + RuntimeDefault	VERIFIED_THIS_RUN	NNP=1, Seccomp=2; syscall causality remains prior fixed S3.3d evidence
allowPrivilegeEscalation=true + Unconfined	VERIFIED_THIS_RUN	NNP=0, Seccomp=0 in ordinary sidecar/boundary
non-TTY exec	VERIFIED_THIS_RUN	identity/groups/caps/NNP/seccomp preserved
privileged node+Pod dual gate	VERIFIED_THIS_RUN	off StartError; on Guest-only elevation
mixed privileged + ordinary containers	VERIFIED_THIS_RUN	one Cube VM; per-container config not crossed; no claim of sibling isolation
automatic Host device enumeration	NOT_SUPPORTED_POC	omitted by containerd policy: OCI linux.devices empty; Guest /dev/kvm absent
explicit Host /dev bind	REJECTED	Cube layer: StartError before running workload; non-/dev HostPath not generalized
runAsNonRoot=true + uid 0	REJECTED	kubelet layer: CreateContainerConfigError for runc and Cube; no OCI claim
invalid capability name	REJECTED	Cube layer: StartError; runc behavior captured this run
Unconfined/RuntimeDefault syscall causal pair	SUPPORTED_BY_PRIOR_FIXED_EVIDENCE	S3.3d inv-b849phgapi and inv-3849tjgnmx
TTY/stdin	NOT_SUPPORTED_POC	explicit first-version exception
host namespaces, explicit Host device passthrough, GPU	NOT_SUPPORTED_POC	not enabled by privileged; explicit /dev bind is separately rejected
AppArmor, SELinux, procMount, unsafe sysctls	DEFERRED	not verified by S3.3 scope
Guest cgroup v2 devices.list observation	DEFERRED	unobservable on this Guest; Agent wildcard conversion has separate 2/2 evidence
MATRIX
printf 'S33F_COMBINED_OK evidence=%s sandboxes_observed=%s lease_delta=%s switch=false cgroup_v2_device_rule=unobservable support_matrix=%s\n' \
  "$evidence" "$sandbox_count" "$((leases_after - leases_before))" "$evidence/support-matrix.tsv" >"$evidence/summary.txt"
cat "$evidence/summary.txt"
