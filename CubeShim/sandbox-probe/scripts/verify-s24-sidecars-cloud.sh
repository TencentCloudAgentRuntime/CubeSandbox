#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
job=cubesandbox-s24-d1
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
warm_mount=/run/cubesandbox-s24-d1-image-warmup
evidence=/data/cubelet/s2.4-evidence/d1-sidecar-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch=$(date +%s)
event_pid=
followers=()

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
    if state_matches_baseline "$tag"; then printf 'S24_D1_BASELINE_CLEAN wait_attempt=%s lease_records=%s\n' "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"; return 0; fi
    sleep .1
  done
  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime resources; do diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" >"$evidence/$kind-$tag.diff" 2>&1 || true; done
  return 1
}

delete_owned_job() {
  local remaining
  if "${kube[@]}" get job "$job" >/dev/null 2>&1; then
    test "$("${kube[@]}" get job "$job" -o jsonpath='{.metadata.labels.cubesandbox\.io/s24-owned}')" = true || return 1
    "${kube[@]}" delete job "$job" --wait=false >/dev/null
  fi
  for _ in $(seq 1 1200); do
    remaining=$("${kube[@]}" get pod -l "job-name=$job" -o name)
    if ! "${kube[@]}" get job "$job" >/dev/null 2>&1 && test -z "$remaining"; then return 0; fi
    sleep .1
  done
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
    index($0, " /tasks/exit ") &&
    index($0, "\"container_id\":\"" id "\"") &&
    index($0, "\"id\":\"" id "\"") {
      if ((status == 0 && !index($0, "\"exit_status\":")) ||
          (status != 0 && index($0, "\"exit_status\":" status))) {
        print NR
        exit
      }
    }
  ' "$evidence/events.txt"
}

main_exit_count() {
  local id=$1
  awk -v id="$id" '
    index($0, " /tasks/exit ") &&
    index($0, "\"container_id\":\"" id "\"") &&
    index($0, "\"id\":\"" id "\"") {count++}
    END {print count+0}
  ' "$evidence/events.txt"
}

wait_file_contains() {
  local file=$1 pattern=$2
  for _ in $(seq 1 1200); do
    if grep -Fq "$pattern" "$file" 2>/dev/null; then return 0; fi
    sleep .1
  done
  return 1
}

stop_observers() {
  local pid
  for pid in "${followers[@]}"; do kill -TERM "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; done
  followers=()
  if test -n "$event_pid"; then kill -TERM "$event_pid" >/dev/null 2>&1 || true; wait "$event_pid" >/dev/null 2>&1 || true; event_pid=; fi
}

