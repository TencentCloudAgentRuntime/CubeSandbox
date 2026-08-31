#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
image=docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
shim=/usr/local/bin/containerd-shim-cube-rs
shim_sha=4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14
agent=/data/cubelet/s13-kubernetes/assets/agent
agent_sha=b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9
implementation_commit=83902212a85158c8c5fd947e8b06a661f0e1075c
container_source_blob=ef43d552feb26e54aa12a625822dba6a6e382a7c
container_source_sha=c08cd3854b085ce94404bc47323d15e40a6e6c16c9b41ac0e0d5a6bf8a6d8a27
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s3.3-evidence/s3.3a-security-context-diagnostic-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
pods=(
  cubesandbox-s33a-runc-uidgid cubesandbox-s33a-cube-uidgid
  cubesandbox-s33a-runc-groups cubesandbox-s33a-cube-groups
  cubesandbox-s33a-runc-cap-ro cubesandbox-s33a-cube-cap-ro
  cubesandbox-s33a-runc-nnp-seccomp cubesandbox-s33a-cube-nnp-seccomp
)
cube_pods=(
  cubesandbox-s33a-cube-uidgid cubesandbox-s33a-cube-groups
  cubesandbox-s33a-cube-cap-ro cubesandbox-s33a-cube-nnp-seccomp
)
pod_uids=()
cube_sandboxes=()
baseline_captured=false

count_entries() { if test -d "$1"; then find "$1" -mindepth 1 -printf '.\n' | wc -l; else echo 0; fi; }
count_files() { if test -d "$1"; then find "$1" -type f -printf '.\n' | wc -l; else echo 0; fi; }
lease_records() { find "$runtime_state/leases" -type f -name '*.json' -printf '.\n' | wc -l; }
cleanup_records() { find "$containerd_state" -name cube-runtime-resource.json -type f -printf '.\n' | wc -l; }
active_leases() {
  local count=0 record records jq_rc
  records=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    if jq -e '.active == null' "$record" >/dev/null; then
      :
    else
      jq_rc=$?
      test "$jq_rc" -eq 1 || return 1
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
  local tag=$1 attempt kind leases
  for attempt in $(seq 1 1800); do
    capture_state "$tag" || return 1
    if state_matches_baseline "$tag"; then
      leases=$(lease_records) || return 1
      printf 'S33A_BASELINE_CLEAN tag=%s wait_attempt=%s lease_records=%s\n' \
        "$tag" "$attempt" "$leases" | tee -a "$evidence/summary.txt" || return 1
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
  label=$("${kube[@]}" get pod "$1" -o jsonpath='{.metadata.labels.cubesandbox\.io/s33a-owned}') || return 1
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
      "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null || return 1
    fi
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
  local pod result uid
  for pod in "${pods[@]}"; do
    result=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name) || return 1
    test -z "$result" && continue
    test "$result" = "pod/$pod" || return 1
    is_owned "$pod" || return 1
    uid=$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.uid}') || return 1
    append_pod_uid "$uid" || return 1
  done
}

wait_known_pod_dirs_absent() {
  local uid attempt all_absent
  for attempt in $(seq 1 1800); do
    all_absent=true
    for uid in "${pod_uids[@]}"; do
      if test -e "/var/lib/kubelet/pods/$uid" || test -L "/var/lib/kubelet/pods/$uid"; then
        all_absent=false
        break
      fi
    done
    test "$all_absent" = true && return 0
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
  local rc=$? cleanup_rc=0 fixed_ok=false dirs_ok=false idle_ok=false baseline_ok=not-captured active_ok=false active_count
  set +e
  save_diagnostics
  if ! collect_existing_owned_uids; then cleanup_rc=1; fi
  if ! delete_owned_pods; then cleanup_rc=1; fi
  if wait_known_pod_dirs_absent; then dirs_ok=true; else cleanup_rc=1; fi
  if wait_runtime_idle; then idle_ok=true; else cleanup_rc=1; fi
  if test "$baseline_captured" = true; then
    if assert_baseline cleanup; then baseline_ok=true; else baseline_ok=false; cleanup_rc=1; fi
  fi
  if fixed_pods_absent; then fixed_ok=true; else cleanup_rc=1; fi
  if active_count=$(active_leases) && test "$active_count" -eq 0; then active_ok=true; else cleanup_rc=1; fi
  printf 'original_rc=%s cleanup_rc=%s fixed_pods_absent=%s pod_dirs_absent=%s runtime_idle=%s exact_baseline=%s active_leases_zero=%s\n' \
    "$rc" "$cleanup_rc" "$fixed_ok" "$dirs_ok" "$idle_ok" "$baseline_ok" "$active_ok" \
    >"$evidence/cleanup-result.txt"
  test "$rc" -ne 0 && exit "$rc"
  exit "$cleanup_rc"
}

