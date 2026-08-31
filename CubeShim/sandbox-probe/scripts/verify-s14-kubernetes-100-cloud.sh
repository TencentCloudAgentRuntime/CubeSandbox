#!/bin/bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock --timeout 180s)
ctr=(ctr --address /run/containerd/containerd.sock --namespace k8s.io)
node=vm-200-2-ubuntu
expected_shim_sha=39b68b08c17d27798b8ef1bf414db9eb5804aa09d21d2ebfb5a39b5042b9d9dd
selector='cubesandbox.io/s14-loop=true'
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
containerd_state=/run/containerd
vm_runtime=/run/vc/vm
evidence=/data/cubelet/s1.4-evidence/loop100-$(date -u +%Y%m%dT%H%M%SZ)
start_epoch="$(date +%s)"
total=100
batch_size=10

count_entries() {
  if test -d "$1"; then find "$1" -mindepth 1 | wc -l; else echo 0; fi
}

count_files() {
  if test -d "$1"; then find "$1" -type f | wc -l; else echo 0; fi
}

active_leases() {
  local count=0 record
  while IFS= read -r record; do
    if ! jq -e '.active == null' "$record" >/dev/null; then count=$((count + 1)); fi
  done < <(find "$runtime_state/leases" -type f -name '*.json' -print 2>/dev/null)
  echo "$count"
}

lease_records() {
  find "$runtime_state/leases" -type f -name '*.json' 2>/dev/null | wc -l
}

capture_state() {
  local tag=$1
  "${ctr[@]}" containers list -q | sort >"$evidence/containers-$tag.txt"
  "${ctr[@]}" tasks list -q | sort >"$evidence/tasks-$tag.txt"
  "${ctr[@]}" sandboxes list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/sandboxes-$tag.txt"
  "${ctr[@]}" snapshots --snapshotter overlayfs list | awk 'NR > 1 && NF {print $1}' | sort >"$evidence/snapshots-$tag.txt"
  find /var/run/netns -mindepth 1 -maxdepth 1 -name 'cni-*' -printf '%f\n' 2>/dev/null \
    | sort >"$evidence/netns-$tag.txt"
  ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {print}' | sort \
    >"$evidence/cube-shims-$tag.txt"
  ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ && /cube-runtime-reaper/ {print}' | sort \
    >"$evidence/cube-reapers-$tag.txt"
  { if test -d "$vm_runtime"; then find "$vm_runtime" -mindepth 1 -printf '%P %y\n' 2>/dev/null || true; fi; } \
    | sort >"$evidence/vm-runtime-$tag.txt"
}

state_matches_baseline() {
  local tag=$1
  cmp -s "$evidence/containers-before.txt" "$evidence/containers-$tag.txt" \
    && cmp -s "$evidence/tasks-before.txt" "$evidence/tasks-$tag.txt" \
    && cmp -s "$evidence/sandboxes-before.txt" "$evidence/sandboxes-$tag.txt" \
    && cmp -s "$evidence/snapshots-before.txt" "$evidence/snapshots-$tag.txt" \
    && cmp -s "$evidence/netns-before.txt" "$evidence/netns-$tag.txt" \
    && cmp -s "$evidence/cube-shims-before.txt" "$evidence/cube-shims-$tag.txt" \
    && cmp -s "$evidence/cube-reapers-before.txt" "$evidence/cube-reapers-$tag.txt" \
    && cmp -s "$evidence/vm-runtime-before.txt" "$evidence/vm-runtime-$tag.txt" \
    && test "$(count_files "$runtime_state/adapter")" -eq 0 \
    && test "$(count_entries "$shared")" -eq 0 \
    && test "$(count_entries "$reaper")" -eq 0 \
    && test "$(find "$containerd_state" -name cube-runtime-resource.json -type f | wc -l)" -eq 0 \
    && test "$(findmnt -rn -o TARGET | grep -Fc "$shared/" || true)" -eq 0 \
    && test "$(active_leases)" -eq 0
}

assert_baseline() {
  local name=$1 attempt tag="after-$1"
  for attempt in $(seq 1 1200); do
    capture_state "$tag"
    if state_matches_baseline "$tag"; then
      printf 'S14_LOOP_BATCH_CLEAN batch=%s wait_attempt=%s lease_records=%s\n' \
        "$name" "$attempt" "$(lease_records)" | tee -a "$evidence/summary.txt"
      return 0
    fi
    sleep 0.1
  done
  capture_state "$tag"
  for kind in containers tasks sandboxes snapshots netns cube-shims cube-reapers vm-runtime; do
    diff -u "$evidence/$kind-before.txt" "$evidence/$kind-$tag.txt" \
      >"$evidence/$kind-$name.diff" 2>&1 || true
  done
  return 1
}

delete_loop_pods() {
  "${kube[@]}" delete pod -l "$selector" --ignore-not-found --grace-period=0 --force --wait=false \
    >/dev/null 2>&1 || true
  for _ in $(seq 1 1200); do
    test -z "$("${kube[@]}" get pod -l "$selector" -o name 2>/dev/null)" && return 0
    sleep 0.1
  done
  return 1
}

