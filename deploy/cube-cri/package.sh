#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$PWD/_output/cube-cri
files=(bin/cubelet-cri bin/containerd-shim-cube-rs bin/cube-vmm-worker bin/cube-template-builder assets/kernel assets/agent assets/guest.img)
for file in "${files[@]}"; do
  test -s "$out/$file" || { echo "缺少制品: $out/$file" >&2; exit 1; }
done
cp deploy/cube-cri/{install.sh,containerd.py} "$out/"
cp deploy/kubernetes/runtimeclass/{install-watchdog.sh,cubesandbox-shim-watchdog.service,runtimeclass-overhead.json} "$out/"
(cd "$out"; sha256sum "${files[@]}" > SHA256SUMS; tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - "${files[@]}" SHA256SUMS install.sh containerd.py install-watchdog.sh cubesandbox-shim-watchdog.service runtimeclass-overhead.json | gzip -n > runtime.tar.gz)
