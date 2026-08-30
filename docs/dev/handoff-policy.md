# PoC Handoff 规则

适用于 Kubernetes RuntimeClass PoC。交接时只更新活动 handoff：当前 stage、基线 commit、已完成与未完成范围、实际运行过的验证、阻塞、受保护路径和按顺序排列的下一步。结论必须能由命令、日志摘要或演示结果复现，不能仅写“已完成”。

未决问题使用稳定 ID，记录问题、当前假设、owner、最迟解决 stage、状态和证据；状态只用 `OPEN`、`VALIDATING`、`DECIDED`、`DEFERRED`。关闭后保留原记录并链接最终决定。

暂停、换人或 stage 结束前更新 handoff；接手者先复现最后一项关键验证，再继续下一步。handoff 与其描述的实现分开提交。运行 `make handoff-validate` 做最小格式检查。不得记录凭证值。
