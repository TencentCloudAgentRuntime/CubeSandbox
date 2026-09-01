#!/usr/bin/env bash
set -Eeuo pipefail

input=/data/cubelet/s3.4-input
source_archive=$input/cubesandbox-s34a-source.tar.gz
patch_rel=CubeShim/sandbox-probe/patches/containerd-v2.3.4-s34-trace.patch
expected_patch=19128819e0a72097e923bae6f5720938648e5368bb054989a9417744e4d5cadc
go_version=go1.26.3
containerd_version=v2.3.4
token=s34a-build-$(date -u +%Y%m%dT%H%M%SZ)-$$
evidence=/data/cubelet/s3.4-evidence/$token
work=$evidence/work
downloads=$evidence/downloads
artifacts=$input/bin

mkdir -p "$work" "$downloads" "$artifacts"
test -f "$source_archive"
sha256sum "$source_archive" >"$evidence/source-archive.sha256"
tar -xzf "$source_archive" -C "$work"
source_root=$work/CubeSandbox
test -f "$source_root/$patch_rel"
test "$(sha256sum "$source_root/$patch_rel" | awk '{print $1}')" = "$expected_patch"

curl -fsSL 'https://go.dev/dl/?mode=json&include=all' -o "$downloads/go-downloads.json"
go_sha=$(jq -er --arg version "$go_version" '
  .[] | select(.version == $version) | .files[] |
  select(.os == "linux" and .arch == "amd64" and .kind == "archive") | .sha256
' "$downloads/go-downloads.json")
test "$(wc -l <<<"$go_sha")" -eq 1
go_archive=$downloads/$go_version.linux-amd64.tar.gz
curl -fsSL "https://go.dev/dl/$go_version.linux-amd64.tar.gz" -o "$go_archive"
printf '%s  %s\n' "$go_sha" "$go_archive" | sha256sum -c - | tee "$evidence/go-archive.verify"
mkdir -p "$work/toolchain"
tar -xzf "$go_archive" -C "$work/toolchain"
go=$work/toolchain/go/bin/go
"$go" version | tee "$evidence/go-version.txt"

export GOCACHE=$work/go-cache
export GOMODCACHE=$work/go-mod-cache
export CCACHE_DIR=$work/ccache
mkdir -p "$GOCACHE" "$GOMODCACHE" "$CCACHE_DIR"
"$go" mod download -json "github.com/containerd/containerd/v2@$containerd_version" >"$evidence/containerd-module.json"
test "$(jq -r '.Version' "$evidence/containerd-module.json")" = "$containerd_version"
test -n "$(jq -r '.Sum' "$evidence/containerd-module.json")"
containerd_module=$(jq -er '.Dir' "$evidence/containerd-module.json")
containerd_source=$work/containerd-${containerd_version#v}
cp -a "$containerd_module" "$containerd_source"
chmod -R u+w "$containerd_source"
test -f "$containerd_source/cmd/containerd/main.go"
patch --directory "$containerd_source" -p1 --fuzz=0 --no-backup-if-mismatch <"$source_root/$patch_rel" | tee "$evidence/containerd-patch.log"
gofmt_files=(client/task.go internal/cri/instrument/instrumented_service.go pkg/s34trace/trace.go)
for file in "${gofmt_files[@]}"; do "$work/toolchain/go/bin/gofmt" -w "$containerd_source/$file"; done

(
  cd "$containerd_source"
  "$go" test ./pkg/s34trace ./client ./internal/cri/instrument
) 2>&1 | tee "$evidence/containerd-tests.log"
(
  cd "$containerd_source"
  CGO_ENABLED=1 "$go" build -trimpath \
    -ldflags "-X github.com/containerd/containerd/v2/version.Version=$containerd_version -X github.com/containerd/containerd/v2/version.Revision=s34a-trace -X github.com/containerd/containerd/v2/version.Package=github.com/containerd/containerd/v2" \
    -o "$artifacts/containerd-s34a-trace" ./cmd/containerd
) 2>&1 | tee "$evidence/containerd-build.log"

(
  cd "$source_root/CubeShim/sandbox-probe"
  "$go" test ./cmd/s34-resource-evidence
  "$go" list -m -json k8s.io/cri-api >"$evidence/helper-cri-api-module.json"
  test "$(jq -r '.Path + "@" + .Version' "$evidence/helper-cri-api-module.json")" = 'k8s.io/cri-api@v0.36.4'
  CGO_ENABLED=1 "$go" build -trimpath -o "$artifacts/s34-resource-evidence" ./cmd/s34-resource-evidence
) 2>&1 | tee "$evidence/helper-build.log"

chmod 0755 "$artifacts/containerd-s34a-trace" "$artifacts/s34-resource-evidence"
sha256sum "$artifacts/containerd-s34a-trace" "$artifacts/s34-resource-evidence" >"$artifacts/SHA256SUMS"
cp "$source_root/$patch_rel" "$evidence/containerd-v2.3.4-s34-trace.patch"
sha256sum "$evidence/containerd-v2.3.4-s34-trace.patch" >"$evidence/containerd-patch.sha256"
"$artifacts/containerd-s34a-trace" --version | tee "$evidence/containerd-artifact-version.txt"
"$artifacts/s34-resource-evidence" schema | tee "$evidence/helper-schema.txt"
"$artifacts/s34-resource-evidence" 2>"$evidence/helper-usage.txt" || test "$?" -eq 2

printf 'S34A_BUILD_OK evidence=%s containerd=%s helper=%s patch=%s source=%s go=%s\n' \
  "$evidence" \
  "$(sha256sum "$artifacts/containerd-s34a-trace" | awk '{print $1}')" \
  "$(sha256sum "$artifacts/s34-resource-evidence" | awk '{print $1}')" \
  "$expected_patch" \
  "$(sha256sum "$source_archive" | awk '{print $1}')" \
  "$go_sha"
