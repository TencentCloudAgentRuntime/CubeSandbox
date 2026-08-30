#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

diff -u CubeShim/protoc/protos/health.proto agent/libs/protocols/protos/health.proto
rg -q 'uint32 protocol_version = 3;' CubeShim/protoc/protos/health.proto
rg -q 'repeated AgentCapability capabilities = 4;' CubeShim/protoc/protos/health.proto
rg -q '[.]version\(' CubeShim/shim/src/sandbox/sb.rs
rg -q 'AGENT_PROTOCOL_VERSION: u32 = 1' agent/src/rpc.rs
rg -q 'SCM_RIGHTS' Cubelet/api/services/runtime/v1/runtime.proto

if rg -n 'rpc (CreateContainer|CreateTask|RunPodSandbox|PullImage|CreateSnapshot)' \
  Cubelet/api/services/runtime/v1/runtime.proto; then
  echo "runtime/v1 must remain a node-resource API" >&2
  exit 1
fi

if [[ -d Cubelet/services/runtime ]] &&
  rg -n 'containerd[.]New|plugins[.]CRIServicePlugin|RunPodSandbox|CreateTask' \
    Cubelet/services/runtime; then
  echo "Cubelet runtime resource service must not re-enter embedded containerd" >&2
  exit 1
fi

(
  cd Cubelet
  go test ./api/services/runtime/v1
)

RUST_TEST_MODE=${S0_4_RUST_TEST_MODE:-builder}

run_rust_checks() {
  cargo fmt --manifest-path CubeShim/Cargo.toml --all -- --check
  cargo test --manifest-path CubeShim/Cargo.toml \
    -p containerd-shim-cube-rs agent_capabilities -- --nocapture

  make -C agent MUSL=no SECCOMP=no src/version.rs
  cargo fmt --manifest-path agent/Cargo.toml --all -- --check
  cargo test --manifest-path agent/Cargo.toml \
    -p cube-agent version_response_advertises_versioned_unique_capabilities -- --nocapture
}

case "$RUST_TEST_MODE" in
  builder)
    BUILDER_IMAGE=${CUBE_BUILDER_IMAGE:-cube-sandbox-builder:ubuntu2004}
    docker run --rm \
      -v "$ROOT:/workspace" \
      -w /workspace \
      "$BUILDER_IMAGE" \
      bash -lc "$(declare -f run_rust_checks); run_rust_checks"
    ;;
  native)
    run_rust_checks
    ;;
  *)
    echo "unsupported S0_4_RUST_TEST_MODE: $RUST_TEST_MODE" >&2
    exit 2
    ;;
esac

echo S0_4_INTERFACE_CONTRACT_OK
