#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
template="$repo_root/cube-cri-testsuite/performance/manifests/cube-cri-load-pod.yaml"
runtime_class="$repo_root/cube-cri-testsuite/performance/manifests/cube-cri-load-runtimeclass.yaml"
system_namespace=cube-cri-load-system
generator_service_account=cube-cri-load-generator
generator_role=cube-cri-load-generator

stage=""
generator_node=""
run_id=""
output=""
count=""
namespace_count=""
qps=""
workers=""
timeout_seconds=""
stable_seconds=""
target_node=""
snapshotter_profile=""
load_image=""
cube_template_mode=""

erox_load_image="tcr-cube.tencentcloudcr.com/journeyyou/busybox@sha256:5b0745afdfec8efe7225bbe20cd87dc9139381e676400707ea979ec5406de3a8"
overlayfs_load_image="mirror.ccs.tencentyun.com/library/busybox:1.36.1"

usage() {
  cat >&2 <<EOF
用法: $0 --stage S0|S1|S2 --generator-node NODE [--target-node NODE] [--run-id ID] [--output DIR]

镜像/快照器模板参数:
  --snapshotter-profile erox|overlayfs
      erox:     使用正式 EROX 负载镜像，并设置 agc.cloud.tencent.com/cube-template-mode=auto
      overlayfs: 使用普通 overlayfs 镜像，并移除 cube-template-mode annotation
  --load-image IMAGE
      覆盖当前 profile 的默认镜像，会同步写入全部 initContainers/containers
  --cube-template-mode auto|none
      覆盖当前 profile 的 template-mode 行为
EOF
}

while (($#)); do
  case "$1" in
    --stage) stage="$2"; shift 2 ;;
    --generator-node) generator_node="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --count) count="$2"; shift 2 ;;
    --namespaces) namespace_count="$2"; shift 2 ;;
    --qps) qps="$2"; shift 2 ;;
    --workers) workers="$2"; shift 2 ;;
    --timeout) timeout_seconds="$2"; shift 2 ;;
    --stable-seconds) stable_seconds="$2"; shift 2 ;;
    --target-node) target_node="$2"; shift 2 ;;
    --snapshotter-profile) snapshotter_profile="$2"; shift 2 ;;
    --load-image) load_image="$2"; shift 2 ;;
    --cube-template-mode) cube_template_mode="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$stage" && -n "$generator_node" ]] || { usage; exit 2; }
[[ -n "${KUBECONFIG:-}" && -r "$KUBECONFIG" ]] || { echo "必须显式设置可读的 KUBECONFIG" >&2; exit 2; }
[[ -r "$template" ]] || { echo "找不到 workload: $template" >&2; exit 2; }
[[ -r "$runtime_class" ]] || { echo "找不到 RuntimeClass: $runtime_class" >&2; exit 2; }

case "$stage" in
  S0) defaults=(1 1 1 1 600 0) ;;
  S1) defaults=(2000 1 1000 200 1800 180) ;;
  S2) defaults=(5000 5 1000 400 1800 600) ;;
  *) echo "stage 只支持 S0、S1、S2" >&2; exit 2 ;;
esac
count="${count:-${defaults[0]}}"
namespace_count="${namespace_count:-${defaults[1]}}"
qps="${qps:-${defaults[2]}}"
workers="${workers:-${defaults[3]}}"
timeout_seconds="${timeout_seconds:-${defaults[4]}}"
stable_seconds="${stable_seconds:-${defaults[5]}}"
snapshotter_profile="${snapshotter_profile:-erox}"
case "$snapshotter_profile" in
  erox)
    load_image="${load_image:-$erox_load_image}"
    cube_template_mode="${cube_template_mode:-auto}"
    ;;
  overlayfs)
    load_image="${load_image:-$overlayfs_load_image}"
    cube_template_mode="${cube_template_mode:-none}"
    ;;
  *) echo "snapshotter-profile 只支持 erox、overlayfs" >&2; exit 2 ;;
esac
case "$cube_template_mode" in
  auto|none) ;;
  *) echo "cube-template-mode 只支持 auto、none" >&2; exit 2 ;;
esac
[[ -n "$load_image" ]] || { echo "load-image 不能为空" >&2; exit 2; }
run_id="${run_id:-$(tr '[:upper:]' '[:lower:]' <<<"$stage")-$(date -u +%Y%m%dT%H%M%SZ)}"
run_id="$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+|-+$//g' | cut -c1-32)"
[[ -n "$run_id" ]] || { echo "run-id 规范化后为空" >&2; exit 2; }
output="${output:-$repo_root/_output/cube-cri-scale/$run_id}"
mkdir -p "$output"

