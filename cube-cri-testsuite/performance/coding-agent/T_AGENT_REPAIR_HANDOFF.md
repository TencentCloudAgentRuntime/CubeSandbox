# AGC-37：Terminal-Bench 问题项修复 Handoff

## 目标

把 `T_AGENT_TEST_PLAN.md` 中未形成双侧成功预检的 Terminal-Bench 候选项逐项跑起来，扩大正式 `t_agent` 任务集。

本工作不追求修改任务答案，也不追求提高 Pi 解题能力。每个 case 的目标是判断并修复以下问题之一：

- 测试环境问题：镜像、磁盘、网络缓存、节点状态、运行时类、资源配额。
- 外层 harness 问题：任务解析、服务编排、验证缓存、工件采集。
- Cube CRI 语义缺口：Pod 启动、容器 exec、进程/信号、网络、文件系统、cgroup、权限等行为与 runc 不一致。
- Agent 路径差异：Pi 在 Cube 下走了不同操作轨迹，导致超时或验证失败；这类只能作为现象记录，不能直接归因到运行时。

## 基本原则

- Terminal-Bench 原始任务目录和 runner 不做侵入修改。
- 允许在外层 build context 使用临时镜像源替换、依赖缓存、镜像预导入和环境修复；必须写入 image manifest。
- 允许扩展本目录的外层 harness，以支持更多标准任务形态；扩展应保持原始 `run-tests.sh`、`tests/` 和任务语义不变。
- 先在 runc 复现，再跑 Cube。runc 失败时不进入 Cube 性能对照，只做任务可用性排查。
- 每次失败都保留完整工件，不用口头结论替代证据。
- 涉及 Cube CRI 代码改动时，必须到测试集群做针对性复测，满足本文件对应验收标准后才算完成。

## 当前基线

已形成双侧成功预检的任务：

| 任务 | 分类 | 备注 |
| --- | --- | --- |
| `modernize-fortran-build` | build_debug | 可进入正式配对。 |
| `openssl-selfsigned-cert` | security | 可进入正式配对。 |
| `new-encrypt-command` | security | 可作为低强度补充样本，正式汇总需单独标注。 |
| `fix-code-vulnerability` | security | 可进入正式配对。 |
| `crack-7z-hash` | security | 2026-09-12 复跑通过，可进入正式配对。 |
| `debug-long-program` | build_debug | 2026-09-12 通过 sidecar harness 复跑通过，可进入正式配对。 |
| `build-pmars` | build_debug | 2026-09-12 通过 Debian mirror workaround 与 Cube retry 复跑通过，可进入正式配对。 |
| `nginx-request-logging` | system_operations | 2026-09-12 通过 Debian mirror workaround 复跑通过，可进入正式配对。 |
| `jupyter-notebook-server` | system_operations | 2026-09-12 通过 Debian/PyPI mirror workaround 复跑通过，可进入正式配对。 |
| `processing-pipeline` | system_operations | 2026-09-12 通过 Ubuntu mirror workaround 复跑通过，可进入正式配对。 |

当前已形成 10 个双侧成功预检任务，已满足总数下限和 build_debug、system_operations、security 分类下限。阶段 5 已完成 9 个正式任务，并满足 build_debug、system_operations、security 分类下限；`db-wal-recovery`、`qemu-startup`、`configure-git-webserver`、`sqlite-with-gcov` 继续作为问题项保留，不阻塞正式集。

## 当前进展

2026-09-12 已完成以下推进：

