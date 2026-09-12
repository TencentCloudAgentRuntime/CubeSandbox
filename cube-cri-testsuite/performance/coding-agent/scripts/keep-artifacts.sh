#!/usr/bin/env bash
# 仅在任务结束后保留共享 artifacts 以供控制器复制；不挂载 workspace、tests 或凭据。
set -euo pipefail

artifacts="${ARTIFACTS_DIR:-/artifacts}"
deadline=$((SECONDS + ${ARTIFACT_KEEPER_WAIT_SECONDS:-480}))
while [[ ! -e "$artifacts/verify.done" ]] && ((SECONDS < deadline)); do sleep 1; done
touch "$artifacts/keeper.ready"
while true; do sleep 3600; done
