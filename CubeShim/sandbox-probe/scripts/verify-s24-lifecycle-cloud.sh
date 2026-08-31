#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
pod=cubesandbox-s24-d4
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
warm_mount=/run/cubesandbox-s24-d4-image-warmup
evidence=/data/cubelet/s2.4-evidence/d4-lifecycle-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
event_pid=

count_entries() { if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi; }
count_files() { if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi; }
active_leases() {
  local n=0 record
  while IFS= read -r record; do
    if ! jq -e '.active == null' "$record" >/dev/null; then n=$((n + 1)); fi
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print 2>/dev/null)
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
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime; do
    cmp -s "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" || return 1
  done
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
    if state_matches_baseline "$tag"; then
      printf 'S24_D4_BASELINE_CLEAN wait_attempt=%s lease_records=%s\n' "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep .1
  done
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime resources; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" >"$evidence/$kind-$tag.diff" 2>&1 || true
  done
  return 1
}

delete_owned_pod() {
  if "${kube[@]}" get pod "$pod" >/dev/null 2>&1; then
    test "$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.labels.cubesandbox\.io/s24-owned}')" = true || return 1
    "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null
  fi
  for _ in $(seq 1 1200); do
    if ! "${kube[@]}" get pod "$pod" >/dev/null 2>&1; then return 0; fi
    sleep .1
  done
  return 1
}

wait_runtime_idle() {
  for _ in $(seq 1 1200); do
    if test "$(count_files "$runtime_state/adapter")" -eq 0 \
      && test "$(count_entries "$shared")" -eq 0 \
      && test "$(count_entries "$reaper")" -eq 0 \
      && test "$(count_entries "$vm_runtime")" -eq 0 \
      && test "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0 \
      && test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0 \
      && test "$(active_leases)" -eq 0 \
      && ! ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {found=1} END {exit !found}'; then
      return 0
    fi
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
    index($0, "\"id\":\"" id "\"") {
      if (status == 0 && (index($0, "\"exit_status\":") == 0 || index($0, "\"exit_status\":0"))) {print NR; exit}
      if (status != 0 && index($0, "\"exit_status\":" status)) {print NR; exit}
    }
  ' "$evidence/events.txt"
}

main_exit_count() {
  local id=$1
  awk -v id="$id" '
    index($0, " /tasks/exit ") && index($0, "\"container_id\":\"" id "\"") &&
    index($0, "\"id\":\"" id "\"") {count++} END {print count+0}
  ' "$evidence/events.txt"
}

exec_lines() {
  local container=$1 file=$2
  "${kube[@]}" exec "$pod" -c "$container" -- sh -c "if test -f '$file'; then wc -l <'$file'; else echo 0; fi" | tr -d '[:space:]'
}

try_exec_lines() { exec_lines "$1" "$2" 2>/dev/null || printf '0\n'; }

