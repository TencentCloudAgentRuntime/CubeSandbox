# AGC-53：Cube CRI 标准链路追踪

## 链路与部署

目标节点为 TS4/PVM `10.0.244.241`。kubelet 1.34 的 CRI metadata 经 containerd 2.2 的 ttrpc 拦截器进入 CubeShim；Shim 提取 W3C `traceparent`，传给 RuntimeResource gRPC 和 Guest Agent ttrpc。Agent 的 span 经 VMM 的 Guest→Host vsock Unix 映射、节点 bridge、trace forwarder 和本地 Collector 进入 Jaeger。该链路不依赖 `cube-cri-trace-proxy`。

containerd 2.2 源码位于相邻的 `tke-containerd` 工作区。本次补丁让 1.7 留存 sandbox 用持久化 runtime handler 恢复 Sandboxer，并让新 sandbox 遵循配置的 `runtime_path`。升级前备份节点 containerd 配置和二进制；部署后验证 `/run/containerd/containerd.sock` 由 containerd 直接监听。

```bash
(cd ../tke-containerd && go build -o bin/containerd-agc53 ./cmd/containerd)
# 将 bin/containerd-agc53 安装至目标节点 /usr/local/bin/containerd-agc53
# 节点 /etc/systemd/system/containerd.service.d/80-agc53-containerd.conf：
# [Service]
# ExecStart=
# ExecStart=/usr/local/bin/containerd-agc53
```

节点 `/etc/cube-cri/tracing.env` 示例（常态 10% 根采样；已有采样父上下文始终继承）：

```ini
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_SERVICE_NAME=cube-cri-containerd
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1
CUBE_CRI_TRACING_OTLP_ENDPOINT=http://127.0.0.1:4318
CUBE_CRI_TRACING_OTLP_PROTOCOL=http/protobuf
CUBE_CRI_TRACING_SAMPLING_RATIO=0.1
```

Collector 须监听上述 OTLP 地址。若要从 kubelet span 开始观察完整链路，还需单独启用 kubelet 的 tracing 配置；Helm 开关不修改 kubelet。

构建、发布与验证：

```bash
task --list-all
task build:runtime
task package:image
cat >/tmp/agc53-helm-values.yaml <<'YAML'
tracing:
  enabled: true
YAML
source local.env
source _output/cube-cri/image.env
export KUBECONFIG="${KUBECONFIG/#\~/$HOME}"
export CUBE_CRI_IMAGE CUBE_CRI_HELM_VALUES=/tmp/agc53-helm-values.yaml
task deploy:runtime
kubectl get node 10.0.244.241
kubectl -n cube-cri-system rollout status daemonset/cube-cri-cube-cri
```

默认 `tracing.enabled=false`：安装器不创建 trace 服务、socket、vsock 映射或 Guest tracing 参数，也不向 containerd 和 RuntimeResource 加载 tracing 环境。启用前须在节点准备上述 `tracing.env`。开启后 Chart 自动向快照模板的 Guest kernel cmdline 追加 `agent.trace=1`；Cubelet 的模板键包含该参数，变更后会重建模板。节点服务 `cube-cri-trace-forwarder`、`cube-cri-agent-trace-bridge` 应为 active，Unix socket `/run/cube-cri/agent-trace.sock` 应存在。关闭后这些节点组件会被移除，用户管理的 `tracing.env` 保留；存量 Cube Pod 的 Shim 和 Guest 需重建后才完全停止 tracing。

## 集群验收

使用 `runtimeClassName: cube` 在该节点创建多个 Pod，并等待 Ready。通过 `kubectl exec POD -- cat /proc/cmdline` 确认 `agent.trace=1`，再查询 Jaeger `/api/traces/<trace-id>`。必须按每个 span 的 `spanID` 和 `references[].spanID` 核对父子关系，不能按时间或 Pod 名拼接。`CreateContainer` 的 Shim RPC 发生在 containerd `StartContainer` 期间的 `Task/Create` 下，这是实际 CRI 调用顺序。

