#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
image=registry.k8s.io/e2e-test-images/agnhost@sha256:2c5b5b056076334e4cf431d964d102e44cbca8f1e6b16ac1e477a0ffbe6caac4
shim=/usr/local/bin/containerd-shim-cube-rs
shim_sha=4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14
agent=/data/cubelet/s13-kubernetes/assets/agent
agent_sha=b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9
runtime_implementation_commit=83902212a85158c8c5fd947e8b06a661f0e1075c
identity_source_sha=019cd2f1915e6a6565703bce16221de719a066a500da35bfad02406533ad0405
unit_invocation=inv-9841kq036r
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.3-evidence/s3.3b-identity-groups-$(date -u +%Y%m%dT%H%M%SZ)
positive_pods=(
  cubesandbox-s33b-runc-merge cubesandbox-s33b-cube-merge
  cubesandbox-s33b-runc-strict cubesandbox-s33b-cube-strict
  cubesandbox-s33b-runc-multi cubesandbox-s33b-cube-multi
)
negative_pods=(cubesandbox-s33b-runc-negative cubesandbox-s33b-cube-negative)
pods=("${positive_pods[@]}" "${negative_pods[@]}")
pod_uids=()
cube_sandboxes=()
baseline_captured=false

count_entries() {
  local value
  if test -d "$1"; then value=$(find "$1" -mindepth 1 -printf '.\n' | wc -l) || return 1; else value=0; fi
  printf '%s\n' "$value"
}

count_files() {
  local value
  if test -d "$1"; then value=$(find "$1" -type f -printf '.\n' | wc -l) || return 1; else value=0; fi
  printf '%s\n' "$value"
}

lease_records() {
  local value
  value=$(find "$runtime_state/leases" -type f -name '*.json' -printf '.\n' | wc -l) || return 1
  printf '%s\n' "$value"
}

active_leases() {
  local records record count=0 jq_rc
  records=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    if jq -e '.active == null' "$record" >/dev/null; then :; else
      jq_rc=$?
      test "$jq_rc" -eq 1 || return 1
      count=$((count + 1))
    fi
  done <<<"$records"
  printf '%s\n' "$count"
}

lease_count_for_sandbox() {
  local sandbox=$1 inactive=$2 records record record_sandbox count=0 jq_rc
  records=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    record_sandbox=$(jq -er '.sandboxID | strings' "$record") || return 1
    test "$record_sandbox" = "$sandbox" || continue
    if test "$inactive" = true; then
      if jq -e '.active == null' "$record" >/dev/null; then count=$((count + 1)); else
        jq_rc=$?
        test "$jq_rc" -eq 1 || return 1
      fi
    else
      count=$((count + 1))
    fi
  done <<<"$records"
  printf '%s\n' "$count"
}

shared_mounts() {
  local mounts
  mounts=$(findmnt -rn -o TARGET) || return 1
  awk -v root="$shared/" 'index($1, root) == 1 {n++} END {print n+0}' <<<"$mounts"
}

cleanup_records() {
  local value
  value=$(find "$containerd_state" -name cube-runtime-resource.json -type f -printf '.\n' | wc -l) || return 1
  printf '%s\n' "$value"
}

capture_state() {
  local tag=$1 adapter_count shared_count reaper_count cleanup_count mounts active_count
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt" || return 1
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt" || return 1
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt" || return 1
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt" || return 1
  { if test -d /var/run/netns; then find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n'; fi; } | sort >"$evidence/netns-$tag.txt" || return 1
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort >"$evidence/cube-shims-$tag.txt" || return 1
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P\t%y\n'; fi; } | sort >"$evidence/vm-runtime-$tag.txt" || return 1
  adapter_count=$(count_files "$runtime_state/adapter") || return 1
  shared_count=$(count_entries "$shared") || return 1
  reaper_count=$(count_entries "$reaper") || return 1
  cleanup_count=$(cleanup_records) || return 1
  mounts=$(shared_mounts) || return 1
  active_count=$(active_leases) || return 1
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s\n' \
    "$adapter_count" "$shared_count" "$reaper_count" "$cleanup_count" "$mounts" "$active_count" \
    >"$evidence/runtime-resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime runtime-resources; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
}

assert_baseline() {
  local tag=$1 attempt leases
  for attempt in $(seq 1 1800); do
    capture_state "$tag" || return 1
    if state_matches_baseline "$tag"; then
      leases=$(lease_records) || return 1
      printf 'S33B_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
        "$tag" "$attempt" "$leases" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep .1
  done
  return 1
}

wait_runtime_idle() {
  local attempt
  for attempt in $(seq 1 1800); do
    if test "$(count_files "$runtime_state/adapter")" -eq 0 \
      && test "$(count_entries "$shared")" -eq 0 \
      && test "$(count_entries "$reaper")" -eq 0 \
      && test "$(count_entries "$vm_runtime")" -eq 0 \
      && test "$(cleanup_records)" -eq 0 \
      && test "$(shared_mounts)" -eq 0 \
      && test "$(active_leases)" -eq 0 \
      && ! ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {found=1} END {exit !found}'; then
      return 0
    fi
    sleep .1
  done
  return 1
}

is_owned() {
  local label
  label=$("${kube[@]}" get pod "$1" -o jsonpath='{.metadata.labels.cubesandbox\.io/s33b-owned}') || return 1
  test "$label" = true
}

fixed_pods_absent() {
  local pod result
  for pod in "${pods[@]}"; do
    result=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name) || return 1
    test -z "$result" || return 1
  done
}

