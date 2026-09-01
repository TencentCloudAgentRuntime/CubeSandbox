#!/usr/bin/env bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
root=/data/cubelet/s3.4-evidence
latest=$root/S34A_LATEST
expected_original_containerd=15e00263fed22c55e75ae2b0fb89c6a0862741d5ee82728a2d4ecb99a26fbf2d
live_containerd=/usr/local/bin/containerd
trace_root=/run/cubesandbox-s34-trace
node=vm-200-2-ubuntu
pods=(
  s34a-runc-besteffort s34a-runc-burstable s34a-runc-guaranteed
  s34a-cube-besteffort s34a-cube-burstable s34a-cube-guaranteed
)

assert_trace_window_values() {
  local id=$1 kind=$2 start_file=$3 end_file=$4 shares=$5 quota=$6 period=$7 memory=$8
  local start_ns end_ns metadata captured_ns relative decoded total=0 matched=0
  start_ns=$(date -u -d "$(cat "$start_file")" +%s%N)
  end_ns=$(date -u -d "$(cat "$end_file")" +%s%N)
  while IFS= read -r metadata; do
    captured_ns=$(date -u -d "$(jq -er '.capturedAt' "$metadata")" +%s%N)
    if test "$captured_ns" -lt "$start_ns" -o "$captured_ns" -gt "$end_ns"; then continue; fi
    total=$((total + 1))
    relative=${metadata#"$evidence/scoped-update-trace/"}
    decoded=$evidence/scoped-update-decoded/${relative%.json}
    if test "$kind" = cri-update; then
      if jq -e --arg id "$id" --arg shares "$shares" --arg quota "$quota" --arg period "$period" --arg memory "$memory" '
        def wanted($actual; $want): $want == "-" or (($actual // 0 | tostring) == $want);
        .container_id == $id and
        wanted(.linux.cpu_shares; $shares) and wanted(.linux.cpu_quota; $quota) and
        wanted(.linux.cpu_period; $period) and wanted(.linux.memory_limit_in_bytes; $memory)
      ' "$decoded.decoded.json" >/dev/null; then matched=$((matched + 1)); fi
    else
      if jq -e --arg shares "$shares" --arg quota "$quota" --arg period "$period" --arg memory "$memory" '
        def wanted($actual; $want): $want == "-" or (($actual // 0 | tostring) == $want);
        wanted(.cpu.shares; $shares) and wanted(.cpu.quota; $quota) and
        wanted(.cpu.period; $period) and wanted(.memory.limit; $memory)
      ' "$decoded.resources.decoded.json" >/dev/null; then matched=$((matched + 1)); fi
    fi
  done < <(find "$evidence/scoped-update-trace/$id" -type f -name "*-$kind.json" | LC_ALL=C sort)
  test "$total" -ge 1
  test "$matched" -ge 1
}

audit_container_metadata_capture() {
  local capture=$1 metadata_key expected_prefix recorded_key recorded_prefix directory
  directory=$capture/raw-containerd
  metadata_key=$(jq -er '
    [.Extensions | to_entries[] | select(.value.type_url == "github.com/containerd/cri/pkg/store/container/Metadata") | .key] |
    if length == 1 then .[0] else error("expected exactly one CRI container metadata extension") end
  ' "$directory/container-info.json")
  case "$metadata_key" in
    io.cri-containerd.container.metadata) expected_prefix=extension-io-cri-containerd-container-metadata ;;
    io.containerd.cri.container.metadata) expected_prefix=extension-io-containerd-cri-container-metadata ;;
    *) return 1 ;;
  esac
  recorded_key=$(cat "$capture/container-metadata-key.txt")
  recorded_prefix=$(cat "$capture/container-metadata-prefix.txt")
  test "$recorded_key" = "$metadata_key"
  test "$recorded_prefix" = "$expected_prefix"
  test "$(jq -r --arg key "$metadata_key" '.Extensions[$key].type_url' "$directory/container-info.json")" = 'github.com/containerd/cri/pkg/store/container/Metadata'
  test -s "$directory/$expected_prefix.value"
  test "$(cat "$directory/$expected_prefix.type-url.txt")" = 'github.com/containerd/cri/pkg/store/container/Metadata'
}

runtime_name_for_case() {
  case "$1" in
    runc) printf '%s\n' io.containerd.runc.v2 ;;
    cube) printf '%s\n' io.containerd.cube.rs ;;
    *) return 1 ;;
  esac
}

assert_pod_runtime_class() {
  local runtime=$1 pod_capture=$2
  case "$runtime" in
    runc) jq -e '(.spec | has("runtimeClassName")) | not' "$pod_capture" >/dev/null ;;
    cube) jq -e '.spec.runtimeClassName == "cube"' "$pod_capture" >/dev/null ;;
    *) return 1 ;;
  esac
}

assert_sandbox_runtime_identity() {
  local runtime=$1 capture=$2 expected
  expected=$(runtime_name_for_case "$runtime") || return 1
  jq -e --arg expected "$expected" '.Runtime.Name == $expected' "$capture/raw-containerd/sandbox-info.json" >/dev/null
}

