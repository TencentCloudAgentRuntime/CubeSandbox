#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
SOURCE_NODE_IP=${SOURCE_NODE_IP:-172.19.200.7}
PEER_NODE_IP=${PEER_NODE_IP:-172.19.200.12}
ADDRESS=${ADDRESS:-/run/containerd-cube-s0.3/containerd.sock}
NAMESPACE=${NAMESPACE:-s0-3}
CTR=${CTR:-/usr/local/bin/ctr}
CRICTL=${CRICTL:-/usr/bin/crictl}
RUNTIME=${RUNTIME:-io.containerd.cube.rs}
IMAGE=${IMAGE:-docker.io/library/busybox:1.36.1}
KERNEL=${KERNEL:-/data/cubelet/s0.2-assets/kernel/vmlinux}
AGENT=${AGENT:-/data/cubelet/s0.2-assets/agent/cube-agent.ext4}
GUEST_IMAGE=${GUEST_IMAGE:-/data/cubelet/s0.2-assets/guest/cube-guest-image-cpu.img}
CONTAINERD_CONFIG=${CONTAINERD_CONFIG:-$(cd "$(dirname "$0")" && pwd)/containerd.toml}
MANIFESTS=${MANIFESTS:-$(cd "$(dirname "$0")" && pwd)/manifests.yaml}
TAP=${TAP:-cbtap0}
TASK_ID=${TASK_ID:-s03-cni}
TC_PREF=${TC_PREF:-49152}

export KUBECONFIG

source_netns=
isolated_containerd_pid=
source_node=
peer_node=

ctr() {
  "$CTR" --address "$ADDRESS" --namespace "$NAMESPACE" "$@"
}

netns() {
  nsenter --net="$source_netns" -- "$@"
}

shim_pids_for() {
  local task_id=$1
  ps -eo pid=,args= | awk -v ns="$NAMESPACE" -v task_id="$task_id" '
    $2 ~ /(^|\/)containerd-shim-cube/ {
      namespace_match = 0
      task_match = 0
      for (i = 3; i <= NF; i++) {
        if ($i == "-namespace" && $(i + 1) == ns) {
          namespace_match = 1
        }
        if ($i == "-id" && $(i + 1) == task_id) {
          task_match = 1
        }
      }
      if (namespace_match && task_match) {
        print $1
      }
    }
  '
}

namespace_shim_pids() {
  ps -eo pid=,args= | awk -v ns="$NAMESPACE" '
    $2 ~ /(^|\/)containerd-shim-cube/ {
      for (i = 3; i <= NF; i++) {
        if ($i == "-namespace" && $(i + 1) == ns) {
          print $1
          break
        }
      }
    }
  '
}

stop_orphan_shim() {
  local task_id=$1
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] && kill -TERM "$pid" >/dev/null 2>&1 || true
  done < <(shim_pids_for "$task_id")
  for _ in $(seq 1 50); do
    [[ -z "$(shim_pids_for "$task_id")" ]] && return 0
    sleep 0.1
  done
  while read -r pid; do
    [[ -n "$pid" ]] && kill -KILL "$pid" >/dev/null 2>&1 || true
  done < <(shim_pids_for "$task_id")
}

cleanup_cube_task() {
  local task_id=${1:-$TASK_ID}
  set +e
  ctr tasks kill --signal SIGKILL "$task_id" >/dev/null 2>&1
  ctr tasks delete "$task_id" >/dev/null 2>&1
  ctr containers delete "$task_id" >/dev/null 2>&1
  stop_orphan_shim "$task_id"
  set -e
}

cleanup_tc() {
  if [[ -n "$source_netns" && -e "$source_netns" ]]; then
    netns tc filter del dev eth0 parent ffff: pref "$TC_PREF" >/dev/null 2>&1 || true
    netns tc filter del dev "$TAP" parent ffff: pref "$TC_PREF" >/dev/null 2>&1 || true
    netns ip tuntap del dev "$TAP" mode tap >/dev/null 2>&1 || true
  fi
}