2026-09-16 验收使用 Helm revision 19、镜像 digest `sha256:08fc358caf55fb6065888eedc81b1ac7a02e10e417d568ab365aca11159ad478`。冷启动和快照恢复 Pod 均 Ready，`/proc/cmdline` 均含 `agent.trace=1`；后者还含 `snapshot-mode`。常态采样率下，`agc53-rr-11` 的 Jaeger trace 为 `c7432779306675760bdf1a53e8d9627e`，共 133 个 span，覆盖五个服务，所有 `CHILD_OF` 父 span 均在同一 trace 中：

| 调用 | span ID | 父 span ID |
| --- | --- | --- |
| kubelet `syncPod` | `ff886655e28e9f64` | 根 |
| kubelet `RunPodSandbox` → containerd CRI `RunPodSandbox` | `d3959219f0324c19` → `aa438cf3d224bca8` | `ff886655e28e9f64` → `d3959219f0324c19` |
| containerd `CreateSandbox` → Shim `CreateSandbox` → RuntimeResource `PrepareSandbox` | `540aedac65ff7aec` → `c09e801f826f9db2` → `c764a26f2a1c169a` | `aa438cf3d224bca8` → `540aedac65ff7aec` → `c09e801f826f9db2` |
| containerd `StartSandbox` → Shim `StartSandbox` → Agent `create_sandbox` | `5cfb976a4225ec36` → `97c2826a24b4676e` → `65c1b54b111a5391` | `aa438cf3d224bca8` → `5cfb976a4225ec36` → `97c2826a24b4676e` |
| kubelet `CreateContainer` → containerd CRI `CreateContainer` | `3a2017d192c0a5b3` → `430d1415123fbd1f` | `ff886655e28e9f64` → `3a2017d192c0a5b3` |
| kubelet `StartContainer` → containerd CRI `StartContainer` | `9aa2d33466a6a25a` → `f4111e2bf76ebb2f` | `ff886655e28e9f64` → `9aa2d33466a6a25a` |
| containerd `Task/Create` → Shim `CreateContainer` → Agent `create_container` | `281481d87de167c0` → `dbcaa7c3b228711c` → `500f090b94b586cf` | `container.NewTask` → `281481d87de167c0` → `dbcaa7c3b228711c` |
| containerd `Task/Start` → Shim `StartContainer` → Agent `start_container` | `8caad3bff5090e2a` → `3b08dcc56b02913c` → `b2b6c0ce33928a81` | `task.Start` → `8caad3bff5090e2a` → `3b08dcc56b02913c` |

同批 `agc53-rr-1` 在 10% 采样下正常 Ready，按 `k8s.pod.name` 查询 Jaeger 无 trace；`agc53-rr-11` 可按相同查询方式找到上述 trace。kubelet 已恢复 `samplingRatePerMillion: 100000`，containerd、Shim、RuntimeResource、Agent 根采样率为 0.1。节点与 Collector 最近五分钟无导出错误，节点 Ready；临时 Pod、全量采样和启动调试配置已清理。

迁移前仍在运行的少数系统 Pod 使用旧 `/run/containerd/containerd-real.sock.ttrpc` 地址。节点保留该地址指向原生 containerd ttrpc socket 的兼容符号链接，待这些 Pod 自然重建后即可移除；正式配置、服务和新建 Pod 均使用 `/run/containerd/containerd.sock`，旧 trace proxy 已停止并卸载。

## 150 Pod 并发启动复测

2026-09-16 在 `10.0.244.241` 以 30 个并发 API 请求提交 150 个 BusyBox Pod，均使用正式 `runtimeClassName: cube`、100m CPU request/limit、128Mi 内存 limit、10% 根采样率。第一轮内存 request 为 64Mi：139 个 Ready（P50 4 秒、P95 6 秒），11 个被节点以 `OutOfmemory` 拒绝。原因是每 Pod 另有 768Mi RuntimeClass 开销，150 个超出节点的资源记账容量；18 条被采样的创建 trace 均通过完整父子链校验。