assert_container_runtime_identity() {
  local runtime=$1 capture=$2 expected
  expected=$(runtime_name_for_case "$runtime") || return 1
  jq -e --arg expected "$expected" '.Runtime.Name == $expected' "$capture/raw-containerd/container-info.json" >/dev/null
}

assert_lowlevel_runtime_identity() {
  local runtime=$1 directory=$2 expected
  expected=$(runtime_name_for_case "$runtime") || return 1
  jq -e --arg expected "$expected" '.Runtime.Name == $expected' "$directory/container-info.json" >/dev/null
}

assert_cgroup_capture() {
  local capture=$1 name layout process_dir resource_dir process_relative resource_relative process_membership resource_membership value
  grep -Fxq 'cgroup_path_resolution=mount-root-relative' "$capture" || return 1
  grep -Fxq 'cgroup_mount_count=1' "$capture" || return 1
  grep -Eq '^cgroup_mount_root=/' "$capture" || return 1
  grep -Eq '^cgroup_mount_point=/' "$capture" || return 1
  grep -Eq '^cgroup_mount_relative=/' "$capture" || return 1
  layout=$(capture_required_value "$capture" cgroup_layout) || return 1
  process_dir=$(capture_required_value "$capture" cgroup_process_dir) || return 1
  resource_dir=$(capture_required_value "$capture" cgroup_resource_dir) || return 1
  process_relative=$(capture_required_value "$capture" cgroup_process_relative) || return 1
  resource_relative=$(capture_required_value "$capture" cgroup_resource_relative) || return 1
  process_membership=$(capture_required_value "$capture" cgroup_process_pid_membership) || return 1
  resource_membership=$(capture_required_value "$capture" cgroup_resource_pid_membership) || return 1
  test "$process_membership" = self || return 1
  case "$layout" in
    process-leaf)
      test "$process_dir" = "$resource_dir" || return 1
      test "$process_relative" = "$resource_relative" || return 1
      test "$resource_membership" = self || return 1
      ;;
    agent-parent-with-runtime-leaf)
      test "$process_dir" = "$resource_dir/runtime" || return 1
      if test "$resource_relative" = /; then
        test "$process_relative" = /runtime || return 1
      else
        test "$process_relative" = "$resource_relative/runtime" || return 1
      fi
      test "$resource_membership" = delegated-child || return 1
      ;;
    *) return 1 ;;
  esac
  for name in cgroup.controllers cgroup.subtree_control cpu.max cpu.weight cpuset.cpus cpuset.cpus.effective cpuset.mems cpuset.mems.effective memory.max memory.low memory.swap.max memory.oom.group pids.max; do
    value=$(capture_required_value "$capture" "$name") || return 1
    test "$value" != ABSENT || return 1
    value=$(capture_required_value "$capture" "process.$name") || return 1
    test "$value" != ABSENT || return 1
  done
  return 0
}

assert_runtime_cgroup_capture() {
  local runtime=$1 capture=$2
  assert_cgroup_capture "$capture" || return 1
  case "$runtime" in
    runc) grep -Fxq 'cgroup_layout=process-leaf' "$capture" || return 1 ;;
    cube) grep -Fxq 'cgroup_layout=agent-parent-with-runtime-leaf' "$capture" || return 1 ;;
    *) return 1 ;;
  esac
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
    assert_runtime_cgroup_capture "$runtime" "$capture"
    return
  fi
  test "$(wc -l <"$capture")" -eq 5 || return 1
  grep -Eq '^uname=.+' "$capture" || return 1
  grep -Eq '^proc_cgroup=0::/.+' "$capture" || return 1
  grep -Eq '^self_pid=[1-9][0-9]*$' "$capture" || return 1
  grep -Fxq 'cgroup_path_resolution=cgroup2-mount-absent' "$capture" || return 1
  grep -Fxq 'cgroup_mount_count=0' "$capture" || return 1
  for name in cgroup_dir cgroup_mount_root cgroup_mount_point cgroup_mount_relative cgroup_layout cgroup_process_dir cgroup_process_relative cgroup_process_pid_membership cgroup_resource_dir cgroup_resource_relative cgroup_resource_pid_membership cgroup2_mountinfo cgroup.controllers cgroup.subtree_control cpu.max cpu.weight cpuset.cpus cpuset.cpus.effective cpuset.mems cpuset.mems.effective memory.max memory.low memory.swap.max memory.oom.group pids.max; do
    if grep -q "^$name=" "$capture"; then return 1; fi
  done
  if grep -q '^process\.' "$capture"; then return 1; fi
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

