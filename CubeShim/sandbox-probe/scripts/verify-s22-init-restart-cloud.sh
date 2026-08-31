#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
expected_shim_sha=39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
init_success=cubesandbox-s22-init-success
init_retry=cubesandbox-s22-init-retry
app_restart=cubesandbox-s22-app-restart
pods=("$init_success" "$init_retry" "$app_restart")
evidence=/data/cubelet/s2.2-evidence/init-restart-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch="$(date +%s)"

count_entries() {
  if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi
}

count_files() {
  if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi
}

active_leases() {
  local count=0 record
  while IFS= read -r record; do
    if ! jq -e '.active == null' "$record" >/dev/null; then count=$((count + 1)); fi
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print 2>/dev/null)
  echo "$count"
}

lease_records() {
  find "$runtime_state/leases" -type f -name '*.json' 2>/dev/null | wc -l
}

capture_state() {
  local tag=$1
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt"
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt"
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt"
  find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n' 2>/dev/null \
    | sort >"$evidence/netns-$tag.txt"
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort \
    >"$evidence/cube-shims-$tag.txt"
  ps -eo pid=,args= | awk '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && /cube-runtime-reaper/ {print}' | sort \
    >"$evidence/cube-reapers-$tag.txt"
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P %y\n' 2>/dev/null || true; fi; } \
    | sort >"$evidence/vm-runtime-$tag.txt"
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s lease_records=%s\n' \
    "$(count_files "$runtime_state/adapter")" "$(count_entries "$shared")" \
    "$(count_entries "$reaper")" \
    "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" \
    "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" \
    "$(active_leases)" "$(lease_records)" >"$evidence/resources-$tag.txt"
}

state_matches_baseline() {
  local tag=$1
  cmp -s "$evidence/containers-before.txt" "$evidence/containers-$tag.txt" \
    && cmp -s "$evidence/tasks-before.txt" "$evidence/tasks-$tag.txt" \
    && cmp -s "$evidence/sandboxes-before.txt" "$evidence/sandboxes-$tag.txt" \
    && cmp -s "$evidence/snapshots-before.txt" "$evidence/snapshots-$tag.txt" \
    && cmp -s "$evidence/netns-before.txt" "$evidence/netns-$tag.txt" \
    && cmp -s "$evidence/cube-shims-before.txt" "$evidence/cube-shims-$tag.txt" \
    && cmp -s "$evidence/cube-reapers-before.txt" "$evidence/cube-reapers-$tag.txt" \
    && cmp -s "$evidence/vm-runtime-before.txt" "$evidence/vm-runtime-$tag.txt" \
    && test "$(count_files "$runtime_state/adapter")" -eq 0 \
    && test "$(count_entries "$shared")" -eq 0 \
    && test "$(count_entries "$reaper")" -eq 0 \
    && test "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0 \
    && test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0 \
    && test "$(active_leases)" -eq 0
}

assert_baseline() {
  local tag=$1 attempt
  for attempt in $(seq 1 1200); do
    capture_state "$tag"
    if state_matches_baseline "$tag"; then
      printf 'S22_BASELINE_CLEAN case=%s wait_attempt=%s lease_records=%s\n' \
        "$tag" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep 0.1
  done
  capture_state "$tag"
  for kind in containers tasks sandboxes snapshots netns cube-shims cube-reapers vm-runtime resources; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" \
      >"$evidence/$kind-$tag.diff" 2>&1 || true
  done
  return 1
}

delete_owned_one() {
  local pod=$1
  if "${kube[@]}" get pod "$pod" >/dev/null 2>&1; then
    test "$("${kube[@]}" get pod "$pod" -o jsonpath='{.metadata.labels.cubesandbox\.io/s22-owned}')" = true \
      || { printf 'refusing to delete non-owned pod %s\n' "$pod" >&2; return 1; }
    "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null
  fi
  for _ in $(seq 1 1200); do
    if ! "${kube[@]}" get pod "$pod" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
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
    sleep 0.1
  done
  return 1
}

