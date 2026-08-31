# S2.4 Kubernetes Sidecar 与 Pod 生命周期验收证据

## 结论

S2.4 `DONE`。Kubernetes 1.36 / containerd 2.3.4 的标准 CRI/Sandbox/Task 链路已经在
同一个 Cube VM 内完成原生 sidecar、ephemeral container、startup/readiness/liveness
probe、PostStart/PreStop、优雅退出与超时强杀验证。单容器加入、退出和重建均未更换
Pod UID/IP、Sandbox、Cube VM 或 shim，也未影响同 Pod survivor。

本阶段同时修复 RuntimeResource Cilium TAP 的 vnet header 契约：Go adapter 在
`TUNSETIFF` 后、仍位于 TAP 所属 netns 时设置 12-byte `TUNSETVNETHDRSZ` 并关闭
offload，与 VMM 的 `virtio_net_hdr_v1` 对齐。实现提交为
`df54800044b9dc0fcd764a19fa393ca4eb70f014`；四组验收脚本提交为
`495ac4ca2d0f03fd6ba709ae528829db71f25453`。同一 reviewer 对每个子阶段、网络修复和
最终脚本集均明确 `APPROVE`。

## 固定输入

- shim SHA-256：
  `0b89ae6d33bbe5cb5e10a02ba490fc4d9aae56d768863c30de7712bac242a4d5`。
- `cube-agent.ext4` SHA-256：
  `b1f5d6856ca40b34bfddb9ec6effe889d761734b9f5d98e701842cf0dc4f09f9`。
- RuntimeResource harness SHA-256：
  `26cb87a0f1adb2b2a8f6f0125d4d9eb39661949030d5b8ecda2af53bf37f0ade`。
- 运行环境：本 PoC 创建的 `ins-pl7mznaa` / `vm-200-2-ubuntu`，Kubernetes 1.36.4、
  containerd 2.3.4、Cilium 1.20.0、匹配的 PVM Host/Guest Linux 6.6.69。
- 验收脚本及 SHA-256：
  - `verify-s24-sidecars-cloud.sh`：`b083c854cf52f8ed0bdca03ae509162bd077e5179b7802bcc534a5b7493a77d9`；
  - `verify-s24-ephemeral-cloud.sh`：`1ae4cb5eaacee1ccd81374c24d0f7ee2cfa3ed73e4e8c48d78c691db390e388e`；
  - `verify-s24-probes-cloud.sh`：`bbc7d5fd70f581977fa8c97cf148fc37f26ed5ee0381ad8358fda5be7e1c9b4d`；
  - `verify-s24-lifecycle-cloud.sh`：`c993b5b59bf6cb92fcab301e721f74fef4902fa2f8288c5b7530b73dc598cf63`。

## D1：原生 sidecar

最终 TAT `inv-383kh2g6w4` 为 `SUCCESS`、exit code 0；证据目录为
`/data/cubelet/s2.4-evidence/d1-sidecar-20260831T155901Z`。

- 两个 `restartPolicy: Always` init container 与一个普通 init、Job app 按 Kubernetes
  原生 sidecar 状态机运行；startup gate 证明 app 不会越过未启动完成的 sidecar。
- side-b exit 42 后仅重建 side-b；side-a、Pod UID/IP、Sandbox、shim 和 VM 保持稳定。
- Job app 完成后，主 TaskExit 顺序精确为 app、side-b、side-a；旧 Task/rootfs 均释放。
- 删除后全量资源恢复 baseline，active lease 为 0，durable tombstone 增量为 1。

```text
S24_D1_OK sidecar_startup_gate=ok side_b_exit42_restart=ok job_complete=ok taskexit_order=app,side-b,side-a shim_identity=stable vm_inode=stable
S24_D1_DONE active_leases=0 durable_tombstone_delta=1
```

## D2：ephemeral container

最终 TAT `inv-983kt80r3f` 为 `SUCCESS`、exit code 0；证据目录为
`/data/cubelet/s2.4-evidence/d2-ephemeral-20260831T160952Z`。

- 通过标准 `pods/ephemeralcontainers` 子资源向运行中 Pod 动态加入 debugger，CRI
  Sandbox、Pod UID/IP、shim 和 VM 均未变化。
- debugger 与 app 共享 net/IPC/UTS，拥有独立 Task/rootfs；app 在加入、运行、退出后
  均可 exec，精确 Task 集合没有额外进程。
- debugger exit 47 后连续 22 秒保持相同 terminated 状态、`restartCount=0`，未被重建。
- 请求中的 `targetContainerName=app` 已进入 Kubernetes API，但当前 Cube runtime 不把
  ephemeral container 加入目标容器 PID namespace；该兼容性缺口记录为
  `K8S-OQ-012`，不虚报 TARGET PID 支持。
- 删除后全量资源恢复 baseline，active lease 为 0，durable tombstone 增量为 1。

