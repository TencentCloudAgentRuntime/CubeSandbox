// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package state

import (
	"sync"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func cubeShimPrepareRequest(sandboxID string, generation uint64) PrepareRequest {
	return PrepareRequest{
		SandboxID: sandboxID, Generation: generation,
		IdempotencyKey: ExpectedPrepareKey(sandboxID, generation),
		PayloadDigest:  "digest",
	}
}

func exactFutureRelease(request PrepareRequest) ReleaseRequest {
	leaseID := ExpectedLeaseIDForPrepare(request)
	return ReleaseRequest{
		SandboxID: request.SandboxID, Generation: request.Generation, LeaseID: leaseID,
		IdempotencyKey: ExpectedReleaseKey(request.SandboxID, request.Generation, leaseID),
	}
}

func TestExactFutureReleasePersistsFenceBeforePrepare(t *testing.T) {
	dir := t.TempDir()
	store := openTestStore(t, dir, deterministicGenerator())
	prepare := cubeShimPrepareRequest("sandbox-future", 5)
	release := exactFutureRelease(prepare)

	result, err := store.BeginRelease(release)
	if err != nil {
		t.Fatal(err)
	}
	if result.Reused || result.Lease.LeaseID != release.LeaseID || result.Lease.Phase != PhaseReleasing {
		t.Fatalf("future release=%+v", result)
	}
	if _, err := store.Prepare(prepare); err == nil {
		t.Fatal("Prepare resurrected an exactly fenced future generation")
	} else {
		requireCode(t, err, codes.FailedPrecondition)
	}

	restarted := openTestStore(t, dir, deterministicGenerator())
	retry, err := restarted.BeginRelease(release)
	if err != nil || !retry.Reused {
		t.Fatalf("future release retry=%+v err=%v", retry, err)
	}
	record, err := restarted.Inspect(prepare.SandboxID)
	if err != nil || record.Active != nil || record.HighWatermark != prepare.Generation {
		t.Fatalf("record=%+v err=%v", record, err)
	}
	tombstone := record.Tombstones[generationKey(prepare.Generation)]
	if tombstone.LeaseID != release.LeaseID || tombstone.ReleaseKey != release.IdempotencyKey {
		t.Fatalf("tombstone=%+v", tombstone)
	}
}

func TestFutureReleaseRejectsLeaseNotDerivedFromCubeShimPrepare(t *testing.T) {
	store := openTestStore(t, t.TempDir(), deterministicGenerator())
	release := ReleaseRequest{
		SandboxID: "sandbox-forged", Generation: 7, LeaseID: "not-the-expected-lease",
	}
	release.IdempotencyKey = ExpectedReleaseKey(release.SandboxID, release.Generation, release.LeaseID)
	_, err := store.BeginRelease(release)
	requireCode(t, err, codes.NotFound)
	if _, err := store.Inspect(release.SandboxID); err == nil {
		t.Fatal("rejected future release unexpectedly created durable state")
	} else {
		requireCode(t, err, codes.NotFound)
	}
}

func TestConcurrentPrepareAndExactReleaseNeverLeavesLiveLease(t *testing.T) {
	for iteration := 0; iteration < 64; iteration++ {
		store := openTestStore(t, t.TempDir(), deterministicGenerator())
		prepare := cubeShimPrepareRequest("sandbox-race", 1)
		release := exactFutureRelease(prepare)
		start := make(chan struct{})
		var prepareErr, releaseErr error
		var wait sync.WaitGroup
		wait.Add(2)
		go func() {
			defer wait.Done()
			<-start
			_, prepareErr = store.Prepare(prepare)
		}()
		go func() {
			defer wait.Done()
			<-start
			_, releaseErr = store.BeginRelease(release)
		}()
		close(start)
		wait.Wait()
		if releaseErr != nil {
			t.Fatalf("iteration %d release error: %v", iteration, releaseErr)
		}
		if prepareErr != nil && codes.FailedPrecondition != status.Code(prepareErr) {
			t.Fatalf("iteration %d prepare error: %v", iteration, prepareErr)
		}
		record, err := store.Inspect(prepare.SandboxID)
		if err != nil {
			t.Fatalf("iteration %d inspect: %v", iteration, err)
		}
		if record.Active != nil {
			if record.Active.Phase != PhaseReleasing || record.Active.LeaseID != release.LeaseID {
				t.Fatalf("iteration %d live lease=%+v", iteration, record.Active)
			}
			if err := store.CompleteRelease(release); err != nil {
				t.Fatalf("iteration %d complete release: %v", iteration, err)
			}
		}
		record, err = store.Inspect(prepare.SandboxID)
		if err != nil || record.Active != nil {
			t.Fatalf("iteration %d final record=%+v err=%v", iteration, record, err)
		}
	}
}
