package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"cube-cri-grafana/internal/dashboard"
	"cube-cri-grafana/internal/manifest"
)

func main() {
	output := flag.String("output", filepath.Join("..", "kubernetes", "cube-cri-monitoring", "monitoring.yaml"), "generated Kubernetes manifest")
	check := flag.Bool("check", false, "fail if output differs from generated manifest")
	flag.Parse()
	dashboardJSON, err := dashboard.Generate()
	if err != nil { exitf("generate dashboard: %v", err) }
	generated, err := manifest.Generate(dashboardJSON)
	if err != nil { exitf("generate manifest: %v", err) }
	if *check {
		current, err := os.ReadFile(*output)
		if err != nil { exitf("read %s: %v", *output, err) }
		if !bytes.Equal(current, generated) { exitf("%s is out of date; run go run ./cmd/grafanacfg", *output) }
		return
	}
	if err := os.MkdirAll(filepath.Dir(*output), 0o755); err != nil { exitf("prepare output: %v", err) }
	if err := os.WriteFile(*output, generated, 0o644); err != nil { exitf("write output: %v", err) }
}

func exitf(format string, args ...any) { fmt.Fprintf(os.Stderr, format+"\n", args...); os.Exit(1) }
