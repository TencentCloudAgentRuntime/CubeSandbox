#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/../.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }

namespace=${CUBE_CRI_TRACING_NAMESPACE:-cube-cri-tracing}
storage_class=${CUBE_CRI_TRACING_STORAGE_CLASS:-}
storage_size=${CUBE_CRI_TRACING_STORAGE_SIZE:-}
jaeger_node=${CUBE_CRI_TRACING_JAEGER_NODE:-}
timeout=${CUBE_CRI_TRACING_TIMEOUT:-10m}
source_manifest=deploy/kubernetes/cube-cri-tracing/tracing.yaml
rendered=_output/cube-cri/tracing-rendered.yaml
smoke_pod=

cleanup() {
  [[ -z $smoke_pod ]] || kubectl -n "$namespace" delete pod "$smoke_pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ -n ${KUBECONFIG:-} && -r $KUBECONFIG ]] || {
  echo "请设置 KUBECONFIG 为可读的 kubeconfig" >&2
  exit 2
}
[[ $namespace =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "非法 namespace: $namespace" >&2; exit 2; }
[[ -z $jaeger_node || $jaeger_node =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || { echo "非法 Jaeger 节点名: $jaeger_node" >&2; exit 2; }

existing_pvc=$(kubectl -n "$namespace" get pvc cube-cri-jaeger-data -o json 2>/dev/null || true)
existing_jaeger_node=$(kubectl -n "$namespace" get deployment cube-cri-jaeger \
  -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}' 2>/dev/null || true)
if [[ -n $existing_pvc ]]; then
  actual_storage_class=$(jq -r '.spec.storageClassName' <<< "$existing_pvc")
  actual_storage_size=$(jq -r '.spec.resources.requests.storage' <<< "$existing_pvc")
  pvc_phase=$(jq -r '.status.phase // "Pending"' <<< "$existing_pvc")
  jq -e '
    .spec.accessModes == ["ReadWriteOnce"] and
    (.spec.volumeMode // "Filesystem") == "Filesystem"
  ' <<< "$existing_pvc" >/dev/null || {
    echo "已有 PVC 必须为 ReadWriteOnce、Filesystem" >&2
    exit 1
  }
  [[ $pvc_phase == Bound || $pvc_phase == Pending ]] || {
    echo "已有 PVC 状态必须为 Bound 或 Pending: actual=$pvc_phase" >&2
    exit 1
  }
  [[ $pvc_phase != Bound || $(jq -r '.spec.volumeName // ""' <<< "$existing_pvc") != "" ]] || {
    echo "Bound PVC 必须绑定有效 PV" >&2
    exit 1
  }
  [[ -z $storage_class || $storage_class == "$actual_storage_class" ]] || {
    echo "已有 PVC 的 StorageClass 不可变: actual=$actual_storage_class requested=$storage_class" >&2
    exit 1
  }
  [[ -z $storage_size || $storage_size == "$actual_storage_size" ]] || {
    echo "已有 PVC 容量不做隐式变更: actual=$actual_storage_size requested=$storage_size" >&2
    exit 1
  }
  storage_class=$actual_storage_class
  storage_size=$actual_storage_size
  [[ -z $jaeger_node || -z $existing_jaeger_node || $jaeger_node == "$existing_jaeger_node" ]] || {
    echo "已有 RWO PVC 时不自动迁移 Jaeger 节点: actual=$existing_jaeger_node requested=$jaeger_node" >&2
    exit 1
  }
fi
storage_class=${storage_class:-sandbox-cbs-wait}
storage_size=${storage_size:-20Gi}
[[ $storage_class =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ ]] || { echo "非法 StorageClass: $storage_class" >&2; exit 2; }
[[ $storage_size =~ ^[1-9][0-9]*(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)$ ]] || { echo "非法存储容量: $storage_size" >&2; exit 2; }
if [[ -z $existing_pvc || ${pvc_phase:-} == Pending ]]; then
  binding_mode=$(kubectl get storageclass "$storage_class" -o jsonpath='{.volumeBindingMode}')
  [[ $binding_mode == WaitForFirstConsumer ]] || {
    echo "未绑定 PVC 要求 WaitForFirstConsumer StorageClass，避免 PVC 与 Jaeger 节点拓扑冲突: $storage_class=$binding_mode" >&2
    exit 1
  }
fi

if [[ -z $jaeger_node ]]; then
  jaeger_node=$existing_jaeger_node
fi
[[ -n $jaeger_node ]] || {
  echo "请设置 CUBE_CRI_TRACING_JAEGER_NODE；首次部署需要一个可挂载 PVC 且目标节点可访问的物理节点" >&2
  exit 2
}
node_json=$(kubectl get node "$jaeger_node" -o json)
jq -e '
  any(.status.conditions[]; .type == "Ready" and .status == "True") and
  (.status.nodeInfo.containerRuntimeVersion | startswith("eks://") | not)
' <<< "$node_json" >/dev/null || {
  echo "Jaeger 节点必须 Ready 且不是 EKS 虚拟节点: $jaeger_node" >&2
  exit 1
}

if [[ -n $existing_pvc && $pvc_phase == Bound ]]; then
  pv_name=$(jq -r '.spec.volumeName' <<< "$existing_pvc")
  pv_json=$(kubectl get pv "$pv_name" -o json)
  node_labels=$(jq -c '.metadata.labels // {}' <<< "$node_json")
  jq -e --arg node_name "$jaeger_node" --argjson labels "$node_labels" '
    def node_value($key):
      if $key == "metadata.name" then $node_name else $labels[$key] end;
    def matches($requirement):
      (node_value($requirement.key)) as $value |
      if $requirement.operator == "In" then
        $value != null and any($requirement.values[]?; . == $value)
      elif $requirement.operator == "NotIn" then
        $value == null or all($requirement.values[]?; . != $value)
      elif $requirement.operator == "Exists" then
        $value != null
      elif $requirement.operator == "DoesNotExist" then
        $value == null
      elif $requirement.operator == "Gt" then
        $value != null and (($value | tonumber) > ($requirement.values[0] | tonumber))
      elif $requirement.operator == "Lt" then
        $value != null and (($value | tonumber) < ($requirement.values[0] | tonumber))
      else
        false
      end;
    (.spec.nodeAffinity.required.nodeSelectorTerms // []) as $terms |
    ($terms | length == 0) or any($terms[];
      all((.matchExpressions // [])[]; matches(.)) and
      all((.matchFields // [])[]; matches(.)))
  ' <<< "$pv_json" >/dev/null || {
    echo "Jaeger 节点不满足已绑定 PV 的 required node affinity: node=$jaeger_node pv=$pv_name" >&2
    exit 1
  }
fi

collector_nodes=$(kubectl get nodes -l agc.cloud.tencent.com/cube=true -o json | jq '[
  .items[] |
  select(any(.status.conditions[]; .type == "Ready" and .status == "True"))
] | length')
((collector_nodes > 0)) || {
  echo "没有 Ready 且带 agc.cloud.tencent.com/cube=true 标签的 Collector 目标节点" >&2
  exit 1
}

mkdir -p "$(dirname "$rendered")"
sed \
  -e "s/__NAMESPACE__/$namespace/g" \
  -e "s/__STORAGE_CLASS__/$storage_class/g" \
  -e "s/__STORAGE_SIZE__/$storage_size/g" \
  "$source_manifest" > "$rendered"

collector_config_sha=$(yq -r '
  select(.kind == "ConfigMap" and .metadata.name == "cube-cri-otel-collector") |
  .data."config.yaml"
' "$rendered" | sha256sum | awk '{print $1}')
sed -i "s/__COLLECTOR_CONFIG_SHA__/$collector_config_sha/g" "$rendered"

JAEGER_NODE=$jaeger_node yq -i '
  (select(.kind == "Deployment" and .metadata.name == "cube-cri-jaeger") |
    .spec.template.spec.nodeSelector."kubernetes.io/hostname") = strenv(JAEGER_NODE)
' "$rendered"

kubectl apply -f "$rendered"
kubectl -n "$namespace" wait pvc/cube-cri-jaeger-data --for=jsonpath='{.status.phase}'=Bound --timeout="$timeout"
kubectl -n "$namespace" rollout status deployment/cube-cri-jaeger --timeout="$timeout"
kubectl -n "$namespace" rollout status daemonset/cube-cri-otel-collector --timeout="$timeout"

trace_id=$(tr -d '-' </proc/sys/kernel/random/uuid)
span_id=${trace_id:0:16}
start_ns=$(date +%s%N)
end_ns=$((start_ns + 1000000))
smoke_pod=cube-cri-tracing-smoke-${trace_id:0:8}
smoke_node=$(kubectl -n "$namespace" get pods -l app.kubernetes.io/name=cube-cri-otel-collector -o json | jq -r '[
  .items[] |
  select(.status.phase == "Running" and any(.status.containerStatuses[]?; .ready == true)) |
  .spec.nodeName
] | first // empty')
[[ -n $smoke_node ]] || {
  echo "没有可用于合成 trace 门禁的 Ready Collector Pod" >&2
  exit 1
}
kubectl -n "$namespace" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $smoke_pod
spec:
  nodeName: $smoke_node
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  restartPolicy: Never
  tolerations:
  - {key: cube-cri-load-generator, operator: Equal, value: "true", effect: NoSchedule}
  containers:
  - name: sender
    image: mirror.ccs.tencentyun.com/library/busybox:1.36.1
    command: ["/bin/sh", "-c"]
    args:
    - >-
      wget -qO- --header='Content-Type: application/json'
      --post-data='{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"cube-cri-tracing-smoke"}}]},"scopeSpans":[{"scope":{"name":"deploy-tracing"},"spans":[{"traceId":"$trace_id","spanId":"$span_id","name":"deploy-tracing-smoke","kind":1,"startTimeUnixNano":"$start_ns","endTimeUnixNano":"$end_ns"}]}]}]}'
      http://127.0.0.1:4318/v1/traces
EOF
if ! kubectl -n "$namespace" wait "pod/$smoke_pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null; then
  kubectl -n "$namespace" logs "$smoke_pod" >&2 || true
  echo "合成 OTLP span 发送失败" >&2
  exit 1
fi
kubectl -n "$namespace" delete pod "$smoke_pod" --wait=false >/dev/null
smoke_pod=

trace_found=false
for _ in $(seq 1 30); do
  response=$(kubectl get --raw "/api/v1/namespaces/$namespace/services/http:cube-cri-jaeger:16686/proxy/api/traces/$trace_id" 2>/dev/null || true)
  if jq -e --arg trace_id "$trace_id" '.data | any(.traceID == $trace_id)' <<< "$response" >/dev/null 2>&1; then
    trace_found=true
    break
  fi
  sleep 2
done
[[ $trace_found == true ]] || {
  echo "Jaeger 未查询到合成 trace: $trace_id" >&2
  exit 1
}

kubectl -n "$namespace" get pvc cube-cri-jaeger-data
kubectl -n "$namespace" get deployment cube-cri-jaeger
kubectl -n "$namespace" get daemonset cube-cri-otel-collector
echo "Tracing ready: namespace=$namespace jaeger_node=$jaeger_node storage=$storage_class/$storage_size smoke_trace=$trace_id"