pod_uid() { "${kube[@]}" get pod "$1" -o jsonpath='{.metadata.uid}'; }

sandbox_for_uid() {
  local ids count
  ids=$("${cri[@]}" pods -o json | jq -r --arg uid "$1" '.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id') || return 1
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1 || return 1
  printf '%s\n' "$ids"
}

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

capture_host_pre_shim_input() {
  local tag=$1 pod=$2 uid id
  "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-$tag.json"
  uid=$(jq -r '.metadata.uid' "$evidence/pod-$tag.json")
  id=$(wait_container_for_uid "$uid")
  "${cri[@]}" inspect "$id" >"$evidence/cri-$tag.json"
  "${ctr[@]}" containers info "$id" >"$evidence/ctr-$tag.json"
  jq -S '{layer:"host-pre-shim-input",processUser:(.info.runtimeSpec.process.user // {}),capabilities:(.info.runtimeSpec.process.capabilities // {}),noNewPrivileges:(.info.runtimeSpec.process.noNewPrivileges // false),rootReadonly:(.info.runtimeSpec.root.readonly // false),seccomp:(.info.runtimeSpec.linux.seccomp // null)}' \
    "$evidence/cri-$tag.json" >"$evidence/host-pre-shim-cri-$tag.json"
  jq -S '{layer:"host-pre-shim-input",processUser:(.Spec.process.user // {}),capabilities:(.Spec.process.capabilities // {}),noNewPrivileges:(.Spec.process.noNewPrivileges // false),rootReadonly:(.Spec.root.readonly // false),seccomp:(.Spec.linux.seccomp // null)}' \
    "$evidence/ctr-$tag.json" >"$evidence/host-pre-shim-ctr-$tag.json"
  cmp "$evidence/host-pre-shim-cri-$tag.json" "$evidence/host-pre-shim-ctr-$tag.json"
}

wait_ready() { "${kube[@]}" wait --for=condition=Ready "pod/$1" --timeout=300s >"$evidence/wait-$1.txt"; }

host_evidence_dir() {
  printf '/var/lib/kubelet/pods/%s/volumes/kubernetes.io~empty-dir/evidence\n' "$1"
}

capture_init_observation() {
  local tag=$1 pod=$2 uid dir line
  uid=$(pod_uid "$pod")
  dir=$(host_evidence_dir "$uid")
  for _ in $(seq 1 600); do test -s "$dir/observed.txt" && break; sleep .1; done
  test -s "$dir/observed.txt"
  cp "$dir/observed.txt" "$evidence/init-$tag.txt"
  test "$(grep -Fc 'INIT_RAN=1' "$evidence/init-$tag.txt")" -eq 1
  for _ in $(seq 1 300); do
    "${kube[@]}" logs "$pod" -c app >"$evidence/log-$tag.txt" 2>"$evidence/log-$tag.stderr" || true
    grep -Fq 'INIT_RAN=1' "$evidence/log-$tag.txt" && break
    sleep .1
  done
  grep -Fq 'INIT_RAN=1' "$evidence/log-$tag.txt"
  while IFS= read -r line; do
    test -n "$line" || continue
    grep -Fxq "$line" "$evidence/log-$tag.txt"
  done <"$evidence/init-$tag.txt"
}