- 阶段 0 基础检查：按 `local.env` 配置后，目标节点 `172.17.209.85` 为 `Ready=True`、`DiskPressure=False`，`runc` 与 `cube` RuntimeClass 均存在。
- 阶段 2 部分完成：`run-terminal-case.sh` 已改为通过 `scripts/extract-instruction.py` 使用 YAML parser 读取 `instruction` 字段，不再只支持 `instruction: |-`。
- `db-wal-recovery` 已复跑：runc 通过，`t_agent=109.17s`；Cube 进入 Pi 阶段后 900 秒超时，原始验证失败，未生成 `recovered.json`。工件位于 `_output/agc37-terminal-repair/db-wal-recovery/`。
- `db-wal-recovery` 已做最小命令对照：同镜像 sleep Pod 中执行 Cube 失败轮末尾同类全盘 `grep -R ... | head -100`，runc 约 2.59s、Cube 约 10.10s，均正常退出；暂未发现 grep/pipe 语义死锁。
- `crack-7z-hash` 已复跑：Cube Pod Ready 阻塞未复现，Cube 预检通过，`t_agent=168.97s`。该任务当前已形成双侧成功预检。
- `debug-long-program` 已复跑：外层 harness 使用 sidecar 启动 `program` 服务，并通过 hostAlias 保持原始任务里的 `http://program:8008` 访问语义；runc `t_agent=216.35s`，Cube `t_agent=256.31s`，二者原始验证均通过。
- `configure-git-webserver` 已补充对照：原 Cube Pi 轨迹使用 `ubuntu + dropbear + python http.server`，未满足官方验证的 `git@localhost` + password 入口；手动执行官方 `solution.sh` 时，runc 通过官方验证，Cube 在 `apt-get install git nginx openssh-server` 覆盖 `libcap2` 时出现 `Stale file handle`。最小复现已收敛为同镜像同节点执行 `apt-get update && apt-get install -y --reinstall libcap2`：runc 成功，Cube `rc=100`，dpkg 状态为 `iUR`。
- `sqlite-with-gcov` 已补充归因：Cube Pi 为安装构建工具触发 apt/dpkg 覆盖文件失败，先在 `dpkg` 包升级时报 `/usr/bin/dpkg.dpkg-tmp: Stale file handle`，后续缩小安装集仍在 `libgcc-s1` 覆盖 `/usr/lib/x86_64-linux-gnu/libgcc_s.so.1.dpkg-tmp` 时报同类错误；最终 `sqlite3` 未进入 PATH，官方验证 3 项失败。
- `nginx-request-logging` 已复跑通过：原失败由 `deb.debian.org` apt update 长时间卡住导致，最小对照中 runc/Cube 都在 300 秒超时；切换腾讯 Debian 镜像后 runc `apt-get update` 约 2.18s，Cube 约 5.84s。基于该 workaround 重建镜像后，runc `t_agent=51.75s`、Cube `t_agent=433.26s`，二者原始验证均通过。
- `polyglot-c-py` 已补充对照：旧 runc Pi 写出的答案可运行，但自测留下 `/app/polyglot/cmain`，官方测试要求目录内仅有 `main.py.c`，因此失败。手动执行官方 `solution.sh` 后，runc 与 Cube 均通过官方验证；该项旧失败归类为 Agent 收尾未清理构建产物，不是 Cube CRI 能力缺口。
- `jupyter-notebook-server` 已复跑通过：旧 runc Pi 卡在 `pip install notebook matplotlib`，900 秒超时。外层 build 脚本新增 PyPI mirror workaround，并和 Debian mirror 一起写入 manifest；重建镜像后 runc `t_agent=429.39s`，Cube retry `t_agent=452.02s`，二者原始验证均通过。Cube 第一次 mirror 轮服务和 notebook 通过，但配置文件缺少测试可识别 password hash，属于 Agent 路径波动，第二轮通过。
- `build-pmars` 已复跑通过：旧 runc 卡在慢 Debian 源与缺少 `dpkg-source` 的迭代中，900 秒超时。切换 Debian HTTP 镜像后 runc `t_agent=311.13s`，原始验证通过。Cube `cube-mirror-v1` 曾因 Agent 将 `debian/` 留在 `/app/debian` 而验证失败；2026-09-12 `cube-mirror-v3` 复跑通过，`t_agent=794.58s`，官方 4 项验证全通过。
- `processing-pipeline` 已复跑通过：使用 Ubuntu mirror workaround 重建镜像，runc `t_agent=61.48s`，Cube `t_agent=44.34s`，官方 9 项验证均通过。该任务补齐 system_operations 分类下限。
- `db-wal-recovery` 追加 retry：2026-09-12 `cube-retry-v1` 在 Pod 调度/启动阶段因节点瞬时 `DiskPressure` 被 kubelet Evicted，未进入 Pi 阶段；`cube-retry-v2` 在节点 `Ready=True`、`DiskPressure=False` 下复跑，仍 900 秒超时，原始验证 7 项均因缺少 `/app/recovered.json` 失败，`t_agent=900.26s`。
- `qemu-startup` 已推进到运行时对照：`repair5` 镜像通过禁用 bullseye-security、关闭 `Valid-Until` 检查、预降级 `perl-base=5.32.1-4+deb11u3` 后可构建并导入节点。runc Agent 轮 Pi 退出 0，但原始验证失败；Cube Agent 轮 900 秒超时。手动执行官方 `solution.sh` 后，runc 与带正式资源配置的 Cube Pod 均通过原始验证。此前 Cube 手动对照中的 qemu `-m 1024` 内存失败是诊断 Pod 未设置 resources 导致，带 `4Gi` limit 的 Cube Pod 中 qemu `-m 3072` 也可启动。
- 阶段 5 已启动：`processing-pipeline` 和 `openssl-selfsigned-cert` 各完成 12 条正式记录、6 个成功配对、无 unpaired；`new-encrypt-command` formal-v1 仅 3 个成功配对，失败轮为 Agent 认为 `rencrypt` 不安全并要求确认，未生成 `/app/encrypted_data/*`，不计为完成任务。
- `modernize-fortran-build`、`fix-code-vulnerability` 和 `crack-7z-hash` 已完成正式配对；其中 `crack-7z-hash` 12 条正式记录、6 个成功配对、无 unpaired，`t_agent` 中位相对变化 `+156.20%`，存在两轮 Cube Agent 长尾。
- `debug-long-program` 已完成正式配对：12 条正式记录、6 个成功配对、无 unpaired，`t_agent` 中位相对变化 `-29.66%`。正式运行中 cube r3/r5 各出现一次 Pi 前 init `StartError`，错误为 container create ttrpc timeout；缺失 cube 侧已补跑，启动失败证据保留在 `orchestration-failures.jsonl`。
- `nginx-request-logging` 已完成正式配对：12 条正式记录、6 个成功配对、无 unpaired，`t_agent` 中位相对变化 `+339.83%`；Cube 侧多轮出现 Agent 长尾，但原始验证均通过。
- `jupyter-notebook-server` 已完成正式配对：12 条正式记录、6 个成功配对、无 unpaired，`t_agent` 中位相对变化 `+151.72%`。阶段 5 正式完成任务数达到 8 个，满足验收下限。
- `build-pmars` 已完成正式配对：12 条正式记录、6 个成功配对、无 unpaired，`t_agent` 中位相对变化 `+260.14%`。第一次 cube r4 900 秒超时并验证失败，失败证据保留在 `failed-reruns/build-pmars-cube-r4-timeout1/`；补跑 cube r4 后形成完整配对。

