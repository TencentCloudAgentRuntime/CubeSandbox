#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }
action=${1:-install}; shift || true
[[ $action == prepare || $action == install ]] || { echo "unknown action: $action" >&2; exit 2; }
node=${NODE:-}
while (($#)); do
  case "$1" in --node) node=$2; shift 2;; *) echo "unknown argument: $1" >&2; exit 2;; esac
done
: "${node:?指定 NODE 或 --node；只操作该节点}"
[[ $node =~ ^[a-z0-9][a-z0-9.-]*$ ]] || exit 2
if [[ $action == install ]]; then
  exec bash deploy/cube-cri/daemonset.sh --node "$node"
fi
out=$root/_output/cube-cri
ns=${CUBE_CRI_NAMESPACE:-default}
run=$(date -u +%Y%m%d%H%M%S)-$$
pod=cube-cri-installer-$run
remote=/var/tmp/$pod
k() { kubectl --request-timeout=30s "$@"; }
host() { k -n "$ns" exec -i "$pod" -- nsenter -t 1 -m -u -i -n -p -- "$@"; }
cleanup() { k -n "$ns" delete pod "$pod" --ignore-not-found --wait=false >/dev/null || true; }
trap cleanup EXIT
# Reject active Cube workloads before replacing runtime assets.
k get pods -A --field-selector "spec.nodeName=$node" -o json | python3 -c '
import json,sys
pods=json.load(sys.stdin)["items"]
active=[p["metadata"]["name"] for p in pods if p["spec"].get("runtimeClassName")=="cube" and p.get("status",{}).get("phase") not in ("Succeeded","Failed")]
if active: sys.exit("请先结束节点上的 Cube Pod: "+", ".join(active))
'
cat <<YAML | k -n "$ns" create -f -
apiVersion: v1
kind: Pod
metadata:
  name: $pod
spec:
  nodeName: $node
  hostPID: true
  hostNetwork: true
  tolerations:
  - operator: Exists
  containers:
  - name: installer
    image: ${NODE_SHELL_IMAGE:-mirror.ccs.tencentyun.com/library/alpine:3.20}
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
YAML
k -n "$ns" wait --for=condition=Ready "pod/$pod" --timeout=180s
host mkdir -p "$remote"
case "$action" in
  prepare)
    host bash -c 'source /etc/os-release; [[ $VERSION_ID == 4* ]]; command -v grubby; command -v rpm'
    if host bash -c 'uname -r | grep -q cubesandbox.pvm.host && modprobe kvm_pvm && test -c /dev/kvm'; then host rmdir "$remote"; exit 0; fi
    : "${PVM_HOST_RPM:=$out/pvm-host.rpm}"
    test -s "$PVM_HOST_RPM"
    old_boot=$(host cat /proc/sys/kernel/random/boot_id)
    host tee "$remote/kernel.rpm" < "$PVM_HOST_RPM" >/dev/null
    host bash -s -- "$remote" <<'HOST'
set -euo pipefail
mkdir -p /var/lib/cube-cri/pvm
# Save the original selection before the RPM post-install hooks can change it.
grubby --default-kernel > /var/lib/cube-cri/pvm/previous-default-kernel
rpm -ivh --oldpackage --replacepkgs "$1/kernel.rpm"
kernel=$(rpm -qpl "$1/kernel.rpm" | grep '^/boot/vmlinuz-.*cubesandbox.pvm.host' | head -1)
test -f "$kernel"
grubby --set-default "$kernel"
printf 'kvm_pvm\n' > /etc/modules-load.d/cube-cri-pvm.conf
systemd-run --unit=cube-cri-reboot --on-active=5s systemctl reboot
HOST
    ready=0
    for ((i=0;i<120;i++)); do
      sleep 5
      if boot=$(host cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [[ $boot != "$old_boot" ]] && host bash -c 'modprobe kvm_pvm && test -c /dev/kvm'; then ready=1; break; fi
    done
    ((ready)) || { echo 'PVM 重启后未恢复，请检查节点控制台' >&2; exit 1; }
    k wait --for=condition=Ready "node/$node" --timeout=180s
    host rm -rf -- "$remote"
    ;;
  *) echo "unknown action: $action" >&2; exit 2;;
esac