test -f "$latest"
evidence=$(cat "$latest")
case "$evidence" in "$root"/s34a-*) ;; *) exit 1 ;; esac
test -d "$evidence"
grep -Fxq "result=clean original_containerd=$expected_original_containerd trace_root=absent owned_pods=absent lowlevel_containers=absent services=active" "$evidence/preflight.txt"
grep -Fxq 'trace_health=runc+cube raw_create=metadata+oci raw_update=cri+task lowlevel_started=17 expected_create_reject=1 invalid_unified=2 cleanup=exact' "$evidence/summary.txt"
grep -Eq '^probe_rc=0 cleanup_rc=0 original_containerd=[0-9a-f]{64} live_containerd=[0-9a-f]{64}$' "$evidence/final-status.txt"
test "$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^original_containerd=/) {sub(/^original_containerd=/,"",$i); print $i}}' "$evidence/final-status.txt")" = "$expected_original_containerd"
test "$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^live_containerd=/) {sub(/^live_containerd=/,"",$i); print $i}}' "$evidence/final-status.txt")" = "$expected_original_containerd"
test "$(sha256sum "$live_containerd" | awk '{print $1}')" = "$expected_original_containerd"
test ! -e "$trace_root"
test ! -L "$trace_root"
test -s "$evidence/owned-pod-uids.txt"
test "$(wc -l <"$evidence/owned-pod-uids.txt")" -eq "$(LC_ALL=C sort -u "$evidence/owned-pod-uids.txt" | wc -l)"

while IFS= read -r manifest; do
  (cd "$(dirname "$manifest")" && sha256sum -c "$(basename "$manifest")")
done < <(find "$evidence" -type f -name '*.sha256' | LC_ALL=C sort)

for checkpoint in pre-restore final cleanup-final; do
  grep -Eq '^result=matched attempts=[1-9][0-9]* capture_errors=[0-9]+$' "$evidence/baseline-wait-$checkpoint.txt"
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime adapter shared reaper cleanup-markers shared-mounts active-leases kubelet-pod-dirs owned-cgroups; do
    cmp "$evidence/$kind-before.txt" "$evidence/$kind-$checkpoint.txt"
  done
  test "$(sed -n '1p' "$evidence/services-$checkpoint.txt")" = active
  test "$(sed -n '2p' "$evidence/services-$checkpoint.txt")" = active
  test "$(sed -n '3p' "$evidence/services-$checkpoint.txt")" = active
  jq -e '[.conditions[] | select(.type == "Ready" and .status == "True")] | length == 1' "$evidence/node-health-$checkpoint.json" >/dev/null
  jq -e '[.conditions[] | select((.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") and .status == "False")] | length == 3' "$evidence/node-health-$checkpoint.json" >/dev/null
done

test -s "$evidence/baseline-before/host-kernel.txt"
test -s "$evidence/baseline-before/kubernetes-version.json"
test -s "$evidence/baseline-before/kubelet-resource-config.json"
test -s "$evidence/baseline-before/runtimeclasses.json"
test -s "$evidence/baseline-before/node.json"
test -s "$evidence/baseline-before/host-cgroup2-mount.json"
test -s "$evidence/baseline-before/host-cgroup-delegation.txt"
test -s "$evidence/baseline-before/host-swaps.txt"
test -s "$evidence/baseline-before/host-meminfo.txt"
grep -Fxq 'cri_api_module=k8s.io/cri-api@v0.36.4' "$evidence/baseline-before/helper-schema.txt"
grep -Fxq 'cri_update=runtime.v1.UpdateContainerResourcesRequest' "$evidence/baseline-before/helper-schema.txt"
jq -e '.kubeletconfig.cgroupDriver == "systemd"' "$evidence/baseline-before/kubelet-resource-config.json" >/dev/null
jq -e '.items[] | select(.metadata.name == "cube") | has("overhead") | not' "$evidence/baseline-before/runtimeclasses.json" >/dev/null
jq -e '.status.capacity["hugepages-2Mi"] == "0" and .status.allocatable["hugepages-2Mi"] == "0"' "$evidence/baseline-before/node.json" >/dev/null

