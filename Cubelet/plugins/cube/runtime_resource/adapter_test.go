// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"golang.org/x/sys/unix"
)

type fakeNetwork struct {
	prepareCalls int
	releaseCalls int
	openCalls    int
	prepareErr   error
	releaseErr   error
}

func (n *fakeNetwork) Prepare(context.Context, string, string, string) (*runtimev1.NetworkAttachment, error) {
	n.prepareCalls++
	if n.prepareErr != nil {
		return nil, n.prepareErr
	}
	return &runtimev1.NetworkAttachment{
		GuestInterfaceName: "eth0", Mac: "02:00:00:00:00:01", Mtu: 1450,
		Ips: []string{"10.0.0.2/24"},
	}, nil
}

func (n *fakeNetwork) Release(context.Context, string, string, string) error {
	n.releaseCalls++
	return n.releaseErr
}

func TestAdapterReleaseNeverTraversesAnActiveVolumeMount(t *testing.T) {
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
	target := filepath.Join(root, "volumes", "task-generation", "000")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(t.TempDir(), "source")
	if err := os.MkdirAll(source, 0o755); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(source, "must-survive")
	if err := os.WriteFile(sentinel, []byte("volume-data"), 0o600); err != nil {
		t.Fatal(err)
	}
	removeCalled := false
	adapter.cleanup = sharedRootCleanupOps{
		mountTargets: func(string) ([]string, error) { return []string{target}, nil },
		unmount:      func(string, int) error { return errors.New("injected unmount failure") },
		removeAll: func(string) error {
			removeCalled = true
			return nil
		},
	}
	release := state.ReleaseRequest{SandboxID: "sandbox-a", Generation: 3, LeaseID: "lease-a"}
	if err := adapter.Release(ctx, release, prepared.GetNetwork().GetNetworkHandle()); err == nil {
		t.Fatal("Release succeeded while both unmount modes failed")
	}
	if removeCalled {
		t.Fatal("RemoveAll called while a writable bind was still active")
	}
	if network.releaseCalls != 0 {
		t.Fatalf("network released before volume cleanup: calls=%d", network.releaseCalls)
	}
	if _, err := adapter.load("sandbox-a"); err != nil {
		t.Fatalf("adapter record not retained for retry: %v", err)
	}
	if data, err := os.ReadFile(sentinel); err != nil || string(data) != "volume-data" {
		t.Fatalf("source sentinel changed: data=%q err=%v", data, err)
	}
	if _, err := os.Stat(root); err != nil {
		t.Fatalf("shared root removed after failed unmount: %v", err)
	}

	adapter.cleanup = sharedRootCleanupOps{
		mountTargets: func(string) ([]string, error) { return nil, nil },
		unmount:      func(string, int) error { t.Fatal("unmount called without mounts"); return nil },
		removeAll:    os.RemoveAll,
	}
	if err := adapter.Release(ctx, release, prepared.GetNetwork().GetNetworkHandle()); err != nil {
		t.Fatalf("Release retry: %v", err)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("shared root remains after safe retry: %v", err)
	}
	if data, err := os.ReadFile(sentinel); err != nil || string(data) != "volume-data" {
		t.Fatalf("source sentinel changed after retry: data=%q err=%v", data, err)
	}
}

func TestAdapterReleaseContinuesAfterRootRemovedBeforeNetworkFailure(t *testing.T) {
	ctx := context.Background()
	network := &fakeNetwork{releaseErr: errors.New("injected network release failure")}
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "resources"), testAssets(t), network)
	if err != nil {
		t.Fatal(err)
	}
	lease := state.Lease{Generation: 3, LeaseID: "lease-a"}
	prepared, err := adapter.Prepare(ctx, adapterRequest(), lease)
	if err != nil {
		t.Fatal(err)
	}
	release := state.ReleaseRequest{SandboxID: "sandbox-a", Generation: 3, LeaseID: "lease-a"}
	if err := adapter.Release(ctx, release, prepared.GetNetwork().GetNetworkHandle()); err == nil {
		t.Fatal("Release succeeded despite network failure")
	}
	if _, err := os.Stat(prepared.GetAssets().GetSharedRoot()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("shared root was not removed before network failure: %v", err)
	}
	if _, err := adapter.load("sandbox-a"); err != nil {
		t.Fatalf("adapter record not retained: %v", err)
	}

	network.releaseErr = nil
	if err := adapter.Release(ctx, release, prepared.GetNetwork().GetNetworkHandle()); err != nil {
		t.Fatalf("Release retry after missing shared root: %v", err)
	}
	if network.releaseCalls != 2 {
		t.Fatalf("network release calls=%d, want 2", network.releaseCalls)
	}
	if _, err := adapter.load("sandbox-a"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("adapter record remains after retry: %v", err)
	}
}

