#!/usr/bin/env bash
# 仅在原始 Terminal-Bench runner 的 uv 引导阶段回放已校验的官方字节。
set -euo pipefail

installer_url="https://astral.sh/uv/0.7.13/install.sh"
tarball_url="https://github.com/astral-sh/uv/releases/download/0.7.13/uv-x86_64-unknown-linux-gnu.tar.gz"
url=""
output=""
previous=""
for argument in "$@"; do
  [[ "$previous" == "-o" ]] && output="$argument"
  [[ "$argument" == http://* || "$argument" == https://* ]] && url="$argument"
  previous="$argument"
done
case "$url" in
  "$installer_url") cat /opt/agc37/verifier-cache/uv-install.sh ;;
  "$tarball_url") [[ -n "$output" ]] || exit 2; cp /opt/agc37/verifier-cache/uv.tar.gz "$output" ;;
  *) exec /usr/bin/curl "$@" ;;
esac