cleanup() {
  local rc=$?
  set +e
  stop_observers
  "${kube[@]}" get job "$job" -o json >"$evidence/job-final.json" 2>&1 || true
  "${kube[@]}" get pod -l "job-name=$job" -o json >"$evidence/pod-final.json" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
  delete_owned_job
  if mountpoint -q "$warm_mount"; then "${ctr[@]}" images unmount --snapshotter overlayfs --rm "$warm_mount" >/dev/null 2>&1 || true; fi
  rmdir "$warm_mount" >/dev/null 2>&1 || true
  wait_runtime_idle
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT
delete_owned_job
wait_runtime_idle
install -d -m 0755 "$warm_mount"
"${ctr[@]}" images mount --snapshotter overlayfs docker.io/library/busybox:1.36.1 "$warm_mount" >"$evidence/image-warm-mount.txt"
"${ctr[@]}" images unmount --snapshotter overlayfs --rm "$warm_mount" >"$evidence/image-warm-unmount.txt"
rmdir "$warm_mount"
capture_state before
leases_before=$(lease_records)

timeout 1800s "${ctr[@]}" events >"$evidence/events.txt" 2>"$evidence/events.stderr" & event_pid=$!
"${kube[@]}" apply -f - >"$evidence/apply.txt" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  labels: {cubesandbox.io/s24-owned: "true"}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: {cubesandbox.io/s24-owned: "true"}
    spec:
      runtimeClassName: cube
      nodeName: $node
      automountServiceAccountToken: false
      restartPolicy: Never
      terminationGracePeriodSeconds: 12
      initContainers:
      - name: side-a
        image: docker.io/library/busybox:1.36.1
        restartPolicy: Always
        startupProbe:
          exec: {command: ["sh", "-c", "n=\$(cat /dev/shm/side-a-probes 2>/dev/null || echo 0); echo \$((n+1)) >/dev/shm/side-a-probes; test -e /dev/shm/side-a-ready || exit 1; echo yes >/dev/shm/side-a-startup-passed"]}
          periodSeconds: 1
          failureThreshold: 20
        command:
        - sh
        - -c
        - |
          trap 'if test -e /dev/shm/side-b-stopped; then echo SIDE_A_AFTER_B; else echo SIDE_A_EARLY; fi; echo yes >/dev/shm/side-a-stopped; exit 0' TERM
          echo SIDE_A_START
          sleep 3
          echo yes >/dev/shm/side-a-ready
          echo SIDE_A_READY
          while :; do sleep 1; done
      - name: regular-init
        image: docker.io/library/busybox:1.36.1
        command: ["sh", "-c", "test -e /dev/shm/side-a-startup-passed; test \$(cat /dev/shm/side-a-probes) -ge 1; echo REGULAR_INIT_AFTER_SIDE_A; echo yes >/dev/shm/regular-init"]
      - name: side-b
        image: docker.io/library/busybox:1.36.1
        restartPolicy: Always
        command:
        - sh
        - -c
        - |
          trap 'if test -e /dev/shm/app-exited; then echo SIDE_B_AFTER_APP; else echo SIDE_B_EARLY; fi; echo yes >/dev/shm/side-b-stopped; exit 0' TERM
          generation=\$(cat /dev/shm/side-b-generation 2>/dev/null || echo 0)
          generation=\$((generation + 1))
          echo \$generation >/dev/shm/side-b-generation
          echo SIDE_B_START generation=\$generation
          echo yes >/dev/shm/side-b-ready-\$generation
          while :; do
            if test -e /dev/shm/crash-side-b; then rm -f /dev/shm/crash-side-b; echo SIDE_B_EXIT_42; exit 42; fi
            sleep 1
          done
      containers:
      - name: app
        image: docker.io/library/busybox:1.36.1
        command:
        - sh
        - -c
        - |
          test -e /dev/shm/regular-init
          for i in \$(seq 1 100); do test -e /dev/shm/side-b-ready-1 && break; sleep .1; done
          test -e /dev/shm/side-b-ready-1
          echo APP_AFTER_INIT_AND_SIDECARS
          while test ! -e /dev/shm/release-app; do sleep 1; done
          echo yes >/dev/shm/app-exited
          echo APP_EXIT_0
          exit 0
EOF
pod=
for _ in $(seq 1 600); do pod=$("${kube[@]}" get pod -l "job-name=$job" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); test -n "$pod" && break; sleep .1; done
test -n "$pod"
"${kube[@]}" wait --for=condition=Ready "pod/$pod" --timeout=300s >"$evidence/wait.txt"
"${kube[@]}" get pod "$pod" -o json >"$evidence/before.json"
uid=$(jq -r '.metadata.uid' "$evidence/before.json")
ip=$(jq -r '.status.podIP' "$evidence/before.json")
sandbox=$(sandbox_for_uid "$uid")
shim=$(shim_pid_for_sandbox "$sandbox")
shim_start=$(awk '{print $22}' "/proc/$shim/stat")
vm_inode=$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")
side_a=$(jq -r '.status.initContainerStatuses[] | select(.name == "side-a") | .containerID | sub("^containerd://"; "")' "$evidence/before.json")
side_b=$(jq -r '.status.initContainerStatuses[] | select(.name == "side-b") | .containerID | sub("^containerd://"; "")' "$evidence/before.json")
app=$(jq -r '.status.containerStatuses[] | select(.name == "app") | .containerID | sub("^containerd://"; "")' "$evidence/before.json")
jq -e '.status.initContainerStatuses[] | select(.name == "side-a" and .started == true and .ready == true)' "$evidence/before.json" >/dev/null
jq -e '.status.initContainerStatuses[] | select(.name == "regular-init" and .state.terminated.exitCode == 0)' "$evidence/before.json" >/dev/null
jq -e '.status.initContainerStatuses[] | select(.name == "side-b" and .started == true)' "$evidence/before.json" >/dev/null
"${kube[@]}" logs "$pod" -c regular-init >"$evidence/regular-init.log"
grep -Fq REGULAR_INIT_AFTER_SIDE_A "$evidence/regular-init.log"

"${kube[@]}" logs -f "$pod" -c side-a >"$evidence/side-a.log" 2>&1 & followers+=("$!")
"${kube[@]}" logs -f "$pod" -c side-b >"$evidence/side-b-first.log" 2>&1 & followers+=("$!")
"${kube[@]}" logs -f "$pod" -c app >"$evidence/app.log" 2>&1 & followers+=("$!")
wait_file_contains "$evidence/side-a.log" SIDE_A_READY
wait_file_contains "$evidence/side-b-first.log" 'SIDE_B_START generation=1'
wait_file_contains "$evidence/app.log" APP_AFTER_INIT_AND_SIDECARS
kill -0 "$event_pid"
"${kube[@]}" exec "$pod" -c app -- sh -c 'echo yes >/dev/shm/crash-side-b'
side_b_new=
for _ in $(seq 1 1200); do
  "${kube[@]}" get pod "$pod" -o json >"$evidence/after-side-b-restart.json"
  side_b_new=$(jq -r --arg old "$side_b" '.status.initContainerStatuses[]? | select(.name == "side-b" and .state.running != null and .restartCount == 1 and .lastState.terminated.exitCode == 42) | .containerID | sub("^containerd://"; "") | select(. != $old)' "$evidence/after-side-b-restart.json")
  test -n "$side_b_new" && break
  sleep .1
done
test -n "$side_b_new"
test "$(jq -r '.status.initContainerStatuses[] | select(.name == "side-a") | .containerID | sub("^containerd://"; "")' "$evidence/after-side-b-restart.json")" = "$side_a"
test "$(jq -r '.status.containerStatuses[] | select(.name == "app") | .containerID | sub("^containerd://"; "")' "$evidence/after-side-b-restart.json")" = "$app"
test "$(jq -r '.metadata.uid' "$evidence/after-side-b-restart.json")" = "$uid"
test "$(jq -r '.status.podIP' "$evidence/after-side-b-restart.json")" = "$ip"
test "$(sandbox_for_uid "$uid")" = "$sandbox"
test "$(shim_pid_for_sandbox "$sandbox")" = "$shim"
test "$(awk '{print $22}' "/proc/$shim/stat")" = "$shim_start"
test "$(stat -Lc '%d:%i' "$vm_runtime/$sandbox")" = "$vm_inode"
for _ in $(seq 1 600); do
  if "${kube[@]}" exec "$pod" -c app -- test -e /dev/shm/side-b-ready-2 >/dev/null 2>&1; then break; fi
  sleep .1
done
"${kube[@]}" exec "$pod" -c app -- test -e /dev/shm/side-b-ready-2
"${ctr[@]}" tasks list -q | sort >"$evidence/tasks-after-restart.txt"
{ cat "$evidence/tasks-before.txt"; printf '%s\n' "$side_a" "$side_b_new" "$app"; } | sort -u >"$evidence/tasks-after-restart-expected.txt"
cmp -s "$evidence/tasks-after-restart-expected.txt" "$evidence/tasks-after-restart.txt"
"${kube[@]}" logs -f "$pod" -c side-b >"$evidence/side-b-second.log" 2>&1 & followers+=("$!")
wait_file_contains "$evidence/side-b-second.log" 'SIDE_B_START generation=2'
"${kube[@]}" exec "$pod" -c app -- sh -c 'echo yes >/dev/shm/release-app'
"${kube[@]}" wait --for=condition=complete "job/$job" --timeout=300s >"$evidence/job-complete.txt"
"${kube[@]}" get pod "$pod" -o json >"$evidence/completed.json"
jq -e '.status.phase == "Succeeded"' "$evidence/completed.json" >/dev/null
jq -e '.status.containerStatuses[] | select(.name == "app" and .state.terminated.exitCode == 0)' "$evidence/completed.json" >/dev/null
jq -e '.status.initContainerStatuses[] | select(.name == "side-a" and .state.terminated.exitCode == 0)' "$evidence/completed.json" >/dev/null
jq -e '.status.initContainerStatuses[] | select(.name == "side-b" and .state.terminated.exitCode == 0 and .restartCount == 1 and .lastState.terminated.exitCode == 42)' "$evidence/completed.json" >/dev/null
wait_file_contains "$evidence/side-b-first.log" SIDE_B_EXIT_42
wait_file_contains "$evidence/app.log" APP_EXIT_0
wait_file_contains "$evidence/side-b-second.log" SIDE_B_AFTER_APP
wait_file_contains "$evidence/side-a.log" SIDE_A_AFTER_B
! grep -Eq 'SIDE_[AB]_EARLY' "$evidence/side-a.log" "$evidence/side-b-second.log"
for _ in $(seq 1 1200); do
  side_b_crash_event=$(main_exit_line "$side_b" 42)
  app_event=$(main_exit_line "$app" 0)
  side_b_event=$(main_exit_line "$side_b_new" 0)
  side_a_event=$(main_exit_line "$side_a" 0)
  if test -n "$side_b_crash_event" -a -n "$app_event" -a -n "$side_b_event" -a -n "$side_a_event"; then break; fi
  sleep .1
done
test -n "$side_b_crash_event" -a -n "$app_event" -a -n "$side_b_event" -a -n "$side_a_event"
test "$(main_exit_count "$side_b")" -eq 1
test "$(main_exit_count "$app")" -eq 1
test "$(main_exit_count "$side_b_new")" -eq 1
test "$(main_exit_count "$side_a")" -eq 1
test "$side_b_crash_event" -lt "$app_event"
test "$app_event" -lt "$side_b_event" -a "$side_b_event" -lt "$side_a_event"
stop_observers
printf 'S24_D1_OK pod=%s sandbox=%s pod_ip=%s sidecar_startup_gate=ok side_b_exit42_restart=ok job_complete=ok taskexit_order=app,side-b,side-a shim_identity=stable vm_inode=stable\n' "$pod" "$sandbox" "$ip" | tee -a "$evidence/summary.txt"
delete_owned_job
assert_baseline after
test $(( $(lease_records) - leases_before )) -eq 1
printf 'S24_D1_DONE active_leases=0 durable_tombstone_delta=1 evidence=%s\n' "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
