#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/../.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }

kubeconfig=${EROX_KUBECONFIG:-${KUBECONFIG:-}}
nodes_raw=${EROX_NODES:-}
namespace=${EROX_NAMESPACE:-kube-system}
release=${EROX_RELEASE:-erox-node}
chart=${EROX_CHART:-oci://tcr-cube.tencentcloudcr.com/cube/erox-node}
version=${EROX_CHART_VERSION:-0.2.1-tcr.20260914}
timeout=${EROX_TIMEOUT:-10m}

[[ -n $kubeconfig && -r $kubeconfig ]] || {
  echo "请设置 EROX_KUBECONFIG（或 KUBECONFIG）为可读的 kubeconfig" >&2
  exit 2
}
[[ -n $nodes_raw ]] || {
  echo "请设置 EROX_NODES，以逗号或空格分隔目标 Cube 节点" >&2
  exit 2
}
[[ $namespace =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "非法命名空间: $namespace" >&2; exit 2; }
[[ $release =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "非法 release 名称: $release" >&2; exit 2; }

k() { kubectl --kubeconfig "$kubeconfig" --request-timeout=30s "$@"; }

read -r -a candidates <<< "${nodes_raw//,/ }"
nodes=()
for node in "${candidates[@]}"; do
  [[ -n $node ]] || continue
  [[ $node =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { echo "非法节点名: $node" >&2; exit 2; }
  if ((${#nodes[@]} > 0)); then
    for existing in "${nodes[@]}"; do
      [[ $existing != "$node" ]] || continue 2
    done
  fi
  nodes+=("$node")
done
((${#nodes[@]} > 0)) || { echo "EROX_NODES 未包含有效节点" >&2; exit 2; }

for node in "${nodes[@]}"; do
  node_json=$(k get node "$node" -o json)
  jq -e '
    .metadata.labels["agc.cloud.tencent.com/cube"] == "true" and
    .status.nodeInfo.architecture == "amd64" and
    (.status.nodeInfo.osImage | startswith("TencentOS Server 4")) and
    any(.status.conditions[]; .type == "Ready" and .status == "True")
  ' <<< "$node_json" >/dev/null || {
    echo "$node 必须是 Ready、amd64、TS4 且带 agc.cloud.tencent.com/cube=true 标签的节点" >&2
    exit 1
  }
done

helm --kubeconfig "$kubeconfig" upgrade --install "$release" "$chart" \
  --version "$version" \
  --namespace "$namespace" \
  --create-namespace \
  --set-string registry.host=tcr-cube.tencentcloudcr.com \
  --set-string registry.baseURL=https://tcr-cube.tencentcloudcr.com \
  --set-string kubeletProfile=tke-config-dir \
  --set snapshotter.maxSlots=128 \
  --set nbd.nbdsMax=128 \
  --set nbd.maxPart=8 \
  --set-string 'nodeSelector.erox\.tencentcloud\.com/enabled=true' \
  --wait \
  --timeout "$timeout"

migrated_nodes=()
for node in "${nodes[@]}"; do
  enabled=$(k get node "$node" -o jsonpath='{.metadata.labels.erox\.tencentcloud\.com/enabled}')
  ready=$(k get node "$node" -o jsonpath='{.metadata.labels.erox\.tencentcloud\.com/ready}')
  if [[ $enabled != true || $ready != true ]]; then
    k drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout="$timeout"
    k label node "$node" erox.tencentcloud.com/enabled=true --overwrite
    k wait "node/$node" --for=jsonpath='{.metadata.labels.erox\.tencentcloud\.com/ready}'=true --timeout="$timeout"
    migrated_nodes+=("$node")
  fi
done

daemonset=$release-erox-node-installer
desired=$(k -n "$namespace" get "daemonset/$daemonset" -o jsonpath='{.status.desiredNumberScheduled}')
k -n "$namespace" wait "daemonset/$daemonset" \
  --for=jsonpath='{.status.numberReady}'="$desired" \
  --timeout="$timeout"
k -n "$namespace" get "daemonset/$daemonset" -o json | jq -e '
  .status.observedGeneration == .metadata.generation and
  .status.desiredNumberScheduled == .status.updatedNumberScheduled and
  .status.desiredNumberScheduled == .status.numberReady and
  ((.status.numberUnavailable // 0) == 0)
' >/dev/null || {
  echo "EROX DaemonSet 未全部更新并 Ready: $namespace/$daemonset" >&2
  exit 1
}

for node in "${nodes[@]}"; do
  KUBECONFIG="$kubeconfig" kubectl node-shell "$node" -- bash -lc '
    set -Eeuo pipefail
    actual=/var/lib/erox-node-snapshotter/native/snapshots
    imagefs=/var/lib/erox-node-snapshotter/snapshots
    fallback=/var/lib/containerd/io.containerd.snapshotter.v1.erox
    test -d "$actual"
    if [[ -L $imagefs ]]; then
      [[ $(readlink "$imagefs") == "$actual" ]]
    elif [[ -e $imagefs ]]; then
      echo "$imagefs 已存在且不是预期兼容链接" >&2
      exit 1
    else
      [[ $(stat -c %d /var/lib/erox-node-snapshotter) == $(stat -c %d "$actual") ]]
      ln -s "$actual" "$imagefs"
    fi
    if [[ -L $fallback ]]; then
      [[ $(readlink "$fallback") == "$actual" ]]
    elif [[ -e $fallback ]]; then
      echo "$fallback 已存在且不是预期兼容链接" >&2
      exit 1
    else
      [[ $(stat -c %d /var/lib/containerd) == $(stat -c %d "$actual") ]]
      ln -s "$actual" "$fallback"
    fi
    systemctl is-active --quiet erox-node-snapshotter.service
    systemctl is-active --quiet erox-tcr-adapter.service
    systemctl is-active --quiet containerd.service
    systemctl is-active --quiet kubelet.service
    ctr plugins ls | grep -Eq "io.containerd.snapshotter.v1[[:space:]]+erox[[:space:]].*ok"
    [[ $(cat /sys/module/nbd/parameters/nbds_max) -ge 128 ]]
    crictl imagefsinfo >/dev/null
    status=$(/usr/local/lib/erox-snapshotter/erox-snapshotter status -addr 127.0.0.1:17782 -json)
    grep -Eq "\"unmanaged_devices\"[[:space:]]*:[[:space:]]*(null|\[\])" <<< "$status"
    grep -Eq "\"unmanaged_mounts\"[[:space:]]*:[[:space:]]*(null|\[\])" <<< "$status"
  '
done

if ((${#migrated_nodes[@]} > 0)); then
  for node in "${migrated_nodes[@]}"; do
    k uncordon "$node"
  done
fi

printf 'EROX ready: release=%s/%s version=%s nodes=%s\n' \
  "$namespace" "$release" "$version" "${nodes[*]}"
