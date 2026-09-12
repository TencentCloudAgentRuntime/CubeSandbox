# AGC-37：Cube/runc `t_agent` 测试方案

## 结论先行

本方案只回答一个问题：在真实 Coding Agent 终端工作负载下，Cube/PVM 相比 runc 增加多少端到端 Agent 运行时长。主指标 `t_agent` 从 Pi 启动至退出；Pod 启动、镜像准备、测试和控制端编排另报，不混入该指标。

Terminal-Bench 的任务文件和 runner 一律不改；只在其外层调用前后记录时间。

## 指标与边界

| 指标 | 起止边界 | 时钟 | 用途 |
| --- | --- | --- | --- |
| `t_agent` | Pi 进程启动前 → Pi 进程退出后 | Agent 容器内 `CLOCK_MONOTONIC` | 唯一主指标 |
| `t_verify_official` | 原始任务验证入口启动前 → 退出后 | Agent 容器内 `CLOCK_MONOTONIC` | 正确性与验证诊断 |
| `t_validation_warm` | 预置依赖后运行原始最终测试命令 | 验证容器内 `CLOCK_MONOTONIC` | 快速诊断，不参与主结论 |
| `t_trial_observed` | 控制端发起 Agent 执行 → 验证结束 | 控制端 `CLOCK_MONOTONIC` | 观察 exec/编排影响 |
| `t_e2e_observed` | 提交 Pod → 验证结束 | 控制端 `CLOCK_MONOTONIC` | 观察调度、准备与执行总路径 |

`t_agent` 包含 Pi 初始化、模型等待、工具调用和输出收尾；不包含 Pod 调度、镜像拉取、工作区快照和验证。不同容器或不同机器的时间戳不得相减。

## Terminal-Bench 的无侵入执行

1. 用锁定的 Terminal-Bench 任务环境创建候选 Pod；runc 与 Cube 仅 `runtimeClassName` 不同。
2. 外层 `agent-run.sh` 在启动 `pi` 前和 Pi 子进程退出后记录单调时钟并保存 `t_agent`；它不实现或修改 Pi 行为。
3. Pi 结束后才把锁定的测试文件放入共享工作区，并在同一 Agent 容器原样调用任务的 `run-tests.sh`；外层只记录 `t_verify_official`，不改脚本、测试或退出码。
4. 验证通过才表示该次任务成功；Pi 退出码和验证结果均须保存。

验证脚本本身不改。为消除外网波动，镜像预存并校验原始 `run-tests.sh` 所下载的固定 uv 安装脚本、tarball 及任务声明的 `uv pip install ...` 依赖解析缓存；验证外层仅为 uv 指定该缓存和离线模式。对已在镜像中的 apt 包，验证外层回放 `apt-get update`，并在包已安装时让 `apt-get install ...` 成功返回；其他 apt 请求仍执行原命令。该模式记为 `terminal-original-hermetic`：它执行原始 runner，但将固定依赖下载替换为已校验缓存，不把下载网络波动计入验证诊断，更不计入 `t_agent`。其他依赖的任务必须先补充锁定缓存并在 manifest 记录。

若原始任务镜像因上游 Ubuntu 源临时 502 无法构建，可在外层构建临时副本中替换为 `https://mirrors.tencent.com/ubuntu`。该 workaround 只发生在临时 build context，原始 Terminal-Bench 任务不被修改；是否启用必须写入 image manifest。

若验证入口是 `tests/run-tests.sh`，则原样运行它；若任务本身指定 `tests/run-uv-pytest.sh`，则原样运行该脚本。不得为了适配 Cube/runc 改写任务 runner。

### warm 验证的含义

`t_validation_warm` 指依赖已固定在镜像或缓存后，调用任务原始最终测试命令的耗时。例如任务本身若指定 `tests/run-uv-pytest.sh`，则可在 warm 诊断中原样调用该脚本。它只在任务存在可分离的 warm 路径时记录，可用于快速确认结果及排查文件系统、依赖或 CPU 问题；但它省略了完整 harness 的准备路径，因此不能代表完整官方 harness 或任务总耗时。

它不是 `t_agent`，也不进入 Cube/runc 的主统计。正式成功判定仍以未改动的任务验证入口完成的结果为准。

## 固定条件

- runc 与 Cube 固定在同一 TS4/PVM 节点，串行执行；当前节点为 `172.17.209.85`。
- 固定镜像 digest、任务锁文件、工作区快照、Pod CPU/内存、Pi 版本、模型、超时和模型连通性。
- 每次使用新 Pod、新工作区和新 Pi 状态，不恢复会话。
- 本轮不要求 ServiceAccount 或网络隔离；两模式的 Pod 配置必须一致，除 `runtimeClassName` 外不得有差异。
- Host 路径不进入主比较；如保留，仅作为独立的特权 chroot 诊断。

## 任务范围与预检

