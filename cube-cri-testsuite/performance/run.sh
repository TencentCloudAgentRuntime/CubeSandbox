#!/usr/bin/env bash
# 顺序执行；每轮由确定性排列打散，避免时间漂移系统性偏向某个 runtime。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
node="${NODE_NAME:-}"
image="${BENCH_IMAGE:-cube-cri-perf:dev}"
rounds=15
seed=20260909
suites="micro,storage,network"
test_filter=""
output_dir=""
profile="full"
rounds_set=false
fio_size_set=false
fio_runtime_set=false
iperf_runtime_set=false
cpu="4"
memory="2Gi"
fio_size="512M"
fio_runtime=30
iperf_runtime=30
sysbench_runtime=10
hackbench_loops=1000
hackbench_groups=10
lmbench_memory_size="128M"
lmbench_file_size_mib=64
lmbench_samples=3
lmbench_iterations=1000000
stream_profile="full"
keep=false

usage() {
  cat <<'EOF'
用法: ./cube-cri-testsuite/performance/run.sh [选项]
  --node NAME       TS4/PVM 节点；缺省自动发现 cube-ready 节点
  --image IMAGE     已导入节点 containerd 的镜像名，默认 cube-cri-perf:dev
  --rounds N        正式样本数，默认 15；每项另有一次预热
  --suite LIST      micro、storage、network，逗号分隔，默认 micro,storage,network
  --tests LIST      仅执行指定测试名，逗号分隔；用于定向复测
  --seed N          runtime 轮转随机种子，默认 20260909
  --output DIR      结果目录，默认 _output/cube-cri-perf/<run-id>
  --profile NAME    full（默认）或 fast；fast 使用短载荷和核心测例
  --cpu N           三组统一 CPU limit/request，默认 4
  --memory SIZE     三组统一内存 limit/request，默认 2Gi
  --fio-size SIZE   fio 文件大小，默认 512M
  --fio-runtime N   fio 每轮时长（秒），默认 30
  --iperf-runtime N iperf 每轮时长（秒），默认 30
  --keep            失败时保留 namespace 与 Host 临时根目录
EOF
}

while (($#)); do
  case "$1" in
    --node) node="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --rounds) rounds="$2"; rounds_set=true; shift 2 ;;
    --suite) suites="$2"; shift 2 ;;
    --tests) test_filter="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --output) output_dir="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --cpu) cpu="$2"; shift 2 ;;
    --memory) memory="$2"; shift 2 ;;
    --fio-size) fio_size="$2"; fio_size_set=true; shift 2 ;;
    --fio-runtime) fio_runtime="$2"; fio_runtime_set=true; shift 2 ;;
    --iperf-runtime) iperf_runtime="$2"; iperf_runtime_set=true; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$profile" in
  full) ;;
  fast)
    [[ "$rounds_set" == true ]] || rounds=3
    [[ "$fio_size_set" == true ]] || fio_size="16M"
    [[ "$fio_runtime_set" == true ]] || fio_runtime=3
    [[ "$iperf_runtime_set" == true ]] || iperf_runtime=3
    sysbench_runtime=3
    hackbench_loops=200
    hackbench_groups=5
    lmbench_memory_size="32M"
    lmbench_file_size_mib=16
    lmbench_samples=1
    lmbench_iterations=1000000
    stream_profile="fast"
    # 覆盖内核关键路径，避免把 Pod 编排开销放大为测试主体。
    [[ -n "$test_filter" ]] || test_filter="sysbench-cpu,stream-triad,lmbench-lat-mem-rd,lmbench-pagefault,lmbench-fork,lmbench-ctx,fio-randread,fio-randwrite,fio-seqwrite,iperf-tcp1,iperf-tcp4"
    ;;
  *) echo '--profile 仅支持 full 或 fast' >&2; exit 2 ;;
