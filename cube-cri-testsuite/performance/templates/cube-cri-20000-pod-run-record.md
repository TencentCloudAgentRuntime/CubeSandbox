# Cube CRI 2 万 Pod 现场实验记录表

本表每轮填写一份，建议保存为 `<run-id>/report.md`。所有字段均为必填；不适用时填写“不适用”及原因，不得留空。

> **主结果只接受实际通过 RuntimeTemplate 启动的 Pod。** `cube-template-mode: auto` 仅表示允许使用模板，不能作为模板命中的证据。模板命中、冷启动、回退和未知数量必须覆盖本轮全部目标 Pod；任一目标 Pod 未确认模板命中，本轮均不得计入模板启动主结果。

- 墙钟时间统一使用带时区的 RFC 3339 格式；阶段耗时使用同一进程的单调时钟计算。
- 数量记录整数，耗时统一记录秒，容量同时记录原始单位和 GiB/TiB 换算值。
- 自动采集的数据必须填写证据文件路径；人工判断必须填写依据和负责人。
- 不在本表记录密钥、Token、证书内容或完整内部访问凭据。

## 1. 轮次信息

| 字段 | 记录值 |
|---|---|
| 记录表版本 | v1 |
| `run-id` | 待填写 |
| 阶段 | S0 / S1 / S2 / S3 / S4 |
| 场景 | template / template-warmup / cold / cold-image / burst / delete |
| 请求的 Template 策略 | auto / cold |
| 主结果启动路径 | RuntimeTemplate（固定值） |
| 测试日期 | 待填写 |
| 时区 | 待填写 |
| 开始时间 | 待填写 |
| 结束时间 | 待填写 |
| 执行人 | 待填写 |
| 复核人 | 待填写 |
| 集群标识 | 待填写 |
| 目标节点池 | 待填写 |
| 目标 Pod 数 | 待填写 |
| 最终结论 | 通过 / 失败 / 无效 |
| 无效或失败原因 | 待填写 |

### 1.1 模板启动有效性门禁

本节必须在填写性能结果前完成。只有“实际模板命中率”为 100%，且冷启动、回退和未知均为 0 时，本轮才能标记为“模板主结果有效”。预热轮只用于生成或分发模板，不记录为性能结果。

| 数据项 | 要求 | 现场值 | 判定 | 证据路径 |
|---|---:|---:|---|---|
| 目标 Pod | 本轮目标数 | 待填写 | 通过 / 失败 | 待填写 |
| 实际模板命中 Pod | 等于目标 Pod 数 | 待填写 | 通过 / 失败 | 待填写 |
| 冷启动 Pod | 0 | 待填写 | 通过 / 失败 | 待填写 |
| 模板 miss 后回退 Pod | 0 | 待填写 | 通过 / 失败 | 待填写 |
| 启动路径未知 Pod | 0 | 待填写 | 通过 / 失败 | 待填写 |
| 分类合计 | 等于目标 Pod 数 | 待填写 | 通过 / 失败 | 待填写 |
| 实际模板命中率 | 100% | 待填写 | 通过 / 失败 | 待填写 |
| 模板 ID/版本 | 与冻结制品一致 | 待填写 | 通过 / 失败 | 待填写 |
| 模板覆盖节点 | 全部有效 Cube 节点 | 待填写 | 通过 / 失败 | 待填写 |
| 判定数据源 | Cube 指标或结构化日志 | 待填写 | 通过 / 失败 | 待填写 |
| 查询时间范围 | 覆盖 T0 至稳定期结束 | 待填写 | 通过 / 失败 | 待填写 |
| 模板主结果有效 | 是 | 待填写 | 通过 / 失败 | 待填写 |

不得根据 Pod 注解、启动耗时或人工推测判定模板命中。证据必须能按 `run-id`、Pod UID 或 Sandbox ID 与本轮目标 Pod 对账；只有聚合指标时，还须证明查询窗口内没有其他 Cube Pod 创建流量。

## 2. 制品与环境冻结