delete_owned_pods() {
  local pod result
  for pod in "${pods[@]}"; do
    result=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name) || return 1
    if test -n "$result"; then
      test "$result" = "pod/$pod" || return 1
      is_owned "$pod" || { printf 'refusing to delete non-owned pod %s\n' "$pod" >&2; return 1; }
      "${kube[@]}" delete pod "$pod" --wait=false >/dev/null || return 1
    fi
  done
}

append_pod_uid() {
  local uid=$1 existing
  for existing in "${pod_uids[@]}"; do
    if test "$existing" = "$uid"; then return 0; fi
  done
  pod_uids+=("$uid")
}

collect_existing_owned_uids() {
  local pod pod_json uid
  for pod in "${pods[@]}"; do
    pod_json=$("${kube[@]}" get pod "$pod" --ignore-not-found -o json) || return 1
    test -n "$pod_json" || continue
    test "$(jq -r '.metadata.labels["cubesandbox.io/s33b-owned"] // ""' <<<"$pod_json")" = true || return 1
    uid=$(jq -er '.metadata.uid | strings | select(length > 0)' <<<"$pod_json") || return 1
    append_pod_uid "$uid" || return 1
  done
}

append_cube_sandbox() {
  local round=$1 pod=$2 sandbox=$3 existing
  for existing in "${cube_sandboxes[@]}"; do test "$existing" != "$sandbox" || return 1; done
  cube_sandboxes+=("$sandbox")
  printf '%s\t%s\t%s\n' "$round" "$pod" "$sandbox" >>"$evidence/cube-sandboxes.tsv"
}

wait_pod_dirs_absent() {
  local uid
  for uid in "${pod_uids[@]}"; do
    for _ in $(seq 1 1200); do test ! -e "/var/lib/kubelet/pods/$uid" && test ! -L "/var/lib/kubelet/pods/$uid" && break; sleep .1; done
    test ! -e "/var/lib/kubelet/pods/$uid" && test ! -L "/var/lib/kubelet/pods/$uid" || return 1
  done
}

cleanup() {
  local original_rc=$? cleanup_rc=0 exact=false idle=false absent=false dirs=false leases_zero=false
  set +e
  collect_existing_owned_uids || cleanup_rc=1
  delete_owned_pods || cleanup_rc=1
  wait_pod_dirs_absent || cleanup_rc=1
  if fixed_pods_absent; then absent=true; else cleanup_rc=1; fi
  if wait_runtime_idle; then idle=true; else cleanup_rc=1; fi
  if test "$(active_leases)" -eq 0; then leases_zero=true; else cleanup_rc=1; fi
  if test "$baseline_captured" = true; then
    if capture_state cleanup && state_matches_baseline cleanup; then exact=true; else cleanup_rc=1; fi
  fi
  if wait_pod_dirs_absent; then dirs=true; else cleanup_rc=1; fi
  printf 'original_rc=%s cleanup_rc=%s fixed_pods_absent=%s pod_dirs_absent=%s runtime_idle=%s exact_baseline=%s active_leases_zero=%s\n' \
    "$original_rc" "$cleanup_rc" "$absent" "$dirs" "$idle" "$exact" "$leases_zero" \
    >"$evidence/cleanup-result.txt"
  if test "$baseline_captured" = true && test "$exact" = true; then
    printf 'S33B_BASELINE_CLEAN tag=cleanup wait_attempt=1 lease_records=%s\n' "$(lease_records)" >>"$evidence/summary.txt"
  fi
  if test "$original_rc" -ne 0; then return "$original_rc"; fi
  return "$cleanup_rc"
}

pod_uid() { "${kube[@]}" get pod "$1" -o jsonpath='{.metadata.uid}'; }

sandbox_for_uid_optional() {
  local uid=$1 ids count
  ids=$("${cri[@]}" pods -o json | jq -r --arg uid "$uid" '.items[]? | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id') || return 1
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -le 1 || return 1
  printf '%s\n' "$ids"
}

