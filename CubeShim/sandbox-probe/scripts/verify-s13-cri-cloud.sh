#!/usr/bin/env bash
set -euo pipefail

artifact=/opt/cubesandbox-s12-runtime-artifacts-rootfs-inode
agent_artifact=/opt/cubesandbox-s12-agent-exit-status-v1
live=/data/cubelet/s13-cri-live
run_dir=/run/cubesandbox-s13
evidence=/data/cubelet/s1.3-evidence/diagnostic-$(date -u +%Y%m%dT%H%M%SZ)
socket=$run_dir/containerd.sock
state=$run_dir/containerd-state
root=$live/containerd-root
shared=$live/shared
assets=$live/assets
reaper=$live/reaper
grpc_socket=$run_dir/runtime-resource.sock
fd_socket=$run_dir/runtime-resource-fd.sock
image_ref=mirror.ccs.tencentyun.com/library/busybox:1.36.1
image_archive=$run_dir/busybox-linux-amd64.tar
pod_id=
pod_check_id=
handler_id=
ignore_id=
containerd_pid=
harness_pid=

cri() {
  crictl --runtime-endpoint "unix://$socket" --image-endpoint "unix://$socket" --timeout 180s "$@"
}

count_entries() {
  if test -d "$1"; then
    find "$1" -mindepth 1 | wc -l
  else
    echo 0
  fi
}

count_files() {
  if test -d "$1"; then
    find "$1" -type f | wc -l
  else
    echo 0
  fi
}

stop_process() {
  local pid=${1:-}
  test -n "$pid" || return 0
  kill -TERM "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 100); do
    kill -0 "$pid" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  local rc=$?
  set +e
  test -n "$handler_id" && cri stop --timeout 0 "$handler_id" >/dev/null 2>&1
  test -n "$handler_id" && cri rm -f "$handler_id" >/dev/null 2>&1
  test -n "$ignore_id" && cri stop --timeout 0 "$ignore_id" >/dev/null 2>&1
  test -n "$ignore_id" && cri rm -f "$ignore_id" >/dev/null 2>&1
  test -n "$pod_id" && cri stopp "$pod_id" >/dev/null 2>&1
  test -n "$pod_id" && cri rmp -f "$pod_id" >/dev/null 2>&1
  stop_process "$containerd_pid"
  stop_process "$harness_pid"
  exit "$rc"
}
trap cleanup EXIT

(cd "$artifact" && sha256sum -c SHA256SUMS)
(cd "$agent_artifact" && sha256sum -c SHA256SUMS)
test -c /dev/kvm
test -x /opt/cni/bin/cilium-cni
test -s /etc/cni/net.d/05-cilium.conflist

for pid_file in "$live/containerd.pid" "$live/harness.pid"; do
  if test -r "$pid_file"; then
    stale_pid="$(cat "$pid_file")"
    if test -n "$stale_pid" && test -r "/proc/$stale_pid/cmdline" && tr '\0' ' ' < "/proc/$stale_pid/cmdline" | grep -Fq cubesandbox-s13; then
      stop_process "$stale_pid"
    fi
  fi
done
test "$live" = /data/cubelet/s13-cri-live
test "$run_dir" = /run/cubesandbox-s13
rm -rf "$live" "$run_dir"
install -d -m 0700 "$live/state" "$reaper" "$run_dir" "$state" "$evidence"
install -d -m 0711 "$shared" "$assets"
install -d -m 0755 "$live/bin" "$live/pod-logs"
trap 'rc=$?; printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$rc" "$BASH_COMMAND" >> "$evidence/trace.log"; exit "$rc"' ERR
ln -s /data/cubelet/s0.2-assets/kernel/vmlinux "$assets/kernel"
ln -s "$agent_artifact/agent/cube-agent.ext4" "$assets/agent"
ln -s /data/cubelet/s0.2-assets/guest/cube-guest-image-cpu.img "$assets/guest.img"
ln -s "$artifact/containerd-shim-cube-rs" "$live/bin/containerd-shim-cube-rs"
resolved_shim="$(PATH="$live/bin:$PATH" command -v containerd-shim-cube-rs)"
test "$(readlink -f "$resolved_shim")" = "$(readlink -f "$artifact/containerd-shim-cube-rs")"
test "$(sha256sum "$resolved_shim" | awk '{print $1}')" = \
  "$(sha256sum "$artifact/containerd-shim-cube-rs" | awk '{print $1}')"

