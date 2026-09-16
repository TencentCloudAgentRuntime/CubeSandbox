#!/usr/bin/env bash
set -Eeuo pipefail

system_namespace=cube-cri-load-system
run_id=""

while (($#)); do
  case "$1" in
    --run-id) run_id="$2"; shift 2 ;;
    -h|--help) echo "用法: $0 --run-id ID"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$run_id" ]] || { echo "必须指定 --run-id" >&2; exit 2; }
[[ -n "${KUBECONFIG:-}" && -r "$KUBECONFIG" ]] || { echo "必须显式设置可读的 KUBECONFIG" >&2; exit 2; }

mapfile -t namespaces < <(
  kubectl get namespaces -l "cube-cri-load-owned=true,load-test-run=$run_id" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)

for namespace in "${namespaces[@]}"; do
  [[ -n "$namespace" ]] || continue
  kubectl delete pods --all -n "$namespace" --wait=false >/dev/null
done

deadline=$((SECONDS + 600))
while ((SECONDS < deadline)); do
  residual_count="$(kubectl get pods -A -l "load-test-batch=$run_id" -o json | jq '.items | length')"
  [[ "$residual_count" -eq 0 ]] && break
  sleep 2
done
[[ "$residual_count" -eq 0 ]] || { echo "目标 Pod 在 600 秒内未归零: $residual_count" >&2; exit 1; }

# 大批 Pod 会产生数千条双写 Event。先显式集合删除，避免 namespace
# controller 删除 core/v1 和 events.k8s.io Event 时请求超时。
event_delete_pids=()
for namespace in "${namespaces[@]}"; do
  [[ -n "$namespace" ]] || continue
  kubectl delete events --all -n "$namespace" --wait=false --request-timeout=300s >/dev/null &
  event_delete_pids+=("$!")
  kubectl delete events.events.k8s.io --all -n "$namespace" --wait=false --request-timeout=300s >/dev/null &
  event_delete_pids+=("$!")
done
for pid in "${event_delete_pids[@]}"; do
  wait "$pid"
done

for namespace in "${namespaces[@]}"; do
  [[ -n "$namespace" ]] || continue
  kubectl delete namespace "$namespace" --wait=false >/dev/null
done

kubectl delete pod -n "$system_namespace" "cube-cri-load-generator-$run_id" --ignore-not-found --wait=false >/dev/null
kubectl delete configmap -n "$system_namespace" "cube-cri-load-$run_id" --ignore-not-found >/dev/null

deadline=$((SECONDS + 300))
while ((SECONDS < deadline)); do
  namespace_count="$(kubectl get namespaces -l "cube-cri-load-owned=true,load-test-run=$run_id" -o json | jq '.items | length')"
  generator_count="$(kubectl get pods -n "$system_namespace" -l "load-test-run=$run_id" -o json | jq '.items | length')"
  [[ "$namespace_count" -eq 0 && "$generator_count" -eq 0 ]] && break
  sleep 2
done
[[ "$namespace_count" -eq 0 ]] || { echo "目标 Namespace 在 300 秒内未归零: $namespace_count" >&2; exit 1; }
[[ "$generator_count" -eq 0 ]] || { echo "发生器 Pod 在 300 秒内未归零: $generator_count" >&2; exit 1; }

residual="$(kubectl get pods -A -l "load-test-batch=$run_id" -o name)"
[[ -z "$residual" ]] || { printf '残留 Pod:\n%s\n' "$residual" >&2; exit 1; }
printf 'cleanup_run=%s namespaces=%s residual_pods=0\n' "$run_id" "${#namespaces[@]}"
