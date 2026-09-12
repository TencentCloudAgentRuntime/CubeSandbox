#!/usr/bin/env bash
# 仅编排 Pi 与原始验证的顺序；Terminal-Bench runner 不在此修改。
set -euo pipefail

artifacts="${ARTIFACTS_DIR:-/artifacts}"
while [[ ! -e "$artifacts/start-agent" ]]; do sleep 0.1; done
/opt/agc37/agent-run.sh
while [[ ! -e "$artifacts/verify.done" ]]; do sleep 0.1; done