func TestAdapterPrepareRejectsPreexistingSharedRootSymlink(t *testing.T) {
	ctx := context.Background()
	network := new(fakeNetwork)
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "resources"), testAssets(t), network)
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(adapter.assets.SharedRootBase, nameFor("sb-", "sandbox-a", 3))
	outside := t.TempDir()
	if err := os.Symlink(outside, root); err != nil {
		t.Fatal(err)
	}
	lease := state.Lease{Generation: 3, LeaseID: "lease-a"}
	if _, err := adapter.Prepare(ctx, adapterRequest(), lease); err == nil || !strings.Contains(err.Error(), "not a real directory") {
		t.Fatalf("Prepare error=%v, want real-directory rejection", err)
	}
	if network.prepareCalls != 0 {
		t.Fatalf("network prepared after shared-root validation failure: %d", network.prepareCalls)
	}
	if _, err := adapter.load("sandbox-a"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed INTENT record was retained: %v", err)
	}
	if target, err := filepath.EvalSymlinks(root); err != nil || target != outside {
		t.Fatalf("preexisting symlink was changed: target=%q err=%v", target, err)
	}
}

func TestAdapterInspectRejectsSharedRootSymlinkReplacement(t *testing.T) {
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
	outside := t.TempDir()
	if err := os.Remove(root); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, root); err != nil {
		t.Fatal(err)
	}
	if _, err := adapter.Inspect(ctx, "sandbox-a", lease); err == nil || !strings.Contains(err.Error(), "not a real directory") {
		t.Fatalf("Inspect error=%v, want symlink replacement rejection", err)
	}
	if err := os.Remove(root); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(root, 0o711); err != nil {
		t.Fatal(err)
	}
	if err := adapter.Release(ctx, state.ReleaseRequest{SandboxID: "sandbox-a", Generation: 3, LeaseID: "lease-a"}, prepared.GetNetwork().GetNetworkHandle()); err != nil {
		t.Fatal(err)
	}
}

func TestSharedRootCleanupUnmountsDeepestFirstAndFallsBackToDetach(t *testing.T) {
	root := t.TempDir()
	outer := filepath.Join(root, "volumes", "task")
	inner := filepath.Join(outer, "nested")
	for _, path := range []string{outer, inner} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	adapter := &adapter{assets: Assets{SharedRootBase: filepath.Dir(root)}}
	remaining := []string{outer, inner, inner}
	var calls []string
	adapter.cleanup = sharedRootCleanupOps{
		mountTargets: func(string) ([]string, error) { return append([]string(nil), remaining...), nil },
		unmount: func(target string, flags int) error {
			calls = append(calls, fmt.Sprintf("%s:%d", target, flags))
			if flags == 0 {
				return unix.EBUSY
			}
			for index := 0; index < len(remaining); {
				if remaining[index] == target {
					remaining = append(remaining[:index], remaining[index+1:]...)
				} else {
					index++
				}
			}
			return nil
		},
		removeAll: os.RemoveAll,
	}
	if err := adapter.cleanupSharedRoot(root); err != nil {
		t.Fatal(err)
	}
	want := []string{
		fmt.Sprintf("%s:0", inner), fmt.Sprintf("%s:%d", inner, unix.MNT_DETACH),
		fmt.Sprintf("%s:0", outer), fmt.Sprintf("%s:%d", outer, unix.MNT_DETACH),
	}
	if !slices.Equal(calls, want) {
		t.Fatalf("unmount calls=%v, want %v", calls, want)
	}
}

func (n *fakeNetwork) Open(string, string) (*os.File, error) {
	n.openCalls++
	return os.Open("/dev/null")
}

