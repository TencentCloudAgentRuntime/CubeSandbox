# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S3.3 `IN_PROGRESS`：S3.2a～S3.2d 已获同一 reviewer `APPROVE`，S3.2 整体标记为 `DONE`；当前开始 SecurityContext。

## 基线

最后一项已验证实现 commit 为 `83902212a85158c8c5fd947e8b06a661f0e1075c`，完整 tree 为 `61b4cf897e957ddeea4b15b3eb91db27106abd16`。S3.2d 回归脚本 SHA-256 为 `2b4ca34d10bf74e30e39296c98e2881b175fad18ace9bd15d624237bf2414325`；运行时仍使用 S3.1 冻结的 shim 与 Guest 资产。

## 已完成

S0、S1、S2.1～S2.4、S3.1a～S3.1d、S3.2a～S3.2d 均为 `DONE`。S3.2d 以固定 SHA 顺序重放前三个子阶段，三次组件运行均恢复精确 runtime/storage/CSI/local-path 基线；六个 Sandbox 各产生且仅产生一条 inactive durable lease，总增量为 6，最终无 active lease 或固定对象残留。20 项矩阵只确认 static-local Filesystem/RWO runtime 语义基线，同一 reviewer 明确 `APPROVE`。

## 未完成

S3.3、S3.4 尚未完成。S3.3 需要冻结并验证 UID/GID、supplemental groups、capabilities、只读 rootfs、`no_new_privileges`、seccomp 和 privileged 双门禁；TTY/stdin 仍可不支持。CSI、动态制备、CBS/CFS/COSFS、跨节点 attach、RWX、扩容与 VolumeSnapshot 仍未验证；static local 只是 runtime 语义基线，不是生产存储方案。

## 验证

S3.2d 组合终验 `inv-a83x7s0g04` 和收紧后的只读审计 `inv-883xivg7ub` 均为 `SUCCESS`；总证据目录为 `/data/cubelet/s3.2-evidence/s3.2d-regression-20260831T220436Z`。审计逐项核对四个脚本 SHA、三个组件证据目录、精确基线、四组 S3.2b mount 与 marker hash、S3.2c 失败/回收证据、六条 Sandbox lease 和 20 项矩阵；最终 active lease 与固定残留均为 0。同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s3.2/README.md`。

## 阻塞

无外部阻塞。S3.3 必须从 CRI/OCI/Guest 三层区分字段是否传入、是否执行和是否可观察，不能只凭 Pod Ready 宣称安全语义生效；privileged 保持节点开关与 Pod 请求双门禁。不触碰非本 PoC 创建的 TKE 集群。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

执行 S3.3：先盘点 kubelet 传入的 CRI/OCI SecurityContext 和当前 Agent 行为，拆成可独立验收的子阶段；依次实现普通身份与组、capabilities/只读 rootfs/`no_new_privileges`/seccomp、privileged 双门禁，最后组合回归并冻结支持矩阵。每个子阶段继续由同一 reviewer 审核到 `APPROVE`。