for pod in "${pods[@]}"; do
  runtime=$(cut -d- -f2 <<<"$pod")
  qos=$(cut -d- -f3 <<<"$pod")
  case "$qos" in besteffort) expected_qos=BestEffort;; burstable) expected_qos=Burstable;; guaranteed) expected_qos=Guaranteed;; esac
  jq -e --arg want "$expected_qos" '.status.qosClass == $want' "$evidence/kubernetes/$pod/ready-pod.json" >/dev/null
  assert_pod_runtime_class "$runtime" "$evidence/kubernetes/$pod/classic-running-pod.json"
  assert_pod_runtime_class "$runtime" "$evidence/kubernetes/$pod/ready-pod.json"
  assert_sandbox_runtime_identity "$runtime" "$evidence/kubernetes/$pod/sandbox"
  jq -e '.status.initContainerStatuses[] | select(.name == "classic" and .state.terminated.exitCode == 0)' "$evidence/kubernetes/$pod/ready-pod.json" >/dev/null
  jq -e '.status.initContainerStatuses[] | select(.name == "sidecar" and .state.running != null and .restartCount == 0)' "$evidence/kubernetes/$pod/ready-pod.json" >/dev/null
  jq -e '.status.containerStatuses[] | select(.name == "app" and .state.running != null and .restartCount == 0)' "$evidence/kubernetes/$pod/ready-pod.json" >/dev/null
  assert_runtime_cgroup_capture "$runtime" "$evidence/kubernetes/$pod/classic-cgroup.txt"
  assert_runtime_cgroup_capture "$runtime" "$evidence/kubernetes/$pod/sidecar-cgroup-before.txt"
  assert_runtime_cgroup_capture "$runtime" "$evidence/kubernetes/$pod/app-cgroup-before.txt"
  for role in classic sidecar app; do
    assert_container_runtime_identity "$runtime" "$evidence/kubernetes/$pod/$role-create"
  done
  test "$(find "$evidence/kubernetes/$pod/host-topology-before" -type f -name '*.txt' -size +0c -printf '.\n' | awk 'NF {n++} END {print n+0}')" -ge 1
  test -s "$evidence/kubernetes/$pod/sandbox/raw-containerd/extension-metadata.value"
  test "$(cat "$evidence/kubernetes/$pod/sandbox/raw-containerd/extension-metadata.type-url.txt")" = 'github.com/containerd/cri/pkg/store/sandbox/Metadata'
  test -s "$evidence/kubernetes/$pod/sandbox/raw-containerd/sandbox-spec.any.pb"
  test -s "$evidence/kubernetes/$pod/sandbox/raw-containerd/sandbox-spec.value"
  test -s "$evidence/kubernetes/$pod/sandbox/raw-containerd/sandbox-spec.sha256"
  test "$(cat "$evidence/kubernetes/$pod/sandbox/raw-containerd/sandbox-spec.type-url.txt")" = 'types.containerd.io/opencontainers/runtime-spec/1/Spec'
  sid=$(cat "$evidence/kubernetes/$pod/sandbox/sandbox-id.txt")
  bundle_manifest=$evidence/kubernetes/$pod/sandbox/raw-containerd/bundle-config.sha256
  test -s "$bundle_manifest"
  if test "$runtime" = cube; then
    grep -Fxq "sandbox_id=$sid" "$evidence/kubernetes/$pod/sandbox/raw-containerd/bundle-config-absence.txt"
    grep -Fxq 'live_bundle_config=absent' "$evidence/kubernetes/$pod/sandbox/raw-containerd/bundle-config-absence.txt"
    grep -Fxq 'search_root=/run/containerd' "$evidence/kubernetes/$pod/sandbox/raw-containerd/bundle-config-absence.txt"
    test ! -s "$evidence/kubernetes/$pod/sandbox/raw-containerd/bundle-config-paths.tsv"
    test "$(find "$evidence/kubernetes/$pod/sandbox/raw-containerd" -maxdepth 1 -type f -name 'bundle-config-[0-9][0-9].json' -printf '.\n' | wc -l)" -eq 0
    test "$(awk '{print $2}' "$bundle_manifest" | LC_ALL=C sort)" = $'bundle-config-absence.txt\nbundle-config-paths.tsv'
  else
    test ! -e "$evidence/kubernetes/$pod/sandbox/raw-containerd/bundle-config-absence.txt"
    test -s "$evidence/kubernetes/$pod/sandbox/raw-containerd/bundle-config-00.json"
    test -s "$evidence/kubernetes/$pod/sandbox/raw-containerd/bundle-config-paths.tsv"
    expected_bundle_manifest=$(find "$evidence/kubernetes/$pod/sandbox/raw-containerd" -maxdepth 1 -type f \( -name 'bundle-config-[0-9][0-9].json' -o -name 'bundle-config-paths.tsv' \) -printf '%f\n' | LC_ALL=C sort)
    test -n "$expected_bundle_manifest"
    test "$(awk '{print $2}' "$bundle_manifest" | LC_ALL=C sort)" = "$expected_bundle_manifest"
  fi
  for role in classic-create sidecar-create app-create; do
    directory=$evidence/kubernetes/$pod/$role/raw-containerd
    audit_container_metadata_capture "$evidence/kubernetes/$pod/$role"
    test -s "$directory/container-spec.any.pb"
    test -s "$directory/container-spec.value"
    test "$(cat "$directory/container-spec.type-url.txt")" = 'types.containerd.io/opencontainers/runtime-spec/1/Spec'
    test -s "$directory/bundle-config-00.json"
  done
  test -s "$evidence/kubernetes/$pod/crictl-statsp.json"
  test -s "$evidence/kubernetes/$pod/kubelet-pod-dir.stat.txt"
  test -s "$evidence/kubernetes/$pod/kubelet-pod-dir.du.txt"
  test -s "$evidence/kubernetes/$pod/emptydir.stat.txt"
  test -s "$evidence/kubernetes/$pod/emptydir.du.txt"
  grep -Fq 'size=1048576' "$evidence/kubernetes/$pod/emptydir-file.stat.txt"
  grep -Fq 'size=1048576' "$evidence/kubernetes/$pod/app-writable-layer.stat.txt"
  test -s "$evidence/kubernetes/$pod/app-crictl-stats.json"
  uid=$(jq -er '.metadata.uid' "$evidence/kubernetes/$pod/ready-pod.json")
  grep -Fxq "$uid" "$evidence/owned-pod-uids.txt"
  for role in classic sidecar app; do
	metadata_prefix=$(cat "$evidence/kubernetes/$pod/$role-create/container-metadata-prefix.txt")
    log_path=$(cat "$evidence/kubernetes/$pod/$role-node-log.path.txt")
	test "$log_path" = "$(jq -er '.Metadata.LogPath' "$evidence/kubernetes/$pod/$role-create/raw-containerd/$metadata_prefix.decoded.json")"
    case "$log_path" in /var/log/pods/default_"$pod"_"$uid"/"$role"/*.log) ;; *) false ;; esac
    test -s "$evidence/kubernetes/$pod/$role-node-log.stat.txt"
    test -f "$evidence/kubernetes/$pod/$role-node-log.content.txt"
    test -s "$evidence/kubernetes/$pod/$role-node-log.sha256.txt"
    test "$(awk '{print $1}' "$evidence/kubernetes/$pod/$role-node-log.sha256.txt")" = "$(sha256sum "$evidence/kubernetes/$pod/$role-node-log.content.txt" | awk '{print $1}')"
    test -s "$evidence/kubernetes/$pod/$role-container-log-symlinks.txt"
  done
  grep -Fq 's34a-ephemeral-log' "$evidence/kubernetes/$pod/app-node-log.content.txt"
  if test "$runtime" = cube; then
    grep -Eq '^thread=[0-9]+ comm=' "$evidence/kubernetes/$pod/host-topology-before/shim.txt"
    test -s "$evidence/kubernetes/$pod/host-topology-before/process-tree.txt"
  else
    test -s "$evidence/kubernetes/$pod/host-topology-before/app.txt"
    test -s "$evidence/kubernetes/$pod/host-topology-before/sidecar.txt"
  fi
done

for pod in s34a-runc-guaranteed s34a-cube-guaranteed; do
  for role in sidecar-update app-update; do
    audit_container_metadata_capture "$evidence/kubernetes/$pod/$role"
  done
done

for pod in s34a-runc-besteffort s34a-cube-besteffort; do
  grep -Eq '^id=[0-9a-f]+ cri=[0-9]+->[0-9]+ task=[0-9]+->[0-9]+$' "$evidence/trace-health-before-resize-$pod.txt"
  test -s "$evidence/trace-health-before-resize-$pod.start"
  test -s "$evidence/trace-health-before-resize-$pod.end"
  id=$(cat "$evidence/kubernetes/$pod/app-create/container-id.txt")
  assert_trace_window_values "$id" cri-update "$evidence/trace-health-before-resize-$pod.start" "$evidence/trace-health-before-resize-$pod.end" 2 - - -
  assert_trace_window_values "$id" task-update "$evidence/trace-health-before-resize-$pod.start" "$evidence/trace-health-before-resize-$pod.end" 2 - - -
done

for pod in s34a-runc-guaranteed s34a-cube-guaranteed; do
  runtime=$(cut -d- -f2 <<<"$pod")
  grep -Fxq 'exit=0 spec_cpu=250m status_allocated_cpu=250m status_resources_cpu=250m classic_cri_trace=0->0 classic_task_trace=0->0 classification=api-spec-and-kubelet-accounting-only-terminated-task' "$evidence/kubernetes/$pod/classic-resize.result.txt"
  grep -Fxq "pod/$pod patched" "$evidence/kubernetes/$pod/classic-resize.response.txt"
  classic_id=$(cat "$evidence/kubernetes/$pod/classic-create/container-id.txt")
  jq -e --arg classic "containerd://$classic_id" '
    (.spec.initContainers[] | select(.name == "classic") |
      .resources.requests.cpu == "200m" and .resources.limits.cpu == "200m" and
      .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
      .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi") and
    (.status.initContainerStatuses[] | select(.name == "classic") |
      .containerID == $classic and .state.terminated.exitCode == 0 and .restartCount == 0 and
      .allocatedResources.cpu == "200m" and .allocatedResources.memory == "128Mi" and
      .allocatedResources["ephemeral-storage"] == "2Mi" and
      .resources.requests.cpu == "200m" and .resources.limits.cpu == "200m" and
      .resources.requests.memory == "128Mi" and .resources.limits.memory == "128Mi" and
      .resources.requests["ephemeral-storage"] == "2Mi" and .resources.limits["ephemeral-storage"] == "8Mi")
  ' "$evidence/kubernetes/$pod/ready-pod.json" >/dev/null
  jq -e --arg pod "$pod" --arg classic "containerd://$classic_id" '
    .metadata.name == $pod and
    (.spec.initContainers[] | select(.name == "classic") | .resources.requests.cpu == "250m" and .resources.limits.cpu == "250m") and
    (.status.initContainerStatuses[] | select(.name == "classic") |
      .containerID == $classic and .state.terminated.exitCode == 0 and .restartCount == 0)
  ' "$evidence/kubernetes/$pod/classic-resize.first-status.json" >/dev/null
  jq -e --arg classic "containerd://$classic_id" '
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
  test -s "$evidence/kubernetes/$pod/classic-resize.start"
  test -s "$evidence/kubernetes/$pod/classic-resize.end"
  audit_container_metadata_capture "$evidence/kubernetes/$pod/classic-post-accounting"
  audit_container_metadata_capture "$evidence/kubernetes/$pod/classic-post-pod-resize"
  assert_container_runtime_identity "$runtime" "$evidence/kubernetes/$pod/classic-post-accounting"
  assert_container_runtime_identity "$runtime" "$evidence/kubernetes/$pod/classic-post-pod-resize"
  grep -Fxq "$classic_id" "$evidence/kubernetes/$pod/classic-post-accounting/container-id.txt"
  grep -Fxq "$classic_id" "$evidence/kubernetes/$pod/classic-post-pod-resize/container-id.txt"
  test "$(cat "$evidence/kubernetes/$pod/classic-post-accounting/raw-containerd/container-spec.type-url.txt")" = 'types.containerd.io/opencontainers/runtime-spec/1/Spec'
  test "$(cat "$evidence/kubernetes/$pod/classic-post-pod-resize/raw-containerd/container-spec.type-url.txt")" = 'types.containerd.io/opencontainers/runtime-spec/1/Spec'
  test ! -e "$evidence/kubernetes/$pod/classic-post-accounting/raw-containerd/bundle-config.sha256"
  test ! -e "$evidence/kubernetes/$pod/classic-post-pod-resize/raw-containerd/bundle-config.sha256"
  cmp "$evidence/kubernetes/$pod/classic-create/raw-containerd/container-spec.value" \
    "$evidence/kubernetes/$pod/classic-post-accounting/raw-containerd/container-spec.value"
  cmp "$evidence/kubernetes/$pod/classic-create/raw-containerd/container-spec.value" \
    "$evidence/kubernetes/$pod/classic-post-pod-resize/raw-containerd/container-spec.value"
  for trace_kind in cri-update task-update; do
    if test -d "$evidence/scoped-update-trace/$classic_id"; then
      test "$(find "$evidence/scoped-update-trace/$classic_id" -type f -name "*-$trace_kind.pb" -printf '.\n' | wc -l)" -eq 0
    fi
  done
  jq -e --arg classic "containerd://$classic_id" '
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
  ' "$evidence/kubernetes/$pod/resize-$(cut -d- -f2 <<<"$pod").status.json" >/dev/null
  jq -e --arg classic "containerd://$classic_id" '
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
  assert_runtime_cgroup_capture "$runtime" "$evidence/kubernetes/$pod/app-cgroup-after.txt"
  assert_runtime_cgroup_capture "$runtime" "$evidence/kubernetes/$pod/sidecar-cgroup-after.txt"
  test "$(find "$evidence/kubernetes/$pod/host-topology-after" -type f -name '*.txt' -size +0c -printf '.\n' | awk 'NF {n++} END {print n+0}')" -ge 1
  phase=$(cut -d- -f2 <<<"$pod")
  for role in app sidecar; do
    assert_container_runtime_identity "$runtime" "$evidence/kubernetes/$pod/$role-update"
    id=$(cat "$evidence/kubernetes/$pod/$role-create/container-id.txt")
    if test "$role" = app; then
      shares=307; quota=30000; period=100000; memory=167772160
    else
      shares=153; quota=15000; period=100000; memory=83886080
    fi
    assert_trace_window_values "$id" cri-update "$evidence/kubernetes/$pod/resize-$phase.start" "$evidence/kubernetes/$pod/resize-$phase.end" "$shares" "$quota" "$period" "$memory"
    assert_trace_window_values "$id" task-update "$evidence/kubernetes/$pod/resize-$phase.start" "$evidence/kubernetes/$pod/resize-$phase.end" "$shares" "$quota" "$period" "$memory"
    spec=$evidence/kubernetes/$pod/$role-update/raw-containerd/container-spec.decoded.json
    jq -e --argjson shares "$shares" --argjson quota "$quota" --argjson period "$period" --argjson memory "$memory" '
      .linux.resources.cpu.shares == $shares and .linux.resources.cpu.quota == $quota and
      .linux.resources.cpu.period == $period and .linux.resources.memory.limit == $memory
    ' "$spec" >/dev/null
  done
done

trace_pb_count=$(find "$evidence/scoped-update-trace" -type f -name '*.pb' -printf '.\n' | awk 'NF {n++} END {print n+0}')
test "$trace_pb_count" -ge 12
while IFS= read -r metadata; do
  pb=${metadata%.json}.pb
  test -f "$pb"
  test "$(jq -r '.sha256' "$metadata")" = "$(sha256sum "$pb" | awk '{print $1}')"
  id=$(jq -er '.objectID' "$metadata")
  grep -Fxq "$id" "$evidence/trace-allowlist.txt"
  case "$metadata" in
    *-cri-update.json) test "$(jq -r '.schema' "$metadata")" = 'runtime.v1.UpdateContainerResourcesRequest' ;;
    *-task-update.json) test "$(jq -r '.schema' "$metadata")" = 'containerd.services.tasks.v1.UpdateTaskRequest' ;;
    *) false ;;
  esac
done < <(find "$evidence/scoped-update-trace" -type f -name '*.json' | LC_ALL=C sort)
decoded_count=$(find "$evidence/scoped-update-decoded" -type f -name '*.request.pb' -printf '.\n' | awk 'NF {n++} END {print n+0}')
test "$decoded_count" -eq "$trace_pb_count"
while IFS= read -r type_url; do
  test "$(cat "$type_url")" = 'types.containerd.io/opencontainers/runtime-spec/1/LinuxResources'
done < <(find "$evidence/scoped-update-decoded" -type f -name '*.resources.type-url.txt' | LC_ALL=C sort)
while IFS= read -r schema; do
  test "$(cat "$schema")" = $'runtime.v1.UpdateContainerResourcesRequest\nmodule=k8s.io/cri-api@v0.36.4'
done < <(find "$evidence/scoped-update-decoded" -type f -name '*-cri-update.schema.txt' | LC_ALL=C sort)

hugepage_uid=$(cat "$evidence/kubernetes/hugepage-pod-uid.txt")
hugepage_token=$(jq -er '.metadata.labels["cubesandbox.io/s34-run"]' "$evidence/kubernetes/hugepage-input.json")
jq -e --arg uid "$hugepage_uid" --arg node "$node" --arg token "$hugepage_token" '
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
jq -e --arg uid "$hugepage_uid" '
  [.items[] | select(
    .involvedObject.uid == $uid and
    .type == "Warning" and
    .reason == "OutOfhugepages-2Mi" and
    ((.message // "") | test("hugepages-2Mi"; "i"))
  )] | length >= 1
' "$evidence/kubernetes/hugepage-events.json" >/dev/null
jq -e --arg uid "$hugepage_uid" '
  [.items[] | select(.metadata.name == "s34a-hugepage-reject" and .metadata.uid == $uid)] | length == 0
' "$evidence/kubernetes/hugepage-sandboxes.json" >/dev/null
grep -Fxq "$hugepage_uid" "$evidence/owned-pod-uids.txt"

for runtime in runc cube; do
  for case_name in cpu memory-limit memory-reservation swap cpuset pids hugepage-create hugepage-update unified; do
    directory=$evidence/lowlevel/$runtime/$case_name
    test -s "$directory/initial.json"
    test -s "$directory/update.json"
    test -s "$directory/create.exit"
    case "$case_name" in
      hugepage-create)
        jq -e '. == {"hugepageLimits":[{"pageSize":"2MB","limit":0}]}' "$directory/initial.json" >/dev/null
        jq -e '.linux.resources.hugepageLimits == [{"pageSize":"2MB","limit":0}]' "$directory/create/container-spec.decoded.json" >/dev/null
        ;;
      hugepage-update)
        jq -e '. == {}' "$directory/initial.json" >/dev/null
        jq -e '(.linux.resources | has("hugepageLimits")) | not' "$directory/create/container-spec.decoded.json" >/dev/null
        ;;
    esac
    if test "$runtime" = cube && test "$case_name" = hugepage-create; then
      assert_lowlevel_runtime_identity "$runtime" "$directory/create"
      test "$(cat "$directory/create.exit")" -ne 0
      test -s "$directory/create/container-spec.any.pb"
      grep -Eq '^error=.+' "$directory/create/create.result.txt"
      grep -Fq 'hugetlb..max' "$directory/create/create.result.txt"
      grep -Eqi 'ENOENT|No such file' "$directory/create/create.result.txt"
      test -z "$(find "$directory" -maxdepth 1 -name 'update-request*' -print -quit)"
      test "$(cat "$directory/delete-after-reject.exit")" -eq 0
      grep -Fxq 'runtime=cube case=hugepage-create create=rejected update=not-attempted reason=invalid-guest-cgroup-file-hugetlb..max' "$directory/classification.txt"
      continue
    fi
    test "$(cat "$directory/create.exit")" -eq 0
    assert_lowlevel_runtime_identity "$runtime" "$directory/create"
    assert_lowlevel_runtime_identity "$runtime" "$directory/container-after"
    test -s "$directory/create/container-spec.any.pb"
    test -s "$directory/create/bundle-config-00.json"
    test -s "$directory/create/create.result.txt"
    grep -Fxq success "$directory/create/create.result.txt"
    task_pid=$(cat "$directory/create/task-pid.txt")
    assert_lowlevel_cgroup_capture "$runtime" "$directory/cgroup-before.txt" "$directory/host-before.txt" "$task_pid"
    test -s "$directory/update-request.request.pb"
    test -s "$directory/update-request.resources.value"
    test "$(cat "$directory/update-request.resources.type-url.txt")" = 'types.containerd.io/opencontainers/runtime-spec/1/LinuxResources'
    test -s "$directory/update-request.result.txt"
    test -s "$directory/update.exit"
    case "$case_name" in
      hugepage-create|hugepage-update)
        jq -e '. == {"hugepageLimits":[{"pageSize":"2MB","limit":2097152}]}' "$directory/update.json" >/dev/null
        jq -e '.hugepageLimits == [{"pageSize":"2MB","limit":2097152}]' "$directory/update-request.resources.decoded.json" >/dev/null
        ;;
    esac
    if test "$(cat "$directory/update.exit")" -eq 0; then
      grep -Fxq success "$directory/update-request.result.txt"
    else
      grep -Eq '^error=.+' "$directory/update-request.result.txt"
    fi
    assert_lowlevel_cgroup_capture "$runtime" "$directory/cgroup-after.txt" "$directory/host-after.txt" "$task_pid"
    if test "$runtime" = runc; then
      test "$(cat "$directory/update.exit")" -eq 0
    fi
    grep -Eq "^runtime=$runtime case=$case_name create=accepted update=(accepted|accepted-applied|accepted-unapplied|rejected) update_exit=[0-9]+$" "$directory/classification.txt"
    case "$runtime:$case_name" in
      runc:hugepage-create|runc:hugepage-update)
        before_value=$(host_leaf_cgroup_value "$directory/host-before.txt" hugetlb.2MB.max)
        after_value=$(host_leaf_cgroup_value "$directory/host-after.txt" hugetlb.2MB.max)
        if test "$case_name" = hugepage-create; then
          test "$before_value" = 0
        else
          test "$before_value" != 2097152
        fi
        if test "$after_value" = 2097152; then
          grep -Fxq "runtime=runc case=$case_name create=accepted update=accepted-applied update_exit=0" "$directory/classification.txt"
        else
          test "$after_value" = "$before_value"
          grep -Fxq "runtime=runc case=$case_name create=accepted update=accepted-unapplied update_exit=0" "$directory/classification.txt"
        fi
        ;;
      cube:hugepage-update)
        before_value=$(cgroup_capture_optional_value "$directory/cgroup-before.txt" hugetlb.2MB.max)
        after_value=$(cgroup_capture_optional_value "$directory/cgroup-after.txt" hugetlb.2MB.max)
        if test "$(cat "$directory/update.exit")" -eq 0; then
          if test "$before_value" != 2097152 && test "$after_value" = 2097152; then
            grep -Fxq 'runtime=cube case=hugepage-update create=accepted update=accepted-applied update_exit=0' "$directory/classification.txt"
          else
            test "$after_value" = "$before_value"
            grep -Fxq 'runtime=cube case=hugepage-update create=accepted update=accepted-unapplied update_exit=0' "$directory/classification.txt"
          fi
        else
          grep -Eq '^runtime=cube case=hugepage-update create=accepted update=rejected update_exit=[1-9][0-9]*$' "$directory/classification.txt"
        fi
        ;;
    esac
  done
  directory=$evidence/lowlevel/$runtime/invalid-unified
  assert_lowlevel_runtime_identity "$runtime" "$directory/create"
  assert_lowlevel_runtime_identity "$runtime" "$directory/container-after"
  test "$(cat "$directory/create.exit")" -eq 0
  grep -Fxq success "$directory/create/create.result.txt"
  test -s "$directory/create/container-spec.any.pb"
  test -s "$directory/create/bundle-config-00.json"
  test -s "$directory/update-request.request.pb"
  test -s "$directory/update-request.resources.value"
  jq -e '.unified["memory.this_controller_does_not_exist"] == "1"' "$directory/update-request.resources.decoded.json" >/dev/null
  test -s "$directory/update-request.result.txt"
  task_pid=$(cat "$directory/create/task-pid.txt")
  assert_lowlevel_cgroup_capture "$runtime" "$directory/cgroup-before.txt" "$directory/host-before.txt" "$task_pid"
  assert_lowlevel_cgroup_capture "$runtime" "$directory/cgroup-after.txt" "$directory/host-after.txt" "$task_pid"
  if test "$runtime" = runc; then
    test "$(cat "$directory/update.exit")" -ne 0
    grep -Eq '^error=.+' "$directory/update-request.result.txt"
    grep -Eq '^runtime=runc classification=rejected update_exit=[1-9][0-9]* invalid_key=memory.this_controller_does_not_exist$' "$directory/classification.txt"
  else
    grep -Eq '^runtime=cube classification=(rejected|accepted-unapplied) update_exit=[0-9]+ invalid_key=memory.this_controller_does_not_exist$' "$directory/classification.txt"
    if test "$(cat "$directory/update.exit")" -eq 0; then grep -Fxq success "$directory/update-request.result.txt"; else grep -Eq '^error=.+' "$directory/update-request.result.txt"; fi
  fi
done

test "$(jq -r '.memory.limit' "$evidence/lowlevel/runc/swap/initial.json")" = "$(jq -r '.memory.limit' "$evidence/lowlevel/runc/swap/update.json")"
test "$(jq -r '.memory.limit' "$evidence/lowlevel/cube/swap/initial.json")" = "$(jq -r '.memory.limit' "$evidence/lowlevel/cube/swap/update.json")"
test "$(jq -r '.memory.swap' "$evidence/lowlevel/runc/swap/initial.json")" != "$(jq -r '.memory.swap' "$evidence/lowlevel/runc/swap/update.json")"
test "$(jq -r '.memory.swap' "$evidence/lowlevel/cube/swap/initial.json")" != "$(jq -r '.memory.swap' "$evidence/lowlevel/cube/swap/update.json")"

for pod in "${pods[@]}" s34a-hugepage-reject; do
  test -z "$("${kube[@]}" get pod "$pod" --ignore-not-found -o name)"
done
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
state=$("${kube[@]}" get node "$node" -o json | jq -r '[.status.conditions[] | select(.type == "Ready" or .type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") | (.type+"="+.status)] | sort | join(",")')
test "$state" = 'DiskPressure=False,MemoryPressure=False,PIDPressure=False,Ready=True'

printf 'S34A_INDEPENDENT_AUDIT_OK evidence=%s highlevel=6 lowlevel_started=17 expected_create_reject=1 invalid_unified=2 trace_pb=%s raw_create=verified raw_update=verified cleanup=exact\n' "$evidence" "$trace_pb_count"