field_value() { awk -F= -v key="$2" '$1 == key {print $2}' "$1"; }
cap_value() { awk -v key="$2" '$1 == key":" {print $2}' "$1"; }
lease_record_count_for_sandbox() {
  local sandbox=$1 inactive=$2 records record record_sandbox count=0 jq_rc
  records=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    record_sandbox=$(jq -er '.sandboxID | strings' "$record") || return 1
    test "$record_sandbox" = "$sandbox" || continue
    if test "$inactive" = true; then
      if jq -e '.active == null' "$record" >/dev/null; then
        count=$((count + 1))
      else
        jq_rc=$?
        test "$jq_rc" -eq 1 || return 1
      fi
    else
      count=$((count + 1))
    fi
  done <<<"$records"
  echo "$count"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

fixed_pods_absent
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
printf 'implementation_commit=%s\ncontainer_source_blob=%s\ncontainer_source_sha256=%s\nshim_sha256=%s\nagent_sha256=%s\nimage=%s\noci_layer=host-pre-shim-input\nshim_mutation=set_noNewPrivileges_false\n' \
  "$implementation_commit" "$container_source_blob" "$container_source_sha" "$shim_sha" "$agent_sha" "$image" \
  >"$evidence/input-fingerprint.txt"
"${cri[@]}" pull "$image" >"$evidence/image-pull.txt"
capture_state before
baseline_captured=true
leases_before=$(lease_records)
printf 'point\tlease_records\n' >"$evidence/lease-counts.tsv"
printf 'before\t%s\n' "$leases_before" >>"$evidence/lease-counts.tsv"

cat >"$evidence/pods.yaml" <<PODS_EOF
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33a-runc-uidgid, labels: {cubesandbox.io/s33a-owned: "true"}}
spec:
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'printf "INIT_RAN=1\\nUID=%s\\nGID=%s\\nGROUPS=%s\\n" "\$(id -u)" "\$(id -g)" "\$(id -G)" | tee /evidence/observed.txt; exec sleep 1000']
    securityContext: {runAsUser: 1234, runAsGroup: 2345}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33a-cube-uidgid, labels: {cubesandbox.io/s33a-owned: "true"}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'printf "INIT_RAN=1\\nUID=%s\\nGID=%s\\nGROUPS=%s\\n" "\$(id -u)" "\$(id -g)" "\$(id -G)" | tee /evidence/observed.txt; exec sleep 1000']
    securityContext: {runAsUser: 1234, runAsGroup: 2345}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33a-runc-groups, labels: {cubesandbox.io/s33a-owned: "true"}}
spec:
  nodeName: $node
  securityContext: {supplementalGroups: [3456, 4567]}
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'printf "INIT_RAN=1\\nUID=%s\\nGID=%s\\nGROUPS=%s\\n" "\$(id -u)" "\$(id -g)" "\$(id -G)" | tee /evidence/observed.txt; exec sleep 1000']
    securityContext: {runAsUser: 1234, runAsGroup: 2345}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33a-cube-groups, labels: {cubesandbox.io/s33a-owned: "true"}}
spec:
  runtimeClassName: cube
  nodeName: $node
  securityContext: {supplementalGroups: [3456, 4567]}
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'printf "INIT_RAN=1\\nUID=%s\\nGID=%s\\nGROUPS=%s\\n" "\$(id -u)" "\$(id -g)" "\$(id -G)" | tee /evidence/observed.txt; exec sleep 1000']
    securityContext: {runAsUser: 1234, runAsGroup: 2345}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33a-runc-cap-ro, labels: {cubesandbox.io/s33a-owned: "true"}}