## 推荐工作流

### 阶段 0：准备与基线确认

目的：确认测试环境未处于异常状态，避免把基础设施问题误判为 Cube 行为。

操作要点：

- 查看脚本入口：`task --list-all`。
- 确认本地 workspace 配置：`local.env`。
- 确认目标 TS4/PVM 节点 Ready、无 DiskPressure、cube/runc RuntimeClass 可用。
- 确认 Terminal-Bench source commit 与 `task-matrix.t-agent.json` 一致。
- 确认 `_output/agc37-terminal-preflight/` 旧工件仍可用于对比。

验收标准：

- 目标节点 `Ready=True`，`DiskPressure=False`。
- runc 与 Cube RuntimeClass 均存在。
- 至少任选一个已通过任务，在 runc 与 Cube 各复跑 1 次仍通过原始验证。
- 新工件包含 `result.json`、`controller-result.json`、`pod.json`、`agent.log` 和 `artifacts/`。

### 阶段 1：镜像和依赖环境收敛

目的：先消除镜像构建、导入、外网依赖和磁盘压力问题。

操作模板：

```bash
cd /data/home/journeyyou/projects/CubeSandbox-zhiyu-beta

cube-cri-testsuite/performance/coding-agent/build-terminal-image.sh \
  --task-dir terminal-bench/original-tasks/<task> \
  --node 172.17.209.85 \
  --image agc37-terminal-<task>:<date> \
  --ubuntu-apt-mirror https://mirrors.tencent.com/ubuntu \
  --output _output/agc37-terminal-images/<task>
```

注意：`--ubuntu-apt-mirror` 只用于临时 build context。若不需要，不应启用。启用后必须保留 `image-manifest.json`。

验收标准：

- 镜像可重复构建并导入目标节点 containerd。
- `image-manifest.json` 记录镜像 ID、任务 hash、Pi 版本、验证缓存 hash 和 build workaround。
- 大镜像不会让目标节点进入 DiskPressure。
- 验证依赖缓存足够运行原始验证入口；新增缓存必须可由 manifest 追溯。

### 阶段 2：外层 harness 标准能力补齐

目的：只补齐 Terminal-Bench 标准任务形态的外层支持，不改原任务。

当前已知缺口：

- 一般多服务拓扑尚未泛化；目前仅对 `debug-long-program` 这种 `client + program` 固定形态提供 sidecar 支持。

允许改动范围：

- `build-terminal-image.sh`：识别和封装更多标准 docker-compose 服务形态。
- `run-terminal-case.sh`：更稳健地读取 `task.yaml` 指令字段。
- 本目录新增只读解析/编排辅助脚本。

不允许改动范围：

- `terminal-bench/original-tasks/<task>/run-tests.sh`。
- `terminal-bench/original-tasks/<task>/tests/`。
- 任务 instruction 的语义内容。

验收标准：

- `debug-long-program` 可在不改原任务的前提下创建所需多服务环境。
- 旧的单服务、`instruction: |-` 任务行为不回退。
- 至少用一个已通过任务复测，确认 harness 改动不改变原始验证结果。

### 阶段 3：逐 case 预检修复

目的：对每个问题项建立可复现结论。顺序建议：先 runc 可通过但 Cube 失败的任务，再修 runc 自身失败的任务，最后处理大镜像和 harness 缺口。

单次运行模板：

```bash
cube-cri-testsuite/performance/coding-agent/run-terminal-case.sh \
  --node 172.17.209.85 \
  --task-dir terminal-bench/original-tasks/<task> \
  --image agc37-terminal-<task>:<date> \
  --mode runc \
  --round 0 \
  --output _output/agc37-terminal-repair/<task>/runc-r0 \
  --keep

cube-cri-testsuite/performance/coding-agent/run-terminal-case.sh \
  --node 172.17.209.85 \
  --task-dir terminal-bench/original-tasks/<task> \
  --image agc37-terminal-<task>:<date> \
  --mode cube \
  --round 0 \
  --output _output/agc37-terminal-repair/<task>/cube-r0 \
  --keep
```

`--keep` 只用于诊断。问题定位完成后需清理 namespace，并用不带 `--keep` 的命令复测。

通用验收标准：

- runc 和 Cube 至少各 1 次 Pi 退出码为 0。
- runc 和 Cube 至少各 1 次原始验证入口退出码为 0。
- 若仍失败，必须明确失败阶段：镜像构建、Pod Ready、Pi 执行、测试加载、原始验证、工件采集。
- 若判定为 Cube CRI 语义缺口，必须有最小复现 Pod 或命令，并能说明 runc 与 Cube 的差异。

