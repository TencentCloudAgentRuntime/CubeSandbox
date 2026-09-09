# Cube CRI e2e-framework 测试

迁移自 `agc-cubesandbox-beta/testsuite/e2e-framework`。所有 Cube 用例均执行 `cold` 和 `auto` 两次；runc 对照用例只执行一次。

从仓库根目录运行（自动加载 `local.env`，可用 `CUBE_CRI_ENV` 指定配置文件）：

```bash
UTILITY_IMAGE=mirror.ccs.tencentyun.com/library/busybox:1.36.1 \
  task test:e2e-framework -- --cube-node 10.0.244.112 --runc-node 10.0.244.2
```

目标 cube 节点须已部署运行时并使用 TS4；省略 `--cube-node` 时选择带 `agc.cloud.tencent.com/cube-ready=true` 标签的可调度 Ready TS4 节点。`--runc-node` 指定另一台物理节点；AWV CSI 用例要求两台节点均已部署对应 CSI 插件和 `awv-btrfs` StorageClass。

privileged 正向用例要求节点已配置 `CUBE_ALLOW_PRIVILEGED=true`，当前部署脚本默认开启；旧节点需更新配置，测试本身不修改开关。模板路径会先以同规格 Pod 预热，且每个用例通过 Prometheus 的 `TemplateDerivedSandbox`/`ColdStartSandbox` 增量验证实际路径；因此须先执行 `task deploy:monitoring`，默认读取 `cube-cri-monitoring` 命名空间中 `app=cube-cri-prometheus` Pod。框架遇到致命断言会中止同组剩余用例，可通过 `--assess` 单独补跑。

```bash
task test:e2e-framework -- --probe-only --cube-node 10.0.244.112
task test:e2e-framework -- --feature runtime --cube-node 10.0.244.112
task test:e2e-framework -- --feature probe --assess 'http|tcp' --cube-node 10.0.244.112
task test:e2e-framework -- --feature core --assess 'multicontainer.*-(cold|template)' --cube-node 10.0.244.112
task test:e2e-framework -- --help
```

默认在 `default` 命名空间运行并清理测试资源；`--namespace` 指定已存在的命名空间，`--keep` 保留资源用于排查。每次执行禁用 Go 测试缓存，整体超时默认 30 分钟。

镜像可用 `UTILITY_IMAGE` 和 `CUBE_IMAGE` 覆盖；工具镜像须包含 `/bin/sh`、`httpd`、`sleep` 等 BusyBox 命令。当前 cube 运行时拒绝 `hostNetwork`，因此 cube Pod 改用标准 Pod 网络，runc 宿主机检查沿用原设置。缺少 StorageClass 或第二台物理节点会跳过对应用例，跳过不代表通过。

## 并发启动延迟

```bash
task test:e2e-framework -- --feature latency --cube-node 10.0.244.241
```

`--latency-count` 为每条路径的 Pod 总数，`--latency-concurrency` 限制同时进行的 Create 请求数，二者默认均为 100。提交后不等待 Ready 即继续提交。用例依次输出 `…-cold` 和 `…-template` 两组结果，不能混合计算分位数。对应环境变量为 `LATENCY_COUNT`、`LATENCY_CONCURRENCY`、`LATENCY_TIMEOUT`、`LATENCY_OUTPUT_DIR`、`TEMPLATE_PREPARE_TIMEOUT`、`SANDBOX_PATH_VERIFY_TIMEOUT`。

Pod 总数须按节点剩余资源及 RuntimeClass 的 `overhead` 选择，降低 Create 并发度不会减少最终驻留的 Pod 数。

用例使用 `cube` RuntimeClass 和 pause 镜像，由 `default-scheduler` 调度；必需节点亲和性以 `metadata.name` 约束到 `--cube-node` 指定或自动发现的节点，Create 请求不设置 `nodeName`。准备 Pod 和建立 Watch 不计入延迟；计时从各 Pod 调用 Create 前开始。仅此用例禁用 client-go 客户端限流，实际负载由并发度控制，API Server 限流仍计入耗时。

| 指标（均为毫秒） | 口径 |
| --- | --- |
| `create_api_ms` | 成功 Create 请求发起至返回 |
| `create_start_to_scheduled_observed_ms` | 提交至调度完成：Create 发起至 Watch 首次看到 `spec.nodeName` 非空，包含提交、排队和绑定 |
| `create_return_to_scheduled_observed_ms` | Create 返回至上述绑定观测时刻 |
| `scheduled_to_{running,containers_ready,ready}_observed_ms` | 节点侧路径：绑定观测至首次观测 Running、ContainersReady=True、Ready=True |
| `create_start_to_{running,containers_ready,ready}_observed_ms` | 完整端到端：Create 发起至上述状态观测时刻 |
| `create_return_to_{running,containers_ready,ready}_observed_ms` | Create 返回至上述状态观测时刻 |
| `running_to_ready_observed_ms` | 首次观测 Running 至首次观测 Ready |
| `creation_timestamp_to_scheduled_transition_ms` | API creationTimestamp 至 PodScheduled=True 的 lastTransitionTime |
| `scheduled_transition_to_{containers_started,containers_ready_transition,ready_transition}_ms` | PodScheduled=True 的 lastTransitionTime 至容器启动或相应条件时间戳 |
| `creation_timestamp_to_containers_started_ms` | API creationTimestamp 至全部常规容器最晚 startedAt |
| `creation_timestamp_to_{containers_ready,ready}_transition_ms` | API creationTimestamp 至对应条件首次为 True 的 lastTransitionTime |

