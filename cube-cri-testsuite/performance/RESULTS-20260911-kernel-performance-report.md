# AGC-30 PVM 内核性能正式报告

报告日期：2026-09-11。结论等级：跨节点 15 样本对比已完成；241 同节点 Host+Guest fast A/B 已完成，用于快速筛查，不能替代完整 15 样本显著性结论。

## 结论

- 本报告按同一 runtime 横向比较两组 kernel，百分比均为 `OS 团队内核 / 仓库构建内核 - 1`。
- 241 同节点 fast A/B 中，Cube 的 CPU 基本持平，STREAM 小幅提升，内存读延迟改善。
- 241 同节点 fast A/B 中，Cube 的 pagefault、fork、context switch、TCP 和 fio 性能均下降，其中 fork 与 context switch 下降最明显。
- OS Host/runc 在部分基础项上更快，但这不能说明 Cube 获益；Cube 自身横向变化才是判断重点。
- fio 仍混合了 `emptyDir` 后端与文件系统差异，只作为端到端观测，不作为纯内核 I/O 结论。

## 241 同节点 Fast A/B

241 节点分别安装仓库 Host+Guest 与 OS Host+Guest，固定 runtime、节点、镜像、资源和 payload：3 个正式样本、4 CPU/2GiB、fio `16MiB/3s`、iperf/sysbench `3s`、seed `20260911`，每组 105 条有效记录。OS Guest 已验证为 `6.6.110-42.45.pvm.guest.cpu.001.set_x86_iopl_ioperm.tl4.x86_64`。

吞吐类“+”表示 OS 更高；延迟类“+”表示 OS 更慢。

| 测例 | 单位 | Host OS/仓库 | runc OS/仓库 | Cube OS/仓库 | Cube 中位数（仓库 -> OS） | 判断 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| sysbench-cpu | events/s | +0.39% | +0.00% | -0.40% | 1733.1 -> 1726.2 | 基本持平 |
| stream-triad | MB/s | +2.66% | +3.05% | +1.44% | 52402 -> 53156 | 小幅提升 |
| lmbench-lat-mem-rd | ns | +13.61% | -6.98% | -10.57% | 5.071 -> 4.535 | Cube 更快 |
| lmbench-pagefault | us | -27.42% | -26.14% | +6.84% | 2.578 -> 2.754 | Cube 小幅变慢 |
| lmbench-fork | us | -4.11% | -4.19% | +52.57% | 376.0 -> 573.7 | Cube 明显变慢 |
| lmbench-ctx | us | -23.59% | -11.17% | +229.93% | 2.84 -> 9.37 | Cube 明显变慢 |
| iperf-tcp1 | bit/s | -45.31% | +15.62% | -18.56% | 2.87G -> 2.34G | Cube 下降 |
| iperf-tcp4 | bit/s | +29.85% | +7.04% | -5.78% | 2.82G -> 2.66G | Cube 下降 |
| fio-randread | IOPS | -1.23% | +2.73% | -12.17% | 43516 -> 38220 | Cube 下降，路径语义影响大 |
| fio-randwrite | IOPS | -0.09% | -6.08% | -12.16% | 41551 -> 36501 | Cube 下降，路径语义影响大 |
| fio-seqwrite | IOPS | +0.00% | +0.04% | -41.62% | 11381 -> 6644 | Cube 下降，路径语义影响大 |

同节点 fast 结果不支持“OS Host+Guest 相比仓库 Host+Guest 带来整体性能提升”的判断。OS 组合只在 Cube 内存读延迟和 STREAM 上更好，进程、缺页、上下文切换、网络与 fio 端到端结果没有改善。

## 跨节点 15 样本补充

下表保留 2026-09-10 的 15 样本结果，仅作补充参考。仓库构建内核运行在 10.0.244.241，OS 团队内核运行在 10.0.0.26，节点差异会影响绝对值，不能单独作为因果结论。

| 测例 | Host OS/仓库 | runc OS/仓库 | Cube OS/仓库 | 解释 |
| --- | ---: | ---: | ---: | --- |
| CPU events/s | -0.61% | -0.54% | -0.80% | 三者同向，主要为节点差异。 |
| STREAM MB/s | -1.70% | -2.25% | -1.68% | 三者同向，未见 OS Guest 特有优势。 |
| fio 随机读 IOPS | +39.41% | +40.04% | +5.41% | 后端不同，不能归因内核。 |
| TCP 单流 Gbit/s | +19.38% | +35.77% | +41.72% | OS 节点绝对值更高，需同节点复核。 |
| TCP 四流 Gbit/s | +19.56% | +43.71% | +48.92% | 同上。 |

## 说明

241 fast A/B 切换的是 Host kernel 与整套 OS Guest/runtime 资产，不是单独替换一个 Guest kernel 文件。因此当前结论应表述为“OS Host+Guest 组合”的横向结果，不能进一步拆成单个 patch 的因果贡献。

回滚后 241 已恢复 repo Host kernel 与 repo installer，但 Cube 探针出现 `reset guest time failed:ttrpc err: Receive packet timeout`。节点保持 `SchedulingDisabled`，未放回普通调度。

## 原始证据

- [仓库 Guest：241 微基准](/data/home/journeyyou/projects/CubeSandbox-zhiyu/_output/cube-cri-perf/20260910-241-repo-kernel-4c-micro-15/report.md)
- [仓库 Guest：241 存储与网络](/data/home/journeyyou/projects/CubeSandbox-zhiyu/_output/cube-cri-perf/20260910-241-repo-kernel-4c-storage-network-15/report.md)
- [OS Guest：26 完整报告](/data/home/journeyyou/projects/CubeSandbox-zhiyu/_output/cube-cri-perf/20260910-026-os-kernel-4c-full-15-rerun/report.md)
- [241 仓库 Host+Guest 快速基线](/data/home/journeyyou/projects/CubeSandbox-zhiyu/_output/cube-cri-perf/20260911-241-repo-host-guest-fast-agent-3-final/report.md)
- [241 OS Host+Guest 快速复测](/data/home/journeyyou/projects/CubeSandbox-zhiyu/_output/cube-cri-perf/20260911-241-os-host-guest-fast-agent-3-final/report.md)
