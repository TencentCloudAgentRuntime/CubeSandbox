# CubeShim Sandbox API S0 探针

本目录是显式启用的 containerd 2.3 架构探针，不是生产 Cube runtime。二进制复用
containerd 的 runc Task Service，并增加最小 Sandbox Service 和 JSONL RPC trace，
用于在移植到 Rust CubeShim 前独立验证：

- bootstrap v3；
- `sandboxer = "shim"`；
- CRI、CNI、Sandbox 和 Task v3 的真实调用顺序；
- 同一 Sandbox endpoint 上的 Task 复用；
- 正常删除、创建失败、启动失败、创建取消和 shim 崩溃清理。

## 构建与配置

需要 containerd 2.3.4、runc、CNI reference plugins 和 crictl 1.36。显式构建：

```bash
go build -o containerd-shim-cube-s0-v1 .
install -m 0755 containerd-shim-cube-s0-v1 /usr/local/bin/
```

参考配置不会替换节点主 containerd，而是使用独立 root、state 和 socket：

```bash
install -d /etc/cni/net.d-cube-s0 /run/cube-s0 /run/cube-s0-containerd
install -m 0755 scripts/cube-s0-trace /opt/cni/bin/
install -m 0644 config/10-cube-s0.conflist /etc/cni/net.d-cube-s0/
install -m 0644 config/containerd.toml /etc/containerd/cube-s0.toml
containerd --config /etc/containerd/cube-s0.toml
```

用 `config/crictl.yaml` 连接独立 CRI endpoint，并在 `runp` 时选择 handler：

```bash
crictl --config config/crictl.yaml runp --runtime cube-s0 pod.json
```

仓库中的固定输入和云端验收脚本可重放完整正常/异常矩阵：

```bash
sudo scripts/verify-cloud.sh
```

脚本使用 `testdata/pod.json`、`testdata/container.json`，断言 Sandbox Ready、
业务进程 exit code 23、日志、bootstrap v3/ttrpc、Sandbox/Task 同 endpoint PID 与
关键 RPC 顺序。每例结束后检查 CRI Pod/Container、containerd sandbox metadata、
shim 进程/socket、state/root bundle、mount、netns、host-local IP 分配均为零，并确认
CNI ADD/DEL 实际执行成功。原始 RPC/CNI trace、失败输出和摘要写入
`ARTIFACT_DIR`。

## S1.3 真实 CRI 验收

`scripts/verify-s13-cri-cloud.sh` 使用独立的 containerd root、state 和 socket，
不会替换节点主 containerd。它复用节点的 Cilium CNI 配置和主 containerd 中的
BusyBox 镜像，验证真实 `io.containerd.cube.rs` RuntimeClass 路径：

- 宿主日志文件符合 CRI 日志格式，`crictl logs` 可读取；
- `ExecSync` 与非 TTY、非 stdin 的 streaming exec 可传递 stdout、stderr 和进程
  退出码；
- `StopContainer` 可传递 `SIGTERM`，并在进程忽略信号时等待 timeout 后升级为
  `SIGKILL`；
- 删除后 CRI/containerd 元数据、Task 新增 snapshot、RuntimeResource 状态、
  shared-root mount、shim/reaper 进程、netns 和 active lease 均为零残留。

云端节点需预先安装 S1.2 产物到
`/opt/cubesandbox-s12-runtime-artifacts-rootfs-inode` 和
`/opt/cubesandbox-s12-agent-exit-status-v1`，并具备 containerd 2.3.4、crictl
1.36、`/dev/kvm`、`/opt/cni/bin/cilium-cni` 和
`/etc/cni/net.d/05-cilium.conflist`。执行：

```bash
sudo scripts/verify-s13-cri-cloud.sh
```

脚本只重建 `/data/cubelet/s13-cri-live` 和 `/run/cubesandbox-s13`，证据保存在
`/data/cubelet/s1.3-evidence/diagnostic-<UTC>`。

`scripts/verify-s13-kubernetes-cloud.sh` 在 PoC 自建 Kubernetes 1.36 集群的主
containerd 上验证同一能力。脚本创建 `RuntimeClass/cube` 和单个 BusyBox Pod，
检查 `kubectl logs`、非 TTY/非 stdin `kubectl exec`、进程退出码、
`terminationGracePeriodSeconds` 和删除后的全量基线。它要求节点名为
`vm-200-2-ubuntu`，RuntimeResource 资产已安装在
`/data/cubelet/s13-kubernetes`，并把证据写到
`/data/cubelet/s1.3-kubernetes-evidence/<UTC>`。执行：

