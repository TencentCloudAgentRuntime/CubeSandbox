#!/usr/bin/env bash
# 每个任务固定 6 个 runc/Cube 配对；3 次各自先行，顺序由固定种子生成。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node=""
task_dir=""
image=""
image_manifest=""
seed=20260911
rounds=6
output=""

usage() {
  echo '用法：run-terminal-formal.sh --node NODE --task-dir DIR --image IMAGE [--image-manifest FILE] [--seed N] [--output DIR]' >&2
}
while (($#)); do
  case "$1" in
    --node) node="$2"; shift 2 ;;
    --task-dir) task_dir="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --image-manifest) image_manifest="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --rounds) rounds="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$node" && -d "$task_dir" && -n "$image" && "$seed" =~ ^[0-9]+$ && "$rounds" == 6 ]] || { usage >&2; exit 2; }

task="$(basename "$task_dir")"
output="${output:-_output/agc37-terminal-formal/${task}-$(date +%Y%m%d%H%M%S)}"
mkdir -p "$output/cases"
find "$task_dir" -type f -print0 | sort -z | xargs -0 sha256sum > "$output/task-files.sha256"
kubectl get node "$node" -o json > "$output/node.json"
kubectl get runtimeclass runc cube -o json > "$output/runtimeclass.json"
if [[ -n "$image_manifest" ]]; then cp "$image_manifest" "$output/image-manifest.json"; fi

jq -cn --arg task "$task" --arg task_dir "$task_dir" --arg image "$image" --arg node "$node" --argjson seed "$seed" \
  '{task:$task,task_dir:$task_dir,image:$image,node:$node,seed:$seed,formal_pairs:6}' > "$output/manifest.json"

pair_orders() {
  python3 - "$seed" "$task" <<'PY'
import hashlib
import random
import sys

seed, task = sys.argv[1:]
orders = [("runc", "cube")] * 3 + [("cube", "runc")] * 3
rng = random.Random(int(hashlib.sha256(f"{seed}:{task}".encode()).hexdigest(), 16))
rng.shuffle(orders)
for number, order in enumerate(orders, 1):
    print(number, *order, sep="\t")
PY
}

run_case() {
  local mode="$1"
  local round="$2"
  local case_dir="$output/cases/${task}-${mode}-r${round}"
  if ! bash "$script_dir/run-terminal-case.sh" --node "$node" --task-dir "$task_dir" --image "$image" --mode "$mode" --round "$round" --output "$case_dir"; then
    jq -cn --arg task "$task" --arg mode "$mode" --argjson round "$round" --arg error 'case runner failed before producing a complete record' \
      '{task:$task,mode:$mode,round:$round,infrastructure_error:$error}' >> "$output/orchestration-failures.jsonl"
  fi
}

pair_orders | tee "$output/execution-order.tsv" | while IFS=$'\t' read -r round first second; do
  run_case "$first" "$round"
  run_case "$second" "$round"
done
python3 "$script_dir/scripts/summarize-formal.py" --cases "$output/cases" --seed "$seed" --output-dir "$output"
sha256sum "$output"/manifest.json "$output"/task-files.sha256 "$output"/node.json "$output"/runtimeclass.json "$output"/report.json > "$output/SHA256SUMS"
printf '%s\n' "$output/report.md"
