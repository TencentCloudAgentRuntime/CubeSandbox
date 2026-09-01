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

## S3.3c capabilities 与只读 rootfs

### 固定输入

- 实现 commit：`c55b759e8d0f836164b092fab20739acceb42836`
- 完整 tree：`3cd344f557471635e23b935175032dc35f717302`
- 非法 capability 负例脚本 SHA-256：
  `bfa8e6c7040108eb35d32c8acad094031debf7e5ef69284214a62284fa18399b`
- capabilities/rootfs 正例脚本 SHA-256：
  `6d3a5f52260e5d591c9cddb2eb3f9e861de1a798c67ef233074a3aaacce655d4`
- legacy Cubebox 回归脚本 SHA-256：
  `34f8a34319795ddf6a7eadaace8a83ecbe8e47c7eef71b0e9ce2fd604802719e`
- 私有 COS 对象分别为
  `s3.3c/diagnose-s33c-invalid-capability-cloud-bfa8e6c7.sh`、
  `s3.3c/verify-s33c-capabilities-rootfs-cloud-6d3a5f52.sh` 和
  `s3.3c/verify-s14-legacy-cubebox-tests-cloud-34f8a343.sh`。
- 已部署 CubeShim SHA-256：
  `51b5447236003dbd168f247696f23f2b4a95e105a5f98434400fcecc9a0e68bf`
- 已部署 Guest Agent ext4 SHA-256：
  `0b87e42457b676793030acf6b7b084297bde89b4f15c236c779ace199cf0a626`
- Guest Agent binary SHA-256：
  `38103fae57effc52205fe52a840b20bdcd042d6e5d3ba8a633bc9499ed80ec0e`
- 云节点：本 PoC 创建的 `ins-pl7mznaa`；未修改账号内已有 TKE 集群。

### 实现契约与构建

Agent 在进入 capability 设置前验证 OCI `bounding/effective/inheritable/permitted/ambient`
五个集合，错误包含字段与非法 token；ambient 设置错误不再被丢弃。Shim 在启动 workload
Task 前对原始 OCI config 做同等预校验，同时仍以严格 raw parser 拒绝重复键，非法 capability
因此在 host Shim fail-closed，不会启动 workload Task。create 请求到 Guest 的五个集合
保持原样。

Agent rootfs 不再无条件强制只读，而是保留 OCI `root.readonly`；缺失 root 时保守默认为
只读，显式 write-layer annotation 仍可覆盖为可写。定向单元测试覆盖五集合、非法 token、
ambient 错误、OCI readonly true/false、缺失 root 和 write-layer override。

Shim 构建 `inv-v845640s9h`、Agent v9 构建 `inv-9846kv0vte` 和构建物独立审计
`inv-a846t9gxuh` 均为 `SUCCESS`。Agent 构建固定 Cargo.lock，显式移除复制来的旧 binary，
要求重新编译，并从 ext4 回读 Agent/holder 与 host binary 逐一比较 SHA；完整 suite 为
Agent `119/119`、rustjail `83/83`。部署前检 `inv-v846vq0qwm` 和部署
`inv-6846w1gvr1` 均成功，部署时 Cube Pod、Shim 和 active lease 为 0，未重启
containerd/kubelet，并保留上一版 Agent 回滚副本。

### 正反用例与最终结果

非法 capability 正式负例 `inv-b845t9grgt` 为 `SUCCESS`，证据目录为：

`/data/cubelet/s3.3-evidence/s3.3c-invalid-capability-baseline-20260901T015011Z`

runc 对照 Pod 正常 `Running` 且存在 workload Task；Cube Pod 在 host Shim 以
`CAP_NOT_A_CAPABILITY` 和 `StartError` 明确失败，marker 不存在、workload Task 为 0。
两种 runtime 的 Pod reason、原始 CRI/ctr、Task 和清理基线均被逐项核对。

正式正例 `inv-6846wbgtiv` 为 `SUCCESS`，证据目录为：

