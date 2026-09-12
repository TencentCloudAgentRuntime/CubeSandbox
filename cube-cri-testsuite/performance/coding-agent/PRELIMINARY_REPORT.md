# AGC-37：t_agent 预检记录（非正式报告）

生成时间：2026-09-11。此文件只记录预检事实；尚未满足至少 8 个任务、每任务 6 个成功配对的正式门槛，不能据此报告 Cube/PVM 相对 runc 的时延增量。

## 固定口径

- 主指标：同一 Agent 容器内，Pi 进程启动前至退出后的 `CLOCK_MONOTONIC` 时长。
- 验证：未改动任务 `run-tests.sh`；固定 uv 与 pytest/requests 缓存仅用于消除验证下载波动，不计入 `t_agent`。
- 节点：`172.17.209.85`，runc 与 Cube 串行使用同一节点。

## 已完成预检

| 任务 | runc | Cube | 结论 |
| --- | --- | --- | --- |
| `modernize-fortran-build` | 成功；`t_agent=39.74s` | 成功；`t_agent=41.58s` | 可进入正式配对；这两个独立 Agent 轨迹不构成性能差值。 |
| `sqlite-with-gcov` | 成功；`t_agent=601.10s`，36 次工具调用 | 900s 超时；验证失败，57 次工具调用 | 排除：未形成成功配对。 |
| `polyglot-c-py` | Pi 成功；`t_agent=293.44s`，但验证失败 | 未运行 | 排除：工作区残留 `cmain`，原始验证要求仅有 `main.py.c`。 |
| `openssl-selfsigned-cert` | 成功；`t_agent=63.73s`，10 次工具调用 | 成功；`t_agent=65.27s`，13 次工具调用 | 节点修复后可进入正式配对；历史 Cube Pi 前启动故障已不再阻塞。 |
| `new-encrypt-command` | 成功；`t_agent=18.92s`，5 次工具调用 | 成功；`t_agent=38.57s`，4 次工具调用 | 可作为低强度补充样本；任务太短，正式汇总时需单独标注。 |
| `fix-code-vulnerability` | 成功；`t_agent=47.81s`，17 次工具调用 | 成功；`t_agent=80.53s`，21 次工具调用 | 可进入正式配对；属于漏洞修复、改代码、跑测试路径。 |
| `configure-git-webserver` | 成功；`t_agent=314.84s`，30 次工具调用 | Pi 退出 0；`t_agent=733.11s`，49 次工具调用；验证失败 | 排除：Cube 原始验证 HTTP 404，未形成成功配对。 |
| `nginx-request-logging` | 成功；`t_agent=568.68s`，15 次工具调用 | 900s 超时；验证失败，7 次工具调用 | 排除：Cube 未完成任务。 |
| `crack-7z-hash` | 成功；`t_agent=140.53s`，16 次工具调用 | Pi 前等待 Pod Ready 超时 | 暂停：无 Cube `t_agent`，先作为 Cube 启动/大镜像事件记录。 |

## 未形成样本的候选

| 任务 | 原因 |
| --- | --- |
| `build-tcc-qemu` | 4.5 GiB 镜像导入后触发目标节点 `disk-pressure:NoSchedule`。 |
| `jupyter-notebook-server` | runc Pi 900s 超时且验证失败，不运行 Cube 对照。 |
| `build-pmars` | runc Pi 900s 超时且验证失败，不运行 Cube 对照。 |
| `debug-long-program` | 任务声明 2 个服务；当前外层 harness 只支持单 client 服务。 |
| `db-wal-recovery` | `task.yaml` 指令格式不符合当前外层解析器支持的 `instruction: |-`。 |

OpenSSL 的第二轮 runc 验证在固定 apt/uv 缓存下通过；此前 runc 验证超时的原因是原始 runner 的 `apt-get update` 外网阻塞。该缓存行为见测试方案，且不进入 `t_agent`。

## 当前状态

此前大镜像触发的磁盘压力已恢复；当前节点 `Ready=True`、`DiskPressure=False`。OpenSSL 已在 Cube 上通过，说明用户修复后的 Cube 基本可用。

当前只有 4 个任务形成双侧成功预检：`modernize-fortran-build`、`openssl-selfsigned-cert`、`new-encrypt-command`、`fix-code-vulnerability`。还不能做正式统计，也不能回答“Cube 相比 runc 增加多少”。失败和超时工件保留，但不参与汇总统计。

原始工件位于 `_output/agc37-terminal-preflight/`。

## 口径提醒

上表中的 runc/Cube 秒数来自独立 Agent 运行，token、工具调用和具体路径不完全相同，只能作为预检事实。正式结论必须使用同一任务内 6 个成功配对，并同时报告工具调用、token 和验证结果。
