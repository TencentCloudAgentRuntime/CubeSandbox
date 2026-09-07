// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	runtimeservice "github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"golang.org/x/sys/unix"
)

type blockingPrepareNetwork struct {
	entered chan string
	proceed <-chan struct{}
}

func (n *blockingPrepareNetwork) Prepare(_ context.Context, netnsPath, _, _ string) (*runtimev1.NetworkAttachment, error) {
	n.entered <- netnsPath
	<-n.proceed
	return &runtimev1.NetworkAttachment{
		GuestInterfaceName: "eth0", Mac: "02:00:00:00:00:01", Mtu: 1450,
		Ips: []string{"10.0.0.2/24"},
	}, nil
}

func (*blockingPrepareNetwork) Release(context.Context, string, string, string) error { return nil }

func (*blockingPrepareNetwork) Open(string, string) (*os.File, error) { return os.Open("/dev/null") }

func adapterRequestFor(sandboxID string) *runtimev1.PrepareSandboxRequest {
	return &runtimev1.PrepareSandboxRequest{
		SandboxId: sandboxID, Generation: 1,
		Network: &runtimev1.NetworkIntent{NetnsPath: "/run/netns/" + sandboxID, InterfaceName: "eth0"},
	}
}

func TestAdapterDifferentSandboxesPrepareConcurrently(t *testing.T) {
	proceed := make(chan struct{})
	network := &blockingPrepareNetwork{entered: make(chan string, 2), proceed: proceed}
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "resources"), testAssets(t), network)
	if err != nil {
		t.Fatal(err)
	}

	results := make(chan error, 2)
	for _, sandboxID := range []string{"sandbox-a", "sandbox-b"} {
		sandboxID := sandboxID
		go func() {
			_, err := adapter.Prepare(context.Background(), adapterRequestFor(sandboxID), state.Lease{Generation: 1, LeaseID: "lease-" + sandboxID})
			results <- err
		}()
	}

	seen := make(map[string]bool)
	for range 2 {
		select {
		case netns := <-network.entered:
			seen[netns] = true
		case <-time.After(time.Second):
			close(proceed)
			t.Fatal("different sandbox Prepare calls did not overlap")
		}
	}
	close(proceed)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	if !seen["/run/netns/sandbox-a"] || !seen["/run/netns/sandbox-b"] {
		t.Fatalf("network entries=%v", seen)
	}
}

