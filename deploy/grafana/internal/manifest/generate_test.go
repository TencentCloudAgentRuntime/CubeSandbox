package manifest

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"cube-cri-grafana/internal/dashboard"
)

func TestGeneratedManifestMatchesArtifact(t *testing.T) {
	dashboard, err := dashboard.Generate()
	if err != nil { t.Fatal(err) }
	got, err := Generate(dashboard)
	if err != nil { t.Fatal(err) }
	want, err := os.ReadFile(filepath.Join("..", "..", "..", "kubernetes", "cube-cri-monitoring", "monitoring.yaml"))
	if err != nil { t.Fatal(err) }
	if !bytes.Equal(got, want) { t.Fatal("generated manifest differs; run go run ./cmd/grafanacfg") }
}
