# S1.4 清理与共存验收证据

> 状态：`DONE`。实现、严格构建和全部云端运行矩阵已通过；同一 reviewer 最终 `APPROVE`。

## 实现范围

- CubeShim 在 `StartSandboxResponse.spec` 返回 containerd 兼容的 OCI `Any`：
  `type_url=types.containerd.io/opencontainers/runtime-spec/1/Spec`，`value` 为已合并 CRI
  annotation 的 OCI Spec JSON。Sandbox 生命周期保存首次 Create 的确定性副本，重试不会
  返回空 Spec。
- 新增默认 runc、Job、Deployment、强制删除、创建中取消、100 Pod 循环、legacy
  Cubebox race test 和 legacy unmanaged CubeShim 数据面验收脚本。
- legacy rootfs probe 对动态 virtio-fs 目录项使用 5 秒最终可见窗口，并把残留检查限制在
  本探针拥有的 `s02-*` 路径；只有在精确 owned target 及子挂载都已脱离后才删除目录，
  失败时保留现场并令验收失败。Kubernetes 矩阵新增 `/run/vc/vm` 前后集合门禁。

## 云端源码、构建和部署

只使用本 PoC 创建的香港构建/控制平面节点 `ins-pl7mznaa`、运行节点
`ins-4dyul5ag` 和私有 COS `cubesandbox-k8s-poc-20260831-1251707795`。

- 最终 shim 源码归档 COS key `s14/source/s14-sandbox-spec-v1-source.tar.gz`，SHA-256
  `ce5f7106636475fd15550dbb3a444299ae28336db03f314ffcc19c5e72f5e908`；包含 S1.3
  最终 `standard_rootfs.rs` 和本次 `sandbox_srv.rs`。
- 严格构建 `inv-a83cu30ran` 为 `SUCCESS`：CubeShim lib tests、all-targets check 和
  release build 均通过。最终 shim SHA-256 为
  `39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd`。
- 部署 `inv-a83cxjgftm` 为 `SUCCESS`：稳定路径
  `/opt/cubesandbox-s14-runtime-artifacts-sandbox-spec-v1/containerd-shim-cube-rs` 与
  `/usr/local/bin/containerd-shim-cube-rs` SHA 一致；CRI、API server 和节点均 Ready，
  默认 runc 未改。

## Sandbox Spec 兼容性

定向终验 `inv-983d0j0cbd` 为 `SUCCESS`，证据目录
`/data/cubelet/s1.4-evidence/sandbox-spec-20260831T114230Z`：

```text
S14_SANDBOX_SPEC_OK sandbox=9fef4e... type_url=types.containerd.io/opencontainers/runtime-spec/1/Spec json=ok warnings=0 shim_sha256=39b68b... evidence=/data/cubelet/s1.4-evidence/sandbox-spec-20260831T114230Z
```

`ctr sandboxes info` 中 Runtime 为 `io.containerd.cube.rs`、Sandboxer 为 `shim`；Spec
可由 base64 解出合法 OCI JSON，CRI sandbox name 正确。显式执行 `crictl inspectp`
后，containerd journal 中 `failed to unmarshal sandbox spec` 计数为 0。

## Kubernetes 清理与共存矩阵

最终 smoke `inv-083ehrgqpm` 为 `SUCCESS`，证据目录
`/data/cubelet/s1.4-evidence/smoke-20260831T123459Z`。实际 payload 先输出并断言
仓库脚本 SHA-256 `10de29a3fbb39d14fd8cf94e41ee41b0e1f4083f2d865d837188dda3ad3523ca`：

```text
S14_REVIEW_V2_PAYLOAD_OK kind=smoke sha256=10de29a3...
S14_RUNC_DEFAULT_OK sandbox=af2982... runtime=io.containerd.runc.v2
S14_JOB_OK completion=success logs=ok
S14_DEPLOYMENT_OK replicas=1 logs=ok exec=ok
S14_FORCE_DELETE_OK elapsed_ms=48
S14_CREATE_CANCEL_OK sandbox=76571f... observed_state=CONTROLLER_CREATE_INFLIGHT fault=runtime-resource-stop-cont
S14_SMOKE_MATRIX_OK evidence=/data/cubelet/s1.4-evidence/smoke-20260831T123459Z active_leases=0 lease_records=238 vm_runtime=baseline sandbox_spec=ok warnings=0 shim_sha256=39b68b...
```

创建中取消通过 `SIGSTOP/SIGCONT` 暂停本 PoC RuntimeResource service，确定性命中
CreateSandbox in-flight 窗口。每个 case 删除后 container、Task、Sandbox、snapshot、
netns、adapter、shared/reaper、mount、shim/reaper process 和 active lease 均恢复前置
基线；`/run/vc/vm` 中 Guest workdir/socket 的完整相对路径和文件类型集合也恢复基线。
不指定 `runtimeClassName` 的 Pod 使用 `io.containerd.runc.v2`，没有 CubeShim 进程。

## 100 Pod 循环

