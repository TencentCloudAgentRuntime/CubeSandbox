#!/usr/bin/env bash
# 由宿主机 systemd 执行，安装不受 containerd / Pod 重启影响。
set -euo pipefail
src=${1:?staging directory}
version=${2:?package checksum}
state=/var/lib/cube-cri/installer
exec 9>"$state/install.lock"
flock 9
bash "$src/daemonset-pvm.sh" "$src/pvm-host.rpm"
[[ ${3:-runtime} != prepare ]] || exit 0
[[ ! -f $state/installed || $(cat "$state/installed") != "$version" ]] || exit 0
tar -xzf "$src/runtime.tar.gz" -C "$src"
bash "$src/install.sh" "$src"
printf '%s\n' "$version" > "$state/installed.new"
mv -f "$state/installed.new" "$state/installed"
