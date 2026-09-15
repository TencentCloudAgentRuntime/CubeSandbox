# Cube CRI 2 万 Pod 集群启动压测计划

> 状态：草案，待资源与目标集群评审
>
> 日期：2026-09-14
>
> 输入工作负载：`cube-cri-testsuite/performance/manifests/cube-cri-load-pod.yaml`

## 1. 测试目标

本次测试验证：在资源充足、镜像和模板按生产策略准备完成的 Cube 集群中，批量提交 20,000 个功能等价轻量 Pod 后，需要多久才能使全部 Pod 达到 `Ready=True`。

主结果定义如下：

```text
T_total = T_last_ready_observed - T_first_create_start
```

- `T_first_create_start`：观察器和 Watch 就绪后，第一个 Pod Create 请求开始的单调时钟时间。
- `T_last_ready_observed`：观察器首次确认第 20,000 个目标 Pod 为 `Ready=True` 的单调时钟时间。
- 目标 Pod 必须是本轮成功创建的 20,000 个唯一 Pod；旧 Pod、重建 Pod和非目标命名空间 Pod 不计入。
- Create 失败、Pod 提前进入 `Failed`、观察中断或超时都使该轮失败，不能用重试后的 Pod 替换原样本。
- 主结果仅统计实际通过 RuntimeTemplate 启动的 Pod。`cube-template-mode: auto` 只是允许查找模板；任一 Pod 发生冷启动、模板 miss 后回退或启动路径无法确认，本轮不得作为模板启动主结果。

同时报告以下辅助结果，避免把提交、调度和运行时耗时混成一个数字：

| 指标 | 定义 |
|---|---|
| `T_submit` | 首个 Create 开始到第 20,000 个 Create 返回 |
| `T_all_scheduled` | 首个 Create 开始到全部 Pod 观察到 `spec.nodeName` |
| `T_all_started` | 首个 Create 开始到全部普通容器均有 `startedAt` |
| `T_all_ready` | 即主指标 `T_total` |
| 逐 Pod 延迟 | Create、Scheduled、ContainersStarted、Ready 各阶段的 P50/P95/P99/max |
| 有效吞吐 | 每秒新增 Scheduled、ContainersStarted、Ready Pod 数 |

安全超时先设为 30 分钟。超时只用于终止失控测试，不是性能目标；正式性能门槛应在小规模标定后评审冻结。

## 2. 范围与边界

### 2.1 主场景

- 走完整 Kubernetes 链路：API Server、调度器、kubelet、containerd CRI、CNI、CubeShim、RuntimeResource、Guest Agent。
- 使用 `runtimeClassName: cube`，由 `default-scheduler` 正常调度，不设置 `nodeName`。
- 保留输入工作负载的 init container、多容器、共享网络、卷、探针、安全上下文和 ServiceAccount 投射语义；资源缩小为启动压测规格。
- 压测镜像固定 digest 并预热到所有节点，主指标不包含大规模镜像下载。
- 主轮使用 `cube-template-mode: auto`，但必须通过 Cube 指标或结构化日志逐 Pod 证明实际模板命中率为 100%。模板预热轮与正式计时轮分开执行。
- Pod Ready 后稳定运行 10 分钟，再执行功能抽检和资源回收。

### 2.2 补充场景

以下场景单独执行和报告，不与主结果合并：

- 冷镜像拉取：验证镜像仓库、网络和解压能力，建议先做 1,000 Pod，再决定是否放大到 20,000。
- Cube 显式冷启动：设置 `agc.cloud.tencent.com/cube-template-mode: cold`，用于与生产默认路径对照。
- 最大突发：取消固定 QPS，仅保留请求并发上限，用于寻找控制面拐点。
- 删除、重建、节点或运行时故障：用于验证回收和恢复，不进入启动主指标。

## 3. 工作负载设计

### 3.1 输入工作负载特征

`cube-cri-testsuite/performance/manifests/cube-cri-load-pod.yaml` 是可直接提交的通用 Kubernetes Pod 模板。模板不依赖原业务镜像、凭据或外部服务，仅用最小命令驱动需要验证的 Kubernetes 语义。

