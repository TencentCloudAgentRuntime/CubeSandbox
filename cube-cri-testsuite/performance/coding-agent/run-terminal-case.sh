#!/usr/bin/env bash
# 单次 Terminal-Bench case：只在 Pi 与原始 runner 外层计时。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../../.." && pwd)"
node=""
task_dir=""
image=""
mode=""
round=""
output=""
agent_timeout_seconds=900
verify_timeout_seconds=300
cpu="2"
memory="4Gi"
keep=false

usage() {
  cat <<'EOF'
用法：run-terminal-case.sh --node NODE --task-dir DIR --image IMAGE --mode runc|cube --round N
  [--agent-timeout SECONDS] [--verify-timeout SECONDS] [--cpu N] [--memory QTY] [--output DIR] [--keep]

任务必须是锁定的单 client Terminal-Bench task；镜像必须已导入目标节点 containerd。
EOF
}
while (($#)); do
  case "$1" in
    --node) node="$2"; shift 2 ;;
    --task-dir) task_dir="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --round) round="$2"; shift 2 ;;
    --agent-timeout) agent_timeout_seconds="$2"; shift 2 ;;
    --verify-timeout) verify_timeout_seconds="$2"; shift 2 ;;
    --cpu) cpu="$2"; shift 2 ;;
    --memory) memory="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$node" && -d "$task_dir" && -n "$image" && -n "$mode" && -n "$round" ]] || { usage >&2; exit 2; }
