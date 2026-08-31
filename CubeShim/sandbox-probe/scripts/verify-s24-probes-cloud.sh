#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
pod=cubesandbox-s24-d3
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
warm_mount=/run/cubesandbox-s24-d3-image-warmup
evidence=/data/cubelet/s2.4-evidence/d3-probes-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
event_pid=

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
    if state_matches_baseline "$tag"; then printf 'S24_D3_BASELINE_CLEAN wait_attempt=%s lease_records=%s\n' "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"; return 0; fi
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

exec_count() {
  local container=$1 file=$2
  "${kube[@]}" exec "$pod" -c "$container" -- sh -c "if test -f '$file'; then wc -l <'$file'; else echo 0; fi" | tr -d '[:space:]'
}

try_exec_count() {
  exec_count "$1" "$2" 2>/dev/null || printf '0\n'
}

stop_observers() {
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

cat >"$evidence/pod.yaml" <<'POD_EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cubesandbox-s24-d3
  labels:
    cubesandbox.io/s24-owned: "true"
spec:
  runtimeClassName: cube
  nodeName: vm-200-2-ubuntu
  automountServiceAccountToken: false
  restartPolicy: Always
  terminationGracePeriodSeconds: 3
  containers:
  - name: target
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c"]
    args:
    - |
      set -eu
      mkdir -p /dev/s24-d3-www/cgi-bin
      cat >/dev/s24-d3-www/cgi-bin/ready <<'CGI'
      #!/bin/sh
      date +%s%N >>/dev/shm/s24-d3-readiness-hits
      if test -f /dev/shm/s24-d3-readiness-gate; then
        printf 'Status: 200 OK\r\nContent-Type: text/plain\r\n\r\nready\n'
      else
        printf 'Status: 503 Service Unavailable\r\nContent-Type: text/plain\r\n\r\nnot-ready\n'
      fi
      CGI
      cat >/dev/s24-d3-tcp-handler <<'TCP'
      #!/bin/sh
      date +%s%N >>/dev/shm/s24-d3-tcp-hits
      exit 0
      TCP
      chmod 0755 /dev/s24-d3-www/cgi-bin/ready /dev/s24-d3-tcp-handler
      date +%s%N >>/dev/shm/s24-d3-target-starts
      echo TARGET_START
      busybox httpd -f -vv -p 8080 -h /dev/s24-d3-www &
      http_pid=$!
      busybox nc -ll -p 9090 -e /dev/s24-d3-tcp-handler &
      tcp_pid=$!
      echo "$tcp_pid" >/dev/shm/s24-d3-tcp-server-pid
      term() {
        echo TARGET_TERM_66
        kill "$http_pid" "$tcp_pid" >/dev/null 2>&1 || true
        exit 66
      }
      trap term TERM INT
      while :; do sleep 1; done
    ports:
    - {name: http-ready, containerPort: 8080}
    - {name: tcp-live, containerPort: 9090}
    startupProbe:
      exec:
        command: ["sh", "-c", "date +%s%N >>/dev/shm/s24-d3-startup-hits; test -f /dev/shm/s24-d3-startup-gate"]
      periodSeconds: 1
      timeoutSeconds: 1
      failureThreshold: 120
    readinessProbe:
      httpGet:
        path: /cgi-bin/ready
        port: http-ready
      periodSeconds: 1
      timeoutSeconds: 1
      failureThreshold: 2
      successThreshold: 1
    livenessProbe:
      tcpSocket:
        port: tcp-live
      periodSeconds: 1
      timeoutSeconds: 1
      failureThreshold: 3
  - name: survivor
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "exec sleep 1000"]
POD_EOF
"${kube[@]}" apply -f "$evidence/pod.yaml" >"$evidence/apply.txt"

