#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
pod=cubesandbox-s24-d2
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
warm_mount=/run/cubesandbox-s24-d2-image-warmup
evidence=/data/cubelet/s2.4-evidence/d2-ephemeral-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
event_pid=
follower_pid=

count_entries() { if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi; }
count_files() { if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi; }
active_leases() {
  local n=0 record
  while IFS= read -r record; do if ! jq -e '.active == null' "$record" >/dev/null; then n=$((n + 1)); fi; done \
    < <(find "$runtime_state/leases" -type f -name '*.json' -print 2>/dev/null)
  echo "$n"
}
lease_records() { find "$runtime_state/leases" -type f -name '*.json' 2>/dev/null | wc -l; }

capture_state() {
  local tag=$1
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt"
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt"
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt"
  find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n' 2>/dev/null | sort >"$evidence/netns-$tag.txt"
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort >"$evidence/cube-shims-$tag.txt"
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P %y\n' 2>/dev/null || true; fi; } | sort >"$evidence/vm-runtime-$tag.txt"
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s lease_records=%s\n' \
    "$(count_files "$runtime_state/adapter")" "$(count_entries "$shared")" "$(count_entries "$reaper")" \
    "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" \
    "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" "$(active_leases)" "$(lease_records)" >"$evidence/resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1 kind
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime; do cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1; done
  test "$(count_files "$runtime_state/adapter")" -eq 0 \
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
    if state_matches_baseline "$tag"; then printf 'S24_D2_BASELINE_CLEAN wait_attempt=%s lease_records=%s\n' "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"; return 0; fi
    sleep .1
  done
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime resources; do diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" >"$evidence/$kind-$tag.diff" 2>&1 || true; done
  return 1
}

delete_owned_pod() {
  if "${kube[@]}" get pod "$pod" >/dev/null 2>&1; then
    test "$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.labels.cubesandbox\.io/s24-owned}')" = true || return 1
    "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null
  fi
  for _ in $(seq 1 1200); do if ! "${kube[@]}" get pod "$pod" >/dev/null 2>&1; then return 0; fi; sleep .1; done
  return 1
}

wait_runtime_idle() {
  for _ in $(seq 1 1200); do
    if test "$(count_files "$runtime_state/adapter")" -eq 0 && test "$(count_entries "$shared")" -eq 0 \
      && test "$(count_entries "$reaper")" -eq 0 && test "$(count_entries "$vm_runtime")" -eq 0 \
      && test "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0 \
      && test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0 && test "$(active_leases)" -eq 0 \
      && ! ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {found=1} END {exit !found}'; then return 0; fi
    sleep .1
  done
  return 1
}

