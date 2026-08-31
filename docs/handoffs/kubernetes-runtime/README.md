# Kubernetes RuntimeClass PoC Handoff

## 当前 Stage

S2.1 `IN_PROGRESS`：S1 单容器纵向 PoC 已全部完成并获同一 reviewer `APPROVE`；当前开始验证同一 Cube VM 内动态创建、运行和删除多个普通容器。

## 基线

最后一项已验证实现 commit 为 `517c62b309edcc25d890de26a6495a6b07517ada`，完整 tree 为 `b8130de93b38d563add6b8c0615814b8ba595133`。S1.4 最终 shim SHA-256 为 `39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd`。

## 已完成

S0 和 S1.1～S1.4 均为 `DONE`。S1.4 已补齐合法 Sandbox OCI Any，并通过默认 runc、Job、Deployment、强制删除、创建中取消、100 Pod 循环、Cubebox race tests 和 unmanaged shim 20 次循环。所有 owned runtime resource 与 `/run/vc/vm` 恢复基线，Sandbox Spec warning 为 0；同一 reviewer 最终 `APPROVE`。

## 未完成

S2.1 尚未验证同一 Sandbox 内第二个普通容器的动态 Create/Start/Wait/Delete、分别 logs/exec、单容器退出不影响同 Pod 其他容器，以及整 Pod 删除零残留。TTY/stdin 不纳入 S2.1。

## 验证

S1.4 严格构建 `inv-a83cu30ran`、部署 `inv-a83cxjgftm`、Spec `inv-983d0j0cbd`、最终 smoke `inv-083ehrgqpm`、100 循环 `inv-883ep9gvt6`、Cubebox race tests `inv-b83ejs0618` 和 legacy shim `inv-683f0pg8ge` 均为 `SUCCESS`。最终 TAT 均先断言仓库脚本 SHA；同一 reviewer 最终 `APPROVE`。完整摘要见 `evidence/s1.4/README.md`。

## 阻塞

无外部阻塞。`K8S-OQ-006`、`K8S-OQ-009` 已关闭；durable tombstone 的生产保留/压缩记录为 `K8S-OQ-010`，目标 S5，不阻塞 S2.1。

## 受保护路径

`CubeShim/`、`Cubelet/`、`agent/`、`deploy/kubernetes/runtimeclass/`、`tests/e2e/kubernetes-runtime/` 和本 handoff bundle。云端只操作本 PoC 创建的 `ins-pl7mznaa`、`ins-4dyul5ag` 和对应私有 COS/自建 Kubernetes，不修改账号内其他资源；现有验证资产不覆盖。

## 下一步

先复现 `evidence/s1.4/README.md` 的最终制品 SHA 与 `inv-683f0pg8ge` 零残留结论。随后为 S2.1 建立最小双普通容器 Pod 基线，确认 containerd 在同一 Sandbox 发出多个 Task 请求；依次验证第二容器动态加入、分别 logs/exec/exit、删除一个 Task 不终止另一 Task/VM，以及整 Pod 删除恢复 S1.4 的全量基线。完成后交同一 reviewer。
