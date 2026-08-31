// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
)

type controlledServiceAdapter struct {
	base              *serviceFakeAdapter
	invalidPrepared   bool
	prepareErr        error
	cancelPrepare     context.CancelFunc
	releaseErr        error
	releaseContextErr error
	releaseStarted    chan struct{}
	releaseContinue   chan struct{}
	startedOnce       sync.Once
}

func (a *controlledServiceAdapter) Prepare(ctx context.Context, request *runtimev1.PrepareSandboxRequest, lease state.Lease) (*runtimev1.PreparedSandbox, error) {
	prepared, err := a.base.Prepare(ctx, request, lease)
	if a.cancelPrepare != nil {
		a.cancelPrepare()
	}
	if err == nil && a.prepareErr != nil {
		return nil, a.prepareErr
	}
	if err == nil && a.invalidPrepared {
		prepared.Network.Ips = nil
	}
	return prepared, err
}

func (a *controlledServiceAdapter) Release(ctx context.Context, request state.ReleaseRequest, networkHandle string) error {
	a.releaseContextErr = ctx.Err()
	if a.releaseStarted != nil {
		a.startedOnce.Do(func() { close(a.releaseStarted) })
		<-a.releaseContinue
	}
	if a.releaseErr != nil {
		return a.releaseErr
	}
	return a.base.Release(ctx, request, networkHandle)
}

func (a *controlledServiceAdapter) Inspect(ctx context.Context, sandboxID string, lease state.Lease) (*runtimev1.PreparedSandbox, error) {
	return a.base.Inspect(ctx, sandboxID, lease)
}

func (a *controlledServiceAdapter) OpenTap(binding handoff.Binding) (*os.File, error) {
	return a.base.OpenTap(binding)
}

func TestValidatePreparedRollbackFailurePreservesReleasingLease(t *testing.T) {
	ctx := context.Background()
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	adapter := &controlledServiceAdapter{
		base: newServiceFakeAdapter(), invalidPrepared: true,
		releaseErr: errors.New("injected cleanup failure"),
	}
	service, _ := newTestService(t, store, adapter)
	_, err = service.PrepareSandbox(ctx, serviceRequest("sandbox-rollback", 1, "prepare-rollback"))
	if err == nil || !strings.Contains(err.Error(), "rollback:") || !strings.Contains(err.Error(), "injected cleanup failure") {
		t.Fatalf("prepare error=%v", err)
	}
	record, err := store.Inspect("sandbox-rollback")
	if err != nil || record.Active == nil || record.Active.Phase != state.PhaseReleasing {
		t.Fatalf("record=%+v err=%v", record, err)
	}

	adapter.releaseErr = nil
	if err := service.Recover(ctx); err != nil {
		t.Fatal(err)
	}
	record, err = store.Inspect("sandbox-rollback")
	if err != nil || record.Active != nil {
		t.Fatalf("recovered record=%+v err=%v", record, err)
	}
}

func TestConcurrentIdenticalReleaseSerializesCleanupAndRetry(t *testing.T) {
	ctx := context.Background()
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	adapter := &controlledServiceAdapter{
		base: newServiceFakeAdapter(), releaseStarted: make(chan struct{}),
		releaseContinue: make(chan struct{}),
	}
	service, _ := newTestService(t, store, adapter)
	response, err := service.PrepareSandbox(ctx, serviceRequest("sandbox-concurrent-release", 1, "prepare-concurrent-release"))
	if err != nil {
		t.Fatal(err)
	}
	prepared := response.GetSandbox()
	release := &runtimev1.ReleaseSandboxRequest{
		SandboxId: prepared.GetSandboxId(), Generation: prepared.GetGeneration(),
		LeaseId: prepared.GetLeaseId(), IdempotencyKey: "release-concurrent",
	}
	errs := make(chan error, 2)
	go func() { _, err := service.ReleaseSandbox(ctx, release); errs <- err }()
	<-adapter.releaseStarted
	go func() { _, err := service.ReleaseSandbox(ctx, release); errs <- err }()
	close(adapter.releaseContinue)
	for range 2 {
		if err := <-errs; err != nil {
			t.Fatalf("concurrent release: %v", err)
		}
	}
	adapter.base.mu.Lock()
	releaseCalls := adapter.base.releaseCalls
	adapter.base.mu.Unlock()
	if releaseCalls != 1 {
		t.Fatalf("adapter release calls=%d, want 1", releaseCalls)
	}
}
