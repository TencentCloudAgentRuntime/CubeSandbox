#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }

out=$PWD/_output/cube-cri
CUBE_CRI_IMAGE_REPOSITORY=${CUBE_CRI_IMAGE_REPOSITORY:-ccr.ccs.tencentyun.com/journeyyou/cube-cri-installer}

rpm=${PVM_HOST_RPM:-$out/pvm-host.rpm}
test -s "$rpm" || { echo "缺少 PVM 内核 RPM: $rpm；请设置 PVM_HOST_RPM 或执行 task build:pvm-host" >&2; exit 1; }

bash deploy/cube-cri/package.sh
context=$out/installer-image
mkdir -p "$context"
cp "$out/runtime.tar.gz" "$context/"
cp "$rpm" "$context/pvm-host.rpm"
cp deploy/cube-cri/{Dockerfile,daemonset-entrypoint.sh,daemonset-install.sh,daemonset-pvm.sh} "$context/"
version=$(cd "$context"; sha256sum Dockerfile daemonset-entrypoint.sh daemonset-install.sh daemonset-pvm.sh runtime.tar.gz pvm-host.rpm | sha256sum | cut -c1-20)
image=$CUBE_CRI_IMAGE_REPOSITORY:$version

docker build -t "$image" "$context"
docker push "$image"
digest_image=$(docker image inspect "$image" --format '{{json .RepoDigests}}' | python3 -c 'import json,sys; print(next(d for d in json.load(sys.stdin) if d.startswith(sys.argv[1]+"@")))' "$CUBE_CRI_IMAGE_REPOSITORY")

printf 'CUBE_CRI_IMAGE=%s\n' "$digest_image" | tee "$out/image.env"
