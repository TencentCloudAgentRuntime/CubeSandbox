#!/usr/bin/env bash
set -Eeuo pipefail

kube=(kubectl --kubeconfig /etc/kubernetes/admin.conf)
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
expected_shim_sha=60ba8906a391bb899b8a393ffc7c6cb9b35c37184ab9018be2a5bc523dd343d2
expected_agent_sha=0b87e42457b676793030acf6b7b084297bde89b4f15c236c779ace199cf0a626
source_evidence=${1:-}

if test -z "$source_evidence"; then
  candidate_records=$(find /data/cubelet/s3.3-evidence -maxdepth 1 -type d -name 's3.3d-nnp-seccomp-*' -printf '%T@ %p\n')
  candidate_records=$(sort -nr <<<"$candidate_records")
  while read -r _ candidate; do
    test -n "$candidate" || continue
    test -f "$candidate/summary.txt" || continue
    grep -Fq 'S33D_DONE active_leases=0 fixed_pods_absent=true' "$candidate/summary.txt" || continue
    source_evidence=$candidate
    break
  done <<<"$candidate_records"
fi
test -n "$source_evidence"
test -d "$source_evidence"
test ! -L "$source_evidence"

audit=/data/cubelet/s3.3-evidence/s3.3d-audit-$(date -u +%Y%m%dT%H%M%SZ)
test ! -e "$audit"
mkdir -m 0700 "$audit"
trap 'printf "S33D_AUDIT_FAILED line=%s rc=%s command=%s source=%s\n" "$LINENO" "$?" "$BASH_COMMAND" "$source_evidence" >"$audit/result.txt"' ERR

test ! -e "$source_evidence/trace.log"
grep -Fxq 'S33D_NNP_SECCOMP_OK rounds=2 pods=8 cube_sandboxes=4 nnp_false=0 nnp_true=1 runtime_default=mode2,filters>=1 unshare=allowed:blocked lease_delta=4 exact_baseline=restored' "$source_evidence/summary.txt"
grep -Fq 'S33D_DONE active_leases=0 fixed_pods_absent=true' "$source_evidence/summary.txt"
grep -Fxq 'original_rc=0 cleanup_rc=0 exact_baseline=true fixed_pods_absent=true active_leases=0' "$source_evidence/cleanup-result.txt"

printf 'container_source_sha256=%s\nagent_source_sha256=%s\nshim_sha256=%s\nagent_sha256=%s\nimage=%s\nprotobuf_contract=%s\n' \
  2d07043963f05d2a8283defcbb3fbbc35ef9235db7a246aefac4e1cef8e62d0b \
  64f15fbf68b8b754447d185bda071230c8084a49c483738c8fd241361a3997c3 \
  "$expected_shim_sha" \
  "$expected_agent_sha" \
  docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 \
  process-9,linux-seccomp-8,runtime-default-subset \
  >"$audit/expected-input-fingerprint.txt"
cmp "$audit/expected-input-fingerprint.txt" "$source_evidence/input-fingerprint.txt"
test "$(sha256sum /usr/local/bin/containerd-shim-cube-rs | awk '{print $1}')" = "$expected_shim_sha"
test "$(sha256sum /data/cubelet/s13-kubernetes/assets/agent | awk '{print $1}')" = "$expected_agent_sha"

printf 'round\truntime\thost_nnp\tguest_nnp\tguest_seccomp\tunshare\n' >"$audit/expected-results.tsv"
for round in round1 round2; do
  for runtime in runc cube; do
    printf '%s\t%s\tfalse\t0\t0\tALLOWED\n' "$round" "$runtime" >>"$audit/expected-results.tsv"
    printf '%s\t%s\ttrue\t1\t2\tBLOCKED\n' "$round" "$runtime" >>"$audit/expected-results.tsv"
  done
done
cmp "$audit/expected-results.tsv" "$source_evidence/results.tsv"