| 数据项 | 必须记录的值 | 证据路径 |
|---|---|---|
| 仓库版本 | Git commit、分支、工作区是否干净 | 待填写 |
| Workload | 文件 SHA-256 | 待填写 |
| 压测镜像 | 完整 registry/repository@digest | 待填写 |
| Cube installer | 镜像或安装包 digest | 待填写 |
| Cube Runtime | 版本、构建 commit、包 SHA-256 | 待填写 |
| RuntimeClass | 完整对象和 SHA-256，含 overhead | 待填写 |
| RuntimeTemplate | 模板 ID、版本、制品 SHA-256 | 待填写 |
| Host OS/kernel | OS 版本、内核完整版本 | 待填写 |
| Guest OS/kernel | Guest image digest、内核完整版本 | 待填写 |
| PVM | 版本、设备和关键启动参数 | 待填写 |
| Kubernetes | Server、kubelet、scheduler 版本 | 待填写 |
| 容器运行时 | containerd、runc、CRI 插件版本 | 待填写 |
| 网络组件 | CNI 类型和版本、IPAM 版本 | 待填写 |
| Cube 组件 | CubeShim、RuntimeResource、Guest Agent 版本 | 待填写 |
| 控制面配置 | API Server、scheduler、etcd 参数和 SHA-256 | 待填写 |
| 节点配置 | kubelet、containerd、CNI、sysctl、systemd limits 和 SHA-256 | 待填写 |
| Cube 配置 | create/destroy 并发、cgroup/TAP 池、采集周期和 SHA-256 | 待填写 |
| 控制面规格 | API Server、scheduler、etcd 实例数和规格 | 待填写 |
| Admission/APF | webhook 清单、APF 配置 SHA-256 | 待填写 |
| 监控系统 | Prometheus shard 数、采集周期、版本 | 待填写 |
| 时间同步 | NTP/PTP 状态、节点最大时钟偏差 | 待填写 |

## 3. 容量与配额

> **`maxPods=250` 是正式压测的硬门禁。** 必须逐一核验全部有效 Cube 节点的 `status.allocatable.pods`；现场值均为 250 方可开始正式轮次。任一节点不是 250，或只能提供平均值，本轮均判为无效。

| 数据项 | 计划值 | 现场值 | 证据路径 |
|---|---:|---:|---|
| 有效 Cube 节点数 | 待填写 | 待填写 | 待填写 |
| 备用节点数 | 待填写 | 待填写 | 待填写 |
| 节点机型与磁盘 | 待填写 | 待填写 | 待填写 |
| 单节点 allocatable CPU | 待填写 | 待填写 | 待填写 |
| 单节点 allocatable memory | 待填写 | 待填写 | 待填写 |
| 单节点 allocatable ephemeral-storage | 待填写 | 待填写 | 待填写 |
| 集群 allocatable CPU 合计 | 待填写 | 待填写 | 待填写 |
| 集群 allocatable memory 合计 | 待填写 | 待填写 | 待填写 |
| 集群 allocatable ephemeral-storage 合计 | 待填写 | 待填写 | 待填写 |
| kubelet `maxPods` | **250（固定值）** | 待填写 | 逐节点 `status.allocatable.pods` 清单 |
| 系统 Pod/节点 | 待填写 | 待填写 | 待填写 |
| 目标 Pod/节点 | 待填写 | 待填写 | 待填写 |
| 可用 Pod IP | 待填写 | 待填写 | 待填写 |
| Namespace 数量 | 待填写 | 待填写 | 待填写 |
| ResourceQuota | 待填写 | 待填写 | 待填写 |
| 云产品与 API 配额 | 待填写 | 待填写 | 待填写 |

节点规格不一致时，按机型或配置分组增加行，不得只填平均值。

## 4. 负载参数