sandbox_for_uid_in_file_optional() {
  local file=$1 uid=$2 ids count
  ids=$(jq -r --arg uid "$uid" '.items[]? | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id' "$file") || return 1
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -le 1 || return 1
  printf '%s\n' "$ids"
}

container_for_uid_name() {
  local uid=$1 name=$2 ids count
  ids=$("${cri[@]}" ps -a -o json | jq -r --arg uid "$uid" --arg name "$name" \
    '.containers[]? | select(.labels["io.kubernetes.pod.uid"] == $uid and .metadata.name == $name) | .id') || return 1
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1 || return 1
  printf '%s\n' "$ids"
}

container_count_for_uid() {
  local uid=$1
  "${cri[@]}" ps -a -o json | jq -r --arg uid "$uid" '[.containers[]? | select(.labels["io.kubernetes.pod.uid"] == $uid)] | length'
}

capture_ctr_records_for_uid() {
  local output=$1 uid=$2 id ids info labels_uid jsonl
  jsonl=$output.jsonl
  : >"$jsonl"
  ids=$("${ctr[@]}" containers list -q) || return 1
  while IFS= read -r id; do
    test -n "$id" || continue
    info=$("${ctr[@]}" containers info "$id") || return 1
    labels_uid=$(jq -r '.Labels["io.kubernetes.pod.uid"] // .labels["io.kubernetes.pod.uid"] // ""' \
      <<<"$info") || return 1
    if test "$labels_uid" = "$uid"; then jq -c '.' <<<"$info" >>"$jsonl" || return 1; fi
  done <<<"$ids"
  jq -s '.' "$jsonl" >"$output"
}

host_evidence_dir() {
  printf '/var/lib/kubelet/pods/%s/volumes/kubernetes.io~empty-dir/evidence\n' "$1"
}

field_value() { awk -F= -v key="$2" '$1 == key {sub(/^[^=]*=/, ""); print}' "$1"; }

sorted_groups() {
  field_value "$1" GROUPS | tr ' ' '\n' | awk 'NF' | sort -n | paste -sd, -
}

assert_log_covers_observation() {
  local observation=$1 log=$2 line
  while IFS= read -r line; do
    test -n "$line" || continue
    grep -Fxq "$line" "$log" || return 1
  done <"$observation"
}

capture_container_input() {
  local round=$1 runtime=$2 case_name=$3 container_name=$4 uid=$5 id tag
  tag=$round-$runtime-$case_name-$container_name
  id=$(container_for_uid_name "$uid" "$container_name")
  "${cri[@]}" inspect "$id" >"$evidence/cri-$tag.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$tag.json"
  jq -S '{layer:"host-pre-shim-input",processUser:(.info.runtimeSpec.process.user // {})}' \
    "$evidence/cri-$tag.json" >"$evidence/host-user-cri-$tag.json"
  jq -S '{layer:"host-pre-shim-input",processUser:(.Spec.process.user // {})}' \
    "$evidence/ctr-$tag.json" >"$evidence/host-user-ctr-$tag.json"
  cmp "$evidence/host-user-cri-$tag.json" "$evidence/host-user-ctr-$tag.json"
  test "$(jq -r '.status.labels["io.kubernetes.pod.uid"]' "$evidence/cri-$tag.json")" = "$uid"
  test "$(jq -r '.status.metadata.name' "$evidence/cri-$tag.json")" = "$container_name"
  test "$(jq -r '.info.sandboxID' "$evidence/cri-$tag.json")" = "$(sandbox_for_uid_optional "$uid")"
}

assert_host_user() {
  local file=$1 uid=$2 gid=$3 groups=$4
  test "$(jq -r '.processUser.uid' "$file")" -eq "$uid"
  test "$(jq -r '.processUser.gid' "$file")" -eq "$gid"
  test "$(jq -r '.processUser.additionalGids | sort | join(",")' "$file")" = "$groups"
}

capture_observation() {
  local round=$1 runtime=$2 case_name=$3 container_name=$4 uid=$5 source tag attempt captured=false
  tag=$round-$runtime-$case_name-$container_name
  source=$(host_evidence_dir "$uid")/$container_name.txt
  for _ in $(seq 1 600); do test -s "$source" && break; sleep .1; done
  test -s "$source"
  cp "$source" "$evidence/observation-$tag.txt"
  for attempt in $(seq 1 300); do
    if "${kube[@]}" logs "cubesandbox-s33b-$runtime-$case_name" -c "$container_name" \
      >"$evidence/log-$tag.txt" 2>"$evidence/log-$tag.stderr" \
      && assert_log_covers_observation "$evidence/observation-$tag.txt" "$evidence/log-$tag.txt"; then
      captured=true
      break
    fi
    sleep .1
  done
  test "$captured" = true
}

