#!/usr/bin/env bash
set -euo pipefail

ADDRESS=${ADDRESS:-/run/containerd-cube-s0.2/containerd.sock}
NAMESPACE=${NAMESPACE:-s0-2}
CTR=${CTR:-/usr/local/bin/ctr}
RUNTIME=${RUNTIME:-io.containerd.cube.rs}
IMAGE=${IMAGE:-docker.io/library/busybox:1.36.1}
KERNEL=${KERNEL:-/data/cubelet/s0.2-assets/kernel/vmlinux}
AGENT=${AGENT:-/data/cubelet/s0.2-assets/agent/cube-agent.ext4}
GUEST_IMAGE=${GUEST_IMAGE:-/data/cubelet/s0.2-assets/guest/cube-guest-image-cpu.img}
CYCLES=${CYCLES:-20}
SHARE_BASE=${SHARE_BASE:-/data/cubelet/s0.2-share}
SOURCE_BASE=${SOURCE_BASE:-/data/cubelet/s0.2-dynamic-source}

current_id=

ctr() {
  "$CTR" --address "$ADDRESS" --namespace "$NAMESPACE" "$@"
}

mount_targets_under() {
  local root=$1
  findmnt -rn -o TARGET | awk -v root="$root" '$0 == root || index($0, root "/") == 1'
}

