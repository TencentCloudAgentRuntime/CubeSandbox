#!/bin/sh
set -eu
host() { nsenter -t 1 -m -u -i -n -p -- "$@"; }
state=/var/lib/cube-cri/installer
base_version=$(cat /installer/version)
guest_kernel_cmdline_append=${CUBE_GUEST_KERNEL_CMDLINE_APPEND:-[]}
guest_boot_trace=${CUBE_GUEST_BOOT_TRACE:-0}
tracing_endpoint=${CUBE_CRI_TRACING_OTLP_ENDPOINT:-}
tracing_protocol=${CUBE_CRI_TRACING_OTLP_PROTOCOL:-http/protobuf}
tracing_service_prefix=${CUBE_CRI_TRACING_SERVICE_NAME_PREFIX:-cube-cri}
tracing_sampling_ratio=${CUBE_CRI_TRACING_SAMPLING_RATIO:-1.0}
version=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$base_version" "$guest_kernel_cmdline_append" "$guest_boot_trace" "$tracing_endpoint" "$tracing_protocol" "$tracing_service_prefix" "$tracing_sampling_ratio" | sha256sum | cut -d ' ' -f1)
mode=${CUBE_CRI_MODE:-runtime}
node_name=${NODE_NAME:?NODE_NAME is required}
api_server="https://${KUBERNETES_SERVICE_HOST:?KUBERNETES_SERVICE_HOST is required}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}"
token_file=/var/run/secrets/kubernetes.io/serviceaccount/token
ca_file=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
set_ready_label() {
  value=${1:?label value}
  test -r "$token_file" && test -r "$ca_file"
  curl --fail --silent --show-error --connect-timeout 5 --max-time 15 --cacert "$ca_file" \
    -H "Authorization: Bearer $(cat "$token_file")" \
    -H 'Content-Type: application/merge-patch+json' \
    -X PATCH "$api_server/api/v1/nodes/$node_name" \
    --data "{\"metadata\":{\"labels\":{\"agc.cloud.tencent.com/cube-ready\":$value}}}" >/dev/null
}
pvm_ready() {
  # 外部预装的 PVM 宿主内核不保证沿用 CubeSandbox 的版本命名；以已加载
  # kvm_pvm 和可用 KVM 设备为准，避免把它误判为未安装后覆盖宿主机内核。
  host bash -c 'test -d /sys/module/kvm_pvm && test -c /dev/kvm'
}
running() {
  case "$(host systemctl show "$unit" --property=ActiveState --value)" in active|activating|reloading) return 0;; *) return 1;; esac
}
ready() {
  pvm_ready || return 1
  host test ! -f /var/lib/cube-cri/pvm/reboot-request || return 1
  [ "$mode" != prepare ] || return 0
  test "$(cat /host-state/installed 2>/dev/null)" = "$version" || return 1
  for service in cube-cri-runtime-resource cubesandbox-shim-watchdog containerd; do
    host systemctl is-active --quiet "$service" || return 1
  done
  host test -S /run/cube-cri/runtime-resource.sock
}
case "${1:-}" in
  check) ready; exit ;;
esac
set_ready_label null
src=$state/$POD_UID
unit=cube-cri-install-$POD_UID
if ! pvm_ready || host test -f /var/lib/cube-cri/pvm/reboot-request || { [ "$mode" != prepare ] && [ "$(cat /host-state/installed 2>/dev/null || true)" != "$version" ]; }; then
  if ! running; then
    mkdir -p "/host-state/$POD_UID"
    cp /installer/runtime.tar.gz /installer/daemonset-install.sh /installer/daemonset-pvm.sh "/host-state/$POD_UID/"
    printf '%s' "$guest_kernel_cmdline_append" > "/host-state/$POD_UID/guest-kernel-cmdline-append.json"
    if [ "$guest_boot_trace" = 1 ]; then touch "/host-state/$POD_UID/guest-boot-trace.enabled"; fi
    if [ -n "$tracing_endpoint" ]; then
      {
        printf 'CUBE_CRI_TRACING_OTLP_ENDPOINT=%s\n' "$tracing_endpoint"
        printf 'CUBE_CRI_TRACING_OTLP_PROTOCOL=%s\n' "$tracing_protocol"
        printf 'CUBE_CRI_TRACING_SERVICE_NAME_PREFIX=%s\n' "$tracing_service_prefix"
        printf 'CUBE_CRI_TRACING_SAMPLING_RATIO=%s\n' "$tracing_sampling_ratio"
      } > "/host-state/$POD_UID/otel.env"
    fi
    if ! pvm_ready && [ ! -s "/host-state/$POD_UID/pvm-host.rpm" ]; then cp /installer/pvm-host.rpm "/host-state/$POD_UID/"; fi
    host systemd-run --collect --unit "$unit" --property=Type=oneshot --property=TimeoutStartSec=20min \
      /bin/bash -c 'bash "$1/daemonset-install.sh" "$1" "$2" "$3" > "$1/install.log" 2>&1; rc=$?; printf "%s\n" "$rc" > "$1/install.exit"; exit "$rc"' bash "$src" "$version" "$mode"
  fi
  while running; do sleep 2; done
  cat "/host-state/$POD_UID/install.log"
  result=$(cat "/host-state/$POD_UID/install.exit")
  if [ "$result" = 75 ]; then
    echo 'PVM 内核已安装，等待节点重启；恢复后继续安装。'
    exec sleep infinity
  fi
  test "$result" = 0
  ready
fi
if ! running; then rm -rf "/host-state/$POD_UID"; fi
if [ "$mode" = runtime ]; then set_ready_label '"true"'; fi
echo "Cube CRI DaemonSet installed: $version"
exec sleep infinity