esac
[[ "$rounds" =~ ^[1-9][0-9]*$ ]] || { echo '--rounds 必须是正整数' >&2; exit 2; }
[[ "$seed" =~ ^[0-9]+$ ]] || { echo '--seed 必须是整数' >&2; exit 2; }
[[ "$cpu" =~ ^[1-9][0-9]*$ ]] || { echo '--cpu 必须是正整数' >&2; exit 2; }
[[ "$memory" =~ ^[1-9][0-9]*([KMGTE]i?|[kMGTPE])?$ ]] || { echo '--memory 必须是 Kubernetes 容量值' >&2; exit 2; }
[[ "$fio_size" =~ ^[1-9][0-9]*([KMGT]i?|[kMGT])?$ ]] || { echo '--fio-size 必须是容量值' >&2; exit 2; }
[[ "$fio_runtime" =~ ^[1-9][0-9]*$ ]] || { echo '--fio-runtime 必须是正整数' >&2; exit 2; }
[[ "$iperf_runtime" =~ ^[1-9][0-9]*$ ]] || { echo '--iperf-runtime 必须是正整数' >&2; exit 2; }
[[ "$sysbench_runtime" =~ ^[1-9][0-9]*$ && "$hackbench_loops" =~ ^[1-9][0-9]*$ && "$hackbench_groups" =~ ^[1-9][0-9]*$ ]] || { echo '微基准负载必须为正整数' >&2; exit 2; }
[[ "$lmbench_memory_size" =~ ^[1-9][0-9]*[M]$ && "$lmbench_file_size_mib" =~ ^[1-9][0-9]*$ && "$lmbench_samples" =~ ^[1-9][0-9]*$ && "$lmbench_iterations" =~ ^[1-9][0-9]*$ ]] || { echo 'LMbench 负载参数无效' >&2; exit 2; }
memory_bytes() {
  local amount unit factor=1
  if [[ "$1" =~ ^([1-9][0-9]*)(Ki|Mi|Gi|Ti)?$ ]]; then
    amount="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]:-}"
    case "$unit" in
      Ki) factor=1024 ;;
      Mi) factor=$((1024 * 1024)) ;;
      Gi) factor=$((1024 * 1024 * 1024)) ;;
      Ti) factor=$((1024 * 1024 * 1024 * 1024)) ;;
    esac
    echo $((amount * factor))
  else
    echo '--memory 传给 Host cgroup 时仅支持整数或 Ki/Mi/Gi/Ti' >&2
    exit 2
  fi
}
memory_max="$(memory_bytes "$memory")"

if [[ -z "$node" ]]; then
  node="$(kubectl get nodes -l agc.cloud.tencent.com/cube-ready=true -o jsonpath='{range .items[?(@.spec.unschedulable!=true)]}{.metadata.name}{"\n"}{end}' | head -n1)"
fi
[[ -n "$node" ]] || { echo '未找到可调度 Cube 节点；请使用 --node 指定' >&2; exit 1; }
run_id="cube-cri-perf-$(date +%Y%m%d%H%M%S)"
namespace="$run_id"
host_root="/var/lib/cube-cri-perf/$run_id"
output_dir="${output_dir:-$repo_dir/_output/cube-cri-perf/$run_id}"
mkdir -p "$output_dir"
raw="$output_dir/results.jsonl"
: > "$raw"
jq -n \
  --arg node "$node" --arg image "$image" --arg profile "$profile" --argjson rounds "$rounds" --argjson seed "$seed" \
  --arg cpu "$cpu" --arg memory "$memory" --arg fio_size "$fio_size" \
  --arg lmbench_memory_size "$lmbench_memory_size" --arg stream_profile "$stream_profile" --argjson fio_runtime "$fio_runtime" --argjson iperf_runtime "$iperf_runtime" \
  --argjson sysbench_runtime "$sysbench_runtime" --argjson hackbench_loops "$hackbench_loops" --argjson hackbench_groups "$hackbench_groups" \
  --argjson lmbench_file_size_mib "$lmbench_file_size_mib" --argjson lmbench_samples "$lmbench_samples" --argjson lmbench_iterations "$lmbench_iterations" \
  '{node:$node,image:$image,profile:$profile,rounds:$rounds,seed:$seed,cpu:$cpu,memory:$memory,fio_size:$fio_size,fio_runtime_seconds:$fio_runtime,iperf_runtime_seconds:$iperf_runtime,sysbench_runtime_seconds:$sysbench_runtime,hackbench_loops:$hackbench_loops,hackbench_groups:$hackbench_groups,lmbench_memory_size:$lmbench_memory_size,lmbench_file_size_mib:$lmbench_file_size_mib,lmbench_samples:$lmbench_samples,lmbench_iterations:$lmbench_iterations,stream_profile:$stream_profile}' \
  > "$output_dir/run-config.json"

