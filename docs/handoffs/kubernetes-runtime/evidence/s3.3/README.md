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
失败语义、双门禁或组合回归。S3.3c～S3.3f 仍必须分别验收。

## S3.3b UID/GID 与组

### 固定输入

- 实现 commit：`d6c16e6b55e4b51249f2619c11e31c3750ae4196`
- 完整 tree：`75482378d7ba2732e6172940db043555d71174b5`
- 云验脚本：
  `CubeShim/sandbox-probe/scripts/verify-s33b-identity-groups-cloud.sh`
- 脚本 SHA-256：
  `0fc2adf4e46687c493b843a8dc8689656e6ee9e81a1ff7c50e99bc0b84f1c619`
- 私有 COS 对象：`s3.3b/verify-s33b-identity-groups-0fc2adf4.sh`
- 身份转换源码 SHA-256：
  `019cd2f1915e6a6565703bce16221de719a066a500da35bfad02406533ad0405`
- 云端定向单元测试：`inv-9841kq036r`，`SUCCESS`、exit code 0；覆盖 create
  两项、exec 一项和已有 Agent spec 转换一项，测试后云端源码恢复原状。
- 实际运行时实现基线：`83902212a85158c8c5fd947e8b06a661f0e1075c`；本阶段 Rust
  改动把既有 exec 转换提取为可测试 helper，不改变已经部署的字段映射，因此 E2E 继续
  固定同一 Shim/Agent binary，并把源代码单测和运行时行为证据分层记录。
- CubeShim SHA-256：
  `4c33aa39c6cd071417f7472fb73a2a7180bf03c68d7f6a6c5e9e9def2f457a14`
- Guest Agent SHA-256：
  `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`
- 固定 OCI image：
  `registry.k8s.io/e2e-test-images/agnhost@sha256:2c5b5b056076334e4cf431d964d102e44cbca8f1e6b16ac1e477a0ffbe6caac4`
- 云节点：本 PoC 创建的 `ins-pl7mznaa`；未修改账号内已有 TKE 集群。

### 实现契约与验收范围

create 与 exec 的 OCI `process.user` 均原样传给 Agent：保留数值 UID/GID 和
`additionalGids` 的输入顺序及重复项，exec 另验证 username；不排序、不去重、不合成
额外组。Kubernetes E2E
使用固定 image 中的 `uid=1000/gid=1000` 用户和隐式组 `gid=50000`，按两轮运行以下
runc/Cube 对照：

1. `supplementalGroupsPolicy=Merge`：Pod `1000:3000`、fsGroup `2000`、显式组
   `4000`，最终组精确为 `2000,3000,4000,50000`；
2. `supplementalGroupsPolicy=Strict`：相同显式输入，最终组精确为
   `2000,3000,4000`；
3. multi Pod：classic init `1100:3100`、restartable sidecar `1200:3200`、继承 Pod
   身份的 app `1000:3000`，三个容器共享一个 Sandbox/VM；
4. 每个容器从原始 CRI inspect 与 containerd info 重算 host-pre-shim user，再和 Guest
   首命令、容器日志及 PodStatus `user.linux` 交叉核对；app 另做非 TTY exec；
5. fsGroup emptyDir 的目录 GID、写入成功和新文件 GID 都必须为 `2000`；
6. 负例固定为 `runAsNonRoot=true + runAsUser=0`，验证 kubelet 在 workload container
   创建前以 `CreateContainerConfigError` 拒绝，而不是把 Guest/Runtime 失败误报成支持。

### 最终结果

最终正式验收 `inv-384315g7di` 为 `SUCCESS`、exit code 0，证据目录为：

`/data/cubelet/s3.3-evidence/s3.3b-identity-groups-20260901T001403Z`

两轮共生成 12 个正例 Pod UID，负例另有 2 个 UID，14 个 UID 全部唯一。正例原始
CRI 中 20 个 container ID 全部唯一；multi 的 init、sidecar、app 绑定同一 sandbox。
Merge、Strict、多容器 override/继承、PodStatus、Guest 日志和 exec 的 runc/Cube 结果
逐项等价。固定 image 的完整 `/etc/passwd` 与 `/etc/group` 原始输出确认隐式组来自 image，
不是验收脚本合成。

负例两种 runtime 的 CRI workload container 数均为 0，日志命令非零且 stdout 为空。
runc 负例 sandbox 位于 legacy ctr container store，kind 为 `sandbox`、runtime 为
`io.containerd.runc.v2`；Cube 负例不产生同 UID legacy ctr container record，而在
containerd v2 sandbox store 中以同一 CRI sandbox ID、`Sandboxer=shim`、runtime
`io.containerd.cube.rs` 表示。该差异是 containerd 双存储模型，不是漏记 workload。

Cube sandbox 为 round1 三个、round2 三个、负例一个，共七个唯一 ID。lease 计数精确为
`466→469→472→473`；七个 sandbox 各自恰有一个 inactive record 和一个 tombstone，
active lease 为 0。round1、round2、negative、final 与 EXIT cleanup 的 container、Task、
Sandbox、snapshot、netns、shim、VM 和 runtime resource 均与 before 精确一致；八个固定
Pod、14 个 kubelet Pod UID 目录和所有活动 runtime 资源均已清零。

独立只读审计脚本 SHA-256 为
`309b1364581af862fe9fb73ee0d8d5ab80af6f589c7f054135cf3ac89f405421`；审计
`inv-a843e8g0wv` 为 `SUCCESS`、exit code 0。审计不信任成功摘要，而是从 PodSpec、原始
CRI/ctr JSON/JSONL、PodStatus、Guest observation/log、完整 image passwd/group、完整
lease inventory 和当前实时状态独立复算 14 个 UID、20 个 container ID、七个 sandbox、
七个 tombstone 及全部检查点。正式脚本 SHA 与无 `-t/--tty` 的 exec 源码行也被绑定。
同一 reviewer 对实现、云验脚本、审计器和最终证据均明确 `APPROVE`。

### 失败迭代与边界

- `inv-a8423i01ra`：误用当前 crictl 不支持的 `pods -a`；改为 `pods -o json`。
- `inv-88426xg5a8`：PodStatus jq 管道作用域错误；改为显式绑定 statuses/matches。
- `inv-b8429p0t7b`：用截断 passwd 前缀做 `grep -Fx`；改为固定完整行。
- `inv-b842d40nvm`：把 runc 的 legacy sandbox record 误算成 workload container；增加
  `io.cri-containerd.kind` 分类。
- `inv-v842i10n9m`：错误假设 Cube sandbox 也必须出现在 legacy ctr container store；
  通过 `inv-8842n00b6j` 确认 containerd v2 sandbox store 后改为双存储模型断言。
- `inv-3842s20b4a`：早期候选已通过功能验收；随后按 reviewer 要求补持久化负例原始
  CRI container JSON 与 logs exit code，最终以 `inv-384315g7di` 重新完整验收。
- 首次独立审计 `inv-8843d1g2eq` 只因审计器把正式脚本生成的 `*.json.jsonl` 误写为
  `*.jsonl` 而停止；同一 reviewer 复审路径修正后，`inv-a843e8g0wv` 完整通过。

所有功能脚本失败轮次均完成 owned Pod 清理并恢复活动资源精确基线；已创建 Cube sandbox
对应的 inactive durable tombstone 按设计保留。S3.3b 只声明 UID/GID/groups、fsGroup 与
相关多容器继承语义；capabilities/readonly rootfs 属于 S3.3c，NNP/seccomp 属于 S3.3d，
privileged 双门禁属于 S3.3e，不在本结论中提前宣称。