`/data/cubelet/s3.3-evidence/s3.3c-capabilities-rootfs-20260901T022736Z`

两轮共 18 个唯一 Pod UID、26 个唯一 workload container 和 9 个唯一 Cube sandbox；
覆盖 classic init、restartable sidecar、app、`drop ALL`、选择性 add、CAP 40 边界、
只读/可写 rootfs、emptyDir 和非 TTY exec。五类 Guest capability mask 与原始 CRI/ctr
集合严格相等，覆盖 `0`、`0x400`、`0x2000`、`0x2400` 和 `0x10000000000`；只读写根
返回 `EROFS`，可写 rootfs 与 emptyDir 写入成功。round1、round2、cleanup 和实时状态均
精确恢复初始 container、Task、Sandbox、snapshot、netns、shim、VM、mount 与 runtime
resource 集合；lease `479→480→484→488`，9 个 sandbox 各一条 inactive tombstone，
active lease 为 0。

不信任正式摘要的总体只读审计 `inv-6847cm06pi` 为 `SUCCESS`。审计器从负例 Pod
JSON/Task/error、26 份原始 CRI/ctr、18 份 Pod JSON、26 份 Guest 观察、4 次 exec、
9 组 sandbox/lease/tombstone 和全部检查点独立重算上述结论。

### legacy 回归

最终 legacy 回归 `inv-084814gvgg` 为 `SUCCESS`，证据目录为：

`/data/cubelet/s1.4-evidence/legacy-cubebox-tests-20260901T030441Z-554186`

回归每次从固定 SHA archive 解压 Rust/Go vendor；Rust/Go image 使用不可变 amd64 OCI
manifest，分别核验 registry config digest、本节点 Docker `.Id` 和 RepoDigest。Cubecow
在断网容器中 `--offline --locked` 完成 release 构建；BPF 生成记录 Debian package 和
compiler 版本，精确生成 14 个非空文件并逐个验证源/目标 SHA。Cubebox 使用
`go test -json -race -count=1`，唯一目标 package 的 324 个 test run 和 324 个 pass
完全相等，无 cache、空测试、fail 或 data race。

legacy 独立审计器 SHA-256 为
`6113eae82bcb3bfa57a9c38a2b54c119a7e990d55984adbeb7b774c1a135a2f0`；
`inv-a8487g0n1w` 为 `SUCCESS`，从固定 13 个证据文件独立重算两份 vendor/source tree、
镜像身份、工具链、14 个 BPF 双 SHA 和 324/324 JSONL 测试结果。

### 失败迭代与边界

- 首轮正例揭示 Agent 无条件强制 rootfs 只读；修复 OCI readonly 保留语义并重新构建、
  独立审计、部署后，正式正例通过。
- legacy 前置轮次先后暴露 CVM 缺少固定 vendor archive、Docker/containerd image store
  的 `.Id` 采用 manifest digest，以及 bpf2go 文件名包含 `x86`/`test` 后缀；每项均保持
  fail-closed，修正为固定输入或精确集合并由同一 reviewer 重新 `APPROVE` 后才重跑。
- legacy 审计首轮仅因预期 GCC 输出含 `gcc version` 而停止；按原始证据改为逐字固定
  Debian GCC 版本后，`inv-a8487g0n1w` 完整通过。

同一 reviewer 对实现、构建、部署、正反用例、两个独立审计和 legacy 回归最终给出
`APPROVE S3.3c DONE`。本阶段只声明 capabilities 与 rootfs 只读/可写语义；NNP/seccomp
属于 S3.3d，privileged 双门禁属于 S3.3e，不在本结论中提前宣称。

## S3.3d：NNP 与 seccomp

### 协议边界与实现