target=
survivor=
startup_hits=0
for _ in $(seq 1 1800); do
  "${kube[@]}" get pod "$pod" -o json >"$evidence/prestart.json"
  target=$(jq -r '.status.containerStatuses[]? | select(.name == "target" and .state.running != null) | .containerID | sub("^containerd://"; "")' "$evidence/prestart.json")
  survivor=$(jq -r '.status.containerStatuses[]? | select(.name == "survivor" and .state.running != null) | .containerID | sub("^containerd://"; "")' "$evidence/prestart.json")
  if test -n "$target" && test -n "$survivor"; then
    startup_hits=$(try_exec_count target /dev/shm/s24-d3-startup-hits)
    test "$startup_hits" -ge 3 && break
  fi
  sleep .1
done
test -n "$target"
test -n "$survivor"
test "$startup_hits" -ge 3
"${kube[@]}" get pod "$pod" -o json >"$evidence/prestart.json"
jq -e --arg target "containerd://$target" --arg survivor "containerd://$survivor" '
  (.status.containerStatuses[] | select(.name == "target") | .containerID == $target and .restartCount == 0 and .ready == false) and
  (.status.containerStatuses[] | select(.name == "survivor") | .containerID == $survivor and .restartCount == 0)
' "$evidence/prestart.json" >/dev/null
"${kube[@]}" exec "$pod" -c target -- sh -c 'test ! -e /dev/shm/s24-d3-readiness-hits; test ! -e /dev/shm/s24-d3-tcp-hits'

uid=$(jq -r '.metadata.uid' "$evidence/prestart.json")
ip=$(jq -r '.status.podIP' "$evidence/prestart.json")
test -n "$uid"
test -n "$ip"
test "$ip" != null
sandbox=$(sandbox_for_uid "$uid")
shim=$(shim_pid_for_sandbox "$sandbox")
shim_start=$(awk '{print $22}' "/proc/$shim/stat")
vm_inode=$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")
"${cri[@]}" inspect "$target" >"$evidence/cri-target-before.json"
"${cri[@]}" inspect "$survivor" >"$evidence/cri-survivor-before.json"
test "$(jq -r '.info.sandboxID' "$evidence/cri-target-before.json")" = "$sandbox"
test "$(jq -r '.info.sandboxID' "$evidence/cri-survivor-before.json")" = "$sandbox"
"${ctr[@]}" tasks list -q | sort >"$evidence/tasks-prestart.txt"
{ cat "$evidence/tasks-before.txt"; printf '%s\n' "$target" "$survivor"; } | sort -u >"$evidence/tasks-prestart-expected.txt"
cmp -s "$evidence/tasks-prestart-expected.txt" "$evidence/tasks-prestart.txt"

"${kube[@]}" exec "$pod" -c target -- touch /dev/shm/s24-d3-startup-gate
for _ in $(seq 1 1800); do
  readiness_hits=$(try_exec_count target /dev/shm/s24-d3-readiness-hits)
  tcp_hits=$(try_exec_count target /dev/shm/s24-d3-tcp-hits)
  "${kube[@]}" get pod "$pod" -o json >"$evidence/readiness-failing.json"
  target_ready=$(jq -r '.status.containerStatuses[] | select(.name == "target") | .ready' "$evidence/readiness-failing.json")
  if test "$readiness_hits" -ge 2 && test "$tcp_hits" -ge 1 && test "$target_ready" = false; then break; fi
  sleep .1
done
test "$readiness_hits" -ge 2
test "$tcp_hits" -ge 1
jq -e --arg target "containerd://$target" --arg survivor "containerd://$survivor" '
  (.status.containerStatuses[] | select(.name == "target") | .containerID == $target and .restartCount == 0 and .ready == false) and
  (.status.containerStatuses[] | select(.name == "survivor") | .containerID == $survivor and .restartCount == 0)
' "$evidence/readiness-failing.json" >/dev/null

