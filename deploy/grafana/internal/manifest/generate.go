package manifest

import (
	"bytes"
	"encoding/json"
	"fmt"
)

const prefix = `apiVersion: v1
kind: ConfigMap
metadata:
  name: cube-cri-prometheus-config
  namespace: __NAMESPACE__
data:
  prometheus.yml: |
    global:
      scrape_interval: 5s
      evaluation_interval: 5s
    scrape_configs:
    - job_name: cube-cri
      # Startup bursts are shorter than the default node scrape interval.
      # This endpoint is node-local and bounded, so retain one-second samples
      # for queue and active-operation diagnosis without increasing kubelet or
      # node-exporter collection load.
      scrape_interval: 1s
      metrics_path: /metrics
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - source_labels: [__meta_kubernetes_node_label_cubesandbox_io_runtime]
        regex: cube
        action: keep
      - source_labels: [__meta_kubernetes_node_address_InternalIP]
        regex: (.+)
        target_label: __address__
        replacement: ${1}:10098
      - source_labels: [__meta_kubernetes_node_name]
        target_label: node
    - job_name: kubelet
      scheme: https
      metrics_path: /metrics
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      tls_config:
        insecure_skip_verify: true
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - source_labels: [__meta_kubernetes_node_label_cubesandbox_io_runtime]
        regex: cube
        action: keep
      - source_labels: [__meta_kubernetes_node_address_InternalIP]
        regex: (.+)
        target_label: __address__
        replacement: ${1}:10250
      - source_labels: [__meta_kubernetes_node_name]
        target_label: node
    - job_name: node-exporter
      metrics_path: /metrics
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - source_labels: [__meta_kubernetes_node_label_cubesandbox_io_runtime]
        regex: cube
        action: keep
      - source_labels: [__meta_kubernetes_node_address_InternalIP]
        regex: (.+)
        target_label: __address__
        replacement: ${1}:9100
      - source_labels: [__meta_kubernetes_node_name]
        target_label: node
    - job_name: apiserver
      scheme: https
      metrics_path: /metrics
      sample_limit: 5000
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      tls_config:
        insecure_skip_verify: true
      static_configs:
      - targets: [kubernetes.default.svc:443]
      # The full managed-control-plane endpoint has high cardinality. Keep
      # only the request family that forms the Pod startup API boundary.
      metric_relabel_configs:
      - source_labels: [__name__, verb, resource, subresource]
        regex: apiserver_request_duration_seconds_(bucket|sum|count);POST;pods;
        action: keep
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cube-cri-prometheus
  namespace: __NAMESPACE__
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cube-cri-prometheus-node-discovery
rules:
- apiGroups: [""]
  resources: [nodes]
  verbs: [get, list, watch]
- apiGroups: [""]
  resources: [nodes/metrics]
  verbs: [get]
- nonResourceURLs: ["/metrics"]
  verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cube-cri-prometheus-node-discovery
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cube-cri-prometheus-node-discovery
subjects:
- kind: ServiceAccount
  name: cube-cri-prometheus
  namespace: __NAMESPACE__
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cube-cri-node-exporter
  namespace: __NAMESPACE__
spec:
  selector:
    matchLabels: {app: cube-cri-node-exporter}
  template:
    metadata:
      labels: {app: cube-cri-node-exporter}
    spec:
      hostNetwork: true
      hostPID: true
      nodeSelector: {cubesandbox.io/runtime: cube}
      tolerations:
      - operator: Exists
      containers:
      - name: node-exporter
        image: prom/node-exporter:v1.8.2
        args:
        - --path.rootfs=/host
        - --path.procfs=/host/proc
        - --path.sysfs=/host/sys
        ports:
        - {name: metrics, containerPort: 9100, hostPort: 9100}
        resources:
          requests: {cpu: 25m, memory: 64Mi}
          limits: {cpu: 100m, memory: 128Mi}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
        volumeMounts:
        - {name: root, mountPath: /host, readOnly: true}
      volumes:
      - name: root
        hostPath: {path: /}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cube-cri-prometheus-data
  namespace: __NAMESPACE__
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cube-cri-prometheus
  namespace: __NAMESPACE__
spec:
  # Prometheus uses a single-writer PVC; a rolling surge would contend on its
  # TSDB lock during every configuration update.
  strategy: {type: Recreate}
  replicas: 1
  selector:
    matchLabels: {app: cube-cri-prometheus}
  template:
    metadata:
      labels: {app: cube-cri-prometheus}
    spec:
      serviceAccountName: cube-cri-prometheus
      securityContext:
        fsGroup: 65534
        fsGroupChangePolicy: OnRootMismatch
      containers:
      - name: prometheus
        image: prom/prometheus:v2.55.1
        args:
        - --config.file=/etc/prometheus/prometheus.yml
        - --storage.tsdb.path=/prometheus
        - --storage.tsdb.retention.time=24h
        - --web.enable-lifecycle
        ports:
        - {name: web, containerPort: 9090}
        readinessProbe:
          httpGet: {path: /-/ready, port: web}
          initialDelaySeconds: 5
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits: {cpu: "1", memory: 1Gi}
        volumeMounts:
        - {name: config, mountPath: /etc/prometheus, readOnly: true}
        - {name: data, mountPath: /prometheus}
      volumes:
      - name: config
        configMap: {name: cube-cri-prometheus-config}
      - name: data
        persistentVolumeClaim:
          claimName: cube-cri-prometheus-data
---
apiVersion: v1
kind: Service
metadata:
  name: cube-cri-prometheus
  namespace: __NAMESPACE__
spec:
  selector: {app: cube-cri-prometheus}
  ports:
  - {name: web, port: 9090, targetPort: web}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cube-cri-grafana-provisioning
  namespace: __NAMESPACE__
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
    - name: Cube CRI Prometheus
      uid: cube-cri-prometheus
      type: prometheus
      access: proxy
      url: http://cube-cri-prometheus.__NAMESPACE__.svc:9090
      isDefault: true
      editable: true
      jsonData: {timeInterval: 1s, queryTimeout: 30s}
  dashboards.yaml: |
    apiVersion: 1
    providers:
    - name: cube-cri
      orgId: 1
      folder: Cube CRI
      type: file
      updateIntervalSeconds: 10
      options: {path: /var/lib/grafana/dashboards}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cube-cri-grafana-dashboards
  namespace: __NAMESPACE__
data:
  cube-cri-runtime.json: |
`

