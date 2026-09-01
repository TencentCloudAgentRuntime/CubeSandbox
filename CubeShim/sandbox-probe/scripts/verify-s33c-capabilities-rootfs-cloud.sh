#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
image=registry.k8s.io/e2e-test-images/agnhost@sha256:2c5b5b056076334e4cf431d964d102e44cbca8f1e6b16ac1e477a0ffbe6caac4
shim=/usr/local/bin/containerd-shim-cube-rs
agent=/data/cubelet/s13-kubernetes/assets/agent
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
vm_runtime=/run/vc/vm
configmap=cubesandbox-s33c-probe
evidence=/data/cubelet/s3.3-evidence/s3.3c-capabilities-rootfs-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
run_token=s33c-$(date -u +%Y%m%d%H%M%S)-$$-$RANDOM
baseline_captured=false
configmap_created=false
configmap_uid=''
uids=()
cube_sandboxes=()
declare -A owned_pod_uids=()
pods=(
  cubesandbox-s33c-runc-preflight cubesandbox-s33c-cube-preflight
  cubesandbox-s33c-runc-drop-all-ro cubesandbox-s33c-cube-drop-all-ro
  cubesandbox-s33c-runc-selective-ro cubesandbox-s33c-cube-selective-ro
  cubesandbox-s33c-runc-boundary-rw cubesandbox-s33c-cube-boundary-rw
  cubesandbox-s33c-runc-multi cubesandbox-s33c-cube-multi
)

count_entries() { if test -d "$1"; then find "$1" -mindepth 1 -printf '.\n' | wc -l; else printf '0\n'; fi; }
lease_records() { find "$runtime_state/leases" -type f -name '*.json' -printf '.\n' | wc -l; }
active_leases() {
  local record count=0 rc
  while IFS= read -r record; do
    test -n "$record" || continue
    if jq -e '.active == null' "$record" >/dev/null; then :; else
      rc=$?; test "$rc" -eq 1 || return 1; count=$((count + 1))
    fi
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print)
  printf '%s\n' "$count"
}
shared_mounts() { findmnt -rn -o TARGET | awk -v root="$shared/" 'index($1,root)==1 {n++} END {print n+0}'; }

capture_state() {
  local tag=$1
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt"
  "${ctr[@]}" sandboxes list | awk 'NR>1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt"
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR>1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt"
  { if test -d /var/run/netns; then find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n'; fi; } | sort >"$evidence/netns-$tag.txt"
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort >"$evidence/cube-shims-$tag.txt"
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P\t%y\n'; fi; } | sort >"$evidence/vm-runtime-$tag.txt"
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s\n' \
    "$(find "$runtime_state/adapter" -type f -printf '.\n' | wc -l)" \
    "$(count_entries "$shared")" "$(count_entries "$reaper")" \
    "$(find /run/containerd -name cube-runtime-resource.json -type f -printf '.\n' | wc -l)" \
    "$(shared_mounts)" "$(active_leases)" >"$evidence/runtime-resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime runtime-resources; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
}

assert_baseline() {
  local tag=$1
  for attempt in $(seq 1 1800); do
    capture_state "$tag"
    if state_matches_baseline "$tag"; then
      printf 'S33C_BASELINE_CLEAN tag=%s attempt=%s leases=%s\n' "$tag" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep .1
  done
  return 1
}

fixed_absent() {
  local pod result
  for pod in "${pods[@]}"; do
    result=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name) || return 1
    test -z "$result" || return 1
  done
}

is_owned() {
  local json
  json=$("${kube[@]}" get pod "$1" -o json)
  test "$(jq -r '.metadata.labels["cubesandbox.io/s33c-owned"] // ""' <<<"$json")" = true &&
    test "$(jq -r '.metadata.labels["cubesandbox.io/s33c-run"] // ""' <<<"$json")" = "$run_token"
}

remember_uid() {
  local uid=$1 existing
  for existing in "${uids[@]}"; do test "$existing" != "$uid" || return 1; done
  uids+=("$uid")
  printf '%s\n' "$uid" >>"$evidence/pod-uids.txt"
}