| 数据项 | 记录值 | 证据路径 |
|---|---:|---|
| Workload profile | production / simple | `run-config.json`、`batch-summary.json` |
| RuntimeClass overhead | 待填写 | 待填写 |
| 单 Pod CPU request/limit，含 overhead | 待填写 | 待填写 |
| 单 Pod memory request/limit，含 overhead | 待填写 | 待填写 |
| 单 Pod ephemeral-storage request/limit | 待填写 | 待填写 |
| init/普通容器数 | 待填写 | 待填写 |
| 聚合目标 Create QPS | 待填写 | 待填写 |
| 实际平均/峰值 Create QPS | 待填写 | 待填写 |
| 最大在途 Create 请求 | 待填写 | 待填写 |
| 生成器实例数和规格 | 待填写 | 待填写 |
| 每生成器 Pod 数和 Namespace | 待填写 | 待填写 |
| 客户端 QPS/burst | 待填写 | 待填写 |
| Create 重试策略 | 待填写 | 待填写 |
| 测试超时 | 待填写 | 待填写 |
| 镜像缓存策略 | 预热 / 冷镜像 | 待填写 |
| Template 请求策略 | auto / cold | 待填写 |
| 期望启动路径 | RuntimeTemplate / cold | 待填写 |
| 模板预热轮 `run-id` | 待填写 | 待填写 |
| 节点重启与 page cache 状态 | 待填写 | 待填写 |

## 5. T0 前基线

| 数据项 | 现场值 | 判定 | 证据路径 |
|---|---:|---|---|
| Ready/目标节点 | 待填写 | 通过 / 失败 | 待填写 |
| Pressure 或不可调度节点 | 待填写 | 通过 / 失败 | 待填写 |
| 残留目标 Pod | 待填写 | 通过 / 失败 | 待填写 |
| 残留 container/sandbox/VM | 待填写 | 通过 / 失败 | 待填写 |
| TAP/netns/mount/cgroup 基线 | 待填写 | 通过 / 失败 | 待填写 |
| containerd snapshot 基线 | 待填写 | 通过 / 失败 | 待填写 |
| Cube lease/reaper 基线 | 待填写 | 通过 / 失败 | 待填写 |
| 镜像缓存成功节点 | 待填写 | 通过 / 失败 | 待填写 |
| Template 可用节点 | 待填写 | 通过 / 失败 | 待填写 |
| 可用 Pod IP | 待填写 | 通过 / 失败 | 待填写 |
| nodefs/imagefs 最小空闲率 | 待填写 | 通过 / 失败 | 待填写 |
| 监控和日志链路 | 待填写 | 通过 / 失败 | 待填写 |

## 6. 关键时间点

| 事件 | 目标累计数 | 墙钟时间 | 相对 T0 耗时（秒） | 证据路径 |
|---|---:|---|---:|---|
| Watch 全部就绪，记为 T0 | - | 待填写 | 0 | 待填写 |
| 首个 Create 开始 | 1 | 待填写 | 待填写 | 待填写 |
| 最后一个 Create 返回 | 待填写 | 待填写 | 待填写 | 待填写 |
| Pod Created 完成 | 待填写 | 待填写 | 待填写 | 待填写 |
| Pod Scheduled 完成 | 待填写 | 待填写 | 待填写 | 待填写 |
| Pod Initialized 完成 | 待填写 | 待填写 | 待填写 | 待填写 |
| 普通容器 Started 完成 | 待填写 | 待填写 | 待填写 | 待填写 |
| Pod Ready 完成 | 待填写 | 待填写 | 待填写 | 待填写 |
| 10 分钟稳定期结束 | 待填写 | 待填写 | 待填写 | 待填写 |
| 删除开始 | 待填写 | 待填写 | 待填写 | 待填写 |
| Kubernetes 对象删除完成 | 0 | 待填写 | 待填写 | 待填写 |
| Runtime 资源归零 | 0 | 待填写 | 待填写 | 待填写 |

## 7. 核心结果

