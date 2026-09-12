#!/usr/bin/env bash
# 构建锁定任务的 Agent 镜像并导入同一目标节点的 containerd。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
task_dir=""
node=""
image=""
pi_version="0.85.1"
output=""
verifier_uv_deps=""
ubuntu_apt_mirror=""

usage() {
  echo '用法：build-terminal-image.sh --task-dir DIR --node NODE --image IMAGE [--pi-version VERSION] [--verifier-uv-deps DEPS] [--ubuntu-apt-mirror URL] [--output DIR]' >&2
}
while (($#)); do
  case "$1" in
    --task-dir) task_dir="$2"; shift 2 ;;
    --node) node="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --pi-version) pi_version="$2"; shift 2 ;;
    --verifier-uv-deps) verifier_uv_deps="$2"; shift 2 ;;
    --ubuntu-apt-mirror) ubuntu_apt_mirror="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$task_dir" && -d "$task_dir" && -n "$node" && -n "$image" ]] || { usage; exit 2; }
[[ -f "$task_dir/Dockerfile" && -f "$task_dir/task.yaml" && -f "$task_dir/run-tests.sh" ]] || { echo '任务目录缺少 Dockerfile、task.yaml 或 run-tests.sh' >&2; exit 2; }

service_count="$(awk '/^services:/{in_services=1;next} in_services && /^  [[:alnum:]_-]+:/{n++} END{print n+0}' "$task_dir/docker-compose.yaml")"
if ((service_count != 1)); then
  echo "仅支持单 client 服务任务；${task_dir} 声明 ${service_count} 个服务" >&2
  exit 3
fi

task_image="${image}-task"
build_task_dir="$task_dir"
tmp_build_dir=""
cleanup_build_context() {
  if [[ -n "$tmp_build_dir" ]]; then
    rm -rf "$tmp_build_dir"
  fi
}
trap cleanup_build_context EXIT
if [[ -n "$ubuntu_apt_mirror" ]]; then
  tmp_build_dir="$(mktemp -d)"
  cp -a "$task_dir"/. "$tmp_build_dir"/
  awk -v mirror="$ubuntu_apt_mirror" '
    { print }
    /^FROM[[:space:]]/ {
      print "RUN find /etc/apt -type f \\( -name '\''*.list'\'' -o -name '\''*.sources'\'' \\) -exec sed -i -e \"s#http://archive.ubuntu.com/ubuntu#" mirror "#g\" -e \"s#http://security.ubuntu.com/ubuntu#" mirror "#g\" {} +"
    }
  ' "$task_dir/Dockerfile" > "$tmp_build_dir/Dockerfile"
  build_task_dir="$tmp_build_dir"
fi
if [[ -z "$verifier_uv_deps" ]]; then
  verifier_uv_deps="$(python3 - "$task_dir/run-tests.sh" <<'PY'
import shlex
import sys

deps = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line.startswith("uv pip install "):
        deps.extend(shlex.split(line)[3:])
print(" ".join(deps or ["pytest==8.4.1", "requests==2.32.4"]))
PY
)"
fi
docker build --file "$build_task_dir/Dockerfile" --tag "$task_image" "$build_task_dir"
docker build --file "$script_dir/Containerfile.pi" \
  --build-arg "TASK_BASE_IMAGE=$task_image" \
  --build-arg "PI_VERSION=$pi_version" \
  --build-arg "VERIFIER_UV_DEPS=$verifier_uv_deps" \
  --tag "$image" "$script_dir"
docker save "$image" | kubectl node-shell "$node" -- sh -ceu 'ctr -n k8s.io images import -'

if [[ -n "$output" ]]; then
  mkdir -p "$output"
  jq -cn \
    --arg task "$(basename "$task_dir")" --arg task_dir "$task_dir" --arg image "$image" \
    --arg task_image "$task_image" --arg pi_version "$pi_version" --arg node "$node" \
    --arg task_image_id "$(docker image inspect "$task_image" --format '{{.Id}}')" \
    --arg image_id "$(docker image inspect "$image" --format '{{.Id}}')" \
    --arg task_sha256 "$(find "$task_dir" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')" \
    --arg uv_version "0.7.13" \
    --arg uv_installer_sha256 "1bd6dcfae3377079ed9ebeb47cc814b0a9b6f42a81089e97de49cd26f7b9d2d2" \
    --arg uv_tarball_sha256 "909278eb197c5ed0e9b5f16317d1255270d1f9ea4196e7179ce934d48c4c2545" \
    --arg verifier_dependencies "$verifier_uv_deps" \
    --arg ubuntu_apt_mirror "$ubuntu_apt_mirror" \
    --arg verifier_uv_cache_sha256 "$(docker run --rm --entrypoint /bin/bash "$image" -ceu 'find /opt/agc37/verifier-uv -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk "{print \$1}"')" \
    '{task:$task,task_dir:$task_dir,image:$image,task_image:$task_image,pi_version:$pi_version,node:$node,task_image_id:$task_image_id,image_id:$image_id,task_sha256:$task_sha256,build_workarounds:{ubuntu_apt_mirror:(if $ubuntu_apt_mirror == "" then null else $ubuntu_apt_mirror end)},verifier_bootstrap:{mode:"terminal-original-hermetic",uv_version:$uv_version,installer_sha256:$uv_installer_sha256,tarball_sha256:$uv_tarball_sha256,dependencies:$verifier_dependencies,uv_cache_sha256:$verifier_uv_cache_sha256}}' \
    > "$output/image-manifest.json"
fi