assert_observation() {
  local file=$1 uid=$2 gid=$3 groups=$4
  test "$(field_value "$file" INIT_RAN)" = 1
  test "$(field_value "$file" UID)" -eq "$uid"
  test "$(field_value "$file" GID)" -eq "$gid"
  test "$(sorted_groups "$file")" = "$groups"
  test "$(field_value "$file" VOLUME_GID)" -eq 2000
  test "$(field_value "$file" WRITE)" = OK
  test "$(field_value "$file" MARKER_GID)" -eq 2000
}

assert_status_user() {
  local pod_json=$1 status_kind=$2 container_name=$3 uid=$4 gid=$5 groups=$6
  jq -e --arg kind "$status_kind" --arg name "$container_name" \
    --argjson uid "$uid" --argjson gid "$gid" --arg groups "$groups" \
    '(.status | if $kind == "init" then .initContainerStatuses else .containerStatuses end // []) as $statuses
     | [$statuses[] | select(.name == $name)] as $matches
     | (($matches | length) == 1) and
       ($matches[0].user.linux.uid == $uid) and
       ($matches[0].user.linux.gid == $gid) and
       (($matches[0].user.linux.supplementalGroups | sort | map(tostring) | join(",")) == $groups)' \
    "$pod_json" >/dev/null
}

observation_command() {
  local container_name=$1 sleep_after=$2
  printf '%s' "printf 'INIT_RAN=1\\nUID=%s\\nGID=%s\\nGROUPS=%s\\nVOLUME_GID=%s\\n' \"\$(id -u)\" \"\$(id -g)\" \"\$(id -G)\" \"\$(stat -c %g /evidence)\" > /evidence/$container_name.txt; if printf '%s\\n' '$container_name-wrote' > /evidence/$container_name.marker; then printf 'WRITE=OK\\n' >> /evidence/$container_name.txt; else printf 'WRITE=FAILED\\n' >> /evidence/$container_name.txt; fi; printf 'MARKER_GID=%s\\n' \"\$(stat -c %g /evidence/$container_name.marker)\" >> /evidence/$container_name.txt; cat /evidence/$container_name.txt; $sleep_after"
}

write_positive_yaml() {
  local round=$1 merge_cmd strict_cmd init_cmd sidecar_cmd app_cmd runtime runtime_class
  merge_cmd=$(observation_command app 'exec sleep 1000')
  strict_cmd=$(observation_command app 'exec sleep 1000')
  init_cmd=$(observation_command init 'exit 0')
  sidecar_cmd=$(observation_command sidecar 'exec sleep 1000')
  app_cmd=$(observation_command app 'exec sleep 1000')
  : >"$evidence/positive-$round.yaml"
  for runtime in runc cube; do
    if test "$runtime" = cube; then runtime_class='  runtimeClassName: cube'; else runtime_class=''; fi
    cat >>"$evidence/positive-$round.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s33b-$runtime-merge
  labels: {cubesandbox.io/s33b-owned: "true", cubesandbox.io/s33b-round: "$round"}
spec:
$runtime_class
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    supplementalGroups: [4000]
    fsGroup: 2000
    supplementalGroupsPolicy: Merge
  containers:
  - name: app
    image: $image
    command:
    - sh
    - -c
    - |
      $merge_cmd
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s33b-$runtime-strict
  labels: {cubesandbox.io/s33b-owned: "true", cubesandbox.io/s33b-round: "$round"}
spec:
$runtime_class
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    supplementalGroups: [4000]
    fsGroup: 2000
    supplementalGroupsPolicy: Strict
  containers:
  - name: app
    image: $image
    command:
    - sh
    - -c
    - |
      $strict_cmd
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s33b-$runtime-multi
  labels: {cubesandbox.io/s33b-owned: "true", cubesandbox.io/s33b-round: "$round"}
spec:
$runtime_class
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    supplementalGroups: [4000]
    fsGroup: 2000
    supplementalGroupsPolicy: Strict
  initContainers:
  - name: init
    image: $image
    command:
    - sh
    - -c
    - |
      $init_cmd
    securityContext: {runAsUser: 1100, runAsGroup: 3100}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  - name: sidecar
    image: $image
    restartPolicy: Always
    command:
    - sh
    - -c
    - |
      $sidecar_cmd
    securityContext: {runAsUser: 1200, runAsGroup: 3200}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  containers:
  - name: app
    image: $image
    command:
    - sh
    - -c
    - |
      $app_cmd
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
EOF
  done
}

