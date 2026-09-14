#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }

namespace=${CUBE_CRI_NAMESPACE:-cube-cri-system}
release=${CUBE_CRI_RELEASE:-cube-cri}
timeout=${CUBE_CRI_HELM_TIMEOUT:-30m}
image=${CUBE_CRI_IMAGE:-}
k() { kubectl --request-timeout=30s "$@"; }
h() { helm upgrade --help | grep -q -- "$1"; }

[[ $namespace =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "非法命名空间: $namespace" >&2; exit 2; }
[[ $release =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "非法 release 名称: $release" >&2; exit 2; }
(( ${#release} <= 54 )) || { echo "release 名称最长 54 个字符" >&2; exit 2; }
[[ -n $image ]] || { echo "请先设置 CUBE_CRI_IMAGE=<repository>@sha256:<digest>，或执行 task package:image 后 source _output/cube-cri/image.env" >&2; exit 2; }

if [[ ! $image =~ ^(.+)@sha256:([a-f0-9]{64})$ ]]; then
  echo "CUBE_CRI_IMAGE 必须是 sha256 digest 镜像: <repository>@sha256:<64位十六进制值>" >&2
  exit 2
fi
repository=${BASH_REMATCH[1]}
digest=${BASH_REMATCH[2]}
[[ $repository =~ ^[A-Za-z0-9./:_-]+$ ]] || { echo "非法镜像仓库: $repository" >&2; exit 2; }

k get nodes -l agc.cloud.tencent.com/cube=true -o json | python3 -c '
import json,sys
nodes=json.load(sys.stdin)["items"]
assert nodes, "未找到带 agc.cloud.tencent.com/cube=true 标签的节点"
for node in nodes:
    info=node["status"]["nodeInfo"]
    name=node["metadata"]["name"]
    assert info["architecture"] == "amd64" and info["osImage"].startswith("TencentOS Server 4"), f"{name}: 需要 TS4 x86_64 节点"
print("Cube nodes:", ", ".join(node["metadata"]["name"] for node in nodes))
'

k apply -f deploy/kubernetes/runtimeclass/runtimeclass.yaml
args=(upgrade --install "$release" deploy/cube-cri/chart --namespace "$namespace" --create-namespace
  --set-string "image.repository=$repository" --set-string "image.digest=$digest"
  --set "runtimeClass.enabled=false" --wait --timeout "$timeout")
if h --force-conflicts; then
  args+=(--force-conflicts)
elif h --force-replace; then
  args+=(--force-replace)
elif h "--force "; then
  args+=(--force)
fi
[[ -z ${CUBE_CRI_IMAGE_PULL_SECRET:-} ]] || args+=(--set-string "imagePullSecrets[0].name=$CUBE_CRI_IMAGE_PULL_SECRET")
[[ -z ${CUBE_CRI_HELM_VALUES:-} ]] || args+=(-f "$CUBE_CRI_HELM_VALUES")
if [[ -n ${CUBE_CRI_TRACING_OTLP_ENDPOINT:-} ]]; then
  args+=(--set-string "tracing.otlpEndpoint=$CUBE_CRI_TRACING_OTLP_ENDPOINT")
  args+=(--set-string "tracing.protocol=${CUBE_CRI_TRACING_OTLP_PROTOCOL:-http/protobuf}")
  args+=(--set-string "tracing.serviceNamePrefix=${CUBE_CRI_TRACING_SERVICE_NAME_PREFIX:-cube-cri}")
  args+=(--set-string "tracing.samplingRatio=${CUBE_CRI_TRACING_SAMPLING_RATIO:-1.0}")
fi

helm "${args[@]}"
k -n "$namespace" rollout status "daemonset/$release-cube-cri" --timeout="$timeout"
echo "Cube CRI Helm release ready: $namespace/$release image=$image"
