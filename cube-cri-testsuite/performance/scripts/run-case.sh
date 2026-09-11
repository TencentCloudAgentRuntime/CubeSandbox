#!/usr/bin/env bash
set -euo pipefail

test_name="${1:?缺少测试名称}"
round="${ROUND:?缺少 ROUND}"
work_dir="${WORK_DIR:-/work}"
iperf_host="${IPERF_HOST:-}"
iperf_port="${IPERF_PORT:-5201}"
iperf_runtime="${IPERF_RUNTIME:-30}"
[[ "$iperf_runtime" =~ ^[1-9][0-9]*$ ]] || { echo 'IPERF_RUNTIME 必须是正整数' >&2; exit 2; }
sysbench_runtime="${SYSBENCH_RUNTIME:-10}"
hackbench_loops="${HACKBENCH_LOOPS:-1000}"
hackbench_groups="${HACKBENCH_GROUPS:-10}"
lmbench_memory_size="${LMBENCH_MEMORY_SIZE:-128M}"
lmbench_file_size_mib="${LMBENCH_FILE_SIZE_MIB:-64}"
lmbench_samples="${LMBENCH_SAMPLES:-3}"
lmbench_iterations="${LMBENCH_ITERATIONS:-1000000}"
stream_profile="${STREAM_PROFILE:-full}"
[[ "$sysbench_runtime" =~ ^[1-9][0-9]*$ && "$hackbench_loops" =~ ^[1-9][0-9]*$ && "$hackbench_groups" =~ ^[1-9][0-9]*$ ]] || { echo '微基准负载必须是正整数' >&2; exit 2; }
[[ "$lmbench_memory_size" =~ ^[1-9][0-9]*M$ && "$lmbench_file_size_mib" =~ ^[1-9][0-9]*$ && "$lmbench_samples" =~ ^[1-9][0-9]*$ && "$lmbench_iterations" =~ ^[1-9][0-9]*$ ]] || { echo 'LMbench 负载参数无效' >&2; exit 2; }
[[ "$stream_profile" == full || "$stream_profile" == fast ]] || { echo 'STREAM_PROFILE 仅支持 full 或 fast' >&2; exit 2; }
lmbench_memory_bytes=$(( ${lmbench_memory_size%M} * 1024 * 1024 ))

emit() {
  local value="$1" unit="$2" detail="$3"
  jq -cn --arg test "$test_name" --argjson round "$round" --argjson value "$value" \
    --arg unit "$unit" --argjson detail "$detail" \
    '{test:$test,round:$round,value:$value,unit:$unit}+ $detail'
}

last_number() {
  awk '{for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) value=$i} END {if (value == "") exit 1; print value}'
}