write_negative_yaml() {
  local runtime runtime_class
  : >"$evidence/negative.yaml"
  for runtime in runc cube; do
    if test "$runtime" = cube; then runtime_class='  runtimeClassName: cube'; else runtime_class=''; fi
    cat >>"$evidence/negative.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s33b-$runtime-negative
  labels: {cubesandbox.io/s33b-owned: "true"}
spec:
$runtime_class
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", "printf 'GUEST_STARTED=1\\n' | tee /evidence/app.txt; exec sleep 1000"]
    securityContext: {runAsNonRoot: true, runAsUser: 0}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
EOF
  done
}

run_positive_round() {
  local round=$1 runtime case_name container_name pod uid sandbox tag pod_file exec_file groups
  local round_leases_before round_leases_after
  round_leases_before=$(lease_records)
  write_positive_yaml "$round"
  "${kube[@]}" create -f "$evidence/positive-$round.yaml" >"$evidence/create-positive-$round.txt"

  for pod in "${positive_pods[@]}"; do
    uid=$(pod_uid "$pod")
    test -n "$uid"
    append_pod_uid "$uid"
  done
  for pod in "${positive_pods[@]}"; do
    "${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=300s \
      >"$evidence/wait-$round-$pod.txt"
  done

  for runtime in runc cube; do
    for case_name in merge strict multi; do
      pod=cubesandbox-s33b-$runtime-$case_name
      uid=$(pod_uid "$pod")
      pod_file=$evidence/pod-$round-$runtime-$case_name.json
      "${kube[@]}" get pod "$pod" -o json >"$pod_file"
      test "$(jq -r '.metadata.uid' "$pod_file")" = "$uid"
      test "$(jq -r '.metadata.labels["cubesandbox.io/s33b-round"]' "$pod_file")" = "$round"
      test "$(jq -r '([.spec.containers[].image] + [.spec.initContainers[]?.image]) | unique | .[]' "$pod_file")" = "$image"
      if test "$runtime" = cube; then
        test "$(jq -r '.spec.runtimeClassName' "$pod_file")" = cube
        sandbox=$(sandbox_for_uid_optional "$uid")
        test -n "$sandbox"
        append_cube_sandbox "$round" "$pod" "$sandbox"
        test -d "$vm_runtime/$sandbox"
      else
        test "$(jq -r '.spec.runtimeClassName // ""' "$pod_file")" = ""
      fi
      sandbox=$(sandbox_for_uid_optional "$uid")
      test -n "$sandbox"
      if test "$case_name" = multi; then
        test "$(container_count_for_uid "$uid")" -eq 3
        for container_name in init sidecar app; do
          capture_container_input "$round" "$runtime" "$case_name" "$container_name" "$uid"
          capture_observation "$round" "$runtime" "$case_name" "$container_name" "$uid"
          test "$(jq -r '.info.sandboxID' "$evidence/cri-$round-$runtime-$case_name-$container_name.json")" = "$sandbox"
        done
        jq -e '.status.state == "CONTAINER_EXITED" and .status.exitCode == 0' \
          "$evidence/cri-$round-$runtime-multi-init.json" >/dev/null
        jq -e '.status.state == "CONTAINER_RUNNING"' "$evidence/cri-$round-$runtime-multi-sidecar.json" >/dev/null
        jq -e '.status.state == "CONTAINER_RUNNING"' "$evidence/cri-$round-$runtime-multi-app.json" >/dev/null
      else
        test "$(container_count_for_uid "$uid")" -eq 1
        capture_container_input "$round" "$runtime" "$case_name" app "$uid"
        capture_observation "$round" "$runtime" "$case_name" app "$uid"
        jq -e '.status.state == "CONTAINER_RUNNING"' "$evidence/cri-$round-$runtime-$case_name-app.json" >/dev/null
      fi
    done
  done

  for case_name in merge strict; do
    if test "$case_name" = merge; then groups=2000,3000,4000,50000; else groups=2000,3000,4000; fi
    for runtime in runc cube; do
      tag=$round-$runtime-$case_name-app
      assert_host_user "$evidence/host-user-cri-$tag.json" 1000 3000 "$groups"
      assert_observation "$evidence/observation-$tag.txt" 1000 3000 "$groups"
      assert_status_user "$evidence/pod-$round-$runtime-$case_name.json" app app 1000 3000 "$groups"
    done
    cmp "$evidence/host-user-cri-$round-runc-$case_name-app.json" \
      "$evidence/host-user-cri-$round-cube-$case_name-app.json"
    cmp "$evidence/observation-$round-runc-$case_name-app.txt" \
      "$evidence/observation-$round-cube-$case_name-app.txt"
  done

  for runtime in runc cube; do
    assert_host_user "$evidence/host-user-cri-$round-$runtime-multi-init.json" 1100 3100 2000,3100,4000
    assert_host_user "$evidence/host-user-cri-$round-$runtime-multi-sidecar.json" 1200 3200 2000,3200,4000
    assert_host_user "$evidence/host-user-cri-$round-$runtime-multi-app.json" 1000 3000 2000,3000,4000
    assert_observation "$evidence/observation-$round-$runtime-multi-init.txt" 1100 3100 2000,3100,4000
    assert_observation "$evidence/observation-$round-$runtime-multi-sidecar.txt" 1200 3200 2000,3200,4000
    assert_observation "$evidence/observation-$round-$runtime-multi-app.txt" 1000 3000 2000,3000,4000
    assert_status_user "$evidence/pod-$round-$runtime-multi.json" init init 1100 3100 2000,3100,4000
    assert_status_user "$evidence/pod-$round-$runtime-multi.json" init sidecar 1200 3200 2000,3200,4000
    assert_status_user "$evidence/pod-$round-$runtime-multi.json" app app 1000 3000 2000,3000,4000

    exec_file=$evidence/exec-$round-$runtime-multi-app.txt
    "${kube[@]}" exec "cubesandbox-s33b-$runtime-multi" -c app -- sh -c \
      'printf "UID=%s\nGID=%s\nGROUPS=%s\n" "$(id -u)" "$(id -g)" "$(id -G)"' >"$exec_file"
    test "$(field_value "$exec_file" UID)" -eq 1000
    test "$(field_value "$exec_file" GID)" -eq 3000
    test "$(sorted_groups "$exec_file")" = 2000,3000,4000
  done

  for container_name in init sidecar app; do
    cmp "$evidence/host-user-cri-$round-runc-multi-$container_name.json" \
      "$evidence/host-user-cri-$round-cube-multi-$container_name.json"
    cmp "$evidence/observation-$round-runc-multi-$container_name.txt" \
      "$evidence/observation-$round-cube-multi-$container_name.txt"
  done
  cmp "$evidence/exec-$round-runc-multi-app.txt" "$evidence/exec-$round-cube-multi-app.txt"

  "${kube[@]}" exec cubesandbox-s33b-runc-merge -c app -- cat /etc/passwd \
    >"$evidence/image-passwd-full-$round.txt"
  "${kube[@]}" exec cubesandbox-s33b-runc-merge -c app -- cat /etc/group \
    >"$evidence/image-group-full-$round.txt"
  grep -Fx 'user-defined-in-image:x:1000:1000:Linux User,,,:/home/user-defined-in-image:/bin/ash' \
    "$evidence/image-passwd-full-$round.txt" \
    >"$evidence/image-passwd-$round.txt"
  grep -Fx 'group-defined-in-image:x:50000:user-defined-in-image' "$evidence/image-group-full-$round.txt" \
    >"$evidence/image-group-$round.txt"

  delete_owned_pods
  wait_pod_dirs_absent
  fixed_pods_absent
  assert_baseline "$round-after"
  round_leases_after=$(lease_records)
  test "$((round_leases_after - round_leases_before))" -eq 3
  printf '%s\t%s\n' "$round" "$round_leases_after" >>"$evidence/lease-counts.tsv"
}

