#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
image=docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
shim=/usr/local/bin/containerd-shim-cube-rs
shim_sha=60ba8906a391bb899b8a393ffc7c6cb9b35c37184ab9018be2a5bc523dd343d2
agent=/data/cubelet/s13-kubernetes/assets/agent
agent_sha=0b87e42457b676793030acf6b7b084297bde89b4f15c236c779ace199cf0a626
container_source_sha=2d07043963f05d2a8283defcbb3fbbc35ef9235db7a246aefac4e1cef8e62d0b
agent_source_sha=64f15fbf68b8b754447d185bda071230c8084a49c483738c8fd241361a3997c3
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.3-evidence/s3.3d-nnp-seccomp-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
run_token=s33d-$(date -u +%Y%m%d%H%M%S)-$$
pods=(
  cubesandbox-s33d-runc-unconfined cubesandbox-s33d-cube-unconfined
  cubesandbox-s33d-runc-default cubesandbox-s33d-cube-default
)
pod_uids=()
cube_sandboxes=()
declare -A created_uids=()
baseline_captured=false

count_entries() {
  local entries
  test -d "$1" || return 1
  entries=$(find "$1" -mindepth 1 -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$entries"
}
count_files() {
  local files
  test -d "$1" || return 1
  files=$(find "$1" -type f -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$files"
}
count_optional_entries() {
  local entries
  if test ! -d "$1"; then echo 0; return 0; fi
  entries=$(find "$1" -mindepth 1 -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$entries"
}
lease_records() {
  local records
  records=$(find "$runtime_state/leases" -type f -name '*.json' -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$records"
}
cleanup_records() {
  local records
  records=$(find "$containerd_state" -name cube-runtime-resource.json -type f -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$records"
}
active_leases() {
  local record records count=0 rc
  records=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    if jq -e '.active == null' "$record" >/dev/null; then
      :
    else
      rc=$?
      test "$rc" -eq 1 || return 1
      count=$((count + 1))
    fi
  done <<<"$records"
  echo "$count"
}
shared_mounts() {
  local mounts
  mounts=$(findmnt -rn -o TARGET) || return 1
  awk -v root="$shared/" 'index($1, root) == 1 {n++} END {print n+0}' <<<"$mounts"
}

capture_state() {
  local tag=$1 adapter shared_count reaper_count cleanup_count mounts active
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt" || return 1
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt" || return 1
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt" || return 1
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt" || return 1
  { if test -d /var/run/netns; then find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n'; fi; } | sort >"$evidence/netns-$tag.txt" || return 1
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort >"$evidence/cube-shims-$tag.txt" || return 1
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P\t%y\n'; fi; } | sort >"$evidence/vm-runtime-$tag.txt" || return 1
  adapter=$(count_files "$runtime_state/adapter") || return 1
  shared_count=$(count_entries "$shared") || return 1
  reaper_count=$(count_entries "$reaper") || return 1
  cleanup_count=$(cleanup_records) || return 1
  mounts=$(shared_mounts) || return 1
  active=$(active_leases) || return 1
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s\n' \
    "$adapter" "$shared_count" "$reaper_count" "$cleanup_count" "$mounts" "$active" \
    >"$evidence/runtime-resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime runtime-resources; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
}

assert_baseline() {
  local tag=$1 attempt kind
  for attempt in $(seq 1 1800); do
    capture_state "$tag" || return 1
    if state_matches_baseline "$tag"; then
      printf 'S33D_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
        "$tag" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep .1
  done
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime runtime-resources; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" >"$evidence/$kind-$tag.diff" 2>&1 || true
  done
  return 1
}

wait_runtime_idle() {
  local attempt adapter shared_count reaper_count vm_count cleanup_count mounts active
  for attempt in $(seq 1 1800); do
    if adapter=$(count_files "$runtime_state/adapter") \
      && shared_count=$(count_entries "$shared") \
      && reaper_count=$(count_entries "$reaper") \
      && vm_count=$(count_optional_entries "$vm_runtime") \
      && cleanup_count=$(cleanup_records) \
      && mounts=$(shared_mounts) \
      && active=$(active_leases) \
      && test "$adapter" -eq 0 \
      && test "$shared_count" -eq 0 \
      && test "$reaper_count" -eq 0 \
      && test "$vm_count" -eq 0 \
      && test "$cleanup_count" -eq 0 \
      && test "$mounts" -eq 0 \
      && test "$active" -eq 0 \
      && ! ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {found=1} END {exit !found}'; then
      return 0
    fi
    sleep .1
  done
  return 1
}

is_owned() {
  local pod=$1 object expected_uid owned token actual_uid
  expected_uid=${created_uids[$pod]:-}
  object=$("${kube[@]}" get pod "$pod" -o json) || return 1
  owned=$(jq -er '.metadata.labels["cubesandbox.io/s33d-owned"] // ""' <<<"$object") || return 1
  token=$(jq -er '.metadata.labels["cubesandbox.io/s33d-run"] // ""' <<<"$object") || return 1
  actual_uid=$(jq -er '.metadata.uid // ""' <<<"$object") || return 1
  test "$owned" = true || return 1
  test "$token" = "$run_token" || return 1
  test -n "$actual_uid" || return 1
  if test -n "$expected_uid"; then
    test "$actual_uid" = "$expected_uid" || return 1
  else
    created_uids[$pod]=$actual_uid
  fi
}

fixed_pods_absent() {
  local pod current
  for pod in "${pods[@]}"; do
    current=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name) || return 1
    test -z "$current" || return 1
  done
}

delete_owned_pods() {
  local pod current
  for pod in "${pods[@]}"; do
    current=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name) || return 1
    test -n "$current" || continue
    test "$current" = "pod/$pod" || return 1
    is_owned "$pod" || { printf 'refusing to delete non-owned pod %s\n' "$pod" >&2; return 1; }
    "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null
  done
  for _ in $(seq 1 1800); do fixed_pods_absent && return 0; sleep .1; done
  return 1
}

append_pod_uid() {
  local candidate=$1 known
  test -n "$candidate" || return 1
  for known in "${pod_uids[@]}"; do test "$known" != "$candidate" || return 0; done
  pod_uids+=("$candidate")
}

collect_existing_owned_uids() {
  local pod current uid
  for pod in "${pods[@]}"; do
    current=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name) || return 1
    test -n "$current" || continue
    test "$current" = "pod/$pod" || return 1
    is_owned "$pod" || return 1
    uid=$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.uid}') || return 1
    test "$uid" = "${created_uids[$pod]:-}" || return 1
    append_pod_uid "$uid" || return 1
  done
}

wait_pod_dirs_absent() {
  local attempt uid clean
  for attempt in $(seq 1 1800); do
    clean=true
    for uid in "${pod_uids[@]}"; do
      if test -e "/var/lib/kubelet/pods/$uid" || test -L "/var/lib/kubelet/pods/$uid"; then clean=false; break; fi
    done
    test "$clean" = true && return 0
    sleep .1
  done
  return 1
}

save_diagnostics() {
  local pod
  for pod in "${pods[@]}"; do
    "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-$pod-final.json" 2>&1 || true
  done
  "${cri[@]}" pods -o json >"$evidence/cri-pods-final.json" 2>&1 || true
  "${cri[@]}" ps -a -o json >"$evidence/cri-containers-final.json" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
}

cleanup() {
  local rc=$? cleanup_rc=0 baseline=not-captured fixed=false active=unknown
  set +e
  save_diagnostics
  collect_existing_owned_uids || cleanup_rc=1
  delete_owned_pods || cleanup_rc=1
  wait_pod_dirs_absent || cleanup_rc=1
  wait_runtime_idle || cleanup_rc=1
  if test "$baseline_captured" = true; then
    if assert_baseline cleanup; then baseline=true; else baseline=false; cleanup_rc=1; fi
  fi
  if fixed_pods_absent; then fixed=true; else cleanup_rc=1; fi
  if active=$(active_leases); then test "$active" -eq 0 || cleanup_rc=1; else active=query-failed; cleanup_rc=1; fi
  printf 'original_rc=%s cleanup_rc=%s exact_baseline=%s fixed_pods_absent=%s active_leases=%s\n' \
    "$rc" "$cleanup_rc" "$baseline" "$fixed" "$active" \
    >"$evidence/cleanup-result.txt"
  test "$rc" -ne 0 && exit "$rc"
  exit "$cleanup_rc"
}

pod_uid() { "${kube[@]}" get pod "$1" -o jsonpath='{.metadata.uid}'; }

container_for_uid() {
  local uid=$1 ids count
  ids=$("${cri[@]}" ps -a -o json | jq -r --arg uid "$uid" \
    '.containers[]? | select(.labels["io.kubernetes.pod.uid"] == $uid and .metadata.name == "app") | .id') || return 1
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1 || return 1
  printf '%s\n' "$ids"
}

wait_container_for_uid() {
  local uid=$1 id
  for _ in $(seq 1 1800); do
    if id=$(container_for_uid "$uid"); then printf '%s\n' "$id"; return 0; fi
    sleep .1
  done
  return 1
}

sandbox_for_uid() {
  local uid=$1 ids count
  ids=$("${cri[@]}" pods -o json | jq -r --arg uid "$uid" '.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id') || return 1
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1 || return 1
  printf '%s\n' "$ids"
}

inactive_lease_count_for_sandbox() {
  local sandbox=$1 record records record_sandbox count=0 rc
  records=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    record_sandbox=$(jq -er '.sandboxID | strings' "$record") || return 1
    test "$record_sandbox" = "$sandbox" || continue
    if jq -e '.active == null' "$record" >/dev/null; then
      count=$((count + 1))
    else
      rc=$?
      test "$rc" -eq 1 || return 1
    fi
  done <<<"$records"
  echo "$count"
}

capture_host_input() {
  local tag=$1 pod=$2 uid id
  "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-$tag.json"
  uid=$(jq -r '.metadata.uid' "$evidence/pod-$tag.json")
  id=$(wait_container_for_uid "$uid")
  "${cri[@]}" inspect "$id" >"$evidence/cri-$tag.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$tag.json"
  jq -S '{layer:"host-pre-shim-input",noNewPrivileges:(.info.runtimeSpec.process.noNewPrivileges // false),seccomp:(.info.runtimeSpec.linux.seccomp // null)}' \
    "$evidence/cri-$tag.json" >"$evidence/host-pre-shim-cri-$tag.json"
  jq -S '{layer:"host-pre-shim-input",noNewPrivileges:(.Spec.process.noNewPrivileges // false),seccomp:(.Spec.linux.seccomp // null)}' \
    "$evidence/ctr-$tag.json" >"$evidence/host-pre-shim-ctr-$tag.json"
  cmp "$evidence/host-pre-shim-cri-$tag.json" "$evidence/host-pre-shim-ctr-$tag.json"
}

capture_guest() {
  local tag=$1 pod=$2 uid dir
  uid=$(pod_uid "$pod")
  dir=/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~empty-dir/evidence
  for _ in $(seq 1 600); do test -s "$dir/observed.txt" && break; sleep .1; done
  test -s "$dir/observed.txt"
  cp "$dir/observed.txt" "$evidence/guest-$tag.txt"
  "${kube[@]}" logs "$pod" >"$evidence/log-$tag.txt"
  cmp "$evidence/guest-$tag.txt" "$evidence/log-$tag.txt"
}

status_value() { awk -v key="$2" '$1 == key":" {print $2}' "$1"; }
field_value() { awk -F= -v key="$2" '$1 == key {print $2}' "$1"; }

assert_runtime_default_profile_transportable() {
  jq -e '
    .noNewPrivileges == true and
    .seccomp.defaultAction == "SCMP_ACT_ERRNO" and
    (.seccomp.architectures | index("SCMP_ARCH_X86_64")) != null and
    (.seccomp.syscalls | length) > 0 and
    ((.seccomp | keys) - ["architectures", "defaultAction", "flags", "syscalls"] | length) == 0 and
    all(.seccomp.syscalls[];
      ((keys - ["action", "args", "errnoRet", "names"]) | length) == 0 and
      ((has("errnoRet") | not) or .errnoRet != 0) and
      all(.args[]?; ((keys - ["index", "op", "value", "valueTwo"]) | length) == 0)
    )
  ' "$1" >/dev/null
}

write_manifest() {
  local output=$1
  cat >"$output" <<PODS_EOF
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33d-runc-unconfined, labels: {cubesandbox.io/s33d-owned: "true", cubesandbox.io/s33d-run: "$run_token"}}
spec:
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'grep -E "^(NoNewPrivs|Seccomp|Seccomp_filters):" /proc/self/status > /evidence/observed.txt; if busybox unshare true 2>/evidence/unshare.stderr; then result=ALLOWED; rc=0; else rc=\$?; result=BLOCKED; fi; printf "UNSHARE=%s\\nUNSHARE_RC=%s\\n" "\$result" "\$rc" >> /evidence/observed.txt; sed "s/^/UNSHARE_STDERR=/" /evidence/unshare.stderr >> /evidence/observed.txt; cat /evidence/observed.txt; exec sleep 600']
    securityContext: {allowPrivilegeEscalation: true, seccompProfile: {type: Unconfined}}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33d-cube-unconfined, labels: {cubesandbox.io/s33d-owned: "true", cubesandbox.io/s33d-run: "$run_token"}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'grep -E "^(NoNewPrivs|Seccomp|Seccomp_filters):" /proc/self/status > /evidence/observed.txt; if busybox unshare true 2>/evidence/unshare.stderr; then result=ALLOWED; rc=0; else rc=\$?; result=BLOCKED; fi; printf "UNSHARE=%s\\nUNSHARE_RC=%s\\n" "\$result" "\$rc" >> /evidence/observed.txt; sed "s/^/UNSHARE_STDERR=/" /evidence/unshare.stderr >> /evidence/observed.txt; cat /evidence/observed.txt; exec sleep 600']
    securityContext: {allowPrivilegeEscalation: true, seccompProfile: {type: Unconfined}}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33d-runc-default, labels: {cubesandbox.io/s33d-owned: "true", cubesandbox.io/s33d-run: "$run_token"}}