实现提交为 `5a8512456b46ab31a28bc0fc11500562c0385499`。CubeShim 不再把 OCI
`process.noNewPrivileges` 强制改成 `false`，而是原样传入 Agent；Agent 既有启动顺序在
NNP=true 时于 exec 前加载 seccomp，并设置 NNP。Shim/Agent protobuf 的 Process NNP
均为 tag 9，Linux seccomp 均为 tag 8；Kubernetes RuntimeDefault 当前实际输入只包含
`architectures/defaultAction/syscalls`，其中 syscall 包含 names/action、可选 args 和非零
`errnoRet`，可由现有 wire contract 无损传输。

Shim syscall `errnoRet` 是 scalar，而 Agent 同 tag 字段带 presence。为避免安全策略静默
降级，Shim 在 serde/protobuf 转换前拒绝现有协议无法表达的 `defaultErrnoRet`、
`listenerPath`、`listenerMetadata`，并拒绝显式 syscall `errnoRet=0`；后者否则会在 wire
上丢失 presence 并被 Agent 当成缺省 `EPERM`。实现源 SHA-256 为
`2d07043963f05d2a8283defcbb3fbbc35ef9235db7a246aefac4e1cef8e62d0b`；Agent 定向
转换测试源 SHA-256 为
`64f15fbf68b8b754447d185bda071230c8084a49c483738c8fd241361a3997c3`。

### 构建、测试与部署

最终 Shim 构建 `inv-b8497x0qge` 为 `SUCCESS`：8 项定向测试和 148 项主库测试全部
通过，workspace 其余 suite 无失败；产物 SHA-256 为
`60ba8906a391bb899b8a393ffc7c6cb9b35c37184ab9018be2a5bc523dd343d2`，证据目录为
`/data/cubelet/s3.3-evidence/s3.3d-build-final-20260901T034606Z`。Agent 重放
`inv-98492wgis7` 为 `SUCCESS`：定向测试 1 项通过，cube-agent 119 项通过，rustjail
84 项通过、1 项按原定义 filtered，其余 suite 无失败；生产 Agent 代码和 ext4 产物未变，
产物 SHA-256 仍为
`0b87e42457b676793030acf6b7b084297bde89b4f15c236c779ace199cf0a626`。

部署 `inv-6849ef00t9` 为 `SUCCESS`。部署前 Cube Pod、Cube Shim 和 active lease 均为
0；旧 Shim `51b54472…` 备份到 `/opt/cubesandbox-s33d-predeploy-backup-v1`，最终 Shim
以原子替换方式安装，失败路径可回滚。containerd 和 kubelet 均未重启，Agent 摘要未变。

### Kubernetes/Guest 正反例

正式脚本
`CubeShim/sandbox-probe/scripts/verify-s33d-nnp-seccomp-cloud.sh` SHA-256 为
`79aba88c3a46e4f7f6d0d3834f44ddf6152bc779a9a4503bdc4d8f055b04658a`；正式执行
`inv-b849phgapi` 为 `SUCCESS`，证据目录为：

`/data/cubelet/s3.3-evidence/s3.3d-nnp-seccomp-20260901T040243Z`

两轮各创建 runc/Cube × Unconfined/RuntimeDefault 四个 Pod，共 8 个唯一 Pod UID 和
4 个唯一 Cube sandbox。原始 CRI 与 ctr OCI 输入逐项相等；Unconfined +
`allowPrivilegeEscalation=true` 的 host NNP=false，Guest `NoNewPrivs=0`、`Seccomp=0`、
filters=0，`busybox unshare true` 成功。RuntimeDefault +
`allowPrivilegeEscalation=false` 的 host NNP=true，Guest `NoNewPrivs=1`、`Seccomp=2`、
filters>=1，`unshare(0)` 以 `EPERM` 被阻断。runc 与 Cube 两轮结果完全一致。

lease record 从 488 增至 492；四个 Cube sandbox 各对应一条 inactive tombstone，active
lease 为 0。round1、round2 和 cleanup 的 containers、tasks、sandboxes、snapshots、
netns、Cube shims、VM runtime 与 runtime-resource 集合均精确恢复到初始基线；固定测试
Pod 全部不存在，containerd、kubelet 和 runtime-resource service 保持 active。

