#!/bin/sh
set -eu
host() { nsenter -t 1 -m -u -i -n -p -- "$@"; }
state=/var/lib/cube-cri/installer
version=$(cat /installer/version)
running() {
  case "$(host systemctl show "$unit" --property=ActiveState --value)" in active|activating|reloading) return 0;; *) return 1;; esac
}
ready() {
  test "$(cat /host-state/installed 2>/dev/null)" = "$version" || return 1
  for service in cube-cri-runtime-resource cubesandbox-shim-watchdog containerd; do
    host systemctl is-active --quiet "$service" || return 1
  done
  host test -S /run/cube-cri/runtime-resource.sock
}
if [ "${1:-}" = check ]; then ready; exit; fi
if [ "$(cat /host-state/installed 2>/dev/null || true)" != "$version" ]; then
  src=$state/$POD_UID
  unit=cube-cri-install-$POD_UID
  if ! running; then
    mkdir -p "/host-state/$POD_UID"
    cp /installer/runtime.tar.gz /installer/daemonset-install.sh "/host-state/$POD_UID/"
    host systemd-run --collect --unit "$unit" --property=Type=oneshot --property=TimeoutStartSec=10min \
      /bin/bash -c 'bash "$1/daemonset-install.sh" "$1" "$2" > "$1/install.log" 2>&1' bash "$src" "$version"
  fi
  while running; do sleep 2; done
  cat "/host-state/$POD_UID/install.log"
  test "$(cat /host-state/installed)" = "$version"
  rm -rf "/host-state/$POD_UID"
fi
echo "Cube CRI DaemonSet installed: $version"
exec sleep infinity
