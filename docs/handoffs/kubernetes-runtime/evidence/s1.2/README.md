# S1.2 OCI Task 验收证据

> 状态：`DONE`。标准 OCI rootfs 已通过 CubeShim 进入真实 Cube Guest；同一 Sandbox/Cube VM 内连续 Task 的自然退出、信号退出与全量清理均已通过，同一 reviewer 对实现、构建、交付和终验分别给出 `APPROVE`。

## 实现范围

- `9c679855`：managed Sandbox Task 无条件消费标准 `CreateTaskRequest.rootfs`，把 containerd overlayfs snapshot 导出到每 Pod 固定 shared root，并加入 Create/Shutdown fence 与 generation 清理。
- `cf07e446`：增加真实 OCI Task probe，覆盖 Create、Start、Wait、Kill、Delete、stdout、rootfs mount 和异常清理。
- `781cd8f8`：CubeShim 在 containerd 2.3 bootstrap v3 endpoint 注册 Task API v3，避免 daemon 实际调用落到旧协议。
- `32a49105`：managed Task 删除只清理本 generation，保留 shared-root 的 `rootfs` 父目录 inode。Guest 的 `cache=never` 配置仍具有 86400 秒目录 entry/attribute timeout，复用同名但不同 inode 会使第二个 Task 命中 stale inode。
- `d47af8c2`：Agent 把 `WaitStatus::Signaled` 映射为 OCI/containerd 约定的 `128 + signal`；SIGKILL/SIGTERM 分别返回 137/143，普通退出码保持不变。

最终已验证实现 commit 为 `d47af8c213f802a3f0cd69593752d1f9c560c3ad`，tree 为 `17224716902ca1ace56c1d68915bbb31c5a766d8`。

## 云端源码与严格构建

只使用本 PoC 创建的香港构建节点 `ins-pl7mznaa`、运行节点 `ins-4dyul5ag` 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`。

- 最终源码归档 SHA-256 `ac85eaf06d18195cd8e08279f82f8a9353bee52d7f9530792ae642c0e98e5b3b`，索引 SHA-256 `136d2326bc95b74ac131770e2c990c30623946955d9f5ac2705f9b40a8b73720`。构建/运行节点物化分别为 `inv-88371kgt1d`、`inv-68371igtqs`，两端 `git write-tree` 均精确匹配最终 tree。
- CubeShim 固定离线 vendor，`115 passed; 0 failed`、all-targets check 和 release build 通过；构建 `inv-a836jsgqnc`、证据 `inv-3836qp0fjn`。最终 shim SHA-256 `a704aa482a4a0faed7eab6d73e2d98b1f238661a9a4a6db776839a5c77844f0b`，cube-runtime SHA-256 `8a9f46be84c264466445efbf66a720717baa47e1df2a5ede98f5de9c275e87eb`。
- Agent 固定 builder image ID `sha256:530b70f6837d036ebb7e4c72d97b5a602957b0a4a31c00fa2c000a2682b2e36c`、Rust 1.89 和 vendor digest `3e812ed1ca842aa25a0dfbf2b1c7679c0acef885eb7d8c6cbe33f31c8ffc291a`。`cargo --offline --locked` 共 203 项通过；一个会修改 TAT/Docker 所属 stdout/stderr UID 的 `test_set_stdio_permissions` 因测试环境前提显式过滤。新增信号转换用例在断网容器内点名 `3 passed; 0 failed`。
- Agent release 在 `--network none` 下构建；主构建/打包 `inv-v837is07tq`，信号定向测试 `inv-b837q0gvrg`，只读证据 `inv-0837qq0nhc`。静态 binary SHA-256 `6153f0ad4521903be74c546702911b9ee7b411c473ae486ae8c4d8c1a241695e`；20 MiB、2 MiB 对齐的 ext4 SHA-256 `7c0fee68583afd9fdc3ad924e403e99beed84c4ac8ecca30c85d139b6af41efb`，`e2fsck` 通过，临时 stage/partial 文件为 0。

## 制品交付

- Shim/runtime/probe 归档 SHA-256 `767a0551e9c6c851de2ca848fda76e3e6601a1ac229dac18b6e03708495e772c`，私有 COS key `s12/artifacts/s12-runtime-artifacts-rootfs-inode.tar.gz`；运行节点物化后全部 SHA 校验通过。
- Agent 归档 size `9142268`、SHA-256 `4e3efbca95f23efa703624c630c2d6411e3adb82aa7370c8e2d7702f9000ca00`，私有 COS key `s12/artifacts/s12-agent-exit-status-v1.tar.gz`。打包 `inv-0837trgbuq`、上传 `inv-b837u8021q`、下载 `inv-0837ukg34d`、运行节点独立目录物化 `inv-b837vd0ssd` 均成功；没有覆盖 S1.1 Agent 资产。

## 真实 Cube VM 终验

终验 TAT `inv-9837xq0wnq` 在 `ins-4dyul5ag` 为 `SUCCESS`，证据目录 `/data/cubelet/s1.2-evidence/20260831T085056Z`。环境为 containerd 2.3.4 独立 root/state/socket、标准 overlayfs OCI image `mirror.ccs.tencentyun.com/library/busybox:1.36.1`、真实 Cilium netns/Pod IP `10.244.2.213` 和 `/dev/kvm`。

关键结果：

```text
S12_OCI_TASK_OK sandbox=s12-live-sandbox ... exit=23 killed=137
S12_HOST_RESIDUE_CLEAN containers=0 tasks=0 sandboxes=0 task_snapshots=0 adapter=0 shared=0 reaper=0 cleanup_records=0 taps=0 filters=0 active_leases=0
S12_LIVE_ACCEPTANCE_OK tree=17224716902ca1ace56c1d68915bbb31c5a766d8 pod_ip=10.244.2.213 lease_records=1 evidence=/data/cubelet/s1.2-evidence/20260831T085056Z image=mirror.ccs.tencentyun.com/library/busybox:1.36.1
S12_STATIC_ANCHOR_CLEAN
```

同一 Sandbox/Cube VM 先执行自然退出 23 的 Task，再执行 SIGKILL Task 并返回 137；第二个 Task 的 Guest overlay 成功建立，关闭了父目录 stale inode 问题。删除后 container、Task、Sandbox、Task 新增 snapshot、adapter/shared/reaper/cleanup record、TAP、tc filter、mount、shim/reaper 进程和 active lease 残留全部为 0；验收前后的既有 snapshot 集合一致，保留的一条 lease record 为 `active=null` durable tombstone，临时 CNI anchor 已删除。

## 审查门禁

同一 reviewer 依次审查并 `APPROVE`：managed rootfs inode 修复、Agent 信号退出码修复、最终源码同步、严格 Agent 构建/ext4、COS 交付/运行节点物化和真实 Cube VM 终验。S1.2 的实现、构建、交付和运行验收门禁均已关闭。