sandbox_for_uid() {
  local ids count
  ids="$("${cri[@]}" pods -o json \
    | jq -r --arg uid "$1" '.items[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | .id')" \
    || return 1
  count="$(printf '%s\n' "$ids" | awk 'NF {count++} END {print count+0}')"
  test "$count" -eq 1 || return 1
  printf '%s\n' "$ids"
}

shim_pid_for_sandbox() {
  local pids count
  pids="$(ps -eo pid=,args= \
    | awk -v id="$1" '$2 ~ /(^|\/)containerd-shim-cube-rs$/ && index($0,id) {print $1}')" \
    || return 1
  count="$(printf '%s\n' "$pids" | awk 'NF {count++} END {print count+0}')"
  test "$count" -eq 1 || return 1
  printf '%s\n' "$pids"
}

active_shared_root() {
  local roots count
  test "$(count_files "$runtime_state/adapter")" -eq 1 || return 1
  roots="$(find "$shared" -mindepth 1 -maxdepth 1 -type d -print)" || return 1
  count="$(printf '%s\n' "$roots" | awk 'NF {count++} END {print count+0}')"
  test "$count" -eq 1 || return 1
  printf '%s\n' "$roots"
}

assert_export() {
  local rootfs=$1 id=$2 expected=$3
  test "$(find "$rootfs" -mindepth 1 -maxdepth 1 -type d -name "$id-*" 2>/dev/null | wc -l)" -eq "$expected"
}

save_diagnostics() {
  local pod
  for pod in "${pods[@]}"; do
    "${kube[@]}" get pod "$pod" -o json >"$evidence/$pod-final.json" 2>&1 || true
  done
  "${cri[@]}" pods >"$evidence/cri-pods.txt" 2>&1 || true
  "${cri[@]}" ps -a >"$evidence/cri-containers.txt" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
}

cleanup() {
  local rc=$? pod
  set +e
  save_diagnostics
  for pod in "${pods[@]}"; do delete_owned_one "$pod"; done
  wait_runtime_idle
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

systemctl is-active --quiet containerd
systemctl is-active --quiet cubesandbox-s13-runtime-resource.service
test "$(sha256sum /usr/local/bin/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
test "$(sha256sum /opt/cubesandbox-s14-runtime-artifacts-sandbox-spec-v1/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
"${kube[@]}" get --raw=/readyz | grep -Fxq ok
"${kube[@]}" get node "$node" -o json \
  | jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' >/dev/null
for pod in "${pods[@]}"; do delete_owned_one "$pod"; done
wait_runtime_idle
capture_state before
leases_before="$(lease_records)"

"${kube[@]}" apply -f - >"$evidence/init-success-apply.txt" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $init_success
  labels: {cubesandbox.io/s22-owned: "true"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 2
  initContainers:
  - name: init-one
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "echo init-one; sleep 2"]
  - name: init-two
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "echo init-two; sleep 2"]
  containers:
  - name: app
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "echo app-started; sleep 600"]
EOF
"${kube[@]}" wait --for=condition=Ready "pod/$init_success" --timeout=300s >"$evidence/init-success-wait.txt"
"${kube[@]}" get pod "$init_success" -o json >"$evidence/init-success.json"
jq -e '
  (.status.initContainerStatuses | length) == 2 and
  ([.status.initContainerStatuses[] | select(.restartCount == 0 and .state.terminated.exitCode == 0)] | length) == 2 and
  (.status.initContainerStatuses[0].state.terminated.finishedAt <= .status.initContainerStatuses[1].state.terminated.startedAt) and
  (.status.initContainerStatuses[1].state.terminated.finishedAt <= .status.containerStatuses[0].state.running.startedAt)