### 阶段 4：正式候选更新

目的：只把稳定通过的任务纳入正式集。

验收标准：

- `task-matrix.t-agent.json` 更新对应 preflight 状态和关键事实。
- `T_AGENT_TEST_PLAN.md` 的任务状态同步更新。
- `PRELIMINARY_REPORT.md` 追加预检事实，不把单次结果当正式结论。
- 正式集达到至少 8 个任务，并满足分类最低数量。

### 阶段 5：正式配对与报告

目的：在修复后按测试计划生成可报告数据。

验收标准：

- 每个正式任务完成 6 个成功配对：3 轮 `runc -> Cube`，3 轮 `Cube -> runc`。
- 每轮仅在两侧 Pi 退出码均为 0 且原始验证均通过时进入配对统计。
- 失败、超时、基础设施错误单独保留，不混入时延统计。
- 汇总报告包含 token、response 数、工具调用、资源采样和原始值。

当前进展：

- 已完成：`processing-pipeline`，报告 `_output/agc37-terminal-formal/processing-pipeline-formal-v1/report.json`，12 条正式记录、6 个成功配对、无 unpaired；`t_agent` 中位相对变化 `+25.54%`。
- 已完成：`openssl-selfsigned-cert`，报告 `_output/agc37-terminal-formal/openssl-selfsigned-cert-formal-v1/report.json`，12 条正式记录、6 个成功配对、无 unpaired；`t_agent` 中位相对变化 `+16.63%`。
- 已完成：`modernize-fortran-build`，报告 `_output/agc37-terminal-formal/modernize-fortran-build-formal-v1/report.json`，12 条正式记录、6 个成功配对、无 unpaired；`t_agent` 中位相对变化 `-30.01%`。
- 已完成：`debug-long-program`，报告 `_output/agc37-terminal-formal/debug-long-program-formal-v1/report.json`，12 条正式记录、6 个成功配对、无 unpaired；`t_agent` 中位相对变化 `-29.66%`；另有 2 次 Cube Pi 前启动失败并已单独保留。
- 已完成：`fix-code-vulnerability`，报告 `_output/agc37-terminal-formal/fix-code-vulnerability-formal-v1/report.json`，12 条正式记录、6 个成功配对、无 unpaired；`t_agent` 中位相对变化 `+84.97%`。
- 已完成：`crack-7z-hash`，报告 `_output/agc37-terminal-formal/crack-7z-hash-formal-v1/report.json`，12 条正式记录、6 个成功配对、无 unpaired；`t_agent` 中位相对变化 `+156.20%`。
- 已完成：`nginx-request-logging`，报告 `_output/agc37-terminal-formal/nginx-request-logging-formal-v1/report.json`，12 条正式记录、6 个成功配对、无 unpaired；`t_agent` 中位相对变化 `+339.83%`。
- 已完成：`jupyter-notebook-server`，报告 `_output/agc37-terminal-formal/jupyter-notebook-server-formal-v1/report.json`，12 条正式记录、6 个成功配对、无 unpaired；`t_agent` 中位相对变化 `+151.72%`。
- 已完成：`build-pmars`，报告 `_output/agc37-terminal-formal/build-pmars-formal-v1/report.json`，12 条正式记录、6 个成功配对、无 unpaired；`t_agent` 中位相对变化 `+260.14%`；另有 1 次 Cube 900 秒超时失败并已单独保留。
- 部分完成但不达标：`new-encrypt-command`，报告 `_output/agc37-terminal-formal/new-encrypt-command-formal-v1/report.json`，12 条正式记录但只有 3 个成功配对；失败轮不进入正式统计，后续应剔除该低强度任务或补跑替代安全样本。

阶段 5 验收结论：已达标。当前正式完成任务 9 个，覆盖 build_debug 3 个、system_operations 3 个、security 3 个，满足正式任务总数和分类下限。

套件级入口已补齐：后续可使用 `task test:coding-agent:formal -- --node 172.17.209.85 --task-root /data/home/journeyyou/agc37-cache/terminal-bench-d28711d/terminal-bench/original-tasks` 一键重跑已验收 formal 套件。该入口会按任务构建镜像、导入节点、运行 6 个 formal 配对、补跑未配对样本、清理节点镜像，并生成 `suite-report.md/json`。

## Case-by-case 修复清单

### `sqlite-with-gcov`

现象：runc 成功；Cube Pi 900 秒超时，原始验证失败。

优先级：高。该任务属于 build_debug，修复后对正式集价值高。

当前进展：2026-09-12 已基于旧工件完成归因补充。Cube 轨迹主要耗在尝试安装 `gcc/make/build-essential/libreadline-dev/zlib1g-dev/tcl-dev`。第一次 apt 安装在升级 `dpkg` 时失败：`unable to securely remove '/usr/bin/dpkg.dpkg-tmp': Stale file handle`，并留下多个 `*.dpkg-tmp` stale 项；随后 Agent 手工回滚/hold dpkg 相关包，再缩小依赖安装集，仍在 `libgcc-s1` 覆盖 `/usr/lib/x86_64-linux-gnu/libgcc_s.so.1.dpkg-tmp` 时失败。最终官方验证报 `sqlite3 not found in PATH`。该问题与 `configure-git-webserver` 的 `libcap2` 最小复现同属 Cube 下 apt/dpkg 文件覆盖语义缺口。