独立审计脚本
`CubeShim/sandbox-probe/scripts/audit-s33d-nnp-seccomp-cloud.sh` SHA-256 为
`4baeaf7699a1f721d88ad74d77d21c44072d053e712a8f8ed787a87b9dbb3bd6`；
`inv-3849tjgnmx` 为 `SUCCESS`。审计从 16 份原始 CRI/ctr 记录重算 host 输入，校验
8 份 Pod spec/UID 与 CRI label 的绑定、4 份 sandboxID 与 lease tombstone 的绑定、Guest
唯一字段、完整 input fingerprint、lease `488→492`、active lease=0、三次基线以及最终
节点/服务状态，输出 `S33D_AUDIT_OK`。

### 环境失败分类与恢复

第一次正式执行 `inv-0849f6g6w5` 在创建 Pod 前的节点门禁处返回 `FAILED/1`，唯一 trace
是 `DiskPressure != False`；cleanup 为 `original_rc=1 cleanup_rc=0`、固定 Pod 全部不存在、
active lease=0，因失败发生在 baseline capture 前而正确记录
`exact_baseline=not-captured`。原因是此前多轮 Rust 中间构建目录占用磁盘。只删除 8 个
已有独立运行产物和证据的中间 build 目录后，约 49 GiB 空间恢复；
`inv-9849p3051k` 记录节点于 `2026-09-01T04:00:26Z` 恢复
`KubeletHasNoDiskPressure`。最终现场汇总 `inv-8849wngpex` 为 `SUCCESS`：测试 Pod
不存在，三项服务 active，Node Ready=true、DiskPressure=false，live Shim/Agent 摘要
与正式 fingerprint 一致，约 52.44 GB 可用。

同一 reviewer 已分别批准实现、正式 E2E 脚本和独立审计脚本，并最终给出
`APPROVE S3.3d DONE`；S3.3d 的技术证据链和清理闭环无遗留问题。privileged 双门禁
属于 S3.3e，不在本节提前声明。

## S3.3e：privileged 双门禁

### 实现契约

实现提交为 `d594a7faf2b3e7a8f8179745e2c971d0b4cb4e1b`。节点开关固定为
`CUBE_ALLOW_PRIVILEGED`：缺失和精确值 `false` 均关闭，只有精确值 `true` 开启，其他
取值对 privileged 请求 fail-closed。containerd runtime 同时设置
`privileged_without_host_devices=true` 和
`privileged_without_host_devices_all_devices_allowed=true`；Pod 必须通过
`securityContext.privileged=true` 产生唯一、规范的 OCI allow-all device marker，节点
开关与 Pod 请求缺一不可。普通 Pod 即使运行在已开启节点上也不提升权限。

privileged 仅表示 Guest 内提权：Shim 要求 Host OCI `.linux.devices` 为空，传给 Agent 的
规则固定为一条 `a,-1,-1,rwm`；Agent 将 `-1` 还原为 OCI `None`，再映射到 cgroup
wildcard，而不是错误地变成 major/minor 0。Shim 在 Task reservation、lease 和 rootfs
准备前 canonicalize privileged bind source；缺失、相对、无法解析、直接 `/dev` 或通过
符号链接解析到 `/dev` 的 source 都会被拒绝，成功解析的 source 写回 OCI spec，消除后续
符号链接切换窗口。Host device/path 的显式透传不属于本阶段能力。

### 构建、测试与部署

云端构建固定 source patch SHA-256
`a57d057ad338607d4b4d45d4032ee41693ea6b5cee3a533f87d951030c747995`，证据目录为
`/data/cubelet/s3.3-evidence/s3.3e-build-v4-20260901T051239Z`。Shim privileged 定向
测试 9/9、create 定向测试 15/15，并完成 workspace build/check；Agent wildcard 定向测试
2/2，完整 suite 为 118/118，另有两个按原定义跳过的环境依赖测试。最终产物为：