不以 Terminal-Bench 总分或 Agent 能力为目标，也不直接跑完整任务集。仅选择能让 Agent 反复经历 shell、fork/exec、文件 I/O、编译、服务进程和测试循环的任务；排除以 GPU 训练、纯模型推理、纯数据处理或单次长计算为主的任务。

候选池、分层和筛选规则见 `task-matrix.t-agent.json`。先在每个候选任务上各跑一次 runc 和 Cube；正式集目标为至少 8 个任务，且构建/调试、系统运维各至少 3 个、安全至少 2 个。不使用 `swe-*` 或 SWE-Bench 类任务；这里的“构建/调试”指普通终端构建、调试、测试工作负载，不是 SWE 评测。

进入正式集须同时满足：镜像可复建、Pi 可完成、原始验证入口可运行、两模式至少各一次验证通过，且 Pi 轨迹确有多轮终端操作或构建/服务/测试活动。

| 基准 | 任务 | 覆盖类型 | 状态 |
| --- | --- | --- | --- |
| Terminal-Bench | `build-tcc-qemu` | C 工具链编译与调试 | 排除：4.5 GiB 镜像触发目标节点磁盘压力 |
| Terminal-Bench | `modernize-fortran-build` | 代码修改、构建与测试 | 预检通过：runc `39.74s`，Cube `41.58s` |
| Terminal-Bench | `sqlite-with-gcov` | C/C++ 构建、覆盖率与测试 | 排除：Cube 预检 900 秒超时、验证失败 |
| Terminal-Bench | `polyglot-c-py` | C/Python 编译与互操作 | 排除：runc 原始验证失败（残留 cmain） |
| Terminal-Bench | `debug-long-program` | 调试与多服务交互 | 暂不支持：任务声明 2 个服务，当前外层 harness 只支持单 client 服务 |
| Terminal-Bench | `build-pmars` | 编译、命令行构建与测试 | 排除：runc 预检 900 秒超时、验证失败 |
| Terminal-Bench | `nginx-request-logging` | 服务配置、启动与调试 | 排除：runc 通过，Cube 900 秒超时且验证失败 |
| Terminal-Bench | `configure-git-webserver` | Web 服务配置与进程操作 | 排除：runc 通过，Cube Pi 退出 0 但原始验证失败 |
| Terminal-Bench | `qemu-startup` | 系统启动与多进程操作 | 待预检 |
| Terminal-Bench | `jupyter-notebook-server` | 服务启动、配置与调试 | 排除：runc 预检 900 秒超时、验证失败 |
| Terminal-Bench | `db-wal-recovery` | SQLite/WAL 恢复与文件分析 | 暂不支持：`task.yaml` 指令格式不符合当前外层解析器 |
| Terminal-Bench | `openssl-selfsigned-cert` | 证书与 OpenSSL 工具链 | 预检通过：runc `63.73s`，Cube `65.27s` |
| Terminal-Bench | `new-encrypt-command` | 加密命令实现与验证 | 预检通过：runc `18.92s`，Cube `38.57s`；低强度补充样本 |
| Terminal-Bench | `fix-code-vulnerability` | 漏洞修复、代码修改与测试 | 预检通过：runc `47.81s`，Cube `80.53s` |
| Terminal-Bench | `crack-7z-hash` | 密码学工具与命令行分析 | runc 通过 `140.53s`；Cube 未到 Pi 阶段，等待 Pod Ready 超时 |

当前仅 4 个任务形成双侧成功预检，尚未达到正式实验门槛。上表中的秒数只是单次独立 Agent 轨迹，不代表 Cube 纯运行时开销；正式结论必须等每任务 6 个成功配对后再给。

## 正式实验

- 每个预检通过任务做 6 个配对：3 轮 `runc → Cube`、3 轮 `Cube → runc`。
- 一轮仅在两侧 Pi 退出码均为 0 且原始验证均通过时进入配对统计；失败、超时和基础设施错误保留并单独报告。
- 每次保存任务与轮次、运行顺序、镜像 digest、Pod 配置、Pi/模型版本、`t_agent`、验证结果、token、response 数、工具调用和资源采样。

## 分析与交付

- 对每个任务的 6 个配对分别报告 `Cube/runc - 1`、绝对差、中位数、P25/P75 和原始值。
- 跨任务仅报告分层分布及任务加权/非加权汇总，不把不同任务轨迹合并解释为纯运行时因果效应。
- 小样本 bootstrap 只表示经验重采样敏感度，不称为可泛化的 95% 置信区间。
- 若两侧 token、response 数或工具调用显著不同，结论只能描述为“完整 Agent 轨迹差异”；要估计纯运行时开销，需另做 trace replay。
- 每个 case 保留脱敏 Pi 事件、资源采样、验证日志、结果 manifest 与锁文件；报告应可在无模型密钥条件下重算。
