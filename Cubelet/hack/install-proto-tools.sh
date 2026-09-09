#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tools="$root/.tools"
protoc_version=5.28.3
protoc_release=28.3
protoc_dir="$tools/protoc-$protoc_version"
protoc_bin="$protoc_dir/bin/protoc"
protoc_sha256_x86_64=0ad949f04a6a174da83cdcbdb36dee0a4925272a5b6d83f79a6bf9852076d53f

case "$(uname -s):$(uname -m)" in
Linux:x86_64) protoc_platform=linux-x86_64; protoc_sha256=$protoc_sha256_x86_64 ;;
*) echo "unsupported pinned protoc platform: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

if [[ ! -x $protoc_bin ]]; then
  mkdir -p "$tools"
  tmp=$(mktemp -d "$tools/.protoc-download.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  archive="$tmp/protoc.zip"
  curl -fsSL --retry 3 -o "$archive" "https://github.com/protocolbuffers/protobuf/releases/download/v${protoc_release}/protoc-${protoc_release}-${protoc_platform}.zip"
  echo "$protoc_sha256  $archive" | sha256sum -c -
  mkdir "$protoc_dir"
  unzip -q "$archive" -d "$protoc_dir"
fi
"$protoc_bin" --version | grep -qx "libprotoc $protoc_release" || { echo "invalid pinned protoc: $protoc_bin" >&2; exit 1; }

mkdir -p "$tools/bin"
install_go_tool() {
  local binary=$1 module=$2 expected=$3
  if [[ -x "$tools/bin/$binary" ]] && "$tools/bin/$binary" --version | grep -qx "$expected"; then
    return
  fi
  GOBIN="$tools/bin" go install "$module"
  "$tools/bin/$binary" --version | grep -qx "$expected" || { echo "invalid $binary version" >&2; exit 1; }
}

install_go_tool protoc-gen-go google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11 'protoc-gen-go v1.36.11'
install_go_tool protoc-gen-go-grpc google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.1 'protoc-gen-go-grpc 1.6.1'