- CubeShim：`84c276492422bbc862e70a61c97c5d1c964595b808051400f33bfb7f531d06fd`；
- Guest Agent binary：`56a3ab87194820b405f90e6c9c19426d6f39ace8511315108ba5aa64c84c0baf`；
- Guest Agent ext4：`87bac7a6cc620595ece5fa5dfa046da8d7b0a6afe63193d7990c6f535b6e6873`。

部署 `inv-684bwgg03r` 为 `SUCCESS`，证据目录为
`/data/cubelet/s3.3-evidence/s3.3e-deploy-20260901T051825Z`；旧版本保存在
`/opt/cubesandbox-s33e-predeploy-backup-v1`。最终 live Shim/Agent ext4 与上述哈希一致。

### Kubernetes/Guest 正反例与独立审计

正式脚本
`CubeShim/sandbox-probe/scripts/verify-s33e-privileged-cloud.sh` SHA-256 为
`31d92bde92677d5121f60925b2ab3ca2d88b09c5e0d3b75a1c521710add90b1f`；最终执行
`inv-084cdrgc1k` 为 `SUCCESS`、exit code 0，证据目录为：

`/data/cubelet/s3.3-evidence/s33e-final-20260901T053443Z-806800`

开关关闭时普通 Pod Ready，privileged Pod 以 `StartError` 和
`CUBE_ALLOW_PRIVILEGED=true is required` 明确拒绝，CRI running workload 为 0。开关
开启后普通与 privileged Pod 均 Ready；普通 Guest 保持默认 capability mask
`00000000a80425fb` 且 mount 被拒，privileged Guest 的 permitted/effective/bounding mask
为 `000001ffffffffff` 且 tmpfs mount 成功；两者都看不到 Host `/dev/kvm`。privileged
原始 OCI 恰有一条 canonical allow-all marker、`.linux.devices` 为空、无 `/dev` source；
普通 OCI 没有 allow-all marker。显式 hostPath `/dev` 的 privileged Pod 在 Task 启动前以
`StartError` 拒绝，CRI running workload 为 0。

目标 Guest 使用 cgroup v2，不提供 cgroup v1 的 `devices.list`，因此本次 E2E 无法直接
读取 Guest all-devices 规则，证据明确记录
`guest_device_e2e=unobservable-cgroup-v2`，没有把它虚报为已观察；Shim 的 canonical OCI
marker 和 Agent `grpc→OCI→cgroup` wildcard 映射由云端定向测试 2/2 闭环。

独立只读审计脚本
`CubeShim/sandbox-probe/scripts/audit-s33e-privileged-cloud.sh` SHA-256 为
`1037cfd0f16a8d6f80f57aeab082a70fb6ae7f6fbeb7217c9c4432a7d4af11e7`；审计
`inv-384cpa0n8v` 为 `SUCCESS`、exit code 0。审计不信任正式摘要，而是从原始 Pod/CRI/OCI
重新计算两条 `StartError`、失败 message 字节与语义、Pod privileged 分类、UID 绑定、
canonical marker、Guest capability/mount、Host `/dev` 输入和 Agent 两个具体测试名；同时
绑定 build/deploy/live 哈希并逐一枚举 `before`、`after-off`、`after-on`、
`after-host-dev`、`final`、`cleanup` 六个检查点。六次均为 adapter/shared/reaper/cleanup/
mount/active lease/shim/VM/Cube Pod 全零，最终开关恢复 `false`，containerd、kubelet、
runtime-resource service 与目标节点健康。同一 reviewer 最终给出
`APPROVE S3.3e DONE`。

### 失败迭代与边界

- `inv-884c1rg5tf`：Kubernetes 1.36 把 `StartError` 放在 terminated state，而早期脚本只
  查询 waiting；改为 waiting/terminated fallback 后重跑。
