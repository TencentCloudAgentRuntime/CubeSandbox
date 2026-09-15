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
		"kubelet_(pod_start_duration_seconds|pod_start_sli_duration_seconds|pod_start_total_duration_seconds|pod_worker_duration_seconds|runtime_operations_duration_seconds)_(bucket|sum|count)",
		"node_disk_io_time_seconds_total;nbd.*",
		"requests: {cpu: 100m, memory: 1Gi}",
		"limits: {cpu: \"1\", memory: 4Gi}",
	} {
		if !strings.Contains(string(manifest), want) {
			t.Fatalf("generated manifest is missing %q", want)
		}
	}
}