"${kube[@]}" exec "$pod" -c target -- touch /dev/shm/s24-d3-readiness-gate
"${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=180s >"$evidence/wait-ready.txt"
"${kube[@]}" get pod "$pod" -o json >"$evidence/ready.json"
jq -e --arg target "containerd://$target" --arg survivor "containerd://$survivor" '
  (.status.containerStatuses[] | select(.name == "target") | .containerID == $target and .restartCount == 0 and .ready == true) and
  (.status.containerStatuses[] | select(.name == "survivor") | .containerID == $survivor and .restartCount == 0)
' "$evidence/ready.json" >/dev/null
ready_hits=$(exec_count target /dev/shm/s24-d3-readiness-hits)
test "$ready_hits" -gt "$readiness_hits"
test "$(sandbox_for_uid "$uid")" = "$sandbox"
test "$(shim_pid_for_sandbox "$sandbox")" = "$shim"
test "$(awk '{print $22}' "/proc/$shim/stat")" = "$shim_start"
test "$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")" = "$vm_inode"

"${kube[@]}" exec "$pod" -c target -- sh -c 'kill "$(cat /dev/shm/s24-d3-tcp-server-pid)"; echo TCP_LISTENER_CLOSED'
new_target=
for _ in $(seq 1 3000); do
  "${kube[@]}" get pod "$pod" -o json >"$evidence/restarted.json"
  new_target=$(jq -r --arg old "containerd://$target" '.status.containerStatuses[]? | select(.name == "target" and .restartCount == 1 and .containerID != $old and .state.running != null and .ready == true) | .containerID | sub("^containerd://"; "")' "$evidence/restarted.json")
  test -n "$new_target" && break
  sleep .1
done
test -n "$new_target"
test "$new_target" != "$target"
jq -e --arg uid "$uid" --arg ip "$ip" --arg new "containerd://$new_target" --arg survivor "containerd://$survivor" '
  (.metadata.uid == $uid) and (.status.podIP == $ip) and
  (.status.containerStatuses[] | select(.name == "target") | .containerID == $new and .restartCount == 1 and .ready == true) and
  (.status.containerStatuses[] | select(.name == "survivor") | .containerID == $survivor and .restartCount == 0)
' "$evidence/restarted.json" >/dev/null

old_exit=
for _ in $(seq 1 1200); do old_exit=$(main_exit_line "$target" 66); test -n "$old_exit" && break; sleep .1; done
test -n "$old_exit"
test "$(main_exit_count "$target")" -eq 1
test "$(main_exit_count "$survivor")" -eq 0
test "$(sandbox_for_uid "$uid")" = "$sandbox"
test "$(shim_pid_for_sandbox "$sandbox")" = "$shim"
test "$(awk '{print $22}' "/proc/$shim/stat")" = "$shim_start"
test "$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")" = "$vm_inode"
"${cri[@]}" inspect "$new_target" >"$evidence/cri-target-after.json"
test "$(jq -r '.info.sandboxID' "$evidence/cri-target-after.json")" = "$sandbox"
test "$(exec_count target /dev/shm/s24-d3-target-starts)" -eq 2
"${ctr[@]}" tasks list -q | sort >"$evidence/tasks-restarted.txt"
{ cat "$evidence/tasks-before.txt"; printf '%s\n' "$new_target" "$survivor"; } | sort -u >"$evidence/tasks-restarted-expected.txt"
cmp -s "$evidence/tasks-restarted-expected.txt" "$evidence/tasks-restarted.txt"
"${kube[@]}" exec "$pod" -c target -- true
"${kube[@]}" exec "$pod" -c survivor -- true
stop_observers
printf 'S24_D3_OK sandbox=%s pod_ip=%s startup_gate=ok readiness_http=fail_to_ready tcp_liveness=restart target_exit66=ok survivor=stable shim_identity=stable vm_inode=stable\n' "$sandbox" "$ip" | tee -a "$evidence/summary.txt"
delete_owned_pod
assert_baseline after
test $(( $(lease_records) - leases_before )) -eq 1
printf 'S24_D3_DONE active_leases=0 durable_tombstone_delta=1 evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