需要保留和验证的 Kubernetes 特性如下：

| 类别 | 输入工作负载 | 压测要求 |
|---|---|---|
| Sandbox | 1 Pod 共享网络和 IPC 基础语义 | 使用 Cube RuntimeClass；每 Pod 一个 Cube Sandbox |
| Init container | 2 个顺序执行的 init container | 前一个写共享卷，后一个校验投射卷并写完成标记 |
| 普通容器 | 3 个普通容器 | 全部成功启动，任一容器失败均不算 Ready |
| 镜像 | 所有容器复用 1 个轻量工具镜像 | 正式测试固定 digest，并在主场景提前缓存 |
| 卷 | 1 个 `emptyDir` | 验证跨 init/app/sidecar 的文件可见性和读写权限 |
| Projected 卷 | ServiceAccount token、`kube-root-ca.crt` ConfigMap、Downward API | 保留投射；检查 token、CA 和 namespace 文件存在 |
| 网络 | `ClusterFirst` DNS、容器端口、同 Pod sidecar 通信 | 使用真实 CNI；抽样验证 DNS 和 localhost 通信 |
| 探针 | HTTP startup/readiness/liveness、TCP readiness/liveness | 探针失败或容器重启使该 Pod 功能验收失败 |
| 安全上下文 | `net-admin` 容器增加 `NET_ADMIN` | 验证能力在 Guest 内生效，不映射 Host 设备 |
| 资源 | CPU、内存和临时存储 request | 主场景使用轻量规格；只验证创建链路和 Kubernetes 功能，不代表生产业务容量 |
| 生命周期 | `restartPolicy: Always`、30 秒终止宽限期 | 启动计时后抽样验证容器重启和优雅删除 |
| API 语义 | labels、annotations、ServiceAccount、ConfigMap | 保留跨平台有效字段；Pod 名称和批次标签按实例生成 |

模板将探针周期缩短到 1 秒，避免人为等待主导启动结果。报告仍须同时给出 `ContainersStarted` 和 `Ready`，单独观察探针阶段耗时。

### 3.2 模板清理

压测生成器基于仓库模板只做以下参数化处理：

1. 为每个 Pod 生成唯一的 `metadata.name`，并写入统一轮次和分片标签。
2. 按目标 Namespace 分片，不改变容器数、探针、卷、资源和安全上下文。
3. 正式测试前将工具镜像 tag 替换为已验证的固定 digest。
4. 不向模板注入业务环境变量、凭据、动态会话 ID或外部服务地址。
5. 渲染后执行服务端 dry-run，并检查单 Pod 与批量对象的字段一致性。

### 3.3 轻量资源规格

主场景要求每个 Pod **包含 Cube RuntimeClass overhead 后**的调度总额为 `333m CPU / 768Mi`。压测使用独立的 `cube-load` RuntimeClass，overhead 使用节点原生支持的 `250m CPU / 768Mi`；PodSpec 中普通容器的 CPU request/limit 合计为 `83m`，内存 request/limit 显式设为 `0`，不修改产品默认 `cube` RuntimeClass 和节点 minimum overhead。

| 容器 | CPU request/limit | 内存 request/limit | 临时存储 request |
|---|---:|---:|---:|
| `main` | 50m | 0 | 512Mi |
| `sidecar` | 17m | 0 | 0 |
| `net-admin` | 16m | 0 | 0 |
| **业务容器合计** | **83m** | **0** | **512Mi** |
| **叠加 RuntimeClass overhead** | **333m** | **768Mi** | **512Mi** |

模板中的命令只负责 init 顺序、共享卷校验、HTTP/TCP 探针和常驻进程，不模拟业务逻辑。若 S0 单 Pod 验证发生 OOM、持续 CPU throttling 或探针失败，应先确认镜像和运行时开销；资源规格一旦调整，必须重新计算集群容量。

### 3.4 功能抽检

大规模启动期间不对全部 Pod 执行 `exec` 或网络探测，避免抽检流量改变主结果。全部 Ready 后固定抽取 1%，即 200 个 Pod，验证：