spec:
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'grep -E "^(NoNewPrivs|Seccomp|Seccomp_filters):" /proc/self/status > /evidence/observed.txt; if busybox unshare true 2>/evidence/unshare.stderr; then result=ALLOWED; rc=0; else rc=\$?; result=BLOCKED; fi; printf "UNSHARE=%s\\nUNSHARE_RC=%s\\n" "\$result" "\$rc" >> /evidence/observed.txt; sed "s/^/UNSHARE_STDERR=/" /evidence/unshare.stderr >> /evidence/observed.txt; cat /evidence/observed.txt; exec sleep 600']
    securityContext: {allowPrivilegeEscalation: false, seccompProfile: {type: RuntimeDefault}}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33d-cube-default, labels: {cubesandbox.io/s33d-owned: "true", cubesandbox.io/s33d-run: "$run_token"}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'grep -E "^(NoNewPrivs|Seccomp|Seccomp_filters):" /proc/self/status > /evidence/observed.txt; if busybox unshare true 2>/evidence/unshare.stderr; then result=ALLOWED; rc=0; else rc=\$?; result=BLOCKED; fi; printf "UNSHARE=%s\\nUNSHARE_RC=%s\\n" "\$result" "\$rc" >> /evidence/observed.txt; sed "s/^/UNSHARE_STDERR=/" /evidence/unshare.stderr >> /evidence/observed.txt; cat /evidence/observed.txt; exec sleep 600']
    securityContext: {allowPrivilegeEscalation: false, seccompProfile: {type: RuntimeDefault}}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