contains_suite() { [[ ",$suites," == *",$1,"* ]]; }
wait_phase() {
  local pod="$1" deadline=$((SECONDS + 600)) phase
  while ((SECONDS < deadline)); do
    phase="$(kubectl -n "$namespace" get "pod/$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Succeeded ]] && return 0
    if [[ "$phase" == Failed ]]; then
      kubectl -n "$namespace" describe "pod/$pod" >&2 || true
      kubectl -n "$namespace" logs "pod/$pod" >&2 || true
      return 1
    fi
    sleep 1
  done
  kubectl -n "$namespace" describe "pod/$pod" >&2 || true
  return 1
}
record_line() {
  local log_file="$1" mode="$2" line
  line="$(awk '/^\{/{last=$0} END{print last}' "$log_file")"
  [[ -n "$line" ]] || { echo "未从 $log_file 取得 JSON 测试结果" >&2; return 1; }
  jq -ce --arg mode "$mode" '. + {mode:$mode}' <<<"$line" >> "$raw"
}
create_host_agent() {
  cat <<EOF | kubectl -n "$namespace" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: host-agent}
spec:
  hostPID: true
  hostNetwork: true
  nodeName: "${node}"
  volumes: [{name: host-root, hostPath: {path: /, type: Directory}}]
  initContainers:
  - name: prepare-rootfs
    image: ${image}
    imagePullPolicy: IfNotPresent
    securityContext: {privileged: true}
    volumeMounts: [{name: host-root, mountPath: /host}]
    command: ["/bin/bash", "-ec"]
    args:
    - |
      target=/host${host_root}/rootfs
      rm -rf "\$target"
      mkdir -p "\$target"/{dev,proc,sys,work,tmp}
      tar -C / -cf - bin etc lib lib64 opt sbin usr | tar -C "\$target" -xf -
  containers:
  - name: agent
    image: ${image}
    imagePullPolicy: IfNotPresent
    securityContext: {privileged: true}
    env: [{name: HOST_BENCH_ROOT, value: "${host_root}"}]
    volumeMounts: [{name: host-root, mountPath: /host}]
    command: ["/bin/bash", "-c", "sleep infinity"]
EOF
  kubectl -n "$namespace" wait --for=condition=Ready pod/host-agent --timeout=10m >/dev/null
}
create_runtime_agents() {
  local mode role pod
  for mode in runc cube; do
    for role in client server; do
      pod="${mode}-${role}-agent"
      cat <<EOF | kubectl -n "$namespace" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: ${pod}}
spec:
  runtimeClassName: ${mode}
  nodeName: "${node}"
  volumes: [{name: work, emptyDir: {}}]
  containers:
  - name: benchmark
    image: ${image}
    imagePullPolicy: IfNotPresent
    command: ["sleep", "infinity"]
    volumeMounts: [{name: work, mountPath: /work}]
    resources:
      requests: {cpu: "${cpu}", memory: "${memory}"}
      limits: {cpu: "${cpu}", memory: "${memory}"}
