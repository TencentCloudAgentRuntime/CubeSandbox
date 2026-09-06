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
| `task build:kernel` | `assets/kernel`；PVM Guest 内核 |
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

默认加载 `local.env` 的 `KUBECONFIG`，可用 `CUBE_CRI_ENV` 指定其他配置；必须显式指定节点：

```bash
export CUBE_CRI_IMAGE_REPOSITORY=<仓库地址>/cube-cri-installer
task deploy:all -- --node 10.0.244.89

# 使用已有制品部署；自动准备 PVM，必要时重启节点。
task deploy:runtime -- --node 10.0.244.89
task test:cri -- --node 10.0.244.89

# 可选：只准备 PVM 内核，同样通过 DaemonSet 执行。
task deploy:prepare -- --node 10.0.244.89
```

节点要求 TS4 x86_64、Python 3.11+、crictl、可运行的 containerd 1.7.x 或 2.x。PVM 准备会在必要时安装内核并重启，等待 `/dev/kvm` 和 Node Ready；部署前需结束目标节点上的 Cube Pod。

安装器从 `containerd.service` 的 MainPID 读取实际二进制、配置路径和启动参数，保留其 root/state/socket、CNI、镜像源和 runc 配置：

| 节点版本 | 配置动作 |
| --- | --- |
| 1.7.x | 使用本机 `config dump`，设置 `sandbox_mode = "shim"`、`ENABLE_CRI_SANDBOXES=1` |
| 2.x | 使用本机 `config migrate` 生成对应版本格式，设置 `sandboxer = "shim"`，清除 1.7 实验开关 |

Shim 启动响应按版本适配：1.7 使用 JSON / Task v2，2.0–2.2 使用 JSON / Task v3，2.3 使用 protobuf / Task v3；详见 [2.2 兼容说明](../../docs/zh/dev/cube-shim-containerd22-pr.md)。

生成配置为 `/etc/cube-cri/containerd.toml`，检测结果为同目录 `containerd.json`；原配置保留，systemd drop-in 指向原二进制和生成配置。相对 imports 保持原路径含义，并去除 1.7 `config dump` 附带的源文件自导入；生效配置由原二进制再次校验。

部署默认给 shim 设置 `CUBE_ALLOW_PRIVILEGED=true`（1.7 通过 systemd 环境变量，2.x 通过 shim manager），同时开启 Cube handler 的两个 `privileged_without_host_devices*` 选项，允许 Guest 内 privileged，保留 Host 设备隔离。

Cube 制品位于 `/opt/cube-cri/releases/<校验和>/`，`current` 指向当前版本；状态位于 `/data/cubelet/cri`。安装会重启 containerd、RuntimeResource 和 watchdog，原配置、drop-in 和上一版本路径备份到 `/opt/cube-cri/backups/`；缺少 `tc` 时安装 `iproute-tc`。

通过原生 `apps/v1` DaemonSet 部署：镜像携带运行时制品及 PVM 宿主机内核 RPM，先准备内核、必要时重启，恢复后自动继续安装运行时。已有可用 PVM 内核时跳过内核安装；重启后仍未进入 PVM 内核则报错，避免循环重启。每个节点对应独立 DaemonSet，多次部署更新同一对象；Pod 重建时，同版本跳过安装。宿主机服务仍由 systemd 管理；删除 DaemonSet 不卸载运行时或内核。

`CUBE_CRI_IMAGE_REPOSITORY` 指定可推送且节点可拉取的仓库；构建镜像需要 `PVM_HOST_RPM` 指定的内核包，默认 `_output/cube-cri/pvm-host.rpm`。`CUBE_CRI_IMAGE` 可直接使用已有的完整安装镜像（建议 digest），无需本地制品。`CUBE_CRI_NAMESPACE` 指定命名空间，`CUBE_CRI_IMAGE_PULL_SECRET` 指定同命名空间已有的拉取凭据。实际清单保存到 `_output/cube-cri/cube-cri-<节点哈希>.json`，安装失败可查看 Pod 日志及宿主机 `/var/lib/cube-cri/installer/<Pod UID>/install.log`。

账号需有 DaemonSet、特权 Pod、RuntimeClass 和节点标签权限，无需 exec 或 SSH 密钥。原默认内核保存在 `/var/lib/cube-cri/pvm/previous-default-kernel`；`reboot-request` 记录本次内核包与启动 ID，排查并修复启动配置后可删除该记录重试。

Pod 测试覆盖 init、EmptyDir、双容器共享网络、HTTP readiness、日志、exec 和 overhead，完成后清理；证据位于 `_output/cube-cri/tests/`。原版 1.7 的实验性 CRI 开关也影响默认 runc，验证范围见 [自动适配验收](../../docs/zh/dev/cube-cri-containerd-auto-pr.md)。

`task test:pvm` 使用 builder 容器验证安装、重复执行、重启失败保护及缺包诊断，不修改本机内核。
