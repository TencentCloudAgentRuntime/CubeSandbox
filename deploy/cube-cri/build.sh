#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
out=$root/_output/cube-cri
mkdir -p "$out/bin" "$out/assets"
builder() {
  local cache=${BUILDER_HOME:-$HOME/.cache/cube-sandbox-builder}
  mkdir -p "$cache"
  docker run --rm -i --user "$(id -u):$(id -g)" \
    -e HOME=/home/builder -e CARGO_HOME=/home/builder/.cargo \
    -e RUSTUP_HOME=/usr/local/rustup -e RUSTUP_TOOLCHAIN=1.89 \
    -v "$root:/workspace" -v "$cache:/home/builder" -w /workspace \
    "${BUILDER_IMAGE:-cube-sandbox-builder:ubuntu2004}" bash -lc "$1"
}
case "${1:-runtime}" in
  builder) make builder-image ;;
  cubelet)
    (cd Cubelet; CGO_ENABLED=0 go build -trimpath -o "$out/bin/cubelet-cri" ./cmd/cubelet-cri) ;;
  shim)
    (cd CubeShim; cargo build --release --locked -p containerd-shim-cube-rs)
    install CubeShim/target/release/{containerd-shim-cube-rs,cube-vmm-worker,cube-template-builder} "$out/bin/" ;;
  agent)
    builder 'cd agent && make && cd /workspace && OUTPUT_DIR=/workspace/_output/cube-agent ONE_CLICK_CUBE_AGENT_BIN=/workspace/agent/target/x86_64-unknown-linux-musl/release/cube-agent bash deploy/one-click/build-agent-ext4.sh'
    cp _output/cube-agent/cube-agent.ext4 "$out/assets/agent" ;;
  guest)
    builder 'cd guest-init && make -B && make BINDIR=/workspace/_output/bin install'
    OUTPUT_DIR="$out/guest" ONE_CLICK_CUBE_INIT_BIN="$root/_output/bin/cube-init" bash deploy/one-click/build-guest-image.sh
    cp "$out/guest/cube-guest-image-cpu.img" "$out/assets/guest.img" ;;
  kernel)
    WORK_DIR="$out/pvm-guest-build" bash deploy/pvm/build-pvm-guest-vmlinux.sh
    cp "$out/pvm-guest-build/output/vmlinux" "$out/assets/kernel" ;;
  pvm-host)
    WORK_DIR="$out/pvm-host-build" bash deploy/pvm/build-pvm-host-kernel-pkg.sh
    shopt -s nullglob
    rpms=("$out"/pvm-host-build/output/kernel-[0-9]*.rpm)
    ((${#rpms[@]} == 1)) || { echo '需要唯一的 PVM kernel RPM' >&2; exit 1; }
    cp "${rpms[0]}" "$out/pvm-host.rpm" ;;
  runtime)
    for component in cubelet shim agent; do bash "$0" "$component"; done ;;
  all)
    for component in runtime guest kernel; do bash "$0" "$component"; done ;;
  *) echo "unknown component: $1" >&2; exit 2 ;;
esac
