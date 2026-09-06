#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "${SCRIPT_DIR}/.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }

TIMEOUT="${TIMEOUT:-30m}"
NAMESPACE="${NAMESPACE:-default}"
CUBE_NODE_NAME="${CUBE_NODE_NAME:-}"
HOST_NODE_NAME="${HOST_NODE_NAME:-}"
RUNC_NODE_NAME="${RUNC_NODE_NAME:-}"
PROBE_ONLY="${PROBE_ONLY:-false}"
KEEP="${KEEP:-false}"

extra_args=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --probe-only            Run only probe semantic cases.
  --keep                  Keep test Pods after the run.
  --cube-node NAME        Cube physical Node name. Auto-detected when omitted.
  --host-node NAME        Physical host Node name for host checks. Default: cube node.
  --runc-node NAME        Native runc Node name for control test. Auto-detected when omitted.
  --namespace NAME        Namespace to run in. Default: ${NAMESPACE}
  --feature REGEX         e2e-framework feature regex.
  --assess REGEX          e2e-framework assessment regex.
  --latency-concurrency N Concurrent cube pause pods for latency test.
  --latency-timeout DUR   Latency test timeout.
  --awv-csi-storage-class NAME
                           StorageClass used by awv-csi PVC tests.
  --awv-csi-driver NAME    Expected CSI driver for awv-csi PVs.
  --awv-csi-pvc-size SIZE  PVC size used by awv-csi PVC tests.
  --timeout DURATION      Go test timeout. Default: ${TIMEOUT}
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe-only) PROBE_ONLY="true"; shift ;;
    --keep) KEEP="true"; shift ;;
    --cube-node) CUBE_NODE_NAME="$2"; shift 2 ;;
    --host-node) HOST_NODE_NAME="$2"; shift 2 ;;
    --runc-node) RUNC_NODE_NAME="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --feature) extra_args+=("-feature=$2"); shift 2 ;;
    --assess) extra_args+=("-assess=$2"); shift 2 ;;
    --latency-concurrency) extra_args+=("-latency-concurrency=$2"); shift 2 ;;
    --latency-timeout) extra_args+=("-latency-timeout=$2"); shift 2 ;;
    --awv-csi-storage-class) extra_args+=("-awv-csi-storage-class=$2"); shift 2 ;;
    --awv-csi-driver) extra_args+=("-awv-csi-driver=$2"); shift 2 ;;
    --awv-csi-pvc-size) extra_args+=("-awv-csi-pvc-size=$2"); shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

args=("-namespace=${NAMESPACE}")
[[ -n "${KUBECONFIG:-}" ]] && args+=("-kubeconfig=${KUBECONFIG}")
[[ -n "${CUBE_NODE_NAME}" ]] && args+=("-cube-node=${CUBE_NODE_NAME}")
[[ -n "${HOST_NODE_NAME}" ]] && args+=("-host-node=${HOST_NODE_NAME}")
[[ -n "${RUNC_NODE_NAME}" ]] && args+=("-runc-node=${RUNC_NODE_NAME}")
args+=("-probe-only=${PROBE_ONLY}" "-keep=${KEEP}")
args+=("${extra_args[@]}")

cd "${SCRIPT_DIR}/e2e-framework"
GOWORK=off go test -count=1 -v ./... -timeout "${TIMEOUT}" --args "${args[@]}"
