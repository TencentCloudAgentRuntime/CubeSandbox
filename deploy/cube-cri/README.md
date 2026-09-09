# Cube CRI 节点部署

链路：kubelet → 节点现有 containerd CRI → CubeShim → Cubelet RuntimeResource / Guest Agent。

安装节点服务 `cubelet-cri`、Shim、VMM worker（含 Hypervisor/virtiofs）、Agent、Guest 系统与内核、Shim watchdog；containerd 和 ctr 由 TKE 节点提供，不进入构建及部署包。无需 CubeMaster、CubeAPI、Redis、CubeVS、CubeEgress、khaoslet 或 cube-kri。

## 构建

`task --list-all` 查看入口，制品写入 `_output/cube-cri/`。

| 入口 | 产物 / 要求 |
| --- | --- |
| `task build` | 节点服务、Shim、Agent |
| `task build:cubelet` | `bin/cubelet-cri`；Go 版本见 `Cubelet/go.mod` |
| `task build:shim` | `bin/containerd-shim-cube-rs`、`bin/cube-vmm-worker`；Rust 版本见 `CubeShim/rust-toolchain.toml` |
| `task build:agent` | `assets/agent`；使用统一 builder 的 musl/libseccomp |
| `task build:guest` | `assets/guest.img`，内含 cube-init；需要 Docker、e2fsprogs |
| `task build:kernel` | `assets/kernel`；默认使用精简 Guest 内核，设置 `CUBE_GUEST_KERNEL_PROFILE=debug` 才保留 debug/FTRACE/SCHEDSTATS；内置 Istio 流量重定向所需的 `xt_owner` |
| `task build:pvm-host` | `pvm-host.rpm`；PVM 宿主机内核包 |
| `task build:builder` | 仓库统一 builder；已有镜像可直接使用 |
| `task build:all` | Cube 运行时、Guest 系统及内核；宿主机内核单独构建 |

可用 `BUILDER_IMAGE` / `BUILDER_HOME` 指定 builder 与缓存；基础制品也可导入：

```bash
GUEST_KERNEL=/path/to/vmlinux-pvm \
GUEST_IMAGE=/path/to/cube-guest-image-cpu.img \
PVM_HOST_RPM=/path/to/kernel-pvm-host.rpm task assets
```

`task assets` 仅处理已指定的变量；`task package` 校验必需文件，输出带 SHA-256 清单的 `runtime.tar.gz`。

## 安装与测试

默认加载 `local.env` 的 `KUBECONFIG`，可用 `CUBE_CRI_ENV` 指定其他配置。为 Ready 的 TS4 x86_64 节点设置安装标签即可：

```bash
kubectl label node <node> agc.cloud.tencent.com/cube=true

# 使用已有的不可变安装镜像部署；自动准备 PVM，必要时重启节点。
export CUBE_CRI_IMAGE=<仓库>/cube-cri-installer@sha256:<digest>
task deploy

# 或构建运行时、构建并推送安装镜像后部署。
export CUBE_CRI_IMAGE_REPOSITORY=<仓库>/cube-cri-installer
task deploy:all

task test:cri -- --node 10.0.244.89
```

## Helm 安装

面向多节点安装请使用 [Helm Chart](chart/README.md)。`agc.cloud.tencent.com/cube=true` 触发安装 DaemonSet；安装完成后安装器写入 `agc.cloud.tencent.com/cube-ready=true`，`RuntimeClass/cube` 只调度到后者。无需 cordon/uncordon。

从旧单节点 DaemonSet 迁移时，执行 `task deploy` 并确认 Helm DaemonSet Ready，再逐个删除 `app.kubernetes.io/name=cube-cri-installer` 的旧 DaemonSet；删除不会卸载节点运行时或内核。

节点要求 TS4 x86_64、Python 3.11+、crictl、可运行的 containerd 1.7.x 或 2.x。PVM 准备会在必要时安装内核并重启，等待 `/dev/kvm` 和 Node Ready；部署前需结束目标节点上的 Cube Pod。

安装器从 `containerd.service` 的 MainPID 读取实际二进制和启动参数，并直接在默认配置 `/etc/containerd/config.toml` 上增量注入，因此保留其 root/state/socket、CNI、镜像源和 runc 配置：