collect_existing_uids() {
  local pod json uid existing expected_uid failed=0 seen
  for pod in "${pods[@]}"; do
    if ! json=$("${kube[@]}" get pod "$pod" --ignore-not-found -o json); then failed=1; continue; fi
    test -n "$json" || continue
    if test "$(jq -r '.metadata.labels["cubesandbox.io/s33c-owned"] // ""' <<<"$json")" != true ||
      test "$(jq -r '.metadata.labels["cubesandbox.io/s33c-run"] // ""' <<<"$json")" != "$run_token"; then
      failed=1
      continue
    fi
    if ! uid=$(jq -er '.metadata.uid' <<<"$json"); then failed=1; continue; fi
    expected_uid=${owned_pod_uids[$pod]-}
    if test -n "$expected_uid" && test "$expected_uid" != "$uid"; then failed=1; continue; fi
    seen=false
    for existing in "${uids[@]}"; do test "$existing" != "$uid" || { seen=true; break; }; done
    if test "$seen" = false; then remember_uid "$uid" || failed=1; fi
    if test -z "$expected_uid"; then
      owned_pod_uids[$pod]=$uid
    fi
  done
  return "$failed"
}

delete_owned() {
  local pod result current_uid expected_uid failed=0
  for pod in "${pods[@]}"; do
    if ! result=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name); then failed=1; continue; fi
    test -n "$result" || continue
    if test "$result" != "pod/$pod" || ! is_owned "$pod"; then failed=1; continue; fi
    if ! current_uid=$(pod_uid "$pod"); then failed=1; continue; fi
    expected_uid=${owned_pod_uids[$pod]-}
    if test -z "$expected_uid" || test "$current_uid" != "$expected_uid"; then failed=1; continue; fi
    "${kube[@]}" delete pod "$pod" --wait=false >/dev/null || failed=1
  done
  return "$failed"
}

wait_pods_absent() {
  local pod
  for _ in $(seq 1 1800); do
    if fixed_absent; then
      for pod in "${pods[@]}"; do unset 'owned_pod_uids[$pod]'; done
      return 0
    fi
    sleep .1
  done
  return 1
}

wait_uid_dirs_absent() {
  local uid clean
  for _ in $(seq 1 1800); do
    clean=true
    for uid in "${uids[@]}"; do
      if test -e "/var/lib/kubelet/pods/$uid" || test -L "/var/lib/kubelet/pods/$uid"; then clean=false; break; fi
    done
    test "$clean" = true && return 0
    sleep .1
  done
  return 1
}

cleanup() {
  local original_rc=$? cleanup_rc=0 exact=not-captured
  set +e
  collect_existing_uids || cleanup_rc=1
  "${cri[@]}" pods -o json >"$evidence/cri-pods-final.json" 2>&1 || true
  "${cri[@]}" ps -a -o json >"$evidence/cri-containers-final.json" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  delete_owned || cleanup_rc=1
  wait_pods_absent || cleanup_rc=1
  wait_uid_dirs_absent || cleanup_rc=1
  delete_owned_configmap || cleanup_rc=1
  if test "$baseline_captured" = true; then
    if assert_baseline cleanup; then exact=true; else exact=false; cleanup_rc=1; fi
  fi
  fixed_absent || cleanup_rc=1
  test "$(active_leases)" -eq 0 || cleanup_rc=1
  printf 'original_rc=%s cleanup_rc=%s exact_baseline=%s active_leases=%s\n' \
    "$original_rc" "$cleanup_rc" "$exact" "$(active_leases)" >"$evidence/cleanup-result.txt"
  if test "$original_rc" -ne 0; then exit "$original_rc"; fi
  exit "$cleanup_rc"
}

pod_uid() { "${kube[@]}" get pod "$1" -o jsonpath='{.metadata.uid}'; }
evidence_dir() { printf '/var/lib/kubelet/pods/%s/volumes/kubernetes.io~empty-dir/evidence\n' "$1"; }
field() { awk -F= -v key="$2" '$1==key {print $2}' "$1"; }
cap() { awk -v key="$2" '$1==key":" {print $2}' "$1"; }

container_id() {
  local uid=$1 name=$2 ids count
  ids=$("${cri[@]}" ps -a -o json | jq -r --arg uid "$uid" --arg name "$name" '.containers[]? | select(.labels["io.kubernetes.pod.uid"]==$uid and .metadata.name==$name) | .id')
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1
  printf '%s\n' "$ids"
}

