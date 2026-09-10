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
  --keep            失败时保留 namespace 与 Host 临时根目录
EOF
}

while (($#)); do
  case "$1" in
    --node) node="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --rounds) rounds="$2"; shift 2 ;;
    --suite) suites="$2"; shift 2 ;;
    --tests) test_filter="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --output) output_dir="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$rounds" =~ ^[1-9][0-9]*$ ]] || { echo '--rounds 必须是正整数' >&2; exit 2; }
[[ "$seed" =~ ^[0-9]+$ ]] || { echo '--seed 必须是整数' >&2; exit 2; }

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
record_log() {
  local pod="$1" mode="$2" line
  line="$(kubectl -n "$namespace" logs "$pod" | awk '/^\{/{last=$0} END{print last}')"
  [[ -n "$line" ]] || { echo "未从 $pod 取得 JSON 测试结果" >&2; return 1; }
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
  nodeSelector: {kubernetes.io/hostname: "${node}"}
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
run_host() {
  local test="$1"
  local round="$2"
  local pod="host-agent"
  local iperf_host="${3:-}"
  kubectl -n "$namespace" exec "$pod" -- env ROUND="$round" FIO_SIZE="${FIO_SIZE:-512M}" FIO_RUNTIME="${FIO_RUNTIME:-30}" IPERF_HOST="$iperf_host" \
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
  local pod="${mode}-${test}-${round}"
  local iperf_host="${4:-}"
  local result_mode="${5:-$mode}"
  cat <<EOF | kubectl -n "$namespace" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: ${pod}}
spec:
  restartPolicy: Never
  runtimeClassName: ${mode}
  nodeSelector: {kubernetes.io/hostname: "${node}"}
  volumes: [{name: work, emptyDir: {}}]
  containers:
  - name: benchmark
    image: ${image}
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "/opt/cube-cri-perf/run-case.sh", "${test}"]
    env:
    - {name: ROUND, value: "${round}"}
    - {name: FIO_SIZE, value: "${FIO_SIZE:-512M}"}
    - {name: FIO_RUNTIME, value: "${FIO_RUNTIME:-30}"}
    - {name: IPERF_HOST, value: "${iperf_host}"}
    volumeMounts: [{name: work, mountPath: /work}]
    resources:
      requests: {cpu: "1", memory: "2Gi"}
      limits: {cpu: "1", memory: "2Gi"}
EOF
  wait_phase "$pod"
  record_log "$pod" "$result_mode"
  kubectl -n "$namespace" delete "pod/$pod" --wait=true >/dev/null
}
start_iperf_server() {
  local mode="$1"
  local round="$2"
  local pod="iperf-server-${mode}-${round}"
  cat <<EOF | kubectl -n "$namespace" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: ${pod}}
spec:
  restartPolicy: Never
  runtimeClassName: ${mode}
  nodeSelector: {kubernetes.io/hostname: "${node}"}
  containers:
  - name: server
    image: ${image}
    imagePullPolicy: IfNotPresent
    command: ["iperf3", "-s", "-1", "-p", "5201"]
    resources:
      requests: {cpu: "1", memory: "2Gi"}
      limits: {cpu: "1", memory: "2Gi"}
EOF
  local deadline=$((SECONDS + 600)) phase
  while ((SECONDS < deadline)); do
    phase="$(kubectl -n "$namespace" get "pod/$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Running ]] && break
    [[ "$phase" == Failed ]] && { kubectl -n "$namespace" describe "pod/$pod" >&2; return 1; }
    sleep 1
  done
  [[ "$phase" == Running ]] || { echo "iperf server $pod 未启动" >&2; return 1; }
  kubectl -n "$namespace" get "pod/$pod" -o jsonpath='{.status.podIP}'
}
run_network_round() {
  local round="$1"
  local streams="$2"
  local test="iperf-tcp${streams}"
  local ip client server
  # runc server 固定，三种 client 形成可直接比较的一端 PVM 网络数据。
  # iperf3 的 -1 服务端只接受一个连接，故每个 client 使用独立服务端。
  for client in host runc cube; do
    server="${round}-${streams}-baseline-${client}"
    ip="$(start_iperf_server runc "$server")"
    if [[ "$client" == host ]]; then
      run_host "$test" "$round" "$ip"
    else
      run_pod "$client" "$test" "$round" "$ip"
    fi
    kubectl -n "$namespace" delete pod "iperf-server-runc-${server}" --wait=true >/dev/null
  done
  # 两端均进入虚拟路径的结果单独保存，不与单端结果混合。
  ip="$(start_iperf_server cube "${round}-${streams}-cube")"
  run_pod cube "$test" "${round}00" "$ip" cube_to_cube
  kubectl -n "$namespace" delete pod "iperf-server-cube-${round}-${streams}-cube" --wait=true >/dev/null
}
collect_runtime_environment() {
  local mode="$1"
  local pod="${mode}-environment"
  cat <<EOF | kubectl -n "$namespace" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: ${pod}}
spec:
  runtimeClassName: ${mode}
  nodeSelector: {kubernetes.io/hostname: "${node}"}
  volumes: [{name: work, emptyDir: {}}]
  containers:
  - name: benchmark
    image: ${image}
    imagePullPolicy: IfNotPresent
    command: ["sleep", "600"]
    volumeMounts: [{name: work, mountPath: /work}]
    resources:
      requests: {cpu: "1", memory: "2Gi"}
      limits: {cpu: "1", memory: "2Gi"}
EOF
  kubectl -n "$namespace" wait --for=condition=Ready "pod/$pod" --timeout=10m >/dev/null
  kubectl -n "$namespace" exec "$pod" -- /opt/cube-cri-perf/collect-environment.sh > "$output_dir/${mode}-environment.json"
  kubectl -n "$namespace" delete "pod/$pod" --wait=true >/dev/null
}
preflight() {
  kubectl get runtimeclass cube runc >/dev/null
  kubectl get node "$node" -o json > "$output_dir/node.json"
  kubectl get runtimeclass cube runc -o json > "$output_dir/runtimeclass.json"
  kubectl node-shell "$node" -- sh -c 'uname -a; lscpu; free -b; findmnt -J; systemctl show -p DefaultCPUAccounting -p DefaultMemoryAccounting' > "$output_dir/host-environment.txt"
  kubectl node-shell "$node" -- sh -c "ctr -n k8s.io images ls | awk 'NR==1 || /${image%%:*}/'" > "$output_dir/node-images.txt"
  grep -q "${image%%:*}" "$output_dir/node-images.txt" || { echo "节点未导入镜像 $image；先运行 build-image.sh" >&2; exit 1; }
}
cleanup() {
  local code=$?
  if [[ "$keep" != true ]]; then
    kubectl -n "$namespace" delete pod --all --wait=true >/dev/null 2>&1 || true
    kubectl delete namespace "$namespace" --wait=true >/dev/null 2>&1 || true
    kubectl node-shell "$node" -- rm -rf "$host_root" >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap cleanup EXIT

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
preflight
create_host_agent
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
