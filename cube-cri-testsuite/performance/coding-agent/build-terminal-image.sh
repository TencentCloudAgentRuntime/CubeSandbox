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
debian_apt_mirror=""
debian_security_apt_mirror=""
disable_debian_security="false"
apt_check_valid_until=""
apt_preinstall=""
pip_index_url=""
pip_trusted_host=""

usage() {
  echo '用法：build-terminal-image.sh --task-dir DIR --node NODE --image IMAGE [--pi-version VERSION] [--verifier-uv-deps DEPS] [--ubuntu-apt-mirror URL] [--debian-apt-mirror URL] [--debian-security-apt-mirror URL] [--disable-debian-security true|false] [--apt-check-valid-until true|false] [--apt-preinstall PACKAGES] [--pip-index-url URL] [--pip-trusted-host HOST] [--output DIR]' >&2
}
while (($#)); do
  case "$1" in
    --task-dir) task_dir="$2"; shift 2 ;;
    --node) node="$2"; shift 2 ;;
    --image) image="$2"; shift 2 ;;
    --pi-version) pi_version="$2"; shift 2 ;;
    --verifier-uv-deps) verifier_uv_deps="$2"; shift 2 ;;
    --ubuntu-apt-mirror) ubuntu_apt_mirror="$2"; shift 2 ;;
    --debian-apt-mirror) debian_apt_mirror="$2"; shift 2 ;;
    --debian-security-apt-mirror) debian_security_apt_mirror="$2"; shift 2 ;;
    --disable-debian-security) disable_debian_security="$2"; shift 2 ;;
    --apt-check-valid-until) apt_check_valid_until="$2"; shift 2 ;;
    --apt-preinstall) apt_preinstall="$2"; shift 2 ;;
    --pip-index-url) pip_index_url="$2"; shift 2 ;;
    --pip-trusted-host) pip_trusted_host="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$task_dir" && -d "$task_dir" && -n "$node" && -n "$image" ]] || { usage; exit 2; }
[[ -f "$task_dir/Dockerfile" && -f "$task_dir/task.yaml" && -f "$task_dir/run-tests.sh" ]] || { echo '任务目录缺少 Dockerfile、task.yaml 或 run-tests.sh' >&2; exit 2; }
[[ "$disable_debian_security" =~ ^(true|false)$ ]] || { usage; exit 2; }
[[ -z "$apt_check_valid_until" || "$apt_check_valid_until" =~ ^(true|false)$ ]] || { usage; exit 2; }
[[ "$apt_preinstall$pip_index_url$pip_trusted_host" != *"'"* ]] || { echo 'build workaround 参数不能包含单引号' >&2; exit 2; }

service_count="$(awk '/^services:/{in_services=1;next} in_services && /^  [[:alnum:]_-]+:/{n++} END{print n+0}' "$task_dir/docker-compose.yaml")"
has_debug_program=false
if ((service_count == 2)) && [[ -f "$task_dir/debug_server.py" ]] && grep -q '^  program:' "$task_dir/docker-compose.yaml"; then
  has_debug_program=true
fi
if ((service_count != 1)) && [[ "$has_debug_program" != true ]]; then
  echo "仅支持单 client 服务任务或 debug-long-program 形态；${task_dir} 声明 ${service_count} 个服务" >&2
  exit 3
fi

