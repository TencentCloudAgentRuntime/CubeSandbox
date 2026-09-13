#!/usr/bin/env bash
# 一键执行已验收的 Terminal-Bench Coding Agent formal 套件。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node=""
task_root="${TERMINAL_BENCH_ROOT:-/data/home/journeyyou/agc37-cache/terminal-bench-d28711d/terminal-bench/original-tasks}"
seed=20260911
retry_limit=2
output=""
tasks_csv=""
keep_images=false

default_tasks=(
  modernize-fortran-build
  debug-long-program
  build-pmars
  nginx-request-logging
  jupyter-notebook-server
  processing-pipeline
  openssl-selfsigned-cert
  fix-code-vulnerability
  crack-7z-hash
)

usage() {
  cat >&2 <<'EOF'
用法：run-terminal-suite.sh --node NODE [--task-root DIR] [--seed N] [--retry-limit N] [--tasks a,b,c] [--output DIR] [--keep-images]

默认执行 task-matrix 中已验收的 9 个 formal 任务。脚本会按任务构建镜像、导入节点、运行 formal 配对、补跑未配对样本、清理节点镜像，并生成 suite-report。
EOF
}

while (($#)); do
  case "$1" in
    --node) node="$2"; shift 2 ;;
    --task-root|--terminal-bench-root) task_root="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --retry-limit) retry_limit="$2"; shift 2 ;;
    --tasks) tasks_csv="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --keep-images) keep_images=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$node" && "$seed" =~ ^[0-9]+$ && "$retry_limit" =~ ^[0-9]+$ ]] || { usage; exit 2; }
[[ -d "$task_root" ]] || { echo "Terminal-Bench task root 不存在：$task_root" >&2; exit 2; }

suite_id="suite-$(date +%Y%m%d%H%M%S)"
output="${output:-$script_dir/_output/agc37-terminal-suite/$suite_id}"
mkdir -p "$output"/{formal,images,logs}

if [[ -n "$tasks_csv" ]]; then
  IFS=',' read -r -a tasks <<< "$tasks_csv"
else
  tasks=("${default_tasks[@]}")
fi

build_args_for() {
  case "$1" in
    modernize-fortran-build|processing-pipeline|crack-7z-hash)
      printf '%s\n' --ubuntu-apt-mirror https://mirrors.tencent.com/ubuntu
      ;;
    build-pmars|nginx-request-logging)
      printf '%s\n' --debian-apt-mirror http://mirrors.tencent.com/debian
      ;;
    jupyter-notebook-server)
      printf '%s\n' --debian-apt-mirror http://mirrors.tencent.com/debian --pip-index-url https://mirrors.tencent.com/pypi/simple --pip-trusted-host mirrors.tencent.com
      ;;
    *)
      ;;
  esac
}

cleanup_image() {
  local image="$1"
  local task="$2"
  [[ "$keep_images" == false ]] || return 0

  local cube_pod
  cube_pod="$(
    kubectl -n cube-cri-system get pods \
      -l app.kubernetes.io/name=cube-cri \
      --field-selector "spec.nodeName=$node" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"
  [[ -n "$cube_pod" ]] || {
    echo "WARN: 未找到节点 $node 上的 cube-cri Pod，跳过节点镜像清理：$image" >&2
    return 0
  }

  local refs=("docker.io/library/$image")
  if [[ "$task" == "debug-long-program" ]]; then
    refs+=("docker.io/library/${image}-program")
  fi
  kubectl -n cube-cri-system exec "$cube_pod" -- nsenter -t 1 -m -u -i -n -p -- \
    ctr -n k8s.io images rm "${refs[@]}" >/dev/null 2>&1 || true
}

summarize_formal() {
  local formal_dir="$1"
  python3 "$script_dir/scripts/summarize-formal.py" \
    --cases "$formal_dir/cases" \
    --seed "$seed" \
    --output-dir "$formal_dir" >/dev/null
  sha256sum "$formal_dir"/manifest.json "$formal_dir"/task-files.sha256 \
    "$formal_dir"/node.json "$formal_dir"/runtimeclass.json "$formal_dir"/report.json \
    > "$formal_dir/SHA256SUMS"
}

