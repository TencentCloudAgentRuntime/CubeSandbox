#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }
node=${NODE:-}
while (($#)); do case "$1" in --node) node=$2; shift 2;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
: "${node:?指定 NODE 或 --node；只操作该节点}"
[[ $node =~ ^[a-z0-9][a-z0-9.-]*$ ]] || exit 2
ns=${CUBE_CRI_NAMESPACE:-default}
name=cube-cri-$(printf '%s' "$node" | sha256sum | cut -c1-12)
out=$PWD/_output/cube-cri
k() { kubectl --request-timeout=30s "$@"; }
k get node "$node" -o json | python3 -c '
import json,sys
n=json.load(sys.stdin)["status"]["nodeInfo"]
assert n["architecture"]=="amd64" and n["osImage"].startswith("TencentOS Server 4"), "需要 TS4 x86_64 节点"
assert "cubesandbox.pvm.host" in n["kernelVersion"], "请先执行 task deploy:prepare"
'
check_workloads() {
  k get pods -A --field-selector "spec.nodeName=$node" -o json | python3 -c '
import json,sys
active=[p["metadata"]["name"] for p in json.load(sys.stdin)["items"] if p["spec"].get("runtimeClassName")=="cube" and p.get("status",{}).get("phase") not in ("Succeeded","Failed")]
if active: sys.exit("请先结束节点上的 Cube Pod: "+", ".join(active))
'
}
check_workloads
image=${CUBE_CRI_IMAGE:-}
if [[ -z $image ]]; then
  : "${CUBE_CRI_IMAGE_REPOSITORY:?设置可推送且节点可拉取的安装镜像仓库，或用 CUBE_CRI_IMAGE 指定已有镜像}"
  bash deploy/cube-cri/package.sh
  context=$out/installer-image
  mkdir -p "$context"
  cp "$out/runtime.tar.gz" "$context/"
  cp deploy/cube-cri/{Dockerfile,daemonset-entrypoint.sh,daemonset-install.sh} "$context/"
  version=$(cd "$context"; sha256sum Dockerfile daemonset-entrypoint.sh daemonset-install.sh runtime.tar.gz | sha256sum | cut -c1-20)
  image=$CUBE_CRI_IMAGE_REPOSITORY:$version
  docker build -t "$image" "$context"
  docker push "$image"
  image=$(docker image inspect "$image" --format '{{json .RepoDigests}}' | python3 -c 'import json,sys; print(next(d for d in json.load(sys.stdin) if d.startswith(sys.argv[1]+"@")))' "$CUBE_CRI_IMAGE_REPOSITORY")
fi
mkdir -p "$out"
# JSON 避免镜像、命名空间等变量影响清单语法；保存实际部署清单便于审查。
python3 - "$name" "$ns" "$node" "$image" "${CUBE_CRI_IMAGE_PULL_SECRET:-}" > "$out/$name.json" <<'PY'
import json,sys
name,ns,node,image,secret=sys.argv[1:]
labels={"app.kubernetes.io/name":"cube-cri-installer","app.kubernetes.io/instance":name}
pod={
    "hostPID":True,"hostNetwork":True,"dnsPolicy":"ClusterFirstWithHostNet",
    "automountServiceAccountToken":False,
    "affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchFields":[{"key":"metadata.name","operator":"In","values":[node]}]}]}}},
    "tolerations":[{"operator":"Exists"}],
    "containers":[{"name":"installer","image":image,"imagePullPolicy":"IfNotPresent",
        "securityContext":{"privileged":True},
        "env":[{"name":"POD_UID","valueFrom":{"fieldRef":{"fieldPath":"metadata.uid"}}}],
        "volumeMounts":[{"name":"state","mountPath":"/host-state"}],
        "readinessProbe":{"exec":{"command":["/bin/sh","/installer/daemonset-entrypoint.sh","check"]},"periodSeconds":5,"timeoutSeconds":5},
        "resources":{"requests":{"cpu":"10m","memory":"32Mi"}}}],
    "volumes":[{"name":"state","hostPath":{"path":"/var/lib/cube-cri/installer","type":"DirectoryOrCreate"}}]
}
if secret: pod["imagePullSecrets"]=[{"name":secret}]
json.dump({"apiVersion":"apps/v1","kind":"DaemonSet","metadata":{"name":name,"namespace":ns,"labels":labels},"spec":{
    "selector":{"matchLabels":labels},"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":1}},
    "template":{"metadata":{"labels":labels},"spec":pod}}},sys.stdout,indent=2)
PY
check_workloads
k apply -f "$out/$name.json"
if ! k -n "$ns" rollout status "daemonset/$name" --timeout=900s; then
  k -n "$ns" describe daemonset "$name" || true
  k -n "$ns" describe pods -l "app.kubernetes.io/instance=$name" || true
  k -n "$ns" logs -l "app.kubernetes.io/instance=$name" --tail=100 || true
  exit 1
fi
k wait --for=condition=Ready "node/$node" --timeout=180s
k apply -f deploy/kubernetes/runtimeclass/runtimeclass.yaml
k label node "$node" cubesandbox.io/runtime=cube --overwrite
k -n "$ns" get daemonset "$name"