sandbox_id() {
  local uid=$1 ids count
  ids=$("${cri[@]}" pods -o json | jq -r --arg uid "$uid" '.items[]? | select(.labels["io.kubernetes.pod.uid"]==$uid) | .id')
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1
  printf '%s\n' "$ids"
}

lease_count_for_sandbox() {
  local sandbox=$1 record count=0 rc
  while IFS= read -r record; do
    test -n "$record" || continue
    test "$(jq -er '.sandboxID' "$record")" = "$sandbox" || continue
    if jq -e '.active == null' "$record" >/dev/null; then count=$((count + 1)); else rc=$?; test "$rc" -eq 1 || return 1; fi
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print)
  printf '%s\n' "$count"
}

record_cube_sandbox() {
  local stage=$1 pod=$2 uid sandbox rc
  uid=$(pod_uid "$pod"); sandbox=$(sandbox_id "$uid")
  if awk -F '\t' -v sandbox="$sandbox" 'NR > 1 && $3 == sandbox {found=1} END {exit !found}' "$evidence/cube-sandboxes.tsv"; then
    return 1
  else
    rc=$?; test "$rc" -eq 1 || return "$rc"
  fi
  cube_sandboxes+=("$sandbox")
  printf '%s\t%s\t%s\n' "$stage" "$pod" "$sandbox" >>"$evidence/cube-sandboxes.tsv"
}

create_probe_configmap() {
  cat >"$evidence/probe.sh" <<'EOF'
    #!/bin/sh
    set -eu
    name=$1
    lifecycle=$2
    out=/evidence/$name.initial
    tmp=$out.tmp.$$
    root_target=/.cubesandbox-s33c-$name
    root_error=/evidence/$name.root-error
    set +e
    { printf 'root-write' >"$root_target"; } 2>"$root_error"
    root_rc=$?
    set -e
    if test "$root_rc" -eq 0; then
      test "$(cat "$root_target")" = root-write
      rm -f "$root_target"
      root_result=RW
    elif grep -Fq 'Read-only file system' "$root_error"; then
      root_result=EROFS
    else
      root_result=FAILED
    fi
    printf 'emptydir-write' >"/evidence/$name.emptydir"
    test "$(cat "/evidence/$name.emptydir")" = emptydir-write
    rm -f "/evidence/$name.emptydir"
    {
      printf 'UID=%s\nGID=%s\n' "$(id -u)" "$(id -g)"
      grep -E '^Cap(Inh|Prm|Eff|Bnd|Amb):' /proc/self/status
      printf 'CAP_LAST_CAP=%s\n' "$(cat /proc/sys/kernel/cap_last_cap)"
      printf 'ROOT_MOUNT_OPTIONS=%s\n' "$(awk '$5=="/" {print $6; exit}' /proc/self/mountinfo)"
      printf 'ROOT_WRITE=%s\nROOT_WRITE_RC=%s\nEMPTYDIR_RW=true\n' "$root_result" "$root_rc"
    } >"$tmp"
    mv "$tmp" "$out"
    cat "$out"
    if test "$lifecycle" = sleep; then exec sleep 1000; fi
EOF
  "${kube[@]}" create configmap "$configmap" \
    --from-file=probe.sh="$evidence/probe.sh" \
    --dry-run=client -o json |
    jq --arg run_token "$run_token" \
      '.metadata.labels = {"cubesandbox.io/s33c-owned":"true", "cubesandbox.io/s33c-run":$run_token}' \
      >"$evidence/configmap-manifest.json"
  "${kube[@]}" create -f "$evidence/configmap-manifest.json" -o json >"$evidence/configmap-created.json"
  configmap_uid=$(jq -er '.metadata.uid' "$evidence/configmap-created.json")
  test -n "$configmap_uid"
  configmap_created=true
}

delete_owned_configmap() {
  local json current_uid
  json=$("${kube[@]}" get configmap "$configmap" --ignore-not-found -o json) || return 1
  if test -z "$json"; then configmap_created=false; return 0; fi
  test "$(jq -r '.metadata.labels["cubesandbox.io/s33c-owned"] // ""' <<<"$json")" = true || return 1
  test "$(jq -r '.metadata.labels["cubesandbox.io/s33c-run"] // ""' <<<"$json")" = "$run_token" || return 1
  current_uid=$(jq -er '.metadata.uid' <<<"$json")
  if test -n "$configmap_uid"; then test "$current_uid" = "$configmap_uid" || return 1; else configmap_uid=$current_uid; fi
  "${kube[@]}" delete configmap "$configmap" --wait=true >/dev/null
  configmap_created=false
}

