#!/bin/sh
set -eu

shim_candidate=${1:-/usr/local/bin/containerd-shim-cube-rs}
unit_source=${2:-./cubesandbox-shim-watchdog.service}
shim_binary=/usr/local/bin/containerd-shim-cube-rs

test -x "$shim_candidate"
test -f "$unit_source"
candidate_path=$(readlink -f "$shim_candidate")
target_path=$(readlink -m "$shim_binary")
if [ "$candidate_path" != "$target_path" ]; then
    temporary_binary="${shim_binary}.new.$$"
    trap 'rm -f "$temporary_binary"' EXIT HUP INT TERM
    install -m 0755 "$candidate_path" "$temporary_binary"
    sync -f "$temporary_binary"
    mv -f "$temporary_binary" "$shim_binary"
    sync -f "$(dirname "$shim_binary")"
    trap - EXIT HUP INT TERM
fi
test -x "$shim_binary"
install -d -m 0755 /data/cubelet/shim-lifecycle
install -d -m 0755 /data/cubelet/shim-cleanup/host-cgroup
install -d -m 0755 /data/cubelet/shim-cleanup/runtime-resource
install -d -m 0755 /data/cubelet/runtime-resource-reaper
install -m 0644 "$unit_source" /etc/systemd/system/cubesandbox-shim-watchdog.service
systemctl daemon-reload
systemctl enable cubesandbox-shim-watchdog.service
# Always restart after installing a candidate. `enable --now` leaves an
# already-running old watchdog untouched and would skip the new binary's
# 200-iteration ExecStartPre gate.
systemctl restart cubesandbox-shim-watchdog.service
systemctl show cubesandbox-shim-watchdog.service \
    --property=ActiveState \
    --property=SubState \
    --property=MainPID \
    --property=ControlGroup