排查路径：

1. 已完成：旧 runc 工件原始验证通过，`t_agent=601.10s`。
2. 已完成：旧 Cube 工件显示 Pi 900 秒超时，验证阶段 `sqlite3` 不存在。
3. 已完成：Cube 失败路径定位到 apt/dpkg 覆盖文件 `Stale file handle`，不是 SQLite 编译本身。
4. 下一步可复用 `configure-git-webserver` 的 `libcap2` 最小复现继续定位 Cube overlay/virtiofs 语义；修复后再复跑本任务。

验收标准：

- Cube 至少 1 次在设定超时内完成 Pi，并通过原始验证。
- 当前未通过；归因为 Cube 下 apt/dpkg 文件覆盖语义缺口，已有跨 case 最小复现。

### `nginx-request-logging`

现象：runc 成功；Cube Pi 900 秒超时，原始验证失败。

优先级：高。该任务属于 system_operations，当前正式集最缺系统运维类样本。

当前结论：2026-09-12 已通过 Debian mirror workaround 修复并复跑成功。原 Cube 失败轮卡在 `apt-get update`，最小 Pod 对照显示 `deb.debian.org` 当前 runc 与 Cube 都在 300 秒超时，属于镜像源/网络环境问题；把 task image 的 Debian 源替换为 `https://mirrors.tencent.com/debian` 和 `https://mirrors.tencent.com/debian-security` 后，runc 与 Cube 均通过原始验证。工件位于 `_output/agc37-terminal-repair/nginx-request-logging/`。

排查路径：

1. 已完成：旧 Cube 工件显示未安装 nginx，验证 8 项全失败。
2. 已完成：最小 `apt-get update` 对照表明 `deb.debian.org` 在 runc/Cube 下均超时，不是 Cube 专属服务语义问题。
3. 已完成：镜像源切到腾讯 Debian 后重建镜像，并完成 runc/Cube 双侧预检。
4. 正式配对前保留 image manifest 中的 mirror workaround，避免和原始慢源混用。

验收标准：

- 已满足：Cube 原始验证通过。
- 已满足：失败原因已归为镜像源/网络环境问题，不是 nginx 服务语义差异。

### `configure-git-webserver`

现象：runc 成功；Cube Pi 退出 0，但原始验证 HTTP 404。

优先级：高。该任务属于 system_operations，且 Cube 已能完成 Pi，问题更接近运行时或服务状态差异。

当前进展：2026-09-12 已补充手动参考方案对照。原 Cube Pi 轨迹配置的是 `ubuntu + dropbear + python http.server`，并在最终清空 repo/webroot，未配置官方验证脚本固定使用的 `git@localhost` 密码登录路径。进一步在同镜像 runc/Cube sleep Pod 内手动执行官方 `solution.sh` 与 `tests/verify.sh`：runc 包含 `TEST PASSED`；Cube 在 `apt-get install git nginx openssh-server` 覆盖 `libcap2` 时失败，报 `unable to securely remove ... libcap.so.2.66.dpkg-tmp: Stale file handle`，后续 `adduser`、`nginx`、`ssh` 缺失，官方验证失败。最小复现已缩到 `apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall libcap2`：runc `rc=0`，Cube `rc=100`。工件位于 `_output/agc37-terminal-repair/configure-git-webserver/manual-solution-v1/` 和 `_output/agc37-terminal-repair/configure-git-webserver/dpkg-libcap2-min-v1/`。

排查路径：

1. 已完成：检查原 Cube Pi 事件，确认它未配置官方 `git@localhost` 密码登录入口，且清空了 webroot。
2. 已完成：手动参考方案对照显示 runc 可通过，Cube 在 apt/dpkg 文件覆盖阶段触发 `Stale file handle`。
3. 已完成：最小 dpkg 复现为 `apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall libcap2`；同镜像同节点下 runc 成功，Cube 失败。
4. 下一步进入 Cube CRI 文件系统/overlay 语义排查：定位 dpkg 替换 `/usr/lib/x86_64-linux-gnu/libcap.so.2.66.dpkg-tmp` 时为何在 Cube overlay/virtiofs 下返回 stale file handle。

验收标准：

- Cube Pi 退出 0 且原始验证通过。
- 当前已明确：原 Pi 失败路径包含 Agent 未按官方验证入口配置服务；参考方案路径暴露 Cube 下 apt/dpkg 文件覆盖语义缺口。

### `crack-7z-hash`

现象：runc 成功；Cube 未到 Pi 阶段，等待 Pod Ready 超时。

优先级：高。该任务属于 security，且现象偏基础设施或 Cube 启动路径。

当前进展：2026-09-12 在同一节点重试 `cube-retry-v1` 已通过，`t_agent=168.97s`，原始验证通过。此前 Pod Ready 超时作为历史基础设施事件保留，当前不再阻塞正式候选。

排查路径：

