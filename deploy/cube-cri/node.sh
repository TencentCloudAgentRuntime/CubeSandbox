#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
action=${1:-install}; shift || true
case "$action" in
  prepare) exec bash deploy/cube-cri/daemonset.sh --prepare-only "$@" ;;
  install) exec bash deploy/cube-cri/daemonset.sh "$@" ;;
  *) echo "unknown action: $action" >&2; exit 2 ;;
esac