每项输出有效样本数及 `p50/p95/p99/min/max`，分位数沿用参考 submitter 的 nearest-rank 算法（排序后第 `ceil(n*p)` 项）。整批另输出首次提交到全部提交返回、全部调度完成、全部 Running、全部 Ready，以及全部提交返回到全部 Ready 的耗时；`created/scheduled/running/ready` 分别记录完成数。

`observed` 使用测试进程的时钟，包含 API 网络、状态上报和 Watch 传输延迟；服务端时间戳通常只有秒级精度，且受 API Server 与节点时钟差影响。Watch 可能早于 Create 响应到达，差值保留负数；同一事件同时报告 Running 和 Ready 时两者差值为 0，不能据此判断内部阶段耗时。

调度路径不是调度器内部纯计算耗时，节点侧路径包含 kubelet 排队、CRI 启动和状态上报。每个 Pod 的「提交至调度完成 + 调度完成至 Ready = 提交至 Ready」，各阶段独立统计的分位数不可直接相加；未调度 Pod 不计入节点侧样本。

日志包含 `SUMMARY_JSON`；输出目录保存 `<batch>.summary.json` 和 `<batch>.pods.json`，后者含逐 Pod 时间戳、指标及最后状态，未指定目录时自动创建临时目录。超时、创建失败、Watch 中断或 Pod 提前结束会保留已有数据并使测试失败；缺失阶段不补零，不输出未完成阶段的整批耗时。默认按唯一批次标签清理 Pod，`--keep` 可保留；镜像缓存和节点已有负载不做重置。

统计与 Watch 异常路径可离线验证：

```bash
cd cube-cri-testsuite/e2e-framework
GOWORK=off go test -race -run '^TestLatency(Percentiles|ObservationsAndPartialSummary|BatchWatch|SchedulingStages|RejectsPreboundPods)$' ./...
```

### 集群验证（2026-09-07）

`local.env` 集群的 `172.17.136.253`（TS4.4、PVM 内核、`cube` RuntimeClass），默认 pause 镜像；未重置缓存。20 / 20 批次全部 Ready，逐 Pod 确认有 `default-scheduler` 的 `Scheduled` 事件，以下单位为毫秒：

| 口径 | p50 | p95 | p99 | min | max |
| --- | --- | --- | --- | --- | --- |
| Create API | 428.218 | 470.324 | 470.465 | 352.822 | 470.465 |
| 提交至绑定（含 API） | 428.990 | 565.802 | 566.434 | 361.816 | 566.434 |
| Create 返回至绑定 | 27.990 | 95.985 | 96.718 | 0.440 | 96.718 |
| 绑定至 Ready | 4104.223 | 4403.660 | 4505.424 | 3718.132 | 4505.424 |
| 提交至 Ready | 4573.457 | 4875.884 | 4896.376 | 4147.088 | 4896.376 |

24 Pod / 8 并发复测全部调度并 Ready，端到端 p50/p95/p99 为 4554.801/4749.240/4843.211ms。两批次的原始时间戳、阶段相加和分位数核对通过，集群无残留测试 Pod；统计、调度拆分、拒绝预绑定及 Watch 异常路径的 `go test -race` 通过。

### 100 并发验证（2026-09-07）

节点 `172.17.209.85`：64 CPU / 128G、TS4.4、PVM 内核；通过现有安装器部署 Cube，先完成 1 Pod 启动检查，再运行 100 Pod / 100 Create 并发，未重置缓存。

```bash
task test:e2e-framework -- --feature latency --cube-node 172.17.209.85 \
  --latency-count 100 --latency-concurrency 100 --latency-timeout 300s \
  --latency-output-dir /tmp/cube-cri-latency-20985-100
```

100/100 经 `default-scheduler` 调度并 Ready，整批提交 1.591s、全部绑定 1.616s、全部 Ready 57.881s；各口径如下，单位为毫秒：

| 口径 | p50 | p95 | p99 | min | max |
| --- | --- | --- | --- | --- | --- |
| Create API | 897.749 | 1127.688 | 1589.427 | 276.715 | 1590.579 |
| 提交至绑定（含 API） | 1352.299 | 1396.094 | 1613.901 | 310.799 | 1613.985 |
| Create 返回至绑定 | 265.583 | 465.716 | 470.284 | 0.700 | 474.176 |
| 绑定至 Ready | 39730.590 | 56254.160 | 56481.875 | 6275.832 | 56554.439 |
| 提交至 Ready | 41089.812 | 57717.188 | 57848.108 | 6586.631 | 57880.637 |

批次 `bae56374-043f-4291-8df2-9b06eb3810e1`；100 条 Scheduled 事件、原始时间戳和分位数均核对通过，测试 Pod 已清理。安装镜像为 `ccr.ccs.tencentyun.com/journeyyou/cube-cri-installer@sha256:3350307edff86cf9d6d798c93b0b3db5953620bcf2c79a2f975decce8cfc32d3`，运行时包 SHA-256 为 `6566c5d534bc3eb52c094f03ec218a21f048424fef942c5002bdf865450847c0`。