```text
S24_D2_OK dynamic_join=ok cri_sandbox=ok net_ipc_uts=shared exit47=ok no_restart_22s=ok survivor=ok target_requested=TARGET target_pid=unsupported
S24_D2_DONE active_leases=0 durable_tombstone_delta=1
```

## D3：probe 与 Cilium TAP 修复

修复前诊断 `inv-b83mijghne` 证明 runc Pod 网络正常，而 host→Cube、runc→Cube、
Cube→runc 均失败；Cilium 报 `Unsupported L3 protocol`。抓包发现以太网帧多出 2 bytes：
VMM 写 12-byte `virtio_net_hdr_v1`，RuntimeResource TAP 仍使用 Linux 默认 10-byte
header。Go adapter 此前遗漏了 S0 Rust 路径已有的跨 netns TAP 准备步骤。

修复补丁 SHA-256 为
`8bad4191fcc33d8557d64834100de03a3d0db37489d0a89facc511f27a6c969c`；严格云构建
`inv-983mvhgxik` 与版本化部署 `inv-683n14gk0q` 均为 `SUCCESS`。第一次复测
`inv-883n1ngwp3` 在创建测试 Pod 前因节点 DiskPressure 被驱逐，不计入功能结论；只删除
本 PoC 新生成且已由版本化产物替代的构建目录后，`inv-083n43gr02` 把可用空间恢复到
20 GiB，`inv-a83n97gr9p` 确认 `DiskPressure=False`。

相同四方向网络脚本 `inv-683n9h04ri` 为 `SUCCESS`：host→Cube、host→runc、
runc→Cube、Cube→runc 均返回 HTTP 200；旧的 IPv4 frame shift 消失。IPv4-only
endpoint 对 Guest IPv6 multicast 的丢弃属于预期，不阻塞本阶段。独立基线
`inv-b83nasgiiq` 确认 active lease、shared 和 VM 均为 0。

严格 probe TAT `inv-683nbagv5s` 为 `SUCCESS`、exit code 0；证据目录为
`/data/cubelet/s2.4-evidence/d3-probes-20260831T170109Z`。startup probe 成功前抑制
readiness/liveness；HTTP readiness 从 503 转 Ready；关闭 TCP listener 后 liveness 只
重建 target，旧 target 唯一 exit 66。survivor、Pod UID/IP、Sandbox、shim 与 VM inode
保持稳定。删除后全量 baseline 清洁，tombstone 增量为 1。

```text
S24_D3_OK startup_gate=ok readiness_http=fail_to_ready tcp_liveness=restart target_exit66=ok survivor=stable shim_identity=stable vm_inode=stable
S24_D3_BASELINE_CLEAN wait_attempt=48
S24_D3_DONE active_leases=0 durable_tombstone_delta=1
```

## D4：lifecycle hook 与终止语义

最终 TAT `inv-383nsc0was` 为 `SUCCESS`、exit code 0；证据目录为
`/data/cubelet/s2.4-evidence/d4-lifecycle-20260831T171712Z`。

- 三代 target 各完成一次 PostStart；不对 PostStart 与 entrypoint 的执行先后作错误假设。
- 每次 PreStop 内故意调用同一 handler 两遍，原子目录锁保证每代只产生一次副作用，
  证明 handler 幂等。
- gen1 由 liveness 触发 PreStop→TERM，trap 验证 PreStop marker 已存在后 exit 0；
  Kubernetes lastState 与主 TaskExit 同时绑定旧 container ID。
- gen2 同样先执行 PreStop 并收到 TERM，但保持运行；`/proc/uptime` heartbeat 证明它在
  TERM 后继续存活 3890 ms，随后被 kubelet 在 4 秒 grace 到期时强杀，唯一 exit 137。
- gen3 正常恢复；survivor、Pod UID/IP、Sandbox、shim PID/starttime 与 VM inode 均不变。
- 首轮验收 `inv-983nn209rj` 仅因 protobuf JSON 省略默认值 `exit_status=0` 而失败；
  `inv-v83nrh01um` 独立确认全量基线归零后才运行终验。最终脚本以“精确主 TaskExit
  缺省/显式 0 + kubelet lastState exitCode 0”交叉判定，非零状态仍严格匹配。
- 终验删除后 baseline 在第 43 次 100 ms 轮询恢复，active lease 为 0，durable
  tombstone 增量为 1。

```text
S24_D4_OK poststart=3 prestop_idempotent=2 graceful_exit0=ok stubborn_exit137=ok stubborn_survival_ms=3890 survivor=stable shim_identity=stable vm_inode=stable
S24_D4_BASELINE_CLEAN wait_attempt=43
S24_D4_DONE active_leases=0 durable_tombstone_delta=1
```

## Reviewer 门禁

同一 reviewer 对 D1、D2、D3 网络修复与严格 probe、D4 脚本三轮静态修订、D4 云端
终验及最终仓库脚本集分别给出 `APPROVE`。D4 的两次 `REJECT` 分别补上 grace 存活时间
下界，以及去除 BusyBox 可选 `%N` 依赖；网络诊断也在修复前后使用相同测试矩阵。没有
剩余 must-fix。