1. 先确认目标节点无 DiskPressure，镜像已导入且 imagePullPolicy 为 `Never`。
2. 检查 Cube Pod events、sandbox 创建日志、containerd/shim 日志、Cube runtime 日志。
3. 对比同镜像在 runc 下是否 Ready，排除镜像本身问题。
4. 若与镜像大小或层数有关，记录镜像大小、层数、导入耗时和 Cube sandbox 创建耗时。
5. 抽取一个不运行 Pi 的最小 Pod，验证 Cube 是否能仅启动该镜像。

验收标准：

- Cube Pod 能 Ready 并进入 Pi 阶段。
- 至少 1 次 Cube 原始验证通过。
- 若仍无法 Ready，必须有 Cube 启动失败的最小复现和日志链路。

### `polyglot-c-py`

现象：runc Pi 成功但原始验证失败，原因是工作区残留额外 `cmain` 文件。

优先级：低。已确认任务和 Cube 运行时本身可通过；后续不作为 Cube 修复主线。

当前结论：2026-09-12 已补充手动官方解法对照。旧 runc Pi 写出的 `main.py.c` 在 Python 和 gcc 下都能输出正确 Fibonacci 值，但 Agent 自测时执行 `gcc /app/polyglot/main.py.c -o /app/polyglot/cmain` 后未清理 `cmain`。官方测试第一步断言 `os.listdir("/app/polyglot") == ["main.py.c"]`，因此失败。手动执行原任务 `solution.sh` 并运行官方验证，runc 与 Cube 均 `verify_exit=0`，工件位于 `_output/agc37-terminal-repair/polyglot-c-py/manual-solution-v1/`。

排查路径：

1. 已完成：旧 runc 工件确认额外文件来自 Pi 自测留下的 gcc 输出 `cmain`。
2. 已完成：原始测试断言要求 `/app/polyglot` 仅包含 `main.py.c`。
3. 已完成：不改原始测试，手动官方解法在 runc/Cube 均通过，排除 Cube CRI 语义缺口。
4. 后续若要纳入正式集，需要通过正式 Agent 轮次自然通过，或明确将其作为 Agent 行为失败样本排除；不建议通过改 prompt 或清理脚本改变基准语义。

验收标准：

- 已满足：官方解法在 runc 与 Cube 均通过原始验证。
- 已明确：旧预检失败为 Agent artifact hygiene 问题，不投入 Cube 修复时间。

### `build-pmars`

现象：runc Pi 900 秒超时且验证失败。

优先级：中。属于 build_debug；runc 已修复，Cube 还未形成成功配对。

当前结论：2026-09-12 已通过 Debian HTTP mirror workaround 修复并复跑成功。旧 runc 主要耗在 `deb.debian.org` 下 `apt-get update` 和 deb-src 更新，且先执行 `apt-get source pmars` 时缺少 `dpkg-source`。使用 `http://mirrors.tencent.com/debian` 和 `http://mirrors.tencent.com/debian-security` 重建镜像后，runc `t_agent=311.13s`，官方验证 4 项通过。Cube `cube-mirror-v1` 中 Pi 退出 0，pMARS 二进制、无 X11 依赖和源码构建检查均通过，但 `test_debian_source_used` 失败：Agent 解法把 Debian packaging 目录留在 `/app/debian`，而官方测试要求 `/app/pmars-0.9.4/debian`。2026-09-12 `cube-mirror-v3` 复跑通过，`t_agent=794.58s`，官方 4 项验证全通过；此前失败归为 Agent 路径波动。

排查路径：

1. 已完成：旧 runc 工件确认慢源导致 apt/deb-src 阶段耗时过长，且 Agent 先缺 `dpkg-source`。
2. 已完成：HTTP Debian mirror repair 镜像构建并导入，manifest 记录 workaround。
3. 已完成：runc repair 轮通过官方验证。
4. 已完成：Cube `cube-mirror-v1` 显示运行时能完成编译与 debugger 交互，失败点为 Agent 放置 Debian packaging 目录不符合测试断言。
5. 已完成：Cube `cube-mirror-v3` 复跑通过，形成双侧成功预检。

验收标准：

- runc 原始验证通过后才跑 Cube。
- 已满足：runc 与 Cube 至少各 1 次通过原始验证。
- 正式配对前保留 Debian HTTP mirror workaround，不能混用旧镜像。

### `jupyter-notebook-server`

现象：runc Pi 900 秒超时且验证失败。

优先级：已修复。属于 system_operations，可进入正式候选；正式前建议再做一次普通复测或直接进入配对流程。

当前结论：2026-09-12 已通过 Debian/PyPI mirror workaround 修复。旧 runc 仅完成 4 次工具调用，卡在 `pip3 install notebook matplotlib`，最终未生成配置文件、notebook 或 Jupyter 服务。手动执行官方 `solution.sh` 时，在临时 Pod 中设置 Debian 与 PyPI 镜像源后 runc/Cube 均通过官方验证。随后 `build-terminal-image.sh` 增加 `--pip-index-url` 与 `--pip-trusted-host`，把 `/etc/pip.conf` 注入临时 build context 并写入 manifest。基于 repair 镜像，runc `t_agent=429.39s`，Cube 第二轮 `t_agent=452.02s`，原始验证均通过。工件位于 `_output/agc37-terminal-repair/jupyter-notebook-server/`。

排查路径：