func TestAdapterSameSandboxInspectWaitsForPrepare(t *testing.T) {
	proceed := make(chan struct{})
	network := &blockingPrepareNetwork{entered: make(chan string, 1), proceed: proceed}
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "resources"), testAssets(t), network)
	if err != nil {
		t.Fatal(err)
	}
	lease := state.Lease{Generation: 1, LeaseID: "lease-a"}
	prepared := make(chan error, 1)
	go func() {
		_, err := adapter.Prepare(context.Background(), adapterRequestFor("sandbox-a"), lease)
		prepared <- err
	}()
	<-network.entered

	inspected := make(chan error, 1)
	go func() {
		_, err := adapter.Inspect(context.Background(), "sandbox-a", lease)
		inspected <- err
	}()
	select {
	case err := <-inspected:
		t.Fatalf("same-sandbox Inspect passed in-flight Prepare: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	close(proceed)
	if err := <-prepared; err != nil {
		t.Fatal(err)
	}
	if err := <-inspected; err != nil {
		t.Fatal(err)
	}
}

type parallelNetwork struct {
	releaseEntered chan string
	releaseProceed <-chan struct{}
}

func (*parallelNetwork) Prepare(context.Context, string, string, string) (*runtimev1.NetworkAttachment, error) {
	return &runtimev1.NetworkAttachment{
		GuestInterfaceName: "eth0", Mac: "02:00:00:00:00:01", Mtu: 1450,
		Ips: []string{"10.0.0.2/24"},
	}, nil
}

func (n *parallelNetwork) Release(_ context.Context, netnsPath, _, _ string) error {
	if n.releaseEntered != nil {
		n.releaseEntered <- netnsPath
		<-n.releaseProceed
	}
	return nil
}

func (*parallelNetwork) Open(string, string) (*os.File, error) { return os.Open("/dev/null") }

func prepareRawSandbox(t *testing.T, adapter *adapter, sandboxID string) (*runtimev1.PreparedSandbox, state.Lease) {
	t.Helper()
	lease := state.Lease{Generation: 1, LeaseID: "lease-" + sandboxID}
	prepared, err := adapter.Prepare(context.Background(), adapterRequestFor(sandboxID), lease)
	if err != nil {
		t.Fatal(err)
	}
	return prepared, lease
}

func bindingFor(prepared *runtimev1.PreparedSandbox) handoff.Binding {
	return handoff.Binding{
		SandboxID: prepared.GetSandboxId(), Generation: prepared.GetGeneration(), LeaseID: prepared.GetLeaseId(),
		NetworkHandle: prepared.GetNetwork().GetNetworkHandle(), Ready: true,
	}
}

func TestAdapterDifferentSandboxOpenTapDuplicatesConcurrently(t *testing.T) {
	network := new(parallelNetwork)
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "resources"), testAssets(t), network)
	if err != nil {
		t.Fatal(err)
	}
	preparedA, _ := prepareRawSandbox(t, adapter, "sandbox-a")
	preparedB, _ := prepareRawSandbox(t, adapter, "sandbox-b")

	originalDuplicate := duplicateTapFD
	entered := make(chan struct{}, 2)
	proceed := make(chan struct{})
	duplicateTapFD = func(fd uintptr) (int, error) {
		entered <- struct{}{}
		<-proceed
		return unix.FcntlInt(fd, unix.F_DUPFD_CLOEXEC, 0)
	}
	defer func() { duplicateTapFD = originalDuplicate }()

	results := make(chan error, 2)
	for _, binding := range []handoff.Binding{bindingFor(preparedA), bindingFor(preparedB)} {
		binding := binding
		go func() {
			file, err := adapter.OpenTap(binding)
			if file != nil {
				file.Close()
			}
			results <- err
		}()
	}
	for range 2 {
		select {
		case <-entered:
		case <-time.After(time.Second):
			close(proceed)
			t.Fatal("different sandbox TAP descriptor duplicates did not overlap")
		}
	}
	close(proceed)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
}

func TestAdapterDifferentSandboxReleasesConcurrently(t *testing.T) {
	proceed := make(chan struct{})
	network := &parallelNetwork{releaseEntered: make(chan string, 2), releaseProceed: proceed}
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "resources"), testAssets(t), network)
	if err != nil {
		t.Fatal(err)
	}
	preparedA, leaseA := prepareRawSandbox(t, adapter, "sandbox-a")
	preparedB, leaseB := prepareRawSandbox(t, adapter, "sandbox-b")

	results := make(chan error, 2)
	for _, item := range []struct {
		prepared *runtimev1.PreparedSandbox
		lease    state.Lease
	}{{preparedA, leaseA}, {preparedB, leaseB}} {
		item := item
		go func() {
			results <- adapter.Release(context.Background(), state.ReleaseRequest{
				SandboxID: item.prepared.GetSandboxId(), Generation: item.lease.Generation, LeaseID: item.lease.LeaseID,
			}, item.prepared.GetNetwork().GetNetworkHandle())
		}()
	}
	for range 2 {
		select {
		case <-network.releaseEntered:
		case <-time.After(time.Second):
			close(proceed)
			t.Fatal("different sandbox Release calls did not overlap")
		}
	}
	close(proceed)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
}

func TestAdapterCloseFailureKeepsTapOwnedForReleaseRetry(t *testing.T) {
	network := new(fakeNetwork)
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "resources"), testAssets(t), network)
	if err != nil {
		t.Fatal(err)
	}
	prepared, lease := prepareRawSandbox(t, adapter, "sandbox-a")
	file, err := adapter.OpenTap(bindingFor(prepared))
	if err != nil {
		t.Fatal(err)
	}
	file.Close()
	original := adapter.getTap("sandbox-a")
	closeCalls := 0
	adapter.closeTap = func(file *os.File) error {
		closeCalls++
		if closeCalls == 1 {
			return errors.New("injected close failure")
		}
		return file.Close()
	}
	release := state.ReleaseRequest{SandboxID: "sandbox-a", Generation: lease.Generation, LeaseID: lease.LeaseID}
	if err := adapter.Release(context.Background(), release, prepared.GetNetwork().GetNetworkHandle()); err == nil {
		t.Fatal("Release succeeded despite injected TAP close failure")
	}
	if adapter.getTap("sandbox-a") != original {
		t.Fatal("TAP ownership was dropped after close failure")
	}
	if err := adapter.Release(context.Background(), release, prepared.GetNetwork().GetNetworkHandle()); err != nil {
		t.Fatalf("Release retry: %v", err)
	}
	if adapter.getTap("sandbox-a") != nil || closeCalls != 2 {
		t.Fatalf("TAP retry state file=%v close_calls=%d", adapter.getTap("sandbox-a"), closeCalls)
	}
}