rerun_unpaired() {
  local task="$1"
  local image="$2"
  local task_dir="$3"
  local formal_dir="$4"
  local attempt round mode case_dir failed_dir

  for ((attempt = 1; attempt <= retry_limit; attempt++)); do
    local paired
    paired="$(jq -r '.paired_successes // 0' "$formal_dir/report.json")"
    if [[ "$paired" == 6 ]]; then
      return 0
    fi

    mapfile -t missing < <(
      jq -r '
        .unpaired[]
        | .round as $round
        | .modes as $modes
        | ["runc", "cube"][]
        | select(($modes[.] // false) != true)
        | [$round, .] | @tsv
      ' "$formal_dir/report.json"
    )

    if ((${#missing[@]} == 0)); then
      return 1
    fi

    for item in "${missing[@]}"; do
      round="${item%%$'\t'*}"
      mode="${item##*$'\t'}"
      case_dir="$formal_dir/cases/${task}-${mode}-r${round}"
      failed_dir="$formal_dir/failed-reruns/${task}-${mode}-r${round}-attempt${attempt}"
      mkdir -p "$formal_dir/failed-reruns"
      if [[ -e "$case_dir" ]]; then
        rm -rf "$failed_dir"
        mv "$case_dir" "$failed_dir"
      fi
      if ! bash "$script_dir/run-terminal-case.sh" \
        --node "$node" \
        --task-dir "$task_dir" \
        --image "$image" \
        --mode "$mode" \
        --round "$round" \
        --output "$case_dir"; then
        jq -cn --arg task "$task" --arg mode "$mode" --argjson round "$round" --argjson attempt "$attempt" \
          '{task:$task,mode:$mode,round:$round,attempt:$attempt,error:"case rerun failed before producing a complete record"}' \
          >> "$formal_dir/orchestration-failures.jsonl"
      fi
    done
    summarize_formal "$formal_dir"
  done

  [[ "$(jq -r '.paired_successes // 0' "$formal_dir/report.json")" == 6 ]]
}

write_suite_report() {
  python3 - "$output" "${tasks[@]}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
tasks = sys.argv[2:]
rows = []
for task in tasks:
    report_path = root / "formal" / task / "report.json"
    if not report_path.exists():
        rows.append({"task": task, "status": "missing_report"})
        continue
    report = json.loads(report_path.read_text(encoding="utf-8"))
    metric = report["metrics"]["t_agent_ns"]
    rel = metric["paired_relative_change"]
    abs_change = metric["paired_absolute_change_ns"]
    rows.append({
        "task": task,
        "status": "complete" if report.get("paired_successes") == 6 else "partial",
        "formal_records": report.get("formal_records"),
        "paired_successes": report.get("paired_successes"),
        "unpaired": report.get("unpaired", []),
        "median_cube_over_runc_minus_1_t_agent": None if rel is None else rel["median"],
        "median_cube_minus_runc_t_agent_ns": None if abs_change is None else abs_change["median"],
        "report": str(report_path),
    })

complete = [row for row in rows if row["status"] == "complete"]
summary = {
    "tasks": rows,
    "complete_tasks": len(complete),
    "partial_tasks": [row["task"] for row in rows if row["status"] != "complete"],
}
(root / "suite-report.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

lines = ["# Coding Agent Terminal-Bench Formal Suite", "", f"完成任务：{len(complete)}/{len(rows)}。", "", "| 任务 | 状态 | 配对 | t_agent 中位相对变化 | t_agent 中位绝对差(ns) |", "| --- | --- | ---: | ---: | ---: |"]
for row in rows:
    rel = row.get("median_cube_over_runc_minus_1_t_agent")
    abs_change = row.get("median_cube_minus_runc_t_agent_ns")
    rel_text = "" if rel is None else f"{rel * 100:.2f}%"
    abs_text = "" if abs_change is None else f"{abs_change:.0f}"
    lines.append(f"| {row['task']} | {row['status']} | {row.get('paired_successes', 0)}/6 | {rel_text} | {abs_text} |")
(root / "suite-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

printf 'suite_id=%s\noutput=%s\nnode=%s\ntask_root=%s\n' "$suite_id" "$output" "$node" "$task_root" | tee "$output/suite.env"

for task in "${tasks[@]}"; do
  task_dir="$task_root/$task"
  [[ -d "$task_dir" ]] || { echo "任务目录不存在：$task_dir" >&2; exit 3; }

  image="cube-cri-agc37-pi-terminal-${task}:tb-d287-pi0.85.6-${suite_id}"
  image_dir="$output/images/$task"
  formal_dir="$output/formal/$task"
  mkdir -p "$image_dir" "$formal_dir"

  echo "==> build $task"
  mapfile -t build_args < <(build_args_for "$task")
  bash "$script_dir/build-terminal-image.sh" \
    --node "$node" \
    --task-dir "$task_dir" \
    --image "$image" \
    --output "$image_dir" \
    "${build_args[@]}" \
    2>&1 | tee "$output/logs/${task}.build.log"

  echo "==> formal $task"
  if ! bash "$script_dir/run-terminal-formal.sh" \
    --node "$node" \
    --task-dir "$task_dir" \
    --image "$image" \
    --image-manifest "$image_dir/image-manifest.json" \
    --seed "$seed" \
    --rounds 6 \
    --output "$formal_dir" \
    2>&1 | tee "$output/logs/${task}.formal.log"; then
    echo "WARN: formal runner failed for $task; attempting to summarize existing cases" >&2
  fi

  if [[ -f "$formal_dir/report.json" ]]; then
    if ! rerun_unpaired "$task" "$image" "$task_dir" "$formal_dir"; then
      echo "ERROR: $task 未达到 6 个成功配对，详见 $formal_dir/report.json" >&2
      cleanup_image "$image" "$task"
      write_suite_report
      exit 4
    fi
  else
    echo "ERROR: $task 未生成 formal report：$formal_dir" >&2
    cleanup_image "$image" "$task"
    write_suite_report
    exit 4
  fi

  cleanup_image "$image" "$task"
  write_suite_report
done

write_suite_report
echo "$output/suite-report.md"