' "$evidence/init-success.json" >/dev/null
"${kube[@]}" logs "$init_success" -c init-one >"$evidence/init-one.log"
"${kube[@]}" logs "$init_success" -c init-two >"$evidence/init-two.log"
"${kube[@]}" logs "$init_success" -c app >"$evidence/init-success-app.log"
grep -Fxq init-one "$evidence/init-one.log"
grep -Fxq init-two "$evidence/init-two.log"
grep -Fxq app-started "$evidence/init-success-app.log"
success_uid="$(jq -r '.metadata.uid' "$evidence/init-success.json")"
success_sandbox="$(sandbox_for_uid "$success_uid")"
success_app="$(jq -r '.status.containerStatuses[0].containerID | sub("^containerd://"; "")' "$evidence/init-success.json")"
mapfile -t success_init_ids < <(jq -r '.status.initContainerStatuses[].containerID | sub("^containerd://"; "")' "$evidence/init-success.json")
test "${#success_init_ids[@]}" -eq 2
grep -Fxq "$success_app" < <("${ctr[@]}" tasks list -q)
for id in "${success_init_ids[@]}"; do ! grep -Fxq "$id" < <("${ctr[@]}" tasks list -q); done
success_rootfs="$(active_shared_root)/rootfs"
test "$(find "$success_rootfs" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1
assert_export "$success_rootfs" "$success_app" 1
for id in "${success_init_ids[@]}"; do assert_export "$success_rootfs" "$id" 0; done
test -d "$vm_runtime/$success_sandbox"
printf 'S22_INIT_SUCCESS_OK sandbox=%s init=2 app=%s strict_order=ok stale_init_tasks=0 stale_init_rootfs=0\n' \
  "$success_sandbox" "$success_app" | tee -a "$evidence/summary.txt"
"${kube[@]}" delete pod "$init_success" --wait=true >"$evidence/init-success-delete.txt"
assert_baseline after-init-success
test $(( $(lease_records) - leases_before )) -eq 1

"${kube[@]}" apply -f - >"$evidence/init-retry-apply.txt" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $init_retry
  labels: {cubesandbox.io/s22-owned: "true"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Always
  terminationGracePeriodSeconds: 2
  initContainers:
  - name: init-flaky
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "echo init-attempt; sleep 6; exit 42"]
  containers:
  - name: app
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "echo app-must-not-start; sleep 600"]
EOF
for _ in $(seq 1 1200); do
  "${kube[@]}" get pod "$init_retry" -o json >"$evidence/init-retry-first.json"
  if jq -e '.status.initContainerStatuses[0].restartCount == 0 and .status.initContainerStatuses[0].state.running != null' "$evidence/init-retry-first.json" >/dev/null; then break; fi
  sleep 0.1
done
jq -e '.status.initContainerStatuses[0].restartCount == 0 and .status.initContainerStatuses[0].state.running != null' "$evidence/init-retry-first.json" >/dev/null
retry_uid="$(jq -r '.metadata.uid' "$evidence/init-retry-first.json")"
retry_ip="$(jq -r '.status.podIP' "$evidence/init-retry-first.json")"
test -n "$retry_uid"
test "$retry_uid" != null
test -n "$retry_ip"
test "$retry_ip" != null
retry_sandbox="$(sandbox_for_uid "$retry_uid")"
retry_first="$(jq -r '.status.initContainerStatuses[0].containerID | sub("^containerd://"; "")' "$evidence/init-retry-first.json")"
retry_shim="$(shim_pid_for_sandbox "$retry_sandbox")"
test -n "$retry_shim"
retry_rootfs="$(active_shared_root)/rootfs"
test "$(find "$retry_rootfs" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1
assert_export "$retry_rootfs" "$retry_first" 1
for _ in $(seq 1 1800); do
  "${kube[@]}" get pod "$init_retry" -o json >"$evidence/init-retry-second.json"
  if jq -e '.status.initContainerStatuses[0].restartCount == 1 and .status.initContainerStatuses[0].state.running != null' "$evidence/init-retry-second.json" >/dev/null; then break; fi
  sleep 0.1
done
jq -e '.status.initContainerStatuses[0].restartCount == 1 and .status.initContainerStatuses[0].state.running != null and .status.initContainerStatuses[0].lastState.terminated.exitCode == 42' \
  "$evidence/init-retry-second.json" >/dev/null
jq -e '(.status.containerStatuses | length) == 1 and .status.containerStatuses[0].name == "app" and .status.containerStatuses[0].containerID == null and .status.containerStatuses[0].state.waiting.reason == "PodInitializing"' \
  "$evidence/init-retry-second.json" >/dev/null