```bash
sudo scripts/verify-s13-kubernetes-cloud.sh
```

containerd 2.3.4 在 `sandboxer = "shim"` 路径创建 Sandbox shim 时按
`runtime_type` 查找标准名称 `containerd-shim-cube-rs`；仅配置 `runtime_path`
不足以覆盖这一步。因此节点必须把与配置对应、校验过 SHA-256 的 shim 安装到
containerd 服务的 `PATH`（PoC 使用 `/usr/local/bin/containerd-shim-cube-rs`）。
独立 CRI 验收脚本也会断言实际 PATH 解析结果与指定制品完全一致。

Kubernetes 注入的 `/etc/hosts`、`/etc/hostname`、`/etc/resolv.conf` 和 Pod
volume 都以宿主 bind mount 出现在 OCI spec。managed rootfs 会把这些源递归
bind 到 Pod 已有的只读 virtio-fs shared root，并把 OCI source 改写为 Guest
可见路径；`/dev/shm` 继续由现有 Guest shared-shm 逻辑处理。Task 清理时先解除
这些 volume export，再解除 rootfs layer export。

## S1.4 清理与共存验收

`scripts/verify-s14-kubernetes-smoke-cloud.sh` 在主 containerd 上验证默认 runc Pod
不经过 CubeShim，并验证 RuntimeClass/cube 的 Job、Deployment、正常删除、强制删除
和创建中取消。创建中取消用 `SIGSTOP/SIGCONT` 暂停本 PoC 的 RuntimeResource
service，确保测试确实命中 CreateSandbox 尚未完成的窗口。每个用例均以
container、Task、Sandbox、snapshot、netns、mount、shim/reaper 和 active lease 的
前后基线一致作为通过条件。

`scripts/verify-s14-kubernetes-100-cloud.sh` 每批并发创建 10 个短任务 Pod，共运行
100 个。每批删除后都检查同一组资源恢复基线，并断言 100 个 Sandbox ID 唯一。
RuntimeResource 的释放记录是故障 fencing tombstone，不属于 active lease；脚本要求
每个已释放 Sandbox 恰好新增一条 tombstone，并单独报告数量。

`scripts/verify-s14-legacy-shim-cloud.sh` 使用节点上隔离的 legacy containerd endpoint，
直接重放 unmanaged CubeShim 的标准 OCI rootfs、动态 bind/rename/只读/unmount 和
20 次创建删除矩阵，同时确认主 CRI 在执行前后均为 `RuntimeReady`。它不调用
Sandbox API，也不会接管 Kubernetes 主 containerd。

`scripts/verify-s14-legacy-cubebox-tests-cloud.sh` 在独立构建节点从固定 source tree
构建 cubecow、用 vendored `bpf2go` 生成 CubeNet BPF，再执行
`go test -race -count=1 ./services/cubebox`。脚本完全离线消费以下已校验依赖：

- `/opt/s14-cubecow-vendor.tar.gz`，SHA-256
  `9469425277208579f969da435dac33e9a1dcf04add893c4b3abc97e704cc63ab`；
- `/opt/s14-cubelet-go-vendor-v2.tar.gz`，SHA-256
  `1bd2bfdec14081e273a3ae8ee65623397771807b92cfced037b82dfd0b4b7c25`。

动态 virtio-fs bind 的 Guest 目录项允许在 5 秒内最终可见；probe 会记录成功的
尝试次数。残留检查只匹配本探针拥有的 `s02-*` 资源，不会把同一固定 share 下
其他探针的 baseline 资产当作本次残留或清理目标。清理前必须确认每个 owned share、
source 的精确挂载点及子挂载都已脱离；无法脱离时保留目录并让验收失败，禁止在仍挂载
时递归删除。Kubernetes smoke 和 100 Pod 循环还会逐项比较 `/run/vc/vm` 前后集合，
legacy 回归要求 `/run/vc/vm/s02-*` 为零，且不会删除共用的 share 根。Cubebox 包级
回归直接从已验证的 Git tree object 用 `git archive` 构造工作目录，不复制工作树，
避免 tracked 修改、untracked 或 ignored 生成物绕过固定源码结论。