for value in "$count" "$namespace_count" "$qps" "$workers" "$timeout_seconds" "$stable_seconds"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "数值参数格式错误: $value" >&2; exit 2; }
done
((count > 0 && namespace_count > 0 && qps > 0 && workers > 0 && timeout_seconds > 0)) || {
  echo "count/namespaces/qps/workers/timeout 必须大于 0" >&2
  exit 2
}

node_json="$(kubectl get node "$generator_node" -o json)"
[[ "$(jq -r '.status.conditions[] | select(.type=="Ready") | .status' <<<"$node_json")" == True ]] || {
  echo "发生器节点未 Ready: $generator_node" >&2
  exit 1
}
[[ "$(jq -r '.metadata.labels["agc.cloud.tencent.com/cube-ready"] // ""' <<<"$node_json")" != true ]] || {
  echo "发生器节点带有 cube-ready 标签，拒绝混用: $generator_node" >&2
  exit 1
}
if [[ -n "$target_node" ]]; then
  [[ "$target_node" != "$generator_node" ]] || { echo "目标节点不能与发生器节点相同" >&2; exit 1; }
  target_node_json="$(kubectl get node "$target_node" -o json)"
  [[ "$(jq -r '.status.conditions[] | select(.type=="Ready") | .status' <<<"$target_node_json")" == True ]] || {
    echo "目标节点未 Ready: $target_node" >&2
    exit 1
  }
  [[ "$(jq -r '.metadata.labels["agc.cloud.tencent.com/cube-ready"] // ""' <<<"$target_node_json")" == true ]] || {
    echo "目标节点不是 Cube 节点: $target_node" >&2
    exit 1
  }
fi
kubectl label node "$generator_node" cube-cri-load-generator=true --overwrite >/dev/null
kubectl taint node "$generator_node" cube-cri-load-generator=true:NoSchedule --overwrite >/dev/null
kubectl apply -f "$runtime_class" >/dev/null

kubectl create namespace "$system_namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create serviceaccount "$generator_service_account" -n "$system_namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: $generator_role
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "get", "list", "watch", "delete"]
EOF

target_namespaces=()
for ((index=0; index<namespace_count; index++)); do
  namespace="cube-cri-load-${run_id}-${index}"
  target_namespaces+=("$namespace")
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    cube-cri-load-owned: "true"
    load-test-run: "$run_id"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cube-cri-load
  namespace: $namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $generator_role
  namespace: $namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: $generator_role
subjects:
  - kind: ServiceAccount
    name: $generator_service_account
    namespace: $system_namespace
EOF
done
namespace_csv="$(IFS=,; echo "${target_namespaces[*]}")"