func testAssets(t *testing.T) Assets {
	t.Helper()
	root := t.TempDir()
	paths := make([]string, 3)
	for index, name := range []string{"kernel", "agent", "guest"} {
		paths[index] = filepath.Join(root, name)
		if err := os.WriteFile(paths[index], []byte(name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return Assets{
		KernelPath: paths[0], AgentPath: paths[1], GuestImagePath: paths[2],
		SharedRootBase: filepath.Join(root, "shared"),
	}
}

func adapterRequest() *runtimev1.PrepareSandboxRequest {
	return &runtimev1.PrepareSandboxRequest{
		SandboxId: "sandbox-a", Generation: 3,
		Network: &runtimev1.NetworkIntent{NetnsPath: "/run/netns/pod-a", InterfaceName: "eth0"},
	}
}

func TestAdapterLifecycleIsPersistentAndExactLeaseScoped(t *testing.T) {
	ctx := context.Background()
	network := new(fakeNetwork)
	stateDir := filepath.Join(t.TempDir(), "resources")
	assets := testAssets(t)
	adapter, err := newAdapter(stateDir, assets, network)
	if err != nil {
		t.Fatal(err)
	}
	lease := state.Lease{Generation: 3, LeaseID: "lease-a"}
	prepared, err := adapter.Prepare(ctx, adapterRequest(), lease)
	if err != nil {
		t.Fatal(err)
	}
	if network.prepareCalls != 1 || prepared.GetNetwork().GetNetworkHandle() == "" {
		t.Fatalf("prepare calls=%d prepared=%+v", network.prepareCalls, prepared)
	}
	if _, err := os.Stat(prepared.GetAssets().GetSharedRoot()); err != nil {
		t.Fatalf("shared root: %v", err)
	}

	retry, err := adapter.Prepare(ctx, adapterRequest(), lease)
	if err != nil {
		t.Fatal(err)
	}
	if network.prepareCalls != 1 || retry.GetNetwork().GetNetworkHandle() != prepared.GetNetwork().GetNetworkHandle() {
		t.Fatalf("retry allocated resources: calls=%d retry=%+v", network.prepareCalls, retry)
	}

	restarted, err := newAdapter(stateDir, assets, network)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := restarted.Inspect(ctx, "sandbox-a", lease); err != nil {
		t.Fatalf("restart inspect: %v", err)
	}
	binding := handoff.Binding{
		SandboxID: "sandbox-a", Generation: 3, LeaseID: "lease-a",
		NetworkHandle: prepared.GetNetwork().GetNetworkHandle(),
	}
	file, err := restarted.OpenTap(binding)
	if err != nil {
		t.Fatal(err)
	}
	firstFD := file.Fd()
	retryFile, err := restarted.OpenTap(binding)
	if err != nil {
		t.Fatal(err)
	}
	if retryFile.Fd() == firstFD || network.openCalls != 1 {
		t.Fatalf("retry fd=%d first=%d open calls=%d", retryFile.Fd(), firstFD, network.openCalls)
	}
	file.Close()
	retryFile.Close()
	binding.LeaseID = "stale"
	if _, err := restarted.OpenTap(binding); !errors.Is(err, handoff.ErrStaleLease) {
		t.Fatalf("stale OpenTap error=%v", err)
	}

	release := state.ReleaseRequest{SandboxID: "sandbox-a", Generation: 3, LeaseID: "lease-a"}
	if err := restarted.Release(ctx, release, prepared.GetNetwork().GetNetworkHandle()); err != nil {
		t.Fatal(err)
	}
	if network.releaseCalls != 1 {
		t.Fatalf("release calls=%d, want 1", network.releaseCalls)
	}
	if _, err := os.Stat(prepared.GetAssets().GetSharedRoot()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("shared root remains after release: %v", err)
	}
	if err := restarted.Release(ctx, release, prepared.GetNetwork().GetNetworkHandle()); err != nil {
		t.Fatalf("release retry: %v", err)
	}
}

func TestAdapterPrepareFailureRollsBackDeterministicNetwork(t *testing.T) {
	network := &fakeNetwork{prepareErr: errors.New("injected network failure")}
	assets := testAssets(t)
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "resources"), assets, network)
	if err != nil {
		t.Fatal(err)
	}
	_, err = adapter.Prepare(context.Background(), adapterRequest(), state.Lease{Generation: 3, LeaseID: "lease-a"})
	if err == nil {
		t.Fatal("Prepare succeeded, want injected failure")
	}
	if network.releaseCalls != 1 {
		t.Fatalf("rollback release calls=%d, want 1", network.releaseCalls)
	}
}
