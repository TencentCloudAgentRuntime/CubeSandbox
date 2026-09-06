#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }
node=${NODE:-}
while (($#)); do case "$1" in --node) node=$2; shift 2;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
: "${node:?指定 NODE 或 --node}"
[[ $node =~ ^[a-z0-9][a-z0-9.-]*$ ]] || exit 2
ns=cube-cri-smoke-$(date -u +%Y%m%d%H%M%S)-$$
evidence=$PWD/_output/cube-cri/tests/$ns
mkdir -p "$evidence"
k() { kubectl --request-timeout=30s "$@"; }
cleanup() {
  local rc=$?
  k -n "$ns" get pods -o yaml > "$evidence/pods.yaml" 2>&1 || true
  k -n "$ns" get events -o wide > "$evidence/events.txt" 2>&1 || true
  k -n "$ns" describe pod smoke > "$evidence/describe.txt" 2>&1 || true
  k -n "$ns" delete pod smoke --ignore-not-found --wait=true --timeout=180s || rc=1
  k delete namespace "$ns" --wait=true --timeout=180s || rc=1
  exit "$rc"
}
trap cleanup EXIT
k create namespace "$ns"
k get runtimeclass cube -o json > "$evidence/runtimeclass.json"
cat <<YAML | k -n "$ns" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: smoke
spec:
  runtimeClassName: cube
  nodeSelector:
    kubernetes.io/hostname: $node
  restartPolicy: Never
  volumes:
  - name: shared
    emptyDir: {}
  initContainers:
  - name: init
    image: ${SMOKE_IMAGE:-mirror.ccs.tencentyun.com/library/busybox:1.36.1}
    command: ["sh", "-c", "echo cube-cri-ready > /shared/index.html"]
    volumeMounts:
    - name: shared
      mountPath: /shared
    resources:
      requests: {cpu: 100m, memory: 64Mi}
      limits: {cpu: 500m, memory: 128Mi}
  containers:
  - name: server
    image: ${SMOKE_IMAGE:-mirror.ccs.tencentyun.com/library/busybox:1.36.1}
    command: ["sh", "-c", "cat /shared/index.html; exec httpd -f -p 8080 -h /shared"]
    volumeMounts:
    - name: shared
      mountPath: /shared
    readinessProbe:
      httpGet: {path: /, port: 8080}
      periodSeconds: 2
    resources:
      requests: {cpu: 100m, memory: 64Mi}
      limits: {cpu: 500m, memory: 128Mi}
  - name: client
    image: ${SMOKE_IMAGE:-mirror.ccs.tencentyun.com/library/busybox:1.36.1}
    command: ["sleep", "3600"]
    resources:
      requests: {cpu: 100m, memory: 64Mi}
      limits: {cpu: 500m, memory: 128Mi}
YAML
k -n "$ns" wait --for=condition=Ready pod/smoke --timeout=300s
k -n "$ns" logs smoke -c server | tee "$evidence/server.log" | grep -Fx cube-cri-ready
k -n "$ns" exec smoke -c client -- wget -qO- http://127.0.0.1:8080 | tee "$evidence/exec.log" | grep -Fx cube-cri-ready
k -n "$ns" get pod smoke -o json | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p["spec"]["nodeName"]==sys.argv[1]
expected=json.load(open(sys.argv[2]))["overhead"]["podFixed"]
assert p["spec"]["overhead"]==expected
assert p["status"]["podIP"]
assert p["status"]["initContainerStatuses"][0]["state"]["terminated"]["exitCode"]==0
print("PASS: node="+sys.argv[1]+" podIP="+p["status"]["podIP"]+" init/volume/readiness/logs/exec/shared-network/overhead")
' "$node" "$evidence/runtimeclass.json" | tee "$evidence/result.txt"
echo "evidence: $evidence"
