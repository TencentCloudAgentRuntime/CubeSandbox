#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ! -f ${CUBE_CRI_ENV:-local.env} ]] || { set -a; source "${CUBE_CRI_ENV:-local.env}"; set +a; }

namespace=${CUBE_CRI_TRACING_NAMESPACE:-cube-cri-tracing}
jaeger_image=${CUBE_CRI_JAEGER_IMAGE:-jaegertracing/all-in-one:1.57}
collector_image=${CUBE_CRI_OTEL_COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.102.1}
manifest=_output/cube-cri/tracing.yaml

[[ $namespace =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "非法 namespace: $namespace" >&2; exit 2; }
[[ $jaeger_image =~ ^[A-Za-z0-9./:_@-]+$ ]] || { echo "非法 Jaeger 镜像: $jaeger_image" >&2; exit 2; }
[[ $collector_image =~ ^[A-Za-z0-9./:_@-]+$ ]] || { echo "非法 OTel Collector 镜像: $collector_image" >&2; exit 2; }

mkdir -p "$(dirname "$manifest")"
cat > "$manifest" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cube-cri-otel-collector
  namespace: ${namespace}
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch: {}
      memory_limiter:
        check_interval: 1s
        limit_mib: 256
    exporters:
      otlp/jaeger:
        endpoint: cube-cri-jaeger.${namespace}.svc.cluster.local:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/jaeger]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cube-cri-otel-collector
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: cube-cri-otel-collector
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cube-cri-otel-collector
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cube-cri-otel-collector
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        - name: otel-collector
          image: ${collector_image}
          args: ["--config=/etc/otelcol/config.yaml"]
          ports:
            - name: otlp-grpc
              containerPort: 4317
              hostPort: 4317
            - name: otlp-http
              containerPort: 4318
              hostPort: 4318
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /etc/otelcol
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: cube-cri-otel-collector
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cube-cri-jaeger
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: cube-cri-jaeger
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: cube-cri-jaeger
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cube-cri-jaeger
    spec:
      containers:
        - name: jaeger
          image: ${jaeger_image}
          env:
            - name: COLLECTOR_OTLP_ENABLED
              value: "true"
          ports:
            - name: ui
              containerPort: 16686
            - name: otlp-grpc
              containerPort: 4317
            - name: otlp-http
              containerPort: 4318
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: cube-cri-jaeger
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: cube-cri-jaeger
spec:
  selector:
    app.kubernetes.io/name: cube-cri-jaeger
  ports:
    - name: ui
      port: 16686
      targetPort: ui
    - name: otlp-grpc
      port: 4317
      targetPort: otlp-grpc
    - name: otlp-http
      port: 4318
      targetPort: otlp-http
YAML

kubectl apply -f "$manifest"
kubectl -n "$namespace" rollout status deployment/cube-cri-jaeger --timeout=180s
kubectl -n "$namespace" rollout status daemonset/cube-cri-otel-collector --timeout=180s
kubectl -n "$namespace" get service cube-cri-jaeger
cat <<EOF
Jaeger UI:
  kubectl -n $namespace port-forward service/cube-cri-jaeger 16686:16686

Cube CRI tracing endpoint:
  --set-string tracing.otlpEndpoint=http://127.0.0.1:4318
  --set-string tracing.protocol=http/protobuf
EOF
