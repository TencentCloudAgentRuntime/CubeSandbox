# S3.3 SecurityContext 验收证据

## S3.3a 输入与现状诊断

### 固定输入

- 实现 commit：`9380c163f1c299fdf184d41cccdb2b4a3894e51a`
- 完整 tree：`f261edbe1bcf0fabc273a794041ba0ea3d132a60`
- 诊断脚本：
  `CubeShim/sandbox-probe/scripts/diagnose-s33a-security-context-cloud.sh`
- 脚本 SHA-256：
  `d8ff768bd07a4f9bb1554ea223d1d74df39c68343815d0c5d1ac6d990bdb7682`
- 私有 COS 对象：`s3.3a/diagnose-s33a-security-context-cloud-d8ff768b.sh`
- 运行时实现基线：`83902212a85158c8c5fd947e8b06a661f0e1075c`
- CubeShim SHA-256：
  `4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14`
- Guest Agent SHA-256：
  `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`
- OCI image：
  `docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662`
- 云节点：本 PoC 创建的 `ins-pl7mznaa`；未修改账号内已有 TKE 集群。

### 诊断范围和取证方法

诊断使用四组 runc/Cube 成对 Pod，共八个不同 Pod UID；四个 Cube Pod 分别对应四个
不同 Sandbox。所有 Pod 固定到 `vm-200-2-ubuntu`，并固定 image digest：

1. `runAsUser=1234`、`runAsGroup=2345`；
2. 在上述身份上增加 `supplementalGroups=[3456,4567]`；
3. `drop ALL + add NET_RAW` 和 `readOnlyRootFilesystem=true`；
4. `allowPrivilegeEscalation=false` 和 `RuntimeDefault` seccomp。

CRI inspect 与 containerd container info 的原始 JSON 分别规范化，取证层明确标为
`host-pre-shim-input`。Guest 结果由容器首个命令写入 `emptyDir`，再从 kubelet 挂载目录
和容器日志交叉核对，不依赖事后 `exec`。删除后比较 container、Task、Sandbox、snapshot、
netns、shim、VM 和 runtime resource 的 before/after/cleanup 精确集合。

### 最终结果

预检 `inv-083xu1ghbk` 确认 Kubernetes v1.36.4、containerd 2.3.4、x86_64、Linux
6.6.69、KVM 和节点/服务状态满足基线。最终诊断 `inv-9840smg1q7` 为 `SUCCESS`，证据
目录为：

`/data/cubelet/s3.3-evidence/s3.3a-security-context-diagnostic-20260831T225851Z`

最终六项矩阵如下：

| 能力 | runc Guest | Cube Guest | S3.3a 结论 |
|---|---|---|---|
| UID/GID | `1234/2345`，groups `2345` | `1234/2345`，groups `2345` | 当前匹配 |
| supplemental groups | `2345,3456,4567` | `2345,3456,4567` | 当前匹配 |
| capability | 仅 `NET_RAW`，mask `0x2000` | 仅 `NET_RAW`，mask `0x2000` | 当前匹配 |
| readonly rootfs | 写根目录返回 `EROFS` | 写根目录返回 `EROFS` | 当前匹配 |
| no new privileges | `NoNewPrivs=1` | `NoNewPrivs=0` | Cube 缺口 |
| RuntimeDefault seccomp | mode `2`，filters ≥ 1 | mode `2`，filters ≥ 1 | 当前匹配 |

两种 runtime 的 host-pre-shim OCI 输入在四组用例中完全一致；NNP 输入均为 `true`。
CubeShim 当前在 `CubeShim/shim/src/container/mod.rs` 的 protobuf 转换中强制
`set_noNewPrivileges(false)`，因此 NNP 差异不是 kubelet/containerd 输入缺失，而是
Shim 到 Guest 的执行缺口，登记为 `K8S-OQ-013`，由 S3.3d 关闭。

lease 记录从 431 增至 435，四个 Cube Sandbox 各自恰有一条 inactive durable
tombstone，active lease 为 0。最终固定 Pod、kubelet Pod 目录、adapter、shared、reaper、
VM runtime、cleanup record、shared mount 均为 0；containerd、kubelet、runtime resource
service 和节点保持健康。

独立只读审计脚本 SHA-256 为
`bd671999a59ac7d8aae06cc48aec941a1f7d898c0fdef5fc38cd6340163e0a73`；审计
`inv-a840xpgpsu` 为 `SUCCESS`、exit code 0、Dropped 0。审计从八份原始 CRI/ctr
JSON 重新计算规范化输入，核对八个 Pod 的名称/唯一 UID/runtimeClass/image/owner/CRI
UID 绑定、实时 Shim/Agent hash、Guest init/log、六项矩阵、lease `431→435`、四条唯一
tombstone、精确基线和实时零残留。同一 reviewer 最终明确 `APPROVE`。

### 失败迭代和边界

- `inv-0840b6gf3k`：脚本错误预期 Cube 不支持 supplemental groups；实际 Guest 已匹配。
- `inv-6840hpgkg3`：脚本遗漏主 GID 会同时出现在 additional groups；实际输入为 `[2345]`。
- `inv-9840m9gia0`：host emptyDir 证据路径误用了 label 名，修正为 volume 名。
- `inv-b840qk0v67`：功能诊断已成功，但 reviewer 要求把 before/after lease 总数写入证据。

上述轮次均执行了清理并恢复精确基线；每轮 Cube Sandbox 对应的 durable tombstone 按
设计保留。S3.3a 只冻结当前行为和实现缺口，不把“观测匹配”代替后续实现级正反用例、
失败语义、双门禁或组合回归。S3.3b～S3.3f 仍必须分别验收。