ctr --address /run/containerd/containerd.sock --namespace k8s.io images export \
  --platform linux/amd64 "$image_archive" "$image_ref" >"$evidence/image-export.log" 2>&1
test -s "$image_archive"

cat > "$live/containerd.toml" <<EOF
version = 4
root = '$root'
state = '$state'

[debug]
  level = 'debug'

[plugins]
  [plugins.'io.containerd.cri.v1.images']
    snapshotter = 'overlayfs'
    disable_snapshot_annotations = true
    [plugins.'io.containerd.cri.v1.images'.pinned_images]
      sandbox = '$image_ref'

  [plugins.'io.containerd.cri.v1.runtime']
    netns_mounts_under_state_dir = true
    drain_exec_sync_io_timeout = '5s'
    [plugins.'io.containerd.cri.v1.runtime'.containerd]
      default_runtime_name = 'cube-s13'
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes]
        [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.cube-s13]
          runtime_type = 'io.containerd.cube.rs'
          runtime_path = '$artifact/containerd-shim-cube-rs'
          sandboxer = 'shim'
          cni_conf_dir = '/etc/cni/net.d'
          cni_max_conf_num = 1

    [plugins.'io.containerd.cri.v1.runtime'.cni]
      bin_dirs = ['/opt/cni/bin']
      conf_dir = '/etc/cni/net.d'
      max_conf_num = 1
      setup_serially = true
      use_internal_loopback = true

  [plugins.'io.containerd.grpc.v1.cri']
    stream_server_address = '127.0.0.1'
    stream_server_port = '0'

  [plugins.'io.containerd.nri.v1.nri']
    disable = true
  [plugins.'io.containerd.server.v1.grpc']
    address = '$socket'
  [plugins.'io.containerd.server.v1.ttrpc']
    address = '$socket.ttrpc'
  [plugins.'io.containerd.shim.v1.manager']
    socket_dir = '$run_dir/shim-sockets'
EOF

cat > "$live/pod.json" <<EOF
{
  "metadata": {"name": "cube-s13-cri", "namespace": "default", "uid": "cube-s13-cri", "attempt": 1},
  "log_directory": "$live/pod-logs",
  "dns_config": {"servers": ["10.96.0.10"], "searches": ["default.svc.cluster.local"], "options": ["ndots:5"]},
  "linux": {}
}
EOF

write_container_config() {
  local name=$1 command=$2 log_path=$3
  jq -n --arg name "$name" --arg image "$image_ref" --arg command "$command" --arg log "$log_path" '{
    metadata: {name: $name, attempt: 1},
    image: {image: $image},
    command: ["/bin/sh", "-c", $command],
    log_path: $log,
    stdin: false,
    stdin_once: false,
    tty: false,
    linux: {}
  }' > "$live/$name.json"
}

S11_RUNTIME_HARNESS_SHARED_ROOT="$shared" \
  "$artifact/s11-live-runtime-harness" \
  "$live/state" "$grpc_socket" "$fd_socket" "$assets" "$reaper" \
  >"$evidence/runtime-resource.log" 2>&1 &
harness_pid=$!
printf '%s\n' "$harness_pid" > "$live/harness.pid"
for _ in $(seq 1 300); do
  test -S "$grpc_socket" && grep -Fq S11_LIVE_RUNTIME_HARNESS_READY "$evidence/runtime-resource.log" && break
  kill -0 "$harness_pid"
  sleep 0.1
done
test -S "$grpc_socket"

