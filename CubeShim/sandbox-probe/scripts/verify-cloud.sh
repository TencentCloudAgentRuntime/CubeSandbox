#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_dir="$(cd "${script_dir}/.." && pwd)"
crictl_bin="${CRICTL:-crictl}"
crictl_config="${CRICTL_CONFIG:-${probe_dir}/config/crictl.yaml}"
ctr_bin="${CTR:-ctr}"
containerd_address="${CONTAINERD_ADDRESS:-/run/cube-s0-containerd/containerd.sock}"
containerd_state="${CONTAINERD_STATE:-/run/cube-s0-containerd}"
containerd_root="${CONTAINERD_ROOT:-/data/cubelet/s0-containerd/root}"
shim_socket_dir="${SHIM_SOCKET_DIR:-${containerd_state}/s}"
host_local_dir="${HOST_LOCAL_DIR:-/var/lib/cni/networks/cube-s0}"
run_dir="${RUN_DIR:-/run/cube-s0}"
artifact_dir="${ARTIFACT_DIR:-${run_dir}/evidence}"
pod_config="${POD_CONFIG:-${probe_dir}/testdata/pod.json}"
container_config="${CONTAINER_CONFIG:-${probe_dir}/testdata/container.json}"
trace_path="${run_dir}/trace.jsonl"
cni_trace_path="${run_dir}/cni.jsonl"
current_pod=""
current_container=""

cri() {
  "${crictl_bin}" --config "${crictl_config}" "$@"
}

ctr_s0() {
  "${ctr_bin}" --address "${containerd_address}" --namespace k8s.io "$@"
}

cleanup_current() {
  if [[ -n "${current_container}" ]]; then
    cri stop --timeout 5 "${current_container}" >/dev/null 2>&1 || true
    cri rm -f "${current_container}" >/dev/null 2>&1 || true
    current_container=""
  fi
  if [[ -n "${current_pod}" ]]; then
    cri stopp --timeout 5 "${current_pod}" >/dev/null 2>&1 || true
    cri rmp -f "${current_pod}" >/dev/null 2>&1 || true
    current_pod=""
  fi
  rm -f "${run_dir}/fail-create" "${run_dir}/fail-start" \
    "${run_dir}/crash-create" "${run_dir}/delay-create"
}
trap cleanup_current EXIT

wait_endpoint() {
  local i
  for i in $(seq 1 30); do
    if cri info >/dev/null 2>&1 && ctr_s0 version >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'CRI/containerd endpoint is not ready: %s\n' "${containerd_address}" >&2
  return 1
}

count_children() {
  local path="$1"
  if [[ ! -d "${path}" ]]; then
    printf '0\n'
    return
  fi
  find "${path}" -mindepth 1 -maxdepth 1 | wc -l
}

resource_counts() {
  local pods containers mounts shims sandboxes sockets state_bundles root_bundles netns ipam
  pods="$(cri pods -q | sed '/^[[:space:]]*$/d' | wc -l)"
  containers="$(cri ps -aq | sed '/^[[:space:]]*$/d' | wc -l)"
  mounts="$(findmnt -rn | grep -F -c "${containerd_root}" || true)"
  shims="$(pgrep -f -c '/usr/local/bin/containerd-shim-cube-s0-v1' || true)"
  sandboxes="$(ctr_s0 sandboxes list | tail -n +2 | sed '/^[[:space:]]*$/d' | wc -l)"
  sockets="$(count_children "${shim_socket_dir}")"
  state_bundles="$((
    $(count_children "${containerd_state}/io.containerd.runtime.v2.task/k8s.io") +
    $(count_children "${containerd_state}/io.containerd.sandbox.controller.v1.shim/k8s.io")
  ))"
  root_bundles="$((
    $(count_children "${containerd_root}/io.containerd.runtime.v2.task/k8s.io") +
    $(count_children "${containerd_root}/io.containerd.sandbox.controller.v1.shim/k8s.io")
  ))"
  netns="$(find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' 2>/dev/null | wc -l)"
  ipam="$(find "${host_local_dir}" -mindepth 1 -maxdepth 1 -type f \
    ! -name lock ! -name 'last_reserved_ip.*' 2>/dev/null | wc -l)"
  printf 'pods=%s containers=%s mounts=%s shims=%s sandbox_meta=%s sockets=%s state_bundles=%s root_bundles=%s netns=%s ipam=%s\n' \
    "${pods}" "${containers}" "${mounts}" "${shims}" "${sandboxes}" \
    "${sockets}" "${state_bundles}" "${root_bundles}" "${netns}" "${ipam}"
  [[ "${pods}" == 0 && "${containers}" == 0 && "${mounts}" == 0 && \
     "${shims}" == 0 && "${sandboxes}" == 0 && "${sockets}" == 0 && \
     "${state_bundles}" == 0 && "${root_bundles}" == 0 && \
     "${netns}" == 0 && "${ipam}" == 0 ]]
}

