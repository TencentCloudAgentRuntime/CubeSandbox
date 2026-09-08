// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"context"
	"errors"
	"strings"
	"testing"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/internal/monotime"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
)

type failAfterReadyStore struct {
	LifecycleStore
	failed bool
}

func (s *failAfterReadyStore) MarkReady(sandboxID string, generation uint64, leaseID, networkHandle string, trace *monotime.TraceBuffer) (*state.Lease, error) {
	lease, err := s.LifecycleStore.MarkReady(sandboxID, generation, leaseID, networkHandle, trace)
	if err == nil && !s.failed {
		s.failed = true
		return nil, errors.New("injected error after READY became durable")
	}
	return lease, err
}

func assertReleasedAndExactlyRetryable(t *testing.T, service *Service, store *state.Store, sandboxID string, generation uint64) {
	t.Helper()
	record, err := store.Inspect(sandboxID)
	if err != nil || record.Active != nil || len(record.Tombstones) != 1 {
		t.Fatalf("released record=%+v err=%v", record, err)
	}
	var leaseID string
	for _, tombstone := range record.Tombstones {
		leaseID = tombstone.LeaseID
	}
	_, err = service.ReleaseSandbox(context.Background(), &runtimev1.ReleaseSandboxRequest{
		SandboxId: sandboxID, Generation: generation, LeaseId: leaseID,
		IdempotencyKey: releaseKey(sandboxID, generation, leaseID),
	})
	if err != nil {
		t.Fatalf("exact delayed release retry: %v", err)
	}
}

func TestPrepareCancellationUsesIndependentCleanupContext(t *testing.T) {
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	adapter := &controlledServiceAdapter{
		base: newServiceFakeAdapter(), prepareErr: context.Canceled, cancelPrepare: cancel,
	}
	service, _ := newTestService(t, store, adapter)
	_, err = service.PrepareSandbox(ctx, serviceRequest("sandbox-canceled", 1, "prepare-canceled"))
	if err == nil || !strings.Contains(err.Error(), "context canceled") {
		t.Fatalf("prepare error=%v", err)
	}
	if adapter.releaseContextErr != nil {
		t.Fatalf("rollback inherited canceled RPC context: %v", adapter.releaseContextErr)
	}
	assertReleasedAndExactlyRetryable(t, service, store, "sandbox-canceled", 1)
}

func TestPrepareReadyCommitUnknownIsRereadAndReleased(t *testing.T) {
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	adapter := newServiceFakeAdapter()
	service, _, err := NewService(&failAfterReadyStore{LifecycleStore: store}, adapter, "/run/cube/runtime-fd.sock")
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.PrepareSandbox(context.Background(), serviceRequest("sandbox-ready-unknown", 1, "prepare-ready-unknown"))
	if err == nil || !strings.Contains(err.Error(), "injected error after READY became durable") {
		t.Fatalf("prepare error=%v", err)
	}
	assertReleasedAndExactlyRetryable(t, service, store, "sandbox-ready-unknown", 1)
}

func TestPreparePublishConflictIsRereadAndReleased(t *testing.T) {
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	service, registry := newTestService(t, store, newServiceFakeAdapter())
	if err := registry.Publish(handoff.Binding{
		SandboxID: "sandbox-publish-conflict", Generation: 99, LeaseID: "stale-lease",
		NetworkHandle: "stale-network", Token: "stale-token", Ready: true,
	}); err != nil {
		t.Fatal(err)
	}
	_, err = service.PrepareSandbox(context.Background(), serviceRequest("sandbox-publish-conflict", 1, "prepare-publish-conflict"))
	if err == nil || !strings.Contains(err.Error(), "conflicting published lease") {
		t.Fatalf("prepare error=%v", err)
	}
	assertReleasedAndExactlyRetryable(t, service, store, "sandbox-publish-conflict", 1)
}
