#!/usr/bin/env bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
evidence=/data/cubelet/s3.3-evidence/s33e-final-20260901T053443Z-806800
build_evidence=/data/cubelet/s3.3-evidence/s3.3e-build-v4-20260901T051239Z
deploy_evidence=/data/cubelet/s3.3-evidence/s3.3e-deploy-20260901T051825Z
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
vm_runtime=/run/vc/vm
fragment=/etc/containerd/conf.d/95-cubesandbox-s33e-privileged.toml
shim=/usr/local/bin/containerd-shim-cube-rs
agent_link=/data/cubelet/s13-kubernetes/assets/agent
agent_artifact=/opt/cubesandbox-s33e-runtime-artifacts-v4-a57d057a/agent/cube-agent.ext4
node=vm-200-2-ubuntu
expected_state='adapter=0 shared=0 reaper=0 cleanup=0 mounts=0 active_leases=0 cube_shims=0 vm_entries=0 cube_pods=0'
expected_shim=84c276492422bbc862e70a61c97c5d1c964595b808051400f33bfb7f531d06fd
expected_agent_bin=56a3ab87194820b405f90e6c9c19426d6f39ace8511315108ba5aa64c84c0baf
expected_agent_ext4=87bac7a6cc620595ece5fa5dfa046da8d7b0a6afe63193d7990c6f535b6e6873
expected_off_message_sha=ea488a9e63a4c96f5dc3792c916446e28ebafbbb98e6bee192509ed4fd3c340c
expected_host_dev_message_sha=50b9180bf4fa157cf11ff487efc0892d0cf5c23da1d19c26d09e4a98a3b8acf2

count_entries() {
    local entries
    if test ! -d "$1"; then printf '0\n'; return 0; fi
    entries=$(find "$1" -mindepth 1 -printf '.\n') || return 1
    awk 'NF {n++} END {print n+0}' <<<"$entries"
}