PODS_EOF
}

run_round() {
  local round=$1 pod runtime case_name tag uid sandbox guest
  fixed_pods_absent || return 1
  created_uids=()
  write_manifest "$evidence/pods-$round.yaml"
  "${kube[@]}" create -f "$evidence/pods-$round.yaml" >"$evidence/create-$round.txt"
  for pod in "${pods[@]}"; do
    uid=$(pod_uid "$pod") || return 1
    created_uids[$pod]=$uid
    is_owned "$pod" || return 1
    append_pod_uid "$uid" || return 1
    "${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=300s >"$evidence/wait-$round-$pod.txt"
  done

  for runtime in runc cube; do
    for case_name in unconfined default; do
      tag=$round-$runtime-$case_name
      pod=cubesandbox-s33d-$runtime-$case_name
      capture_host_input "$tag" "$pod"
      capture_guest "$tag" "$pod"
    done
  done
  cmp "$evidence/host-pre-shim-cri-$round-runc-unconfined.json" "$evidence/host-pre-shim-cri-$round-cube-unconfined.json"
  cmp "$evidence/host-pre-shim-cri-$round-runc-default.json" "$evidence/host-pre-shim-cri-$round-cube-default.json"

  jq -e '.noNewPrivileges == false and .seccomp == null' "$evidence/host-pre-shim-cri-$round-runc-unconfined.json" >/dev/null
  assert_runtime_default_profile_transportable "$evidence/host-pre-shim-cri-$round-runc-default.json"

  for runtime in runc cube; do
    guest=$evidence/guest-$round-$runtime-unconfined.txt
    test "$(status_value "$guest" NoNewPrivs)" = 0
    test "$(status_value "$guest" Seccomp)" = 0
    test "$(status_value "$guest" Seccomp_filters)" = 0
    test "$(field_value "$guest" UNSHARE)" = ALLOWED
    test "$(field_value "$guest" UNSHARE_RC)" = 0

    guest=$evidence/guest-$round-$runtime-default.txt
    test "$(status_value "$guest" NoNewPrivs)" = 1
    test "$(status_value "$guest" Seccomp)" = 2
    test "$(status_value "$guest" Seccomp_filters)" -ge 1
    test "$(field_value "$guest" UNSHARE)" = BLOCKED
    test "$(field_value "$guest" UNSHARE_RC)" -ne 0
    grep -Fq 'UNSHARE_STDERR=unshare: unshare(0x0): Operation not permitted' "$guest"

    printf '%s\t%s\tfalse\t0\t0\tALLOWED\n' "$round" "$runtime" >>"$evidence/results.tsv"
    printf '%s\t%s\ttrue\t1\t2\tBLOCKED\n' "$round" "$runtime" >>"$evidence/results.tsv"
  done

  for pod in cubesandbox-s33d-cube-unconfined cubesandbox-s33d-cube-default; do
    uid=$(pod_uid "$pod")
    sandbox=$(sandbox_for_uid "$uid")
    cube_sandboxes+=("$sandbox")
    printf '%s\t%s\t%s\n' "$round" "$pod" "$sandbox" >>"$evidence/cube-sandboxes.tsv"
  done

  delete_owned_pods
  wait_pod_dirs_absent
  assert_baseline "$round-after"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

fixed_pods_absent
for required_dir in "$runtime_state/leases" "$runtime_state/adapter" "$shared" "$reaper" "$containerd_state"; do
  test -d "$required_dir"
done
wait_runtime_idle
test "$(sha256sum "$shim" | awk '{print $1}')" = "$shim_sha"
test "$(sha256sum "$agent" | awk '{print $1}')" = "$agent_sha"
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False
test -c /dev/kvm
"${kube[@]}" version -o json >"$evidence/kubernetes-version.json"
containerd --version >"$evidence/containerd-version.txt"
uname -srmo >"$evidence/kernel.txt"
test "$(jq -r '.serverVersion.minor | sub("\\+.*$"; "")' "$evidence/kubernetes-version.json")" -ge 36
grep -F 'containerd github.com/containerd/containerd/v2 v2.3.4' "$evidence/containerd-version.txt" >/dev/null
test "$(uname -m)" = x86_64
printf 'container_source_sha256=%s\nagent_source_sha256=%s\nshim_sha256=%s\nagent_sha256=%s\nimage=%s\nprotobuf_contract=process-9,linux-seccomp-8,runtime-default-subset\n' \
  "$container_source_sha" "$agent_source_sha" "$shim_sha" "$agent_sha" "$image" >"$evidence/input-fingerprint.txt"
"${cri[@]}" pull "$image" >"$evidence/image-pull.txt"
capture_state before
baseline_captured=true
leases_before=$(lease_records)
printf 'round\truntime\thost_nnp\tguest_nnp\tguest_seccomp\tunshare\n' >"$evidence/results.tsv"
printf 'round\tpod\tsandbox_id\n' >"$evidence/cube-sandboxes.tsv"
printf 'point\tlease_records\n' >"$evidence/lease-counts.tsv"
printf 'before\t%s\n' "$leases_before" >>"$evidence/lease-counts.tsv"

run_round round1
run_round round2

leases_after=$(lease_records)
printf 'after\t%s\n' "$leases_after" >>"$evidence/lease-counts.tsv"
test $((leases_after - leases_before)) -eq 4
test "$(printf '%s\n' "${cube_sandboxes[@]}" | sort -u | wc -l)" -eq 4
test "${#pod_uids[@]}" -eq 8
for sandbox in "${cube_sandboxes[@]}"; do
  test "$(inactive_lease_count_for_sandbox "$sandbox")" -eq 1
done
test "$(wc -l <"$evidence/results.tsv")" -eq 9
test "$(active_leases)" -eq 0
fixed_pods_absent
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
"${kube[@]}" get node "$node" -o json >"$evidence/node-after.json"
test "$(jq -r '.status.conditions[] | select(.type == "Ready") | .status' "$evidence/node-after.json")" = True
test "$(jq -r '.status.conditions[] | select(.type == "DiskPressure") | .status' "$evidence/node-after.json")" = False
test ! -e "$evidence/trace.log"
printf 'S33D_NNP_SECCOMP_OK rounds=2 pods=8 cube_sandboxes=4 nnp_false=0 nnp_true=1 runtime_default=mode2,filters>=1 unshare=allowed:blocked lease_delta=4 exact_baseline=restored\n' | tee -a "$evidence/summary.txt"
printf 'S33D_DONE active_leases=0 fixed_pods_absent=true evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
