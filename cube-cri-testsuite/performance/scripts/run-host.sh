#!/usr/bin/env bash
# 此脚本运行在特权 runc 工具 Pod 内；被测进程经 PID 1 的命名空间和 systemd service 进入原生 Host。
set -euo pipefail

host_root="${HOST_BENCH_ROOT:?缺少 HOST_BENCH_ROOT}"
test_name="${1:?缺少测试名称}"
mount_root="${host_root}/rootfs"
cpu_limit="${CPU_LIMIT:?缺少 CPU_LIMIT}"
memory_limit_bytes="${MEMORY_LIMIT_BYTES:?缺少 MEMORY_LIMIT_BYTES}"
[[ "$cpu_limit" =~ ^[1-9][0-9]*$ ]] || { echo 'CPU_LIMIT 必须是正整数' >&2; exit 2; }
[[ "$memory_limit_bytes" =~ ^[1-9][0-9]*$ ]] || { echo 'MEMORY_LIMIT_BYTES 必须是正整数' >&2; exit 2; }

cleanup() {
  nsenter -t 1 -m -- umount -R "${mount_root}/dev" 2>/dev/null || true
  nsenter -t 1 -m -- umount "${mount_root}/proc" 2>/dev/null || true
}
trap cleanup EXIT

nsenter -t 1 -m -- mount -t proc proc "${mount_root}/proc"
nsenter -t 1 -m -- mount --rbind /dev "${mount_root}/dev"
nsenter -t 1 -m -- mount --make-rslave "${mount_root}/dev"
nsenter -t 1 -m -u -i -n -p -- systemd-run --quiet --pipe --wait --collect \
  -p CPUQuota=$((cpu_limit * 100))% -p MemoryMax="$memory_limit_bytes" -p TasksMax=4096 \
  /usr/sbin/chroot "$mount_root" /usr/bin/env \
  ROUND="${ROUND:?缺少 ROUND}" WORK_DIR=/work FIO_SIZE="${FIO_SIZE:-512M}" \
  FIO_RUNTIME="${FIO_RUNTIME:-30}" IPERF_RUNTIME="${IPERF_RUNTIME:-30}" SYSBENCH_RUNTIME="${SYSBENCH_RUNTIME:-10}" HACKBENCH_LOOPS="${HACKBENCH_LOOPS:-1000}" HACKBENCH_GROUPS="${HACKBENCH_GROUPS:-10}" LMBENCH_MEMORY_SIZE="${LMBENCH_MEMORY_SIZE:-128M}" LMBENCH_FILE_SIZE_MIB="${LMBENCH_FILE_SIZE_MIB:-64}" LMBENCH_SAMPLES="${LMBENCH_SAMPLES:-3}" LMBENCH_ITERATIONS="${LMBENCH_ITERATIONS:-1000000}" STREAM_PROFILE="${STREAM_PROFILE:-full}" IPERF_HOST="${IPERF_HOST:-}" IPERF_PORT="${IPERF_PORT:-5201}" \
  /opt/cube-cri-perf/run-case.sh "$test_name"