for round in round1 round2; do
  for runtime in runc cube; do
    for case_name in unconfined default; do
      tag=$round-$runtime-$case_name
      jq -S '{layer:"host-pre-shim-input",noNewPrivileges:(.info.runtimeSpec.process.noNewPrivileges // false),seccomp:(.info.runtimeSpec.linux.seccomp // null)}' \
        "$source_evidence/cri-$tag.json" >"$audit/host-pre-shim-cri-$tag.json"
      jq -S '{layer:"host-pre-shim-input",noNewPrivileges:(.Spec.process.noNewPrivileges // false),seccomp:(.Spec.linux.seccomp // null)}' \
        "$source_evidence/ctr-$tag.json" >"$audit/host-pre-shim-ctr-$tag.json"
      cmp "$audit/host-pre-shim-cri-$tag.json" "$audit/host-pre-shim-ctr-$tag.json"
      cmp "$audit/host-pre-shim-cri-$tag.json" "$source_evidence/host-pre-shim-cri-$tag.json"
      cmp "$audit/host-pre-shim-ctr-$tag.json" "$source_evidence/host-pre-shim-ctr-$tag.json"
      cmp "$source_evidence/guest-$tag.txt" "$source_evidence/log-$tag.txt"
    done
    jq -e '.noNewPrivileges == false and .seccomp == null' \
      "$audit/host-pre-shim-cri-$round-$runtime-unconfined.json" >/dev/null
    jq -e '
      .noNewPrivileges == true and
      .seccomp.defaultAction == "SCMP_ACT_ERRNO" and
      (.seccomp.architectures | index("SCMP_ARCH_X86_64")) != null and
      (.seccomp.syscalls | length) > 0 and
      ((.seccomp | keys) - ["architectures", "defaultAction", "flags", "syscalls"] | length) == 0 and
      all(.seccomp.syscalls[];
        ((keys - ["action", "args", "errnoRet", "names"]) | length) == 0 and
        ((has("errnoRet") | not) or .errnoRet != 0) and
        all(.args[]?; ((keys - ["index", "op", "value", "valueTwo"]) | length) == 0)
      )
    ' "$audit/host-pre-shim-cri-$round-$runtime-default.json" >/dev/null
  done
  cmp "$audit/host-pre-shim-cri-$round-runc-unconfined.json" "$audit/host-pre-shim-cri-$round-cube-unconfined.json"
  cmp "$audit/host-pre-shim-cri-$round-runc-default.json" "$audit/host-pre-shim-cri-$round-cube-default.json"

  for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime runtime-resources; do
    cmp "$source_evidence/$kind-before.txt" "$source_evidence/$kind-$round-after.txt"
  done
done

for round in round1 round2; do
  for runtime in runc cube; do
    guest=$source_evidence/guest-$round-$runtime-unconfined.txt
    awk '
      $1 == "NoNewPrivs:" && NF == 2 && $2 == "0" { nnp++; next }
      $1 == "Seccomp:" && NF == 2 && $2 == "0" { seccomp++; next }
      $1 == "Seccomp_filters:" && NF == 2 && $2 == "0" { filters++; next }
      $0 == "UNSHARE=ALLOWED" { result++; next }
      $0 == "UNSHARE_RC=0" { rc++; next }
      { invalid++ }
      END { exit !(NR == 5 && nnp == 1 && seccomp == 1 && filters == 1 && result == 1 && rc == 1 && invalid == 0) }
    ' "$guest"

    guest=$source_evidence/guest-$round-$runtime-default.txt
    awk '
      $1 == "NoNewPrivs:" && NF == 2 && $2 == "1" { nnp++; next }
      $1 == "Seccomp:" && NF == 2 && $2 == "2" { seccomp++; next }
      $1 == "Seccomp_filters:" && NF == 2 && $2 ~ /^[1-9][0-9]*$/ { filters++; next }
      $0 == "UNSHARE=BLOCKED" { result++; next }
      $0 ~ /^UNSHARE_RC=[1-9][0-9]*$/ { rc++; next }
      $0 == "UNSHARE_STDERR=unshare: unshare(0x0): Operation not permitted" { stderr++; next }
      { invalid++ }
      END { exit !(NR == 6 && nnp == 1 && seccomp == 1 && filters == 1 && result == 1 && rc == 1 && stderr == 1 && invalid == 0) }
    ' "$guest"
  done
done

awk -F '\t' '
  NR == 1 { valid = ($1 == "round" && $2 == "pod" && $3 == "sandbox_id" && NF == 3); next }
  NR == 2 { valid = valid && $1 == "round1" && $2 == "cubesandbox-s33d-cube-unconfined" }
  NR == 3 { valid = valid && $1 == "round1" && $2 == "cubesandbox-s33d-cube-default" }
  NR == 4 { valid = valid && $1 == "round2" && $2 == "cubesandbox-s33d-cube-unconfined" }
  NR == 5 { valid = valid && $1 == "round2" && $2 == "cubesandbox-s33d-cube-default" }
  NR > 1 { valid = valid && NF == 3 && length($3) == 64 && $3 ~ /^[0-9a-f]+$/ }
  END { exit !(NR == 5 && valid) }
' "$source_evidence/cube-sandboxes.tsv"
sandbox_ids=$(awk -F '\t' 'NR > 1 {print $3}' "$source_evidence/cube-sandboxes.tsv")
unique_sandbox_ids=$(sort -u <<<"$sandbox_ids")
test "$(wc -l <<<"$unique_sandbox_ids")" -eq 4

