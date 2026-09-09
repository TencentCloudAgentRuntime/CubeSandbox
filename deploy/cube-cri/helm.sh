#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }

namespace=${CUBE_CRI_NAMESPACE:-cube-cri-system}
release=${CUBE_CRI_RELEASE:-cube-cri}
timeout=${CUBE_CRI_HELM_TIMEOUT:-30m}
image=${CUBE_CRI_IMAGE:-}
out=$PWD/_output/cube-cri
k() { kubectl --request-timeout=30s "$@"; }

[[ $namespace =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "非法命名空间: $namespace" >&2; exit 2; }
[[ $release =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "非法 release 名称: $release" >&2; exit 2; }
(( ${#release} <= 54 )) || { echo "release 名称最长 54 个字符" >&2; exit 2; }

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

if [[ -z $image ]]; then
  : "${CUBE_CRI_IMAGE_REPOSITORY:?设置可推送且节点可拉取的安装镜像仓库，或用 CUBE_CRI_IMAGE 指定 digest 镜像}"
  rpm=${PVM_HOST_RPM:-$out/pvm-host.rpm}
  test -s "$rpm" || { echo "缺少 PVM 内核 RPM: $rpm；请设置 PVM_HOST_RPM 或执行 task build:pvm-host" >&2; exit 1; }
  bash deploy/cube-cri/package.sh
  context=$out/installer-image
  mkdir -p "$context"
  cp "$out/runtime.tar.gz" "$context/"
  cp "$rpm" "$context/pvm-host.rpm"
  cp deploy/cube-cri/{Dockerfile,daemonset-entrypoint.sh,daemonset-install.sh,daemonset-pvm.sh} "$context/"
  version=$(cd "$context"; sha256sum Dockerfile daemonset-entrypoint.sh daemonset-install.sh daemonset-pvm.sh runtime.tar.gz pvm-host.rpm | sha256sum | cut -c1-20)
  image=$CUBE_CRI_IMAGE_REPOSITORY:$version
  docker build -t "$image" "$context"
  docker push "$image"
  image=$(docker image inspect "$image" --format '{{json .RepoDigests}}' | python3 -c 'import json,sys; print(next(d for d in json.load(sys.stdin) if d.startswith(sys.argv[1]+"@")))' "$CUBE_CRI_IMAGE_REPOSITORY")
fi

if [[ ! $image =~ ^(.+)@sha256:([a-f0-9]{64})$ ]]; then
  echo "CUBE_CRI_IMAGE 必须是 sha256 digest 镜像: <repository>@sha256:<64位十六进制值>" >&2
  exit 2
fi
repository=${BASH_REMATCH[1]}
digest=${BASH_REMATCH[2]}
[[ $repository =~ ^[A-Za-z0-9./:_-]+$ ]] || { echo "非法镜像仓库: $repository" >&2; exit 2; }

k apply -f deploy/kubernetes/runtimeclass/runtimeclass.yaml
args=(upgrade --install "$release" deploy/cube-cri/chart --namespace "$namespace" --create-namespace
  --set-string "image.repository=$repository" --set-string "image.digest=$digest"
  --set "runtimeClass.enabled=false" --wait --timeout "$timeout")
[[ -z ${CUBE_CRI_IMAGE_PULL_SECRET:-} ]] || args+=(--set-string "imagePullSecrets[0].name=$CUBE_CRI_IMAGE_PULL_SECRET")
[[ -z ${CUBE_CRI_HELM_VALUES:-} ]] || args+=(-f "$CUBE_CRI_HELM_VALUES")

helm "${args[@]}"
k -n "$namespace" rollout status "daemonset/$release-cube-cri" --timeout="$timeout"
echo "Cube CRI Helm release ready: $namespace/$release image=$image"