run_negative() {
  local runtime pod uid reason sandbox guest_file logs_rc
  local negative_leases_before negative_leases_after negative_cube_sandboxes=0
  local cri_containers_file cri_pods_file ctr_records_file
  negative_leases_before=$(lease_records)
  write_negative_yaml
  "${kube[@]}" create -f "$evidence/negative.yaml" >"$evidence/create-negative.txt"
  for pod in "${negative_pods[@]}"; do
    uid=$(pod_uid "$pod")
    test -n "$uid"
    append_pod_uid "$uid"
  done
  for runtime in runc cube; do
    pod=cubesandbox-s33b-$runtime-negative
    uid=$(pod_uid "$pod")
    for _ in $(seq 1 1200); do
      reason=$("${kube[@]}" get pod "$pod" -o jsonpath='{.status.containerStatuses[?(@.name=="app")].state.waiting.reason}')
      test "$reason" = CreateContainerConfigError && break
      sleep .1
    done
    test "$reason" = CreateContainerConfigError
    "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-negative-$runtime.json"
    jq -e '.status.containerStatuses | length == 1 and .[0].name == "app" and .[0].state.waiting.reason == "CreateContainerConfigError"' \
      "$evidence/pod-negative-$runtime.json" >/dev/null
    cri_containers_file=$evidence/cri-containers-negative-$runtime.json
    "${cri[@]}" ps -a -o json >"$cri_containers_file"
    test "$(jq -r --arg uid "$uid" '[.containers[]? | select(.labels["io.kubernetes.pod.uid"] == $uid)] | length' \
      "$cri_containers_file")" -eq 0
    cri_pods_file=$evidence/cri-pods-negative-$runtime.json
    "${cri[@]}" pods -o json >"$cri_pods_file"
    sandbox=$(sandbox_for_uid_in_file_optional "$cri_pods_file" "$uid")
    ctr_records_file=$evidence/ctr-records-negative-$runtime.json
    capture_ctr_records_for_uid "$ctr_records_file" "$uid"
    jq -e 'all(.[]; (.Labels["io.cri-containerd.kind"] // .labels["io.cri-containerd.kind"] // "") as $kind
      | ($kind == "sandbox" or $kind == "container"))' \
      "$ctr_records_file" >/dev/null
    test "$(jq '[.[] | select((.Labels["io.cri-containerd.kind"] // .labels["io.cri-containerd.kind"]) == "container")] | length' \
      "$ctr_records_file")" -eq 0
    if test -n "$sandbox"; then
      if test "$runtime" = cube; then
        test "$(jq 'length' "$ctr_records_file")" -eq 0
        "${ctr[@]}" sandboxes info "$sandbox" >"$evidence/ctr-sandbox-negative-cube.json"
        jq -e --arg sandbox "$sandbox" \
          '(.ID == $sandbox) and
           (.Sandboxer == "shim") and
           (.Runtime.Name == "io.containerd.cube.rs")' \
          "$evidence/ctr-sandbox-negative-cube.json" >/dev/null
      else
        jq -e --arg sandbox "$sandbox" \
          'length == 1 and
           ((.[0].ID // .[0].id) == $sandbox) and
           ((.[0].Labels["io.cri-containerd.kind"] // .[0].labels["io.cri-containerd.kind"]) == "sandbox") and
           ((.[0].Runtime.Name // .[0].runtime.name) == "io.containerd.runc.v2")' \
          "$ctr_records_file" >/dev/null
      fi
    else
      test "$(jq 'length' "$ctr_records_file")" -eq 0
    fi
    guest_file=$(host_evidence_dir "$uid")/app.txt
    test ! -e "$guest_file"
    if "${kube[@]}" logs "$pod" -c app >"$evidence/log-negative-$runtime.txt" 2>"$evidence/log-negative-$runtime.stderr"; then
      logs_rc=0
    else
      logs_rc=$?
    fi
    printf '%s\n' "$logs_rc" >"$evidence/log-negative-$runtime.rc"
    test "$logs_rc" -ne 0
    test ! -s "$evidence/log-negative-$runtime.txt"
    printf '%s\t%s\t%s\n' "$runtime" "$uid" "${sandbox:-NONE}" >>"$evidence/negative-sandboxes.tsv"
    if test -n "$sandbox"; then
      "${cri[@]}" inspectp "$sandbox" >"$evidence/cri-sandbox-negative-$runtime.json"
      test "$(jq -r '.status.labels["io.kubernetes.pod.uid"]' "$evidence/cri-sandbox-negative-$runtime.json")" = "$uid"
    fi
    if test "$runtime" = cube && test -n "$sandbox"; then
      append_cube_sandbox negative "$pod" "$sandbox"
      negative_cube_sandboxes=1
    fi
  done
  delete_owned_pods
  wait_pod_dirs_absent
  fixed_pods_absent
  assert_baseline negative-after
  negative_leases_after=$(lease_records)
  test "$((negative_leases_after - negative_leases_before))" -eq "$negative_cube_sandboxes"
  printf 'negative\t%s\n' "$negative_leases_after" >>"$evidence/lease-counts.tsv"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

fixed_pods_absent
wait_runtime_idle
test "$(sha256sum "$shim" | awk '{print $1}')" = "$shim_sha"
test "$(sha256sum "$agent" | awk '{print $1}')" = "$agent_sha"
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.features.supplementalGroupsPolicy}')" = true
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
test -c /dev/kvm
"${kube[@]}" version -o json >"$evidence/kubernetes-version.json"
containerd --version >"$evidence/containerd-version.txt"
uname -srmo >"$evidence/kernel.txt"
test "$(jq -r '.serverVersion.minor | sub("\\+.*$"; "")' "$evidence/kubernetes-version.json")" -ge 36
grep -F 'containerd github.com/containerd/containerd/v2 v2.3.4' "$evidence/containerd-version.txt" >/dev/null
"${cri[@]}" inspecti "$image" >"$evidence/image.json"
jq -e --arg image "$image" '.status.repoDigests | index($image) != null' "$evidence/image.json" >/dev/null

printf 'runtime_implementation_commit=%s\nidentity_source_sha256=%s\nunit_invocation=%s\nshim_sha256=%s\nagent_sha256=%s\nimage=%s\nimage_uid=1000\nimage_implicit_gid=50000\nnode_supplemental_groups_policy=true\nnegative_layer=KUBELET_PRE_RUNTIME\n' \
  "$runtime_implementation_commit" "$identity_source_sha" "$unit_invocation" "$shim_sha" "$agent_sha" "$image" \
  >"$evidence/input-fingerprint.txt"

capture_state before
baseline_captured=true
grep -Fx 'adapter=0 shared=0 reaper=0 cleanup=0 mounts=0 active_leases=0' \
  "$evidence/runtime-resources-before.txt" >/dev/null
leases_before=$(lease_records)
printf 'point\tlease_records\n' >"$evidence/lease-counts.tsv"
printf 'before\t%s\n' "$leases_before" >>"$evidence/lease-counts.tsv"
printf 'round\tpod\tsandbox_id\n' >"$evidence/cube-sandboxes.tsv"
printf 'runtime\tpod_uid\tsandbox_id\n' >"$evidence/negative-sandboxes.tsv"

run_positive_round round1
run_positive_round round2
run_negative

test "${#pod_uids[@]}" -eq 14
test "$(printf '%s\n' "${pod_uids[@]}" | sort -u | wc -l)" -eq 14
test "$(awk -F '\t' '$1 == "round1" {n++} END {print n+0}' "$evidence/cube-sandboxes.tsv")" -eq 3
test "$(awk -F '\t' '$1 == "round2" {n++} END {print n+0}' "$evidence/cube-sandboxes.tsv")" -eq 3
cube_sandbox_count=${#cube_sandboxes[@]}
test "$cube_sandbox_count" -ge 6
test "$cube_sandbox_count" -le 7
test "$(tail -n +2 "$evidence/cube-sandboxes.tsv" | cut -f3 | sort -u | wc -l)" -eq "$cube_sandbox_count"

leases_after=$(lease_records)
lease_delta=$((leases_after - leases_before))
test "$lease_delta" -eq "$cube_sandbox_count"
test "$(awk -F '\t' '$1 == "negative" {print $2}' "$evidence/lease-counts.tsv")" -eq "$leases_after"
for sandbox in "${cube_sandboxes[@]}"; do
  test "$(lease_count_for_sandbox "$sandbox" false)" -eq 1
  test "$(lease_count_for_sandbox "$sandbox" true)" -eq 1
done
test "$(active_leases)" -eq 0

printf 'capability\trunc_observation\tcube_observation\tstatus\n' >"$evidence/support-matrix.tsv"
printf 'merge-image-groups\t2000,3000,4000,50000\t2000,3000,4000,50000\tSUPPORTED_POC\n' >>"$evidence/support-matrix.tsv"
printf 'strict-explicit-groups\t2000,3000,4000\t2000,3000,4000\tSUPPORTED_POC\n' >>"$evidence/support-matrix.tsv"
printf 'fsgroup-emptydir\tgid=2000,write=ok\tgid=2000,write=ok\tSUPPORTED_POC\n' >>"$evidence/support-matrix.tsv"
printf 'pod-identity-inheritance\tuid=1000,gid=3000\tuid=1000,gid=3000\tSUPPORTED_POC\n' >>"$evidence/support-matrix.tsv"
printf 'container-identity-override\tinit=1100:3100,sidecar=1200:3200\tinit=1100:3100,sidecar=1200:3200\tSUPPORTED_POC\n' >>"$evidence/support-matrix.tsv"
printf 'classic-init-and-restartable-sidecar\tthree-container-ids,one-sandbox\tthree-container-ids,one-sandbox-one-vm\tSUPPORTED_POC\n' >>"$evidence/support-matrix.tsv"
printf 'non-tty-exec-identity\t1000:3000:2000,3000,4000\t1000:3000:2000,3000,4000\tSUPPORTED_POC\n' >>"$evidence/support-matrix.tsv"
printf 'run-as-non-root-with-uid-zero\tCreateContainerConfigError\tCreateContainerConfigError\tKUBELET_PRE_RUNTIME\n' >>"$evidence/support-matrix.tsv"
test "$(wc -l <"$evidence/support-matrix.tsv")" -eq 9

fixed_pods_absent
wait_runtime_idle
capture_state final
state_matches_baseline final
test "$(active_leases)" -eq 0
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False
test ! -e "$evidence/trace.log"

printf 'S33B_IDENTITY_OK rounds=2 pod_uids=14 positive_cube_sandboxes=6 negative_layer=KUBELET_PRE_RUNTIME merge_groups=2000,3000,4000,50000 strict_groups=2000,3000,4000 fsgroup=2000 multi_container=init-sidecar-app exec=non-tty exact_baseline=restored\n' \
  | tee -a "$evidence/summary.txt"
printf 'S33B_DONE cube_sandboxes=%s durable_tombstone_delta=%s active_leases=0 fixed_pods=absent evidence=%s\n' \
  "$cube_sandbox_count" "$lease_delta" "$evidence" | tee -a "$evidence/summary.txt"