sandbox_for_uid() {
  local ids count
  ids=$("${cri[@]}" pods -o json | jq -r --arg uid "$1" '.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id')
  count=$(printf '%s\n' "$ids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1
  printf '%s\n' "$ids"
}

shim_pid_for_sandbox() {
  local pids count
  pids=$(ps -eo pid=,args= | awk -v id="$1" '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {print $1}')
  count=$(printf '%s\n' "$pids" | awk 'NF {n++} END {print n+0}')
  test "$count" -eq 1
  printf '%s\n' "$pids"
}

main_exit_line() {
  local id=$1 status=$2
  awk -v id="$id" -v status="$status" '
    index($0, " /tasks/exit ") && index($0, "\"container_id\":\"" id "\"") &&
    index($0, "\"id\":\"" id "\"") && index($0, "\"exit_status\":" status) {print NR; exit}
  ' "$evidence/events.txt"
}

main_exit_count() {
  local id=$1
  awk -v id="$id" '
    index($0, " /tasks/exit ") && index($0, "\"container_id\":\"" id "\"") &&
    index($0, "\"id\":\"" id "\"") {count++} END {print count+0}
  ' "$evidence/events.txt"
}

wait_file_contains() {
  local file=$1 pattern=$2
  for _ in $(seq 1 1200); do if grep -Fq "$pattern" "$file" 2>/dev/null; then return 0; fi; sleep .1; done
  return 1
}

stop_observers() {
  if test -n "$follower_pid"; then kill -TERM "$follower_pid" >/dev/null 2>&1 || true; wait "$follower_pid" >/dev/null 2>&1 || true; follower_pid=; fi
  if test -n "$event_pid"; then kill -TERM "$event_pid" >/dev/null 2>&1 || true; wait "$event_pid" >/dev/null 2>&1 || true; event_pid=; fi
}

cleanup() {
  local rc=$?
  set +e
  stop_observers
  "${kube[@]}" get pod "$pod" -o json >"$evidence/pod-final.json" 2>&1 || true
  "${cri[@]}" ps -a >"$evidence/cri-containers-final.txt" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  delete_owned_pod
  if mountpoint -q "$warm_mount"; then "${ctr[@]}" images unmount --snapshotter overlayfs --rm "$warm_mount" >/dev/null 2>&1 || true; fi
  rmdir "$warm_mount" >/dev/null 2>&1 || true
  wait_runtime_idle
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT
delete_owned_pod
wait_runtime_idle
install -d -m 0755 "$warm_mount"
"${ctr[@]}" images mount --snapshotter overlayfs docker.io/library/busybox:1.36.1 "$warm_mount" >"$evidence/image-warm-mount.txt"
"${ctr[@]}" images unmount --snapshotter overlayfs --rm "$warm_mount" >"$evidence/image-warm-unmount.txt"
rmdir "$warm_mount"
capture_state before
leases_before=$(lease_records)
timeout 1800s "${ctr[@]}" events >"$evidence/events.txt" 2>"$evidence/events.stderr" & event_pid=$!

"${kube[@]}" apply -f - >"$evidence/apply.txt" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels: {cubesandbox.io/s24-owned: "true"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Always
  terminationGracePeriodSeconds: 3
  containers:
  - name: app
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
  - name: survivor
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1001"]
EOF
"${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=300s >"$evidence/wait.txt"
"${kube[@]}" get pod "$pod" -o json >"$evidence/before.json"
uid=$(jq -r '.metadata.uid' "$evidence/before.json")
ip=$(jq -r '.status.podIP' "$evidence/before.json")
sandbox=$(sandbox_for_uid "$uid")
shim=$(shim_pid_for_sandbox "$sandbox")
shim_start=$(awk '{print $22}' "/proc/$shim/stat")
vm_inode=$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")
app=$(jq -r '.status.containerStatuses[] | select(.name == "app") | .containerID | sub("^containerd://"; "")' "$evidence/before.json")
survivor=$(jq -r '.status.containerStatuses[] | select(.name == "survivor") | .containerID | sub("^containerd://"; "")' "$evidence/before.json")
"${cri[@]}" inspect "$app" >"$evidence/cri-app.json"
"${cri[@]}" inspect "$survivor" >"$evidence/cri-survivor.json"
test "$(jq -r '.info.sandboxID' "$evidence/cri-app.json")" = "$sandbox"
test "$(jq -r '.info.sandboxID' "$evidence/cri-survivor.json")" = "$sandbox"
"${kube[@]}" exec "$pod" -c app -- true
"${kube[@]}" exec "$pod" -c survivor -- true

jq '.spec.ephemeralContainers = [{
  name: "debugger",
  image: "docker.io/library/busybox:1.36.1",
  imagePullPolicy: "IfNotPresent",
  targetContainerName: "app",
  stdin: false,
  tty: false,
  command: ["sh", "-c", "echo DEBUG_RUNNING; while test ! -e /dev/shm/ephemeral-release; do sleep 1; done; echo DEBUG_EXIT_47; exit 47"]
}] | {apiVersion, kind, metadata: {name: .metadata.name, namespace: .metadata.namespace, resourceVersion: .metadata.resourceVersion}, spec: {ephemeralContainers: .spec.ephemeralContainers}}' \
  "$evidence/before.json" >"$evidence/ephemeral-update.json"
jq -e '.spec.ephemeralContainers[0] | .name == "debugger" and .targetContainerName == "app" and .stdin == false and .tty == false and (has("ports") | not) and (has("startupProbe") | not) and (has("readinessProbe") | not) and (has("livenessProbe") | not) and (has("lifecycle") | not) and (has("resources") | not)' "$evidence/ephemeral-update.json" >/dev/null
"${kube[@]}" replace --raw "/api/v1/namespaces/default/pods/$pod/ephemeralcontainers" -f "$evidence/ephemeral-update.json" >"$evidence/ephemeral-update-response.json"
jq -e '(.spec.ephemeralContainers | length) == 1 and .spec.ephemeralContainers[0].name == "debugger" and .spec.ephemeralContainers[0].targetContainerName == "app"' "$evidence/ephemeral-update-response.json" >/dev/null

debug=
for _ in $(seq 1 1200); do
  "${kube[@]}" get pod "$pod" -o json >"$evidence/running.json"
  debug=$(jq -r '.status.ephemeralContainerStatuses[]? | select(.name == "debugger" and .state.running != null) | .containerID | sub("^containerd://"; "")' "$evidence/running.json")
  test -n "$debug" && break
  sleep .1
done
test -n "$debug"
jq -e '(.spec.ephemeralContainers | length) == 1 and (.status.ephemeralContainerStatuses | length) == 1' "$evidence/running.json" >/dev/null
"${cri[@]}" inspect "$debug" >"$evidence/cri-debugger.json"
"${ctr[@]}" containers info "$debug" >"$evidence/ctr-debugger.json"
test "$(jq -r '.info.sandboxID' "$evidence/cri-debugger.json")" = "$sandbox"
test "$(jq -r '.info.config.linux.security_context.namespace_options.pid' "$evidence/cri-debugger.json")" -eq 3
test "$(jq -r '.info.config.linux.security_context.namespace_options.target_id' "$evidence/cri-debugger.json")" = "$app"
test "$(jq -r '.Spec.annotations["io.kubernetes.cri.sandbox-id"]' "$evidence/ctr-debugger.json")" = "$sandbox"
app_net=$("${kube[@]}" exec "$pod" -c app -- readlink /proc/self/ns/net)
debug_net=$("${kube[@]}" exec "$pod" -c debugger -- readlink /proc/self/ns/net)
app_ipc=$("${kube[@]}" exec "$pod" -c app -- readlink /proc/self/ns/ipc)
debug_ipc=$("${kube[@]}" exec "$pod" -c debugger -- readlink /proc/self/ns/ipc)
app_uts=$("${kube[@]}" exec "$pod" -c app -- readlink /proc/self/ns/uts)
debug_uts=$("${kube[@]}" exec "$pod" -c debugger -- readlink /proc/self/ns/uts)
app_pidns=$("${kube[@]}" exec "$pod" -c app -- readlink /proc/self/ns/pid)
debug_pidns=$("${kube[@]}" exec "$pod" -c debugger -- readlink /proc/self/ns/pid)
test "$app_net" = "$debug_net"
test "$app_ipc" = "$debug_ipc"
test "$app_uts" = "$debug_uts"
if test "$app_pidns" = "$debug_pidns"; then target_pid=ok; else target_pid=unsupported; fi
test "$(jq -r '.metadata.uid' "$evidence/running.json")" = "$uid"
test "$(jq -r '.status.podIP' "$evidence/running.json")" = "$ip"
test "$(jq -r '.status.containerStatuses[] | select(.name == "app") | .containerID | sub("^containerd://"; "")' "$evidence/running.json")" = "$app"
test "$(jq -r '.status.containerStatuses[] | select(.name == "survivor") | .containerID | sub("^containerd://"; "")' "$evidence/running.json")" = "$survivor"
test "$(sandbox_for_uid "$uid")" = "$sandbox"
test "$(shim_pid_for_sandbox "$sandbox")" = "$shim"
test "$(awk '{print $22}' "/proc/$shim/stat")" = "$shim_start"
test "$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")" = "$vm_inode"
"${ctr[@]}" tasks list -q | sort >"$evidence/tasks-running.txt"
{ cat "$evidence/tasks-before.txt"; printf '%s\n' "$app" "$survivor" "$debug"; } | sort -u >"$evidence/tasks-running-expected.txt"
cmp -s "$evidence/tasks-running-expected.txt" "$evidence/tasks-running.txt"

