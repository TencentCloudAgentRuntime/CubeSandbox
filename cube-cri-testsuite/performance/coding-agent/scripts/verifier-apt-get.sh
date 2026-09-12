#!/usr/bin/env bash
# 仅回放原始 runner 已满足的 apt-get update/install；其他请求保留原 apt-get 行为。
set -euo pipefail

original=("$@")
if [[ "${1:-}" == update ]]; then
  exit 0
fi
if [[ "${1:-}" == install ]]; then
  shift
  packages=()
  for argument in "$@"; do
    [[ "$argument" == -* ]] || packages+=("$argument")
  done
  if ((${#packages[@]} > 0)); then
    all_installed=true
    for package in "${packages[@]}"; do
      dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed' || all_installed=false
    done
  fi
  if [[ "${all_installed:-false}" == true ]]; then
    exit 0
  fi
fi
exec /usr/bin/apt-get "${original[@]}"