stop_observers() {
  if test -n "$event_pid"; then
    kill -TERM "$event_pid" >/dev/null 2>&1 || true
    wait "$event_pid" >/dev/null 2>&1 || true
    event_pid=
  fi
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

cat >"$evidence/pod.yaml" <<'POD_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s24-d4
  labels:
    cubesandbox.io/s24-owned: "true"
spec:
  runtimeClassName: cube
  nodeName: vm-200-2-ubuntu
  automountServiceAccountToken: false
  restartPolicy: Always
  terminationGracePeriodSeconds: 4
  containers:
  - name: target
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c"]
    args:
    - |
      set -eu
      starts=/dev/shm/s24-d4-target-starts
      gen=$(( $(test -f "$starts" && wc -l <"$starts" || echo 0) + 1 ))
      printf '%s\n' "$gen" >>"$starts"
      printf '%s\n' "$gen" >/dev/s24-d4-generation
      cat >/dev/s24-d4-prestop <<'HOOK'
      #!/bin/sh
      set -eu
      gen=$(cat /dev/s24-d4-generation)
      if mkdir "/dev/shm/s24-d4-prestop-$gen.lock" 2>/dev/null; then
        awk -v gen="$gen" '{printf "%s %.0f\n", gen, $1 * 1000}' /proc/uptime >>/dev/shm/s24-d4-prestop-events
        touch "/dev/shm/s24-d4-prestop-$gen"
      fi
      HOOK
      chmod 0755 /dev/s24-d4-prestop
      cat >/dev/s24-d4-tcp-handler <<'TCP'
      #!/bin/sh
      exit 0
      TCP
      chmod 0755 /dev/s24-d4-tcp-handler
      busybox nc -ll -p 9090 -e /dev/s24-d4-tcp-handler &
      tcp_pid=$!
      printf '%s\n' "$tcp_pid" >/dev/shm/s24-d4-tcp-server-pid
      term() {
        if ! test -f "/dev/shm/s24-d4-prestop-$gen"; then
          printf '%s\n' "$gen" >>/dev/shm/s24-d4-term-before-prestop
          exit 99
        fi
        awk -v gen="$gen" '{printf "%s %.0f\n", gen, $1 * 1000}' /proc/uptime >>/dev/shm/s24-d4-term-events
        kill "$tcp_pid" >/dev/null 2>&1 || true
        if test "$gen" -eq 2; then
          trap '' TERM INT
          while :; do
            awk -v gen="$gen" '{printf "%s %.0f\n", gen, $1 * 1000}' /proc/uptime >>/dev/shm/s24-d4-stubborn-heartbeats
            sleep .1
          done
        fi
        exit 0
      }
      trap term TERM INT
      while :; do sleep 1; done
    ports:
    - {name: tcp-live, containerPort: 9090}
    lifecycle:
      postStart:
        exec:
          command:
          - sh
          - -c
          - |
            for _ in $(seq 1 1000); do test -s /dev/s24-d4-generation && break; sleep .01; done
            gen=$(cat /dev/s24-d4-generation)
            if mkdir "/dev/shm/s24-d4-poststart-$gen.lock" 2>/dev/null; then
              awk -v gen="$gen" '{printf "%s %.0f\n", gen, $1 * 1000}' /proc/uptime >>/dev/shm/s24-d4-poststart-events
            fi
      preStop:
        exec:
          command: ["sh", "-c", "/dev/s24-d4-prestop; /dev/s24-d4-prestop"]
    livenessProbe:
      tcpSocket:
        port: tcp-live
      periodSeconds: 1
      timeoutSeconds: 1
      failureThreshold: 3
      terminationGracePeriodSeconds: 4
  - name: survivor
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
POD_EOF
"${kube[@]}" apply -f "$evidence/pod.yaml" >"$evidence/apply.txt"
"${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=180s >"$evidence/wait-generation-1.txt"

target1=
survivor=
for _ in $(seq 1 1800); do
  "${kube[@]}" get pod "$pod" -o json >"$evidence/generation-1.json"
  target1=$(jq -r '.status.containerStatuses[]? | select(.name == "target" and .restartCount == 0 and .state.running != null and .ready == true) | .containerID | sub("^containerd://"; "")' "$evidence/generation-1.json")
  survivor=$(jq -r '.status.containerStatuses[]? | select(.name == "survivor" and .restartCount == 0 and .state.running != null) | .containerID | sub("^containerd://"; "")' "$evidence/generation-1.json")
  if test -n "$target1" && test -n "$survivor" && test "$(try_exec_lines target /dev/shm/s24-d4-poststart-events)" -eq 1; then break; fi
  sleep .1
done
test -n "$target1"
test -n "$survivor"
test "$(exec_lines target /dev/shm/s24-d4-target-starts)" -eq 1
test "$(exec_lines target /dev/shm/s24-d4-poststart-events)" -eq 1
"${kube[@]}" exec "$pod" -c target -- sh -c 'test ! -e /dev/shm/s24-d4-prestop-events; test ! -e /dev/shm/s24-d4-term-events; test ! -e /dev/shm/s24-d4-term-before-prestop'

uid=$(jq -r '.metadata.uid' "$evidence/generation-1.json")
ip=$(jq -r '.status.podIP' "$evidence/generation-1.json")
test -n "$uid"
test -n "$ip"
test "$ip" != null
sandbox=$(sandbox_for_uid "$uid")
shim=$(shim_pid_for_sandbox "$sandbox")
shim_start=$(awk '{print $22}' "/proc/$shim/stat")
vm_inode=$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")
"${cri[@]}" inspect "$target1" >"$evidence/cri-target-generation-1.json"
"${cri[@]}" inspect "$survivor" >"$evidence/cri-survivor.json"
test "$(jq -r '.info.sandboxID' "$evidence/cri-target-generation-1.json")" = "$sandbox"
test "$(jq -r '.info.sandboxID' "$evidence/cri-survivor.json")" = "$sandbox"
"${ctr[@]}" tasks list -q | sort >"$evidence/tasks-generation-1.txt"
{ cat "$evidence/tasks-before.txt"; printf '%s\n' "$target1" "$survivor"; } | sort -u >"$evidence/tasks-generation-1-expected.txt"
cmp -s "$evidence/tasks-generation-1-expected.txt" "$evidence/tasks-generation-1.txt"

"${kube[@]}" exec "$pod" -c target -- sh -c 'kill "$(cat /dev/shm/s24-d4-tcp-server-pid)"; echo GRACEFUL_LISTENER_CLOSED'
target2=
for _ in $(seq 1 3000); do
  "${kube[@]}" get pod "$pod" -o json >"$evidence/generation-2.json"
  target2=$(jq -r --arg old "containerd://$target1" '.status.containerStatuses[]? | select(.name == "target" and .restartCount == 1 and .containerID != $old and .state.running != null and .ready == true) | .containerID | sub("^containerd://"; "")' "$evidence/generation-2.json")
  test -n "$target2" && test "$(try_exec_lines target /dev/shm/s24-d4-poststart-events)" -eq 2 && break
  sleep .1
done
test -n "$target2"
test "$target2" != "$target1"
jq -e --arg old "containerd://$target1" '
  .status.containerStatuses[] | select(.name == "target") |
  .lastState.terminated.containerID == $old and .lastState.terminated.exitCode == 0 and .lastState.terminated.reason == "Completed"
' "$evidence/generation-2.json" >/dev/null
graceful_exit=
for _ in $(seq 1 1200); do graceful_exit=$(main_exit_line "$target1" 0); test -n "$graceful_exit" && break; sleep .1; done
test -n "$graceful_exit"
test "$(main_exit_count "$target1")" -eq 1
test "$(main_exit_count "$survivor")" -eq 0
test "$(exec_lines target /dev/shm/s24-d4-target-starts)" -eq 2
test "$(exec_lines target /dev/shm/s24-d4-prestop-events)" -eq 1
test "$(exec_lines target /dev/shm/s24-d4-term-events)" -eq 1
"${kube[@]}" exec "$pod" -c target -- sh -c '
  test "$(grep -c "^1 " /dev/shm/s24-d4-prestop-events)" -eq 1
  test "$(grep -c "^1 " /dev/shm/s24-d4-term-events)" -eq 1
  test ! -e /dev/shm/s24-d4-term-before-prestop
'
test "$(sandbox_for_uid "$uid")" = "$sandbox"
test "$(shim_pid_for_sandbox "$sandbox")" = "$shim"
test "$(awk '{print $22}' "/proc/$shim/stat")" = "$shim_start"
test "$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")" = "$vm_inode"
"${cri[@]}" inspect "$target2" >"$evidence/cri-target-generation-2.json"
test "$(jq -r '.info.sandboxID' "$evidence/cri-target-generation-2.json")" = "$sandbox"
"${ctr[@]}" tasks list -q | sort >"$evidence/tasks-generation-2.txt"
{ cat "$evidence/tasks-before.txt"; printf '%s\n' "$target2" "$survivor"; } | sort -u >"$evidence/tasks-generation-2-expected.txt"
cmp -s "$evidence/tasks-generation-2-expected.txt" "$evidence/tasks-generation-2.txt"
"${kube[@]}" exec "$pod" -c survivor -- true