| 指标 | 结果（秒） | 门槛 | 判定 | 证据路径 |
|---|---:|---:|---|---|
| `T_submit` | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| `T_all_scheduled` | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| `T_all_started` | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| `T_all_ready` | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| Ready 后稳定时长 | 待填写 | 600 | 通过 / 失败 | 待填写 |
| Kubernetes 对象删除耗时 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| Runtime 资源归零耗时 | 待填写 | 900 | 通过 / 失败 | 待填写 |

### 7.1 逐 Pod 时延

| 阶段 | P50（秒） | P95（秒） | P99（秒） | Max（秒） | 样本数 | 证据路径 |
|---|---:|---:|---:|---:|---:|---|
| Create 请求 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| Create → Scheduled | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| Scheduled → Initialized | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| Initialized → ContainersStarted | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| ContainersStarted → Ready | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| Create → Ready | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |

## 8. 数量与错误

| 数据项 | 期望值 | 实际值 | 判定 | 证据路径 |
|---|---:|---:|---|---|
| Create 成功 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| Create 409/429/5xx/timeout | 0/0/0/0 | 待填写 | 通过 / 失败 | 待填写 |
| Ready Pod | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| Failed/Unknown Pod | 0/0 | 待填写 | 通过 / 失败 | 待填写 |
| 成功 init container | production: 目标 Pod 数 × 2；simple: 不适用 | 待填写 | 通过 / 失败 / 不适用 | 待填写 |
| 成功普通容器 | production: 目标 Pod 数 × 3；simple: 目标 Pod 数 × 1 | 待填写 | 通过 / 失败 | 待填写 |
| 非注入容器重启 | 0 | 待填写 | 通过 / 失败 | 待填写 |
| probe 失败 Pod | 0 | 待填写 | 通过 / 失败 | 待填写 |
| Unschedulable Pod | 0 | 待填写 | 通过 / 失败 | 待填写 |
| CRI/Cube 创建错误 | 0 | 待填写 | 通过 / 失败 | 待填写 |
| 重复 IP/MAC/Sandbox ID | 0 | 待填写 | 通过 / 失败 | 待填写 |
| Template 命中/冷启动/回退/未知 | 目标数/0/0/0 | 待填写 | 通过 / 失败 | 待填写 |
| NotReady/Pressure/OOM 节点 | 0 | 待填写 | 通过 / 失败 | 待填写 |

## 9. 系统峰值

| 层级 | 固定记录项 | 峰值或 P99 | 峰值时间 | 证据路径 |
|---|---|---:|---|---|
| 生成器 | 实际 QPS、inflight、Create P99、Watch 重连 | 待填写 | 待填写 | 待填写 |
| API Server/APF | POST P99、inflight、排队、拒绝、429/5xx | 待填写 | 待填写 | 待填写 |
| scheduler | pending、调度吞吐、attempt、调度 P99 | 待填写 | 待填写 | 待填写 |
| etcd | request P99、WAL fsync P99、DB 大小、leader 变更 | 待填写 | 待填写 | 待填写 |
| kubelet | pod worker、PLEG、CRI P99、runtime error | 待填写 | 待填写 | 待填写 |
| containerd | CPU、内存、FD、task/shim、snapshot、GC | 待填写 | 待填写 | 待填写 |
| Cube | create P99、inflight、error、锁等待、lease、reaper | 待填写 | 待填写 | 待填写 |
| 节点 | CPU、run queue、PSI、内存、PID/FD | 待填写 | 待填写 | 待填写 |
| 节点存储 | nodefs/imagefs 使用率、inode、I/O P99 | 待填写 | 待填写 | 待填写 |
| 节点网络 | 丢包、conntrack、CNI/IPAM P99 | 待填写 | 待填写 | 待填写 |

## 10. 长尾节点

至少记录 Ready 最慢的 10 个节点；节点不足 10 个时全部记录。

| 排名 | 节点 | Pod 数 | 最后 Ready（秒） | Ready 速率 | CPU/内存峰值 | 磁盘/网络峰值 | 错误或说明 |
|---:|---|---:|---:|---:|---|---|---|
| 1 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| 2 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| 3 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| 4 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| 5 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 | 待填写 |
| 6-10 | 追加记录 | - | - | - | - | - | - |