emit_simple() {
  local runtime=$1 case_name=$2 readonly=$3 add=$4 runtime_line='' add_line=''
  local pod=cubesandbox-s33c-$runtime-$case_name
  test "$runtime" != cube || runtime_line='  runtimeClassName: cube'
  test -z "$add" || add_line="        add: [$add]"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $pod, labels: {cubesandbox.io/s33c-owned: "true", cubesandbox.io/s33c-run: "$run_token"}}
spec:
  nodeName: $node
$runtime_line
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "/probe/probe.sh", "app", "sleep"]
    securityContext:
      runAsUser: 0
      runAsGroup: 0
      readOnlyRootFilesystem: $readonly
      capabilities:
        drop: ["ALL"]
$add_line
    volumeMounts:
    - {name: evidence, mountPath: /evidence}
    - {name: probe, mountPath: /probe, readOnly: true}
  volumes:
  - {name: evidence, emptyDir: {}}
  - {name: probe, configMap: {name: $configmap}}
EOF
}

emit_multi() {
  local runtime=$1 runtime_line=''
  local pod=cubesandbox-s33c-$runtime-multi
  test "$runtime" != cube || runtime_line='  runtimeClassName: cube'
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $pod, labels: {cubesandbox.io/s33c-owned: "true", cubesandbox.io/s33c-run: "$run_token"}}
spec:
  nodeName: $node
$runtime_line
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  initContainers:
  - name: classic-init
    image: $image
    command: ["sh", "/probe/probe.sh", "classic-init", "exit"]
    securityContext: {runAsUser: 0, runAsGroup: 0, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  - name: sidecar
    image: $image
    restartPolicy: Always
    command: ["sh", "/probe/probe.sh", "sidecar", "sleep"]
    securityContext: {runAsUser: 0, runAsGroup: 0, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"], add: ["NET_BIND_SERVICE"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  containers:
  - name: app
    image: $image
    command: ["sh", "/probe/probe.sh", "app", "sleep"]
    securityContext: {runAsUser: 0, runAsGroup: 0, readOnlyRootFilesystem: false, capabilities: {drop: ["ALL"], add: ["NET_RAW"]}}
    volumeMounts: [{name: evidence, mountPath: /evidence}, {name: probe, mountPath: /probe, readOnly: true}]
  volumes:
  - {name: evidence, emptyDir: {}}
  - {name: probe, configMap: {name: $configmap}}
EOF
}

create_stage() {
  local stage=$1 runtime uid result
  local manifest=$evidence/pods-$stage.yaml
  : >"$manifest"
  for runtime in runc cube; do
    if test "$stage" = preflight; then
      emit_simple "$runtime" preflight false '' >>"$manifest"
      printf '%s\n' '---' >>"$manifest"
    else
      emit_simple "$runtime" drop-all-ro true '' >>"$manifest"; printf '%s\n' '---' >>"$manifest"
      emit_simple "$runtime" selective-ro true '"NET_BIND_SERVICE", "NET_RAW"' >>"$manifest"; printf '%s\n' '---' >>"$manifest"
      emit_simple "$runtime" boundary-rw false '"CHECKPOINT_RESTORE"' >>"$manifest"; printf '%s\n' '---' >>"$manifest"
      emit_multi "$runtime" >>"$manifest"; printf '%s\n' '---' >>"$manifest"
    fi
  done
  "${kube[@]}" create -f "$manifest" >"$evidence/create-$stage.txt"
  for pod in "${pods[@]}"; do
    result=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name)
    test -n "$result" || continue
    is_owned "$pod"
    uid=$(pod_uid "$pod")
    remember_uid "$uid"
    owned_pod_uids[$pod]=$uid
  done
  for pod in "${pods[@]}"; do
    test -n "$("${kube[@]}" get pod "$pod" --ignore-not-found -o name)" || continue
    "${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=360s >"$evidence/wait-$stage-$pod.txt"
  done
}

