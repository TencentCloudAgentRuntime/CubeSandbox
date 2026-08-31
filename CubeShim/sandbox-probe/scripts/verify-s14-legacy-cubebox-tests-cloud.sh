#!/bin/bash
set -Eeuo pipefail

source_tree=/opt/cubesandbox-s12-a9c4cc3b
source_tree_id=a9c4cc3bcd7a8d7ab4362e142f3e77df88946045
vendor_archive=/opt/s14-cubecow-vendor.tar.gz
vendor_sha=9469425277208579f969da435dac33e9a1dcf04add893c4b3abc97e704cc63ab
vendor=/opt/s14-cubecow-vendor
go_vendor_archive=/opt/s14-cubelet-go-vendor-v2.tar.gz
go_vendor_sha=1bd2bfdec14081e273a3ae8ee65623397771807b92cfced037b82dfd0b4b7c25
rust_image=mirror.ccs.tencentyun.com/library/rust:1.97.1-bookworm
go_image=mirror.ccs.tencentyun.com/library/golang:1.26.3-bookworm
work=$(mktemp -d /tmp/s14-legacy-cubebox.XXXXXX)
evidence=/data/cubelet/s1.4-evidence/legacy-cubebox-tests-$(date -u +%Y%m%dT%H%M%SZ)

cleanup() {
  rc=$?
  if test "$rc" -ne 0; then
    tail -n 240 "$evidence/cubecow-build.log" 2>/dev/null || true
    tail -n 240 "$evidence/cubevs-generate.log" 2>/dev/null || true
    tail -n 240 "$evidence/cubebox-test.log" 2>/dev/null || true
  fi
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT

install -d -m 0700 "$evidence"
test "$(git -C "$source_tree" write-tree)" = "$source_tree_id"
test "$(git -C "$source_tree" cat-file -t "$source_tree_id")" = tree
test "$(sha256sum "$vendor_archive" | awk '{print $1}')" = "$vendor_sha"
test "$(sha256sum "$go_vendor_archive" | awk '{print $1}')" = "$go_vendor_sha"
if test ! -d "$vendor"; then
  tar -xzf "$vendor_archive" -C /opt
fi
test -d "$vendor/tracing-appender"
git -C "$source_tree" archive "$source_tree_id" | tar -x -C "$work"
tar -xzf "$go_vendor_archive" -C "$work"

docker pull "$rust_image" >"$evidence/rust-image.log"
docker run --rm \
  --mount "type=bind,src=$work,dst=/workspace" \
  --mount "type=bind,src=$vendor,dst=/vendor,readonly" \
  --workdir /workspace/cubecow \
  --env RUSTUP_TOOLCHAIN=1.97.1-x86_64-unknown-linux-gnu \
  "$rust_image" bash -ec '
    cargo \
      --config "source.crates-io.replace-with=\"vendored-sources\"" \
      --config "source.vendored-sources.directory=\"/vendor\"" \
      build --release --offline --locked
  ' >"$evidence/cubecow-build.log" 2>&1
install -d -m 0755 "$work/Cubelet/third_party/cubecow/lib" "$work/Cubelet/third_party/cubecow/include"
install -m 0644 "$work/cubecow/target/release/libcubecow.a" "$work/Cubelet/third_party/cubecow/lib/libcubecow.a"
install -m 0644 "$work/cubecow/include/cubecow.h" "$work/Cubelet/third_party/cubecow/include/cubecow.h"

docker run --rm \
  --mount "type=bind,src=$work,dst=/workspace" \
  --workdir /workspace \
  --env GOFLAGS=-mod=vendor \
  --env GOPROXY=off \
  "$go_image" bash -ec '
    sed -i "s|deb.debian.org/debian|mirrors.tencent.com/debian|g; s|security.debian.org/debian-security|mirrors.tencent.com/debian-security|g" /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
    apt-get update >/tmp/apt.log 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential clang libbpf-dev libelf-dev llvm make pkg-config >>/tmp/apt.log 2>&1
    cd /workspace/CubeNet/cubevs
    make gen
    cubelet_cubevs=/workspace/Cubelet/vendor/github.com/tencentcloud/CubeSandbox/CubeNet/cubevs
    test -d "$cubelet_cubevs"
    find . -maxdepth 1 -type f \( -name "*_bpfel*.go" -o -name "*_bpfel*.o" \) \
      -exec cp -a -- {} "$cubelet_cubevs/" \;
  ' >"$evidence/cubevs-generate.log" 2>&1

docker run --rm \
  --mount "type=bind,src=$work,dst=/workspace" \
  --workdir /workspace/Cubelet \
  --env CGO_ENABLED=1 \
  --env GOFLAGS=-mod=vendor \
  --env GOPROXY=off \
  "$go_image" bash -ec '
    go test -race -count=1 ./services/cubebox
  ' >"$evidence/cubebox-test.log" 2>&1
grep -Fq 'ok  ' "$evidence/cubebox-test.log"

printf 'S14_LEGACY_CUBEBOX_TESTS_OK source_tree=%s cubecow=offline cubevs_bpf=generated race=passed evidence=%s\n' \
  "$source_tree_id" "$evidence"
trap - EXIT
rm -rf -- "$work"