task_image="${image}-task"
program_image="${image}-program"
build_task_dir="$task_dir"
tmp_build_dir=""
cleanup_build_context() {
  if [[ -n "$tmp_build_dir" ]]; then
    rm -rf "$tmp_build_dir"
  fi
}
trap cleanup_build_context EXIT
if [[ -n "$ubuntu_apt_mirror" || -n "$debian_apt_mirror" || -n "$debian_security_apt_mirror" || "$disable_debian_security" == true || -n "$apt_check_valid_until" || -n "$apt_preinstall" || -n "$pip_index_url" ]]; then
  tmp_build_dir="$(mktemp -d)"
  cp -a "$task_dir"/. "$tmp_build_dir"/
  awk -v ubuntu="$ubuntu_apt_mirror" -v debian="$debian_apt_mirror" -v debian_security="$debian_security_apt_mirror" -v disable_debian_security="$disable_debian_security" -v check_valid_until="$apt_check_valid_until" -v apt_preinstall="$apt_preinstall" -v pip_index_url="$pip_index_url" -v pip_trusted_host="$pip_trusted_host" '
    { print }
    /^FROM[[:space:]]/ {
      if (check_valid_until == "false") {
        print "RUN printf '\''Acquire::Check-Valid-Until \"false\";\\n'\'' > /etc/apt/apt.conf.d/99agc37-check-valid-until"
      }
      if (disable_debian_security == "true") {
        print "RUN find /etc/apt -type f \\( -name '\''*.list'\'' -o -name '\''*.sources'\'' \\) -exec sed -i '\''/debian-security/d'\'' {} +"
      }
      if (ubuntu != "" || debian != "" || debian_security != "") {
        command = "RUN find /etc/apt -type f \\( -name '\''*.list'\'' -o -name '\''*.sources'\'' \\) -exec sed -i"
        if (ubuntu != "") {
          command = command " -e \"s#http://archive.ubuntu.com/ubuntu#" ubuntu "#g\" -e \"s#http://security.ubuntu.com/ubuntu#" ubuntu "#g\""
        }
        if (debian_security != "") {
          debian_security_target = debian_security
          if (debian != "") {
            debian_security_target = "AGC37_DEBIAN_SECURITY_PLACEHOLDER"
          }
          command = command " -e \"s#http://deb.debian.org/debian-security#" debian_security_target "#g\" -e \"s#https://deb.debian.org/debian-security#" debian_security_target "#g\" -e \"s#http://security.debian.org/debian-security#" debian_security_target "#g\" -e \"s#https://security.debian.org/debian-security#" debian_security_target "#g\""
        }
        if (debian != "") {
          command = command " -e \"s#http://deb.debian.org/debian#" debian "#g\" -e \"s#https://deb.debian.org/debian#" debian "#g\""
        }
        if (debian != "" && debian_security != "") {
          command = command " -e \"s#AGC37_DEBIAN_SECURITY_PLACEHOLDER#" debian_security "#g\""
        }
        print command " {} +"
      }
      if (apt_preinstall != "") {
        print "RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades " apt_preinstall " && rm -rf /var/lib/apt/lists/*"
      }
      if (pip_index_url != "") {
        command = "RUN mkdir -p /etc && printf '\''[global]\\nindex-url = " pip_index_url "\\n"
        if (pip_trusted_host != "") {
          command = command "trusted-host = " pip_trusted_host "\\n"
        }
        print command "'\'' > /etc/pip.conf"
      }
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

import_image_to_node() {
  local source_image="$1"
  if docker save "$source_image" | kubectl node-shell "$node" -- sh -ceu 'ctr -n k8s.io images import -'; then
    return 0
  fi
  local cube_pod
  cube_pod="$(
    kubectl -n cube-cri-system get pods \
      -l app.kubernetes.io/name=cube-cri \
      --field-selector "spec.nodeName=$node" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"
  [[ -n "$cube_pod" ]] || {
    echo "node-shell 导入失败，且未找到节点 ${node} 上的 cube-cri DaemonSet Pod" >&2
    return 1
  }
  docker save "$source_image" | kubectl -n cube-cri-system exec -i "$cube_pod" -- \
    nsenter -t 1 -m -u -i -n -p -- ctr -n k8s.io images import -
}

docker build --file "$build_task_dir/Dockerfile" --tag "$task_image" "$build_task_dir"
if [[ "$has_debug_program" == true ]]; then
  program_build_dir="$(mktemp -d)"
  cp "$task_dir/debug_server.py" "$program_build_dir/debug_server.py"
  cat > "$program_build_dir/Dockerfile" <<'EOF'
FROM python:3.13-slim-bookworm
WORKDIR /app
COPY debug_server.py /app/debug_server.py
RUN pip install --no-cache-dir flask flask-cors
ENV PYTHONUNBUFFERED=1
CMD ["python", "/app/debug_server.py"]
EOF
  docker build --file "$program_build_dir/Dockerfile" --tag "$program_image" "$program_build_dir"
  rm -rf "$program_build_dir"
fi
docker build --file "$script_dir/Containerfile.pi" \
  --build-arg "TASK_BASE_IMAGE=$task_image" \
  --build-arg "PI_VERSION=$pi_version" \
  --build-arg "VERIFIER_UV_DEPS=$verifier_uv_deps" \
  --tag "$image" "$script_dir"
import_image_to_node "$image"
if [[ "$has_debug_program" == true ]]; then
  import_image_to_node "$program_image"
fi

if [[ -n "$output" ]]; then
  mkdir -p "$output"
  if [[ "$has_debug_program" == true ]]; then
    program_image_id="$(docker image inspect "$program_image" --format '{{.Id}}')"
  else
    program_image_id=""
  fi
  jq -cn \
    --arg task "$(basename "$task_dir")" --arg task_dir "$task_dir" --arg image "$image" \
    --arg task_image "$task_image" --arg pi_version "$pi_version" --arg node "$node" \
    --arg program_image "$(if [[ "$has_debug_program" == true ]]; then printf '%s' "$program_image"; fi)" \
    --arg program_image_id "$program_image_id" \
    --arg task_image_id "$(docker image inspect "$task_image" --format '{{.Id}}')" \
    --arg image_id "$(docker image inspect "$image" --format '{{.Id}}')" \
    --arg task_sha256 "$(find "$task_dir" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')" \
    --arg uv_version "0.7.13" \
    --arg uv_installer_sha256 "1bd6dcfae3377079ed9ebeb47cc814b0a9b6f42a81089e97de49cd26f7b9d2d2" \
    --arg uv_tarball_sha256 "909278eb197c5ed0e9b5f16317d1255270d1f9ea4196e7179ce934d48c4c2545" \
    --arg verifier_dependencies "$verifier_uv_deps" \
    --arg ubuntu_apt_mirror "$ubuntu_apt_mirror" \
    --arg debian_apt_mirror "$debian_apt_mirror" \
    --arg debian_security_apt_mirror "$debian_security_apt_mirror" \
    --arg disable_debian_security "$disable_debian_security" \
    --arg apt_check_valid_until "$apt_check_valid_until" \
    --arg apt_preinstall "$apt_preinstall" \
    --arg pip_index_url "$pip_index_url" \
    --arg pip_trusted_host "$pip_trusted_host" \
    --arg verifier_uv_cache_sha256 "$(docker run --rm --entrypoint /bin/bash "$image" -ceu 'find /opt/agc37/verifier-uv -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk "{print \$1}"')" \
    '{task:$task,task_dir:$task_dir,image:$image,task_image:$task_image,program_image:(if $program_image == "" then null else $program_image end),pi_version:$pi_version,node:$node,task_image_id:$task_image_id,image_id:$image_id,program_image_id:(if $program_image_id == "" then null else $program_image_id end),task_sha256:$task_sha256,build_workarounds:{ubuntu_apt_mirror:(if $ubuntu_apt_mirror == "" then null else $ubuntu_apt_mirror end),debian_apt_mirror:(if $debian_apt_mirror == "" then null else $debian_apt_mirror end),debian_security_apt_mirror:(if $debian_security_apt_mirror == "" then null else $debian_security_apt_mirror end),disable_debian_security:($disable_debian_security == "true"),apt_check_valid_until:(if $apt_check_valid_until == "" then null else $apt_check_valid_until end),apt_preinstall:(if $apt_preinstall == "" then null else $apt_preinstall end),pip_index_url:(if $pip_index_url == "" then null else $pip_index_url end),pip_trusted_host:(if $pip_trusted_host == "" then null else $pip_trusted_host end)},verifier_bootstrap:{mode:"terminal-original-hermetic",uv_version:$uv_version,installer_sha256:$uv_installer_sha256,tarball_sha256:$uv_tarball_sha256,dependencies:$verifier_dependencies,uv_cache_sha256:$verifier_uv_cache_sha256}}' \
    > "$output/image-manifest.json"
fi