[[ "$mode" =~ ^(runc|cube)$ && "$round" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
[[ "$agent_timeout_seconds" =~ ^[1-9][0-9]*$ && "$verify_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
[[ -f "$task_dir/task.yaml" && -f "$task_dir/run-tests.sh" && -d "$task_dir/tests" ]] || { echo '任务目录缺少 task.yaml、run-tests.sh 或 tests/' >&2; exit 2; }

task="$(basename "$task_dir")"
attempt="agc37-${mode}-${task}-r${round}-$(date +%s)"
namespace="$attempt"
output="${output:-$repo_dir/_output/agc37-terminal/$attempt}"
mkdir -p "$output"

monotonic_ns() { python3 -c 'import time; print(time.monotonic_ns())'; }
instruction="$(python3 - "$task_dir/task.yaml" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
try:
    start = lines.index("instruction: |-") + 1
except ValueError as error:
    raise SystemExit("仅支持 instruction: |- 格式") from error
for line in lines[start:]:
    if line and not line[0].isspace():
        break
    print(line[2:] if line.startswith("  ") else line)
PY
)"

cleanup() {
  local status=$?
  if [[ "$keep" != true ]]; then
    kubectl delete namespace "$namespace" --wait=true >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

kubectl get node "$node" >/dev/null
kubectl get runtimeclass "$mode" >/dev/null
kubectl create namespace "$namespace" >/dev/null
set -a
. "${LLM_MODEL_PROVIDER:-/data/home/journeyyou/dotfiles/tokenhub-apikey.sh}"
set +a
kubectl -n "$namespace" create secret generic provider --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" >/dev/null
unset OPENAI_API_KEY
kubectl -n "$namespace" create configmap instruction --from-literal=instruction="$instruction" >/dev/null
kubectl -n "$namespace" create configmap terminal-tests \
  --from-file=run-tests.sh="$task_dir/run-tests.sh" \
  --from-file="$task_dir/tests" >/dev/null

e2e_start_monotonic_ns="$(monotonic_ns)"
cat <<EOF | kubectl -n "$namespace" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: agent
  labels: {agc37-role: pi, agc37-mode: $mode, agc37-task: "$task"}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 10
  runtimeClassName: $mode
  nodeSelector: {kubernetes.io/hostname: "$node"}
  volumes:
  - {name: workspace, emptyDir: {}}
  - {name: artifacts, emptyDir: {}}
  - {name: test-stage, emptyDir: {}}
  - {name: instruction, configMap: {name: instruction}}
  - {name: test-source, configMap: {name: terminal-tests}}
  initContainers:
  - name: workspace-snapshot
    image: $image
    imagePullPolicy: Never
    command: ["/bin/bash", "-ceu", "cp -a /app/. /workspace/"]
    volumeMounts: [{name: workspace, mountPath: /workspace}]
  containers:
  - name: agent
    image: $image
    imagePullPolicy: Never
    command: ["/opt/agc37/run-terminal-agent.sh"]
    env:
    - {name: OPENAI_API_KEY, valueFrom: {secretKeyRef: {name: provider, key: OPENAI_API_KEY}}}
    - {name: TASK_INSTRUCTION_FILE, value: /instruction/instruction}
    - {name: AGENT_TIMEOUT_SECONDS, value: "$agent_timeout_seconds"}
    volumeMounts:
    - {name: workspace, mountPath: /app}
    - {name: artifacts, mountPath: /artifacts}
    - {name: test-stage, mountPath: /tests}
    - {name: instruction, mountPath: /instruction, readOnly: true}
    resources: {requests: {cpu: "$cpu", memory: "$memory"}, limits: {cpu: "$cpu", memory: "$memory"}}
  - name: test-loader
    image: $image
    imagePullPolicy: Never
    command: ["/bin/bash", "-ceu", "while [[ ! -e /artifacts/agent.done ]]; do sleep 0.1; done; cp -a /test-source/. /tests/; touch /artifacts/tests.ready"]
    volumeMounts:
    - {name: artifacts, mountPath: /artifacts}
    - {name: test-stage, mountPath: /tests}
    - {name: test-source, mountPath: /test-source, readOnly: true}
    resources: {requests: {cpu: "50m", memory: "128Mi"}, limits: {cpu: "50m", memory: "128Mi"}}
  - name: artifact-keeper
    image: $image
    imagePullPolicy: Never
    command: ["/opt/agc37/keep-artifacts.sh"]
    volumeMounts: [{name: artifacts, mountPath: /artifacts}]
    resources: {requests: {cpu: "50m", memory: "128Mi"}, limits: {cpu: "50m", memory: "128Mi"}}
EOF

kubectl -n "$namespace" wait --for=condition=Ready pod/agent --timeout=10m >/dev/null

trial_start_monotonic_ns="$(monotonic_ns)"
kubectl -n "$namespace" exec agent -c agent -- touch /artifacts/start-agent
deadline=$((SECONDS + agent_timeout_seconds + 180))
while [[ ! -e "$output/.unused" ]] && ((SECONDS < deadline)); do
  kubectl -n "$namespace" exec agent -c artifact-keeper -- test -e /artifacts/tests.ready 2>/dev/null && break
  sleep 1
done
kubectl -n "$namespace" exec agent -c artifact-keeper -- test -e /artifacts/tests.ready
verify_env=(TERMINAL_TEST_ROOT=/tests TERMINAL_TEST_RUNNER=/tests/run-tests.sh VERIFY_TIMEOUT_SECONDS="$verify_timeout_seconds" TERMINAL_VERIFIER_MODE=terminal-original-hermetic UV_CACHE_DIR=/opt/agc37/verifier-uv UV_OFFLINE=1 PATH=/opt/agc37/verifier-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
kubectl -n "$namespace" exec agent -c agent -- env "${verify_env[@]}" /opt/agc37/verify-terminal.sh
trial_end_monotonic_ns="$(monotonic_ns)"
e2e_end_monotonic_ns="$trial_end_monotonic_ns"

for _ in $(seq 1 60); do
  phase="$(kubectl -n "$namespace" get pod agent -o jsonpath='{.status.containerStatuses[?(@.name=="agent")].state.terminated.reason}' 2>/dev/null || true)"
  [[ -n "$phase" ]] && break
  sleep 1
done
kubectl -n "$namespace" get pod agent -o json > "$output/pod.json"
kubectl -n "$namespace" logs agent -c agent > "$output/agent.log"
kubectl -n "$namespace" logs agent -c test-loader > "$output/test-loader.log" || true
for _ in $(seq 1 120); do
  kubectl -n "$namespace" exec agent -c artifact-keeper -- test -e /artifacts/keeper.ready 2>/dev/null && break
  sleep 1
done
kubectl -n "$namespace" exec agent -c artifact-keeper -- test -e /artifacts/keeper.ready
kubectl -n "$namespace" cp agent:/artifacts/. "$output/artifacts" -c artifact-keeper
python3 "$script_dir/scripts/summarize-attempt.py" \
  --artifacts "$output/artifacts" --mode "$mode" --task "$task" --round "$round" --pod-json "$output/pod.json" \
  --controller-e2e-start-monotonic-ns "$e2e_start_monotonic_ns" --controller-e2e-end-monotonic-ns "$e2e_end_monotonic_ns" \
  --controller-trial-start-monotonic-ns "$trial_start_monotonic_ns" --controller-trial-end-monotonic-ns "$trial_end_monotonic_ns" \
  --output "$output/result.json"
jq -cn \
  --arg task "$task" --arg mode "$mode" --argjson round "$round" \
  --argjson e2e_start_monotonic_ns "$e2e_start_monotonic_ns" --argjson e2e_end_monotonic_ns "$e2e_end_monotonic_ns" \
  --argjson trial_start_monotonic_ns "$trial_start_monotonic_ns" --argjson trial_end_monotonic_ns "$trial_end_monotonic_ns" \
  '{task:$task,mode:$mode,round:$round,e2e_start_monotonic_ns:$e2e_start_monotonic_ns,e2e_end_monotonic_ns:$e2e_end_monotonic_ns,e2e_duration_ns:($e2e_end_monotonic_ns-$e2e_start_monotonic_ns),trial_start_monotonic_ns:$trial_start_monotonic_ns,trial_end_monotonic_ns:$trial_end_monotonic_ns,trial_duration_ns:($trial_end_monotonic_ns-$trial_start_monotonic_ns)}' \
  > "$output/controller-result.json"
printf '%s\n' "$output"
