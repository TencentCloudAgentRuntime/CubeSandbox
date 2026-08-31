#!/bin/bash
set -Eeuo pipefail

probe=/opt/s14-rootfs-probe-v3.sh
probe_sha=5f6b55492171ae0e5bd3e6c9fb5215beb9e8119b6ad691578dcd9ff021632b9b
shim=/usr/local/bin/containerd-shim-cube-rs
shim_sha=39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd
address=/run/containerd-cube-s0.2/containerd.sock
namespace=s0-2
share=/data/cubelet/s0.2-share
source_base=/data/cubelet/s14-legacy-source
evidence=/data/cubelet/s1.4-evidence/legacy-shim-$(date -u +%Y%m%dT%H%M%SZ)

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
    if test "${#targets[@]}" -eq 0; then return 0; fi
    for target in "${targets[@]}"; do
      if ! umount "$target" 2>/dev/null && ! umount -l "$target" 2>/dev/null; then
        printf 'S14_LEGACY_CLEANUP_UNMOUNT_FAILED target=%s\n' "$target" >&2
        return 1
      fi
    done
  done
  if test -n "$(mount_targets_under "$root")"; then
    printf 'S14_LEGACY_CLEANUP_MOUNT_REMAINS root=%s\n' "$root" >&2
    return 1
  fi
}

safe_remove_tree() {
  local root=$1
  if test -n "$(mount_targets_under "$root")"; then
    printf 'S14_LEGACY_CLEANUP_REMOVE_REFUSED root=%s\n' "$root" >&2
    return 1
  fi
  rm -rf -- "$root"
}

cleanup() {
  local rc=$?
  local cleanup_rc=0 owned
  local -a owned_shares owned_sources
  trap - EXIT
  set +e
  mapfile -t owned_shares < <(find "$share" -mindepth 1 -maxdepth 1 -name 's02-*' -print 2>/dev/null)
  for owned in "${owned_shares[@]}"; do
    detach_mounts_under "$owned" && safe_remove_tree "$owned" || cleanup_rc=1
  done
  mapfile -t owned_sources < <(find /data/cubelet -mindepth 1 -maxdepth 1 -name 's14-legacy-source-s02-*' -print 2>/dev/null)
  for owned in "${owned_sources[@]}"; do
    detach_mounts_under "$owned" && safe_remove_tree "$owned" || cleanup_rc=1
  done
  if test "$rc" -ne 0; then exit "$rc"; fi
  exit "$cleanup_rc"
}
trap cleanup EXIT

install -d -m 0700 "$evidence"
test -r "$probe"
test "$(sha256sum "$probe" | awk '{print $1}')" = "$probe_sha"
test "$(sha256sum "$shim" | awk '{print $1}')" = "$shim_sha"
systemctl is-active --quiet containerd-cube-s0.2.service
test -S "$address"
test "$(ctr --address "$address" --namespace "$namespace" tasks list -q | wc -l)" -eq 0
test "$(ctr --address "$address" --namespace "$namespace" containers list -q | wc -l)" -eq 0
test "$(find "$share" -mindepth 1 -maxdepth 1 -name 's02-*' 2>/dev/null | wc -l)" -eq 0
test "$(find /run/vc/vm -mindepth 1 -maxdepth 1 -name 's02-*' 2>/dev/null | wc -l)" -eq 0
test -z "$(ps -eo args= | awk -v ns="$namespace" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {for (i=2;i<=NF;i++) if ($i=="-namespace" && $(i+1)==ns) print}')"
systemctl is-active --quiet containerd
crictl --runtime-endpoint unix:///run/containerd/containerd.sock info \
  >"$evidence/primary-cri-before.json"
jq -e '.status.conditions[] | select(.type == "RuntimeReady" and .status == true)' \
  "$evidence/primary-cri-before.json" >/dev/null

if ! ADDRESS="$address" NAMESPACE="$namespace" CYCLES=20 \
  SHARE_BASE="$share" SOURCE_BASE="$source_base" \
  bash "$probe" >"$evidence/probe.log" 2>&1; then
  tail -n 260 "$evidence/probe.log"
  exit 1
fi
grep -F 'S0_2_ROOTFS_PROBE_OK' "$evidence/probe.log"
grep -F 'CYCLE_MATRIX_OK cycles=20' "$evidence/probe.log"
grep -F 'DYNAMIC_MOUNT_MATRIX_OK' "$evidence/probe.log"
grep -F 'STANDARD_OCI_ROOTFS_OK' "$evidence/probe.log"
test "$(ctr --address "$address" --namespace "$namespace" tasks list -q | wc -l)" -eq 0
test "$(ctr --address "$address" --namespace "$namespace" containers list -q | wc -l)" -eq 0
test "$(findmnt -rn -o TARGET | grep -Ec "^$share/s02-" || true)" -eq 0
test "$(find "$share" -mindepth 1 -maxdepth 1 -name 's02-*' 2>/dev/null | wc -l)" -eq 0
test "$(find /run/vc/vm -mindepth 1 -maxdepth 1 -name 's02-*' 2>/dev/null | wc -l)" -eq 0
test -z "$(ps -eo args= | awk -v ns="$namespace" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {for (i=2;i<=NF;i++) if ($i=="-namespace" && $(i+1)==ns) print}')"
crictl --runtime-endpoint unix:///run/containerd/containerd.sock info \
  >"$evidence/primary-cri-after.json"
jq -e '.status.conditions[] | select(.type == "RuntimeReady" and .status == true)' \
  "$evidence/primary-cri-after.json" >/dev/null

printf 'S14_LEGACY_SHIM_OK cycles=20 standard_rootfs=ok dynamic_mount=ok tasks=0 containers=0 mounts=0 vm_runtime=0 shims=0 shim_sha256=%s evidence=%s\n' \
  "$shim_sha" "$evidence"
trap - EXIT