assert_clean() {
  local case_name="$1" i counts
  for i in $(seq 1 30); do
    if counts="$(resource_counts)"; then
      printf '%s cleanup %s\n' "${case_name}" "${counts}" | tee -a "${artifact_dir}/s0.1-summary.txt"
      return 0
    fi
    sleep 1
  done
  counts="$(resource_counts || true)"
  printf '%s cleanup FAILED %s\n' "${case_name}" "${counts}" | tee -a "${artifact_dir}/s0.1-summary.txt" >&2
  return 1
}

reset_trace() {
  install -d -m 0755 "${run_dir}" "${artifact_dir}"
  : > "${trace_path}"
  : > "${cni_trace_path}"
}

save_trace() {
  local case_name="$1"
  cp "${trace_path}" "${artifact_dir}/s0.1-${case_name}-shim.jsonl"
  cp "${cni_trace_path}" "${artifact_dir}/s0.1-${case_name}-cni.jsonl"
}

assert_cni_cleanup() {
  local case_name="$1" adds dels add_ok del_ok
  adds="$(grep -c '"event":"cni.ADD"' "${cni_trace_path}" || true)"
  dels="$(grep -c '"event":"cni.DEL"' "${cni_trace_path}" || true)"
  add_ok="$(grep -c '"event":"cni.ADD.result","result":"ok","status":0' "${cni_trace_path}" || true)"
  del_ok="$(grep -c '"event":"cni.DEL.result","result":"ok","status":0' "${cni_trace_path}" || true)"
  if [[ "${adds}" -lt 1 || "${dels}" -lt 1 || "${adds}" != "${add_ok}" || "${dels}" != "${del_ok}" ]]; then
    printf '%s CNI cleanup FAILED add=%s/%s del=%s/%s\n' \
      "${case_name}" "${add_ok}" "${adds}" "${del_ok}" "${dels}" >&2
    return 1
  fi
  printf '%s cni add_ok=%s del_ok=%s\n' "${case_name}" "${add_ok}" "${del_ok}" | tee -a "${artifact_dir}/s0.1-summary.txt"
}

assert_normal_trace() {
  local result
  result="$(python3 - "${trace_path}" <<'PY'
import json
import sys

entries = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
boot = [e for e in entries if e.get("event") == "bootstrap.started" and e.get("result") == "ok"]
boot = [e for e in boot if e.get("version") == 3 and e.get("protocol") == "ttrpc"]
assert len(boot) == 1, boot
rpcs = [e for e in entries if e.get("event") == "rpc.begin"]
sandbox_pids = {e["pid"] for e in rpcs if "Sandbox/" in e.get("method", "")}
task_pids = {e["pid"] for e in rpcs if "Task/" in e.get("method", "")}
assert len(sandbox_pids) == 1, sandbox_pids
assert task_pids == sandbox_pids, (sandbox_pids, task_pids)
rpc_pid = next(iter(sandbox_pids))
spawned = [e for e in entries if e.get("event") == "shim.spawned"]
assert len(spawned) == 1 and spawned[0].get("shim_pid") == rpc_pid, (spawned, rpc_pid)

required = [
    "Sandbox/CreateSandbox",
    "Sandbox/StartSandbox",
    "Sandbox/SandboxStatus",
    "Sandbox/WaitSandbox",
    "Sandbox/Platform",
    "Task/Create",
    "Task/Connect",
    "Task/Start",
    "Task/Wait",
    "Task/State",
    "Task/Kill",
    "Task/Delete",
    "Sandbox/StopSandbox",
    "Sandbox/ShutdownSandbox",
]
cursor = -1
methods = [e.get("method", "") for e in rpcs]
for fragment in required:
    cursor = next((i for i in range(cursor + 1, len(methods)) if fragment in methods[i]), -1)
    assert cursor >= 0, (fragment, methods)
print(f'bootstrap=3/ttrpc endpoint={boot[0].get("address")} sandbox_task_pid={rpc_pid} ordered_rpcs={len(required)}')
PY
)"
  printf 'normal trace %s\n' "${result}" | tee -a "${artifact_dir}/s0.1-summary.txt"
}