"${kube[@]}" logs -f "$pod" -c debugger >"$evidence/debugger.log" 2>&1 & follower_pid=$!
wait_file_contains "$evidence/debugger.log" DEBUG_RUNNING
kill -0 "$event_pid"
"${kube[@]}" exec "$pod" -c app -- sh -c 'echo yes >/dev/shm/ephemeral-release'
for _ in $(seq 1 1200); do
  "${kube[@]}" get pod "$pod" -o json >"$evidence/exited.json"
  if jq -e --arg id "containerd://$debug" '.status.ephemeralContainerStatuses[]? | select(.name == "debugger" and .containerID == $id and .state.terminated.exitCode == 47 and .restartCount == 0)' "$evidence/exited.json" >/dev/null; then break; fi
  sleep .1
done
jq -e --arg id "containerd://$debug" '(.spec.ephemeralContainers | length) == 1 and (.status.ephemeralContainerStatuses | length) == 1 and .status.ephemeralContainerStatuses[0].name == "debugger" and .status.ephemeralContainerStatuses[0].containerID == $id and .status.ephemeralContainerStatuses[0].state.terminated.exitCode == 47 and .status.ephemeralContainerStatuses[0].restartCount == 0' "$evidence/exited.json" >/dev/null
wait_file_contains "$evidence/debugger.log" DEBUG_EXIT_47
for _ in $(seq 1 1200); do debug_event=$(main_exit_line "$debug" 47); test -n "$debug_event" && break; sleep .1; done
test -n "$debug_event"
test "$(main_exit_count "$debug")" -eq 1

