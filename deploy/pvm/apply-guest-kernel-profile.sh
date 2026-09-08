#!/usr/bin/env bash
# Apply the Guest kernel build profile to an already configured kernel source.
set -euo pipefail

source_dir=${1:?用法: $0 <kernel-source>}
profile=${CUBE_GUEST_KERNEL_PROFILE:-release}
[[ -x ${source_dir}/scripts/config ]] || { echo "未找到 kernel scripts/config: ${source_dir}/scripts/config" >&2; exit 2; }

case ${profile} in
  release)
    # 保留运行时和容器所需特性；移除每个 Sandbox 启动时都会初始化的调试追踪。
    ;;
  debug)
    # 显式恢复诊断所需的调试与追踪能力。
    ;;
  *)
    echo "不支持的 CUBE_GUEST_KERNEL_PROFILE=${profile}，仅支持 release 或 debug" >&2
    exit 2
    ;;
esac

(
  cd "${source_dir}"
  if [[ ${profile} == release ]]; then
      ./scripts/config --disable DEBUG_KERNEL \
      --disable DEBUG_MISC \
      --disable DEBUG_BUGVERBOSE \
      --disable DEBUG_SECTION_MISMATCH \
      --disable DEBUG_FS \
      --disable SLUB_DEBUG \
      --disable SCHED_DEBUG \
      --disable SCHED_INFO \
      --disable SCHEDSTATS \
      --disable LATENCYTOP \
      --disable FTRACE \
      --disable KALLSYMS_ALL
  else
      ./scripts/config --enable DEBUG_MISC \
      --enable DEBUG_BUGVERBOSE \
      --enable DEBUG_SECTION_MISMATCH \
      --enable DEBUG_FS \
      --enable DEBUG_FS_ALLOW_ALL \
      --enable SLUB_DEBUG \
      --enable SCHED_DEBUG \
      --enable SCHED_INFO \
      --enable SCHEDSTATS \
      --enable LATENCYTOP \
      --enable FTRACE \
      --enable FUNCTION_TRACER \
      --enable FUNCTION_GRAPH_TRACER \
      --enable FUNCTION_PROFILER \
      --enable STACK_TRACER \
      --enable SCHED_TRACER \
      --enable FTRACE_SYSCALLS \
      --enable TRACER_SNAPSHOT \
      --enable BLK_DEV_IO_TRACE \
      --enable KPROBE_EVENTS \
      --enable UPROBE_EVENTS \
      --enable BPF_EVENTS \
      --enable DYNAMIC_EVENTS \
      --enable PROBE_EVENTS \
      --enable KALLSYMS_ALL
  fi
  make olddefconfig
)

if [[ ${profile} == release ]]; then
  # SCHED_INFO is selected by KVM and must remain enabled for PVM guests.
  for option in DEBUG_MISC SCHED_DEBUG SCHEDSTATS LATENCYTOP FTRACE KALLSYMS_ALL; do
    state=$(cd "${source_dir}" && ./scripts/config --state "${option}")
    [[ ${state} != y && ${state} != m ]] || {
      echo "release profile 未关闭 CONFIG_${option}" >&2
      exit 1
    }
  done
fi

echo "Guest kernel profile: ${profile}"