: >"$audit/pod-uids.txt"
for round in round1 round2; do
  for runtime in runc cube; do
    for case_name in unconfined default; do
      tag=$round-$runtime-$case_name
      pod=cubesandbox-s33d-$runtime-$case_name
      pod_json=$source_evidence/pod-$tag.json
      cri_json=$source_evidence/cri-$tag.json
      test "$(jq -er '.metadata.name | strings | select(length > 0)' "$pod_json")" = "$pod"
      uid=$(jq -er '.metadata.uid | strings | select(length > 0)' "$pod_json")
      [[ $uid =~ ^[0-9a-f-]+$ ]]
      test "$(jq -er '.status.labels["io.kubernetes.pod.uid"] | strings | select(length > 0)' "$cri_json")" = "$uid"
      if test "$runtime" = cube; then
        test "$(jq -er '.spec.runtimeClassName | strings' "$pod_json")" = cube
        sandbox=$(jq -er '.info.sandboxID | strings | select(length > 0)' "$cri_json")
        tsv_sandbox=$(awk -F '\t' -v round="$round" -v pod="$pod" '$1 == round && $2 == pod {print $3}' "$source_evidence/cube-sandboxes.tsv")
        test -n "$tsv_sandbox"
        test "$sandbox" = "$tsv_sandbox"
      else
        jq -e '.spec.runtimeClassName == null' "$pod_json" >/dev/null
      fi
      if test "$case_name" = unconfined; then
        jq -e '.spec.containers | length == 1 and .[0].securityContext.allowPrivilegeEscalation == true and .[0].securityContext.seccompProfile.type == "Unconfined"' "$pod_json" >/dev/null
      else
        jq -e '.spec.containers | length == 1 and .[0].securityContext.allowPrivilegeEscalation == false and .[0].securityContext.seccompProfile.type == "RuntimeDefault"' "$pod_json" >/dev/null
      fi
      printf '%s\n' "$uid" >>"$audit/pod-uids.txt"
    done
  done
done
test "$(wc -l <"$audit/pod-uids.txt")" -eq 8
unique_pod_uids=$(sort -u "$audit/pod-uids.txt")
test "$(wc -l <<<"$unique_pod_uids")" -eq 8

awk -F '\t' '
  NR == 1 { valid = ($1 == "point" && $2 == "lease_records" && NF == 2); next }
  NR == 2 { valid = valid && $1 == "before" && $2 ~ /^[0-9]+$/ && NF == 2 }
  NR == 3 { valid = valid && $1 == "after" && $2 ~ /^[0-9]+$/ && NF == 2 }
  END { exit !(NR == 3 && valid) }
' "$source_evidence/lease-counts.tsv"
leases_before=$(awk -F '\t' 'NR == 2 {print $2}' "$source_evidence/lease-counts.tsv")
leases_after=$(awk -F '\t' 'NR == 3 {print $2}' "$source_evidence/lease-counts.tsv")
[[ $leases_before =~ ^[0-9]+$ ]]
[[ $leases_after =~ ^[0-9]+$ ]]
test "$((leases_after - leases_before))" -eq 4
lease_files=$(find "$runtime_state/leases" -type f -name '*.json' -print)
live_lease_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$lease_files")
test "$live_lease_count" -eq "$leases_after"
while IFS= read -r sandbox; do
  test -n "$sandbox"
  inactive_for_sandbox=0
  while IFS= read -r record; do
    test -n "$record" || continue
    record_sandbox=$(jq -er '.sandboxID | strings' "$record")
    test "$record_sandbox" = "$sandbox" || continue
    jq -e '.active == null' "$record" >/dev/null
    inactive_for_sandbox=$((inactive_for_sandbox + 1))
  done <<<"$lease_files"
  test "$inactive_for_sandbox" -eq 1
done <<<"$sandbox_ids"
active_leases=0
while IFS= read -r record; do
  test -n "$record" || continue
  if jq -e '.active == null' "$record" >/dev/null; then
    :
  else
    rc=$?
    test "$rc" -eq 1
    active_leases=$((active_leases + 1))
  fi
done <<<"$lease_files"
test "$active_leases" -eq 0

for kind in containers tasks sandboxes snapshots netns cube-shims vm-runtime runtime-resources; do
  cmp "$source_evidence/$kind-before.txt" "$source_evidence/$kind-cleanup.txt"
done
for pod in cubesandbox-s33d-runc-unconfined cubesandbox-s33d-cube-unconfined cubesandbox-s33d-runc-default cubesandbox-s33d-cube-default; do
  pod_name=$("${kube[@]}" get pod "$pod" --ignore-not-found -o name)
  test -z "$pod_name"
done
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
test "$("${kube[@]}" get node vm-200-2-ubuntu -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
test "$("${kube[@]}" get node vm-200-2-ubuntu -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}')" = False

trap - ERR
printf 'S33D_AUDIT_OK source=%s rounds=2 pods=8 cube_sandboxes=4 lease_delta=4 active_leases=0 exact_baseline=true\n' "$source_evidence" \
  | tee "$audit/result.txt"