第二轮仅将空闲测试容器的内存 request 调为 1Mi，保留 128Mi limit 和正式 RuntimeClass 开销。单 Pod 烟测通过后，150 个 API 创建请求在 1.25 秒内完成；150/150 Pod Ready、零重启。以 Kubernetes `creationTimestamp` 和 Ready condition 的 `lastTransitionTime` 计算，创建到 Ready 的 P50 为 4 秒、P95/P99 为 5 秒、最大 5 秒；最后一个 Ready 时间距提交开始约 6 秒。时间戳精度为 1 秒。

第二轮 15 条被采样的创建 trace（约 10%）均有 133～134 个 span，覆盖 kubelet、containerd、CubeShim、RuntimeResource 和 Agent；全部 `CHILD_OF` 引用可在同一 trace 中找到父 span，`RunPodSandbox`、`CreateContainer`、`StartContainer` 的跨进程父子边界全部通过。示例：Pod `agc53-b150-115316-130`，trace `283bd5659bd4888917a53f7f86b929c7`；未采样的 `agc53-b150-115316-000` 也正常 Ready，按 Pod 名和 `k8s.pod.update_type=create` 查询不到 trace。15 个 trace ID：

```text
283bd5659bd4888917a53f7f86b929c7 a2bfc74cb371051a004498c1d7eb8167 f79097eef624472113630c5c2d6ce64e
568311b4aab2286713d06c9eb3c895b5 8da9226a02c76c5e119e90d40156830c fe0cef6d3ec1130b12cfbedb78d6b418
240bcbad3369318f08fe7aa45252a7ad 9cad86f6890ae91602feb33dfd415259 55704185f1d9e9e30c50fe213db4e5b7
8cda0408ea2cd12600dd856a7c2936c9 8398910022ed037e198362f1dad1301d 73422e32bfd95ff60d0e25e6d7090017
b1d2d1db7092a89b0c1afe6d018774c5 fed85c8aa6c95b7e0b9a270a05781745 c8f133d62d4f63f7111a9a9ec5b3abaa
```

测试窗口内，bridge 与 forwarder 的进程 CPU 时间增量分别约 0.05 秒、0.06 秒（54 秒采样窗口，含烟测）；150 Pod 运行时文件描述符数分别为 257、136。节点 CPU/内存单点采样为 2668m/7972Mi；节点服务与 Collector 没有本轮导出告警，Jaeger 重启次数未增加。上述 CPU 和内存值不是峰值，不据此推断更高并发容量。临时 Pod 和用于验证低开销被拒绝的 RuntimeClass 已清理，正式 RuntimeClass 未修改。

## 默认关闭开关验收

2026-09-16 使用镜像 digest `sha256:fb650e68b2f14626b004a8cbf3da220a6bef64cb491b1360979be52a1f519ddd` 在同一节点验证 Helm revision 20（`tracing.enabled=false`）：两个 trace unit 均未运行且已移除，trace socket、vsock 映射和宿主机 release 中的 trace 程序不存在；containerd 与 RuntimeResource 的 unit 均不加载 `tracing.env`。新建 Cube Pod Ready，Guest cmdline 不含 `agent.trace`。

随后升级到 revision 21（`tracing.enabled=true`）：两个 trace 服务 active，socket 与 vsock 映射存在；60/60 个新建 Cube Pod Ready，Guest cmdline 含 `agent.trace=1`。Jaeger 中 4 条被采样的创建 trace 各有 133～134 个 span，均覆盖 kubelet、containerd、CubeShim、RuntimeResource、Agent 五个服务，所有 `CHILD_OF` 父 span 可在同一 trace 中找到。示例 trace ID：`42e3c2a9efd1c51c07cb3a9f1ea25307`。测试 Pod 已清理，节点 Ready、DaemonSet 1/1。集群保留显式开启配置，便于继续排查 tracing。
