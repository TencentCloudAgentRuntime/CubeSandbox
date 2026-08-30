// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
)

type fakeNetwork struct {
	prepareCalls int
	releaseCalls int
	openCalls    int
	prepareErr   error
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
	return nil
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
	file.Close()
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