最终循环 `inv-883ep9gvt6` 为 `SUCCESS`，证据目录
`/data/cubelet/s1.4-evidence/loop100-20260831T124051Z`。实际 payload SHA-256 为
`cf126ac1cfc661e4862174fcb77da304f4d544e6a1e60b64cf2e6c309e3c950f`：

```text
S14_REVIEW_V2_PAYLOAD_OK kind=loop100 sha256=cf126ac1...
S14_LOOP_BATCH_CLEAN batch=01 ... lease_records=248
...
S14_LOOP_BATCH_CLEAN batch=10 ... lease_records=338
S14_100_LOOP_OK total=100 batch_size=10 unique_sandboxes=100 active_leases=0 durable_tombstone_delta=100 vm_runtime=baseline shim_sha256=39b68b... evidence=/data/cubelet/s1.4-evidence/loop100-20260831T124051Z
```

10 批各并发 10 个 Pod；每批删除后全量运行资源恢复基线，100 个 Sandbox ID 均唯一。
每个已释放 Sandbox 恰好增加一条 `active=null` durable tombstone，这是 S1.1 已接受的
generation fencing 元数据而非活动资源；其生产保留/压缩策略记录为 `K8S-OQ-010`。

## Legacy 回归

Cubebox 包级回归 `inv-b83ejs0618` 在 `ins-4dyul5ag` 为 `SUCCESS`，证据目录
`/data/cubelet/s1.4-evidence/legacy-cubebox-tests-20260831T123708Z`。实际 payload
SHA-256 为 `679d3a20c9fa50509717dd61dc3265cd099c335337198de4611ea3443498fc54`：

```text
S14_REVIEW_V3_PAYLOAD_OK kind=legacy-cubebox sha256=679d3a20...
S14_LEGACY_CUBEBOX_TESTS_OK source_tree=a9c4cc3bcd7a8d7ab4362e142f3e77df88946045 cubecow=offline cubevs_bpf=generated race=passed evidence=/data/cubelet/s1.4-evidence/legacy-cubebox-tests-20260831T123708Z
```

脚本验证 `git write-tree` 和 tree object 类型后，直接以 `git archive` 从固定 tree
`a9c4cc3b...` 构造工作目录；云端工作树中的 tracked 修改、untracked 和 ignored BPF
生成物均不会进入测试输入。cubecow
锁定 vendor 的 COS key 为 `s14/deps/s14-cubecow-vendor.tar.gz`、SHA-256
`9469425277208579f969da435dac33e9a1dcf04add893c4b3abc97e704cc63ab`；Go vendor v2
key 为 `s14/deps/s14-cubelet-go-vendor-v2.tar.gz`、SHA-256
`1bd2bfdec14081e273a3ae8ee65623397771807b92cfced037b82dfd0b4b7c25`。云端离线
构建 cubecow、生成 CubeNet BPF，并通过 `go test -race -count=1 ./services/cubebox`。

最终 unmanaged 数据面 `inv-683f0pg8ge` 在 `ins-pl7mznaa` 为 `SUCCESS`，证据目录
`/data/cubelet/s1.4-evidence/legacy-shim-20260831T125055Z`。wrapper payload SHA-256 为
`63b6808b9828ecc4e9e2b44bbfd54dd162c51c0b568c3f3278ad8ff5227d5b41`：

```text
S14_REVIEW_V4_PAYLOAD_OK kind=legacy-shim sha256=63b6808b...
S0_2_ROOTFS_PROBE_OK
CYCLE_MATRIX_OK cycles=20
DYNAMIC_MOUNT_MATRIX_OK
STANDARD_OCI_ROOTFS_OK
S14_LEGACY_SHIM_OK cycles=20 standard_rootfs=ok dynamic_mount=ok tasks=0 containers=0 mounts=0 vm_runtime=0 shims=0 shim_sha256=39b68b... evidence=/data/cubelet/s1.4-evidence/legacy-shim-20260831T125055Z
```

最终 probe 的 COS key 为 `s14/review-v2/s14-rootfs-probe-v3.sh`、SHA-256
`5f6b55492171ae0e5bd3e6c9fb5215beb9e8119b6ad691578dcd9ff021632b9b`。节点上既有
`s03-cni` mount 属于前序 S0.3 基线；wrapper 只检查和清理 `s02-*` owned children，
不删除共用 share 根。清理只有在 exact target/descendant 全部脱离后才删除目录，失败
则保留并让验收失败。`/run/vc/vm/s02-*` 为 0，主 CRI 在回归前后均为 RuntimeReady。

以上最终脚本分别固定在私有 COS `s14/review-v2/`、`s14/review-v3/` 和
`s14/review-v4/`。本地 `/tmp` 历史草稿和更早 invocation 不作为验收证据；每个最终
TAT 都在运行前打印并断言下载文件的精确 SHA。

## 审查门禁

同一 reviewer 逐轮检查实现、脚本、证据和验收边界，并要求补齐安全 unmount、固定
Git tree 输入、`/run/vc/vm` 基线、主 CRI 前后 Ready 和到期 OQ。所有修订均重放受影响
矩阵；最终结论为 `APPROVE`，无剩余 must-fix issue。实现提交为
`517c62b309edcc25d890de26a6495a6b07517ada`。
