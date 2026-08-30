#!/usr/bin/env bash
set -euo pipefail

CILIUM_VERSION=${CILIUM_VERSION:-1.20.0}
HELM_VERSION=${HELM_VERSION:-v3.18.4}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

curl -fsSLo "$tmp_dir/helm.tar.gz" \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLo "$tmp_dir/helm.sha256sum" \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
printf '%s  %s\n' "$(awk '{print $1}' "$tmp_dir/helm.sha256sum")" "$tmp_dir/helm.tar.gz" |
  sha256sum --check -
tar -C "$tmp_dir" -xzf "$tmp_dir/helm.tar.gz"
install -m 0755 "$tmp_dir/linux-amd64/helm" /usr/local/bin/helm

helm repo add cilium https://helm.cilium.io/
helm repo update
helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set kubeProxyReplacement=false \
  --set operator.replicas=1

kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m
kubectl -n kube-system rollout status deployment/coredns --timeout=10m
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
echo CILIUM_INSTALLED