const suffix = `---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cube-cri-grafana
  namespace: __NAMESPACE__
spec:
  replicas: 1
  selector:
    matchLabels: {app: cube-cri-grafana}
  template:
    metadata:
      labels: {app: cube-cri-grafana}
    spec:
      securityContext: {fsGroup: 472}
      containers:
      - name: grafana
        image: grafana/grafana:11.4.0
        env:
        - {name: GF_AUTH_ANONYMOUS_ENABLED, value: "true"}
        - {name: GF_AUTH_ANONYMOUS_ORG_ROLE, value: Viewer}
        - {name: GF_SECURITY_ADMIN_USER, value: admin}
        - {name: GF_SECURITY_ADMIN_PASSWORD, value: admin}
        - {name: GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH, value: /var/lib/grafana/dashboards/cube-cri-runtime.json}
        ports:
        - {name: web, containerPort: 3000}
        readinessProbe:
          httpGet: {path: /api/health, port: web}
          initialDelaySeconds: 10
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits: {cpu: "1", memory: 1Gi}
        volumeMounts:
        - {name: provisioning, mountPath: /etc/grafana/provisioning, readOnly: true}
        - {name: dashboards, mountPath: /var/lib/grafana/dashboards, readOnly: true}
        - {name: data, mountPath: /var/lib/grafana}
      volumes:
      - name: provisioning
        configMap:
          name: cube-cri-grafana-provisioning
          items:
          - {key: datasources.yaml, path: datasources/datasources.yaml}
          - {key: dashboards.yaml, path: dashboards/dashboards.yaml}
      - name: dashboards
        configMap: {name: cube-cri-grafana-dashboards}
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: cube-cri-grafana
  namespace: __NAMESPACE__
spec:
  selector: {app: cube-cri-grafana}
  ports:
  - {name: web, port: 3000, targetPort: web}
`

func Generate(dashboard []byte) ([]byte, error) {
	if !json.Valid(dashboard) {
		return nil, fmt.Errorf("dashboard JSON is invalid")
	}
	var out bytes.Buffer
	out.WriteString(prefix)
	for _, line := range bytes.Split(bytes.TrimRight(dashboard, "\n"), []byte("\n")) {
		out.WriteString("    ")
		out.Write(line)
		out.WriteByte('\n')
	}
	out.WriteString(suffix)
	return out.Bytes(), nil
}