spec:
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command:
    - sh
    - -c
    - 'printf "INIT_RAN=1\\n" > /evidence/observed.txt; grep -E "^Cap(Inh|Prm|Eff|Bnd|Amb):" /proc/self/status | tee -a /evidence/observed.txt; if touch /s33a-write-probe 2>/evidence/root-write.stderr; then printf "ROOT_WRITE=SUCCESS\\n" | tee -a /evidence/observed.txt; else rc=\$?; if grep -Fq "Read-only file system" /evidence/root-write.stderr; then printf "ROOT_WRITE=EROFS\\n" | tee -a /evidence/observed.txt; else printf "ROOT_WRITE=FAILED:%s\\n" "\$rc" | tee -a /evidence/observed.txt; fi; fi; cat /evidence/observed.txt; exec sleep 1000'
    securityContext:
      capabilities: {drop: ["ALL"], add: ["NET_RAW"]}
      readOnlyRootFilesystem: true
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33a-cube-cap-ro, labels: {cubesandbox.io/s33a-owned: "true"}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command:
    - sh
    - -c
    - 'printf "INIT_RAN=1\\n" > /evidence/observed.txt; grep -E "^Cap(Inh|Prm|Eff|Bnd|Amb):" /proc/self/status | tee -a /evidence/observed.txt; if touch /s33a-write-probe 2>/evidence/root-write.stderr; then printf "ROOT_WRITE=SUCCESS\\n" | tee -a /evidence/observed.txt; else rc=\$?; if grep -Fq "Read-only file system" /evidence/root-write.stderr; then printf "ROOT_WRITE=EROFS\\n" | tee -a /evidence/observed.txt; else printf "ROOT_WRITE=FAILED:%s\\n" "\$rc" | tee -a /evidence/observed.txt; fi; fi; cat /evidence/observed.txt; exec sleep 1000'
    securityContext:
      capabilities: {drop: ["ALL"], add: ["NET_RAW"]}
      readOnlyRootFilesystem: true
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33a-runc-nnp-seccomp, labels: {cubesandbox.io/s33a-owned: "true"}}
spec:
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'printf "INIT_RAN=1\\n" > /evidence/observed.txt; grep -E "^(NoNewPrivs|Seccomp|Seccomp_filters):" /proc/self/status | tee -a /evidence/observed.txt; cat /evidence/observed.txt; exec sleep 1000']
    securityContext:
      allowPrivilegeEscalation: false
      seccompProfile: {type: RuntimeDefault}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: cubesandbox-s33a-cube-nnp-seccomp, labels: {cubesandbox.io/s33a-owned: "true"}}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: app
    image: $image
    command: ["sh", "-c", 'printf "INIT_RAN=1\\n" > /evidence/observed.txt; grep -E "^(NoNewPrivs|Seccomp|Seccomp_filters):" /proc/self/status | tee -a /evidence/observed.txt; cat /evidence/observed.txt; exec sleep 1000']
    securityContext:
      allowPrivilegeEscalation: false
      seccompProfile: {type: RuntimeDefault}
    volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, emptyDir: {}}]
PODS_EOF

"${kube[@]}" create -f "$evidence/pods.yaml" >"$evidence/create-pods.txt"
for pod in "${pods[@]}"; do
  uid=$(pod_uid "$pod")
  test -n "$uid"
  append_pod_uid "$uid"
done

wait_ready cubesandbox-s33a-runc-uidgid
wait_ready cubesandbox-s33a-cube-uidgid
wait_ready cubesandbox-s33a-runc-groups
wait_ready cubesandbox-s33a-cube-groups
wait_ready cubesandbox-s33a-runc-cap-ro
wait_ready cubesandbox-s33a-cube-cap-ro
wait_ready cubesandbox-s33a-runc-nnp-seccomp
wait_ready cubesandbox-s33a-cube-nnp-seccomp

for runtime in runc cube; do
  capture_host_pre_shim_input "$runtime-uidgid" "cubesandbox-s33a-$runtime-uidgid"
  capture_host_pre_shim_input "$runtime-groups" "cubesandbox-s33a-$runtime-groups"
  capture_host_pre_shim_input "$runtime-cap-ro" "cubesandbox-s33a-$runtime-cap-ro"
  capture_host_pre_shim_input "$runtime-nnp-seccomp" "cubesandbox-s33a-$runtime-nnp-seccomp"
