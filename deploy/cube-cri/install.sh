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
tracing_enabled=0
if [[ -f $src/tracing.enabled ]]; then tracing_enabled=1; fi
python3 - "$tracing_enabled" "$src/guest-kernel-cmdline-append.json" <<'PY'
import json
import pathlib
import sys

enabled = sys.argv[1] == "1"
path = pathlib.Path(sys.argv[2])
params = json.loads(path.read_text() if path.exists() else "[]")
if not isinstance(params, list) or not all(isinstance(param, str) for param in params):
    raise ValueError("guest kernel parameters must be a string array")
trace_params = [param for param in params if param.startswith("agent.trace")]
if trace_params != (["agent.trace=1"] if enabled else []):
    raise ValueError("agent.trace kernel parameter must match tracing.enabled")
if enabled:
    env = pathlib.Path("/etc/cube-cri/tracing.env")
    if not env.is_file():
        raise ValueError("tracing.enabled requires /etc/cube-cri/tracing.env")
    values = dict(line.split("=", 1) for line in env.read_text().splitlines() if "=" in line and not line.lstrip().startswith("#"))
    for key in ("OTEL_EXPORTER_OTLP_ENDPOINT", "CUBE_CRI_TRACING_OTLP_ENDPOINT"):
        if not values.get(key, "").strip().strip("\"'"):
            raise ValueError(f"tracing.env requires {key}")
    if values.get("CUBE_CRI_TRACING_OTLP_PROTOCOL", "http/protobuf").strip().strip("\"'") != "http/protobuf":
        raise ValueError("Cube Agent trace forwarder requires http/protobuf")
PY
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
if [[ $tracing_enabled == 1 ]]; then
  containerd_args+=(--tracing-enabled)
fi
python3 containerd.py "${containerd_args[@]}"
release=$base/releases/$(sha256sum SHA256SUMS | cut -c1-16)-trace-$tracing_enabled
backup=$base/backups/$(date -u +%Y%m%dT%H%M%S)-$$
mkdir -p "$release" "$backup" /etc/cube-cri /etc/systemd/system/containerd.service.d
python3 - "$src/guest-kernel-cmdline-append.json" <<'PY' > /etc/cube-cri/guest.env
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
params = json.loads(path.read_text() if path.exists() else "[]")
if not isinstance(params, list) or not all(isinstance(param, str) for param in params):
    raise ValueError("guest kernel parameters must be a string array")
print("CUBE_GUEST_KERNEL_CMDLINE_APPEND=" + json.dumps(json.dumps(params)))
PY
cp -a "$containerd_config" "$backup/"
source_config=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_config"])' "$src/prepared/containerd.json")
cp -a "$source_config" "$backup/source-containerd.toml"
cp "$src/prepared/containerd.json" "$backup/"
cp -a /etc/systemd/system/containerd.service.d "$backup/"
if [[ -f /etc/cube-hypervisor/vsock_conf.json ]]; then
  cp -a /etc/cube-hypervisor/vsock_conf.json "$backup/"
fi
if [[ -f /etc/systemd/system/cube-cri-trace-proxy.service ]]; then
  cp -a /etc/systemd/system/cube-cri-trace-proxy.service "$backup/"
fi
systemctl cat containerd > "$backup/containerd.service.txt"
[[ ! -e $base/current ]] || readlink -f "$base/current" > "$backup/previous-release"
if [[ -f $release/SHA256SUMS ]]; then
  (cd "$release"; sha256sum -c SHA256SUMS)
else
  mkdir -p "$release/bin" "$release/assets"
  files=(bin/cubelet-cri bin/containerd-shim-cube-rs bin/cube-vmm-worker bin/cube-template-builder assets/kernel assets/agent assets/guest.img)
  if [[ $tracing_enabled == 1 ]]; then
    files+=(bin/cube-trace-forwarder bin/agent-trace-bridge.py cube-cri-agent-trace-bridge.service cube-cri-trace-forwarder.service)
  fi
  for file in "${files[@]}"; do
    cp -a "$file" "$release/$file"
  done
  sha256sum "${files[@]}" > "$release/SHA256SUMS"
fi
python3 - "$tracing_enabled" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path("/etc/cube-hypervisor/vsock_conf.json")
entries = json.loads(path.read_text()) if path.exists() else []
if not isinstance(entries, list):
    raise ValueError("vsock_conf.json must be a list")
bridge = {"file": "/run/cube-cri/agent-trace.sock", "port": 10240}
if sys.argv[1] == "1":
    for entry in entries:
        if entry.get("port") == bridge["port"]:
            if entry != bridge:
                raise ValueError("vsock port 10240 is already configured")
            break
    else:
        entries.append(bridge)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(entries) + "\n")
