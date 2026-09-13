# AGC-37：t_agent 预检记录（非正式报告）

生成时间：2026-09-11，2026-09-12 更新。此文件只记录预检事实；虽已满足至少 8 个任务的总数下限和分类门槛，但尚未完成每任务 6 个成功配对，不能据此报告 Cube/PVM 相对 runc 的时延增量。

## 固定口径

- 主指标：同一 Agent 容器内，Pi 进程启动前至退出后的 `CLOCK_MONOTONIC` 时长。
- 验证：未改动任务 `run-tests.sh`；固定 uv 与 pytest/requests 缓存仅用于消除验证下载波动，不计入 `t_agent`。
- 节点：`172.17.209.85`，runc 与 Cube 串行使用同一节点。

## 已完成预检

| 任务 | runc | Cube | 结论 |
| --- | --- | --- | --- |
| `modernize-fortran-build` | 成功；`t_agent=39.74s` | 成功；`t_agent=41.58s` | 可进入正式配对；这两个独立 Agent 轨迹不构成性能差值。 |
| `sqlite-with-gcov` | 成功；`t_agent=601.10s`，36 次工具调用 | 900s 超时；验证失败，57 次工具调用 | 排除：Cube 安装构建工具时 apt/dpkg 覆盖文件触发 `Stale file handle`，最终 `sqlite3` 不在 PATH；与 `configure-git-webserver` 的最小 dpkg 复现同类。 |
| `polyglot-c-py` | Pi 成功；`t_agent=293.44s`，但验证失败 | 手动官方解法验证通过 | 排除：工作区残留 `cmain`，原始验证要求仅有 `main.py.c`；官方解法 runc/Cube 均通过，归类为 Agent 收尾问题。 |
| `openssl-selfsigned-cert` | 成功；`t_agent=63.73s`，10 次工具调用 | 成功；`t_agent=65.27s`，13 次工具调用 | 节点修复后可进入正式配对；历史 Cube Pi 前启动故障已不再阻塞。 |
| `new-encrypt-command` | 成功；`t_agent=18.92s`，5 次工具调用 | 成功；`t_agent=38.57s`，4 次工具调用 | 可作为低强度补充样本；任务太短，正式汇总时需单独标注。 |
| `fix-code-vulnerability` | 成功；`t_agent=47.81s`，17 次工具调用 | 成功；`t_agent=80.53s`，21 次工具调用 | 可进入正式配对；属于漏洞修复、改代码、跑测试路径。 |
| `debug-long-program` | 成功；`t_agent=216.35s`，11 次工具调用 | 成功；`t_agent=256.31s`，6 次工具调用 | 可进入正式配对；外层 harness 已用 sidecar 支持该固定双服务形态，未修改原任务。 |
| `configure-git-webserver` | 成功；`t_agent=314.84s`，30 次工具调用 | Pi 退出 0；`t_agent=733.11s`，49 次工具调用；验证失败 | 排除：Cube 原始验证 HTTP 404；最小 `apt install --reinstall libcap2` 复现 Cube dpkg `Stale file handle`，属于待修运行时文件系统语义缺口。 |
| `nginx-request-logging` | 成功；原始轮 `t_agent=568.68s`；腾讯 Debian 镜像复跑 `51.75s` | 成功；腾讯 Debian 镜像复跑 `433.26s`，42 次工具调用 | 可进入正式配对；原失败来自 `deb.debian.org` apt update 长时间卡住，非 nginx 语义差异。 |
| `crack-7z-hash` | 成功；`t_agent=140.53s`，16 次工具调用 | 成功；`t_agent=168.97s`，15 次工具调用 | 可进入正式配对；此前 Cube Pod Ready 超时在 2026-09-12 重试中未复现。 |
| `db-wal-recovery` | 成功；`t_agent=109.17s`，15 次工具调用 | 900s 超时；retry2 在干净节点仍 900s 超时，验证失败 | 排除：外层 instruction 解析已修复；最小 grep 对照 runc 2.59s、Cube 10.10s 均正常退出；干净节点 retry 仍未生成 `recovered.json`，当前更像 Agent 路径差异叠加 Cube 下 I/O 慢。 |
| `jupyter-notebook-server` | 成功；Debian/PyPI 镜像复跑 `t_agent=429.39s`，56 次工具调用 | 成功；Debian/PyPI 镜像复跑 `t_agent=452.02s`，38 次工具调用 | 可进入正式配对；旧失败来自 `pip install` 长时间卡住。Cube 第一次 mirror 轮只缺测试可识别 password hash 静态配置，第二轮通过。 |
| `build-pmars` | 成功；Debian HTTP 镜像复跑 `t_agent=311.13s`，51 次工具调用 | 成功；Cube retry `t_agent=794.58s`，108 次工具调用 | 可进入正式配对；`cube-mirror-v1` 曾因 Agent 将 `debian/` 留在 `/app/debian` 失败，`cube-mirror-v3` 已通过官方 4 项验证。 |
| `qemu-startup` | Pi 退出 0；`t_agent=601.69s`，验证失败；官方 solution 手动对照原始验证通过 | Pi 900s 超时；验证失败；官方 solution 手动对照在 `4Gi` 资源下通过 | 排除：repair5 镜像已可复建；官方解法 runc/Cube 均通过。此前 Cube qemu 内存失败来自未设置 resources 的诊断 Pod，带 `4Gi` limit 后 qemu `-m 3072` 也可启动；当前归类为 Agent 路径失败。 |
| `processing-pipeline` | 成功；Ubuntu 镜像复跑 `t_agent=61.48s`，12 次工具调用 | 成功；Ubuntu 镜像复跑 `t_agent=44.34s`，15 次工具调用 | 可进入正式配对；官方 9 项验证通过，补齐 system_operations 分类下限。 |