save_diagnostics() {
  "${kube[@]}" get pod -l "$selector" -o wide >"$evidence/loop-pods.txt" 2>&1 || true
  "${cri[@]}" pods >"$evidence/cri-pods.txt" 2>&1 || true
  "${cri[@]}" ps -a >"$evidence/cri-containers.txt" 2>&1 || true
  journalctl -u containerd --since "@$start_epoch" --no-pager >"$evidence/containerd.journal" 2>&1 || true
  journalctl -u kubelet --since "@$start_epoch" --no-pager >"$evidence/kubelet.journal" 2>&1 || true
}

cleanup() {
  rc=$?
  set +e
  save_diagnostics
  delete_loop_pods
  exit "$rc"
}

install -d -m 0700 "$evidence"
trap 'printf "ERR line=%s rc=%s command=%s\n" "$LINENO" "$?" "$BASH_COMMAND" >>"$evidence/trace.log"' ERR
trap cleanup EXIT

systemctl is-active --quiet containerd
systemctl is-active --quiet cubesandbox-s13-runtime-resource.service
test "$(sha256sum /usr/local/bin/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
test "$(sha256sum /opt/cubesandbox-s14-runtime-artifacts-sandbox-spec-v1/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
"${kube[@]}" get --raw=/readyz | grep -Fxq ok
"${kube[@]}" get node "$node" -o json \
  | jq -e '.status.conditions[] | select(.type == "Ready" and .status == "True")' >/dev/null
delete_loop_pods
capture_state before
test "$(active_leases)" -eq 0
leases_before="$(lease_records)"

for batch in $(seq 1 $((total / batch_size))); do
  first=$(( (batch - 1) * batch_size + 1 ))
  last=$(( batch * batch_size ))
  batch_label="$(printf '%02d' "$batch")"
  for index in $(seq "$first" "$last"); do
    suffix="$(printf '%03d' "$index")"
    name="cubesandbox-s14-loop-$suffix"
    "${kube[@]}" apply -f - >>"$evidence/batch-$batch_label.apply" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    cubesandbox.io/s14-loop: "true"
    cubesandbox.io/s14-loop-batch: "$batch_label"
spec:
  runtimeClassName: cube
  nodeName: $node
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
  - name: main
    image: docker.io/library/busybox:1.36.1
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "echo s14-loop-$suffix"]
EOF
  done

  for _ in $(seq 1 6000); do
    "${kube[@]}" get pod -l "cubesandbox.io/s14-loop-batch=$batch_label" -o json \
      >"$evidence/batch-$batch_label.pods.json"
    pod_count="$(jq '.items | length' "$evidence/batch-$batch_label.pods.json")"
    succeeded="$(jq '[.items[] | select(.status.phase == "Succeeded")] | length' "$evidence/batch-$batch_label.pods.json")"
    failed="$(jq '[.items[] | select(.status.phase == "Failed")] | length' "$evidence/batch-$batch_label.pods.json")"
    test "$failed" -eq 0
    if test "$pod_count" -eq "$batch_size" && test "$succeeded" -eq "$batch_size"; then break; fi
    sleep 0.1
  done
  test "$pod_count" -eq "$batch_size"
  test "$succeeded" -eq "$batch_size"
  test "$failed" -eq 0

  for index in $(seq "$first" "$last"); do
    suffix="$(printf '%03d' "$index")"
    name="cubesandbox-s14-loop-$suffix"
    "${kube[@]}" logs "$name" >"$evidence/$name.log"
    grep -Fxq "s14-loop-$suffix" "$evidence/$name.log"
    sid="$("${cri[@]}" pods --name "$name" -q | head -n1)"
    test -n "$sid"
    printf '%s\n' "$sid" >>"$evidence/sandbox-ids.txt"
  done
  "${kube[@]}" delete pod -l "cubesandbox.io/s14-loop-batch=$batch_label" --wait=true \
    >"$evidence/batch-$batch_label.delete"
  assert_baseline "$batch_label"
done

test "$(wc -l <"$evidence/sandbox-ids.txt")" -eq "$total"
test "$(sort -u "$evidence/sandbox-ids.txt" | wc -l)" -eq "$total"
leases_after="$(lease_records)"
lease_delta=$((leases_after - leases_before))
test "$lease_delta" -eq "$total"
test "$(active_leases)" -eq 0
capture_state final
state_matches_baseline final
save_diagnostics
printf 'S14_100_LOOP_OK total=%s batch_size=%s unique_sandboxes=%s active_leases=0 durable_tombstone_delta=%s vm_runtime=baseline shim_sha256=%s evidence=%s\n' \
  "$total" "$batch_size" "$total" "$lease_delta" "$expected_shim_sha" "$evidence" | tee -a "$evidence/summary.txt"
trap - ERR EXIT