- 三个普通容器均运行，两个 init container 均成功且只执行一次。
- HTTP/TCP probe 持续成功，10 分钟内容器重启次数为 0。
- init container 写入 `emptyDir` 的文件可被目标普通容器读取。
- Projected token、CA、namespace 文件存在，权限和内容类型符合预期。
- 同 Pod 容器通过 localhost 和声明端口互通，DNS 能解析 `kubernetes.default.svc.cluster.local`。
- `net-admin` 容器的 `NET_ADMIN` 能力生效，且不获得额外 Host 能力。
- `kubectl logs` 和 `kubectl exec` 各成功一次。

主结果完成后再从抽样 Pod 中选 20 个终止主容器进程，验证 `restartPolicy: Always` 和容器重建不会重建整个 Sandbox。该动作不计入启动时延。

## 4. 容量规划

### 4.1 单 Pod 调度资源

轻量工作负载的普通容器 CPU request/limit 合计为 `83m`，每个 init container 为 `10m`，不会增加 Pod 的有效 CPU request；所有容器的内存 request/limit 均显式设为 `0`。Kubernetes 调度器叠加 `cube-load` RuntimeClass overhead 后，单 Pod 调度总额为 `333m CPU / 768Mi memory`。

| 来源 | CPU | 内存 | 临时存储 |
|---|---:|---:|---:|
| `main` | 0.050 | 0 | 512Mi |
| `sidecar` | 0.017 | 0 | 0 |
| `net-admin` | 0.016 | 0 | 0 |
| 业务容器合计 | 0.083 | 0 | 0.5Gi |
| `cube-load` RuntimeClass overhead | 0.250 | 0.75Gi | 0 |
| **单 Pod 调度合计** | **0.333** | **0.75Gi** | **0.5Gi** |

20,000 Pod 的理论 request 总量为：

- CPU：6,660 核。
- 内存：15,000Gi，约 14.6TiB。
- 临时存储：10,000Gi，约 9.8TiB。
- Sandbox：20,000 个；普通容器 60,000 个；init container 执行 40,000 次。

以上只是调度 request。节点还需要容纳 Host kernel、kubelet、containerd、CNI、Cube RuntimeResource、Shim/VMM、镜像和启动时 page cache，不能按 request 恰好装满。

### 4.2 节点数公式

每节点建议容量按以下公式计算：

```text
P_cpu   = floor(allocatable_cpu * 0.90 / 0.333)
P_mem   = floor(allocatable_memory * 0.90 / 0.75Gi)
P_disk  = floor(allocatable_ephemeral * 0.70 / 0.5Gi)
P_ip    = 可用 Pod IP 数 - 系统 Pod 数
P_node  = min(P_cpu, P_mem, P_disk, P_ip, maxPods - 系统 Pod 数)
N_active = ceil(20000 / P_node)
N_total  = N_active + ceil(N_active * 10%)
```

CPU和内存至少预留 10%，临时存储预留 30%；10% 备用节点不参与正式调度，用于替换异常节点，不能在容量不足时临时加入并改变测试口径。系统 DaemonSet 的 request 也要从可用余量中扣除。

### 4.3 候选节点规格

下表是立项估算，必须用实际 `status.allocatable`、系统 DaemonSet 数量、镜像大小和磁盘配额重新计算。

| 节点规格 | 理论主要约束 | 建议 Pod/节点 | 有效节点 | 含 10% 备用 |
|---|---|---:|---:|---:|
| 16C/64Gi | CPU；预留后约 43 Pod | 40 | 500 | 550 |
| 32C/64Gi | 内存；预留后约 76 Pod | 75 | 267 | 294 |
| 64C/128Gi | 内存和系统 Pod | 135 | 149 | 164 |
| 64C/256Gi | CPU和系统 Pod | 170 | 118 | 130 |