## 11. 功能抽检

`simple` profile 下，init、volume、Projected token、probe 和跨容器通信相关检查均填写“不适用”；改为核验每个 Pod 恰有一个普通容器，且无 init container、volume、probe 和自动 ServiceAccount token 挂载。

| 检查项 | 样本数 | 通过 | 失败 | 失败 Pod/证据路径 |
|---|---:|---:|---:|---|
| init 顺序和执行次数 | 200 | 待填写 | 待填写 | 待填写 |
| `emptyDir` 跨容器读写 | 200 | 待填写 | 待填写 | 待填写 |
| Projected token/CA/namespace | 200 | 待填写 | 待填写 | 待填写 |
| HTTP/TCP probe | 200 | 待填写 | 待填写 | 待填写 |
| localhost 端口通信 | 200 | 待填写 | 待填写 | 待填写 |
| ClusterFirst DNS | 200 | 待填写 | 待填写 | 待填写 |
| `NET_ADMIN` 能力边界 | 200 | 待填写 | 待填写 | 待填写 |
| logs/exec | 200 | 待填写 | 待填写 | 待填写 |
| 容器重启且 Sandbox 不重建 | 20 | 待填写 | 待填写 | 待填写 |

## 12. 异常与现场操作

没有异常或人工操作时也要分别填写“无”。任何发布、参数修改、扩缩容、节点重启或人工清理都会改变实验条件，必须记录并判断本轮是否无效。

| 时间 | 类型 | 现象或操作 | 影响范围 | 证据路径 | 负责人 | 对本轮影响 |
|---|---|---|---|---|---|---|
| 待填写 | 异常 / 人工操作 | 待填写 | 待填写 | 待填写 | 待填写 | 无 / 可解释 / 本轮无效 |

## 13. 清理与资源归零

| 数据项 | T0 前 | 清理后 | 差值 | 判定 | 证据路径 |
|---|---:|---:|---:|---|---|
| Kubernetes Pod 对象 | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| CRI container | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| CRI sandbox | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| Cube VM/worker/shim | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| TAP/netns | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| mount/cgroup | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| containerd snapshot | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| Cube lease/reaper pending | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| nodefs/imagefs 字节和 inode | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |
| 节点内存/PID/FD | 待填写 | 待填写 | 待填写 | 通过 / 失败 | 待填写 |

未归零项及处置结论：待填写。

## 14. 证据完整性

| 产物 | 路径 | SHA-256 | 完整性检查 |
|---|---|---|---|
| `run-config.yaml` | 待填写 | 待填写 | 通过 / 失败 |
| `environment.json` | 待填写 | 待填写 | 通过 / 失败 |
| `artifacts.sha256` | 待填写 | 待填写 | 通过 / 失败 |
| `nodes.json` | 待填写 | 待填写 | 通过 / 失败 |
| `pods.jsonl` | 待填写 | 待填写 | 通过 / 失败 |
| `batch-summary.json` | 待填写 | 待填写 | 通过 / 失败 |
| `feature-sampling.json` | 待填写 | 待填写 | 通过 / 失败 |
| `prometheus-snapshot/` | 待填写 | 待填写 | 通过 / 失败 |
| `error-logs/` | 待填写 | 待填写 | 通过 / 失败 |
| `cleanup-summary.json` | 待填写 | 待填写 | 通过 / 失败 |

## 15. 结论签署

| 项目 | 记录值 |
|---|---|
| 20,000 Pod 是否全部 Ready | 待填写 |
| 全部 Ready 用时 | 待填写 |
| 主要瓶颈及证据 | 待填写 |
| 正确性门禁是否通过 | 待填写 |
| 性能门槛是否通过 | 待填写 |
| 清理门禁是否通过 | 待填写 |
| 本轮能否纳入三轮汇总 | 待填写 |
| 执行人签署和时间 | 待填写 |
| 复核人签署和时间 | 待填写 |
