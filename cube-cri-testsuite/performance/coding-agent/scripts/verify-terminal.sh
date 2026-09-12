#!/usr/bin/env bash
# Pi 未挂载 /tests；本容器在 Pi 结束后使用 Terminal-Bench 原始验证脚本。
set -euo pipefail

artifacts="${ARTIFACTS_DIR:-/artifacts}"
workspace="${WORKSPACE_DIR:-/app}"
test_root="${TERMINAL_TEST_ROOT:?缺少 TERMINAL_TEST_ROOT}"
runner="${TERMINAL_TEST_RUNNER:?缺少 TERMINAL_TEST_RUNNER}"
timeout_seconds="${VERIFY_TIMEOUT_SECONDS:-120}"
verifier_mode="${TERMINAL_VERIFIER_MODE:-terminal-original}"
deadline=$((SECONDS + timeout_seconds + 60))
while [[ ! -e "$artifacts/agent.done" ]] && ((SECONDS < deadline)); do sleep 1; done
if [[ ! -e "$artifacts/agent.done" ]]; then
  jq -cn '{phase:"verify",infrastructure_error:"等待 Agent 结束超时"}' > "$artifacts/verify-result.json"
  exit 0
fi

start_unix_ns="$(date +%s%N)"
start_monotonic_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
set +e
cd "$workspace"
timeout --preserve-status "${timeout_seconds}s" env TEST_DIR="$test_root" /bin/bash "$runner" \
  > "$artifacts/verify.log" 2>&1
status=$?
set -e
end_monotonic_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
end_unix_ns="$(date +%s%N)"
jq -cn \
  --arg phase verify --argjson start_unix_ns "$start_unix_ns" --argjson end_unix_ns "$end_unix_ns" \
  --arg verifier "$verifier_mode" \
  --argjson start_monotonic_ns "$start_monotonic_ns" --argjson end_monotonic_ns "$end_monotonic_ns" \
  --argjson duration_ns "$((end_monotonic_ns - start_monotonic_ns))" --argjson exit_code "$status" \
  '{phase:$phase,verifier:$verifier,start_unix_ns:$start_unix_ns,end_unix_ns:$end_unix_ns,start_monotonic_ns:$start_monotonic_ns,end_monotonic_ns:$end_monotonic_ns,duration_ns:$duration_ns,exit_code:$exit_code}' \
  > "$artifacts/verify-result.json"
touch "$artifacts/verify.done"
exit 0