EOF
    done
  done
  for mode in runc cube; do
    for role in client server; do
      kubectl -n "$namespace" wait --for=condition=Ready "pod/${mode}-${role}-agent" --timeout=10m >/dev/null
    done
  done
}
run_host() {
  local test="$1"
  local round="$2"
  local pod="host-agent"
  local iperf_host="${3:-}"
  kubectl -n "$namespace" exec "$pod" -- env ROUND="$round" CPU_LIMIT="$cpu" MEMORY_LIMIT_BYTES="$memory_max" FIO_SIZE="$fio_size" FIO_RUNTIME="$fio_runtime" IPERF_RUNTIME="$iperf_runtime" SYSBENCH_RUNTIME="$sysbench_runtime" HACKBENCH_LOOPS="$hackbench_loops" HACKBENCH_GROUPS="$hackbench_groups" LMBENCH_MEMORY_SIZE="$lmbench_memory_size" LMBENCH_FILE_SIZE_MIB="$lmbench_file_size_mib" LMBENCH_SAMPLES="$lmbench_samples" LMBENCH_ITERATIONS="$lmbench_iterations" STREAM_PROFILE="$stream_profile" IPERF_HOST="$iperf_host" \
    /opt/cube-cri-perf/run-host.sh "$test" > "$output_dir/${test}.host.${round}.log"
  local line
  line="$(awk '/^\{/{last=$0} END{print last}' "$output_dir/${test}.host.${round}.log")"
  [[ -n "$line" ]] || { echo "Host $test 未返回 JSON" >&2; return 1; }
  jq -ce --arg mode host '. + {mode:$mode}' <<<"$line" >> "$raw"
}
run_pod() {
  local mode="$1"
  local test="$2"
  local round="$3"
  local pod="${mode}-client-agent"
  local iperf_host="${4:-}"
  local result_mode="${5:-$mode}"
  local log_file="$output_dir/${test}.${result_mode}.${round}.log"
  kubectl -n "$namespace" exec "$pod" -- env ROUND="$round" WORK_DIR="/work/${test}.${round}" FIO_SIZE="$fio_size" FIO_RUNTIME="$fio_runtime" IPERF_RUNTIME="$iperf_runtime" SYSBENCH_RUNTIME="$sysbench_runtime" HACKBENCH_LOOPS="$hackbench_loops" HACKBENCH_GROUPS="$hackbench_groups" LMBENCH_MEMORY_SIZE="$lmbench_memory_size" LMBENCH_FILE_SIZE_MIB="$lmbench_file_size_mib" LMBENCH_SAMPLES="$lmbench_samples" LMBENCH_ITERATIONS="$lmbench_iterations" STREAM_PROFILE="$stream_profile" IPERF_HOST="$iperf_host" \
    /opt/cube-cri-perf/run-case.sh "$test" > "$log_file"
  record_line "$log_file" "$result_mode"
}
start_iperf_server() {
  local mode="$1" pod="${mode}-server-agent" pid
  pid="$(kubectl -n "$namespace" exec "$pod" -- sh -c 'iperf3 -s -1 -p 5201 >/tmp/iperf-server.log 2>&1 & echo $!')"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "iperf server $pod 未返回 PID" >&2; return 1; }
  sleep 1
  kubectl -n "$namespace" exec "$pod" -- sh -c "kill -0 $pid" >/dev/null || { kubectl -n "$namespace" exec "$pod" -- cat /tmp/iperf-server.log >&2 || true; return 1; }
  kubectl -n "$namespace" get "pod/$pod" -o jsonpath='{.status.podIP}'
}
run_network_round() {
  local round="$1"
  local streams="$2"
  local test="iperf-tcp${streams}"
  local ip client
  # runc server 固定，三种 client 形成可直接比较的一端 PVM 网络数据。
  # iperf3 的 -1 服务端只接受一个连接，故每个 client 使用独立服务端。
  for client in host runc cube; do
    ip="$(start_iperf_server runc)"
    if [[ "$client" == host ]]; then
      run_host "$test" "$round" "$ip"
    else
      run_pod "$client" "$test" "$round" "$ip"
    fi
  done
  # 两端均进入虚拟路径的结果单独保存，不与单端结果混合。
  ip="$(start_iperf_server cube)"
  run_pod cube "$test" "${round}00" "$ip" cube_to_cube
}
collect_runtime_environment() {
  local mode="$1"
  kubectl -n "$namespace" exec "${mode}-client-agent" -- /opt/cube-cri-perf/collect-environment.sh > "$output_dir/${mode}-environment.json"
}
preflight() {
  kubectl get runtimeclass cube runc >/dev/null
  kubectl get node "$node" -o json > "$output_dir/node.json"
  kubectl get runtimeclass cube runc -o json > "$output_dir/runtimeclass.json"
  # host-agent 已实际使用基准镜像并进入目标节点；无需依赖 node-shell 的独立
  # 工具镜像，避免受测试节点镜像仓库访问策略影响。
  kubectl -n "$namespace" exec host-agent -- nsenter -t 1 -m -u -i -n -p -- \
    sh -c 'uname -a; lscpu; free -b; findmnt -J; systemctl show -p DefaultCPUAccounting -p DefaultMemoryAccounting' \
    > "$output_dir/host-environment.txt"
  printf '基准镜像已由 host-agent 在节点验证：%s\n' "$image" > "$output_dir/node-images.txt"
}
cleanup() {
  local code=$?
  if [[ "$keep" != true ]]; then
    # host-agent 已挂载节点根目录；在删 namespace 前清理 Host 临时根目录，
    # 不依赖 node-shell 工具镜像。
    kubectl -n "$namespace" exec host-agent -- rm -rf "/host${host_root}" >/dev/null 2>&1 || true
    kubectl -n "$namespace" delete pod --all --wait=true >/dev/null 2>&1 || true
    kubectl delete namespace "$namespace" --wait=true >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap cleanup EXIT

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
create_host_agent
create_runtime_agents
preflight
collect_runtime_environment runc
collect_runtime_environment cube
micro=(sysbench-cpu stream-triad lmbench-lat-mem-rd lmbench-bw-mem lmbench-pagefault lmbench-mmap lmbench-fork lmbench-exec lmbench-ctx lmbench-syscall hackbench-process hackbench-socket)
storage=(fio-randread fio-randwrite fio-seqwrite)
tests=()
contains_suite micro && tests+=("${micro[@]}")
contains_suite storage && tests+=("${storage[@]}")
network_streams=(1 4)
if [[ -n "$test_filter" ]]; then
  filtered=()
  IFS=, read -r -a requested <<<"$test_filter"
  for candidate in "${tests[@]}"; do
    for wanted in "${requested[@]}"; do [[ "$candidate" == "$wanted" ]] && filtered+=("$candidate"); done
  done
  tests=("${filtered[@]}")
  network_streams=()
  IFS=, read -r -a requested <<<"$test_filter"
  for wanted in "${requested[@]}"; do
    [[ "$wanted" == iperf-tcp1 ]] && network_streams+=(1)
    [[ "$wanted" == iperf-tcp4 ]] && network_streams+=(4)
  done
fi
[[ ${#tests[@]} -gt 0 ]] || contains_suite network || { echo '至少选择 micro、storage 或 network' >&2; exit 2; }
contains_suite network && [[ ${#network_streams[@]} -gt 0 ]] || ! contains_suite network || { echo 'network 仅支持 iperf-tcp1、iperf-tcp4' >&2; exit 2; }

# round=0 是预热且仅归档日志；正式轮由 Python 生成确定性随机排列。
for test in "${tests[@]}"; do
  for mode in host runc cube; do
    if [[ "$mode" == host ]]; then run_host "$test" 0 > "$output_dir/${test}.host.0.log"; else run_pod "$mode" "$test" 0 >/dev/null; fi
  done
done
if contains_suite network; then
  for streams in "${network_streams[@]}"; do run_network_round 0 "$streams"; done
fi
# 预热只保留各自日志，不进入统计样本。
: > "$raw"
for test in "${tests[@]}"; do
  for round in $(seq 1 "$rounds"); do
    mapfile -t order < <(python3 - "$seed" "$test" "$round" <<'PY'
import hashlib, random, sys
r = random.Random(int(hashlib.sha256(':'.join(sys.argv[1:]).encode()).hexdigest(), 16))
modes = ['host', 'runc', 'cube']
r.shuffle(modes)
print(*modes, sep='\n')
PY
)
    for mode in "${order[@]}"; do
      if [[ "$mode" == host ]]; then run_host "$test" "$round"; else run_pod "$mode" "$test" "$round"; fi
    done
  done
done
if contains_suite network; then
  for round in $(seq 1 "$rounds"); do
    for streams in "${network_streams[@]}"; do run_network_round "$round" "$streams"; done
  done
fi
python3 "$script_dir/scripts/summarize.py" "$raw" --output-dir "$output_dir" --seed "$seed"
printf '结果：%s/report.md\n' "$output_dir"