retry_second="$(jq -r '.status.initContainerStatuses[0].containerID | sub("^containerd://"; "")' "$evidence/init-retry-second.json")"
test "$retry_second" != "$retry_first"
test "$(jq -r '.metadata.uid' "$evidence/init-retry-second.json")" = "$retry_uid"
test "$(jq -r '.status.podIP' "$evidence/init-retry-second.json")" = "$retry_ip"
test "$(sandbox_for_uid "$retry_uid")" = "$retry_sandbox"
test "$(shim_pid_for_sandbox "$retry_sandbox")" = "$retry_shim"
! grep -Fxq "$retry_first" < <("${ctr[@]}" tasks list -q)
grep -Fxq "$retry_second" < <("${ctr[@]}" tasks list -q)
assert_export "$retry_rootfs" "$retry_first" 0
assert_export "$retry_rootfs" "$retry_second" 1
test "$(find "$retry_rootfs" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1
"${cri[@]}" ps -o json >"$evidence/init-retry-cri-running.json"
jq -r --arg uid "$retry_uid" '.containers[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | [.metadata.name,.id,.state,.podSandboxId] | @tsv' \
  "$evidence/init-retry-cri-running.json" >"$evidence/init-retry-running.tsv"
test "$(wc -l <"$evidence/init-retry-running.tsv")" -eq 1
awk -v id="$retry_second" -v sid="$retry_sandbox" '$1 != "init-flaky" || $2 != id || $3 != "CONTAINER_RUNNING" || $4 != sid {exit 1}' \
  "$evidence/init-retry-running.tsv"
"${kube[@]}" logs "$init_retry" -c init-flaky --previous >"$evidence/init-retry-previous.log"
grep -Fxq init-attempt "$evidence/init-retry-previous.log"
test -d "$vm_runtime/$retry_sandbox"
printf 'S22_INIT_RETRY_OK sandbox=%s deleted=%s replacement=%s exit=42 restart_count=1 app_started=0 shim_pid_stable=ok\n' \
  "$retry_sandbox" "$retry_first" "$retry_second" | tee -a "$evidence/summary.txt"
"${kube[@]}" delete pod "$init_retry" --wait=true >"$evidence/init-retry-delete.txt"
assert_baseline after-init-retry
test $(( $(lease_records) - leases_before )) -eq 2

"${kube[@]}" apply -f - >"$evidence/app-restart-apply.txt" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $app_restart
  labels: {cubesandbox.io/s22-owned: "true"}
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Always
  terminationGracePeriodSeconds: 2
  containers:
  - name: alpha
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "echo alpha-attempt; sleep 8; exit 23"]
  - name: beta
    image: docker.io/library/busybox:1.36.1
    command: ["sh", "-c", "echo beta-started; sleep 600"]
EOF
"${kube[@]}" wait --for=condition=Ready "pod/$app_restart" --timeout=300s >"$evidence/app-restart-first-wait.txt"
"${kube[@]}" get pod "$app_restart" -o json >"$evidence/app-restart-first.json"
app_uid="$(jq -r '.metadata.uid' "$evidence/app-restart-first.json")"
app_ip="$(jq -r '.status.podIP' "$evidence/app-restart-first.json")"
test -n "$app_uid"
test "$app_uid" != null
test -n "$app_ip"
test "$app_ip" != null
app_sandbox="$(sandbox_for_uid "$app_uid")"
alpha_first="$(jq -r '.status.containerStatuses[] | select(.name == "alpha") | .containerID | sub("^containerd://"; "")' "$evidence/app-restart-first.json")"
beta_id="$(jq -r '.status.containerStatuses[] | select(.name == "beta") | .containerID | sub("^containerd://"; "")' "$evidence/app-restart-first.json")"
app_shim="$(shim_pid_for_sandbox "$app_sandbox")"
test -n "$app_shim"
app_rootfs="$(active_shared_root)/rootfs"
test "$(find "$app_rootfs" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2
assert_export "$app_rootfs" "$alpha_first" 1
assert_export "$app_rootfs" "$beta_id" 1
for _ in $(seq 1 1800); do
  "${kube[@]}" get pod "$app_restart" -o json >"$evidence/app-restart-second.json"
  if jq -e '.status.containerStatuses[] | select(.name == "alpha" and .restartCount == 1 and .ready == true and .state.running != null)' "$evidence/app-restart-second.json" >/dev/null \
    && jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' "$evidence/app-restart-second.json" >/dev/null; then break; fi
  sleep 0.1