推荐使用 **64C/128Gi、至少 200Gi allocatable 临时存储、25Gbps 以上网络** 的 TS4/PVM 兼容机型，每节点放置 135 个目标 Pod，需要 149 台有效节点和约 15 台备用节点。每个有效节点的目标 Pod 合计调度资源约为 44.96 CPU、101.25Gi 内存和 67.5Gi 临时存储，仍需用实际 allocatable、系统 Pod 数和启动峰值复核。

单节点可执行 150 Pod 密度上限测试，对应 49.95 CPU、112.5Gi 内存和 75Gi 临时存储。当前 64C/128Gi 节点叠加系统 Pod 后 memory request 约为 98%，该密度不作为正式集群容量规划值。

所有有效 Cube 节点的 kubelet `maxPods` 必须统一设置为 **250**，为目标 Pod 以及 Cube installer、CNI、node-exporter 等系统 Pod 留出对象容量。正式测试前必须逐节点确认 `status.allocatable.pods=250`；任一有效节点不满足时不得开始正式轮次。轻量规格的结果只说明 2 万 Pod 创建链路能力，不能外推原始 `5.5 CPU / 11Gi / 30Gi` workload 的生产容量。

### 4.4 临时存储与镜像

主场景把每个 Pod 的 `ephemeral-storage` request 从 30Gi 缩小为 512Mi，但保留 `emptyDir`、容器可写层和 kubelet 临时存储调度语义。推荐：

- 64C/128Gi 节点至少提供 200Gi allocatable 临时存储，并确认扣除 30% 余量后仍足以调度计划密度。
- containerd imagefs、Cube 状态/模板数据和 Pod 临时存储尽量分盘或设置明确配额。
- 统计工具镜像解压后的实际占用，保证预热完成后 nodefs/imagefs 仍至少有 30% 空闲。
- 测试前后记录磁盘字节、inode、Cube 状态目录和 containerd snapshot 数量。

若仍保留原始 30Gi request，则 1TiB 节点按 30% 磁盘余量只能放约 23 个目标 Pod，至少需要 870 台有效节点和 87 台备用节点；因此 CPU/内存缩小后必须同步确认临时存储口径。

## 5. 集群与参数准备

### 5.1 TKE资源

- TKE集群规格升配: L1000
- 测试节点池关闭自动扩缩容、自动升级和自动修复；加专用 taint，仅允许压测 Pod及必要 DaemonSet 调度。

Kubernetes 官方大集群参考范围为最多 5,000 节点、150,000 Pod 和 300,000 容器；本测试对象数量在范围内，但控制面仍须按启动突发单独压测。

### 5.2 Kubernetes 配置

正式测试前导出并评审以下配置。参数变更先在 100 节点预演，不得在正式轮次临时修改。

| 配置 | 建议 | 说明 |
|---|---|---|
| kubelet `maxPods` | **固定为 250** | 所有有效 Cube 节点逐一核验 `status.allocatable.pods=250`，不一致时不得开始正式轮次 |
| kubelet `podsPerCore` | `0` | 避免与 `maxPods` 叠加造成意外限制 |
| 镜像拉取 | 主场景保持 `IfNotPresent`，所有节点预热 | 不需要为主场景放大 registry QPS |
| Namespace | 20 个，每个 1,000 Pod | 分散对象、Watch 和清理压力 |
| ResourceQuota | 预留完整 20,000 Pod 和总 request | 检查 CPU、内存、临时存储和 Pod 等维度 |
| LimitRange | 禁止改变模板 resource | 防止 admission 注入导致容量口径漂移 |
| APF/admission webhook | 保持生产配置并记录 | 429、排队和 webhook 延迟属于端到端结果 |
| 调度 | `default-scheduler` + hostname topology spread | 不通过 `nodeName` 绕过调度器 |
| 优先级 | 使用专用、低于系统组件的 PriorityClass | 压测不能阻塞 DNS、CNI 和控制面组件 |

创建 20 个专用 Namespace，每个 Namespace 预置同名的最小权限 ServiceAccount。`kube-root-ca.crt` ConfigMap 由 Kubernetes 自动维护，不为每个 Pod 创建独立 Secret、ConfigMap 或 Service。

### 5.3 网络地址