count_files() {
    local entries
    entries=$(find "$1" -type f -name "$2" -printf '.\n') || return 1
    awk 'NF {n++} END {print n+0}' <<<"$entries"
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

shared_mounts() {
    local mounts
    mounts=$(findmnt -rn -o TARGET) || return 1
    awk -v root="$shared/" 'index($1, root) == 1 {n++} END {print n+0}' <<<"$mounts"
}

current_state() {
    local adapter shared_count reaper_count cleanup_count mount_count lease_count shim_count vm_count pod_count pods
    adapter=$(count_files "$runtime_state/adapter" '*')
    shared_count=$(count_entries "$shared")
    reaper_count=$(count_entries "$reaper")
    cleanup_count=$(count_files /run/containerd cube-runtime-resource.json)
    mount_count=$(shared_mounts)
    lease_count=$(active_leases)
    shim_count=$(ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {n++} END {print n+0}')
    vm_count=$(count_entries "$vm_runtime")
    pods=$("${kube[@]}" get pods -A -o json)
    pod_count=$(jq -er '[.items[] | select(.spec.runtimeClassName=="cube")] | length' <<<"$pods")
    printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s cube_shims=%s vm_entries=%s cube_pods=%s\n' \
        "$adapter" "$shared_count" "$reaper_count" "$cleanup_count" "$mount_count" "$lease_count" "$shim_count" "$vm_count" "$pod_count"
}

test -d "$evidence"
grep -Fxq 'switch_off=ordinary-ready,privileged-rejected switch_on=ordinary-confined,privileged-guest-only guest_device_e2e=unobservable-cgroup-v2,agent-wildcard-unit=passed-separately host_dev=rejected exact_runtime_baseline=true' "$evidence/summary.txt"
grep -Fxq 'original_rc=0 cleanup_rc=0 switch=false pods_absent=true active_leases=0' "$evidence/cleanup-result.txt"

checkpoints=(before after-off after-on after-host-dev final cleanup)
for checkpoint in "${checkpoints[@]}"; do
    state="$evidence/runtime-state-$checkpoint.txt"
    test -f "$state"
    grep -Fxq "$expected_state" "$state"
done
test "$(find "$evidence" -maxdepth 1 -type f -name 'runtime-state-*.txt' -printf '.\n' | awk 'NF {n++} END {print n+0}')" -eq 6
test "$(sha256sum "$evidence"/runtime-state-*.txt | awk '{print $1}' | sort -u | awk 'NF {n++} END {print n+0}')" -eq 1

grep -Fxq ORDINARY=ready "$evidence/guest-off-normal.txt"
off_pod="$evidence/pod-cubesandbox-s33e-off-privileged.json"
test "$(jq -er '.status.containerStatuses[0].state as $s | ($s.waiting // $s.terminated).reason' "$off_pod")" = StartError
off_message=$(jq -er '.status.containerStatuses[0].state as $s | ($s.waiting // $s.terminated).message' "$off_pod")
test "$(printf '%s' "$off_message" | sha256sum | awk '{print $1}')" = "$expected_off_message_sha"
[[ "$off_message" == *'privileged OCI request rejected: node switch CUBE_ALLOW_PRIVILEGED=true is required'* ]]
jq -e '
  .metadata.name=="cubesandbox-s33e-off-privileged" and
  .spec.runtimeClassName=="cube" and
  .spec.containers[0].securityContext.privileged==true
' "$off_pod" >/dev/null
off_uid=$(jq -er '.metadata.uid' "$off_pod")
test "$(jq -er --arg uid "$off_uid" '[.containers[] | select(.labels["io.kubernetes.pod.uid"]==$uid)] | length' "$evidence/cri-running-off.json")" -eq 0

jq -e '
  .metadata.name=="cubesandbox-s33e-on-normal" and
  .spec.runtimeClassName=="cube" and
  (.spec.containers[0].securityContext.privileged // false)==false
' "$evidence/pod-normal.json" >/dev/null
jq -e '
  .metadata.name=="cubesandbox-s33e-on-privileged" and
  .spec.runtimeClassName=="cube" and
  .spec.containers[0].securityContext.privileged==true
' "$evidence/pod-privileged.json" >/dev/null
test "$(jq -er '.linux.devices // [] | length' "$evidence/oci-privileged.json")" -eq 0
test "$(jq -er '.linux.resources.devices // [] | length' "$evidence/oci-privileged.json")" -eq 1
test "$(jq -er '[.linux.resources.devices[]? | select(.allow==true and .type==null and .major==null and .minor==null and .access=="rwm")] | length' "$evidence/oci-privileged.json")" -eq 1
test "$(jq -er '[.mounts[]? | select((.source // "") | startswith("/dev"))] | length' "$evidence/oci-privileged.json")" -eq 0
test "$(jq -er '[.linux.resources.devices[]? | select(.allow==true and .type==null and .major==null and .minor==null and .access=="rwm")] | length' "$evidence/oci-normal.json")" -eq 0
test "$(jq -er '.process.capabilities.bounding | length' "$evidence/oci-privileged.json")" -eq 41
test "$(grep -Fxc 'CUBE_ALLOW_PRIVILEGED=true' "$evidence/shim-environments.txt")" -eq 2

grep -Eq '^CapEff:[[:space:]]+000001ffffffffff$' "$evidence/guest-privileged.txt"
grep -Eq '^CapPrm:[[:space:]]+000001ffffffffff$' "$evidence/guest-privileged.txt"
grep -Eq '^CapBnd:[[:space:]]+000001ffffffffff$' "$evidence/guest-privileged.txt"
grep -Eq '^CapInh:[[:space:]]+0000000000000000$' "$evidence/guest-privileged.txt"
grep -Eq '^CapAmb:[[:space:]]+0000000000000000$' "$evidence/guest-privileged.txt"
grep -Fxq DEV_KVM=absent "$evidence/guest-privileged.txt"
grep -Fxq MOUNT=allowed "$evidence/guest-privileged.txt"
grep -Fxq CGROUP_MODE=v2 "$evidence/guest-privileged.txt"
grep -Fxq DEVICE_LIST=missing "$evidence/guest-privileged.txt"
grep -Eq '^CapEff:[[:space:]]+00000000a80425fb$' "$evidence/guest-normal.txt"
grep -Eq '^CapPrm:[[:space:]]+00000000a80425fb$' "$evidence/guest-normal.txt"
grep -Eq '^CapBnd:[[:space:]]+00000000a80425fb$' "$evidence/guest-normal.txt"
grep -Eq '^CapInh:[[:space:]]+0000000000000000$' "$evidence/guest-normal.txt"
grep -Eq '^CapAmb:[[:space:]]+0000000000000000$' "$evidence/guest-normal.txt"
grep -Fxq DEV_KVM=absent "$evidence/guest-normal.txt"
grep -Fxq MOUNT=denied "$evidence/guest-normal.txt"
grep -Fxq CGROUP_MODE=v2 "$evidence/guest-normal.txt"
grep -Fxq DEVICE_LIST=missing "$evidence/guest-normal.txt"

host_dev_pod="$evidence/pod-cubesandbox-s33e-host-dev.json"
test "$(jq -er '.status.containerStatuses[0].state as $s | ($s.waiting // $s.terminated).reason' "$host_dev_pod")" = StartError
host_dev_message=$(jq -er '.status.containerStatuses[0].state as $s | ($s.waiting // $s.terminated).message' "$host_dev_pod")
test "$(printf '%s' "$host_dev_message" | sha256sum | awk '{print $1}')" = "$expected_host_dev_message_sha"
[[ "$host_dev_message" == *'privileged OCI request contains Host /dev mount source'* ]]
jq -e '
  .metadata.name=="cubesandbox-s33e-host-dev" and
  .spec.runtimeClassName=="cube" and
  .spec.containers[0].securityContext.privileged==true and
  any(.spec.volumes[]?; .name=="host-dev" and .hostPath.path=="/dev") and
  any(.spec.containers[0].volumeMounts[]?; .name=="host-dev" and .mountPath=="/host-dev")
' "$host_dev_pod" >/dev/null
host_dev_uid=$(jq -er '.metadata.uid' "$host_dev_pod")
test "$(jq -er --arg uid "$host_dev_uid" '[.containers[] | select(.labels["io.kubernetes.pod.uid"]==$uid)] | length' "$evidence/cri-running-host-dev.json")" -eq 0

grep -Fq 'privileged_without_host_devices = true' "$evidence/containerd-config-initial.toml"
grep -Fq 'privileged_without_host_devices_all_devices_allowed = true' "$evidence/containerd-config-initial.toml"
grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=false']" "$evidence/containerd-config-initial.toml"
grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=true']" "$evidence/containerd-config-switch-true.toml"
grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=false']" "$evidence/containerd-config-switch-false.toml"

test -d "$build_evidence"
grep -Fq "shim_sha=$expected_shim" "$build_evidence/summary.txt"
grep -Fq "agent_binary_sha=$expected_agent_bin" "$build_evidence/summary.txt"
grep -Fq "agent_ext4_sha=$expected_agent_ext4" "$build_evidence/summary.txt"
grep -Fxq 'test tests::all_devices_wildcard_survives_grpc_to_oci_resources ... ok' "$build_evidence/s33e-v4-agent-wildcard.log"
grep -Fxq 'test cgroups::fs::tests::all_devices_wildcard_survives_cgroup_resource_application ... ok' "$build_evidence/s33e-v4-agent-wildcard.log"
grep -Fq 'test result: ok. 2 passed; 0 failed;' "$build_evidence/s33e-v4-agent-wildcard.log"
test -d "$deploy_evidence"
grep -Fq "new_shim=$expected_shim" "$deploy_evidence/deploy-manifest.txt"
grep -Fq "new_agent=$expected_agent_ext4" "$deploy_evidence/deploy-manifest.txt"
test "$(sha256sum "$shim" | awk '{print $1}')" = "$expected_shim"
test -L "$agent_link"
test "$(readlink -f "$agent_link")" = "$agent_artifact"
test "$(sha256sum "$agent_link" | awk '{print $1}')" = "$expected_agent_ext4"

grep -Fxq "  env = ['CUBE_ALLOW_PRIVILEGED=false']" "$fragment"
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False
test "$(current_state)" = "$expected_state"

printf 'S33E_INDEPENDENT_AUDIT_OK evidence=%s e2e_device_observation=unobservable-cgroup-v2 agent_wildcard_unit=2/2 live_shim=%s live_agent_ext4=%s current_state="%s"\n' \
    "$evidence" "$expected_shim" "$expected_agent_ext4" "$expected_state"
