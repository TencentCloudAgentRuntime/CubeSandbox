// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"context"
	"sync"
	"testing"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func cubeShimServiceRequest(id string, generation uint64) *runtimev1.PrepareSandboxRequest {
	return serviceRequest(id, generation, state.ExpectedPrepareKey(id, generation))
}

func releaseBeforePrepareRequest(request *runtimev1.PrepareSandboxRequest) *runtimev1.ReleaseSandboxRequest {
	identity := state.PrepareRequest{
		SandboxID: request.GetSandboxId(), Generation: request.GetGeneration(),
		IdempotencyKey: request.GetIdempotencyKey(),
	}
	leaseID := state.ExpectedLeaseIDForPrepare(identity)
	return &runtimev1.ReleaseSandboxRequest{
		SandboxId: request.GetSandboxId(), Generation: request.GetGeneration(), LeaseId: leaseID,
		IdempotencyKey: state.ExpectedReleaseKey(request.GetSandboxId(), request.GetGeneration(), leaseID),
	}
}

func TestServiceReleaseBeforePreparePersistsFutureFence(t *testing.T) {
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	adapter := newServiceFakeAdapter()
	service, _ := newTestService(t, store, adapter)
	prepare := cubeShimServiceRequest("sandbox-release-first", 1)
	release := releaseBeforePrepareRequest(prepare)

	if _, err := service.ReleaseSandbox(context.Background(), release); err != nil {
		t.Fatal(err)
	}
	if _, err := service.PrepareSandbox(context.Background(), prepare); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("late Prepare error=%v code=%s", err, status.Code(err))
	}
	record, err := store.Inspect(prepare.GetSandboxId())
	if err != nil || record.Active != nil || record.HighWatermark != prepare.GetGeneration() {
		t.Fatalf("record=%+v err=%v", record, err)
	}
	adapter.mu.Lock()
	defer adapter.mu.Unlock()
	if adapter.prepareCalls != 0 || adapter.releaseCalls != 0 || len(adapter.records) != 0 {
		t.Fatalf("adapter calls prepare=%d release=%d records=%d", adapter.prepareCalls, adapter.releaseCalls, len(adapter.records))
	}
}

func TestServiceConcurrentPrepareReleaseConvergesReleased(t *testing.T) {
	for iteration := 0; iteration < 64; iteration++ {
		store, err := state.Open(t.TempDir(), serviceGenerator())
		if err != nil {
			t.Fatal(err)
		}
		adapter := newServiceFakeAdapter()
		service, _ := newTestService(t, store, adapter)
		prepare := cubeShimServiceRequest("sandbox-service-race", 1)
		release := releaseBeforePrepareRequest(prepare)
		start := make(chan struct{})
		var prepareErr, releaseErr error
		var wait sync.WaitGroup
		wait.Add(2)
		go func() {
			defer wait.Done()
			<-start
			_, prepareErr = service.PrepareSandbox(context.Background(), prepare)
		}()
		go func() {
			defer wait.Done()
			<-start
			_, releaseErr = service.ReleaseSandbox(context.Background(), release)
		}()
		close(start)
		wait.Wait()
		if releaseErr != nil {
			t.Fatalf("iteration %d release: %v", iteration, releaseErr)
		}
		if prepareErr != nil && status.Code(prepareErr) != codes.FailedPrecondition {
			t.Fatalf("iteration %d prepare: %v", iteration, prepareErr)
		}
		record, err := store.Inspect(prepare.GetSandboxId())
		if err != nil || record.Active != nil {
			t.Fatalf("iteration %d record=%+v err=%v", iteration, record, err)
		}
		adapter.mu.Lock()
		recordCount := len(adapter.records)
		adapter.mu.Unlock()
		if recordCount != 0 {
			t.Fatalf("iteration %d adapter retained %d records", iteration, recordCount)
		}
	}
}
