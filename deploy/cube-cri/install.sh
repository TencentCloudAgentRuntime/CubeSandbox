#!/usr/bin/env bash
# 由 DaemonSet 提交的宿主机 systemd 任务执行。
set -euo pipefail
trap 'echo "安装失败: line=$LINENO command=$BASH_COMMAND" >&2' ERR
src=${1:?package directory}
cd "$src"
sha256sum -c SHA256SUMS
[[ $(uname -m) == x86_64 ]]
modprobe kvm_pvm
test -c /dev/kvm
if ! command -v tc >/dev/null; then dnf install -y iproute-tc; fi
for command in python3 tc ip mount nsenter systemctl; do
  command -v "$command" >/dev/null || { echo "缺少宿主机依赖: $command" >&2; exit 1; }
done
ls /etc/cni/net.d/*conf* >/dev/null
base=/opt/cube-cri
containerd_config=/etc/containerd/config.toml
test -f "$containerd_config"
containerd_args=("$src/prepared" --config-path "$containerd_config")
if [[ -s $src/guest-kernel-cmdline-append.json ]]; then
  containerd_args+=(--guest-kernel-cmdline-append-file "$src/guest-kernel-cmdline-append.json")
fi
if [[ -f $src/guest-boot-trace.enabled ]]; then
  containerd_args+=(--guest-boot-trace)
fi
runtime_resource_env=
trace_forwarder_env=
trace_forwarder_enabled=0
trace_proxy_env=
trace_proxy_enabled=0
if [[ -f $src/otel.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$src/otel.env"
  set +a
  : "${CUBE_CRI_TRACING_OTLP_PROTOCOL:=http/protobuf}"
  : "${CUBE_CRI_TRACING_SERVICE_NAME_PREFIX:=cube-cri}"
  : "${CUBE_CRI_TRACING_SAMPLING_RATIO:=1.0}"
  if [[ -n ${CUBE_CRI_TRACING_OTLP_ENDPOINT:-} ]]; then
    containerd_args+=(--otel-endpoint "$CUBE_CRI_TRACING_OTLP_ENDPOINT" --otel-protocol "$CUBE_CRI_TRACING_OTLP_PROTOCOL" --otel-service-name "${CUBE_CRI_TRACING_SERVICE_NAME_PREFIX}-containerd" --otel-sampling-ratio "$CUBE_CRI_TRACING_SAMPLING_RATIO" --enable-agent-tracing)
    runtime_resource_env+=$'Environment=CUBE_CRI_TRACING_OTLP_ENDPOINT='"$CUBE_CRI_TRACING_OTLP_ENDPOINT"$'\n'
    runtime_resource_env+=$'Environment=CUBE_CRI_TRACING_OTLP_PROTOCOL='"$CUBE_CRI_TRACING_OTLP_PROTOCOL"$'\n'
    runtime_resource_env+=$'Environment=CUBE_CRI_TRACING_SERVICE_NAME='"${CUBE_CRI_TRACING_SERVICE_NAME_PREFIX}-runtime-resource"$'\n'
    runtime_resource_env+=$'Environment=CUBE_CRI_TRACING_SAMPLING_RATIO='"$CUBE_CRI_TRACING_SAMPLING_RATIO"$'\n'
    trace_forwarder_enabled=1
    trace_forwarder_env+=$'Environment=CUBE_CRI_TRACING_OTLP_ENDPOINT='"$CUBE_CRI_TRACING_OTLP_ENDPOINT"$'\n'
    trace_forwarder_env+=$'Environment=CUBE_CRI_TRACING_OTLP_PROTOCOL='"$CUBE_CRI_TRACING_OTLP_PROTOCOL"$'\n'
    trace_proxy_enabled=1
    trace_proxy_env+=$'Environment=CUBE_CRI_TRACING_OTLP_ENDPOINT='"$CUBE_CRI_TRACING_OTLP_ENDPOINT"$'\n'
    trace_proxy_env+=$'Environment=CUBE_CRI_TRACING_OTLP_PROTOCOL='"$CUBE_CRI_TRACING_OTLP_PROTOCOL"$'\n'
    trace_proxy_env+=$'Environment=CUBE_CRI_TRACING_SERVICE_NAME='"${CUBE_CRI_TRACING_SERVICE_NAME_PREFIX}-trace-proxy"$'\n'
    trace_proxy_env+=$'Environment=CUBE_CRI_TRACING_SAMPLING_RATIO='"$CUBE_CRI_TRACING_SAMPLING_RATIO"$'\n'
  fi
fi
python3 containerd.py "${containerd_args[@]}"
release=$base/releases/$(sha256sum SHA256SUMS | cut -c1-16)
backup=$base/backups/$(date -u +%Y%m%dT%H%M%S)-$$
mkdir -p "$release" "$backup" /etc/cube-cri /etc/systemd/system/containerd.service.d
cp -a "$containerd_config" "$backup/"
source_config=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_config"])' "$src/prepared/containerd.json")
cp -a "$source_config" "$backup/source-containerd.toml"
cp "$src/prepared/containerd.json" "$backup/"
cp -a /etc/systemd/system/containerd.service.d "$backup/"
systemctl cat containerd > "$backup/containerd.service.txt"
[[ ! -e $base/current ]] || readlink -f "$base/current" > "$backup/previous-release"
if [[ -f $release/SHA256SUMS ]]; then
  (cd "$release"; sha256sum -c SHA256SUMS)
else
  mkdir -p "$release/bin" "$release/assets"
  for file in bin/cubelet-cri bin/cube-cri-trace-proxy bin/containerd-shim-cube-rs bin/cube-vmm-worker bin/cube-template-builder bin/cube-trace-forwarder assets/kernel assets/agent assets/guest.img; do
    cp -a "$file" "$release/$file"
  done
  cp SHA256SUMS "$release/"
fi
ln -sfn "$release" "$base/current.new"
mv -Tf "$base/current.new" "$base/current"
cat > /etc/systemd/system/cube-cri-runtime-resource.service <<UNIT
[Unit]
Description=Cube CRI node RuntimeResource
After=local-fs.target
Before=containerd.service
[Service]
${runtime_resource_env}ExecStart=/opt/cube-cri/current/bin/cubelet-cri
Restart=always
RestartSec=1
Delegate=yes
[Install]
WantedBy=multi-user.target
UNIT
if [[ $trace_forwarder_enabled == 1 ]]; then
  cat > /etc/systemd/system/cube-cri-trace-forwarder.service <<UNIT
[Unit]
Description=Cube CRI guest trace forwarder
After=local-fs.target
Before=containerd.service
[Service]
${trace_forwarder_env}ExecStart=/opt/cube-cri/current/bin/cube-trace-forwarder
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
UNIT
else
  systemctl disable --now cube-cri-trace-forwarder >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/cube-cri-trace-forwarder.service
fi
if [[ $trace_proxy_enabled == 1 ]]; then
  frontend_address=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["address"])' "$src/prepared/containerd.json")
  backend_address=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["backend_address"])' "$src/prepared/containerd.json")
  cat > /etc/systemd/system/cube-cri-trace-proxy.service <<UNIT
[Unit]
Description=Cube CRI containerd trace proxy
After=local-fs.target
Before=containerd.service
[Service]
${trace_proxy_env}ExecStart=/opt/cube-cri/current/bin/cube-cri-trace-proxy --listen $frontend_address --backend $backend_address
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
UNIT
else
  systemctl disable --now cube-cri-trace-proxy >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/cube-cri-trace-proxy.service
fi
install -m 0644 "$src/prepared/containerd.toml" "$containerd_config"
install -m 0644 "$src/prepared/containerd.json" /etc/cube-cri/containerd.json
install -m 0644 "$src/prepared/containerd.service.conf" /etc/systemd/system/containerd.service.d/90-cube-cri.conf
bash install-watchdog.sh "$release/bin/containerd-shim-cube-rs" cubesandbox-shim-watchdog.service runtimeclass-overhead.json
systemctl daemon-reload
systemctl enable cube-cri-runtime-resource
if [[ $trace_forwarder_enabled == 1 ]]; then
  systemctl enable cube-cri-trace-forwarder
  systemctl restart cube-cri-trace-forwarder
fi
if [[ $trace_proxy_enabled == 1 ]]; then
  systemctl enable cube-cri-trace-proxy
fi
systemctl restart cube-cri-runtime-resource
for ((i=0;i<30;i++)); do test ! -S /run/cube-cri/runtime-resource.sock || break; sleep 1; done
test -S /run/cube-cri/runtime-resource.sock
if [[ $trace_proxy_enabled == 1 ]]; then
  systemctl stop containerd || true
  systemctl restart cube-cri-trace-proxy
fi
systemctl restart containerd
endpoint=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["address"])' /etc/cube-cri/containerd.json)
endpoint="unix://${endpoint#unix://}"
for ((i=0;i<30;i++)); do
  if command -v crictl >/dev/null && crictl --runtime-endpoint "$endpoint" info > "$src/cri-info.json" 2>/dev/null && python3 - /etc/cube-cri/containerd.json "$src/cri-info.json" <<'PY'
import json,sys
metadata=json.load(open(sys.argv[1])); info=json.load(open(sys.argv[2]))
conditions={c['type']:c['status'] for c in info['status']['conditions']}
assert conditions.get('RuntimeReady') and conditions.get('NetworkReady')
handler=info['config']['containerd']['runtimes']['cube']
assert handler['runtimeType']=='io.containerd.cube.rs'
assert handler['sandboxMode' if metadata['family']=='1.7' else 'sandboxer']=='shim'
PY
  then
    active_units=(cube-cri-runtime-resource cubesandbox-shim-watchdog containerd)
    if [[ $trace_forwarder_enabled == 1 ]]; then active_units+=(cube-cri-trace-forwarder); fi
    if [[ $trace_proxy_enabled == 1 ]]; then active_units+=(cube-cri-trace-proxy); fi
    systemctl is-active "${active_units[@]}"
    echo "Cube CRI installed: $release; backup: $backup"
    exit 0
  fi
  active_units=(cube-cri-runtime-resource cubesandbox-shim-watchdog containerd)
  if [[ $trace_forwarder_enabled == 1 ]]; then active_units+=(cube-cri-trace-forwarder); fi
  if [[ $trace_proxy_enabled == 1 ]]; then active_units+=(cube-cri-trace-proxy); fi
  if ! command -v crictl >/dev/null && systemctl is-active --quiet "${active_units[@]}" && test -S "${endpoint#unix://}"; then
    echo "宿主机未安装 crictl，跳过本地 CRI info 校验；后续由 Kubernetes smoke 验证。"
    echo "Cube CRI installed: $release; backup: $backup"
    exit 0
  fi
  sleep 2
done
journalctl -u containerd -n 80 --no-pager
exit 1
