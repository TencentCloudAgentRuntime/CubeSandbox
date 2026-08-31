# S1.3 CRI 基础交互验收证据

> 状态：`DONE`。实现、严格构建和真实 Kubernetes RuntimeClass 终验已通过，同一 reviewer 对初审问题修复和最终证据均给出 `APPROVE`。

## 实现范围

- CubeShim managed rootfs 把 OCI spec 中 Kubernetes 注入的宿主 bind mount 导出到该 Pod 已有的 virtio-fs shared root，并把 source 改写为 Guest 可见路径。文件与目录均支持；目录使用递归 bind，`/dev/shm` 保留给现有 Guest shared-shm 逻辑。
- `PreparedRootfs` 按 volume export、rootfs layer export 的逆序清理，失败和正常删除均复用同一清理路径。
- 独立 CRI 验收增加 shim 标准 PATH 解析结果与指定制品 SHA-256 一致性断言。containerd 2.3.4 的 `sandboxer = "shim"` Sandbox bootstrap 会按 `runtime_type` 查找标准 shim 名，不能只依赖 handler 的 `runtime_path`。
- 新增主集群 `RuntimeClass/cube` 验收，覆盖 `kubectl logs`、非 TTY/非 stdin exec、stdout/stderr、进程/客户端退出码、termination grace period、SIGKILL 退出事件和删除后的全量基线。

## 云端源码与构建

只使用本 PoC 创建的香港构建/控制平面节点 `ins-pl7mznaa`、运行节点 `ins-4dyul5ag` 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`。

- 最终源码归档 COS key `s13/source/s13-bind-mount-v2-source.tar.gz`，SHA-256 `3f2d1be2297bdd59a718a4e76dd3ce4ce2ba4f738f1d815f2e6029d3567587f4`。v2 包含 reviewer 要求的 unmount 失败保留 export 修复和回归测试。
- 最终严格构建 `inv-683bb60cjf` 为 `SUCCESS`：CubeShim lib tests（包含 `drop_preserves_export_when_unmount_fails`）、all-targets check 和 release build 全部通过。前一版构建 `inv-083akx0vx8` 也成功，但不作为最终制品。
- 最终 shim SHA-256 为 `f873cdbe2cf63cbcf5c809ffc9035ba4066d6a92dc658599c50fd513586c253d`，构建路径 `/opt/cubesandbox-s13-build/bind-mount-v2/containerd-shim-cube-rs`。
- 最终部署 `inv-883besgxts` 为 `SUCCESS`：稳定制品路径 `/opt/cubesandbox-s13-runtime-artifacts-bind-mount-v2/containerd-shim-cube-rs`，标准 PATH 安装 `/usr/local/bin/containerd-shim-cube-rs`，两者 SHA-256 一致；handler 保持 `runtime_type = "io.containerd.cube.rs"`、`sandboxer = "shim"`，默认 runc 未改。
- 只清理由早期错误 shim 产生且已核对无 CRI/RuntimeResource owner 的 10 个孤儿进程，定点清理 `inv-083aspgs12` 为 `SUCCESS`；未操作其他进程或资源。

## 真实 Kubernetes RuntimeClass 终验

reviewer 修复后的最终 TAT `inv-383bfj082n` 在 `ins-pl7mznaa` 为 `SUCCESS`，证据目录 `/data/cubelet/s1.3-kubernetes-evidence/20260831T105014Z`。环境为 Kubernetes 1.36.4、containerd 2.3.4、Cilium 1.20.0、Linux 6.6+、x86_64 和 KVM。验收脚本先验证标准 PATH 与稳定 runtime path 的 shim SHA-256 均为最终值，再创建 Pod。

关键结果：

```text
S13_KUBERNETES_LOGS_OK pod_ip=10.244.0.71 runtime_class=cube
S13_KUBERNETES_EXEC_OK process_exit=19 client_rc=19 stdout=ok stderr=ok tty=false stdin=false
S13_KUBERNETES_GRACE_OK elapsed_ms=4451 exit=137 timeout=3
S13_KUBERNETES_RESIDUE_CLEAN containers=baseline tasks=baseline sandboxes=baseline snapshots=baseline netns=baseline adapter=0 shared=0 reaper=0 cleanup_records=0 shared_mounts=0 shim_processes=0 reaper_processes=0 active_leases=0
S13_KUBERNETES_ACCEPTANCE_OK node=vm-200-2-ubuntu evidence=/data/cubelet/s1.3-kubernetes-evidence/20260831T105014Z sandbox=2a7c04ba34d5072be32d2320faf7d77124057ce526ecbd7f7df64c8596c5d539 container=43a4c6ee4a37b85124958c7a74f28c1af444c7eb3e66e5e2117e0b9114e28d34
```

Pod 通过 `runtimeClassName: cube` 启动并获得 Cilium Pod IP；`kubectl logs` 返回启动日志，普通 exec 的 stdout/stderr 正确，失败 exec 的 Guest 进程和 kubectl 客户端均返回 19。容器忽略 TERM 后，kubelet/containerd 等待 3 秒并升级 SIGKILL，CubeShim 上报 137。Pod 删除后 container、Task、Sandbox、snapshot、netns、adapter、shared/reaper/cleanup record、mount、shim/reaper 进程和 active lease 全部恢复到验收前基线。

## 已知非阻塞项

containerd verbose status 会对 Sandbox API 返回的空 `Spec.type_url` 记录 unmarshal warning，但不影响 Sandbox/Task、logs、exec、停止或清理。本项不在 S1.3 扩大协议范围，留作后续兼容性整理。

## 审查门禁

同一 reviewer 初审发现 Drop 在 lazy unmount 失败后仍删除 export 的问题；修复为只有全部 unmount 成功才删除，并增加确定性的失败回归测试。修复后 reviewer 对代码给出 `APPROVE`，在 v2 严格构建、部署和真实 RuntimeClass 终验完成后再次给出最终 `APPROVE`。S1.3 的实现、构建、部署和运行门禁均已关闭。
