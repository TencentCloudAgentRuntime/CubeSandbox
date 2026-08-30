// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func coordinatorGenerator() state.ValueGenerator {
	next := 0
	return func() (string, error) {
		next++
		return fmt.Sprintf("coordinator-value-%d", next), nil
	}
}

func handoffRequest(binding handoff.Binding) *runtimev1.FDHandoffRequestV1 {
	return &runtimev1.FDHandoffRequestV1{
		ProtocolVersion: handoff.ProtocolVersion,
		SandboxId:       binding.SandboxID,
		Generation:      binding.Generation,
		LeaseId:         binding.LeaseID,
		NetworkHandle:   binding.NetworkHandle,
		Token:           binding.Token,
	}
}

func readyCoordinator(t *testing.T, opener handoff.TapOpener) (*Coordinator, *state.Store, *handoff.Registry, handoff.Binding, state.ReleaseRequest) {
	t.Helper()
	store, err := state.Open(t.TempDir(), coordinatorGenerator())
	if err != nil {
		t.Fatal(err)
	}
	registry, err := handoff.NewRegistry(opener)
	if err != nil {
		t.Fatal(err)
	}
	coordinator, err := NewCoordinator(store, registry)
	if err != nil {
		t.Fatal(err)
	}
	prepared, err := coordinator.Prepare(state.PrepareRequest{
		SandboxID:      "sandbox-a",
		Generation:     1,
		IdempotencyKey: "prepare-1",
		PayloadDigest:  "digest-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	lease, err := coordinator.MarkReadyAndPublish("sandbox-a", 1, prepared.Lease.LeaseID, "network-1")
	if err != nil {
		t.Fatal(err)
	}
	binding := bindingFromLease("sandbox-a", lease)
	release := state.ReleaseRequest{
		SandboxID:      "sandbox-a",
		Generation:     1,
		LeaseID:        lease.LeaseID,
		IdempotencyKey: "release-1",
	}
	return coordinator, store, registry, binding, release
}

func TestCoordinatorReleaseLinearizesWithInFlightFDDuplicate(t *testing.T) {
	opened := make(chan struct{})
	allowDuplicate := make(chan struct{})
	coordinator, store, registry, binding, release := readyCoordinator(t, func(handoff.Binding) (*os.File, error) {
		close(opened)
		<-allowDuplicate
		return os.Open("/dev/null")
	})

	type acquireResult struct {
		file *os.File
		code runtimev1.FDHandoffCode
		err  error
	}
	acquired := make(chan acquireResult, 1)
	go func() {
		file, code, err := registry.Acquire(handoffRequest(binding))
		acquired <- acquireResult{file: file, code: code, err: err}
	}()
	<-opened

	released := make(chan error, 1)
	go func() {
		_, err := coordinator.BeginReleaseAndFence(release)
		released <- err
	}()
	select {
	case err := <-released:
		t.Fatalf("release passed an in-flight FD duplicate: %v", err)
	case <-time.After(20 * time.Millisecond):
	}

	close(allowDuplicate)
	result := <-acquired
	if result.err != nil || result.code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK || result.file == nil {
		t.Fatalf("in-flight acquire=(%v,%s,%v), want one OK FD", result.file, result.code, result.err)
	}
	result.file.Close()
	if err := <-released; err != nil {
		t.Fatal(err)
	}

	file, code, err := registry.Acquire(handoffRequest(binding))
	if file != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_STALE || !errors.Is(err, handoff.ErrStaleLease) {
		t.Fatalf("post-release acquire=(%v,%s,%v), want STALE and zero FD", file, code, err)
	}
	record, err := store.Inspect("sandbox-a")
	if err != nil {
		t.Fatal(err)
	}
	if record.Active == nil || record.Active.Phase != state.PhaseReleasing {
		t.Fatalf("durable state=%+v, want RELEASING", record.Active)
	}
}

type failingReleaseStore struct {
	LifecycleStore
}

func (f failingReleaseStore) BeginRelease(state.ReleaseRequest) (*state.ReleaseResult, error) {
	return nil, status.Error(codes.Unavailable, "injected durable persist failure")
}

func TestCoordinatorPersistFailureRetainsBindingAndReadyRecovery(t *testing.T) {
	opener := func(handoff.Binding) (*os.File, error) { return os.Open("/dev/null") }
	_, store, registry, binding, release := readyCoordinator(t, opener)
	failing, err := NewCoordinator(failingReleaseStore{LifecycleStore: store}, registry)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := failing.BeginReleaseAndFence(release); status.Code(err) != codes.Unavailable {
		t.Fatalf("release error=%v code=%s, want Unavailable", err, status.Code(err))
	}

	file, code, err := registry.Acquire(handoffRequest(binding))
	if err != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK || file == nil {
		t.Fatalf("binding after persist failure=(%v,%s,%v), want READY FD", file, code, err)
	}
	file.Close()
	record, err := store.Inspect("sandbox-a")
	if err != nil {
		t.Fatal(err)
	}
	if record.Active == nil || record.Active.Phase != state.PhaseReady {
		t.Fatalf("state after persist failure=%+v, want READY", record.Active)
	}

	restartedRegistry, err := handoff.NewRegistry(opener)
	if err != nil {
		t.Fatal(err)
	}
	restarted, err := NewCoordinator(store, restartedRegistry)
	if err != nil {
		t.Fatal(err)
	}
	if err := restarted.RecoverSandbox("sandbox-a"); err != nil {
		t.Fatal(err)
	}
	file, code, err = restartedRegistry.Acquire(handoffRequest(binding))
	if err != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK || file == nil {
		t.Fatalf("READY recovery=(%v,%s,%v), want published FD", file, code, err)
	}
	file.Close()
}

func TestCoordinatorRestartKeepsReleasingFencedAndReplacementStale(t *testing.T) {
	opener := func(handoff.Binding) (*os.File, error) { return os.Open("/dev/null") }
	coordinator, store, _, oldBinding, release := readyCoordinator(t, opener)
	if _, err := coordinator.BeginReleaseAndFence(release); err != nil {
		t.Fatal(err)
	}

	restartedRegistry, err := handoff.NewRegistry(opener)
	if err != nil {
		t.Fatal(err)
	}
	restarted, err := NewCoordinator(store, restartedRegistry)
	if err != nil {
		t.Fatal(err)
	}
	if err := restarted.RecoverSandbox("sandbox-a"); err != nil {
		t.Fatal(err)
	}
	file, code, err := restartedRegistry.Acquire(handoffRequest(oldBinding))
	if file != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_STALE || !errors.Is(err, handoff.ErrStaleLease) {
		t.Fatalf("RELEASING recovery acquire=(%v,%s,%v), want STALE and zero FD", file, code, err)
	}
	retry, err := restarted.BeginReleaseAndFence(release)
	if err != nil || !retry.Reused {
		t.Fatalf("release retry=(%+v,%v), want reused", retry, err)
	}
	if err := restarted.CompleteRelease(release); err != nil {
		t.Fatal(err)
	}

	prepared2, err := restarted.Prepare(state.PrepareRequest{
		SandboxID:      "sandbox-a",
		Generation:     2,
		IdempotencyKey: "prepare-2",
		PayloadDigest:  "digest-2",
	})
	if err != nil {
		t.Fatal(err)
	}
	lease2, err := restarted.MarkReadyAndPublish("sandbox-a", 2, prepared2.Lease.LeaseID, "network-2")
	if err != nil {
		t.Fatal(err)
	}
	newBinding := bindingFromLease("sandbox-a", lease2)
	file, code, err = restartedRegistry.Acquire(handoffRequest(oldBinding))
	if file != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_STALE || !errors.Is(err, handoff.ErrStaleLease) {
		t.Fatalf("replaced old acquire=(%v,%s,%v), want STALE and zero FD", file, code, err)
	}
	file, code, err = restartedRegistry.Acquire(handoffRequest(newBinding))
	if err != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK || file == nil {
		t.Fatalf("replacement acquire=(%v,%s,%v), want new READY FD", file, code, err)
	}
	file.Close()
}