- 若使用 VPC/ENI Pod 网络，至少准备 22,000 个可用 Pod IP，并额外预留节点、系统 Pod和删除重建空间；确认单节点 ENI/IP 上限不小于计划密度。
- 若使用每节点 PodCIDR，按 CNI 的节点掩码计算集群 CIDR。例如约 164 个节点若每节点分配 `/24`，至少需要可容纳 164 个 `/24` 的地址空间；不要只按 20,000 个实际 Pod 估算。
- 校验 Service CIDR、节点网段、Pod CIDR 和 Cube 内部 `192.168.0.0/18` 地址段不发生冲突。

当前集群使用共享网卡 Route ENI，`tke-eni-ipamd:v3.8.2` 的默认 `ip-min-warm-target` 和 `ip-max-warm-target` 均为 5。正式测试必须对**存量目标节点**逐一修改 `NodeENIConfig`，不能只修改全局默认值：

```bash
node=10.0.244.13
kubectl annotate nodeeniconfig "$node" \
  tke.cloud.tencent.com/route-eni-ip-min-warm-target=150 \
  tke.cloud.tencent.com/route-eni-ip-max-warm-target=160 \
  --overwrite
```

最小值按单节点最大突发 Pod 数设置，最大值额外保留少量回收缓冲。修改前确认 `maxRouteENI * maxIPPerENI`、云 API 配额及子网可用 IP 均覆盖目标值。所有测试节点可在核对节点清单后批量执行，但不得包含发生器和非目标节点。

预热完成不能只检查 annotation。目标节点无业务 Pod 时，必须同时满足：

```bash
kubectl get nodeeniconfig "$node" -o jsonpath='{.spec.desiredRouteENIIP}{"\n"}'
kubectl get vpcip \
  -l "tke.cloud.tencent.com/node-name=$node" -o json |
  jq '[.items[] | select(.spec.type == "Pod" and .status.phase == "Assigned")] | length'
```

- `desiredRouteENIIP` 不低于预热最小值，空闲 Pod IP 实际计数也不低于该值。
- Node 出现 `SucceedSetRouteENIWarmTarget` Event，IPAMD/Agent 无分配失败或持续重试。
- 所有节点达到门禁后再静置 2 分钟并保存快照，然后开始正式计时。

全部压测轮次结束后恢复环境默认水位：

```bash
kubectl annotate nodeeniconfig "$node" \
  tke.cloud.tencent.com/route-eni-ip-min-warm-target=5 \
  tke.cloud.tencent.com/route-eni-ip-max-warm-target=5 \
  --overwrite
```

全局默认值通过 TKE `eniipamd` 组件配置维护。当前 v3.8.2 修改全局默认值不自动同步存量节点；升级到支持自动同步的版本后，也应先在小规模节点验证再启用。

### 5.4 PVC存储

- 本次测试不涉及.

### 5.5 Cube 与节点参数

当前仓库默认值包括：

- 压测专用 `cube-load` RuntimeClass overhead：`250m CPU / 768Mi memory`。
- 全部目标节点的 `/etc/cubesandbox/runtimeclass-overhead.json` 保持原生配置：`minimum_cpu_millicores=250`、`minimum_memory_bytes=805306368`。
- Cube workflow `create.concurrent=100`、`destroy.concurrent=100`。
- cgroup pool 3,000，TAP 预创建 500。
- Cube 资源指标采集并发 8，采集周期 5 秒。

单节点密度测试启动 150 个目标 Pod，将覆盖默认 create/destroy 并发上限并观察节点侧排队；cgroup 和 TAP 资源池理论上足够，不应为了集群总量盲目增大。正式测试要记录**节点实际生效配置**及文件 SHA-256，而不是只记录仓库默认值。

节点预检还应覆盖：

- kubelet、containerd、cubelet-cri 和 systemd unit 的 `LimitNOFILE`、`TasksMax`。
- Host `pid_max`、文件句柄、inotify、conntrack、网络队列和端口范围当前值。
- nodefs/imagefs eviction 阈值、日志轮转和 inode 容量。
- CPU governor、NUMA、时间同步、IRQ 分布和背景任务。
- Cube 状态目录、cgroup、TAP、mount 和模板资产基线数量。

