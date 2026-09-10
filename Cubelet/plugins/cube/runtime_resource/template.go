// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

// This file intentionally owns only template selection and publication. The
// actual VM is built by Cube's existing template producer, invoked as a
// separate process, so RuntimeResource does not acquire legacy Cubelet or
// CubeCow lifecycle ownership.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
)

const templateReadyFile = "ready.json"
const templateBuildTimeout = 15 * time.Minute
const templateFormat = "v11-networkless-hotplug-net-cgroupv2"
const templateModeAuto = "auto"
const templateModeCold = "cold"

// templateManifest is atomically published by the template producer only
// after Cube's snapshot, metadata and optional CubeCow memory object are all
// ready. RuntimeResource never guesses a partially-built template.
type templateManifest struct {
	SnapshotBase         string `json:"snapshot_base"`
	SnapshotMemoryVolURL string `json:"snapshot_memory_vol_url,omitempty"`
	TemplateKey          string `json:"template_key"`
}

type templateResolver struct {
	root     string
	builder  []string
	mu       sync.Mutex
	building map[string]struct{}
	run      func(context.Context, string, string, uint32, uint64) error
}

func newTemplateResolver(root, builder string) (*templateResolver, error) {
	root = strings.TrimSpace(root)
	if root == "" {
		return nil, nil
	}
	if !filepath.IsAbs(root) {
		return nil, fmt.Errorf("template root must be absolute: %q", root)
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, fmt.Errorf("create template root %q: %w", root, err)
	}
	r := &templateResolver{root: filepath.Clean(root), builder: strings.Fields(builder), building: make(map[string]struct{})}
	r.run = r.runBuilder
	return r, nil
}

func templateKey(resources *runtimev1.ResourceRequest, assets Assets) string {
	cpu, memory := templateResources(resources)
	identity := strings.Join([]string{
		templateFormat,
		fmt.Sprintf("%dC%dM", cpu, memory),
		assetFingerprint(assets.KernelPath),
		assetFingerprint(assets.AgentPath),
		assetFingerprint(assets.GuestImagePath),
	}, "\x00")
	digest := sha256.Sum256([]byte(identity))
	return fmt.Sprintf("%dC%dM-%s", cpu, memory, hex.EncodeToString(digest[:8]))
}

func assetFingerprint(path string) string {
	// Runtime assets are installed under /opt/cube-cri/current. The installer
	// deliberately normalizes file mtimes, so size+mtime alone can leave an
	// old VM snapshot eligible after the current release symlink changes.
	// Include the resolved release path to invalidate snapshots across every
	// runtime release switch.
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		path = resolved
	}
	info, err := os.Stat(path)
	if err != nil {
		return path + ":missing"
	}
	return fmt.Sprintf("%s:%d:%d", path, info.Size(), info.ModTime().UnixNano())
}

func templateResources(resources *runtimev1.ResourceRequest) (uint32, uint64) {
	if resources == nil {
		return 0, 0
	}
	return resources.GetVcpuCount(), (resources.GetMemoryBytes() + 1024*1024 - 1) / (1024 * 1024)
}

// resolve returns a published template when it exactly matches this VM
// profile. A miss never delays the current Pod: it queues one single-flight
// producer and returns cold-start assets.
func (r *templateResolver) resolve(resources *runtimev1.ResourceRequest, assets Assets) *templateManifest {
	if r == nil {
		return nil
	}
	key := templateKey(resources, assets)
	cpu, memory := templateResources(resources)
	if cpu == 0 || memory == 0 {
		return nil
	}
	manifestPath := filepath.Join(r.root, key, templateReadyFile)
	manifest, err := loadTemplateManifest(manifestPath, key, cpu, memory)
	if err == nil {
		return manifest
	}
	r.enqueue(key, cpu, memory)
	return nil
}

func (r *templateResolver) resolveForMode(mode string, resources *runtimev1.ResourceRequest, assets Assets) (*templateManifest, error) {
	if !templateReuseEnabled(mode) {
		return nil, nil
	}
	return r.resolve(resources, assets), nil
}

func templateReuseEnabled(mode string) bool {
	return mode == "" || mode == templateModeAuto
}

func loadTemplateManifest(path, key string, cpu uint32, memory uint64) (*templateManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var manifest templateManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, fmt.Errorf("decode template manifest %q: %w", path, err)
	}
	if manifest.TemplateKey != key || !filepath.IsAbs(manifest.SnapshotBase) {
		return nil, fmt.Errorf("template manifest %q does not match profile", path)
	}
	metadata := filepath.Join(manifest.SnapshotBase, fmt.Sprintf("%dC%dM", cpu, memory), "metadata.json")
	if info, err := os.Stat(metadata); err != nil || info.IsDir() {
		return nil, fmt.Errorf("template metadata %q is not ready", metadata)
	}
	if info, err := os.Stat(filepath.Join(filepath.Dir(metadata), "snapshot")); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("template snapshot next to %q is not ready", metadata)
	}
	return &manifest, nil
}

func (r *templateResolver) enqueue(key string, cpu uint32, memory uint64) {
	if len(r.builder) == 0 {
		return
	}
	r.mu.Lock()
	if _, exists := r.building[key]; exists {
		r.mu.Unlock()
		return
	}
	r.building[key] = struct{}{}
	r.mu.Unlock()
	go func() {
		defer func() {
			r.mu.Lock()
			delete(r.building, key)
			r.mu.Unlock()
		}()
		ctx, cancel := context.WithTimeout(context.Background(), templateBuildTimeout)
		defer cancel()
		if err := r.run(ctx, key, filepath.Join(r.root, key), cpu, memory); err != nil {
			log.Printf("template build profile=%s failed: %v", key, err)
		}
	}()
}

func (r *templateResolver) runBuilder(ctx context.Context, key, output string, cpu uint32, memory uint64) error {
	if len(r.builder) == 0 {
		return nil
	}
	args := append([]string{}, r.builder[1:]...)
	args = append(args, "--template-key", key, "--output", output, "--cpu", fmt.Sprint(cpu), "--memory-mib", fmt.Sprint(memory))
	cmd := exec.CommandContext(ctx, r.builder[0], args...)
	outputBytes, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("run template builder: %w: %s", err, strings.TrimSpace(string(outputBytes)))
	}
	if _, err := loadTemplateManifest(filepath.Join(output, templateReadyFile), key, cpu, memory); err != nil {
		return fmt.Errorf("template builder returned without a valid ready manifest: %w", err)
	}
	return nil
}

// Tests keep template selection independent from the privileged Cube template
// producer. The producer contract is covered by the ready-manifest validation.