PATH="$live/bin:$PATH" \
CUBE_RUNTIME_RESOURCE_ENDPOINT="$grpc_socket" \
CUBE_RUNTIME_RESOURCE_REAPER_DIR="$reaper" \
  /usr/local/bin/containerd --config "$live/containerd.toml" \
  >"$evidence/containerd.log" 2>&1 &
containerd_pid=$!
printf '%s\n' "$containerd_pid" > "$live/containerd.pid"
for _ in $(seq 1 300); do
  test -S "$socket" && break
  kill -0 "$containerd_pid"
  sleep 0.1
done
test -S "$socket"

ctr --address "$socket" --namespace k8s.io images import --platform linux/amd64 \
  "$image_archive" >"$evidence/image-import.log" 2>&1
ctr --address "$socket" --namespace k8s.io snapshots --snapshotter overlayfs list \
  | awk 'NR > 1 && NF {print $1}' | sort > "$evidence/snapshots-before.txt"
test -s "$evidence/snapshots-before.txt"
for _ in $(seq 1 120); do
  if cri info >/dev/null 2>&1; then break; fi
  sleep 0.25
done
cri info > "$evidence/cri-info.json"
ctr --address "$socket" plugins list > "$evidence/plugins.txt"
awk '$1 == "io.containerd.cri.v1" && $2 == "images" && $4 == "ok" {images=1}
     $1 == "io.containerd.cri.v1" && $2 == "runtime" && $4 == "ok" {runtime=1}
     END {exit !(images && runtime)}' "$evidence/plugins.txt"

pod_id="$(cri runp --runtime cube-s13 "$live/pod.json")"
test -n "$pod_id"
pod_check_id="$pod_id"
pod_state="$(cri inspectp "$pod_id" | jq -r '.status.state')"
pod_ip="$(cri inspectp "$pod_id" | jq -r '.status.network.ip')"
test "$pod_state" = SANDBOX_READY
test -n "$pod_ip"

handler_command="trap 'echo cube-s13-term; exit 42' TERM; echo cube-s13-started; while :; do sleep 1; done"
write_container_config handler "$handler_command" handler.log
handler_id="$(cri create "$pod_id" "$live/handler.json" "$live/pod.json")"
cri start "$handler_id" >/dev/null
for _ in $(seq 1 120); do
  cri logs "$handler_id" 2>/dev/null | grep -Fq cube-s13-started && break
  sleep 0.25
done
cri logs "$handler_id" > "$evidence/handler-before-stop.log"
grep -Fq cube-s13-started "$evidence/handler-before-stop.log"
test -s "$live/pod-logs/handler.log"
cp "$live/pod-logs/handler.log" "$evidence/handler-cri-format.log"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ stdout [FP] cube-s13-started$' "$evidence/handler-cri-format.log"

cri exec --sync --timeout 10 "$handler_id" sh -c "printf 'cube-s13-sync-out'; printf 'cube-s13-sync-err' >&2" \
  >"$evidence/exec-sync.stdout" 2>"$evidence/exec-sync.stderr"
grep -Fq cube-s13-sync-out "$evidence/exec-sync.stdout"
grep -Fq cube-s13-sync-err "$evidence/exec-sync.stdout"

if cri exec --sync --timeout 10 "$handler_id" sh -c "printf 'cube-s13-sync-fail-err' >&2; exit 17" \
  >"$evidence/exec-sync-nonzero.stdout" 2>"$evidence/exec-sync-nonzero.stderr"; then
  sync_nonzero_rc=0
else
  sync_nonzero_rc=$?
fi
printf '%s\n' "$sync_nonzero_rc" > "$evidence/exec-sync-nonzero.rc"
test "$sync_nonzero_rc" -eq 1
grep -Fq cube-s13-sync-fail-err "$evidence/exec-sync-nonzero.stderr"
grep -Fq 'exited with 17' "$evidence/exec-sync-nonzero.stderr"

if cri exec --timeout 10 "$handler_id" sh -c "printf 'cube-s13-stream-out'; printf 'cube-s13-stream-err' >&2; exit 19" \
  >"$evidence/exec-stream.stdout" 2>"$evidence/exec-stream.stderr"; then
  stream_rc=0