done
for case_name in uidgid groups cap-ro nnp-seccomp; do
  cmp "$evidence/host-pre-shim-cri-runc-$case_name.json" "$evidence/host-pre-shim-cri-cube-$case_name.json"
done
jq -e '.processUser.uid == 1234 and .processUser.gid == 2345 and ((.processUser.additionalGids // []) == [2345])' "$evidence/host-pre-shim-cri-runc-uidgid.json" >/dev/null
jq -e '.processUser.uid == 1234 and .processUser.gid == 2345 and ((.processUser.additionalGids // []) | sort == [2345,3456,4567])' "$evidence/host-pre-shim-cri-runc-groups.json" >/dev/null
jq -e '.rootReadonly == true and .capabilities.bounding == ["CAP_NET_RAW"] and .capabilities.effective == ["CAP_NET_RAW"] and .capabilities.permitted == ["CAP_NET_RAW"] and (.capabilities.inheritable | length == 0) and (.capabilities.ambient | length == 0)' "$evidence/host-pre-shim-cri-runc-cap-ro.json" >/dev/null
jq -e '.noNewPrivileges == true and .seccomp != null' "$evidence/host-pre-shim-cri-runc-nnp-seccomp.json" >/dev/null

capture_init_observation runc-uidgid cubesandbox-s33a-runc-uidgid
capture_init_observation cube-uidgid cubesandbox-s33a-cube-uidgid
capture_init_observation runc-groups cubesandbox-s33a-runc-groups
capture_init_observation cube-groups cubesandbox-s33a-cube-groups
capture_init_observation runc-cap-ro cubesandbox-s33a-runc-cap-ro
capture_init_observation cube-cap-ro cubesandbox-s33a-cube-cap-ro
capture_init_observation runc-nnp-seccomp cubesandbox-s33a-runc-nnp-seccomp
capture_init_observation cube-nnp-seccomp cubesandbox-s33a-cube-nnp-seccomp

printf '2345\n' >"$evidence/uidgid-groups-expected.txt"
for runtime in runc cube; do
  test "$(field_value "$evidence/init-$runtime-uidgid.txt" UID)" = 1234
  test "$(field_value "$evidence/init-$runtime-uidgid.txt" GID)" = 2345
  printf '%s\n' "$(field_value "$evidence/init-$runtime-uidgid.txt" GROUPS)" | tr ' ' '\n' | awk 'NF' | sort -n >"$evidence/uidgid-groups-$runtime-sorted.txt"
  cmp "$evidence/uidgid-groups-expected.txt" "$evidence/uidgid-groups-$runtime-sorted.txt"
done
printf '2345\n3456\n4567\n' >"$evidence/groups-expected.txt"
for runtime in runc cube; do
  test "$(field_value "$evidence/init-$runtime-groups.txt" UID)" = 1234
  test "$(field_value "$evidence/init-$runtime-groups.txt" GID)" = 2345
  printf '%s\n' "$(field_value "$evidence/init-$runtime-groups.txt" GROUPS)" | tr ' ' '\n' | awk 'NF' | sort -n >"$evidence/groups-$runtime-sorted.txt"
  cmp "$evidence/groups-expected.txt" "$evidence/groups-$runtime-sorted.txt"
done
for runtime in runc cube; do
  test "$(cap_value "$evidence/init-$runtime-cap-ro.txt" CapInh)" = 0000000000000000
  test "$(cap_value "$evidence/init-$runtime-cap-ro.txt" CapPrm)" = 0000000000002000
  test "$(cap_value "$evidence/init-$runtime-cap-ro.txt" CapEff)" = 0000000000002000
  test "$(cap_value "$evidence/init-$runtime-cap-ro.txt" CapBnd)" = 0000000000002000
  test "$(cap_value "$evidence/init-$runtime-cap-ro.txt" CapAmb)" = 0000000000000000
  test "$(field_value "$evidence/init-$runtime-cap-ro.txt" ROOT_WRITE)" = EROFS
  grep -F 'Read-only file system' "$(host_evidence_dir "$(pod_uid "cubesandbox-s33a-$runtime-cap-ro")")/root-write.stderr" >"$evidence/root-write-$runtime.stderr"