detach_mounts_under() {
  local root=$1
  local attempt target
  local -a targets
  for attempt in $(seq 1 8); do
    mapfile -t targets < <(mount_targets_under "$root" | sort -r)
    if [[ ${#targets[@]} -eq 0 ]]; then
      return 0
    fi
    for target in "${targets[@]}"; do
      if ! umount "$target" 2>/dev/null && ! umount -l "$target" 2>/dev/null; then
        printf 'CLEANUP_UNMOUNT_FAILED target=%s\n' "$target" >&2
        return 1
      fi
    done
  done
  if [[ -n "$(mount_targets_under "$root")" ]]; then
    printf 'CLEANUP_MOUNT_REMAINS root=%s\n' "$root" >&2
    return 1
  fi
}

safe_remove_tree() {
  local root=$1
  if [[ -n "$(mount_targets_under "$root")" ]]; then
    printf 'CLEANUP_REMOVE_REFUSED root=%s\n' "$root" >&2
    return 1
  fi
  rm -rf -- "$root"
}

cleanup_id() {
  local id=$1
  local share="$SHARE_BASE/$id"
  local source="$SOURCE_BASE-$id"
  case "$id" in
    s02-*) ;;
    *)
      printf 'CLEANUP_ID_REFUSED id=%s\n' "$id" >&2
      return 1
      ;;
  esac
  ctr tasks kill --signal SIGKILL "$id" 2>/dev/null || true
  ctr tasks delete "$id" 2>/dev/null || true
  ctr containers delete "$id" 2>/dev/null || true
  detach_mounts_under "$share" || return 1
  safe_remove_tree "$share" || return 1
  detach_mounts_under "$source" || return 1
  safe_remove_tree "$source"
}

cleanup() {
  local rc=$?
  local cleanup_rc=0
  trap - EXIT
  if [[ -n "$current_id" ]]; then
    cleanup_id "$current_id" || cleanup_rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    exit "$rc"
  fi
  exit "$cleanup_rc"
}
trap cleanup EXIT

cube_annotations=(
  --runtime "$RUNTIME"
  --annotation io.containerd.cube.s0.standard-rootfs=true
  --annotation 'cube.vmmres={"cpu":2,"memory":1024}'
  --annotation "cube.vm.kernel.path=$KERNEL"
  --annotation "cube.vm.agent.path=$AGENT"
  --annotation "cube.vm.os-image.path=$GUEST_IMAGE"
)

preflight() {
  test -S "$ADDRESS"
  test -c /dev/kvm
  test -r "$KERNEL"
  test -r "$AGENT"
  test -r "$GUEST_IMAGE"
  ctr images list -q | grep -Fx "$IMAGE" >/dev/null
  mkdir -p "$SHARE_BASE"
}

wait_for_zero() {
  local attempt
  for attempt in $(seq 1 100); do
    if [[ $(ctr tasks list -q | wc -l) -eq 0 ]] &&
      [[ $(ctr containers list -q | wc -l) -eq 0 ]] &&
      [[ $(findmnt -rn -o TARGET | grep -Ec "^$SHARE_BASE/s02-" || true) -eq 0 ]] &&
      [[ $(find "$SHARE_BASE" -mindepth 1 -maxdepth 1 -name 's02-*' 2>/dev/null | wc -l) -eq 0 ]] &&
      [[ $(ps -eo args | grep -c "[c]ontainerd-shim-cube-rs -namespace $NAMESPACE " || true) -eq 0 ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

assert_zero() {
  local mounts shares tasks containers shims
  mounts=$(findmnt -rn -o TARGET | grep -Ec "^$SHARE_BASE/s02-" || true)
  shares=$(find "$SHARE_BASE" -mindepth 1 -maxdepth 1 -name 's02-*' 2>/dev/null | wc -l)
  tasks=$(ctr tasks list -q | wc -l)
  containers=$(ctr containers list -q | wc -l)
  shims=$(ps -eo args | grep -c "[c]ontainerd-shim-cube-rs -namespace $NAMESPACE " || true)
  printf 'RESIDUE mounts=%s shares=%s tasks=%s containers=%s shims=%s\n' \
    "$mounts" "$shares" "$tasks" "$containers" "$shims"
  [[ $mounts -eq 0 && $shares -eq 0 && $tasks -eq 0 && $containers -eq 0 && $shims -eq 0 ]]
}

guest_exec() {
  local id=$1
  local command=$2
  GUEST_SOCKET="/run/vc/vm/$id/cube.sock" GUEST_COMMAND="$command" python3 - <<'PY'
import os
import re
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
sock.connect(os.environ["GUEST_SOCKET"])
sock.sendall(b"CONNECT 1026\n")
response = b""
while not response.endswith(b"\n"):
    response += sock.recv(128)
command = os.environ["GUEST_COMMAND"]
sock.sendall((f"({command}); rc=$?; echo __S0_RC__=$rc; exit\n").encode())
chunks = []
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    try:
        data = sock.recv(4096)
    except socket.timeout:
        continue
    if not data:
        break
    chunks.append(data)
    if re.search(rb"__S0_RC__=\d+", b"".join(chunks)):
        break
output = b"".join(chunks).decode(errors="replace")
sys.stdout.write(output)
match = re.search(r"__S0_RC__=(\d+)", output)
if match is None:
    raise SystemExit(125)
raise SystemExit(int(match.group(1)))
PY
}

guest_exec_eventually() {
  local id=$1
  local command=$2
  local attempt
  for attempt in $(seq 1 50); do
    if guest_exec "$id" "$command"; then
      printf 'GUEST_VISIBILITY_OK attempt=%s\n' "$attempt"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

standard_rootfs_case() {
  local output rc
  current_id=s02-standard
  cleanup_id "$current_id"
  set +e
  output=$(ctr run --rm "${cube_annotations[@]}" "$IMAGE" "$current_id" \
    /bin/sh -c 'echo STANDARD_OCI_ROOTFS_OK; exit 23' 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$output"
  [[ $rc -eq 23 ]]
  grep -q STANDARD_OCI_ROOTFS_OK <<<"$output"
  current_id=
  wait_for_zero
  assert_zero
}

dynamic_mount_case() {
  local id share source_dir guest_share
  id=s02-dynamic
  share="$SHARE_BASE/$id"
  source_dir="$SOURCE_BASE-$id"
  guest_share="/run/cube-containers/shared/containers/$id"
  current_id=$id
  cleanup_id "$id"

  ctr run -d "${cube_annotations[@]}" "$IMAGE" "$id" /bin/sh -c 'sleep 300'
  for _ in $(seq 1 50); do
    [[ -S "/run/vc/vm/$id/cube.sock" ]] && break
    sleep 0.1
  done
  test -S "/run/vc/vm/$id/cube.sock"

  mkdir -p "$source_dir" "$share/dynamic/bind"
  printf dynamic-bind-visible >"$source_dir/value"
  mount --bind "$source_dir" "$share/dynamic/bind"
  guest_exec_eventually "$id" \
    "test \"\$(cat $guest_share/dynamic/bind/value)\" = dynamic-bind-visible && echo DYNAMIC_BIND_VISIBLE"

  printf rename-visible >"$share/dynamic/name-old"
  mv "$share/dynamic/name-old" "$share/dynamic/name-new"
  guest_exec_eventually "$id" \
    "test -f $guest_share/dynamic/name-new && test ! -e $guest_share/dynamic/name-old && echo DYNAMIC_RENAME_VISIBLE"

  mount -o remount,bind,ro "$share/dynamic/bind"
  if guest_exec "$id" "printf should-fail >> $guest_share/dynamic/bind/value"; then
    echo DYNAMIC_READ_ONLY_FAILED
    return 1
  fi
  echo DYNAMIC_READ_ONLY_ENFORCED

  if umount "$share/dynamic/bind"; then
    echo DYNAMIC_UNMOUNT_REGULAR
  else
    umount -l "$share/dynamic/bind"
    echo DYNAMIC_UNMOUNT_DETACHED
  fi
  ! findmnt -rn -o TARGET | grep -Fx "$share/dynamic/bind" >/dev/null
  if guest_exec "$id" "test -e $guest_share/dynamic/bind/value"; then
    echo DYNAMIC_STALE_INODE_UNTIL_TASK_DELETE
  else
    echo DYNAMIC_IMMEDIATE_INVALIDATION
  fi

  rm -f "$share/dynamic/name-new"
  rmdir "$share/dynamic/bind" "$share/dynamic"
  safe_remove_tree "$source_dir"

  ctr tasks kill --signal SIGKILL "$id"
  ctr tasks delete "$id"
  [[ $(findmnt -rn -o TARGET | grep -c "^$share/" || true) -eq 0 ]]
  ctr containers delete "$id"
  current_id=
  wait_for_zero
  assert_zero
  echo DYNAMIC_MOUNT_MATRIX_OK
}

cycle_case() {
  local index id output
  for index in $(seq -w 1 "$CYCLES"); do
    id="s02-cycle-$index"
    current_id=$id
    cleanup_id "$id"
    output=$(ctr run --rm "${cube_annotations[@]}" "$IMAGE" "$id" \
      /bin/sh -c 'echo CUBE_S0_CYCLE_OK')
    grep -q CUBE_S0_CYCLE_OK <<<"$output"
    current_id=
    wait_for_zero
    [[ $(findmnt -rn -o TARGET | grep -Ec "^$SHARE_BASE/s02-" || true) -eq 0 ]]
    printf 'CYCLE_OK %s\n' "$index"
  done
  assert_zero
  printf 'CYCLE_MATRIX_OK cycles=%s\n' "$CYCLES"
}

preflight
wait_for_zero
standard_rootfs_case
dynamic_mount_case
cycle_case
echo S0_2_ROOTFS_PROBE_OK
