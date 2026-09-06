#!/usr/bin/env bash
# Stage explicitly supplied base artifacts; never extract an entire runtime distribution.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$PWD/_output/cube-cri
mkdir -p "$out/assets"
[[ -z ${GUEST_KERNEL:-} ]] || cp "$GUEST_KERNEL" "$out/assets/kernel"
[[ -z ${GUEST_IMAGE:-} ]] || cp "$GUEST_IMAGE" "$out/assets/guest.img"
[[ -z ${PVM_HOST_RPM:-} ]] || cp "$PVM_HOST_RPM" "$out/pvm-host.rpm"