- `inv-084c8mgfxf`：核心正反例已通过，但早期脚本在 cgroup v2 Guest 上误要求 v1
  `devices.list`；改为按 cgroup 模式分支并诚实记录 v2 不可观测边界。

上述失败轮次均完成 owned Pod 清理、开关恢复和活动资源精确归零。S3.3e 只声明 Guest 内
privileged 双门禁；Host device passthrough、GPU 与生产准入策略不在本阶段范围。

## S3.3f：组合回归与支持矩阵

### exec 安全上下文补齐

实现提交为 `7bf7f09d`，实现 patch SHA-256 为
`b73771d7676a1df4bc6e9c471cce28876d5e2aa45056dba948fdd4c50ff03185`。
CubeShim 的非 TTY exec 现在从 OCI `Process` 到 Agent protobuf 保留五组 capability、
rlimit 和 `noNewPrivileges`，同时保持 TTY 覆盖与既有 UID/GID/additionalGids 顺序语义。
当前 Agent protobuf 无法无损表达的 `user.umask`、`commandLine`、`ioPriority`、
`scheduler` 和 `execCPUAffinity` 在 passfd 分配前 fail-closed；raw OCI ingress 同时识别
规范字段 `/execCPUAffinity` 和当前 oci-spec serde 名 `/execCpuAffinity`，避免 typed
反序列化静默吞字段。AppArmor、OOM score 和 SELinux 仍按首版边界不在 exec 支持范围内。

云端最终构建 `inv-984fnr0n8h` 为 `SUCCESS`，独立构建审计
`inv-b84fx5ght7` 为 `SUCCESS`；证据目录为
`/data/cubelet/s3.3-evidence/s3.3f-exec-build-v5-20260901T072642Z`。四项定向测试
1/1/1/1、Shim 全量测试 164/164、all-targets check 和 release build 全部通过；固定
vendor 为 18,350 个文件，content/tree SHA 分别为 `62479c28…` 和 `7d5d6d47…`。
最终 Shim SHA-256 为
`3c7156524fb62bd595840fd9e4cb306682a98f56b28c96a37623be76fa2770f3`。

部署 `inv-384g480rcx` 与独立部署审计 `inv-884ga1gc5e` 均为 `SUCCESS`；证据目录为
`/data/cubelet/s3.3-evidence/s3.3f-exec-deploy-20260901T074104Z`，旧 Shim 保存在
`/opt/cubesandbox-s33f-predeploy-backup-exec-v1`。部署未重启 containerd，Agent ext4
保持 `87bac7a6…`，部署前后 Cube Pod、Shim、VM 和 active lease 均为 0，节点开关保持
`false`。

### Kubernetes/Guest 组合回归

正式脚本
`CubeShim/sandbox-probe/scripts/verify-s33f-security-combined-cloud.sh` SHA-256 为
`86cc6a1136966cf546d8bb37ed380a2389a69d95895246e56a1c26229a4c247a`；
正式执行 `inv-v84gjpgj7k` 为 `SUCCESS`，证据目录为：

`/data/cubelet/s3.3-evidence/s33f-20260901T075735Z-1024831`

组合回归顺序覆盖 runc/Cube、Strict/Merge、classic init/restartable sidecar/app、
UID/GID/supplemental groups/fsGroup、capability 五集合、RO/RW rootfs、NNP/seccomp、
非 TTY exec、privileged 开关关闭/开启、同 Pod 普通与 privileged 容器、Host `/dev`
负例、非法 capability 和 `runAsNonRoot=true + uid 0`。16 个成功容器均从原始 CRI 与
ctr OCI 重算并绑定 Pod UID；exec 的 UID/GID/groups、capability bounding、
`NoNewPrivs=1` 和 seccomp mode 2 在 runc/Cube 及开关前后相同。

