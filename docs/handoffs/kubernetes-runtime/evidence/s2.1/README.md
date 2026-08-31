# S2.1 动态多容器验收证据

## 结论

同一个 `runtimeClassName: cube` Pod 的两个普通容器已在同一 Sandbox、同一 Cube VM 和
同一 Pod IP 内运行。两个容器有独立 Task、rootfs、日志和 exec；通过 CRI 停止并删除
其中一个容器后，另一个容器、Sandbox、VM 与 Pod IP 均保持不变，kubelet 按 desired
state 只重建被删除的容器。整 Pod 删除后，containerd、CNI、CubeShim、VM、mount 和
RuntimeResource active lease 恢复运行前基线。

实现与验收脚本提交为 `ce3afe4c494b23a8b32a06c0221554629090d926`；同一 reviewer
完成最终复核并明确 `APPROVE`，无剩余 must-fix。

## 固定输入

- 基线 source tree：`a9c4cc3bcd7a8d7ab4362e142f3e77df88946045`。
- S2.1 source archive：COS `s21/source/s21-multitask-v1-source.tar.gz`，SHA-256
  `1c2984987656133adab25257138ee9db7ca1f5b308c89d1f3526c26d3d7f55a1`。
- 最终验收脚本：COS `s21/scripts/verify-s21-multicontainer-cloud-v5.sh`，SHA-256
  `55a5323ad1eea4a17680bd99f921a2f99a5834b13543a5b65d8b9a3e56e8627d`。
- 运行节点：自建 Kubernetes 1.36 / containerd 2.3.4 控制平面
  `ins-pl7mznaa`；Pod 固定到本 PoC 的 Cube runtime 节点 `vm-200-2-ubuntu`。

## 严格构建

TAT `inv-083fdrgb3k` 为 `SUCCESS`。构建从固定 Git tree 解包，只覆盖 archive 中两个
显式列出的 Rust 源文件，并校验每个 SHA；随后在 Rust 1.97.1 容器中使用固定 vendor
离线执行：

```text
cargo test -p containerd-shim-cube-rs --lib --offline --locked
cargo check -p containerd-shim-cube-rs --all-targets --offline --locked
cargo build -p containerd-shim-cube-rs --release --offline --locked
```

新增内容是 Sandbox 生命周期单测，release 制品未发生变化：

```text
S21_MULTITASK_BUILD_OK
sha256=39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd
```

因此继续使用 S1.4 已部署且 SHA 相同的 shim，没有覆盖现有部署资产。

## Kubernetes 终验

最终 TAT `inv-083g3u0npg` 为 `SUCCESS`，执行前先断言验收脚本和已部署 shim SHA。
关键结果：

- alpha、beta 同时为 `CONTAINER_RUNNING`，`podSandboxId` 相同；containerd 中两个
  Task、一个 Cube shim、一个 `/run/vc/vm/<sandbox-id>`，两个独立 rootfs export。
- 两个容器的 `kubectl logs` 和非 TTY/非 stdin `kubectl exec` 分别成功。
- alpha 被停止为 exit code `137` 并删除；旧 Task 和旧 rootfs export 消失。
- kubelet 仅以新 container ID 重建 alpha；脚本显式断言旧 containerd Task 不存在，
  新 running container 精确为 replacement alpha 和原 beta，且二者仍指向原 Sandbox。
  Pod 重新达到 Ready，Kubernetes containerStatuses 中两个 ID、running 和 ready 均与
  CRI 一致；beta container ID、exec，Pod UID/IP、Cube VM 和 shim PID 保持不变。
- 删除 Pod 后第 40 次 100 ms 轮询恢复前置基线；active lease 为 0，VM runtime
  恢复基线，durable tombstone 恰好增加 1 条。

终验摘要：

```text
S21_TWO_RUNNING_OK containers=2 shim_count=1
S21_ONE_DELETE_ISOLATED_OK alpha_exit=137 replacement=created survivor=running
S21_BASELINE_CLEAN wait_attempt=40 lease_records=344
S21_MULTICONTAINER_OK isolated_delete=ok active_leases=0 durable_tombstone_delta=1 vm_runtime=baseline
```

完整云端证据位于
`/data/cubelet/s2.1-evidence/multicontainer-20260831T132824Z`。早期诊断
`inv-a83f7uge7x` 已独立证明删除 alpha 后 beta 可继续 exec；最终脚本进一步覆盖 kubelet
重建语义和全量前后基线。

## 代码门禁

`managed_sandbox_allows_distinct_task_creates_and_waits_for_all` 同时保留两个不同 Task
create reservation，证明 Sandbox 允许不同 Task ID 并发进入 shared-root 模式；shutdown
必须等待两项 reservation 全部释放。重复 Task ID 仍由既有测试拒绝。