yq -o=json '.' "$template" \
  | jq \
      --arg image "$load_image" \
      --arg profile "$snapshotter_profile" \
      --arg templateMode "$cube_template_mode" '
        def set_images($image):
          .spec.containers = ((.spec.containers // []) | map(.image = $image))
          | if (.spec.initContainers? // null) == null then .
            else .spec.initContainers |= map(.image = $image)
            end;
        def prune_empty_annotations:
          if ((.metadata.annotations // {}) | length) == 0 then del(.metadata.annotations) else . end;

        set_images($image)
        | .metadata.labels = (.metadata.labels // {})
        | .metadata.labels["load-test-snapshotter-profile"] = $profile
        | if $templateMode == "auto" then
            .metadata.annotations = (.metadata.annotations // {})
            | .metadata.annotations["agc.cloud.tencent.com/cube-template-mode"] = "auto"
          elif $templateMode == "none" then
            del(.metadata.annotations["agc.cloud.tencent.com/cube-template-mode"])
            | prune_empty_annotations
          else .
          end
      ' > "$output/pod-template.json"
jq -n \
  --arg runId "$run_id" --arg stage "$stage" --arg generatorNode "$generator_node" \
  --arg namespaces "$namespace_csv" --argjson count "$count" --argjson qps "$qps" \
  --argjson workers "$workers" --argjson timeout "$timeout_seconds" \
  --argjson stable "$stable_seconds" --arg targetNode "$target_node" \
  --arg snapshotterProfile "$snapshotter_profile" --arg loadImage "$load_image" \
  --arg cubeTemplateMode "$cube_template_mode" \
  '{runId:$runId,stage:$stage,generatorNode:$generatorNode,targetNode:$targetNode,targetNamespaces:($namespaces|split(",")),podCount:$count,createQPS:$qps,createWorkers:$workers,timeoutSeconds:$timeout,stableSeconds:$stable,snapshotterProfile:$snapshotterProfile,loadImage:$loadImage,cubeTemplateMode:$cubeTemplateMode}' \
  > "$output/run-config.json"
sha256sum "$script_dir/runner.py" "$template" "$runtime_class" "$output/pod-template.json" "$output/run-config.json" > "$output/artifacts.sha256"

config_map="cube-cri-load-${run_id}"
generator_pod="cube-cri-load-generator-${run_id}"
kubectl create configmap "$config_map" -n "$system_namespace" \
  --from-file=runner.py="$script_dir/runner.py" \
  --from-file=pod-template.json="$output/pod-template.json" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
jq --arg namespace "${target_namespaces[0]}" '.metadata.namespace = $namespace' "$output/pod-template.json" \
  | kubectl apply --server-side --dry-run=server -f - >/dev/null

kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $generator_pod
  namespace: $system_namespace
  labels:
    app: cube-cri-load-generator
    load-test-run: "$run_id"
spec:
  serviceAccountName: $generator_service_account
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: "$generator_node"
    cube-cri-load-generator: "true"
  tolerations:
    - key: cube-cri-load-generator
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: generator
      image: mirror.ccs.tencentyun.com/library/python:3.11-alpine
      imagePullPolicy: IfNotPresent
      command: ["/bin/sh", "-c"]
      args:
        - python /config/runner.py; rc=\$?; printf '%s\\n' "\$rc" > /output/exit-code; touch /output/done; exit "\$rc"
      env:
        - {name: RUN_ID, value: "$run_id"}
        - {name: TARGET_NAMESPACES, value: "$namespace_csv"}
        - {name: POD_COUNT, value: "$count"}
        - {name: CREATE_QPS, value: "$qps"}
        - {name: CREATE_WORKERS, value: "$workers"}
        - {name: TIMEOUT_SECONDS, value: "$timeout_seconds"}
        - {name: STABLE_SECONDS, value: "$stable_seconds"}
        - {name: TARGET_NODE, value: "$target_node"}
        - {name: TEMPLATE_PATH, value: /config/pod-template.json}
        - {name: OUTPUT_DIR, value: /output}
      resources:
        requests: {cpu: "2", memory: 2Gi}
        limits: {cpu: "16", memory: 16Gi}
      volumeMounts:
        - {name: config, mountPath: /config, readOnly: true}
        - {name: output, mountPath: /output}
    - name: artifact-holder
      image: mirror.ccs.tencentyun.com/library/busybox:1.36.1
      imagePullPolicy: IfNotPresent
      command: ["/bin/sh", "-c"]
      args: ["sleep 86400"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 64Mi}
      volumeMounts:
        - {name: output, mountPath: /output, readOnly: true}
  volumes:
    - name: config
      configMap:
        name: $config_map
    - name: output
      emptyDir: {}
EOF

kubectl wait -n "$system_namespace" --for=condition=Ready "pod/$generator_pod" --timeout=300s >/dev/null
deadline=$((SECONDS + timeout_seconds + stable_seconds + 300))
while ((SECONDS < deadline)); do
  state="$(kubectl get pod -n "$system_namespace" "$generator_pod" -o jsonpath='{.status.containerStatuses[?(@.name=="generator")].state.terminated.exitCode}' 2>/dev/null || true)"
  [[ -n "$state" ]] && break
  sleep 2
done
[[ -n "$state" ]] || { kubectl describe pod -n "$system_namespace" "$generator_pod" > "$output/generator-describe.txt"; exit 1; }
kubectl logs -n "$system_namespace" "$generator_pod" -c generator > "$output/generator.log" 2>&1 || true
kubectl cp -n "$system_namespace" -c artifact-holder "$generator_pod:/output/." "$output" >/dev/null
kubectl get pod -n "$system_namespace" "$generator_pod" -o json > "$output/generator-pod.json"
kubectl get events -n "$system_namespace" --field-selector "involvedObject.name=$generator_pod" -o json > "$output/generator-events.json"
printf 'run_id=%s generator_exit=%s output=%s\n' "$run_id" "$state" "$output"
printf 'cleanup: %s/cleanup.sh --run-id %s\n' "$script_dir" "$run_id"
exit "$state"
