// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
)

func testTemplateAssets() Assets {
	return Assets{KernelPath: "/assets/kernel", AgentPath: "/assets/agent", GuestImagePath: "/assets/guest.img"}
}

func testTemplateRequest() *runtimev1.ResourceRequest {
	return &runtimev1.ResourceRequest{VcpuCount: 1, MemoryBytes: 128 * 1024 * 1024}
}

func publishTestTemplate(t *testing.T, root string, assets Assets, request *runtimev1.ResourceRequest) string {
	t.Helper()
	key := templateKey(request, assets)
	base := filepath.Join(root, "snapshot-base")
	if err := os.MkdirAll(filepath.Join(base, "1C128M", "snapshot"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, "1C128M", "metadata.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(templateManifest{SnapshotBase: base, TemplateKey: key})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, key), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, key, templateReadyFile), data, 0o600); err != nil {
		t.Fatal(err)
	}
	return key
}

func TestTemplateResolverUsesOnlyPublishedMatchingTemplate(t *testing.T) {
	root := t.TempDir()
	assets, request := testTemplateAssets(), testTemplateRequest()
	key := publishTestTemplate(t, root, assets, request)
	resolver, err := newTemplateResolver(root, "")
	if err != nil {
		t.Fatal(err)
	}
	manifest := resolver.resolve(request, assets)
	if manifest == nil || manifest.TemplateKey != key {
		t.Fatalf("expected published template %q, got %#v", key, manifest)
	}
	if resolver.resolve(&runtimev1.ResourceRequest{VcpuCount: 2, MemoryBytes: request.MemoryBytes}, assets) != nil {
		t.Fatal("a different VM profile must not reuse a template")
	}
}

func TestTemplateResolverQueuesOneBuildPerMiss(t *testing.T) {
	root := t.TempDir()
	assets, request := testTemplateAssets(), testTemplateRequest()
	resolver, err := newTemplateResolver(root, "producer")
	if err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	resolver.run = func(_ context.Context, _ string, _ string, _ uint32, _ uint64) error {
		started <- struct{}{}
		<-release
		return nil
	}
	if resolver.resolve(request, assets) != nil || resolver.resolve(request, assets) != nil {
		t.Fatal("a missing template must stay on the cold path")
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("template build was not queued")
	}
	select {
	case <-started:
		t.Fatal("duplicate miss queued more than one build")
	default:
	}
	close(release)
}

func TestTemplateResolverColdModeSkipsReuseAndBuild(t *testing.T) {
	root := t.TempDir()
	assets, request := testTemplateAssets(), testTemplateRequest()
	resolver, err := newTemplateResolver(root, "producer")
	if err != nil {
		t.Fatal(err)
	}
	called := make(chan struct{}, 1)
	resolver.run = func(_ context.Context, _ string, _ string, _ uint32, _ uint64) error {
		called <- struct{}{}
		return nil
	}
	manifest, err := resolver.resolveForMode(templateModeCold, request, assets)
	if err != nil || manifest != nil {
		t.Fatalf("cold mode must not resolve a template: manifest=%#v err=%v", manifest, err)
	}
	select {
	case <-called:
		t.Fatal("cold mode must not queue a template build")
	case <-time.After(50 * time.Millisecond):
	}
}

func TestTemplateKeyTracksResolvedAssetRelease(t *testing.T) {
	root := t.TempDir()
	for _, release := range []string{"release-a", "release-b"} {
		path := filepath.Join(root, release)
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "agent"), []byte("same-size"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	current := filepath.Join(root, "current")
	if err := os.Symlink(filepath.Join(root, "release-a"), current); err != nil {
		t.Fatal(err)
	}
	assets := Assets{AgentPath: filepath.Join(current, "agent")}
	request := testTemplateRequest()
	first := templateKey(request, assets)
	if err := os.Remove(current); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "release-b"), current); err != nil {
		t.Fatal(err)
	}
	if second := templateKey(request, assets); second == first {
		t.Fatal("template key must change when the resolved asset release changes")
	}
}