本轮记录 8 个唯一 Cube sandbox，lease record 从 `524` 增至 `532`；每条 record 的
`highWatermark=1`，且恰有一条 inactive tombstone、一个 PREPARE 和一个 RELEASE，
无 active lease。
`before`、`after-off`、`after-on` 和 `cleanup` 的 containers、tasks、sandboxes、
snapshots、netns、Cube shims、VM runtime、adapter、shared、reaper、cleanup marker、
shared mount、active lease 和 runtime-resource 共 14 类集合逐字恢复基线。最终
privileged effective config 与磁盘 fragment 均为 `false`，三项服务 active，Node
Ready 且无 DiskPressure，Cube Pod/Shim/VM/active lease 全为 0。

### 独立审计与冻结边界

独立只读审计脚本
`CubeShim/sandbox-probe/scripts/audit-s33f-security-combined-cloud.sh` SHA-256 为
`972e9962c81dfd4d56916ef2705a5ff6cfd90ef14faec6b8b29dad80786c9a94`；
最终审计 `inv-884huw00ab` 为 `SUCCESS`。审计不使用正式脚本生成的 normalized JSON
作为结论，而是从 16 份 raw CRI/ctr OCI、Guest/exec 文本、Pod 与 CRI sandbox、
lease JSONL、build/deploy evidence 和 live state 重新计算；另验证三类
`StartError`、两类 kubelet no-record、Host `/dev` 的 privileged/hostPath/mountPath
原始 Pod spec，以及 S3.3d 的 direct-bound NNP/seccomp 证据。

最终支持矩阵共 21 项：

- 12 项 `VERIFIED_THIS_RUN`：数值身份与 Strict/Merge groups、init/sidecar/app、
  runtime-specific mount 差异、capability add/drop/CAP 40、RO/RW rootfs、
  NNP/RuntimeDefault、Unconfined、非 TTY exec、privileged 双门禁和 mixed Pod；
- 3 项 `REJECTED`：显式 Host `/dev`、`runAsNonRoot=true + uid 0`、Cube 非法
  capability；
- 3 项 `NOT_SUPPORTED_POC`：Host 自动设备枚举、TTY/stdin、host namespaces/
  Host device passthrough/GPU；
- 1 项 `SUPPORTED_BY_PRIOR_FIXED_EVIDENCE`：S3.3d 的 RuntimeDefault syscall
  causality；
- 2 项 `DEFERRED`：AppArmor/SELinux/procMount/unsafe sysctls，以及 cgroup v2
  Guest `devices.list` 直接观察。

这里的 mixed privileged + ordinary 只证明同一 Cube VM 内 per-container 配置未串扰，
不声明恶意 sibling 隔离；runc 对非法 capability 的输入/Guest 行为只作为对照记录，
拒绝结论属于 Cube fail-closed。

### 失败迭代与恢复

- 构建前两轮分别因 network-none 环境下 rustup 同步和错误 vendor 版本停止；第三轮通过
  raw ingress 测试发现 oci-spec 的 `execCpuAffinity` 派生拼写，修正后才进入最终构建。
- 组合回归前四轮依次修复 shell 局部变量、非 root Guest capability、Merge groups/mount
  预期，并发现 exec NNP 的真实实现缺口；实现重构、重新构建和部署后继续。
- `inv-984gdx0m1d` 发现 kubelet 对已有 `StartError` CRI record 的空日志可返回 rc 0；
  脚本改为记录 rc 并精确要求 stdout 为空，cleanup 的 Pod/目录/lease/全量资源基线和
  开关恢复均为 true。
- 独立审计的失败轮次全部只读，依次收紧预期 trace、Bash `local` 初始化、Pod/CRI
  message 编码和空 ID 集合的序列化表示，未修改正式证据或 live 状态。

同一 reviewer 对实现、构建、部署、正式组合回归和独立审计逐项复核，最终明确给出
`APPROVE S3.3f DONE`。S3.3 SecurityContext 至此完成；资源 requests/limits 与
Host/Guest 双层 cgroup 进入 S3.4。
