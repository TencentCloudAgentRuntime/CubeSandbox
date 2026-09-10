#!/usr/bin/env bash
# 构建后直接导入指定节点的 containerd，避免私有仓库拉取权限影响测评。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${IMAGE:-cube-cri-perf:dev}"
node="${NODE_NAME:?请设置 NODE_NAME}"

docker build -f "$script_dir/Containerfile" -t "$image" "$script_dir"
docker save "$image" | kubectl node-shell "$node" -- sh -c 'ctr -n k8s.io images import -'
docker image inspect "$image" --format '{{json .RepoDigests}} {{.Id}}'
