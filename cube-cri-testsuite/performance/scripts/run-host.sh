#!/usr/bin/env bash
# 此脚本运行在特权 runc 工具 Pod 内；被测进程经 PID 1 的命名空间和 systemd service 进入原生 Host。
set -euo pipefail

host_root="${HOST_BENCH_ROOT:?缺少 HOST_BENCH_ROOT}"
test_name="${1:?缺少测试名称}"
mount_root="${host_root}/rootfs"

cleanup() {
  nsenter -t 1 -m -- umount -R "${mount_root}/dev" 2>/dev/null || true
  nsenter -t 1 -m -- umount "${mount_root}/proc" 2>/dev/null || true
}
trap cleanup EXIT

nsenter -t 1 -m -- mount -t proc proc "${mount_root}/proc"
nsenter -t 1 -m -- mount --rbind /dev "${mount_root}/dev"
nsenter -t 1 -m -- mount --make-rslave "${mount_root}/dev"
nsenter -t 1 -m -u -i -n -p -- systemd-run --quiet --pipe --wait --collect \
  -p CPUQuota=100% -p MemoryMax=2147483648 -p TasksMax=4096 \
  /usr/sbin/chroot "$mount_root" /usr/bin/env \
  ROUND="${ROUND:?缺少 ROUND}" WORK_DIR=/work FIO_SIZE="${FIO_SIZE:-512M}" \
  FIO_RUNTIME="${FIO_RUNTIME:-30}" IPERF_HOST="${IPERF_HOST:-}" IPERF_PORT="${IPERF_PORT:-5201}" \
  /opt/cube-cri-perf/run-case.sh "$test_name"