| 节点版本 | 配置动作 |
| --- | --- |
| 1.7.x | 使用本机 `config dump`，设置 `sandbox_mode = "shim"`、`ENABLE_CRI_SANDBOXES=1` |
| 2.x | 使用本机 `config migrate` 生成对应版本格式，设置 `sandboxer = "shim"`，清除 1.7 实验开关 |

Shim 启动响应按版本适配：1.7 使用 JSON / Task v2，2.0–2.2 使用 JSON / Task v3，2.3 使用 protobuf / Task v3；详见 [2.2 兼容说明](../../docs/zh/dev/cube-shim-containerd22-pr.md)。

安装器直接复用 `/etc/containerd/config.toml`，仅追加或更新 `cube` runtime 段及 2.x 必需的 shim manager 环境；不规范化、不迁移整份节点配置，也不改写 `containerd.service` 的 `ExecStart`。1.7 使用 legacy CRI 表和 `sandbox_mode`；2.x 若默认文件仍是 legacy 格式则保持该格式，由 containerd 迁移，若已是 v3 格式则使用 `sandboxer`。

部署默认给 shim 设置 `CUBE_ALLOW_PRIVILEGED=true`（1.7 通过 systemd 环境变量，2.x 通过 shim manager），同时开启 Cube handler 的两个 `privileged_without_host_devices*` 选项，允许 Guest 内 privileged，保留 Host 设备隔离。

Cube 制品位于 `/opt/cube-cri/releases/<校验和>/`，`current` 指向当前版本；状态位于 `/data/cubelet/cri`。安装会重启 containerd、RuntimeResource 和 watchdog，原配置、drop-in 和上一版本路径备份到 `/opt/cube-cri/backups/`；缺少 `tc` 时安装 `iproute-tc`。

通过 Helm 管理的原生 `apps/v1` DaemonSet 部署：带 `agc.cloud.tencent.com/cube=true` 标签的节点自动安装；安装器在升级开始时移除、仅在运行时与服务检查通过后写入 `agc.cloud.tencent.com/cube-ready=true`。镜像携带运行时制品及 PVM 宿主机内核 RPM，先准备内核、必要时重启，恢复后自动继续安装运行时。已有可用 PVM 内核时跳过内核安装；重启后仍未进入 PVM 内核则报错，避免循环重启。Pod 重建时，同版本跳过安装。删除 DaemonSet 不卸载运行时或内核；节点退役时请先迁移 Cube Pod，再同时移除两个标签。

`CUBE_CRI_IMAGE_REPOSITORY` 指定可推送且节点可拉取的仓库；构建镜像需要 `PVM_HOST_RPM` 指定的内核包，默认 `_output/cube-cri/pvm-host.rpm`。`CUBE_CRI_IMAGE` 可直接使用已有的完整 digest 安装镜像，无需本地制品。`CUBE_CRI_NAMESPACE`、`CUBE_CRI_RELEASE` 分别指定 Helm 命名空间和 release；`CUBE_CRI_IMAGE_PULL_SECRET` 指定同命名空间已有的拉取凭据。`task deploy` 在 Helm 安装前直接 apply `RuntimeClass/cube`，不接管该资源。安装失败可查看 DaemonSet Pod 日志及宿主机 `/var/lib/cube-cri/installer/<Pod UID>/install.log`。

账号需有 DaemonSet、特权 Pod、RuntimeClass 和节点标签权限，无需 exec 或 SSH 密钥。原默认内核保存在 `/var/lib/cube-cri/pvm/previous-default-kernel`；`reboot-request` 记录本次内核包与启动 ID，排查并修复启动配置后可删除该记录重试。

Pod 测试覆盖 init、EmptyDir、双容器共享网络、HTTP readiness、日志、exec 和 overhead，完成后清理；证据位于 `_output/cube-cri/tests/`。原版 1.7 的实验性 CRI 开关也影响默认 runc，验证范围见 [自动适配验收](../../docs/zh/dev/cube-cri-containerd-auto-pr.md)。

`task test:pvm` 使用 builder 容器验证安装、重复执行、重启失败保护及缺包诊断，不修改本机内核。