mkdir -p "$work_dir"
case "$test_name" in
  sysbench-cpu)
    output="$(sysbench cpu --threads=1 --time="$sysbench_runtime" --cpu-max-prime=20000 run)"
    value="$(awk '/events per second:/ {print $4}' <<<"$output")"
    emit "$value" "events/s" '{"tool":"sysbench","metric":"cpu_events_per_second","higher_is_better":true}'
    ;;
  stream-triad)
    stream_bin="/opt/stream"
    [[ "$stream_profile" == fast ]] && stream_bin="/opt/stream-fast"
    output="$("$stream_bin")"
    value="$(awk '$1 == "Triad:" {print $2}' <<<"$output")"
    emit "$value" "MB/s" '{"tool":"STREAM","metric":"Triad","higher_is_better":true}'
    ;;
  lmbench-lat-mem-rd)
    output="$(/opt/lmbench/bin/*/lat_mem_rd -N "$lmbench_samples" -W 0 -s "$lmbench_memory_bytes" -e "$lmbench_memory_bytes" -c "$lmbench_iterations" "$lmbench_memory_size" 64 2>&1)"
    value="$(awk 'NF >= 2 && $1 ~ /^[0-9]+(\.[0-9]+)?$/ {last=$NF} END {if (last == "") exit 1; print last}' <<<"$output")"
    emit "$value" "ns" "{\"tool\":\"LMbench\",\"metric\":\"lat_mem_rd_${lmbench_memory_size}_stride64\",\"higher_is_better\":false}"
    ;;
  lmbench-bw-mem)
    output="$(/opt/lmbench/bin/*/bw_mem "$lmbench_memory_size" rd 2>&1)"
    value="$(awk 'NF >= 2 {print $NF; exit}' <<<"$output")"
    emit "$value" "MB/s" '{"tool":"LMbench","metric":"bw_mem_128M_read","higher_is_better":true}'
    ;;
  lmbench-pagefault)
    file="$work_dir/pagefault.bin"
    dd if=/dev/zero of="$file" bs=1M count="$lmbench_file_size_mib" conv=fsync status=none
    output="$(/opt/lmbench/bin/*/lat_pagefault -N 1 -W 0 "$file" 2>&1)"
    value="$(last_number <<<"$output")"
    rm -f "$file"
    emit "$value" "us" '{"tool":"LMbench","metric":"page_fault_latency","higher_is_better":false}'
    ;;
  lmbench-mmap)
    file="$work_dir/mmap.bin"
    dd if=/dev/zero of="$file" bs=1M count="$lmbench_file_size_mib" conv=fsync status=none
    output="$(/opt/lmbench/bin/*/lat_mmap -N 1 -W 0 "${lmbench_file_size_mib}M" "$file" 2>&1)"
    value="$(last_number <<<"$output")"
    rm -f "$file"
    emit "$value" "us" '{"tool":"LMbench","metric":"mmap_64MiB_total_time","higher_is_better":false}'
    ;;
  lmbench-fork|lmbench-exec)
    mode="${test_name#lmbench-}"
    output="$(/opt/lmbench/bin/*/lat_proc -N 1 -W 0 "$mode" 2>&1)"
    value="$(last_number <<<"$output")"
    emit "$value" "us" "{\"tool\":\"LMbench\",\"metric\":\"lat_proc_${mode}\",\"higher_is_better\":false}"
    ;;
  lmbench-ctx)
    output="$(/opt/lmbench/bin/*/lat_ctx -N 1 -W 0 -s 8 2 2>&1)"
    value="$(last_number <<<"$output")"
    emit "$value" "us" '{"tool":"LMbench","metric":"context_switch_2proc_8KiB","higher_is_better":false}'
    ;;
  lmbench-syscall)
    output="$(/opt/lmbench/bin/*/lat_syscall -N 1 -W 0 null 2>&1)"
    value="$(last_number <<<"$output")"
    emit "$value" "us" '{"tool":"LMbench","metric":"null_syscall_latency","higher_is_better":false}'
    ;;
  hackbench-process|hackbench-socket)
    flag="-p"
    [[ "$test_name" == hackbench-socket ]] && flag="-i"
    output="$(hackbench "$flag" -l "$hackbench_loops" -g "$hackbench_groups" 2>&1)"
    value="$(awk '/Time:/ {print $2}' <<<"$output")"
    emit "$value" "seconds" "{\"tool\":\"hackbench\",\"metric\":\"${test_name#hackbench-}_completion_time\",\"higher_is_better\":false}"
    ;;
  fio-randread|fio-randwrite|fio-seqwrite)
    rw="${test_name#fio-}"
    fio_rw="$rw"
    [[ "$rw" == seqwrite ]] && fio_rw=write
    bs=4k
    [[ "$rw" == seqwrite ]] && bs=1m
    output="$(fio --name="$rw" --filename="$work_dir/fio.bin" --rw="$fio_rw" --bs="$bs" \
      --size="${FIO_SIZE:-512M}" --time_based --runtime="${FIO_RUNTIME:-30}" --ioengine=sync --direct=1 --iodepth=1 \
      --numjobs=1 --group_reporting --output-format=json)"
    section=read
    [[ "$rw" != randread ]] && section=write
    value="$(jq ".jobs[0].${section}.iops" <<<"$output")"
    bw="$(jq ".jobs[0].${section}.bw_bytes" <<<"$output")"
    p99="$(jq ".jobs[0].${section}.clat_ns.percentile[\"99.000000\"] // null" <<<"$output")"
    rm -f "$work_dir/fio.bin"
    emit "$value" "IOPS" "{\"tool\":\"fio\",\"metric\":\"${rw}_${bs}_iops\",\"bandwidth_bytes_per_second\":${bw},\"clat_p99_ns\":${p99},\"higher_is_better\":true}"
    ;;
  iperf-tcp1|iperf-tcp4)
    [[ -n "$iperf_host" ]] || { echo 'IPERF_HOST 不能为空' >&2; exit 2; }
    streams=1
    [[ "$test_name" == iperf-tcp4 ]] && streams=4
    output="$(iperf3 -c "$iperf_host" -p "$iperf_port" -t "$iperf_runtime" -P "$streams" -J)"
    value="$(jq '.end.sum_received.bits_per_second' <<<"$output")"
    retransmits="$(jq '.end.sum_sent.retransmits // 0' <<<"$output")"
    emit "$value" "bit/s" "{\"tool\":\"iperf3\",\"metric\":\"tcp_${streams}_stream_throughput\",\"retransmits\":${retransmits},\"higher_is_better\":true}"
    ;;
  iperf-loopback1|iperf-loopback4)
    streams=1
    [[ "$test_name" == iperf-loopback4 ]] && streams=4
    local_port="${IPERF_PORT:-5201}"
    iperf3 -s -1 -p "$local_port" >/tmp/iperf-server.log 2>&1 &
    server_pid=$!
    sleep 1
    if ! output="$(iperf3 -c 127.0.0.1 -p "$local_port" -t "$iperf_runtime" -P "$streams" -J)"; then
      kill "$server_pid" 2>/dev/null || true
      wait "$server_pid" 2>/dev/null || true
      exit 1
    fi
    wait "$server_pid" || true
    value="$(jq '.end.sum_received.bits_per_second' <<<"$output")"
    retransmits="$(jq '.end.sum_sent.retransmits // 0' <<<"$output")"
    emit "$value" "bit/s" "{\"tool\":\"iperf3\",\"metric\":\"loopback_tcp_${streams}_stream_throughput\",\"retransmits\":${retransmits},\"higher_is_better\":true}"
    ;;
  *)
    echo "未知测试: $test_name" >&2
    exit 2
    ;;
esac
