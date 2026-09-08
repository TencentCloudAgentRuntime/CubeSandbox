#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }

namespace=${CUBE_CRI_MONITORING_NAMESPACE:-cube-cri-monitoring}
[[ $namespace =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "非法 namespace: $namespace" >&2; exit 2; }
manifest=_output/cube-cri/monitoring.yaml
mkdir -p "$(dirname "$manifest")"
(cd deploy/grafana && go run ./cmd/grafanacfg --output "../../$manifest")
rendered=_output/cube-cri/monitoring-rendered.yaml
sed "s/__NAMESPACE__/$namespace/g" "$manifest" > "$rendered"

kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace"
prometheus_version=$(kubectl -n "$namespace" get configmap cube-cri-prometheus-config -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)
dashboard_version=$(kubectl -n "$namespace" get configmap cube-cri-grafana-dashboards -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)
kubectl apply -f "$rendered"
updated_prometheus_version=$(kubectl -n "$namespace" get configmap cube-cri-prometheus-config -o jsonpath='{.metadata.resourceVersion}')
updated_dashboard_version=$(kubectl -n "$namespace" get configmap cube-cri-grafana-dashboards -o jsonpath='{.metadata.resourceVersion}')
if [[ -n $prometheus_version && $prometheus_version != "$updated_prometheus_version" ]]; then
  kubectl -n "$namespace" rollout restart deployment/cube-cri-prometheus
fi
if [[ -n $dashboard_version && $dashboard_version != "$updated_dashboard_version" ]]; then
  kubectl -n "$namespace" rollout restart deployment/cube-cri-grafana
fi
kubectl -n "$namespace" rollout status deployment/cube-cri-prometheus --timeout=180s
kubectl -n "$namespace" rollout status deployment/cube-cri-grafana --timeout=180s
kubectl -n "$namespace" get service cube-cri-prometheus cube-cri-grafana
echo "Grafana: kubectl -n $namespace port-forward service/cube-cri-grafana 3000:3000"