else:
    remaining = [entry for entry in entries if entry != bridge]
    if len(remaining) != len(entries):
        if remaining:
            path.write_text(json.dumps(remaining) + "\n")
        else:
            path.unlink()
PY
if [[ $tracing_enabled == 0 ]]; then
  systemctl disable --now cube-cri-agent-trace-bridge cube-cri-trace-forwarder 2>/dev/null || true
  for service in cube-cri-agent-trace-bridge cube-cri-trace-forwarder; do
    if systemctl is-active --quiet "$service" || systemctl is-enabled --quiet "$service"; then
      echo "未能停用 tracing 服务: $service" >&2
      exit 1
    fi
  done
  rm -f /etc/systemd/system/cube-cri-agent-trace-bridge.service /etc/systemd/system/cube-cri-trace-forwarder.service /run/cube-cri/agent-trace.sock
fi
ln -sfn "$release" "$base/current.new"
mv -Tf "$base/current.new" "$base/current"
if [[ $tracing_enabled == 1 ]]; then
  install -m 0644 "$release/cube-cri-agent-trace-bridge.service" /etc/systemd/system/
  install -m 0644 "$release/cube-cri-trace-forwarder.service" /etc/systemd/system/
fi
cat > /etc/systemd/system/cube-cri-runtime-resource.service <<'UNIT'
[Unit]
Description=Cube CRI node RuntimeResource
After=local-fs.target
Before=containerd.service
[Service]
EnvironmentFile=-/etc/cube-cri/guest.env
ExecStart=/opt/cube-cri/current/bin/cubelet-cri
Restart=always
RestartSec=1
Delegate=yes
[Install]
WantedBy=multi-user.target
UNIT
if [[ $tracing_enabled == 1 ]]; then
  sed -i '/EnvironmentFile=-\/etc\/cube-cri\/guest.env/a EnvironmentFile=-/etc/cube-cri/tracing.env' /etc/systemd/system/cube-cri-runtime-resource.service
fi
install -m 0644 "$src/prepared/containerd.toml" "$containerd_config"
install -m 0644 "$src/prepared/containerd.json" /etc/cube-cri/containerd.json
install -m 0644 "$src/prepared/containerd.service.conf" /etc/systemd/system/containerd.service.d/90-cube-cri.conf
bash install-watchdog.sh "$release/bin/containerd-shim-cube-rs" cubesandbox-shim-watchdog.service runtimeclass-overhead.json
systemctl daemon-reload
if [[ $tracing_enabled == 1 ]]; then
  systemctl enable cube-cri-trace-forwarder cube-cri-agent-trace-bridge
  systemctl restart cube-cri-trace-forwarder cube-cri-agent-trace-bridge
  systemctl is-active --quiet cube-cri-trace-forwarder cube-cri-agent-trace-bridge
  for ((i=0;i<10;i++)); do test -S /run/cube-cri/agent-trace.sock && break; sleep 1; done
  test -S /run/cube-cri/agent-trace.sock
  python3 - <<'PY'
import socket
import time

for attempt in range(10):
    try:
        with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as connection:
            connection.settimeout(3)
            connection.connect((socket.VMADDR_CID_HOST, 10240))
        break
    except OSError:
        if attempt == 9:
            raise
        time.sleep(1)
PY
fi
systemctl enable cube-cri-runtime-resource
systemctl restart cube-cri-runtime-resource
for ((i=0;i<30;i++)); do test ! -S /run/cube-cri/runtime-resource.sock || break; sleep 1; done
test -S /run/cube-cri/runtime-resource.sock
# The old trace proxy occupied kubelet's CRI socket. The rendered config now
# binds containerd directly there, so retire the proxy before restarting it.
if systemctl list-unit-files cube-cri-trace-proxy.service --no-legend | grep -q '^cube-cri-trace-proxy.service'; then
  systemctl disable --now cube-cri-trace-proxy.service
  rm -f /etc/systemd/system/cube-cri-trace-proxy.service /run/containerd/containerd.sock
  systemctl daemon-reload
fi
rm -rf /run/cube-cri/trace-context
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
    systemctl is-active cube-cri-runtime-resource cubesandbox-shim-watchdog containerd
    echo "Cube CRI installed: $release; backup: $backup"
    exit 0
  fi
  if ! command -v crictl >/dev/null && systemctl is-active --quiet cube-cri-runtime-resource cubesandbox-shim-watchdog containerd && test -S "${endpoint#unix://}"; then
    echo "宿主机未安装 crictl，跳过本地 CRI info 校验；后续由 Kubernetes smoke 验证。"
    echo "Cube CRI installed: $release; backup: $backup"
    exit 0
  fi
  sleep 2
done
journalctl -u containerd -n 80 --no-pager
exit 1