这些内核值先通过预演观测是否成为瓶颈；只修改有证据触发上限的参数，并在报告中记录前后值。

### 5.6 镜像与模板准备

主场景执行前：

1. 将模板使用的轻量工具镜像同步到压测集群可访问的仓库并固定 digest。
2. 通过 DaemonSet 或节点镜像预热机制将镜像拉取、解压到全部有效节点。
3. 每节点核对镜像 digest，预热失败的节点移出有效节点池。
4. 为该 Pod 推导出的 VM 规格提前准备兼容 RuntimeTemplate，并完成每节点可用性检查。
5. 预热轮完成后清理其 Pod，确认模板已覆盖全部有效 Cube 节点，再开始独立的正式计时轮。
6. 运行时按 Pod UID 或 Sandbox ID 记录模板命中、冷启动、回退和未知数量，四类合计必须等于目标 Pod 数。

主场景采用 `auto` 请求策略和实际 RuntimeTemplate 启动路径。只有模板命中率为 100%，且冷启动、回退和未知均为 0 时，数据才进入主结果。纯冷启动使用 `cold` 作为独立对照场景，不能与模板启动样本混合解释。

### 5.7 负载生成器

- 在集群内准备一台专用节点. 负载生成器 Pod 被调度到此节点上. 不可把压测 Pod 调度到此节点上.

## 6. 压测工具与提交模型

集群规模编排优先使用 Kubernetes ClusterLoader2，复用其固定 QPS、Pod startup measurement 和 Prometheus 采集能力；增加 Cube 专用逐 Pod 结果收集器，沿用现有 latency 用例的时间口径。

负载生成器调度到专用节点上，共 4 个实例，每个负责 5,000 Pod。协调器在所有 Watch 建立后发布统一开始信号。每个生成器使用独立 Namespace 集合和 API 客户端，并保存逐请求结果。

正式轮次采用开放负载：

- 聚合目标速率：1,000 Pod Create/s。
- 目标提交窗口：约 20 秒。
- 聚合最大在途 Create 请求：2,000。
- 客户端不得因默认 client-go QPS 限流而低于目标速率。
- 到达时间、实际发送时间和响应时间分别记录；落后目标速率也必须如实计入 `T_submit`。

该定义中的“2 万并发”指一个批次中存在 20,000 个目标 Pod，并在约 20 秒内提交，不表示建立 20,000 条同时进行的 HTTP 连接。若业务要求瞬时释放 20,000 个请求，另执行最大突发场景并单独报告。

## 7. 执行流程

### 7.1 环境冻结

1. 记录 Git commit、installer digest、runtime 包、Host/Guest kernel、Guest image、Agent、containerd、kubelet和 CNI 版本。
2. 记录节点清单、`allocatable`、Pod IP和临时存储容量，确认有效节点数满足规划。
3. 关闭发布、扩缩容和其他压测；确保节点无 Pressure、NotReady、异常重启或待清理资源。
4. 验证镜像与模板预热、ServiceAccount 投射、CoreDNS 和监控链路。
5. 保存 API Server、调度器、etcd、kubelet、containerd 和 Cube 的空载基线。

### 7.2 分级预演

任何一级失败都先定位和清理，不继续扩大规模。

| 阶段 | 节点范围 | Pod 数 | 目的 |
|---|---:|---:|---|
| S0 | 1 节点 | 1 | 完整功能和清理检查 |
| S1 | 15 节点 | 2,000 | 预计每节点 133～134 Pod，并发及业务探针检查 |
| S2 | 50 节点 | 5,000 | 控制面、CNI、DNS、监控预演 |
| S3 | 100 节点 | 10,000 | 半规模容量和提交速率验证 |
| S4 | 全部有效节点 | 20,000 | 正式测试 |

S1 至 S3 每级至少成功两轮。S4 正式执行三轮，轮次之间完成清理、资源归零和至少 15 分钟冷却；若需要控制 Host page cache，则在三轮中保持相同策略并明确记录是否重启节点。

