#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; printf "S33F_AUDIT_ERR line=%s rc=%s command=%s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

kubeconfig=/etc/kubernetes/admin.conf
evidence=/data/cubelet/s3.3-evidence/s33f-20260901T075735Z-1024831
build_evidence=/data/cubelet/s3.3-evidence/s3.3f-exec-build-v5-20260901T072642Z
deploy_evidence=/data/cubelet/s3.3-evidence/s3.3f-exec-deploy-20260901T074104Z
prior_s33d=/data/cubelet/s3.3-evidence/s3.3d-nnp-seccomp-20260901T040243Z
runtime_state=/data/cubelet/s13-kubernetes/runtime-resource-state
shared=/data/cubelet/s13-kubernetes/shared
reaper=/data/cubelet/s13-kubernetes/reaper
vm_runtime=/run/vc/vm
fragment=/etc/containerd/conf.d/95-cubesandbox-s33e-privileged.toml
shim=/usr/local/bin/containerd-shim-cube-rs
agent=/data/cubelet/s13-kubernetes/assets/agent
artifact=/opt/cubesandbox-s33f-runtime-artifacts-exec-v5-b73771d7/bin/containerd-shim-cube-rs
main_script=/opt/cubesandbox-s33f-inputs/s33f-combined-regression-86cc6a11.sh
node=vm-200-2-ubuntu
expected_main=86cc6a1136966cf546d8bb37ed380a2389a69d95895246e56a1c26229a4c247a
expected_patch=b73771d7676a1df4bc6e9c471cce28876d5e2aa45056dba948fdd4c50ff03185
expected_shim=3c7156524fb62bd595840fd9e4cb306682a98f56b28c96a37623be76fa2770f3
expected_agent=87bac7a6cc620595ece5fa5dfa046da8d7b0a6afe63193d7990c6f535b6e6873
expected_matrix=d7ec7f033d1d9a9a51474cebf8737acbbcc02046202a1a77065ab3eaca648e6f
expected_runtime='adapter=0 shared=0 reaper=0 cleanup=0 mounts=0 active_leases=0'
expected_live='adapter=0 shared=0 reaper=0 cleanup=0 mounts=0 active_leases=0 cube_shims=0 vm_entries=0 cube_pods=0'