done
test "$(cap_value "$evidence/init-runc-nnp-seccomp.txt" NoNewPrivs)" = 1
test "$(cap_value "$evidence/init-cube-nnp-seccomp.txt" NoNewPrivs)" = 0
for runtime in runc cube; do
  test "$(cap_value "$evidence/init-$runtime-nnp-seccomp.txt" Seccomp)" = 2
  test "$(cap_value "$evidence/init-$runtime-nnp-seccomp.txt" Seccomp_filters)" -ge 1
done

printf 'capability\trunc_observation\tcube_observation\tdiagnostic_status\n' >"$evidence/diagnostic-matrix.tsv"
printf 'uid-gid\tuid=1234,gid=2345\tuid=1234,gid=2345\tOBSERVED_MATCH\n' >>"$evidence/diagnostic-matrix.tsv"
printf 'supplemental-groups\t2345,3456,4567\t2345,3456,4567\tOBSERVED_MATCH\n' >>"$evidence/diagnostic-matrix.tsv"
printf 'capabilities-net-raw\tmask=0x2000\tmask=0x2000\tOBSERVED_MATCH\n' >>"$evidence/diagnostic-matrix.tsv"
printf 'readonly-rootfs\tEROFS\tEROFS\tOBSERVED_MATCH\n' >>"$evidence/diagnostic-matrix.tsv"
printf 'no-new-privileges\t1\t0\tCUBE_GAP_OBSERVED\n' >>"$evidence/diagnostic-matrix.tsv"
printf 'runtime-default-seccomp\tmode=2,filters>=1\tmode=2,filters>=1\tOBSERVED_MATCH\n' >>"$evidence/diagnostic-matrix.tsv"
test "$(wc -l <"$evidence/diagnostic-matrix.tsv")" -eq 7

printf 'case\tsandbox_id\n' >"$evidence/cube-sandboxes.tsv"
for pod in "${cube_pods[@]}"; do
  uid=$(pod_uid "$pod")
  sandbox=$(sandbox_for_uid "$uid")
  test -n "$sandbox"
  cube_sandboxes+=("$sandbox")
  printf '%s\t%s\n' "$pod" "$sandbox" >>"$evidence/cube-sandboxes.tsv"
done
test "$(printf '%s\n' "${cube_sandboxes[@]}" | sort -u | wc -l)" -eq 4

delete_owned_pods
for uid in "${pod_uids[@]}"; do
  for _ in $(seq 1 1200); do test ! -e "/var/lib/kubelet/pods/$uid" && break; sleep .1; done
  test ! -e "/var/lib/kubelet/pods/$uid"
done
assert_baseline after
leases_after=$(lease_records)
printf 'after\t%s\n' "$leases_after" >>"$evidence/lease-counts.tsv"
test $(( leases_after - leases_before )) -eq 4
for sandbox in "${cube_sandboxes[@]}"; do
  test "$(lease_record_count_for_sandbox "$sandbox" false)" -eq 1
  test "$(lease_record_count_for_sandbox "$sandbox" true)" -eq 1
done
fixed_pods_absent
test "$(active_leases)" -eq 0
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
"${kube[@]}" get node "$node" -o json >"$evidence/node-after.json"
test "$(jq -r '.status.conditions[] | select(.type == "Ready") | .status' "$evidence/node-after.json")" = True
test "$(jq -r '.status.conditions[] | select(.type == "DiskPressure") | .status' "$evidence/node-after.json")" = False
test ! -e "$evidence/trace.log"
printf 'S33A_DIAGNOSTIC_OK host_input=cri-oci-equal uid_gid=match supplemental_groups=match capabilities=0x2000 readonly_rootfs=EROFS nnp_runc=1 nnp_cube=0 seccomp=mode2 lease_delta=4 exact_baseline=restored\n' | tee -a "$evidence/summary.txt"
printf 'S33A_DONE active_leases=0 durable_tombstone_delta=4 kubelet_pod_dirs=removed evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
