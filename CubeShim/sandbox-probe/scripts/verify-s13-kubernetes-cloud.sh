#!/bin/bash
set -Eeuo pipefail

kubeconfig=/etc/kubernetes/admin.conf
kube=(kubectl --kubeconfig "$kubeconfig")
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
live=/data/cubelet/s13-kubernetes
shared=$live/shared
reaper=$live/reaper
runtime_state=$live/runtime-resource-state
containerd_state=/run/containerd
shim=/usr/local/bin/containerd-shim-cube-rs
runtime_shim=/opt/cubesandbox-s13-runtime-artifacts-bind-mount-v2/containerd-shim-cube-rs
expected_shim_sha=f873cdbe2cf63cbcf5c809ffc9035ba4066d6a92dc658599c50fd513586c253d
evidence=/data/cubelet/s1.3-kubernetes-evidence/$(date -u +%Y%m%dT%H%M%SZ)
pod=cubesandbox-s13-kubelet
node=vm-200-2-ubuntu
pod_created=0
sandbox_id=
container_id=

count_entries() {
  if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi
}

count_files() {
  if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi
}

save_diagnostics() {
  "${kube[@]}" get pod "$pod" -o yaml >"$evidence/pod.yaml" 2>&1 || true
  "${kube[@]}" describe pod "$pod" >"$evidence/pod.describe" 2>&1 || true
  "${cri[@]}" pods >"$evidence/cri-pods.txt" 2>&1 || true
  "${cri[@]}" ps -a >"$evidence/cri-containers.txt" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
}

cleanup() {
  rc=$?
  set +e
  save_diagnostics
  if test "$pod_created" -eq 1; then
    "${kube[@]}" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null 2>&1
    "${kube[@]}" wait --for=delete pod/"$pod" --timeout=60s >/dev/null 2>&1
  fi
  exit "$rc"
}

install -d -m 0700 "$evidence"
start_epoch="$(date +%s)"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

systemctl is-active --quiet containerd
systemctl is-active --quiet cubesandbox-s13-runtime-resource.service
test "$(PATH=/usr/local/bin:/usr/bin:/bin command -v containerd-shim-cube-rs)" = "$shim"
test "$(sha256sum "$shim" | awk '{print $1}')" = "$expected_shim_sha"
test "$(sha256sum "$runtime_shim" | awk '{print $1}')" = "$expected_shim_sha"
containerd config dump >"$evidence/containerd-config.toml"
grep -Fq "runtime_path = '$runtime_shim'" "$evidence/containerd-config.toml"
grep -Fq "sandboxer = 'shim'" "$evidence/containerd-config.toml"
"${kube[@]}" get --raw=/readyz | grep -Fxq ok
"${kube[@]}" get node "$node" -o json \
  | jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' >/dev/null

"${kube[@]}" apply -f - >"$evidence/runtimeclass.apply" <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: cube
  annotations:
    cubesandbox.io/poc-resource: "勿删"
handler: cube
EOF
"${kube[@]}" get runtimeclass cube -o json \
  | jq -e '.handler == "cube" and .metadata.annotations["cubesandbox.io/poc-resource"] == "勿删"' >/dev/null

ctr --address /run/containerd/containerd.sock --namespace k8s.io containers list -q | sort >"$evidence/containers-before.txt"
ctr --address /run/containerd/containerd.sock --namespace k8s.io tasks list -q | sort >"$evidence/tasks-before.txt"
ctr --address /run/containerd/containerd.sock --namespace k8s.io sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-before.txt"
ctr --address /run/containerd/containerd.sock --namespace k8s.io snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-before.txt"
find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n' 2>/dev/null | sort >"$evidence/netns-before.txt"
printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s\n' \
  "$(count_files "$runtime_state/adapter")" "$(count_entries "$shared")" "$(count_entries "$reaper")" \
  "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" \
  "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" >"$evidence/lower-before.txt"

"${kube[@]}" apply -f - >"$evidence/pod.apply" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: default
  labels:
    app: cubesandbox-s13-kubelet
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 3
  tolerations:
  - operator: Exists
  containers:
  - name: main
    image: docker.io/library/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - "trap '' TERM; echo cube-k8s-started; while :; do sleep 1; done"
EOF
pod_created=1

if ! "${kube[@]}" wait --for=condition=Ready pod/"$pod" --timeout=180s >"$evidence/pod.wait" 2>&1; then
  save_diagnostics
  exit 1
fi
pod_ip="$("${kube[@]}" get pod "$pod" -o jsonpath='{.status.podIP}')"
test -n "$pod_ip"
runtime_handler="$("${kube[@]}" get pod "$pod" -o jsonpath='{.spec.runtimeClassName}')"
test "$runtime_handler" = cube

for _ in $(seq 1 100); do
  sandbox_id="$("${cri[@]}" pods --name "$pod" -q 2>/dev/null | head -n 1)"
  test -n "$sandbox_id" && break
  sleep 0.1
done
test -n "$sandbox_id"
container_id="$("${cri[@]}" ps --pod "$sandbox_id" -q 2>/dev/null | head -n 1)"
test -n "$container_id"
printf '%s\n' "$sandbox_id" >"$evidence/sandbox-id"
printf '%s\n' "$container_id" >"$evidence/container-id"

"${kube[@]}" logs "$pod" >"$evidence/kubectl-logs.txt"
grep -Fq cube-k8s-started "$evidence/kubectl-logs.txt"