normalize_cri() {
  local input=$1 output=$2 expected_readonly=$3
  jq -e --argjson expected_readonly "$expected_readonly" '
    .info.runtimeSpec.process.capabilities as $caps |
    .info.runtimeSpec.root as $root |
    ($caps | type) == "object" and
    ($root | type) == "object" and
    all(["bounding","effective","inheritable","permitted","ambient"][];
      . as $field | (($caps | has($field) | not) or (($caps[$field] | type) == "array"))) and
    (if ($root | has("readonly")) then
      (($root.readonly | type) == "boolean" and $root.readonly == $expected_readonly)
    else $expected_readonly == false end)
  ' "$input" >/dev/null
  jq -S 'def norm: {bounding:(.bounding//[]|sort),effective:(.effective//[]|sort),inheritable:(.inheritable//[]|sort),permitted:(.permitted//[]|sort),ambient:(.ambient//[]|sort)}; {capabilities:((.info.runtimeSpec.process.capabilities//{})|norm),rootReadonly:(.info.runtimeSpec.root.readonly//false)}' "$input" >"$output"
}
normalize_ctr() {
  local input=$1 output=$2 expected_readonly=$3
  jq -e --argjson expected_readonly "$expected_readonly" '
    .Spec.process.capabilities as $caps |
    .Spec.root as $root |
    ($caps | type) == "object" and
    ($root | type) == "object" and
    all(["bounding","effective","inheritable","permitted","ambient"][];
      . as $field | (($caps | has($field) | not) or (($caps[$field] | type) == "array"))) and
    (if ($root | has("readonly")) then
      (($root.readonly | type) == "boolean" and $root.readonly == $expected_readonly)
    else $expected_readonly == false end)
  ' "$input" >/dev/null
  jq -S 'def norm: {bounding:(.bounding//[]|sort),effective:(.effective//[]|sort),inheritable:(.inheritable//[]|sort),permitted:(.permitted//[]|sort),ambient:(.ambient//[]|sort)}; {capabilities:((.Spec.process.capabilities//{})|norm),rootReadonly:(.Spec.root.readonly//false)}' "$input" >"$output"
}