### 7.3 正式轮次

1. 创建批次 ID，清理同名残留，建立 20 个 Namespace Watch。
2. 确认监控窗口和日志时间范围，记录 T0 前 5 分钟基线。
3. 协调器发布开始信号，4 个生成器按 1,000 Pod/s 聚合速率提交。
4. 持续统计 Created、Scheduled、Initialized、ContainersStarted、Ready 和失败数。
5. 第 20,000 个 Pod Ready 后停止主计时，保存所有逐 Pod 和批次结果。
6. 保持 20,000 Pod 运行 10 分钟，确认 Ready 不回退、probe 和容器重启正常。
7. 执行 200 Pod 功能抽检及 20 Pod 容器重启抽检。
8. 保存测试后资源快照，然后进入清理。

### 7.4 清理与归零

- 先删除 Namespace 内的目标 Pod，再删除 Namespace；目标集群的 Gatekeeper 禁止直接删除仍含 Pod 的 Namespace。
- 先以 1,000 Pod/s 删除，测量正常回收耗时；最大突发删除另做补充场景。
- 等待 Kubernetes Pod 对象、CRI container/sandbox、Cube VM、Shim/worker 全部消失。
- 检查 TAP、netns、mount、cgroup、共享目录、containerd snapshot、Cube lease 和 reaper。
- `cube_cri_reaper_pending_jobs` 回到 0，lease 数量回到测试前基线。
- 节点内存、PID、FD、磁盘字节和 inode 在 15 分钟内收敛到可解释范围。
- 未归零时保留节点和证据，不进入下一轮，也不得以人工删除掩盖运行时清理问题。

## 8. 观测与结果归因

### 8.1 必采指标

| 层级 | 指标 |
|---|---|
| 生成器 | 计划/实际 QPS、inflight、Create 延迟、429/5xx、Watch 延迟和断连 |
| API Server/APF | Pod POST/PATCH/DELETE、请求时延、排队、拒绝、inflight |
| scheduler | pending Pod、调度吞吐、attempt、queue 和 e2e scheduling latency |
| etcd | request、WAL/fsync、commit、DB 大小、leader 变更 |
| kubelet | pod worker、pod start、RunPodSandbox/Create/Start、PLEG、runtime error |
| containerd | CRI 请求、shim/task、snapshot、GC、进程 CPU/内存/FD |
| Cube | operation duration/inflight/error、RPC、锁等待、模板命中、lease、reaper |
| 节点 | CPU、run queue、PSI、内存、PID/FD、磁盘延迟/inode、网络丢包/conntrack |
| Pod | 各条件时间戳、容器 startedAt/restartCount、probe 和失败原因 |

必须保留 `node` 维度，报告集群分位数的同时给出每节点 Ready 吞吐和长尾节点。内部阶段直方图的分位数不能相加；单 Pod 根因通过 Pod UID、sandbox ID 和时间窗口关联结构化日志。

### 8.2 监控容量

仓库自带监控适合小规模验证，默认单 Prometheus、4Gi 内存和 10Gi 存储，不足以作为约 110 节点的正式采集系统。正式环境建议：

- 4 个 Prometheus shard 按节点分片，或节点 Agent remote-write 到独立时序系统。
- Cube 启动指标 1 秒采集，kubelet和 node-exporter 5 秒采集；先测量监控自身开销。
- 不在指标 label 中加入 Pod UID、sandbox ID 或 container ID。
- 逐 Pod 20,000 条延迟由压测工具保存为 JSONL/Parquet，不依赖高基数 Prometheus。
- 关闭全量 Guest boot trace 和 debug 日志；错误节点按需采集，避免日志 I/O 改变结果。

## 9. 验收标准

### 9.1 正确性门禁