1. 已完成：旧 runc 工件确认超时点为 PyPI 依赖安装，验证阶段 4 项全失败。
2. 已完成：官方解法手动对照在镜像源 workaround 下 runc/Cube 均通过，排除任务自身不可用。
3. 已完成：外层 build 脚本支持 PyPI mirror manifest 追溯，repair 镜像已构建并导入节点。
4. 已完成：runc repair 轮通过；Cube `cube-mirror-v1` 仅 password hash 静态配置断言失败，`cube-mirror-v2` 通过。

验收标准：

- 已满足：runc 与 Cube 至少各 1 次通过原始验证。
- 正式配对前保留 Debian/PyPI mirror workaround，不能混用旧镜像。

### `processing-pipeline`

现象：作为补齐 system_operations 分类下限的新候选，需确认脚本权限、CRLF 行尾、shebang 和流水线执行路径在 runc/Cube 下均可通过。

当前结论：2026-09-12 已通过 Ubuntu mirror workaround 重建镜像并完成双侧预检。runc `t_agent=61.48s`，12 次工具调用；Cube `t_agent=44.34s`，15 次工具调用；官方 9 项 pytest 全部通过。工件位于 `_output/agc37-terminal-repair/processing-pipeline/`。

排查路径：

1. 已完成：读取原始任务，确认验证只依赖脚本权限、行尾、shebang、`/data/output` 可写和流水线输出，不需要修改 Terminal-Bench 源码。
2. 已完成：使用 `--ubuntu-apt-mirror https://mirrors.tencent.com/ubuntu` 重建镜像，manifest 记录 workaround。
3. 已完成：runc 与 Cube 各 1 次通过原始验证。
4. 下一步进入正式配对；正式前保留该镜像 manifest，不能和未记录 mirror workaround 的旧镜像混用。

验收标准：

- 已满足：runc 与 Cube 至少各 1 次通过原始验证。
- 已满足：system_operations 分类达到正式集最低数量。

### `debug-long-program`

现象：任务声明 2 个服务；原先外层 harness 只支持单 client 服务。

当前结论：2026-09-12 已通过外层 sidecar harness 复跑成功。runc `t_agent=216.35s`，Cube `t_agent=256.31s`，原始验证均通过。

已完成路径：

1. 阅读原始 `docker-compose.yaml`，识别 client 与辅助服务的网络、卷和启动顺序。
2. 在外层 Pod 中用 `program` sidecar 等价表达服务拓扑。
3. 使用 hostAlias 将 `program` 解析到 `127.0.0.1`，保持任务 instruction 中的访问地址不变。
4. 保持原始任务文件、runner 和验证入口不变。

验收标准：

- 已满足：harness 能启动该任务需要的两个服务。
- 已满足：runc 与 Cube 各至少 1 次通过原始验证。
- 待持续回归：正式配对前继续用既有单服务任务确认旧路径不回退。

### `db-wal-recovery`

现象：原先因 `task.yaml` 使用 `instruction: |` 阻塞；YAML parser 修复后，runc 预检通过，Cube 900 秒超时且原始验证失败。

优先级：高。属于 system_operations，已能在 runc 通过，下一步应定位 Cube 下长尾行为。

排查路径：

1. 使用 `_output/agc37-terminal-repair/db-wal-recovery/runc-parser-v1` 与 `cube-parser-v1` 对比 Pi 事件。
2. Cube 失败轮最后卡在全盘 `grep -R ... / ... | head -100`，需判断是 Agent 路径差异、Cube 文件系统遍历性能差异，还是命令退出/管道行为差异。
3. 已完成最小 Pod 对照：同镜像下同类搜索命令 runc 约 2.59s、Cube 约 10.10s，均正常退出；Cube 存在遍历变慢，但不足以解释 900 秒超时。
4. 已尝试 Cube retry：`cube-retry-v1` 因节点瞬时 `DiskPressure` 在调度/启动阶段被 Evicted，未进入 Pi 阶段；该轮仅作为基础设施事件记录。
5. 已完成干净节点复跑：`cube-retry-v2` 在节点无 DiskPressure 时仍 900 秒超时，未生成 `recovered.json`；Pi 末尾继续停在全盘文本搜索路径附近。
6. 下一步若继续投入，应优先对比 runc/Cube Pi 事件路径，判断为何 runc 能较快收敛到恢复方案而 Cube 继续搜索；当前证据仍不足以归因到 grep/pipe 死锁。

验收标准：

- Cube 至少 1 次 Pi 退出码为 0 且原始验证通过。
- 当前未满足；两次有效 Cube Agent 轮均 900 秒超时，干净节点 retry 已排除 DiskPressure 干扰。
- 若仍不能通过，需给出明确归因：Cube 运行时差异或 Agent 路径差异。当前证据不支持 grep/pipe 死锁归因。

### `build-tcc-qemu`

现象：4.5 GiB 镜像触发目标节点磁盘压力。

优先级：低到中。任务覆盖价值高，但不能在磁盘压力状态下测量。

排查路径：

1. 先清理目标节点无关镜像和旧 namespace，确认 kubelet image GC 状态。
2. 评估目标节点是否有足够磁盘承载该任务和正式配对重复运行。
3. 如需换节点，必须仍满足 TS4/PVM、runc/Cube 同节点串行和测试计划固定条件。
4. 不通过压缩、删任务文件或改 Dockerfile 内容来改变任务语义；仅允许通用镜像 GC、预导入和镜像源 workaround。