verify_one() {
  local stage=$1 runtime=$2 case_name=$3 container=$4 mask=$5 readonly=$6 expected_caps=$7
  local pod uid dir obs id status_id ro_value rc
  pod=cubesandbox-s33c-$runtime-$case_name
  uid=$(pod_uid "$pod"); dir=$(evidence_dir "$uid"); obs=$evidence/guest-$stage-$runtime-$case_name-$container.txt
  for _ in $(seq 1 1200); do test -s "$dir/$container.initial" && break; sleep .1; done
  test -s "$dir/$container.initial"; cp "$dir/$container.initial" "$obs"
  test "$(field "$obs" UID)" = 0; test "$(field "$obs" GID)" = 0
  test "$(field "$obs" CAP_LAST_CAP)" -ge 40
  test "$(cap "$obs" CapInh)" = 0000000000000000
  test "$(cap "$obs" CapPrm)" = "$mask"; test "$(cap "$obs" CapEff)" = "$mask"; test "$(cap "$obs" CapBnd)" = "$mask"
  test "$(cap "$obs" CapAmb)" = 0000000000000000
  test "$(field "$obs" EMPTYDIR_RW)" = true
  if test "$readonly" = true; then
    test "$(field "$obs" ROOT_WRITE)" = EROFS
    printf '%s\n' "$(field "$obs" ROOT_MOUNT_OPTIONS)" | tr ',' '\n' | grep -Fxq ro
    grep -Fq 'Read-only file system' "$dir/$container.root-error"
    ro_value=true
  else
    test "$(field "$obs" ROOT_WRITE)" = RW
    test "$(field "$obs" ROOT_WRITE_RC)" = 0
    printf '%s\n' "$(field "$obs" ROOT_MOUNT_OPTIONS)" | tr ',' '\n' | grep -Fxq rw
    ro_value=false
  fi
  id=$(container_id "$uid" "$container")
  if grep -Fxq "$id" "$evidence/container-ids.txt"; then return 1; else rc=$?; test "$rc" -eq 1 || return "$rc"; fi
  printf '%s\n' "$id" >>"$evidence/container-ids.txt"
  "${cri[@]}" inspect "$id" >"$evidence/cri-$stage-$runtime-$case_name-$container.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$stage-$runtime-$case_name-$container.json"
  normalize_cri "$evidence/cri-$stage-$runtime-$case_name-$container.json" "$evidence/input-$stage-$runtime-$case_name-$container-cri.json" "$ro_value"
  normalize_ctr "$evidence/ctr-$stage-$runtime-$case_name-$container.json" "$evidence/input-$stage-$runtime-$case_name-$container-ctr.json" "$ro_value"
  cmp "$evidence/input-$stage-$runtime-$case_name-$container-cri.json" "$evidence/input-$stage-$runtime-$case_name-$container-ctr.json"
  jq -e --argjson caps "$expected_caps" --argjson ro "$ro_value" \
    '.rootReadonly==$ro and .capabilities.bounding==$caps and .capabilities.effective==$caps and .capabilities.permitted==$caps and (.capabilities.inheritable|length)==0 and (.capabilities.ambient|length)==0' \
    "$evidence/input-$stage-$runtime-$case_name-$container-cri.json" >/dev/null
  "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-$stage-$runtime-$case_name.json"
  jq -e --arg name "$container" --argjson caps "$expected_caps" --argjson ro "$ro_value" '
    ([.spec.containers[]?, .spec.initContainers[]?] | map(select(.name==$name)) | .[0].securityContext) as $context |
    ($context.readOnlyRootFilesystem == $ro) and
    ($context.capabilities.drop == ["ALL"]) and
    (($context.capabilities.add // [] | map("CAP_" + .) | sort) == $caps)
  ' "$evidence/pod-$stage-$runtime-$case_name.json" >/dev/null
  status_id=$(jq -r --arg name "$container" '[.status.containerStatuses[]?,.status.initContainerStatuses[]?] | map(select(.name==$name)) | .[0].containerID // "" | sub("^containerd://";"")' "$evidence/pod-$stage-$runtime-$case_name.json")
  test "$status_id" = "$id"
}

verify_exec() {
  local stage=$1 runtime=$2 case_name=$3 mask=$4 readonly=$5 pod file
  pod=cubesandbox-s33c-$runtime-$case_name
  file=$evidence/exec-$stage-$runtime-$case_name.txt
  "${kube[@]}" exec "$pod" -c app -- sh -c '
    grep -E "^Cap(Inh|Prm|Eff|Bnd|Amb):" /proc/self/status
    set +e
    { printf exec > /.cubesandbox-s33c-exec; } 2>/evidence/exec-root-error
    rc=$?
    set -e
    if test "$rc" -eq 0; then test "$(cat /.cubesandbox-s33c-exec)" = exec; rm -f /.cubesandbox-s33c-exec; printf "EXEC_ROOT=RW\n"; elif grep -Fq "Read-only file system" /evidence/exec-root-error; then printf "EXEC_ROOT=EROFS\n"; else exit 91; fi
  ' >"$file"
  test "$(cap "$file" CapPrm)" = "$mask"; test "$(cap "$file" CapEff)" = "$mask"; test "$(cap "$file" CapBnd)" = "$mask"
  test "$(cap "$file" CapInh)" = 0000000000000000; test "$(cap "$file" CapAmb)" = 0000000000000000
  if test "$readonly" = true; then grep -Fxq EXEC_ROOT=EROFS "$file"; else grep -Fxq EXEC_ROOT=RW "$file"; fi
}

verify_round() {
  local round=$1 runtime
  for runtime in runc cube; do
    verify_one "$round" "$runtime" drop-all-ro app 0000000000000000 true '[]'
    verify_one "$round" "$runtime" selective-ro app 0000000000002400 true '["CAP_NET_BIND_SERVICE","CAP_NET_RAW"]'
    verify_one "$round" "$runtime" boundary-rw app 0000010000000000 false '["CAP_CHECKPOINT_RESTORE"]'
    verify_one "$round" "$runtime" multi classic-init 0000000000000000 true '[]'
    verify_one "$round" "$runtime" multi sidecar 0000000000000400 true '["CAP_NET_BIND_SERVICE"]'
    verify_one "$round" "$runtime" multi app 0000000000002000 false '["CAP_NET_RAW"]'
    if test "$runtime" = cube; then
      record_cube_sandbox "$round" cubesandbox-s33c-cube-drop-all-ro
      record_cube_sandbox "$round" cubesandbox-s33c-cube-selective-ro
      record_cube_sandbox "$round" cubesandbox-s33c-cube-boundary-rw
      record_cube_sandbox "$round" cubesandbox-s33c-cube-multi
    fi
  done
  for case_name in drop-all-ro selective-ro boundary-rw; do
    cmp "$evidence/input-$round-runc-$case_name-app-cri.json" "$evidence/input-$round-cube-$case_name-app-cri.json"
  done
  for container in classic-init sidecar app; do cmp "$evidence/input-$round-runc-multi-$container-cri.json" "$evidence/input-$round-cube-multi-$container-cri.json"; done
  if test "$round" = round1; then
    for runtime in runc cube; do
      verify_exec "$round" "$runtime" selective-ro 0000000000002400 true
      verify_exec "$round" "$runtime" boundary-rw 0000010000000000 false
    done
  fi
}

mkdir -p "$evidence"
chmod 0700 "$evidence"
: >"$evidence/pod-uids.txt"
: >"$evidence/container-ids.txt"
printf 'stage\tpod\tsandbox\n' >"$evidence/cube-sandboxes.tsv"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

fixed_absent
test -z "$("${kube[@]}" get configmap "$configmap" --ignore-not-found -o name)"
test "$(active_leases)" -eq 0
test "$(cat /proc/sys/kernel/cap_last_cap)" -ge 40
test -c /dev/kvm
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$("${kube[@]}" get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
"${kube[@]}" version -o json >"$evidence/kubernetes-version.json"
containerd --version >"$evidence/containerd-version.txt"; uname -srmo >"$evidence/kernel.txt"
test "$(jq -r '.serverVersion.minor | sub("\\+.*$";"")' "$evidence/kubernetes-version.json")" -ge 36
"${cri[@]}" pull "$image" >"$evidence/image-pull.txt"
printf 'shim_sha=%s\nagent_sha=%s\nimage=%s\nhost_cap_last_cap=%s\n' \
  "$(sha256sum "$shim" | awk '{print $1}')" "$(sha256sum "$agent" | awk '{print $1}')" "$image" "$(cat /proc/sys/kernel/cap_last_cap)" >"$evidence/input-fingerprint.txt"
capture_state before; baseline_captured=true
leases_before=$(lease_records); printf 'point\tleases\nbefore\t%s\n' "$leases_before" >"$evidence/lease-counts.tsv"
create_probe_configmap

create_stage preflight
for runtime in runc cube; do verify_one preflight "$runtime" preflight app 0000000000000000 false '[]'; done
record_cube_sandbox preflight cubesandbox-s33c-cube-preflight
delete_owned; wait_pods_absent; wait_uid_dirs_absent; assert_baseline after-preflight
leases_preflight=$(lease_records); printf 'after-preflight\t%s\n' "$leases_preflight" >>"$evidence/lease-counts.tsv"
test $((leases_preflight-leases_before)) -eq 1

for round in round1 round2; do
  create_stage "$round"
  verify_round "$round"
  delete_owned; wait_pods_absent; wait_uid_dirs_absent; assert_baseline "after-$round"
  current_leases=$(lease_records); printf 'after-%s\t%s\n' "$round" "$current_leases" >>"$evidence/lease-counts.tsv"
done

leases_after=$(lease_records)
test $((leases_after-leases_before)) -eq 9
test "$(sort -u "$evidence/pod-uids.txt" | wc -l)" -eq 18
test "$(sort -u "$evidence/container-ids.txt" | wc -l)" -eq 26
test "$(tail -n +2 "$evidence/cube-sandboxes.tsv" | cut -f3 | sort -u | wc -l)" -eq 9
for sandbox in "${cube_sandboxes[@]}"; do test "$(lease_count_for_sandbox "$sandbox")" -eq 1; done
test "$(active_leases)" -eq 0
delete_owned_configmap
test ! -e "$evidence/trace.log"
printf 'S33C_CAPABILITIES_ROOTFS_OK rounds=2 preflight=host-runc-cube cap_last_cap_gte_40=true positive_pods=18 containers=26 cube_sandboxes=9 masks=0,0x400,0x2000,0x2400,0x10000000000 readonly_rootfs=EROFS writable_rootfs=RW emptydir=RW exec=non-tty raw_cri_ctr=set-equal exact_baseline=all-checkpoints active_leases=0 evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