- 20,000/20,000 Pod 成功创建、调度并达到 `Ready=True`。
- 60,000 个普通容器全部启动；40,000 次 init container 执行全部成功。
- 无 Pod `Failed`、无不可恢复 Create 错误、无重复 IP/MAC、无 Sandbox 身份冲突。
- Ready 后稳定 10 分钟，抽检功能全部通过，非注入场景容器重启数为 0。
- 无节点 NotReady、MemoryPressure、DiskPressure、PIDPressure、OOM 或内核异常。
- 删除后运行时和 Kubernetes 资源按第 7.4 节归零。

### 9.2 性能结果

本计划首先测量而不预设“必须多少秒”。S3 完成后应冻结正式门槛，至少包含：

- `T_submit`、`T_all_scheduled`、`T_all_started`、`T_all_ready` 上限。
- Create→Ready、Scheduled→Ready 和 ContainersStarted→Ready 的 P95/P99 上限。
- API Server 429/5xx、CRI 错误和 Cube 内部错误上限。
- 每节点吞吐偏斜和最慢节点上限。

三轮 S4 均满足正确性门禁才算通过。最终结论报告三轮各自结果和中位数，不挑选最快轮次；版本、配置、镜像缓存或 RuntimeTemplate 制品不同的轮次不得合并。任何模板命中率低于 100% 或启动路径存在未知项的轮次均为无效主轮。

## 10. 产物

每轮必须使用 `cube-cri-testsuite/performance/templates/cube-cri-20000-pod-run-record.md` 填写现场记录。表格字段不得删减；补充数据可增加行，不适用项必须说明原因。

每轮输出到独立目录，至少包含：

```text
<run-id>/
  run-config.yaml
  environment.json
  artifacts.sha256
  nodes.json
  pods.jsonl
  batch-summary.json
  feature-sampling.json
  prometheus-snapshot/
  error-logs/
  cleanup-summary.json
  report.md
```

`report.md` 必须回答：

1. 20,000 个 Pod 是否全部确认通过 RuntimeTemplate 启动，模板命中证据是什么。
2. 20,000 个 Pod 是否全部 Ready，实际用了多久。
3. 时间分别消耗在提交、调度、Sandbox、容器启动和 probe 的哪一段。
4. 是否存在节点、控制面、存储、网络或外部依赖瓶颈。
5. 20,000 Pod 稳定运行和删除后是否有资源泄漏。
6. 本轮结果适用于哪组制品、节点规格、镜像缓存和 RuntimeTemplate 制品。

## 11. 开始前检查表

- [ ] 20,000 Pod 的目标提交速率、镜像缓存和 RuntimeTemplate 制品已冻结。
- [ ] 节点数按实际 allocatable 重算，10% 备用节点已就绪但不参与调度。
- [ ] 全部有效 Cube 节点已逐一确认 `status.allocatable.pods=250`。
- [ ] vCPU、内存、临时存储、Pod IP、镜像和云产品配额均已确认。
- [ ] 全部 Cube 节点使用相同 TS4/PVM、containerd、CNI 和不可变 runtime 制品。
- [ ] 脱敏 workload 已通过 `task test:cri` 和单 Pod完整功能验证。
- [ ] 工具镜像 digest 已在所有有效节点缓存，匹配模板已覆盖全部有效节点并验证。
- [ ] 模板命中指标或结构化日志可按 Pod UID/Sandbox ID 与本轮目标 Pod 对账。
- [ ] 20 个 Namespace 的 ServiceAccount 和根 CA ConfigMap 已准备。
- [ ] API Server、scheduler、etcd、kubelet、containerd、Cube和节点监控完整可用。
- [ ] S0 至 S3 已通过，S4 的超时、停止条件和性能门槛已经评审。
- [ ] 清理脚本经过预演，能够检查 Kubernetes 与 Host/Cube 资源归零。

## 12. 参考

- [Cube CRI 运行时监控方案](./cube-cri-observability.md)
- Cube CRI 并发启动延迟口径：`cube-cri-testsuite/e2e-framework/README.md`
- [Kubernetes 大集群注意事项](https://kubernetes.io/docs/setup/best-practices/cluster-large/)
- [ClusterLoader2](https://github.com/kubernetes/perf-tests/tree/master/clusterloader2)
