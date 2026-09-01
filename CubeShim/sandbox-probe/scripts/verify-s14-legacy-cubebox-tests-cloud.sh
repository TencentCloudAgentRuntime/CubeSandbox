#!/bin/bash
set -Eeuo pipefail

source_tree=/opt/cubesandbox-s12-a9c4cc3b
source_tree_id=a9c4cc3bcd7a8d7ab4362e142f3e77df88946045
vendor_archive=/opt/s14-cubecow-vendor.tar.gz
vendor_sha=9469425277208579f969da435dac33e9a1dcf04add893c4b3abc97e704cc63ab
go_vendor_archive=/opt/s14-cubelet-go-vendor-v2.tar.gz
go_vendor_sha=1bd2bfdec14081e273a3ae8ee65623397771807b92cfced037b82dfd0b4b7c25
rust_image=mirror.ccs.tencentyun.com/library/rust@sha256:408fe88047cef61a2087653b0c5255fa51c0f2d6d94ddedd7a2562a9b91a46f6
rust_config_digest=sha256:897e260d0a1a5a5146433bdb73f62bd84f5f47e846d3485e5f70f63912b5917d
rust_docker_image_id=sha256:408fe88047cef61a2087653b0c5255fa51c0f2d6d94ddedd7a2562a9b91a46f6
go_image=mirror.ccs.tencentyun.com/library/golang@sha256:3bf5b04541eb4a37fe62aa1bc9c98a1dec09db9d2e79c1d2eb54e3c9d08dbca9
go_config_digest=sha256:eafdda676c2e68f1d9a6574d33f89db1d6933e24f5be8e2cbe003b864fc865c9
go_docker_image_id=sha256:3bf5b04541eb4a37fe62aa1bc9c98a1dec09db9d2e79c1d2eb54e3c9d08dbca9
work=$(mktemp -d /tmp/s14-legacy-cubebox.XXXXXX)
vendor=$work/s14-cubecow-vendor
evidence=/data/cubelet/s1.4-evidence/legacy-cubebox-tests-$(date -u +%Y%m%dT%H%M%SZ)-$$
package=github.com/tencentcloud/CubeSandbox/Cubelet/services/cubebox

