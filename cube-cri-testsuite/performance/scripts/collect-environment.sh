#!/usr/bin/env bash
set -euo pipefail

jq -n \
  --arg uname "$(uname -a)" \
  --arg cpuinfo "$(lscpu 2>/dev/null || true)" \
  --arg meminfo "$(free -b 2>/dev/null || true)" \
  --arg mount "$(findmnt -J 2>/dev/null || true)" \
  --arg cgroup "$(cat /proc/self/cgroup)" \
  --arg cpuset "$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || true)" \
  --arg cpu_max "$(cat /sys/fs/cgroup/cpu.max 2>/dev/null || true)" \
  --arg memory_max "$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)" \
  --arg nproc "$(nproc)" \
  --arg packages "$(cat /opt/cube-cri-perf/packages.txt)" \
  --arg sources "$(cat /opt/cube-cri-perf/sources.txt)" \
  '{uname:$uname,cpuinfo:$cpuinfo,meminfo:$meminfo,mount:$mount,cgroup:$cgroup,cpuset:$cpuset,cpu_max:$cpu_max,memory_max:$memory_max,nproc:$nproc,packages:$packages,sources:$sources}'
