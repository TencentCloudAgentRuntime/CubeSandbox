#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}"
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }

E2E_NODE_TEST="${E2E_NODE_TEST:-e2e_node.test}"
KUBECONFIG_PATH="${KUBECONFIG:-}"
PROVIDER="${PROVIDER:-skeleton}"
FOCUS="${SIG_NODE_E2E_FOCUS:-\\[sig-node\\]}"
BASE_SKIP="${SIG_NODE_E2E_BASE_SKIP:-\\[Serial\\]|\\[Slow\\]|\\[Flaky\\]|\\[Alpha\\]|\\[Beta\\]|\\[BetaOffByDefault\\]|\\[Deprecated\\]}"
EXTRA_SKIP="${SIG_NODE_E2E_EXTRA_SKIP:-}"
OUT_DIR="${SIG_NODE_E2E_OUT_DIR:-${REPO_ROOT}/_output/sig-node-e2e/$(date +%Y%m%d-%H%M%S)}"
PROCS="${SIG_NODE_E2E_PROCS:-4}"
TIMEOUT="${SIG_NODE_E2E_TIMEOUT:-2h}"
SEMVER_FILTER="${SIG_NODE_E2E_SEMVER_FILTER:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [extra e2e_node.test args...]

Environment:
  E2E_NODE_TEST                 e2e_node.test binary path. Default: e2e_node.test
  KUBECONFIG                    kubeconfig path. Loaded from local.env when present.
  SIG_NODE_E2E_OUT_DIR          output directory. Default: _output/sig-node-e2e/<timestamp>
  SIG_NODE_E2E_PROCS            reserved for external ginkgo CLI runners; direct test binary dry-run/run is single-process.
  SIG_NODE_E2E_TIMEOUT          ginkgo timeout. Default: ${TIMEOUT}
  SIG_NODE_E2E_BASE_SKIP        baseline skip regex.
  SIG_NODE_E2E_EXTRA_SKIP       additional skip regex appended after the repo skip list.
  SIG_NODE_E2E_SEMVER_FILTER    optional --ginkgo.sem-ver-filter value, for example 1.36.2.

The repository skip list is loaded from:
  ${SCRIPT_DIR}/skip-list.json
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

skip_regex="$(python3 "${SCRIPT_DIR}/render-skip.py" --base-skip "${BASE_SKIP}" --format regex)"
if [[ -n "${EXTRA_SKIP}" ]]; then
  skip_regex="(?:${skip_regex})|(?:${EXTRA_SKIP})"
fi

mkdir -p "${OUT_DIR}"
python3 "${SCRIPT_DIR}/render-skip.py" --format markdown > "${OUT_DIR}/skip-list.md"
printf '%s\n' "${skip_regex}" > "${OUT_DIR}/ginkgo-skip.regex"

args=(
  "--provider=${PROVIDER}"
  "--ginkgo.focus=${FOCUS}"
  "--ginkgo.skip=${skip_regex}"
  "--ginkgo.timeout=${TIMEOUT}"
  "--ginkgo.json-report=${OUT_DIR}/report.json"
  "--ginkgo.junit-report=${OUT_DIR}/junit.xml"
  "--delete-namespace=true"
)

if [[ -n "${KUBECONFIG_PATH}" ]]; then
  args+=("--kubeconfig=${KUBECONFIG_PATH}")
fi
if [[ -n "${SEMVER_FILTER}" ]]; then
  args+=("--ginkgo.sem-ver-filter=${SEMVER_FILTER}")
fi

echo "SIG Node e2e output: ${OUT_DIR}" >&2
echo "Loaded $(python3 "${SCRIPT_DIR}/render-skip.py" --format count) enabled skip entries from ${SCRIPT_DIR}/skip-list.json" >&2
exec "${E2E_NODE_TEST}" "${args[@]}" "$@"
