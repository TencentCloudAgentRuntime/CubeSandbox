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
for command in python3 crictl tc ip mount nsenter systemctl; do
  command -v "$command" >/dev/null || { echo "缺少宿主机依赖: $command" >&2; exit 1; }
done
ls /etc/cni/net.d/*conf* >/dev/null
base=/opt/cube-cri
containerd_config=/etc/containerd/config.toml
test -f "$containerd_config"
python3 containerd.py "$src/prepared" --config-path "$containerd_config"
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
  for file in bin/cubelet-cri bin/containerd-shim-cube-rs bin/cube-vmm-worker assets/kernel assets/agent assets/guest.img; do
    cp -a "$file" "$release/$file"
  done
  cp SHA256SUMS "$release/"
fi
ln -sfn "$release" "$base/current.new"
mv -Tf "$base/current.new" "$base/current"
cat > /etc/systemd/system/cube-cri-runtime-resource.service <<'UNIT'
[Unit]
Description=Cube CRI node RuntimeResource
After=local-fs.target
Before=containerd.service
[Service]
ExecStart=/opt/cube-cri/current/bin/cubelet-cri
Restart=always
RestartSec=1
Delegate=yes
[Install]
WantedBy=multi-user.target
UNIT
install -m 0644 "$src/prepared/containerd.toml" "$containerd_config"
install -m 0644 "$src/prepared/containerd.json" /etc/cube-cri/containerd.json
install -m 0644 "$src/prepared/containerd.service.conf" /etc/systemd/system/containerd.service.d/90-cube-cri.conf
bash install-watchdog.sh "$release/bin/containerd-shim-cube-rs" cubesandbox-shim-watchdog.service runtimeclass-overhead.json
systemctl daemon-reload
systemctl enable cube-cri-runtime-resource
systemctl restart cube-cri-runtime-resource
for ((i=0;i<30;i++)); do test ! -S /run/cube-cri/runtime-resource.sock || break; sleep 1; done
test -S /run/cube-cri/runtime-resource.sock
systemctl restart containerd
endpoint=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["address"])' /etc/cube-cri/containerd.json)
endpoint="unix://${endpoint#unix://}"
for ((i=0;i<30;i++)); do
  if crictl --runtime-endpoint "$endpoint" info > "$src/cri-info.json" 2>/dev/null && python3 - /etc/cube-cri/containerd.json "$src/cri-info.json" <<'PY'
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
  sleep 2
done
journalctl -u containerd -n 80 --no-pager
exit 1