验收标准：

- 镜像导入后节点无 DiskPressure。
- runc 与 Cube 各至少 1 次通过原始验证。
- 正式运行前确认不会因 image GC 影响 `imagePullPolicy: Never`。

### `qemu-startup`

现象：runc Agent 轮未通过原始验证；Cube Agent 轮 900 秒超时。官方 solution 在 runc 与带正式资源配置的 Cube Pod 中均通过。

优先级：高。属于 system_operations，是补齐系统运维类样本的直接候选。

当前进展：2026-09-12 已形成可复建镜像 workaround。原始 `deb.debian.org/debian-security` 因 `Valid-Until` 过期和包对象 404 阻塞；Tencent Debian security 镜像同样 404，archive.debian.org 不提供 bullseye-security suite，snapshot.debian.org 返回 509。最终采用 `--disable-debian-security true`、`--apt-check-valid-until false`、`--debian-apt-mirror http://mirrors.tencent.com/debian`，并预安装 `perl-base=5.32.1-4+deb11u3` 消除 base image 已带 security 版 perl-base 与 main 源候选版本不一致的问题。镜像 `cube-cri-agc37-pi-terminal-qemu-startup:tb-d287-pi0.85.6-repair5` 已构建并导入节点，manifest 位于 `_output/agc37-terminal-repair/qemu-startup/image-repair-v5/`。

runc Agent 预检工件位于 `_output/agc37-terminal-repair/qemu-startup/runc-repair-v1/`：Pi 退出 0，`t_agent=601.69s`，但原始验证失败；日志显示 Agent 自测 telnet 可见 Alpine login prompt，但官方 expect 连接时 spawn 已关闭，未生成 `/tmp/data.txt`。Cube Agent 预检工件位于 `_output/agc37-terminal-repair/qemu-startup/cube-repair-v1/`：Pi 900 秒超时，验证同样未生成 `/tmp/data.txt`；Pi 最后尝试了 `-serial telnet:127.0.0.1:6665,server`，该参数会等待连接，未等价于官方 `server,nowait` 路径。

为区分镜像、运行时和 Agent 路径，手动把官方 `solution.sh` 拷入同镜像 Pod 执行，再跑原始 `run-tests.sh`。runc 对照通过，工件位于 `_output/agc37-terminal-repair/qemu-startup/manual-solution-v4/runc/`。Cube 带正式资源配置的对照也通过，工件位于 `_output/agc37-terminal-repair/qemu-startup/manual-solution-v5/cube-4g/`。

资源诊断工件位于 `_output/agc37-terminal-repair/qemu-startup/qemu-memory-min-v1/cube/` 和 `_output/agc37-terminal-repair/qemu-startup/qemu-memory-min-v2/cube-4g/`。未设置 resources 的 Cube 诊断 Pod 内 `MemTotal` 约 471376 kB，qemu `-m 512/768/1024` 失败；带 `2 CPU / 4Gi` requests/limits 后，Cube Pod 内 `MemTotal` 约 4012128 kB，qemu `-m 128/256/512/768/1024/1536/2048/3072` 均可启动。此前 `cannot set up guest memory 'pc.ram'` 不是 Cube CRI 固有 qemu 缺口，而是诊断 Pod 资源配置不足。

排查路径：

1. 已完成：构建并导入 repair5 镜像，记录 manifest。
2. 已完成：runc Agent 轮 Pi 退出 0 但验证失败；runc 官方 solution 手动对照通过。
3. 已完成：Cube 官方 solution 手动对照在 `4Gi` limit 下通过；资源不足诊断 Pod 中的 qemu 内存失败已排除为测试配置问题。
4. 下一步：若继续尝试纳入正式集，只能靠 Agent 自然走到官方等价路径；不应修改 Terminal-Bench 源码或用外层脚本代替 Pi 解题。

验收标准：

- 当前未满足：runc/Cube Agent 轮均未通过，不能进入正式集。
- 已满足诊断验收：官方 solution 在 runc 与 Cube 均通过；带正式资源配置的 Cube Pod 中 qemu `-m 1024` 以上可启动。
- 若要进入正式集：runc 与 Cube Agent 轮必须各至少 1 次通过原始验证；不能通过修改任务测试或在外层注入官方解法补救。

## 失败归因模板

每个未通过 case 都应在 issue 或后续报告中补齐以下字段：

```text
任务：
运行模式：runc / cube
阶段：build / pod-ready / agent / test-load / verify / artifact
命令：
镜像：
节点：
工件目录：
现象：
runc 对照：
Cube 对照：
最小复现：
初步归因：环境 / harness / Cube CRI / Agent 路径 / 未定
下一步：
```

## 收尾检查

停止工作前必须做一次改动回顾：

- 哪些改动是调试 workaround。
- workaround 是否仍必要。
- 是否污染了 Terminal-Bench 原始任务。
- 是否需要收敛到外层 harness 或环境 manifest。
- 收敛后是否已到集群复测。
- `T_AGENT_TEST_PLAN.md`、`PRELIMINARY_REPORT.md`、`task-matrix.t-agent.json` 是否同步更新。
