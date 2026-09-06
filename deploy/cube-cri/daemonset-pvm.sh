#!/usr/bin/env bash
# 在宿主机执行；75 表示已安排重启，交给 DaemonSet 在启动后继续。
set -euo pipefail
rpm_file=${1:?PVM RPM path}
state=/var/lib/cube-cri/pvm
source /etc/os-release
[[ $VERSION_ID == 4* && $(uname -m) == x86_64 ]] || { echo '需要 TS4 x86_64 节点' >&2; exit 1; }
mkdir -p "$state"
if [[ $(uname -r) == *cubesandbox.pvm.host* ]]; then
  modprobe kvm_pvm
  test -c /dev/kvm
  rm -f "$state/reboot-request"
  echo "PVM ready: $(uname -r)"
  exit 0
fi
test -s "$rpm_file" || { echo "缺少镜像内 PVM RPM: $rpm_file" >&2; exit 1; }
version=$(sha256sum "$rpm_file" | cut -d ' ' -f1)
boot=$(cat /proc/sys/kernel/random/boot_id)
reboot_node() {
  if ! systemctl is-active --quiet cube-cri-pvm-reboot.timer; then
    systemd-run --collect --unit=cube-cri-pvm-reboot --on-active=5s systemctl reboot
  fi
  echo "PVM reboot requested: boot=$boot"
  exit 75
}
if [[ -f $state/reboot-request ]]; then
  read -r previous_version previous_boot < "$state/reboot-request"
  if [[ $previous_version == "$version" ]]; then
    [[ $previous_boot == "$boot" ]] || { echo '重启后仍未进入 PVM 内核，停止自动重启；请检查 grub 默认内核及节点控制台。' >&2; exit 1; }
    reboot_node
  fi
fi
listing=$(rpm -qpl "$rpm_file")
mapfile -t kernels < <(printf '%s\n' "$listing" | grep '^/boot/vmlinuz-.*cubesandbox.pvm.host')
[[ ${#kernels[@]} == 1 ]] || { echo 'RPM 必须包含唯一的 PVM 宿主机内核' >&2; exit 1; }
kernel=${kernels[0]}
[[ -f $state/previous-default-kernel ]] || grubby --default-kernel > "$state/previous-default-kernel"
rpm -ivh --oldpackage --replacepkgs "$rpm_file"
test -f "$kernel"
grubby --set-default "$kernel"
[[ $(grubby --default-kernel) == "$kernel" ]]
printf 'kvm_pvm\n' > /etc/modules-load.d/cube-cri-pvm.conf
printf '%s %s\n' "$version" "$boot" > "$state/reboot-request.new"
mv -f "$state/reboot-request.new" "$state/reboot-request"
reboot_node
