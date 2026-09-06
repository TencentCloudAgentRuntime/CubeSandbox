#!/usr/bin/env bash
# 使用隔离容器验证重启状态机，不修改本机内核。
set -euo pipefail
cd "$(dirname "$0")/../.."
docker run --rm -i -v "$PWD/deploy/cube-cri/daemonset-pvm.sh:/pvm.sh:ro" \
  "${BUILDER_IMAGE:-cube-sandbox-builder:ubuntu2004}" bash -s <<'TEST'
set -euo pipefail
mkdir -p /mock /fixture /boot
printf 'VERSION_ID=4.4\n' > /etc/os-release
printf 'native-kernel\n' > /fixture/kernel
printf 'boot-one\n' > /fixture/boot
printf '/boot/vmlinuz-native\n' > /fixture/default
printf 'test-rpm\n' > /fixture/kernel.rpm
ln -s /dev/null /dev/kvm
cat > /mock/tool <<'SH'
#!/bin/bash
set -eu
case "${0##*/}" in
  uname)
    if [[ $1 == -m ]]; then echo x86_64; else /bin/cat /fixture/kernel; fi ;;
  cat)
    if [[ $1 == /proc/sys/kernel/random/boot_id ]]; then /bin/cat /fixture/boot; else /bin/cat "$@"; fi ;;
  modprobe) test ! -f /fixture/module-fails ;;
  rpm)
    if [[ $1 == -qpl ]]; then
      echo /boot/vmlinuz-test.cubesandbox.pvm.host
    else
      echo install >> /fixture/actions
      touch /boot/vmlinuz-test.cubesandbox.pvm.host
    fi ;;
  grubby)
    if [[ $1 == --default-kernel ]]; then /bin/cat /fixture/default; else echo "$2" > /fixture/default; fi ;;
  systemctl) test -f /fixture/timer ;;
  systemd-run) echo reboot >> /fixture/actions; touch /fixture/timer ;;
esac
SH
chmod +x /mock/tool
for command in uname cat modprobe rpm grubby systemctl systemd-run; do ln -s tool "/mock/$command"; done
export PATH=/mock:$PATH
run() {
  local expected=$1 rc=0
  bash /pvm.sh /fixture/kernel.rpm > /fixture/result 2>&1 || rc=$?
  if [[ $rc != "$expected" ]]; then cat /fixture/result; echo "expected=$expected actual=$rc"; exit 1; fi
}
run 75
test "$(cat /fixture/actions)" = $'install\nreboot'
test "$(cat /var/lib/cube-cri/pvm/previous-default-kernel)" = /boot/vmlinuz-native
run 75
test "$(cat /fixture/actions)" = $'install\nreboot'
echo 'PASS: install schedules one reboot; same-boot retry preserves backup and does not reinstall'
echo boot-two > /fixture/boot
rm /fixture/timer
run 1
grep -q '停止自动重启' /fixture/result
test "$(cat /fixture/actions)" = $'install\nreboot'
echo 'PASS: failed kernel switch does not reboot again'
echo test.cubesandbox.pvm.host > /fixture/kernel
touch /fixture/module-fails
run 1
test -f /var/lib/cube-cri/pvm/reboot-request
echo 'PASS: module failure does not mark PVM ready'
rm /fixture/module-fails
run 0
test ! -f /var/lib/cube-cri/pvm/reboot-request
test "$(cat /fixture/actions)" = $'install\nreboot'
rm /fixture/kernel.rpm
run 0
echo 'PASS: healthy PVM skips RPM and clears reboot state'
echo native-kernel > /fixture/kernel
run 1
grep -q '缺少镜像内 PVM RPM' /fixture/result
test "$(cat /fixture/actions)" = $'install\nreboot'
echo 'PASS: missing RPM fails before host changes'
TEST
