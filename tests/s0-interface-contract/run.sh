#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

run_contract_checks() {
  diff -u CubeShim/protoc/protos/health.proto agent/libs/protocols/protos/health.proto
  grep -Eq 'uint32 protocol_version = 3;' CubeShim/protoc/protos/health.proto
  grep -Eq 'repeated AgentCapability capabilities = 4;' CubeShim/protoc/protos/health.proto
  grep -Eq '[.]version\(' CubeShim/shim/src/sandbox/sb.rs
  grep -Eq 'AGENT_PROTOCOL_VERSION: u32 = 1' agent/src/rpc.rs
  grep -Eq 'SCM_RIGHTS' Cubelet/api/services/runtime/v1/runtime.proto

  if grep -En 'rpc (CreateContainer|CreateTask|RunPodSandbox|PullImage|CreateSnapshot)' \
    Cubelet/api/services/runtime/v1/runtime.proto; then
    echo "runtime/v1 must remain a node-resource API" >&2
    exit 1
  fi

  if [[ -d Cubelet/services/runtime ]] &&
    grep -RnE 'containerd[.]New|plugins[.]CRIServicePlugin|RunPodSandbox|CreateTask' \
      Cubelet/services/runtime; then
    echo "Cubelet runtime resource service must not re-enter embedded containerd" >&2
    exit 1
  fi

  (
    cd Cubelet
    go test ./api/services/runtime/v1
  )

  cargo fmt --manifest-path CubeShim/Cargo.toml --all -- --check
  cargo test --manifest-path CubeShim/Cargo.toml \
    -p containerd-shim-cube-rs agent_capabilities -- --nocapture

  make -C agent MUSL=no SECCOMP=no src/version.rs
  cargo fmt --manifest-path agent/Cargo.toml --all -- --check
  cargo test --manifest-path agent/Cargo.toml \
    -p cube-agent version_response_advertises_versioned_unique_capabilities -- --nocapture
}

RUST_TEST_MODE=${S0_4_RUST_TEST_MODE:-builder}

case "$RUST_TEST_MODE" in
  builder)
    BUILDER_RUNNER=${CUBE_BUILDER_RUNNER:-auto}
    DOCKER_IMAGE=${CUBE_BUILDER_IMAGE:-cube-sandbox-builder:ubuntu2004}
    CTR_IMAGE=${CUBE_BUILDER_IMAGE:-ghcr.io/tencentcloud/cubesandbox-builder:ubuntu2004}
    CTR_NAMESPACE=${CUBE_BUILDER_NAMESPACE:-moby}

    if [[ "$BUILDER_RUNNER" == auto ]]; then
      if command -v docker >/dev/null 2>&1 &&
        docker info >/dev/null 2>&1 &&
        docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
        BUILDER_RUNNER=docker
      elif command -v ctr >/dev/null 2>&1 &&
        ctr -n "$CTR_NAMESPACE" images list -q | grep -Fxq "$CTR_IMAGE"; then
        BUILDER_RUNNER=ctr
      elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        BUILDER_RUNNER=docker
      elif command -v ctr >/dev/null 2>&1; then
        BUILDER_RUNNER=ctr
      else
        echo "neither docker nor ctr is available for builder checks" >&2
        exit 1
      fi
    fi

    case "$BUILDER_RUNNER" in
      docker)
        docker run --rm \
          -v "$ROOT:/workspace" \
          -w /workspace \
          "$DOCKER_IMAGE" \
          bash -lc "$(declare -f run_contract_checks); run_contract_checks"
        ;;
      ctr)
        ctr -n "$CTR_NAMESPACE" run --rm \
          --mount "type=bind,src=$ROOT,dst=/workspace,options=rbind:rw" \
          "$CTR_IMAGE" "cubesandbox-s04-contract-$$" \
          bash -lc "cd /workspace; $(declare -f run_contract_checks); run_contract_checks"
        ;;
      *)
        echo "unsupported CUBE_BUILDER_RUNNER: $BUILDER_RUNNER" >&2
        exit 2
        ;;
    esac
    ;;
  native)
    run_contract_checks
    ;;
  *)
    echo "unsupported S0_4_RUST_TEST_MODE: $RUST_TEST_MODE" >&2
    exit 2
    ;;
esac

echo S0_4_INTERFACE_CONTRACT_OK
