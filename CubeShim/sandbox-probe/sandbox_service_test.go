// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	sandboxapi "github.com/containerd/containerd/api/runtime/sandbox/v1"
	"github.com/containerd/containerd/v2/pkg/shutdown"
)

func TestSandboxLifecycle(t *testing.T) {
	trace := filepath.Join(t.TempDir(), "trace.jsonl")
	t.Setenv("CUBE_S0_TRACE_PATH", trace)
	_, sd := shutdown.WithShutdown(context.Background())
	service := newSandboxService(sd)
	ctx := context.Background()

	_, err := service.CreateSandbox(ctx, &sandboxapi.CreateSandboxRequest{
		SandboxID:  "sandbox-test",
		BundlePath: "/run/test/bundle",
		NetnsPath:  "/run/netns/test",
	})
	if err != nil {
		t.Fatalf("CreateSandbox() error = %v", err)
	}
	created, err := service.SandboxStatus(ctx, &sandboxapi.SandboxStatusRequest{
		SandboxID: "sandbox-test",
	})
	if err != nil {
		t.Fatalf("SandboxStatus(created) error = %v", err)
	}
	if created.GetState() != "SANDBOX_NOTREADY" {
		t.Fatalf("created state = %q, want SANDBOX_NOTREADY", created.GetState())
	}

	started, err := service.StartSandbox(ctx, &sandboxapi.StartSandboxRequest{
		SandboxID: "sandbox-test",
	})
	if err != nil {
		t.Fatalf("StartSandbox() error = %v", err)
	}
	if started.GetPid() != uint32(os.Getpid()) {
		t.Fatalf("pid = %d, want %d", started.GetPid(), os.Getpid())
	}
	status, err := service.SandboxStatus(ctx, &sandboxapi.SandboxStatusRequest{
		SandboxID: "sandbox-test",
	})
	if err != nil {
		t.Fatalf("SandboxStatus(ready) error = %v", err)
	}
	if status.GetState() != "SANDBOX_READY" {
		t.Fatalf("ready state = %q, want SANDBOX_READY", status.GetState())
	}

	platform, err := service.Platform(ctx, &sandboxapi.PlatformRequest{SandboxID: "sandbox-test"})
	if err != nil {
		t.Fatalf("Platform() error = %v", err)
	}
	if platform.GetPlatform().GetOS() != runtime.GOOS || platform.GetPlatform().GetArchitecture() != runtime.GOARCH {
		t.Fatalf("platform = %v, want %s/%s", platform.GetPlatform(), runtime.GOOS, runtime.GOARCH)
	}

	waited := make(chan *sandboxapi.WaitSandboxResponse, 1)
	go func() {
		response, waitErr := service.WaitSandbox(ctx, &sandboxapi.WaitSandboxRequest{SandboxID: "sandbox-test"})
		if waitErr == nil {
			waited <- response
		}
	}()
	select {
	case <-waited:
		t.Fatal("WaitSandbox returned before StopSandbox")
	case <-time.After(20 * time.Millisecond):
	}
	if _, err := service.StopSandbox(ctx, &sandboxapi.StopSandboxRequest{SandboxID: "sandbox-test"}); err != nil {
		t.Fatalf("StopSandbox() error = %v", err)
	}
	select {
	case response := <-waited:
		if response.GetExitStatus() != 0 || response.GetExitedAt() == nil {
			t.Fatalf("WaitSandbox() response = %v", response)
		}
	case <-time.After(time.Second):
		t.Fatal("WaitSandbox did not return after StopSandbox")
	}
	if _, err := os.Stat(trace); err != nil {
		t.Fatalf("trace was not written: %v", err)
	}
}