assert_failure_trace() {
  local case_name="$1" failpoint="$2" result
  result="$(python3 - "${trace_path}" "${case_name}" "${failpoint}" <<'PY'
import json
import sys

entries = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
case_name, failpoint = sys.argv[2], sys.argv[3]
events = [e.get("event") for e in entries]
methods = [e.get("method", "") for e in entries if e.get("event") == "rpc.begin"]
assert f"failpoint.{failpoint}" in events, (case_name, events)
shutdown = any("Sandbox/ShutdownSandbox" in method for method in methods)
deleted = "bootstrap.delete" in events
expected = {
    "fail-create": (True, True),
    "fail-start": (True, True),
    "crash-create": (False, True),
    "cancel-create": (True, False),
}
assert (shutdown, deleted) == expected[case_name], (case_name, shutdown, deleted, events)
if deleted:
    cleanup = [e for e in entries if e.get("event") == "manager.socket_cleanup"]
    assert len(cleanup) == 1 and cleanup[0].get("result") == "ok", cleanup
print(f'failpoint={failpoint} shutdown={shutdown} delete_helper={deleted}')
PY
)"
  printf '%s trace %s\n' "${case_name}" "${result}" | tee -a "${artifact_dir}/s0.1-summary.txt"
}

wait_container_exit() {
  local container_id="$1" i state
  for i in $(seq 1 30); do
    state="$(cri inspect --output json "${container_id}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])')"
    if [[ "${state}" == "CONTAINER_EXITED" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_normal() {
  local pod_status exit_code output
  reset_trace
  current_pod="$(cri runp --runtime cube-s0 "${pod_config}")"
  pod_status="$(cri inspectp --output json "${current_pod}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])')"
  [[ "${pod_status}" == "SANDBOX_READY" ]]

  current_container="$(cri create "${current_pod}" "${container_config}" "${pod_config}")"
  cri start "${current_container}" >/dev/null
  wait_container_exit "${current_container}"
  exit_code="$(cri inspect --output json "${current_container}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["exitCode"])')"
  output="$(cri logs "${current_container}")"
  [[ "${exit_code}" == 23 ]]
  [[ "${output}" == *cube-s0-task-ok* ]]

  cleanup_current
  assert_clean normal
  assert_cni_cleanup normal
  assert_normal_trace
  save_trace normal
  printf 'normal state=%s exit=%s output=%s\n' "${pod_status}" "${exit_code}" "${output}" | tee -a "${artifact_dir}/s0.1-summary.txt"
}

run_failure() {
  local case_name="$1" failpoint="$2" timeout_seconds="${3:-0}"
  local output_file="${artifact_dir}/s0.1-${case_name}-runp.txt"
  reset_trace
  touch "${run_dir}/${failpoint}"
  if [[ "${timeout_seconds}" -gt 0 ]]; then
    if timeout "${timeout_seconds}s" "${crictl_bin}" --config "${crictl_config}" \
      runp --runtime cube-s0 "${pod_config}" >"${output_file}" 2>&1; then
      printf '%s unexpectedly succeeded\n' "${case_name}" >&2
      return 1
    fi
  elif cri runp --runtime cube-s0 "${pod_config}" >"${output_file}" 2>&1; then
    printf '%s unexpectedly succeeded\n' "${case_name}" >&2
    return 1
  fi
  rm -f "${run_dir}/${failpoint}"
  if [[ "${timeout_seconds}" -gt 0 ]]; then
    sleep 12
  fi
  assert_clean "${case_name}"
  assert_cni_cleanup "${case_name}"
  assert_failure_trace "${case_name}" "${failpoint}"
  save_trace "${case_name}"
}

main() {
  command -v "${crictl_bin}" >/dev/null
  command -v "${ctr_bin}" >/dev/null
  command -v python3 >/dev/null
  wait_endpoint
  install -d -m 0755 "${artifact_dir}"
  find "${artifact_dir}" -maxdepth 1 -type f -name 's0.1-*' -delete
  : > "${artifact_dir}/s0.1-summary.txt"
  assert_clean preflight
  cri pull docker.io/library/busybox:1.36.1 >/dev/null

  run_normal
  run_failure fail-create fail-create
  run_failure fail-start fail-start
  run_failure crash-create crash-create
  run_failure cancel-create delay-create 1
  printf 'S0.1 verification PASS\n' | tee -a "${artifact_dir}/s0.1-summary.txt"
}

main "$@"