"${kube[@]}" exec "$pod" -c target -- sh -c 'kill "$(cat /dev/shm/s24-d4-tcp-server-pid)"; echo STUBBORN_LISTENER_CLOSED'
target3=
for _ in $(seq 1 3600); do
  "${kube[@]}" get pod "$pod" -o json >"$evidence/generation-3.json"
  target3=$(jq -r --arg old "containerd://$target2" '.status.containerStatuses[]? | select(.name == "target" and .restartCount == 2 and .containerID != $old and .state.running != null and .ready == true) | .containerID | sub("^containerd://"; "")' "$evidence/generation-3.json")
  test -n "$target3" && test "$(try_exec_lines target /dev/shm/s24-d4-poststart-events)" -eq 3 && break
  sleep .1
done
test -n "$target3"
test "$target3" != "$target2"
jq -e --arg old "containerd://$target2" '
  .status.containerStatuses[] | select(.name == "target") |
  .lastState.terminated.containerID == $old and .lastState.terminated.exitCode == 137
' "$evidence/generation-3.json" >/dev/null
stubborn_exit=
for _ in $(seq 1 1200); do stubborn_exit=$(main_exit_line "$target2" 137); test -n "$stubborn_exit" && break; sleep .1; done
test -n "$stubborn_exit"
test "$(main_exit_count "$target2")" -eq 1
test "$(main_exit_count "$survivor")" -eq 0
test "$(exec_lines target /dev/shm/s24-d4-target-starts)" -eq 3
test "$(exec_lines target /dev/shm/s24-d4-poststart-events)" -eq 3
test "$(exec_lines target /dev/shm/s24-d4-prestop-events)" -eq 2
test "$(exec_lines target /dev/shm/s24-d4-term-events)" -eq 2
term2_ms=$("${kube[@]}" exec "$pod" -c target -- awk '$1 == 2 {print $2; exit}' /dev/shm/s24-d4-term-events | tr -d '[:space:]')
last_heartbeat_ms=$("${kube[@]}" exec "$pod" -c target -- awk '$1 == 2 {value=$2} END {print value}' /dev/shm/s24-d4-stubborn-heartbeats | tr -d '[:space:]')
test -n "$term2_ms"
test -n "$last_heartbeat_ms"
stubborn_survival_ms=$((last_heartbeat_ms - term2_ms))
test "$stubborn_survival_ms" -ge 3000
"${kube[@]}" exec "$pod" -c target -- sh -c '
  test "$(grep -c "^1 " /dev/shm/s24-d4-prestop-events)" -eq 1
  test "$(grep -c "^2 " /dev/shm/s24-d4-prestop-events)" -eq 1
  test "$(grep -c "^1 " /dev/shm/s24-d4-term-events)" -eq 1
  test "$(grep -c "^2 " /dev/shm/s24-d4-term-events)" -eq 1
  test ! -e /dev/shm/s24-d4-term-before-prestop
