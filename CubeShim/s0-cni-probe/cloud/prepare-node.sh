#!/usr/bin/env bash
set -euo pipefail

KUBERNETES_MINOR=${KUBERNETES_MINOR:-v1.36}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.36.4}
CONTAINERD_VERSION=${CONTAINERD_VERSION:-2.3.4}

export DEBIAN_FRONTEND=noninteractive

swapoff -a
modprobe overlay
modprobe br_netfilter
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.bridge.bridge-nf-call-iptables=1
sysctl -w net.bridge.bridge-nf-call-ip6tables=1

apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg jq conntrack iproute2 \
  iptables socat ethtool

install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" |
  gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
printf '%s\n' \
  "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y \
  "kubelet=${KUBERNETES_VERSION}-1.1" \
  "kubeadm=${KUBERNETES_VERSION}-1.1" \
  "kubectl=${KUBERNETES_VERSION}-1.1" \
  cri-tools runc
apt-mark hold kubelet kubeadm kubectl

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
archive="containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
curl -fsSLo "$tmp_dir/$archive" \
  "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/$archive"
curl -fsSLo "$tmp_dir/$archive.sha256sum" \
  "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/$archive.sha256sum"
(
  cd "$tmp_dir"
  sha256sum --check "$archive.sha256sum"
)
tar -C /usr/local -xzf "$tmp_dir/$archive"

install -d -m 0755 /etc/containerd
if [[ -f /etc/containerd/config.toml && ! -f /etc/containerd/config.toml.s03-pre ]]; then
  cp /etc/containerd/config.toml /etc/containerd/config.toml.s03-pre
fi
/usr/local/bin/containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

printf '%s\n' \
  '[Unit]' \
  'Description=containerd container runtime' \
  'Documentation=https://containerd.io' \
  'After=network.target local-fs.target' \
  '' \
  '[Service]' \
  'ExecStartPre=-/sbin/modprobe overlay' \
  'ExecStart=/usr/local/bin/containerd' \
  'Type=notify' \
  'Delegate=yes' \
  'KillMode=process' \
  'Restart=always' \
  'RestartSec=5' \
  'LimitNPROC=infinity' \
  'LimitCORE=infinity' \
  'LimitNOFILE=infinity' \
  'TasksMax=infinity' \
  'OOMScoreAdjust=-999' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  >/etc/systemd/system/containerd.service

systemctl daemon-reload
systemctl enable --now containerd
systemctl enable kubelet

test "$(/usr/local/bin/containerd --version | awk '{print $3}')" = "v${CONTAINERD_VERSION}"
test "$(kubeadm version -o short)" = "v${KUBERNETES_VERSION}"
test -c /dev/kvm
grep -q '^kvm_pvm ' /proc/modules

printf 'NODE_PREPARED kubernetes=%s containerd=%s kernel=%s\n' \
  "$(kubeadm version -o short)" \
  "$(/usr/local/bin/containerd --version | awk '{print $3}')" \
  "$(uname -r)"