执行顺序：

```bash
sudo scripts/verify-s14-kubernetes-smoke-cloud.sh
sudo scripts/verify-s14-kubernetes-100-cloud.sh
sudo scripts/verify-s14-legacy-cubebox-tests-cloud.sh
sudo scripts/verify-s14-legacy-shim-cloud.sh
```

## S2.1 动态多容器验收

`scripts/verify-s21-multicontainer-cloud.sh` 在主 containerd 上创建包含 alpha、beta 两个
普通容器的 `RuntimeClass/cube` Pod，验证两个独立 Task/rootfs 共用一个 Sandbox、Cube
VM 和 Pod IP，并分别检查 logs 与非 TTY/非 stdin exec。脚本通过 CRI 停止和删除
alpha，要求旧 Task/rootfs 清理、beta ID 和运行状态不变，同时验证 kubelet 只重建
alpha；最后删除 Pod 并比较 container、Task、Sandbox、snapshot、netns、shim、reaper、
VM、mount 和 RuntimeResource active lease 的前后基线，且仅允许新增一条 durable
tombstone。证据写入 `/data/cubelet/s2.1-evidence/multicontainer-<UTC>`。

```bash
sudo scripts/verify-s21-multicontainer-cloud.sh
```

## S2.2 Init 与定向重启验收

`scripts/verify-s22-init-restart-cloud.sh` 覆盖三个独立 `RuntimeClass/cube` Pod：两个
init container 严格串行成功、失败 init 的新 Task 重试、双业务容器中仅重建 exit 23
的 alpha。脚本按 Pod UID 关联 CRI 对象，比较旧/新 Task 与 rootfs export，确认 app
不会越过失败 init 启动，并要求 survivor、Pod UID/IP、Sandbox、VM 和 shim PID 保持
不变。每例删除后均执行 S2.1 全量资源基线检查，最终要求三条 durable tombstone、
active lease 为零。证据写入 `/data/cubelet/s2.2-evidence/init-restart-<UTC>`。

```bash
sudo scripts/verify-s22-init-restart-cloud.sh
```

shim 默认写 `/run/cube-s0/trace.jsonl`，CNI wrapper 写
`/run/cube-s0/cni.jsonl`；可用 `CUBE_S0_TRACE_PATH` 改写 shim trace 位置。

## 调用与清理责任

实测正常顺序为：

1. CRI 创建 netns，执行 CNI ADD；
2. shim bootstrap v3 返回 Task v3 endpoint；
3. Sandbox `CreateSandbox → StartSandbox → WaitSandbox`；
4. 创建业务容器时查询 `SandboxStatus/Platform`；
5. 同一 endpoint 执行 Task `Create → Start → Wait`；
6. 删除时先 Task `Kill/Delete`，再 Sandbox `StopSandbox`；
7. CRI 执行 CNI DEL 和 netns 删除；
8. `ShutdownSandbox` 后 containerd 执行 shim delete 和 bundle 清理。

清理责任：CNI ADD 失败或 Sandbox 创建前失败由 CRI 回滚 netns；Sandbox
`Create/Start` 失败由 shim controller 调用 `ShutdownSandbox`、删除 shim/bundle；
Task 创建失败由 CRI 删除 Task/snapshot；正常或强制删除由 CRI 先清 Task，再 Stop
Sandbox、CNI DEL、Shutdown。CNI DEL 与各删除 RPC必须幂等。

## S0 failpoint

以下 sentinel 只用于云端清理测试，正常路径中不存在：

- `/run/cube-s0/fail-create`：CreateSandbox 返回错误；
- `/run/cube-s0/fail-start`：StartSandbox 返回错误；
- `/run/cube-s0/crash-create`：CreateSandbox 中模拟 shim 崩溃；
- `/run/cube-s0/delay-create`：CreateSandbox 延迟 10 秒，用于取消请求。

每个用例结束后至少检查 CRI Pod/Container、containerd sandbox metadata、shim
进程和 mount 均为 0。

## 演进

S1.1 要把本探针已经验证的 bootstrap、双服务注册、状态枚举、endpoint 和清理契约
移植到 Rust CubeShim，并把 runc Task 替换为 Cube-backed Task。替换完成后删除本
Go 探针，保留配置和 E2E 用例作为回归测试。