'
jq -e --arg uid "$uid" --arg ip "$ip" --arg target "containerd://$target3" --arg survivor "containerd://$survivor" '
  (.metadata.uid == $uid) and (.status.podIP == $ip) and
  (.status.containerStatuses[] | select(.name == "target") | .containerID == $target and .restartCount == 2 and .ready == true) and
  (.status.containerStatuses[] | select(.name == "survivor") | .containerID == $survivor and .restartCount == 0)
' "$evidence/generation-3.json" >/dev/null
test "$(sandbox_for_uid "$uid")" = "$sandbox"
test "$(shim_pid_for_sandbox "$sandbox")" = "$shim"
test "$(awk '{print $22}' "/proc/$shim/stat")" = "$shim_start"
test "$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")" = "$vm_inode"
"${cri[@]}" inspect "$target3" >"$evidence/cri-target-generation-3.json"
test "$(jq -r '.info.sandboxID' "$evidence/cri-target-generation-3.json")" = "$sandbox"
"${ctr[@]}" tasks list -q | sort >"$evidence/tasks-generation-3.txt"
{ cat "$evidence/tasks-before.txt"; printf '%s\n' "$target3" "$survivor"; } | sort -u >"$evidence/tasks-generation-3-expected.txt"
cmp -s "$evidence/tasks-generation-3-expected.txt" "$evidence/tasks-generation-3.txt"
"${kube[@]}" exec "$pod" -c target -- true
"${kube[@]}" exec "$pod" -c survivor -- true
stop_observers
printf 'S24_D4_OK sandbox=%s pod_ip=%s poststart=3 prestop_idempotent=2 graceful_exit0=ok stubborn_exit137=ok stubborn_survival_ms=%s survivor=stable shim_identity=stable vm_inode=stable\n' "$sandbox" "$ip" "$stubborn_survival_ms" | tee -a "$evidence/summary.txt"
delete_owned_pod
assert_baseline after
test $(( $(lease_records) - leases_before )) -eq 1
printf 'S24_D4_DONE active_leases=0 durable_tombstone_delta=1 evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
