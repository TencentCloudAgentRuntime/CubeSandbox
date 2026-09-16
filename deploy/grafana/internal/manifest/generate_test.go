package manifest

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cube-cri-grafana/internal/dashboard"
)

func TestGeneratedManifestMatchesArtifact(t *testing.T) {
	dashboard, err := dashboard.Generate()
	if err != nil {
		t.Fatal(err)
	}
	got, err := Generate(dashboard)
	if err != nil {
		t.Fatal(err)
	}
	want, err := os.ReadFile(filepath.Join("..", "..", "..", "kubernetes", "cube-cri-monitoring", "monitoring.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("generated manifest differs; run go run ./cmd/grafanacfg")
	}
}

func TestControlPlaneAndIPAMScrapeJobs(t *testing.T) {
	dashboardJSON, err := dashboard.Generate()
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := Generate(dashboardJSON)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"master-metrics-service.kube-system.svc:19090",
		"scheduler_pod_scheduling_sli_duration_seconds_(bucket|sum|count)",
		"tke-eni-ipamd.kube-system.svc:8080",
		"ipamd_pod_set_ip_latency_seconds_(bucket|sum|count)",
		"pod_worker_start_duration_seconds",
		"run_podsandbox_duration_seconds",
		"pleg_relist_duration_seconds",
		"runtime_operations_(errors_)?total",
		"started_pods(_errors)?_total",
		"image_manager_ensure_image_requests_total",
		"node_disk_io_time_seconds_total;nbd.*",
		"nodeSelector: {agc.cloud.tencent.com/cube-monitoring: \"true\"}",
		"{key: cube-cri-load-generator, operator: Equal, value: \"true\", effect: NoSchedule}",
		"requests: {cpu: 100m, memory: 1Gi}",
		"limits: {cpu: \"1\", memory: 4Gi}",
	} {
		if !strings.Contains(string(manifest), want) {
			t.Fatalf("generated manifest is missing %q", want)
		}
	}
}