else
  stream_rc=$?
fi
printf '%s\n' "$stream_rc" > "$evidence/exec-stream.rc"
test "$stream_rc" -eq 1
grep -Fq cube-s13-stream-out "$evidence/exec-stream.stdout"
grep -Fq cube-s13-stream-err "$evidence/exec-stream.stderr"
grep -Fq 'exit code 19' "$evidence/exec-stream.stderr"

cri stop --timeout 5 "$handler_id" >/dev/null
handler_exit="$(cri inspect "$handler_id" | jq -r '.status.exitCode')"
printf '%s\n' "$handler_exit" > "$evidence/handler-exit.rc"
test "$handler_exit" -eq 42
cri logs "$handler_id" > "$evidence/handler-after-stop.log"
grep -Fq cube-s13-term "$evidence/handler-after-stop.log"
cri rm "$handler_id" >/dev/null
handler_id=

ignore_command="trap '' TERM; echo cube-s13-ignore-ready; while :; do sleep 1; done"
write_container_config ignore "$ignore_command" ignore.log
ignore_id="$(cri create "$pod_id" "$live/ignore.json" "$live/pod.json")"
cri start "$ignore_id" >/dev/null
for _ in $(seq 1 120); do
  cri logs "$ignore_id" 2>/dev/null | grep -Fq cube-s13-ignore-ready && break
  sleep 0.25
done
grep -Fq cube-s13-ignore-ready < <(cri logs "$ignore_id")
start_ms="$(date +%s%3N)"
cri stop --timeout 3 "$ignore_id" >/dev/null
end_ms="$(date +%s%3N)"
grace_ms=$((end_ms - start_ms))
ignore_exit="$(cri inspect "$ignore_id" | jq -r '.status.exitCode')"
printf '%s\n' "$ignore_exit" > "$evidence/ignore-exit.rc"
printf '%s\n' "$grace_ms" > "$evidence/ignore-grace-ms"
test "$ignore_exit" -eq 137
test "$grace_ms" -ge 2500
test "$grace_ms" -le 6000
grace_result=CORRECT_TIMEOUT_ESCALATION
cri rm "$ignore_id" >/dev/null
ignore_id=

cri stopp "$pod_id" >/dev/null
cri rmp "$pod_id" >/dev/null
pod_id=
printf 'after-pod-remove\n' >> "$evidence/trace.log"

assert_lower_clean() {
  test "$(cri pods -q | wc -l)" -eq 0
  test "$(cri ps -aq | wc -l)" -eq 0
  test "$(count_files "$live/state/adapter")" -eq 0
  test "$(count_entries "$shared")" -eq 0
  test "$(count_entries "$reaper")" -eq 0
  test "$(find "$state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0
  test "$(ctr --address "$socket" --namespace k8s.io containers list -q | wc -l)" -eq 0
  test "$(ctr --address "$socket" --namespace k8s.io tasks list -q | wc -l)" -eq 0
  test "$(ctr --address "$socket" --namespace k8s.io sandboxes list | awk 'NR > 1 && NF {n++} END {print n+0}')" -eq 0
  test "$(count_entries "$state/io.containerd.grpc.v1.cri/netns")" -eq 0
  ctr --address "$socket" --namespace k8s.io snapshots --snapshotter overlayfs list \
    | awk 'NR > 1 && NF {print $1}' | sort > "$evidence/snapshots-after.txt"
  cmp "$evidence/snapshots-before.txt" "$evidence/snapshots-after.txt"
  test -z "$(ps -eo args= | awk -v id="$pod_check_id" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {for (i=2; i<=NF; i++) if ($i == "-id" && $(i+1) == id) print $0}')"
  test -z "$(ps -eo args= | awk -v id="$pod_check_id" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ && $0 ~ /cube-runtime-reaper/ && index($0, id) {print $0}')"
  test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0
  while IFS= read -r record; do
    jq -e '.active == null' "$record" >/dev/null
  done < <(find "$live/state/leases" -type f -name '*.json' -print)
}