## 未形成样本的候选

| 任务 | 原因 |
| --- | --- |
| `build-tcc-qemu` | 4.5 GiB 镜像导入后触发目标节点 `disk-pressure:NoSchedule`。 |
| `qemu-startup` | repair5 镜像已可复建并导入；官方 solution runc/Cube 均通过；runc/Cube Agent 轮未过验证。 |

OpenSSL 的第二轮 runc 验证在固定 apt/uv 缓存下通过；此前 runc 验证超时的原因是原始 runner 的 `apt-get update` 外网阻塞。该缓存行为见测试方案，且不进入 `t_agent`。

## 当前状态

此前大镜像触发的磁盘压力已恢复；当前节点 `Ready=True`、`DiskPressure=False`。OpenSSL 已在 Cube 上通过，说明用户修复后的 Cube 基本可用。

当前有 10 个任务形成双侧成功预检：`modernize-fortran-build`、`openssl-selfsigned-cert`、`new-encrypt-command`、`fix-code-vulnerability`、`crack-7z-hash`、`debug-long-program`、`build-pmars`、`nginx-request-logging`、`jupyter-notebook-server`、`processing-pipeline`。总数下限和 build/debug、system_operations、security 分类下限均已满足。`db-wal-recovery` 已从 harness 解析阻塞推进到 Cube 侧 Agent 超时问题；`qemu-startup` 已从镜像构建阻塞推进到官方解法双侧通过、Agent 路径失败。二者仍不能进入正式集。失败和超时工件保留，但不参与汇总统计。

阶段 5 已完成 9 个正式任务，达到测试方案的正式任务数量下限和 build_debug、system_operations、security 分类下限。当前 `modernize-fortran-build`、`debug-long-program`、`build-pmars`、`nginx-request-logging`、`jupyter-notebook-server`、`processing-pipeline`、`openssl-selfsigned-cert`、`fix-code-vulnerability` 和 `crack-7z-hash` 完成每任务 6 个成功配对；其中 `debug-long-program` formal-v1 曾有 2 次 Cube Pi 前 init `StartError`，缺失侧补跑后形成完整配对，启动失败证据单独保留；`build-pmars` formal-v1 曾有 1 次 Cube 900 秒超时，失败证据单独保留；`nginx-request-logging`、`jupyter-notebook-server`、`build-pmars` 与 `crack-7z-hash` 的 Cube 侧存在多轮 Agent 长尾。`new-encrypt-command` formal-v1 只有 3 个成功配对，失败轮为 Agent 判断 `rencrypt` 无真实安全性并要求确认，未生成 `/app/encrypted_data/*`，不进入完成集。

原始工件位于 `_output/agc37-terminal-preflight/`；修复复跑工件位于 `_output/agc37-terminal-repair/`；正式配对工件位于 `_output/agc37-terminal-formal/`。`qemu-startup` repair5 image manifest 位于 `_output/agc37-terminal-repair/qemu-startup/image-repair-v5/`。

## 口径提醒

上表中的 runc/Cube 秒数来自独立 Agent 运行，token、工具调用和具体路径不完全相同，只能作为预检事实。正式结论必须使用同一任务内 6 个成功配对，并同时报告工具调用、token 和验证结果。