cleanup() {
  set +e
  cleanup_cube_task
  cleanup_cube_task "${TASK_ID}-create-failure"
  cleanup_tc
  kubectl delete namespace cube-s0-net --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1
  if [[ -n "$isolated_containerd_pid" ]]; then
    kill "$isolated_containerd_pid" >/dev/null 2>&1
    wait "$isolated_containerd_pid" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

preflight() {
  install -d -m 0755 /data/log/CubeVmm
  test -c /dev/kvm
  test -r "$KERNEL"
  test -r "$AGENT"
  test -r "$GUEST_IMAGE"
  test -x "$CTR"
  test -x "$CRICTL"
  test -r "$CONTAINERD_CONFIG"
  test -r "$MANIFESTS"
  kubectl version

  source_node=$(kubectl get nodes -o json |
    jq -r --arg ip "$SOURCE_NODE_IP" '.items[] | select(any(.status.addresses[]; .address == $ip)) | .metadata.name')
  peer_node=$(kubectl get nodes -o json |
    jq -r --arg ip "$PEER_NODE_IP" '.items[] | select(any(.status.addresses[]; .address == $ip)) | .metadata.name')
  test -n "$source_node"
  test -n "$peer_node"
  test "$source_node" != "$peer_node"
  kubectl label node "$source_node" cube-s0-role=source --overwrite
  kubectl label node "$peer_node" cube-s0-role=peer --overwrite
}

start_isolated_containerd() {
  install -d -m 0755 /run/containerd-cube-s0.3 \
    /data/cubelet/s0.3-containerd/root \
    /data/cubelet/s0.3-containerd/state
  if [[ -S "$ADDRESS" ]] && ! ctr version >/dev/null 2>&1; then
    rm -f "$ADDRESS"
  fi
  if [[ ! -S "$ADDRESS" ]]; then
    /usr/local/bin/containerd --config "$CONTAINERD_CONFIG" \
      >/tmp/containerd-cube-s0.3.log 2>&1 &
    isolated_containerd_pid=$!
  fi
  for _ in $(seq 1 100); do
    [[ -S "$ADDRESS" ]] && break
    sleep 0.1
  done
  test -S "$ADDRESS"
  ctr plugins list | grep 'io.containerd.runtime.v2' >/dev/null
  if ! ctr images list -q | grep -Fx "$IMAGE" >/dev/null; then
    ctr images pull "$IMAGE" >/tmp/cube-s0.3-image-pull.log 2>&1
    echo S0_3_IMAGE_PULL_OK
  fi
}

create_cni_endpoints() {
  kubectl delete namespace cube-s0-net --ignore-not-found --wait=true --timeout=180s
  kubectl apply -f "$MANIFESTS"
  kubectl -n cube-s0-net wait --for=condition=Ready \
    pod/cube-source pod/cube-peer pod/cube-denied --timeout=300s

  local source_actual peer_actual
  source_actual=$(kubectl -n cube-s0-net get pod cube-source -o jsonpath='{.spec.nodeName}')
  peer_actual=$(kubectl -n cube-s0-net get pod cube-peer -o jsonpath='{.spec.nodeName}')
  test "$source_actual" = "$source_node"
  test "$peer_actual" = "$peer_node"
  test "$source_actual" != "$peer_actual"

  kubectl -n cube-s0-net get pod -o wide
  kubectl -n cube-s0-net get service,networkpolicy
  sleep 5
}

discover_source_netns() {
  local pod_id sandbox_pid
  pod_id=$("$CRICTL" --runtime-endpoint unix:///run/containerd/containerd.sock \
    pods --namespace cube-s0-net --name cube-source -q | head -n1)
  test -n "$pod_id"
  sandbox_pid=$("$CRICTL" --runtime-endpoint unix:///run/containerd/containerd.sock \
    inspectp "$pod_id" | jq -r '.info.pid')
  test "$sandbox_pid" -gt 1
  source_netns="/proc/$sandbox_pid/ns/net"
  test -e "$source_netns"
}

setup_tcfilter() {
  local mtu
  cleanup_tc
  mtu=$(netns ip -j link show dev eth0 | jq -r '.[0].mtu')
  netns ip tuntap add dev "$TAP" mode tap vnet_hdr
  netns ip link set dev "$TAP" mtu "$mtu" up
  netns tc qdisc show dev eth0 | grep -Eq 'qdisc (ingress|clsact) ffff:' ||
    netns tc qdisc add dev eth0 ingress
  netns tc qdisc add dev "$TAP" ingress
  netns tc filter replace dev eth0 parent ffff: protocol all pref "$TC_PREF" \
    u32 match u8 0 0 action mirred egress redirect dev "$TAP"
  netns tc filter replace dev "$TAP" parent ffff: protocol all pref "$TC_PREF" \
    u32 match u8 0 0 action mirred egress redirect dev eth0
  netns tc filter show dev eth0 parent ffff:
  netns tc filter show dev "$TAP" parent ffff:
}

run_expected_create_failure() {
  local net_json=$1
  local failure_id="${TASK_ID}-create-failure"
  local output rc

  cleanup_cube_task "$failure_id"
  wait_for_clean "$failure_id"
  set +e
  output=$(ctr run --rm \
    --runtime "$RUNTIME" \
    --annotation io.containerd.cube.s0.standard-rootfs=true \
    --annotation io.containerd.cube.s0.cni-netns=relative/netns \
    --annotation 'cube.vmmres={"cpu":2,"memory":1024}' \
    --annotation "cube.vm.kernel.path=$KERNEL" \
    --annotation "cube.vm.agent.path=$AGENT" \
    --annotation "cube.vm.os-image.path=$GUEST_IMAGE" \
    --annotation cube.snapshot.disable=true \
    --annotation cube.use_passfd_io=false \
    --annotation "cube.net=$net_json" \
    "$IMAGE" "$failure_id" /bin/true 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$output"
  [[ $rc -ne 0 ]]
  grep -q "must be an absolute path" <<<"$output"
  cleanup_cube_task "$failure_id"
  wait_for_clean "$failure_id"
  echo S0_3_CREATE_FAILURE_CLEAN_OK
}

run_cube_network_case() {
  local source_cidr source_ip prefix mac mtu gateway gateway_mac attempt
  local peer_ip denied_ip service_ip dns_name net_json dns_json dns_content dns_custom_json output

  source_cidr=$(netns ip -j -4 addr show dev eth0 |
    jq -r '.[0].addr_info[] | select(.scope == "global") | "\(.local)/\(.prefixlen)"' | head -n1)
  source_ip=${source_cidr%/*}
  prefix=${source_cidr#*/}
  mac=$(netns ip -j link show dev eth0 | jq -r '.[0].address')
  mtu=$(netns ip -j link show dev eth0 | jq -r '.[0].mtu')
  gateway=$(netns ip -j -4 route show default | jq -r '.[0].gateway')
  gateway_mac=
  for attempt in $(seq 1 10); do
    gateway_mac=$(netns ip -j neigh show dev eth0 |
      jq -r --arg gateway "$gateway" '.[] | select(.dst == $gateway and ((.lladdr? // "") != "")) | .lladdr' | head -n1)
    [[ -n "$gateway_mac" ]] && break
    netns ping -c 1 -W 1 "$gateway" >/dev/null 2>&1 || true
    sleep 0.1
  done
  test -n "$source_ip"
  test -n "$gateway"
  test -n "$gateway_mac"

  peer_ip=$(kubectl -n cube-s0-net get pod cube-peer -o jsonpath='{.status.podIP}')
  denied_ip=$(kubectl -n cube-s0-net get pod cube-denied -o jsonpath='{.status.podIP}')
  service_ip=$(kubectl -n cube-s0-net get service cube-peer -o jsonpath='{.spec.clusterIP}')
  dns_name=cube-peer.cube-s0-net.svc.cluster.local

  dns_json=$("$CRICTL" --runtime-endpoint unix:///run/containerd/containerd.sock \
    exec "$("$CRICTL" --runtime-endpoint unix:///run/containerd/containerd.sock \
      ps --pod "$("$CRICTL" --runtime-endpoint unix:///run/containerd/containerd.sock \
        pods --namespace cube-s0-net --name cube-source -q | head -n1)" -q | head -n1)" \
    cat /etc/resolv.conf |
    jq -Rsc 'split("\n") | map(select(startswith("nameserver ") or startswith("search ") or startswith("options ")))')

  dns_content=$(jq -r ".[]" <<<"$dns_json" | base64 -w0)
  dns_custom_json="[{\"path\":\"/etc/resolv.conf\",\"content\":\"$dns_content\"}]"

  net_json=$(jq -cn \
    --arg tap "$TAP" --arg mac "$mac" --arg ip "$source_ip" \
    --arg gateway "$gateway" --arg gateway_mac "$gateway_mac" \
    --argjson prefix "$prefix" --argjson mtu "$mtu" \
    '{
      interfaces: [{
        name: $tap, guest_name: "eth0", mac: $mac, mtu: $mtu,
        ip: "", family: 0, mask: 0,
        ips: [{ip: $ip, family: 0, mask: $prefix}],
        qos: null
      }],
      routes: [
        {family: 0, dest: ($gateway + "/32"), gateway: "", source: $ip,
         device: "eth0", scope: 253, onlink: false},
        {family: 0, dest: "0.0.0.0/0", gateway: $gateway, source: $ip,
         device: "eth0", scope: 0, onlink: false}
      ],
      arps: [{
        dest_ip: $gateway, device: "eth0", ll_addr: $gateway_mac,
        state: 128, flags: 0
      }]
    }')

  run_expected_create_failure "$net_json"
  echo S0_3_PHASE_TCFILTER
  setup_tcfilter
  cleanup_cube_task
  wait_for_clean
  set +e
  output=$(ctr run --rm \
    --runtime "$RUNTIME" \
    --annotation io.containerd.cube.s0.standard-rootfs=true \
    --annotation "io.containerd.cube.s0.cni-netns=$source_netns" \
    --annotation 'cube.vmmres={"cpu":2,"memory":1024}' \
    --annotation "cube.vm.kernel.path=$KERNEL" \
    --annotation "cube.vm.agent.path=$AGENT" \
    --annotation "cube.vm.os-image.path=$GUEST_IMAGE" \
    --annotation cube.snapshot.disable=true \
    --annotation cube.use_passfd_io=true \
    --annotation "cube.net=$net_json" \
    --annotation "cube.container.custom.file=$dns_custom_json" \
    --annotation "cube.sandbox.dns=$dns_json" \
    "$IMAGE" "$TASK_ID" /bin/sh -c "
      echo CUBE_NETWORK_DIAGNOSTICS &&
      ip link show dev eth0 &&
      ip -4 -o addr show dev eth0 &&
      ip route show &&
      cat /etc/resolv.conf &&
      ip -4 -o addr show dev eth0 | grep -F '$source_ip/' >/dev/null &&
      echo POD_IP_EQUALS_CUBE_VM &&
      wget -T 5 -qO- http://$peer_ip:8080 | grep -q CUBE_PEER_OK &&
      echo CROSS_NODE_POD_TO_POD_PREFLIGHT_OK &&
      timeout 10 nslookup '$dns_name' >/dev/null &&
      echo CLUSTER_DNS_OK &&
      wget -T 5 -qO- 'http://$service_ip:8080' | grep -q CUBE_PEER_OK &&
      echo SERVICE_CLUSTER_IP_OK &&
      wget -T 5 -qO- 'http://$peer_ip:8080' | grep -q CUBE_PEER_OK &&
      echo CROSS_NODE_POD_TO_POD_OK &&
      if timeout 5 wget -T 2 -qO- 'http://$denied_ip:8080' >/dev/null 2>&1; then
        echo NETWORK_POLICY_UNEXPECTED_ALLOW
        exit 42
      fi &&
      echo NETWORK_POLICY_DENY_OK
    " 2>&1)
  local rc=$?
  set -e
  printf '%s\n' "$output"
  if [[ $rc -ne 0 ]]; then
    netns ip -s link show dev eth0
    netns ip -s link show dev "$TAP"
    netns tc -s filter show dev eth0 parent ffff:
    netns tc -s filter show dev "$TAP" parent ffff:
  fi
  [[ $rc -eq 0 ]]
  grep -q POD_IP_EQUALS_CUBE_VM <<<"$output"
  grep -q CLUSTER_DNS_OK <<<"$output"
  grep -q SERVICE_CLUSTER_IP_OK <<<"$output"
  grep -q CROSS_NODE_POD_TO_POD_OK <<<"$output"
  grep -q NETWORK_POLICY_DENY_OK <<<"$output"
}

wait_for_clean() {
  local task_id=${1:-$TASK_ID}
  local attempt
  for attempt in $(seq 1 100); do
    if [[ $(ctr tasks list -q | wc -l) -eq 0 ]] &&
      [[ $(ctr containers list -q | wc -l) -eq 0 ]] &&
      [[ $(namespace_shim_pids | wc -l) -eq 0 ]] &&
      [[ $(findmnt -rn -o TARGET | grep -c "/data/cubelet/s0.2-share/$task_id/" || true) -eq 0 ]] &&
      [[ ! -e "/data/cubelet/s0.2-share/$task_id" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

assert_clean() {
  local tasks containers shims taps source_filters tap_filters rootfs_mounts rootfs_dir
  tasks=$(ctr tasks list -q | wc -l)
  containers=$(ctr containers list -q | wc -l)
  shims=$(namespace_shim_pids | wc -l)
  taps=0
  source_filters=0
  tap_filters=0
  rootfs_mounts=$(findmnt -rn -o TARGET | grep -c "/data/cubelet/s0.2-share/$TASK_ID/" || true)
  rootfs_dir=0
  [[ -e "/data/cubelet/s0.2-share/$TASK_ID" ]] && rootfs_dir=1
  if [[ -n "$source_netns" && -e "$source_netns" ]]; then
    netns ip link show dev "$TAP" >/dev/null 2>&1 && taps=1
    source_filters=$(netns tc filter show dev eth0 parent ffff: 2>/dev/null |
      grep -c "pref $TC_PREF" || true)
    if [[ $taps -eq 1 ]]; then
      tap_filters=$(netns tc filter show dev "$TAP" parent ffff: 2>/dev/null |
        grep -c "pref $TC_PREF" || true)
    fi
  fi
  printf 'RESIDUE tasks=%s containers=%s shims=%s taps=%s source_filters=%s tap_filters=%s rootfs_mounts=%s rootfs_dir=%s\n' \
    "$tasks" "$containers" "$shims" "$taps" \
    "$source_filters" "$tap_filters" "$rootfs_mounts" "$rootfs_dir"
  [[ $tasks -eq 0 && $containers -eq 0 && $shims -eq 0 &&
    $taps -eq 0 && $source_filters -eq 0 && $tap_filters -eq 0 &&
    $rootfs_mounts -eq 0 && $rootfs_dir -eq 0 ]]
}

echo S0_3_PHASE_PREFLIGHT
preflight
echo S0_3_PHASE_CONTAINERD
start_isolated_containerd
echo S0_3_PHASE_CNI_ENDPOINTS
create_cni_endpoints
echo S0_3_PHASE_NETNS
discover_source_netns
echo S0_3_PHASE_CUBE
run_cube_network_case
cleanup_cube_task
cleanup_tc
wait_for_clean
assert_clean
kubectl delete namespace cube-s0-net --wait=true --timeout=180s
! kubectl get namespace cube-s0-net >/dev/null 2>&1
echo KUBERNETES_CNI_NAMESPACE_CLEAN
echo S0_3_CNI_PROBE_OK