for _ in $(seq 1 300); do
  if assert_lower_clean >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
assert_lower_clean
printf 'after-residual-wait\n' >> "$evidence/trace.log"
pods_count="$(cri pods -q | wc -l)"
cri_containers_count="$(cri ps -aq | wc -l)"
adapter_count="$(count_files "$live/state/adapter")"
shared_count="$(count_entries "$shared")"
reaper_count="$(count_entries "$reaper")"
ctr_containers_count="$(ctr --address "$socket" --namespace k8s.io containers list -q | wc -l)"
ctr_tasks_count="$(ctr --address "$socket" --namespace k8s.io tasks list -q | wc -l)"
ctr_sandboxes_count="$(ctr --address "$socket" --namespace k8s.io sandboxes list | awk 'NR > 1 && NF {n++} END {print n+0}')"
netns_count="$(count_entries "$state/io.containerd.grpc.v1.cri/netns")"
cleanup_records_count="$(find "$state" -name cube-runtime-resource.json -type f | wc -l)"
shared_mounts_count="$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)"
shim_processes_count="$(ps -eo args= | awk -v id="$pod_check_id" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {for (i=2; i<=NF; i++) if ($i == "-id" && $(i+1) == id) n++} END {print n+0}')"
reaper_processes_count="$(ps -eo args= | awk -v id="$pod_check_id" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ && $0 ~ /cube-runtime-reaper/ && index($0, id) {n++} END {print n+0}')"
printf 'pods=%s cri_containers=%s adapter=%s shared=%s reaper=%s ctr_containers=%s ctr_tasks=%s ctr_sandboxes=%s netns=%s cleanup_records=%s shared_mounts=%s shim_processes=%s reaper_processes=%s snapshots_equal=yes\n' \
  "$pods_count" "$cri_containers_count" "$adapter_count" "$shared_count" "$reaper_count" \
  "$ctr_containers_count" "$ctr_tasks_count" "$ctr_sandboxes_count" "$netns_count" \
  "$cleanup_records_count" "$shared_mounts_count" "$shim_processes_count" "$reaper_processes_count" \
  > "$evidence/residual-counts.txt"
test "$pods_count" -eq 0
test "$cri_containers_count" -eq 0
test "$adapter_count" -eq 0
test "$shared_count" -eq 0
test "$reaper_count" -eq 0
test "$ctr_containers_count" -eq 0
test "$ctr_tasks_count" -eq 0
test "$ctr_sandboxes_count" -eq 0
test "$netns_count" -eq 0
test "$cleanup_records_count" -eq 0
test "$shared_mounts_count" -eq 0
test "$shim_processes_count" -eq 0
test "$reaper_processes_count" -eq 0
while IFS= read -r record; do
  jq -e '.active == null' "$record" >/dev/null
done < <(find "$live/state/leases" -type f -name '*.json' -print)

printf 'S13_CRI_LOG_OK pod_ip=%s exit=%s\n' "$pod_ip" "$handler_exit"
printf 'S13_CRI_EXEC_SYNC_OK process_exit=17 client_rc=%s stdout=ok stderr=ok\n' "$sync_nonzero_rc"
printf 'S13_CRI_EXEC_STREAM_OK process_exit=19 client_rc=%s stdout=ok stderr=ok tty=false stdin=false\n' "$stream_rc"
printf 'S13_CRI_GRACE_DIAGNOSTIC result=%s elapsed_ms=%s exit=%s timeout=3\n' "$grace_result" "$grace_ms" "$ignore_exit"
printf 'S13_CRI_RESIDUE_CLEAN pods=0 containers=0 tasks=0 sandboxes=0 task_snapshots=0 adapter=0 shared=0 reaper=0 cleanup_records=0 shared_mounts=0 shim_processes=0 reaper_processes=0 netns=0 active_leases=0\n'
printf 'S13_CRI_DIAGNOSTIC_OK evidence=%s\n' "$evidence"

stop_process "$containerd_pid"
stop_process "$harness_pid"
containerd_pid=
harness_pid=
trap - EXIT
