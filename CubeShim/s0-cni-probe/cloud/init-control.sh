#!/usr/bin/env bash
set -euo pipefail

CONTROL_IP=${CONTROL_IP:-172.19.200.7}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-v1.36.4}

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  kubeadm init \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --apiserver-advertise-address "$CONTROL_IP" \
    --control-plane-endpoint "${CONTROL_IP}:6443" \
    --pod-network-cidr 10.244.0.0/16 \
    --service-cidr 10.96.0.0/12 \
    --cri-socket unix:///run/containerd/containerd.sock
fi

install -d -m 0700 /root/.kube
install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
kubectl get nodes -o wide
echo CONTROL_PLANE_INITIALIZED
