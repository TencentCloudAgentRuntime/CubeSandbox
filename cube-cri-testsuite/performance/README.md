# Cube CRI PVM 性能测评方案

## 目标

量化同一 TS4/PVM 节点上原生 Host、`RuntimeClass=runc` 与 `RuntimeClass=cube` 的性能差异，优先定位 PVM 的页表、缺页、进程创建和调度损耗。

不将 Cube 模板恢复、镜像拉取、调度排队和 API 延迟混入运行时性能；它们另由现有 `task test:e2e-framework -- --feature latency` 测量。

## 对照与控制变量

| 项目 | Host | runc | Cube |
| --- | --- | --- | --- |
| 执行位置 | 节点宿主机 | 同一节点 Pod | 同一节点 Pod，`RuntimeClass=cube` |
| CPU/内存 | 受独立 cgroup 限制 | 相同 request/limit | 相同 request/limit，另记录 RuntimeClass overhead |
| CPU | 相同 quota，记录可见 CPU/频率 | 同左 | 同左 |
| 镜像 | 相同基准镜像及 SHA-256 | 同左 | 同左 |
| 存储 | 节点本地文件系统 | runtime `emptyDir` | runtime `emptyDir`；块卷场景单列 |
| 网络 | Host 网络栈 | CNI Pod 网络 | CNI + virtio/vhost 路径 |

每项先预热 1 次，再按固定随机种子轮转 Host/runc/Cube，正式采样 15 次；所有原始 stdout、节点/内核/运行时版本、RuntimeClass、镜像 digest、CPU 拓扑、频率、cgroup、磁盘设备和网络 MTU 均归档。测试期间禁止其他压测及运行时发布。完整预设默认 fio 使用 `512M/30s`，iperf 使用 `30s`，并将实际值写入 `run-config.json`。

`--profile fast` 用于同节点内核 A/B 快速筛查：默认采样 3 次，仅保留 CPU、内存/缺页、进程/上下文切换、三类 fio 和 TCP 单/四流；fio 为 `16M/3s`，iperf、sysbench 为 `3s`，并使用较小的 STREAM、hackbench 和 LMbench 负载。它以约 15 分钟为目标，不代替完整预设的容量与尾延迟结论；两组比较必须使用相同预设、镜像、资源和种子。

主结果为中位数、P5/P95、bootstrap 95% CI 和原始指标相对变化 `Cube/基线 - 1`；报告在测试名中标记 `↑好` 或 `↓好`，避免把吞吐增益误读为“负损耗”。只有 CI 显著且绝对差异达到预先登记门槛时才标记回归；不以单次结果下结论。

## 第一版基准矩阵

| 层面 | 基准 | 关键指标 | 定位价值 | 状态 |
| --- | --- | --- | --- | --- |
| CPU | sysbench cpu | events/s、total time | 指令执行基线 | 必测 |
| 内存 | STREAM | Copy/Scale/Add/Triad GB/s | 内存带宽 | 必测 |
| 内存/页表 | LMbench | `lat_mem_rd`、`bw_mem`、`lat_pagefault`、`lat_mmap` | TLB/页表、缺页和映射 | 必测，主结论 |
| 进程/调度 | LMbench | `lat_proc fork/exec`、`lat_ctx` | fork、exec、context switch | 必测，主结论 |
| 系统调用 | LMbench | `lat_syscall` | 用户态/内核态切换 | 必测 |
| 磁盘 | fio | 4 KiB randread/randwrite IOPS、P50/P99 clat；1 MiB 顺序 BW | virtio 块设备或共享卷 | 必测 |
| 网络 | iperf3 | TCP 单流/4 流 Gbit/s、retransmit；ping RTT | virtio/vhost/CNI | 必测 |
| 调度压力 | hackbench | process/socket 模式完成时间 | 调度与 IPC 辅助证据 | 必测 |
| 综合 | UnixBench、stress-ng | score、各子项吞吐 | 面向汇报的综合读数 | 辅助，不单独归因 |
| 构建 | Linux Kbuild | clean build wall time、CPU time | 多进程/文件系统应用负载 | 第二阶段 |
| Web | Blogbench | requests/s、延迟 | 业务型 I/O 负载 | 第二阶段 |
| JVM | SPECjbb | composite max-jOPS、critical-jOPS | Java 服务负载 | 可选，须有许可证 |
| PARSEC | fluidanimate | wall time、speedup | 多线程应用负载 | 可选，须确认套件许可 |

参照 PVM 相关研究的 LMbench 覆盖范围，保留 process management、memory、filesystem 和 network I/O 中与同机对照相关的 32 项；逐项保存命令、单位和较优方向，不将不同单位聚合成一个分数。

## 网络与存储口径

网络分别报告 Host→runc、runc→runc、Cube→runc 与 Cube→Cube。前 3 组使用相同 runc 服务端，Cube→Cube 单列；不得将 Host loopback 与 Pod 网络直接解释为虚拟网卡损耗。

存储分别报告 runtime `emptyDir`、容器可写层和块卷。三者的介质、挂载选项和路径不同，严禁合并；`emptyDir` 结果只能解释为运行时默认临时卷语义，不能归因成纯虚拟块设备开销。fio 使用 `direct=1`，随机 I/O 固定 4 KiB，顺序 I/O 固定 1 MiB，并单列 IOPS、带宽及尾延迟。

## 可复用实现与验收

实现放在本目录：固定版本基准镜像、Host/runc/Cube 编排器、逐轮执行器、环境采集器和 JSONL 汇总器。镜像不得使用 `latest`，应记录源码 tag/commit、编译器和镜像 digest；结果写入 `_output/cube-cri-perf/<run-id>/`，含原始结果、`environment.json`、汇总 CSV/Markdown 和绘图输入。

新增 `task test:performance`，参数至少包括 `--node`、`--rounds`、`--suite`、`--output`、`--seed`、`--profile`、`--cpu`、`--memory`、`--fio-size`、`--fio-runtime`、`--iperf-runtime`、`--keep`。默认 CPU 为 4；同批各组必须显式使用相同规格。默认运行 `micro,storage,network` 三个必测 suite；综合和第二阶段项显式启用。脚本须在运行前检查 TS4/PVM 内核、`cube`/`runc` RuntimeClass、节点空闲资源、镜像可用性和 CPU 隔离条件；测试后清理 Pod、临时文件和 Host cgroup。

验收：同机三组均完成 15 个有效样本；每个 LMbench 核心项、STREAM、sysbench、fio、iperf3、hackbench 均有原始数据；结果可由汇总器离线再现；测试集群无残留 Pod、VM、TAP、mount 和临时 Host 文件。完成数据采集后再形成结论，当前方案不预设 Cube 的具体损耗数值。

## 上游来源

- [LMbench](https://github.com/intel/lmbench)
- [STREAM](https://www.cs.virginia.edu/stream/)
- [sysbench](https://github.com/akopytov/sysbench)
- [fio](https://github.com/axboe/fio)
- [iperf3](https://software.es.net/iperf/)
- [hackbench](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/selftests/sched)
- [UnixBench](https://github.com/kdlucas/byte-unixbench)、[stress-ng](https://github.com/ColinIanKing/stress-ng)
