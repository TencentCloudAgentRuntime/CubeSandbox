#!/usr/bin/env bash
# 运行已发布的 Pi CLI；本脚本只创建隔离状态、限时和采集事件，不实现 Agent 循环。
set -euo pipefail

artifacts="${ARTIFACTS_DIR:-/artifacts}"
workspace="${WORKSPACE_DIR:-/app}"
instruction="${TASK_INSTRUCTION_FILE:?缺少 TASK_INSTRUCTION_FILE}"
timeout_seconds="${AGENT_TIMEOUT_SECONDS:-360}"
provider="${PI_PROVIDER:-tokenhub}"
model="${PI_MODEL:-ep-s55rmple}"
mkdir -p "$artifacts" /pi-state
cp /opt/agc37/models.json /pi-state/models.json
export PI_CODING_AGENT_DIR=/pi-state

# 墙上时间仅用于日志关联；时长必须由同一进程命名空间的单调时钟计算。
start_unix_ns="$(date +%s%N)"
start_monotonic_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
/opt/agc37/sample-resources.py --output "$artifacts/resources-agent.jsonl" &
sampler_pid=$!
event_pipe="$(mktemp -u /tmp/agc37-pi-events.XXXXXX)"
mkfifo "$event_pipe"
/opt/agc37/sanitize-pi.py < "$event_pipe" > "$artifacts/pi-events.jsonl" &
sanitize_pid=$!
set +e
cd "$workspace"
timeout --preserve-status "${timeout_seconds}s" \
  pi --print --mode json --no-session --no-extensions --no-skills --no-context-files \
     --no-prompt-templates --no-themes --approve --provider "$provider" --model "$model" \
     -- "$(<"$instruction")" \
  > "$event_pipe"
pi_status=$?
set -e
# 计时终点是 Pi 子进程退出，不等待脱敏写盘或资源采样收尾。
end_monotonic_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
end_unix_ns="$(date +%s%N)"
wait "$sanitize_pid"
rm -f "$event_pipe"
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true

jq -cn \
  --arg phase agent \
  --argjson start_unix_ns "$start_unix_ns" \
  --argjson end_unix_ns "$end_unix_ns" \
  --argjson start_monotonic_ns "$start_monotonic_ns" \
  --argjson end_monotonic_ns "$end_monotonic_ns" \
  --argjson duration_ns "$((end_monotonic_ns - start_monotonic_ns))" \
  --argjson exit_code "$pi_status" \
  --arg provider "$provider" --arg model "$model" \
  --arg pi_version "$(pi --version)" \
  '{phase:$phase,start_unix_ns:$start_unix_ns,end_unix_ns:$end_unix_ns,start_monotonic_ns:$start_monotonic_ns,end_monotonic_ns:$end_monotonic_ns,duration_ns:$duration_ns,exit_code:$exit_code,provider:$provider,model:$model,pi_version:$pi_version}' \
  > "$artifacts/agent-result.json"
touch "$artifacts/agent.done"
# verifier 必须运行，Pi 失败由 agent-result 判定，不由容器失败掩盖。
exit 0