for second in $(seq 1 22); do
  "${kube[@]}" get pod "$pod" -o json >"$evidence/stable-$second.json"
  jq -e --arg id "containerd://$debug" '(.spec.ephemeralContainers | length) == 1 and (.status.ephemeralContainerStatuses | length) == 1 and .status.ephemeralContainerStatuses[0].containerID == $id and .status.ephemeralContainerStatuses[0].state.terminated.exitCode == 47 and .status.ephemeralContainerStatuses[0].restartCount == 0' "$evidence/stable-$second.json" >/dev/null
  test "$(jq -r '.status.containerStatuses[] | select(.name == "app") | .containerID | sub("^containerd://"; "")' "$evidence/stable-$second.json")" = "$app"
  test "$(jq -r '.status.containerStatuses[] | select(.name == "survivor") | .containerID | sub("^containerd://"; "")' "$evidence/stable-$second.json")" = "$survivor"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-stable-$second.txt"
  { cat "$evidence/tasks-before.txt"; printf '%s\n' "$app" "$survivor"; } | sort -u >"$evidence/tasks-stable-expected.txt"
  cmp -s "$evidence/tasks-stable-expected.txt" "$evidence/tasks-stable-$second.txt"
  sleep 1
done
"${kube[@]}" get pod "$pod" -o json >"$evidence/stable-final.json"
jq -e --arg id "containerd://$debug" '(.spec.ephemeralContainers | length) == 1 and (.status.ephemeralContainerStatuses | length) == 1 and .status.ephemeralContainerStatuses[0].name == "debugger" and .status.ephemeralContainerStatuses[0].containerID == $id and .status.ephemeralContainerStatuses[0].state.terminated.exitCode == 47 and .status.ephemeralContainerStatuses[0].restartCount == 0' "$evidence/stable-final.json" >/dev/null
test "$(jq -r '.status.containerStatuses[] | select(.name == "app") | .containerID | sub("^containerd://"; "")' "$evidence/stable-final.json")" = "$app"
test "$(jq -r '.status.containerStatuses[] | select(.name == "survivor") | .containerID | sub("^containerd://"; "")' "$evidence/stable-final.json")" = "$survivor"
"${ctr[@]}" tasks list -q | sort >"$evidence/tasks-stable-final.txt"
cmp -s "$evidence/tasks-stable-expected.txt" "$evidence/tasks-stable-final.txt"
test "$(main_exit_count "$debug")" -eq 1
stop_observers
"${kube[@]}" exec "$pod" -c app -- true
"${kube[@]}" exec "$pod" -c survivor -- true
test "$(sandbox_for_uid "$uid")" = "$sandbox"
test "$(shim_pid_for_sandbox "$sandbox")" = "$shim"
test "$(awk '{print $22}' "/proc/$shim/stat")" = "$shim_start"
test "$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")" = "$vm_inode"
printf 'S24_D2_OK sandbox=%s pod_ip=%s dynamic_join=ok cri_sandbox=ok net_ipc_uts=shared exit47=ok no_restart_22s=ok survivor=ok target_requested=TARGET target_pid=%s\n' "$sandbox" "$ip" "$target_pid" | tee -a "$evidence/summary.txt"
delete_owned_pod
assert_baseline after
test $(( $(lease_records) - leases_before )) -eq 1
printf 'S24_D2_DONE active_leases=0 durable_tombstone_delta=1 evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