count_entries() {
  local entries
  if test ! -d "$1"; then printf '0\n'; return 0; fi
  entries=$(find "$1" -mindepth 1 -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$entries"
}

count_files() {
  local entries
  entries=$(find "$1" -type f -name "$2" -printf '.\n') || return 1
  awk 'NF {n++} END {print n+0}' <<<"$entries"
}

active_leases() {
  local paths record count=0 rc
  paths=$(find "$runtime_state/leases" -type f -name '*.json' -print) || return 1
  while IFS= read -r record; do
    test -n "$record" || continue
    if jq -e '.active == null' "$record" >/dev/null; then
      :
    else
      rc=$?
      test "$rc" -eq 1 || return "$rc"
      count=$((count + 1))
    fi
  done <<<"$paths"
  printf '%s\n' "$count"
}

shared_mounts() {
  local mounts
  mounts=$(findmnt -rn -o TARGET) || return 1
  awk -v root="$shared/" 'index($1,root)==1 {n++} END {print n+0}' <<<"$mounts"
}

current_state() {
  local adapter shared_count reaper_count cleanup_count mount_count lease_count shim_count vm_count pod_count pods
  adapter=$(count_files "$runtime_state/adapter" '*') || return 1
  shared_count=$(count_entries "$shared") || return 1
  reaper_count=$(count_entries "$reaper") || return 1
  cleanup_count=$(count_files /run/containerd cube-runtime-resource.json) || return 1
  mount_count=$(shared_mounts) || return 1
  lease_count=$(active_leases) || return 1
  shim_count=$(ps -eo args= | awk '$1 ~ /(^|\/)containerd-shim-cube-rs$/ {n++} END {print n+0}') || return 1
  vm_count=$(count_entries "$vm_runtime") || return 1
  pods=$(kubectl --kubeconfig "$kubeconfig" get pods -A -o json) || return 1
  pod_count=$(jq -er '[.items[]|select(.spec.runtimeClassName=="cube")]|length' <<<"$pods") || return 1
  printf 'adapter=%s shared=%s reaper=%s cleanup=%s mounts=%s active_leases=%s cube_shims=%s vm_entries=%s cube_pods=%s\n' \
    "$adapter" "$shared_count" "$reaper_count" "$cleanup_count" "$mount_count" "$lease_count" "$shim_count" "$vm_count" "$pod_count"
}

normalize_spec() {
  local input=$1 root=$2
  jq -cS --arg root "$root" '
    def caps: {
      bounding:(.bounding//[]|sort), effective:(.effective//[]|sort),
      inheritable:(.inheritable//[]|sort), permitted:(.permitted//[]|sort), ambient:(.ambient//[]|sort)
    };
    def sec:
      if . == null then null else {
        architectures:(.architectures//[]|sort), defaultAction:.defaultAction, flags:(.flags//[]|sort),
        syscalls:(.syscalls//[] | map({names:(.names//[]|sort),action:.action,args:(.args//[]|sort_by(.index,.op,.value,.valueTwo)),errnoRet:(.errnoRet//null)}) | sort_by(.action,(.names|join(","))))
      } end;
    getpath($root|split(".")) as $s |
    {
      processUser:{uid:$s.process.user.uid,gid:$s.process.user.gid,additionalGids:($s.process.user.additionalGids//[]|sort)},
      capabilities:(($s.process.capabilities//{})|caps),
      noNewPrivileges:($s.process.noNewPrivileges//false),
      rootReadonly:($s.root.readonly//false),
      seccomp:(($s.linux.seccomp//null)|sec),
      devices:(($s.linux.devices//[])|map({path,type,major,minor,fileMode,uid,gid})|sort_by(.path)),
      deviceRules:(($s.linux.resources.devices//[])|map({allow,type,major,minor,access})|sort_by(.allow,.type,.major,.minor,.access)),
      mounts:(($s.mounts//[])|map({destination,type,options:(.options//[]|sort)})|sort_by(.destination,.type))
    }
  ' "$input"
}

field() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

proc_field() {
  awk -F: -v key="$2" '$1==key {gsub(/^[[:space:]]+/,"",$2); print $2}' "$1" | tail -n 1
}

guest_semantic() {
  local input=$1 groups filters
  groups=$(field "$input" GROUPS | tr ' ' '\n' | awk 'NF' | sort -n | paste -sd, -)
  filters=$(proc_field "$input" Seccomp_filters)
  test -n "$filters" || filters=0
  jq -cnS \
    --arg uid "$(field "$input" UID)" --arg gid "$(field "$input" GID)" --arg groups "$groups" \
    --arg capinh "$(proc_field "$input" CapInh)" --arg capprm "$(proc_field "$input" CapPrm)" \
    --arg capeff "$(proc_field "$input" CapEff)" --arg capbnd "$(proc_field "$input" CapBnd)" \
    --arg capamb "$(proc_field "$input" CapAmb)" --arg nnp "$(proc_field "$input" NoNewPrivs)" \
    --arg seccomp "$(proc_field "$input" Seccomp)" --arg filters "$filters" \
    --arg rootMode "$(field "$input" ROOT_MODE)" --arg rootWrite "$(field "$input" ROOT_WRITE)" \
    --arg volumeGid "$(field "$input" VOLUME_GID)" --arg volumeWrite "$(field "$input" VOLUME_WRITE)" \
    --arg devKvm "$(field "$input" DEV_KVM)" --arg mountResult "$(field "$input" MOUNT_RESULT)" \
    --arg cgroupMode "$(field "$input" CGROUP_MODE)" --arg deviceList "$(field "$input" DEVICE_LIST)" \
    '{uid:$uid,gid:$gid,groups:$groups,capabilities:{inheritable:$capinh,permitted:$capprm,effective:$capeff,bounding:$capbnd,ambient:$capamb},noNewPrivileges:$nnp,seccompMode:$seccomp,seccompFiltered:(($filters|tonumber)>0),rootMode:$rootMode,rootWrite:$rootWrite,volumeGid:$volumeGid,volumeWrite:$volumeWrite,devKvm:$devKvm,mountResult:$mountResult,cgroupMode:$cgroupMode,deviceList:$deviceList}'
}

exec_semantic() {
  local input=$1 groups
  groups=$(field "$input" GROUPS | tr ' ' '\n' | awk 'NF' | sort -n | paste -sd, -)
  jq -cnS --arg uid "$(field "$input" UID)" --arg gid "$(field "$input" GID)" --arg groups "$groups" \
    --arg volume "$(field "$input" VOLUME_GID)" --arg capinh "$(proc_field "$input" CapInh)" \
    --arg capprm "$(proc_field "$input" CapPrm)" --arg capeff "$(proc_field "$input" CapEff)" \
    --arg capbnd "$(proc_field "$input" CapBnd)" --arg capamb "$(proc_field "$input" CapAmb)" \
    --arg nnp "$(proc_field "$input" NoNewPrivs)" --arg seccomp "$(proc_field "$input" Seccomp)" \
    '{uid:$uid,gid:$gid,groups:$groups,volumeGid:$volume,capabilities:{inheritable:$capinh,permitted:$capprm,effective:$capeff,bounding:$capbnd,ambient:$capamb},noNewPrivileges:$nnp,seccompMode:$seccomp}'
}

pod_json() {
  printf '%s/pod-%s-%s.json\n' "$evidence" "$1" "$2"
}

assert_raw_binding() {
  local phase=$1 pod=$2 name=$3 cri ctr pod_file uid cri_norm ctr_norm
  cri="$evidence/cri-$phase-$pod-$name.json"
  ctr="$evidence/ctr-$phase-$pod-$name.json"
  pod_file=$(pod_json "$phase" "$pod")
  test -s "$cri"; test -s "$ctr"; test -s "$pod_file"
  cri_norm=$(normalize_spec "$cri" info.runtimeSpec) || return 1
  ctr_norm=$(normalize_spec "$ctr" Spec) || return 1
  test "$cri_norm" = "$ctr_norm"
  uid=$(jq -er '.metadata.uid' "$pod_file")
  test "$(jq -er '.status.labels["io.kubernetes.pod.uid"]' "$cri")" = "$uid"
  test "$(jq -er '.status.metadata.name' "$cri")" = "$name"
  test -n "$(jq -er '.info.sandboxID' "$cri")"
}

assert_ordinary() {
  local phase=$1 pod=$2 name=$3 uid=$4 gid=$5 groups=$6 caps=$7 ro=$8 nnp=$9
  shift 9
  local seccomp=$1 guest_bnd=$2 guest_prm=$3 guest_eff=$4 root_mode=$5 root_write=$6 mount_result=$7
  local cri="$evidence/cri-$phase-$pod-$name.json" guest="$evidence/guest-$phase-$pod-$name.txt"
  assert_raw_binding "$phase" "$pod" "$name"
  normalize_spec "$cri" info.runtimeSpec | jq -e --argjson uid "$uid" --argjson gid "$gid" --arg groups "$groups" \
    --argjson caps "$caps" --argjson ro "$ro" --argjson nnp "$nnp" --argjson seccomp "$seccomp" '
      .processUser.uid==$uid and .processUser.gid==$gid and
      (.processUser.additionalGids|map(tostring)|join(","))==$groups and
      .capabilities.bounding==$caps and .capabilities.permitted==$caps and .capabilities.effective==$caps and
      (.capabilities.inheritable|length)==0 and (.capabilities.ambient|length)==0 and
      .rootReadonly==$ro and .noNewPrivileges==$nnp and
      (if $seccomp then .seccomp!=null else .seccomp==null end) and
      ([.deviceRules[]|select(.allow==true and .type==null and .major==null and .minor==null and .access=="rwm")]|length)==0
    ' >/dev/null
  guest_semantic "$guest" | jq -e --arg uid "$uid" --arg gid "$gid" --arg groups "$groups" \
    --arg bnd "$guest_bnd" --arg prm "$guest_prm" --arg eff "$guest_eff" \
    --arg root "$root_mode" --arg write "$root_write" --arg mount "$mount_result" \
    --argjson nnp "$nnp" --argjson seccomp "$seccomp" '
      .uid==$uid and .gid==$gid and .groups==$groups and
      .capabilities.bounding==$bnd and .capabilities.permitted==$prm and .capabilities.effective==$eff and
      .capabilities.inheritable=="0000000000000000" and .capabilities.ambient=="0000000000000000" and
      .volumeGid=="2000" and .volumeWrite=="ok" and .devKvm=="absent" and
      .rootMode==$root and .rootWrite==$write and .mountResult==$mount and
      .noNewPrivileges==($nnp|if . then "1" else "0" end) and
      (if $seccomp then .seccompMode=="2" and .seccompFiltered else .seccompMode=="0" and (.seccompFiltered|not) end) and
      .cgroupMode=="v2" and .deviceList=="missing"
    ' >/dev/null
}

assert_mount_partition() {
  local phase=$1 pod=$2 name=$3 runtime=$4 cri
  cri="$evidence/cri-$phase-$pod-$name.json"
  normalize_spec "$cri" info.runtimeSpec | jq -e '
    ([.mounts[].destination]|length)==([.mounts[].destination]|unique|length) and
    any(.mounts[];.destination=="/evidence" and .type=="bind" and .options==["rbind","rprivate","rw"]) and
    any(.mounts[];.destination=="/probe" and .type=="bind" and .options==["rbind","ro","rprivate"]) and
    any(.mounts[];.destination=="/etc/hosts" and .type=="bind") and
    any(.mounts[];.destination=="/proc" and .type=="proc") and
    any(.mounts[];.destination=="/sys" and .type=="sysfs") and
    any(.mounts[];.destination=="/sys/fs/cgroup" and .type=="cgroup")
  ' >/dev/null
  if test "$runtime" = runc; then
    normalize_spec "$cri" info.runtimeSpec | jq -e '
      any(.mounts[];.destination=="/dev/shm" and .type=="bind" and .options==["rbind","rprivate","rw"]) and
      (if .rootReadonly then
        ([.mounts[]|select(.destination=="/etc/hostname" and .type=="bind" and .options==["rbind","ro","rprivate"])]|length)==1 and
        ([.mounts[]|select(.destination=="/etc/resolv.conf" and .type=="bind" and .options==["rbind","ro","rprivate"])]|length)==1
      else
        ([.mounts[]|select(.destination=="/etc/hostname" and .type=="bind" and .options==["rbind","rprivate","rw"])]|length)==1 and
        ([.mounts[]|select(.destination=="/etc/resolv.conf" and .type=="bind" and .options==["rbind","rprivate","rw"])]|length)==1
      end)
    ' >/dev/null
  else
    normalize_spec "$cri" info.runtimeSpec | jq -e '
      any(.mounts[];.destination=="/dev/shm" and .type=="tmpfs" and .options==["mode=1777","nodev","noexec","nosuid","size=65536k"]) and
      ([.mounts[]|select(.destination=="/etc/hostname" or .destination=="/etc/resolv.conf")]|length)==0
    ' >/dev/null
  fi
}

compare_pair() {
  local phase_a=$1 pod_a=$2 name_a=$3 runtime_a=$4 phase_b=$5 pod_b=$6 name_b=$7 runtime_b=$8
  local cri_a="$evidence/cri-$phase_a-$pod_a-$name_a.json" cri_b="$evidence/cri-$phase_b-$pod_b-$name_b.json"
  local spec_a spec_b security_a security_b mounts_a mounts_b guest_a guest_b
  assert_mount_partition "$phase_a" "$pod_a" "$name_a" "$runtime_a"
  assert_mount_partition "$phase_b" "$pod_b" "$name_b" "$runtime_b"
  spec_a=$(normalize_spec "$cri_a" info.runtimeSpec) || return 1
  spec_b=$(normalize_spec "$cri_b" info.runtimeSpec) || return 1
  security_a=$(jq -cS 'del(.mounts)' <<<"$spec_a") || return 1
  security_b=$(jq -cS 'del(.mounts)' <<<"$spec_b") || return 1
  test "$security_a" = "$security_b"
  mounts_a=$(jq -cS '{mounts:[.mounts[]|select(.destination!="/dev/shm" and .destination!="/etc/hostname" and .destination!="/etc/resolv.conf")]}' <<<"$spec_a") || return 1
  mounts_b=$(jq -cS '{mounts:[.mounts[]|select(.destination!="/dev/shm" and .destination!="/etc/hostname" and .destination!="/etc/resolv.conf")]}' <<<"$spec_b") || return 1
  test "$mounts_a" = "$mounts_b"
  guest_a=$(guest_semantic "$evidence/guest-$phase_a-$pod_a-$name_a.txt") || return 1
  guest_b=$(guest_semantic "$evidence/guest-$phase_b-$pod_b-$name_b.txt") || return 1
  test "$guest_a" = "$guest_b"
}

assert_start_error() {
  local pod=$1 needle=$2 uid sandbox count id raw pod_file cri_norm ctr_norm mapped
  pod_file="$evidence/pod-$pod.json"
  test -s "$pod_file"
  test "$(jq -er '.status.containerStatuses[0].state as $s|($s.waiting//$s.terminated).reason' "$pod_file")" = StartError
  jq -er '.status.containerStatuses[0].state as $s|($s.waiting//$s.terminated).message' "$pod_file" | grep -Fq "$needle"
  uid=$(jq -er '.metadata.uid' "$pod_file")
  test "$(jq -er --arg uid "$uid" '[.containers[]?|select(.labels["io.kubernetes.pod.uid"]==$uid)]|length' "$evidence/cri-running-$pod.json")" -eq 0
  test "$(sed -n 's/^cri_container_records=//p' "$evidence/failed-workload-$pod.txt")" -eq 1
  count=$(find "$evidence" -maxdepth 1 -type f -name "cri-failed-$pod-*.json" -printf '.\n' | awk 'NF{n++}END{print n+0}')
  test "$count" -eq 1
  raw=$(find "$evidence" -maxdepth 1 -type f -name "cri-failed-$pod-*.json" -print)
  id=$(jq -er '.status.id' "$raw")
  test "$(jq -er '.status.state' "$raw")" = CONTAINER_EXITED
  test "$(jq -er '.status.exitCode' "$raw")" -eq 128
  test "$(jq -er '.status.reason' "$raw")" = StartError
  test "$(jq -er '.status.metadata.name' "$raw")" = app
  jq -er '.status.message' "$raw" | grep -Fq "$needle"
  test "$(jq -er '.status.labels["io.kubernetes.pod.uid"]' "$raw")" = "$uid"
  sandbox=$(jq -er '.info.sandboxID' "$raw")
  test -n "$sandbox"
  mapped=$(awk -F '\t' -v pod="$pod" 'NR>1&&$2==pod{print $3}' "$evidence/cube-sandboxes.tsv") || return 1
  test -n "$mapped"
  test "$sandbox" = "$mapped"
  if grep -Fxq "$id" "$evidence/ctr-tasks-$pod.txt"; then return 1; else test "$?" -eq 1; fi
  cri_norm=$(normalize_spec "$raw" info.runtimeSpec) || return 1
  ctr_norm=$(normalize_spec "$evidence/ctr-failed-$pod-$id.json" Spec) || return 1
  test "$cri_norm" = "$ctr_norm"
  test ! -s "$evidence/logs-$pod.stdout"
}

assert_no_record() {
  local pod=$1 runtime=$2 uid actual_runtime pod_file
  pod_file="$evidence/pod-$pod.json"
  test -s "$pod_file"
  test "$(jq -er '.metadata.name' "$pod_file")" = "$pod"
  test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-owned"]' "$pod_file")" = true
  test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-run"]' "$pod_file")" = "$(basename "$evidence")"
  actual_runtime=$(jq -r '.spec.runtimeClassName // ""' "$pod_file") || return 1
  if test "$runtime" = cube; then
    test "$actual_runtime" = cube
  else
    test -z "$actual_runtime"
  fi
  test "$(jq -er '.status.containerStatuses[0].state.waiting.reason' "$pod_file")" = CreateContainerConfigError
  jq -er '.status.containerStatuses[0].state.waiting.message' "$pod_file" | grep -Fq non-root
  uid=$(jq -er '.metadata.uid' "$pod_file")
  test "$(sed -n 's/^cri_container_records=//p' "$evidence/failed-workload-$pod.txt")" -eq 0
  test "$(stat -c '%s' "$evidence/cri-container-ids-$pod.txt")" -eq 1
  test "$(sha256sum "$evidence/cri-container-ids-$pod.txt" | awk '{print $1}')" = 01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b
  test "$(jq -er --arg uid "$uid" '[.containers[]?|select(.labels["io.kubernetes.pod.uid"]==$uid)]|length' "$evidence/cri-all-$pod.json")" -eq 0
  test ! -s "$evidence/logs-$pod.stdout"
}

test -d "$evidence"; test ! -L "$evidence"
test -d "$build_evidence"; test -d "$deploy_evidence"; test -d "$prior_s33d"; test ! -L "$prior_s33d"
test -f "$main_script"; test ! -L "$main_script"
test "$(sha256sum "$main_script" | awk '{print $1}')" = "$expected_main"
test "$(wc -l <"$evidence/trace.log")" -eq 2
test "$(sha256sum "$evidence/trace.log" | awk '{print $1}')" = 5511dc81a683e359dfcdf7d7f70bbd52524feecbf28e0827d40151c0f2825639
grep -Fxq "S33F_COMBINED_OK evidence=$evidence sandboxes_observed=8 lease_delta=8 switch=false cgroup_v2_device_rule=unobservable support_matrix=$evidence/support-matrix.tsv" "$evidence/summary.txt"
grep -Fxq 'original_rc=0 cleanup_rc=0 switch_false=true pods_absent=true pod_dirs_absent=true active_leases_zero=true exact_baseline=true' "$evidence/cleanup-result.txt"

for phase in after-off after-on cleanup; do
  for category in containers tasks sandboxes snapshots netns cube-shims vm-runtime adapter shared reaper cleanup-markers shared-mounts active-leases runtime-resources; do
    cmp "$evidence/$category-before.txt" "$evidence/$category-$phase.txt"
  done
done
for phase in before after-off after-on cleanup; do
  grep -Fxq "$expected_runtime" "$evidence/runtime-resources-$phase.txt"
done

grep -Fxq $'phase\tpod\tsandbox' "$evidence/cube-sandboxes.tsv"
actual_sandbox_cases=$(awk -F '\t' 'NR>1{print $1 "|" $2}' "$evidence/cube-sandboxes.tsv") || exit 1
expected_sandbox_cases=$(printf '%s\n' \
  'off|cubesandbox-s33f-cube-off-strict' \
  'off|cubesandbox-s33f-cube-off-merge' \
  'off|cubesandbox-s33f-cube-off-privileged' \
  'on|cubesandbox-s33f-cube-on-strict' \
  'on|cubesandbox-s33f-cube-mixed' \
  'on|cubesandbox-s33f-cube-host-dev' \
  'on|cubesandbox-s33f-cube-invalid-cap' \
  'on|cubesandbox-s33f-cube-nonroot-zero') || exit 1
test "$actual_sandbox_cases" = "$expected_sandbox_cases"
test "$(awk 'NR>1{n++}END{print n+0}' "$evidence/cube-sandboxes.tsv")" -eq 8
test "$(awk -F '\t' 'NR>1{print $3}' "$evidence/cube-sandboxes.tsv" | sort -u | awk 'NF{n++}END{print n+0}')" -eq 8
test "$(awk -F '\t' 'NR>1&&$1=="off"{n++}END{print n+0}' "$evidence/cube-sandboxes.tsv")" -eq 3
test "$(awk -F '\t' 'NR>1&&$1=="on"{n++}END{print n+0}' "$evidence/cube-sandboxes.tsv")" -eq 5
before_count=$(wc -l <"$evidence/leases-before.jsonl")
after_count=$(wc -l <"$evidence/leases-after.jsonl")
test "$before_count" -eq 524
test "$after_count" -eq 532
test "$before_count" -eq "$(cat "$evidence/lease-count-before.txt")"
test "$after_count" -eq "$(cat "$evidence/lease-count-after.txt")"
test "$((after_count-before_count))" -eq 8
before_sorted=$(sort "$evidence/leases-before.jsonl") || exit 1
after_sorted=$(sort "$evidence/leases-after.jsonl") || exit 1
removed_count=$(comm -23 <(printf '%s\n' "$before_sorted") <(printf '%s\n' "$after_sorted") | awk 'NF{n++}END{print n+0}') || exit 1
added_count=$(comm -13 <(printf '%s\n' "$before_sorted") <(printf '%s\n' "$after_sorted") | awk 'NF{n++}END{print n+0}') || exit 1
test "$removed_count" -eq 0
test "$added_count" -eq 8
while IFS=$'\t' read -r phase pod sandbox; do
  test "$phase" != phase || continue
  if test -s "$evidence/pod-$phase-$pod.json"; then
    pod_file="$evidence/pod-$phase-$pod.json"
  else
    pod_file="$evidence/pod-$pod.json"
  fi
  test -s "$pod_file"
  test "$(jq -er '.metadata.name' "$pod_file")" = "$pod"
  test "$(jq -er '.spec.runtimeClassName' "$pod_file")" = cube
  test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-owned"]' "$pod_file")" = true
  test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-run"]' "$pod_file")" = "$(basename "$evidence")"
  pod_uid=$(jq -er '.metadata.uid' "$pod_file") || exit 1
  cri_sandbox_count=$(jq -er --arg uid "$pod_uid" '[.items[]?|select(.labels["io.kubernetes.pod.uid"]==$uid)]|length' "$evidence/cri-pods-$phase.json") || exit 1
  test "$cri_sandbox_count" -eq 1
  cri_sandbox=$(jq -er --arg uid "$pod_uid" '.items[]?|select(.labels["io.kubernetes.pod.uid"]==$uid)|.id' "$evidence/cri-pods-$phase.json") || exit 1
  test "$cri_sandbox" = "$sandbox"
  jq -sc --arg sandbox "$sandbox" '
    [.[]|select(.sandboxID==$sandbox)] as $records |
    ($records|length)==1 and
    $records[0].highWatermark==1 and
    ($records[0].tombstones|length)==1 and
    ($records[0].idempotencyKeys|length)==2 and
    ([$records[0].idempotencyKeys[].operation]|sort)==["PREPARE","RELEASE"] and
    ([.[]|select(.sandboxID==$sandbox and .active!=null)]|length)==0
  ' "$evidence/leases-after.jsonl" >/dev/null
  test "$(jq -sc --arg sandbox "$sandbox" '[.[]|select(.sandboxID==$sandbox)]|length' "$evidence/leases-before.jsonl")" -eq 0
done <"$evidence/cube-sandboxes.tsv"

zero=0000000000000000
while IFS='|' read -r phase pod name uid gid groups caps ro nnp seccomp bnd prm eff root write mount; do
  test "$phase" != phase || continue
  assert_ordinary "$phase" "$pod" "$name" "$uid" "$gid" "$groups" "$caps" "$ro" "$nnp" "$seccomp" "$bnd" "$prm" "$eff" "$root" "$write" "$mount"
done <<CASES
phase|pod|name|uid|gid|groups|caps|ro|nnp|seccomp|bnd|prm|eff|root|write|mount
off|cubesandbox-s33f-runc-strict|classic-init|1100|3100|2000,3100,4000|[]|true|true|true|$zero|$zero|$zero|ro|not-attempted|not-attempted
off|cubesandbox-s33f-cube-off-strict|classic-init|1100|3100|2000,3100,4000|[]|true|true|true|$zero|$zero|$zero|ro|not-attempted|not-attempted
off|cubesandbox-s33f-runc-strict|sidecar|1200|3200|2000,3200,4000|["CAP_NET_BIND_SERVICE"]|true|false|false|0000000000000400|$zero|$zero|ro|not-attempted|not-attempted
off|cubesandbox-s33f-cube-off-strict|sidecar|1200|3200|2000,3200,4000|["CAP_NET_BIND_SERVICE"]|true|false|false|0000000000000400|$zero|$zero|ro|not-attempted|not-attempted
off|cubesandbox-s33f-runc-strict|app|1000|3000|2000,3000,4000|["CAP_NET_RAW"]|false|true|true|0000000000002000|$zero|$zero|rw|not-attempted|denied
off|cubesandbox-s33f-cube-off-strict|app|1000|3000|2000,3000,4000|["CAP_NET_RAW"]|false|true|true|0000000000002000|$zero|$zero|rw|not-attempted|denied
off|cubesandbox-s33f-runc-merge|identity|1000|3000|2000,3000,4000,50000|[]|true|true|true|$zero|$zero|$zero|ro|not-attempted|not-attempted
off|cubesandbox-s33f-cube-off-merge|identity|1000|3000|2000,3000,4000,50000|[]|true|true|true|$zero|$zero|$zero|ro|not-attempted|not-attempted
off|cubesandbox-s33f-runc-merge|boundary|0|0|0,1,2,3,4,6,10,11,20,26,27,2000,4000|["CAP_CHECKPOINT_RESTORE"]|false|false|false|0000010000000000|0000010000000000|0000010000000000|rw|ok|not-attempted
off|cubesandbox-s33f-cube-off-merge|boundary|0|0|0,1,2,3,4,6,10,11,20,26,27,2000,4000|["CAP_CHECKPOINT_RESTORE"]|false|false|false|0000010000000000|0000010000000000|0000010000000000|rw|ok|not-attempted
on|cubesandbox-s33f-cube-on-strict|classic-init|1100|3100|2000,3100,4000|[]|true|true|true|$zero|$zero|$zero|ro|not-attempted|not-attempted
on|cubesandbox-s33f-cube-on-strict|sidecar|1200|3200|2000,3200,4000|["CAP_NET_BIND_SERVICE"]|true|false|false|0000000000000400|$zero|$zero|ro|not-attempted|not-attempted
on|cubesandbox-s33f-cube-on-strict|app|1000|3000|2000,3000,4000|["CAP_NET_RAW"]|false|true|true|0000000000002000|$zero|$zero|rw|not-attempted|denied
on|cubesandbox-s33f-cube-mixed|ordinary|1000|3000|2000,3000,4000|["CAP_NET_RAW"]|false|true|true|0000000000002000|$zero|$zero|rw|not-attempted|denied
CASES

success_cases=$(printf '%s\n' \
  'off|cubesandbox-s33f-runc-strict|classic-init|runc|CONTAINER_EXITED|0' \
  'off|cubesandbox-s33f-runc-strict|sidecar|runc|CONTAINER_RUNNING|-' \
  'off|cubesandbox-s33f-runc-strict|app|runc|CONTAINER_RUNNING|-' \
  'off|cubesandbox-s33f-cube-off-strict|classic-init|cube|CONTAINER_EXITED|0' \
  'off|cubesandbox-s33f-cube-off-strict|sidecar|cube|CONTAINER_RUNNING|-' \
  'off|cubesandbox-s33f-cube-off-strict|app|cube|CONTAINER_RUNNING|-' \
  'off|cubesandbox-s33f-runc-merge|identity|runc|CONTAINER_RUNNING|-' \
  'off|cubesandbox-s33f-runc-merge|boundary|runc|CONTAINER_RUNNING|-' \
  'off|cubesandbox-s33f-cube-off-merge|identity|cube|CONTAINER_RUNNING|-' \
  'off|cubesandbox-s33f-cube-off-merge|boundary|cube|CONTAINER_RUNNING|-' \
  'on|cubesandbox-s33f-cube-on-strict|classic-init|cube|CONTAINER_EXITED|0' \
  'on|cubesandbox-s33f-cube-on-strict|sidecar|cube|CONTAINER_RUNNING|-' \
  'on|cubesandbox-s33f-cube-on-strict|app|cube|CONTAINER_RUNNING|-' \
  'on|cubesandbox-s33f-cube-mixed|ordinary|cube|CONTAINER_RUNNING|-' \
  'on|cubesandbox-s33f-cube-mixed|privileged|cube|CONTAINER_RUNNING|-' \
  'on|cubesandbox-s33f-runc-invalid-cap|app|runc|CONTAINER_RUNNING|-') || exit 1

derive_raw_ids() {
  local phase pod name runtime state exit_code cri pod_file uid id actual_runtime mapped mapped_count
  while IFS='|' read -r phase pod name runtime state exit_code; do
    cri="$evidence/cri-$phase-$pod-$name.json"
    pod_file=$(pod_json "$phase" "$pod") || return 1
    test -s "$cri" || return 1
    test -s "$pod_file" || return 1
    test "$(jq -er '.metadata.name' "$pod_file")" = "$pod" || return 1
    test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-owned"]' "$pod_file")" = true || return 1
    test "$(jq -er '.metadata.labels["cubesandbox.io/s33f-run"]' "$pod_file")" = "$(basename "$evidence")" || return 1
    uid=$(jq -er '.metadata.uid' "$pod_file") || return 1
    test "$(jq -er '.status.labels["io.kubernetes.pod.uid"]' "$cri")" = "$uid" || return 1
    test "$(jq -er '.status.metadata.name' "$cri")" = "$name" || return 1
    test "$(jq -er '.status.state' "$cri")" = "$state" || return 1
    if test "$exit_code" != -; then
      test "$(jq -er '.status.exitCode' "$cri")" -eq "$exit_code" || return 1
    fi
    actual_runtime=$(jq -r '.spec.runtimeClassName // ""' "$pod_file") || return 1
    if test "$runtime" = cube; then
      test "$actual_runtime" = cube || return 1
      mapped=$(awk -F '\t' -v pod="$pod" 'NR>1&&$2==pod{print $3}' "$evidence/cube-sandboxes.tsv") || return 1
      mapped_count=$(awk 'NF{n++}END{print n+0}' <<<"$mapped") || return 1
      test "$mapped_count" -eq 1 || return 1
      test "$(jq -er '.info.sandboxID' "$cri")" = "$mapped" || return 1
    else
      test -z "$actual_runtime" || return 1
      test "$(awk -F '\t' -v pod="$pod" 'NR>1&&$2==pod{n++}END{print n+0}' "$evidence/cube-sandboxes.tsv")" -eq 0 || return 1
    fi
    id=$(jq -er '.status.id' "$cri") || return 1
    test -n "$id" || return 1
    printf '%s\n' "$id" || return 1
  done <<<"$success_cases"
}

raw_ids=$(derive_raw_ids) || exit 1
raw_ids_sorted=$(sort -u <<<"$raw_ids") || exit 1
recorded_ids_sorted=$(sort -u "$evidence/container-ids.txt") || exit 1
test "$(awk 'NF{n++}END{print n+0}' <<<"$raw_ids_sorted")" -eq 16
test "$raw_ids_sorted" = "$recorded_ids_sorted"

for name in classic-init sidecar app; do
  compare_pair off cubesandbox-s33f-runc-strict "$name" runc off cubesandbox-s33f-cube-off-strict "$name" cube
  compare_pair off cubesandbox-s33f-cube-off-strict "$name" cube on cubesandbox-s33f-cube-on-strict "$name" cube
done
for name in identity boundary; do
  compare_pair off cubesandbox-s33f-runc-merge "$name" runc off cubesandbox-s33f-cube-off-merge "$name" cube
done
compare_pair off cubesandbox-s33f-cube-off-strict app cube on cubesandbox-s33f-cube-mixed ordinary cube

for input in \
  "$evidence/exec-off-cubesandbox-s33f-runc-strict-app.txt" \
  "$evidence/exec-off-cubesandbox-s33f-cube-off-strict-app.txt" \
  "$evidence/exec-on-cubesandbox-s33f-cube-on-strict-app.txt"; do
  exec_semantic "$input" | jq -e '
    .uid=="1000" and .gid=="3000" and .groups=="2000,3000,4000" and .volumeGid=="2000" and
    .capabilities.inheritable=="0000000000000000" and .capabilities.permitted=="0000000000000000" and
    .capabilities.effective=="0000000000000000" and .capabilities.bounding=="0000000000002000" and
    .capabilities.ambient=="0000000000000000" and .noNewPrivileges=="1" and .seccompMode=="2"
  ' >/dev/null
done
exec_runc=$(exec_semantic "$evidence/exec-off-cubesandbox-s33f-runc-strict-app.txt") || exit 1
exec_cube_off=$(exec_semantic "$evidence/exec-off-cubesandbox-s33f-cube-off-strict-app.txt") || exit 1
exec_cube_on=$(exec_semantic "$evidence/exec-on-cubesandbox-s33f-cube-on-strict-app.txt") || exit 1
test "$exec_runc" = "$exec_cube_off"
test "$exec_cube_off" = "$exec_cube_on"

assert_start_error cubesandbox-s33f-cube-off-privileged 'CUBE_ALLOW_PRIVILEGED=true is required'
assert_start_error cubesandbox-s33f-cube-host-dev 'Host /dev mount source'
jq -e '
  .spec.runtimeClassName=="cube" and
  .spec.containers[0].securityContext.privileged==true and
  any(.spec.volumes[]?;.name=="host-dev" and .hostPath.path=="/dev") and
  any(.spec.containers[0].volumeMounts[]?;.name=="host-dev" and .mountPath=="/host-dev")
' "$evidence/pod-cubesandbox-s33f-cube-host-dev.json" >/dev/null
assert_start_error cubesandbox-s33f-cube-invalid-cap 'invalid OCI Linux capability: CAP_NOT_A_CAPABILITY'
assert_no_record cubesandbox-s33f-runc-nonroot-zero runc
assert_no_record cubesandbox-s33f-cube-nonroot-zero cube

assert_raw_binding on cubesandbox-s33f-runc-invalid-cap app
normalize_spec "$evidence/cri-on-cubesandbox-s33f-runc-invalid-cap-app.json" info.runtimeSpec | jq -e '
  (.capabilities.bounding|index("CAP_NOT_A_CAPABILITY"))!=null and
  (.capabilities.permitted|index("CAP_NOT_A_CAPABILITY"))!=null and
  (.capabilities.effective|index("CAP_NOT_A_CAPABILITY"))!=null
' >/dev/null
guest_semantic "$evidence/guest-on-cubesandbox-s33f-runc-invalid-cap-app.txt" | jq -e '
  .uid=="0" and .gid=="0" and .groups=="0,10" and
  .capabilities.bounding=="00000000a80425fb" and .capabilities.permitted=="00000000a80425fb" and
  .capabilities.effective=="00000000a80425fb" and .capabilities.inheritable=="0000000000000000" and
  .capabilities.ambient=="0000000000000000" and .noNewPrivileges=="0" and .seccompMode=="0"
' >/dev/null

assert_raw_binding on cubesandbox-s33f-cube-mixed privileged
priv_cri="$evidence/cri-on-cubesandbox-s33f-cube-mixed-privileged.json"
normalize_spec "$priv_cri" info.runtimeSpec | jq -e '
  .processUser.uid==0 and .processUser.gid==0 and
  (.capabilities.bounding|length)==41 and (.capabilities.permitted|length)==41 and (.capabilities.effective|length)==41 and
  (.capabilities.inheritable|length)==0 and (.capabilities.ambient|length)==0 and
  .noNewPrivileges==false and .rootReadonly==false and .seccomp==null and
  (.devices|length)==0 and ([.mounts[]|select(.destination=="/host-dev")]|length)==0 and
  ([.deviceRules[]|select(.allow==true and .type==null and .major==null and .minor==null and .access=="rwm")]|length)==1 and
  (.deviceRules|length)==1
' >/dev/null
guest_semantic "$evidence/guest-on-cubesandbox-s33f-cube-mixed-privileged.txt" | jq -e '
  .uid=="0" and .gid=="0" and
  .capabilities.bounding=="000001ffffffffff" and .capabilities.permitted=="000001ffffffffff" and
  .capabilities.effective=="000001ffffffffff" and .capabilities.inheritable=="0000000000000000" and
  .capabilities.ambient=="0000000000000000" and .noNewPrivileges=="0" and .seccompMode=="0" and
  .rootMode=="rw" and .rootWrite=="ok" and .mountResult=="allowed" and .devKvm=="absent" and
  .cgroupMode=="v2" and .deviceList=="missing"
' >/dev/null
test "$(jq -er '.info.sandboxID' "$priv_cri")" = "$(jq -er '.info.sandboxID' "$evidence/cri-on-cubesandbox-s33f-cube-mixed-ordinary.json")"
test "$(grep -Fxc 'CUBE_ALLOW_PRIVILEGED=false' "$evidence/shim-env-off.txt")" -eq 2
test "$(grep -Fxc 'CUBE_ALLOW_PRIVILEGED=true' "$evidence/shim-env-on.txt")" -eq 2
test "$(sort -u "$evidence/container-ids.txt" | awk 'NF{n++}END{print n+0}')" -eq 16

test "$(sha256sum "$evidence/support-matrix.tsv" | awk '{print $1}')" = "$expected_matrix"
test "$(awk 'NR>1{n++}END{print n+0}' "$evidence/support-matrix.tsv")" -eq 21
test "$(awk -F '\t' 'NR>1&&$2=="VERIFIED_THIS_RUN"{n++}END{print n+0}' "$evidence/support-matrix.tsv")" -eq 12
test "$(awk -F '\t' 'NR>1&&$2=="REJECTED"{n++}END{print n+0}' "$evidence/support-matrix.tsv")" -eq 3
test "$(awk -F '\t' 'NR>1&&$2=="NOT_SUPPORTED_POC"{n++}END{print n+0}' "$evidence/support-matrix.tsv")" -eq 3
test "$(awk -F '\t' 'NR>1&&$2=="SUPPORTED_BY_PRIOR_FIXED_EVIDENCE"{n++}END{print n+0}' "$evidence/support-matrix.tsv")" -eq 1
test "$(awk -F '\t' 'NR>1&&$2=="DEFERRED"{n++}END{print n+0}' "$evidence/support-matrix.tsv")" -eq 2
grep -Fxq 's33d_script_sha256=79aba88c3a46e4f7f6d0d3834f44ddf6152bc779a9a4503bdc4d8f055b04658a,e2e=inv-b849phgapi' "$evidence/prior-fixed-evidence.txt"
grep -Fxq 's33d_audit_sha256=4baeaf7699a1f721d88ad74d77d21c44072d053e712a8f8ed787a87b9dbb3bd6,audit=inv-3849tjgnmx' "$evidence/prior-fixed-evidence.txt"
grep -Fxq 'S33D_NNP_SECCOMP_OK rounds=2 pods=8 cube_sandboxes=4 nnp_false=0 nnp_true=1 runtime_default=mode2,filters>=1 unshare=allowed:blocked lease_delta=4 exact_baseline=restored' "$prior_s33d/summary.txt"
grep -Fxq "S33D_DONE active_leases=0 fixed_pods_absent=true evidence=$prior_s33d" "$prior_s33d/summary.txt"
grep -Fxq 'original_rc=0 cleanup_rc=0 exact_baseline=true fixed_pods_absent=true active_leases=0' "$prior_s33d/cleanup-result.txt"
prior_cri_count=$(find "$prior_s33d" -maxdepth 1 -type f -name 'cri-round*-*.json' -printf '.\n' | awk 'NF{n++}END{print n+0}') || exit 1
prior_guest_count=$(find "$prior_s33d" -maxdepth 1 -type f -name 'guest-round*-*.txt' -printf '.\n' | awk 'NF{n++}END{print n+0}') || exit 1
prior_pod_count=$(find "$prior_s33d" -maxdepth 1 -type f -name 'pod-round*-*.json' -printf '.\n' | awk 'NF{n++}END{print n+0}') || exit 1
test "$prior_cri_count" -eq 8
test "$prior_guest_count" -eq 8
test "$prior_pod_count" -eq 8

grep -Fxq "patch_sha=$expected_patch" "$build_evidence/summary.txt"
grep -Fxq "shim_sha=$expected_shim" "$build_evidence/summary.txt"
grep -Fq 'test result: ok. 164 passed; 0 failed;' "$build_evidence/s33f-shim-full.log"
grep -Fq 'Finished ' "$build_evidence/s33f-shim-check.log"
grep -Fq 'Finished ' "$build_evidence/s33f-shim-release.log"
for path in "$artifact" "$shim"; do
  test -f "$path"; test ! -L "$path"
  test "$(stat -c '%a' "$path")" = 755
  test "$(sha256sum "$path" | awk '{print $1}')" = "$expected_shim"
done
grep -Fxq "new_shim=$expected_shim" "$deploy_evidence/deploy-manifest.txt"
test -L "$agent"
agent_target=$(readlink -f "$agent") || exit 1
test -f "$agent_target"; test ! -L "$agent_target"
test "$(sha256sum "$agent" | awk '{print $1}')" = "$expected_agent"

test -f "$fragment"; test ! -L "$fragment"
test "$(grep -Ec 'CUBE_ALLOW_PRIVILEGED=(true|false)' "$fragment")" -eq 1
grep -Fxq "  env = ['CUBE_ALLOW_PRIVILEGED=false']" "$fragment"
grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=false']" "$evidence/containerd-config-cleanup.toml"
effective_config=$(containerd config dump) || exit 1
effective_switch_count=$(grep -Ec 'CUBE_ALLOW_PRIVILEGED=(true|false)' <<<"$effective_config") || exit 1
test "$effective_switch_count" -eq 1
grep -Fq "env = ['CUBE_ALLOW_PRIVILEGED=false']" <<<"$effective_config"
test "$(systemctl is-active containerd)" = active
test "$(systemctl is-active kubelet)" = active
test "$(systemctl is-active cubesandbox-s13-runtime-resource.service)" = active
node_json=$(kubectl --kubeconfig "$kubeconfig" get node "$node" -o json) || exit 1
ready=$(jq -er '[.status.conditions[]|select(.type=="Ready")][0].status' <<<"$node_json") || exit 1
disk_pressure=$(jq -er '[.status.conditions[]|select(.type=="DiskPressure")][0].status' <<<"$node_json") || exit 1
test "$ready" = True
test "$disk_pressure" = False
live=$(current_state) || exit 1
test "$live" = "$expected_live"

printf 'S33F_INDEPENDENT_AUDIT_OK evidence=%s raw_containers=16 cube_sandboxes=8 leases=%s->%s tombstones=8 support_matrix=21 live_shim=%s live_agent=%s current_state="%s"\n' \
  "$evidence" "$before_count" "$after_count" "$expected_shim" "$expected_agent" "$expected_live"