cleanup() {
  rc=$?
  if test "$rc" -ne 0; then
    tail -n 240 "$evidence/cubecow-build.log" 2>/dev/null || true
    tail -n 240 "$evidence/cubevs-generate.log" 2>/dev/null || true
    tail -n 240 "$evidence/cubebox-test.jsonl" 2>/dev/null || true
  fi
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT

install -d -m 0700 "$evidence"
command -v jq >/dev/null
test "$(uname -m)" = x86_64
test "$(git -C "$source_tree" write-tree)" = "$source_tree_id"
test "$(git -C "$source_tree" cat-file -t "$source_tree_id")" = tree
test "$(sha256sum "$vendor_archive" | awk '{print $1}')" = "$vendor_sha"
test "$(sha256sum "$go_vendor_archive" | awk '{print $1}')" = "$go_vendor_sha"
tar -xzf "$vendor_archive" -C "$work"
test -d "$vendor/tracing-appender"
git -C "$source_tree" archive "$source_tree_id" | tar -x -C "$work"
tar -xzf "$go_vendor_archive" -C "$work"

docker pull "$rust_image" >"$evidence/rust-image.log"
docker manifest inspect "$rust_image" >"$evidence/rust-registry-manifest.json"
test "$(jq -r '.config.digest' "$evidence/rust-registry-manifest.json")" = "$rust_config_digest"
test "$(docker image inspect "$rust_image" --format '{{.Id}}')" = "$rust_docker_image_id"
docker image inspect "$rust_image" --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep -Fxq "$rust_image"
docker image inspect "$rust_image" >"$evidence/rust-image-inspect.json"
docker run --rm \
  --network none \
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

docker pull "$go_image" >"$evidence/go-image.log"
docker manifest inspect "$go_image" >"$evidence/go-registry-manifest.json"
test "$(jq -r '.config.digest' "$evidence/go-registry-manifest.json")" = "$go_config_digest"
test "$(docker image inspect "$go_image" --format '{{.Id}}')" = "$go_docker_image_id"
docker image inspect "$go_image" --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep -Fxq "$go_image"
docker image inspect "$go_image" >"$evidence/go-image-inspect.json"
docker run --rm \
  --mount "type=bind,src=$work,dst=/workspace" \
  --workdir /workspace \
  --env GOFLAGS=-mod=vendor \
  --env GOARCH=amd64 \
  --env GOPROXY=off \
  --env GOSUMDB=off \
  "$go_image" bash -ec '
    sed -i "s|deb.debian.org/debian|mirrors.tencent.com/debian|g; s|security.debian.org/debian-security|mirrors.tencent.com/debian-security|g" /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
    apt-get update >/workspace/s14-bpf-apt.log 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential clang libbpf-dev libelf-dev llvm make pkg-config >>/workspace/s14-bpf-apt.log 2>&1
    {
      cat /etc/os-release
      dpkg-query -W -f="\${Package}\t\${Version}\n" \
        build-essential clang libbpf-dev libelf-dev llvm make pkg-config
      clang --version
      llc --version
      gcc --version
      make --version
      pkg-config --version
      go version
    } >/workspace/s14-bpf-toolchain.txt 2>&1
    cd /workspace/CubeNet/cubevs
    cubelet_cubevs=/workspace/Cubelet/vendor/github.com/tencentcloud/CubeSandbox/CubeNet/cubevs
    test -d "$cubelet_cubevs"
    expected=(
      dnslearn_x86_bpfel_test.go dnslearn_x86_bpfel_test.o
      egresspolicy_x86_bpfel_test.go egresspolicy_x86_bpfel_test.o
      l7mark_x86_bpfel_test.go l7mark_x86_bpfel_test.o
      localgw_x86_bpfel.go localgw_x86_bpfel.o
      mvmtap_x86_bpfel.go mvmtap_x86_bpfel.o
      nodenic_x86_bpfel.go nodenic_x86_bpfel.o
      tcpstate_x86_bpfel_test.go tcpstate_x86_bpfel_test.o
    )
    find . -maxdepth 1 -type f \( -name "*_bpfel*.go" -o -name "*_bpfel*.o" \) -delete
    find "$cubelet_cubevs" -maxdepth 1 -type f \
      \( -name "*_bpfel*.go" -o -name "*_bpfel*.o" \) -delete
    make gen
    printf "%s\n" "${expected[@]}" | sort >/tmp/expected-bpf-files
    find . -maxdepth 1 -type f \( -name "*_bpfel*.go" -o -name "*_bpfel*.o" \) \
      -printf "%f\n" | sort >/tmp/actual-bpf-files
    diff -u /tmp/expected-bpf-files /tmp/actual-bpf-files
    : >/workspace/s14-generated-bpf-sha256.tsv
    for name in "${expected[@]}"; do
      test -s "$name"
      install -m 0644 "$name" "$cubelet_cubevs/$name"
      test -s "$cubelet_cubevs/$name"
      source_sha=$(sha256sum "$name" | cut -d " " -f 1)
      destination_sha=$(sha256sum "$cubelet_cubevs/$name" | cut -d " " -f 1)
      test "$source_sha" = "$destination_sha"
      printf "%s\t%s\t%s\n" "$name" "$source_sha" "$destination_sha" \
        >>/workspace/s14-generated-bpf-sha256.tsv
    done
    find "$cubelet_cubevs" -maxdepth 1 -type f \
      \( -name "*_bpfel*.go" -o -name "*_bpfel*.o" \) \
      -printf "%f\n" | sort >/tmp/copied-bpf-files
    diff -u /tmp/expected-bpf-files /tmp/copied-bpf-files
  ' >"$evidence/cubevs-generate.log" 2>&1
install -m 0600 "$work/s14-bpf-apt.log" "$evidence/bpf-apt.log"
install -m 0600 "$work/s14-bpf-toolchain.txt" "$evidence/bpf-toolchain.txt"
install -m 0600 "$work/s14-generated-bpf-sha256.tsv" "$evidence/generated-bpf-sha256.tsv"
test "$(wc -l <"$evidence/generated-bpf-sha256.tsv")" -eq 14

docker run --rm \
  --network none \
  --mount "type=bind,src=$work,dst=/workspace" \
  --workdir /workspace/Cubelet \
  --env CGO_ENABLED=1 \
  --env GOFLAGS=-mod=vendor \
  --env GOARCH=amd64 \
  --env GOPROXY=off \
  --env GOSUMDB=off \
  "$go_image" bash -ec '
    go test -json -race -count=1 ./services/cubebox
  ' >"$evidence/cubebox-test.jsonl" 2>&1
if grep -Eqi '\(cached\)|\[no test files\]|\[no tests to run\]' "$evidence/cubebox-test.jsonl"; then
  printf 'refusing cached or empty test result\n' >&2
  exit 1
fi
test "$(jq -r 'select(.Package != null) | .Package' "$evidence/cubebox-test.jsonl" | sort -u)" = "$package"
test "$(jq -s --arg package "$package" \
  '[.[] | select(.Package == $package and .Action == "pass" and (has("Test") | not))] | length' \
  "$evidence/cubebox-test.jsonl")" -eq 1
test "$(jq -s '[.[] | select(.Action == "fail")] | length' "$evidence/cubebox-test.jsonl")" -eq 0
test_count=$(jq -s --arg package "$package" \
  '[.[] | select(.Package == $package and .Action == "pass" and .Test != null)] | length' \
  "$evidence/cubebox-test.jsonl")
test "$test_count" -gt 0
run_count=$(jq -s --arg package "$package" \
  '[.[] | select(.Package == $package and .Action == "run" and .Test != null)] | length' \
  "$evidence/cubebox-test.jsonl")
test "$run_count" -eq "$test_count"
printf 'package=%s\nrun_count=%s\npass_count=%s\nrace=true\ncount=1\n' \
  "$package" "$run_count" "$test_count" >"$evidence/cubebox-test-summary.txt"

printf 'S14_LEGACY_CUBEBOX_TESTS_OK source_tree=%s cubecow=offline cubevs_bpf=14 race=passed tests=%s evidence=%s\n' \
  "$source_tree_id" "$test_count" "$evidence"
trap - EXIT
rm -rf -- "$work"