func TestRuntimeReleaseWaitsForRealAdapterTapDuplicate(t *testing.T) {
	network := new(fakeNetwork)
	adapter, err := newAdapter(filepath.Join(t.TempDir(), "adapter"), testAssets(t), network)
	if err != nil {
		t.Fatal(err)
	}
	store, err := state.Open(filepath.Join(t.TempDir(), "state"), func() (string, error) { return "token-a", nil })
	if err != nil {
		t.Fatal(err)
	}
	service, registry, err := runtimeservice.NewService(store, adapter, "/run/cube/runtime-fd.sock")
	if err != nil {
		t.Fatal(err)
	}
	request := &runtimev1.PrepareSandboxRequest{
		SandboxId: "sandbox-a", Generation: 1, IdempotencyKey: "prepare-a",
		Pod:       &runtimev1.PodIdentity{Uid: "pod-a", Namespace: "default", Name: "pod-a"},
		Resources: &runtimev1.ResourceRequest{VcpuCount: 1, MemoryBytes: 512 << 20},
		Network:   &runtimev1.NetworkIntent{NetnsPath: "/run/netns/sandbox-a", InterfaceName: "eth0"},
	}
	response, err := service.PrepareSandbox(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	prepared := response.GetSandbox()
	descriptor := prepared.GetNetwork().GetFdHandoff()
	binding := handoff.Binding{
		SandboxID: prepared.GetSandboxId(), Generation: prepared.GetGeneration(), LeaseID: prepared.GetLeaseId(),
		NetworkHandle: prepared.GetNetwork().GetNetworkHandle(), Token: descriptor.GetToken(), Ready: true,
	}

	originalDuplicate := duplicateTapFD
	duplicateEntered := make(chan struct{})
	duplicateProceed := make(chan struct{})
	duplicateTapFD = func(fd uintptr) (int, error) {
		close(duplicateEntered)
		<-duplicateProceed
		return unix.FcntlInt(fd, unix.F_DUPFD_CLOEXEC, 0)
	}
	defer func() { duplicateTapFD = originalDuplicate }()

	type acquireResult struct {
		file *os.File
		err  error
	}
	acquired := make(chan acquireResult, 1)
	go func() {
		file, _, err := registry.Acquire(&runtimev1.FDHandoffRequestV1{
			ProtocolVersion: handoff.ProtocolVersion, SandboxId: binding.SandboxID,
			Generation: binding.Generation, LeaseId: binding.LeaseID,
			NetworkHandle: binding.NetworkHandle, Token: binding.Token,
		})
		acquired <- acquireResult{file: file, err: err}
	}()
	<-duplicateEntered

	released := make(chan error, 1)
	go func() {
		_, err := service.ReleaseSandbox(context.Background(), &runtimev1.ReleaseSandboxRequest{
			SandboxId: binding.SandboxID, Generation: binding.Generation, LeaseId: binding.LeaseID,
			IdempotencyKey: "release-a",
		})
		released <- err
	}()
	select {
	case err := <-released:
		t.Fatalf("Release passed an in-flight real adapter duplicate: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	if network.releaseCalls != 0 {
		t.Fatalf("network released during TAP duplicate: calls=%d", network.releaseCalls)
	}
	close(duplicateProceed)
	result := <-acquired
	if result.err != nil || result.file == nil {
		t.Fatalf("Acquire file=%v err=%v", result.file, result.err)
	}
	result.file.Close()
	if err := <-released; err != nil {
		t.Fatal(err)
	}
	if network.releaseCalls != 1 || adapter.getTap("sandbox-a") != nil {
		t.Fatalf("release_calls=%d tap=%v", network.releaseCalls, adapter.getTap("sandbox-a"))
	}
}
