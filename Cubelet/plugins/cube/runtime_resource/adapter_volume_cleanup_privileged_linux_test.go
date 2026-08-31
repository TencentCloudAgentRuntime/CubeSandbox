// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package runtimeresource

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"golang.org/x/sys/unix"
)

func TestAdapterReleaseUnmountsRealBindBeforeRemovingSharedRoot(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("real bind mount requires root")
	}

	ctx := context.Background()
	network := new(fakeNetwork)
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "resources"), testAssets(t), network)
	if err != nil {
		t.Fatal(err)
	}
	lease := state.Lease{Generation: 3, LeaseID: "lease-a"}
	prepared, err := adapter.Prepare(ctx, adapterRequest(), lease)
	if err != nil {
		t.Fatal(err)
	}
	root := prepared.GetAssets().GetSharedRoot()
	source := filepath.Join(t.TempDir(), "source")
	target := filepath.Join(root, "volumes", "task-generation", "000")
	for _, path := range []string{source, target} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	sentinel := filepath.Join(source, "must-survive")
	if err := os.WriteFile(sentinel, []byte("volume-data"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mount(source, target, "", unix.MS_BIND|unix.MS_REC, ""); err != nil {
		if errors.Is(err, unix.EPERM) || errors.Is(err, unix.EACCES) {
			t.Skipf("mount namespace does not allow bind mounts: %v", err)
		}
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = unix.Unmount(target, unix.MNT_DETACH) })

	release := state.ReleaseRequest{SandboxID: "sandbox-a", Generation: 3, LeaseID: "lease-a"}
	if err := adapter.Release(ctx, release, prepared.GetNetwork().GetNetworkHandle()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("shared root remains after Release: %v", err)
	}
	if data, err := os.ReadFile(sentinel); err != nil || string(data) != "volume-data" {
		t.Fatalf("bind source was traversed or changed: data=%q err=%v", data, err)
	}
	if targets, err := mountedTargetsUnder(root); err != nil || len(targets) != 0 {
		t.Fatalf("mounts remain below released root: targets=%v err=%v", targets, err)
	}
}