done
jq -e '.status.containerStatuses[] | select(.name == "alpha" and .restartCount == 1 and .ready == true and .state.running != null and .lastState.terminated.exitCode == 23)' \
  "$evidence/app-restart-second.json" >/dev/null
jq -e '.status.containerStatuses[] | select(.name == "beta" and .restartCount == 0 and .ready == true and .state.running != null)' \
  "$evidence/app-restart-second.json" >/dev/null
alpha_second="$(jq -r '.status.containerStatuses[] | select(.name == "alpha") | .containerID | sub("^containerd://"; "")' "$evidence/app-restart-second.json")"
test "$alpha_second" != "$alpha_first"
test "$(jq -r '.status.containerStatuses[] | select(.name == "beta") | .containerID | sub("^containerd://"; "")' "$evidence/app-restart-second.json")" = "$beta_id"
test "$(jq -r '.metadata.uid' "$evidence/app-restart-second.json")" = "$app_uid"
test "$(jq -r '.status.podIP' "$evidence/app-restart-second.json")" = "$app_ip"
test "$(sandbox_for_uid "$app_uid")" = "$app_sandbox"
test "$(shim_pid_for_sandbox "$app_sandbox")" = "$app_shim"
! grep -Fxq "$alpha_first" < <("${ctr[@]}" tasks list -q)
grep -Fxq "$alpha_second" < <("${ctr[@]}" tasks list -q)
grep -Fxq "$beta_id" < <("${ctr[@]}" tasks list -q)
assert_export "$app_rootfs" "$alpha_first" 0
assert_export "$app_rootfs" "$alpha_second" 1
assert_export "$app_rootfs" "$beta_id" 1
test "$(find "$app_rootfs" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2
"${cri[@]}" ps -o json >"$evidence/app-restart-cri-running.json"
jq -r --arg uid "$app_uid" '.containers[] | select(.labels["io.kubernetes.pod.uid"] == $uid) | [.metadata.name,.id,.state,.podSandboxId] | @tsv' \
  "$evidence/app-restart-cri-running.json" | sort >"$evidence/app-restart-running.tsv"
test "$(wc -l <"$evidence/app-restart-running.tsv")" -eq 2
awk -v sid="$app_sandbox" '$3 != "CONTAINER_RUNNING" || $4 != sid {exit 1}' "$evidence/app-restart-running.tsv"
test "$(awk '$1 == "alpha" {print $2}' "$evidence/app-restart-running.tsv")" = "$alpha_second"
test "$(awk '$1 == "beta" {print $2}' "$evidence/app-restart-running.tsv")" = "$beta_id"
"${kube[@]}" logs "$app_restart" -c alpha --previous >"$evidence/alpha-previous.log"
grep -Fxq alpha-attempt "$evidence/alpha-previous.log"
"${kube[@]}" exec "$app_restart" -c beta -- sh -c 'printf beta-survived' >"$evidence/beta-survived.exec"
grep -Fxq beta-survived "$evidence/beta-survived.exec"
test -d "$vm_runtime/$app_sandbox"
printf 'S22_APP_RESTART_OK sandbox=%s deleted=%s replacement=%s survivor=%s exit=23 restart_count=1 pod_ready=ok shim_pid_stable=ok\n' \
  "$app_sandbox" "$alpha_first" "$alpha_second" "$beta_id" | tee -a "$evidence/summary.txt"
"${kube[@]}" delete pod "$app_restart" --wait=true >"$evidence/app-restart-delete.txt"
assert_baseline after-app-restart
leases_after="$(lease_records)"
test $((leases_after - leases_before)) -eq 3
save_diagnostics
printf 'S22_INIT_RESTART_OK cases=3 strict_init_order=ok init_retry_exit=42 app_restart_exit=23 survivor=ok active_leases=0 durable_tombstone_delta=3 vm_runtime=baseline shim_sha256=%s evidence=%s\n' \
  "$expected_shim_sha" "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