"${kube[@]}" exec "$pod" -- sh -c "printf 'cube-k8s-exec-out'; printf 'cube-k8s-exec-err' >&2" \
  >"$evidence/kubectl-exec.stdout" 2>"$evidence/kubectl-exec.stderr"
grep -Fq cube-k8s-exec-out "$evidence/kubectl-exec.stdout"
grep -Fq cube-k8s-exec-err "$evidence/kubectl-exec.stderr"

if "${kube[@]}" exec "$pod" -- sh -c "printf 'cube-k8s-exec-fail' >&2; exit 19" \
  >"$evidence/kubectl-exec-nonzero.stdout" 2>"$evidence/kubectl-exec-nonzero.stderr"; then
  exec_rc=0
else
  exec_rc=$?
fi
printf '%s\n' "$exec_rc" >"$evidence/kubectl-exec-nonzero.rc"
test "$exec_rc" -eq 19
grep -Fq cube-k8s-exec-fail "$evidence/kubectl-exec-nonzero.stderr"
grep -Fq 'exit code 19' "$evidence/kubectl-exec-nonzero.stderr"

delete_start_ms="$(date +%s%3N)"
"${kube[@]}" delete pod "$pod" --grace-period=3 --wait=true >"$evidence/pod.delete"
delete_end_ms="$(date +%s%3N)"
delete_ms=$((delete_end_ms - delete_start_ms))
printf '%s\n' "$delete_ms" >"$evidence/pod-delete-ms"
test "$delete_ms" -ge 2500
test "$delete_ms" -le 12000
pod_created=0

for _ in $(seq 1 600); do
  ctr --address /run/containerd/containerd.sock --namespace k8s.io containers list -q | sort >"$evidence/containers-after.txt"
  ctr --address /run/containerd/containerd.sock --namespace k8s.io tasks list -q | sort >"$evidence/tasks-after.txt"
  ctr --address /run/containerd/containerd.sock --namespace k8s.io sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-after.txt"
  ctr --address /run/containerd/containerd.sock --namespace k8s.io snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-after.txt"
  find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n' 2>/dev/null | sort >"$evidence/netns-after.txt"
  if cmp -s "$evidence/containers-before.txt" "$evidence/containers-after.txt" \
    && cmp -s "$evidence/tasks-before.txt" "$evidence/tasks-after.txt" \
    && cmp -s "$evidence/sandboxes-before.txt" "$evidence/sandboxes-after.txt" \
    && cmp -s "$evidence/snapshots-before.txt" "$evidence/snapshots-after.txt" \
    && cmp -s "$evidence/netns-before.txt" "$evidence/netns-after.txt" \
    && test "$(count_files "$runtime_state/adapter")" -eq 0 \
    && test "$(count_entries "$shared")" -eq 0 \
    && test "$(count_entries "$reaper")" -eq 0 \
    && test "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0 \
    && test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0; then
    break
  fi
  sleep 0.1
done
cmp "$evidence/containers-before.txt" "$evidence/containers-after.txt"
cmp "$evidence/tasks-before.txt" "$evidence/tasks-after.txt"
cmp "$evidence/sandboxes-before.txt" "$evidence/sandboxes-after.txt"
cmp "$evidence/snapshots-before.txt" "$evidence/snapshots-after.txt"
cmp "$evidence/netns-before.txt" "$evidence/netns-after.txt"
test "$(count_files "$runtime_state/adapter")" -eq 0
test "$(count_entries "$shared")" -eq 0
test "$(count_entries "$reaper")" -eq 0
test "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0
test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0
test -z "$(ps -eo args= | awk -v id="$sandbox_id" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {for (i=2; i<=NF; i++) if ($i == "-id" && $(i+1) == id) print $0}')"
test -z "$(ps -eo args= | awk -v id="$sandbox_id" '$1 ~ /(^|\/)containerd-shim-cube-rs$/ && $0 ~ /cube-runtime-reaper/ && index($0, id) {print $0}')"
while IFS= read -r record; do jq -e '.active == null' "$record" >/dev/null; done \
  < <(find "$runtime_state/leases" -type f -name '*.json' -print)

save_diagnostics
grep -F "$container_id" "$evidence/containerd.journal" \
  >"$evidence/container-exit-events.txt"
grep -Fq 'exit_status:137' "$evidence/container-exit-events.txt"
printf 'S13_KUBERNETES_LOGS_OK pod_ip=%s runtime_class=cube\n' "$pod_ip"
printf 'S13_KUBERNETES_EXEC_OK process_exit=19 client_rc=19 stdout=ok stderr=ok tty=false stdin=false\n'
printf 'S13_KUBERNETES_GRACE_OK elapsed_ms=%s exit=137 timeout=3\n' "$delete_ms"
printf 'S13_KUBERNETES_RESIDUE_CLEAN containers=baseline tasks=baseline sandboxes=baseline snapshots=baseline netns=baseline adapter=0 shared=0 reaper=0 cleanup_records=0 shared_mounts=0 shim_processes=0 reaper_processes=0 active_leases=0\n'
printf 'S13_KUBERNETES_ACCEPTANCE_OK node=%s evidence=%s sandbox=%s container=%s\n' "$node" "$evidence" "$sandbox_id" "$container_id"

trap - ERR EXIT
