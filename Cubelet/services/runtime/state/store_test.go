// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package state

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func deterministicGenerator() ValueGenerator {
	next := 0
	return func() (string, error) {
		next++
		return fmt.Sprintf("value-%d", next), nil
	}
}

func openTestStore(t *testing.T, dir string, generator ValueGenerator) *Store {
	t.Helper()
	store, err := Open(dir, generator)
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func prepareRequest(generation uint64, key, digest string) PrepareRequest {
	return PrepareRequest{
		SandboxID:      "sandbox-a",
		Generation:     generation,
		IdempotencyKey: key,
		PayloadDigest:  digest,
	}
}

func releaseRequest(generation uint64, lease, key string) ReleaseRequest {
	return ReleaseRequest{
		SandboxID:      "sandbox-a",
		Generation:     generation,
		LeaseID:        lease,
		IdempotencyKey: key,
	}
}

func requireCode(t *testing.T, err error, code codes.Code) {
	t.Helper()
	if status.Code(err) != code {
		t.Fatalf("error=%v code=%s, want %s", err, status.Code(err), code)
	}
}

func TestListSandboxIDsSortsAndRejectsCorruptState(t *testing.T) {
	dir := t.TempDir()
	store := openTestStore(t, dir, deterministicGenerator())
	for _, id := range []string{"sandbox-z", "sandbox-a"} {
		_, err := store.Prepare(PrepareRequest{SandboxID: id, Generation: 1, IdempotencyKey: "prepare-" + id, PayloadDigest: "digest-" + id})
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "ignored.txt"), []byte("ignored"), 0o600); err != nil {
		t.Fatal(err)
	}
	ids, err := store.ListSandboxIDs()
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"sandbox-a", "sandbox-z"}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("ids=%v want=%v", ids, want)
	}
	if err := os.WriteFile(filepath.Join(dir, "corrupt.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ListSandboxIDs(); status.Code(err) != codes.Unavailable {
		t.Fatalf("corrupt state error=%v code=%s", err, status.Code(err))
	}
}

func TestPrepareIdempotencyAndGenerationRules(t *testing.T) {
	store := openTestStore(t, t.TempDir(), deterministicGenerator())
	request := prepareRequest(1, "prepare-1", "digest-1")
	first, err := store.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if first.Reused || first.Lease.LeaseID != ExpectedLeaseIDForPrepare(request) || first.Lease.HandoffToken != "value-1" {
		t.Fatalf("first prepare=%+v", first)
	}
	retry, err := store.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if !retry.Reused || retry.Lease.LeaseID != first.Lease.LeaseID {
		t.Fatalf("retry=%+v, want same reused lease", retry)
	}

	_, err = store.Prepare(prepareRequest(1, "prepare-different-key", "digest-1"))
	requireCode(t, err, codes.FailedPrecondition)
	_, err = store.Prepare(prepareRequest(1, "prepare-different-payload", "digest-2"))
	requireCode(t, err, codes.FailedPrecondition)
	_, err = store.Prepare(prepareRequest(2, "prepare-2", "digest-2"))
	requireCode(t, err, codes.FailedPrecondition)
	_, err = store.Prepare(prepareRequest(2, "prepare-1", "digest-2"))
	requireCode(t, err, codes.InvalidArgument)
}

func TestReleaseRequiresExactLeaseAndStableOperationKey(t *testing.T) {
	store := openTestStore(t, t.TempDir(), deterministicGenerator())
	prepared, err := store.Prepare(prepareRequest(4, "prepare-4", "digest-4"))
	if err != nil {
		t.Fatal(err)
	}
	lease := prepared.Lease.LeaseID
	if _, err := store.MarkReady("sandbox-a", 4, lease, "network-4", nil); err != nil {
		t.Fatal(err)
	}

	_, err = store.BeginRelease(releaseRequest(4, lease+"-wrong", "release-wrong"))
	requireCode(t, err, codes.FailedPrecondition)
	_, err = store.BeginRelease(releaseRequest(4, lease, "prepare-4"))
	requireCode(t, err, codes.InvalidArgument)

	release := releaseRequest(4, lease, "release-4")
	first, err := store.BeginRelease(release)
	if err != nil {
		t.Fatal(err)
	}
	if first.Reused || first.Lease.Phase != PhaseReleasing {
		t.Fatalf("first release=%+v", first)
	}
	retry, err := store.BeginRelease(release)
	if err != nil {
		t.Fatal(err)
	}
	if !retry.Reused {
		t.Fatalf("release retry=%+v, want reused", retry)
	}
	_, err = store.BeginRelease(releaseRequest(4, lease, "release-4-other"))
	requireCode(t, err, codes.FailedPrecondition)
}

func TestRestartRecoveryTombstoneAndStaleOperationFencing(t *testing.T) {
	dir := t.TempDir()
	firstStore := openTestStore(t, dir, deterministicGenerator())
	prepared, err := firstStore.Prepare(prepareRequest(1, "prepare-1", "digest-1"))
	if err != nil {
		t.Fatal(err)
	}
	lease1 := prepared.Lease.LeaseID
	if _, err := firstStore.MarkReady("sandbox-a", 1, lease1, "network-1", nil); err != nil {
		t.Fatal(err)
	}
	release1 := releaseRequest(1, lease1, "release-1")
	if _, err := firstStore.BeginRelease(release1); err != nil {
		t.Fatal(err)
	}
	if err := firstStore.CompleteRelease(release1); err != nil {
		t.Fatal(err)
	}

	restarted := openTestStore(t, dir, deterministicGenerator())
	_, err = restarted.Prepare(prepareRequest(1, "prepare-1", "digest-1"))
	requireCode(t, err, codes.FailedPrecondition)
	releasedRetry, err := restarted.BeginRelease(release1)
	if err != nil {
		t.Fatal(err)
	}
	if !releasedRetry.Reused {
		t.Fatalf("tombstone release retry=%+v, want reused", releasedRetry)
	}
	_, err = restarted.BeginRelease(releaseRequest(1, lease1, "release-1-other"))
	requireCode(t, err, codes.FailedPrecondition)

	prepared2, err := restarted.Prepare(prepareRequest(2, "prepare-2", "digest-2"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := restarted.MarkReady("sandbox-a", 2, prepared2.Lease.LeaseID, "network-2", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := restarted.BeginRelease(release1); err != nil {
		t.Fatalf("exact old release retry must be harmless success: %v", err)
	}
	record, err := restarted.Inspect("sandbox-a")
	if err != nil {
		t.Fatal(err)
	}
	if record.Active == nil || record.Active.Generation != 2 || record.Active.Phase != PhaseReady {
		t.Fatalf("old release retry changed current lease: %+v", record.Active)
	}
	_, err = restarted.BeginRelease(releaseRequest(1, lease1, "delayed-new-key"))
	requireCode(t, err, codes.FailedPrecondition)
	_, err = restarted.BeginRelease(releaseRequest(2, prepared2.Lease.LeaseID+"-wrong", "release-2"))
	requireCode(t, err, codes.FailedPrecondition)
}

func TestPreparingLeaseRetrySurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	store := openTestStore(t, dir, deterministicGenerator())
	request := prepareRequest(9, "prepare-9", "digest-9")
	first, err := store.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	restarted := openTestStore(t, dir, deterministicGenerator())
	retry, err := restarted.Prepare(request)
	if err != nil {
		t.Fatal(err)
	}
	if !retry.Reused || retry.Lease.LeaseID != first.Lease.LeaseID ||
		retry.Lease.HandoffToken != first.Lease.HandoffToken || retry.Lease.Phase != PhasePreparing {
		t.Fatalf("restart retry=%+v, want durable preparing lease %+v", retry, first)
	}
}

func TestAbandonedPrepareLeavesHighWatermarkTombstone(t *testing.T) {
	store := openTestStore(t, t.TempDir(), deterministicGenerator())
	prepared, err := store.Prepare(prepareRequest(3, "prepare-3", "digest-3"))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.AbandonPrepare("sandbox-a", 3, prepared.Lease.LeaseID); err != nil {
		t.Fatal(err)
	}
	_, err = store.Prepare(prepareRequest(3, "prepare-3-new", "digest-3"))
	requireCode(t, err, codes.FailedPrecondition)
	_, err = store.Prepare(prepareRequest(2, "prepare-2", "digest-2"))
	requireCode(t, err, codes.FailedPrecondition)
	next, err := store.Prepare(prepareRequest(4, "prepare-4", "digest-4"))
	if err != nil {
		t.Fatal(err)
	}
	if next.Lease.Generation != 4 {
		t.Fatalf("next lease=%+v", next.Lease)
	}
}

func TestUnknownFutureReleaseDoesNotAdvanceHighWatermark(t *testing.T) {
	store := openTestStore(t, t.TempDir(), deterministicGenerator())
	_, err := store.BeginRelease(releaseRequest(5, "lease-5", "release-5"))
	requireCode(t, err, codes.NotFound)
	prepared, err := store.Prepare(prepareRequest(1, "prepare-1", "digest-1"))
	if err != nil {
		t.Fatal(err)
	}
	if prepared.Lease.Generation != 1 {
		t.Fatalf("prepared=%+v", prepared)
	}
}

func TestCompleteReleaseRetryAndOperationKeyRemainFencedAfterReplacement(t *testing.T) {
	store := openTestStore(t, t.TempDir(), deterministicGenerator())
	prepared1, err := store.Prepare(prepareRequest(1, "prepare-1", "digest-1"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.MarkReady("sandbox-a", 1, prepared1.Lease.LeaseID, "network-1", nil); err != nil {
		t.Fatal(err)
	}
	release1 := releaseRequest(1, prepared1.Lease.LeaseID, "release-1")
	if _, err := store.BeginRelease(release1); err != nil {
		t.Fatal(err)
	}
	if err := store.CompleteRelease(release1); err != nil {
		t.Fatal(err)
	}

	prepared2, err := store.Prepare(prepareRequest(2, "prepare-2", "digest-2"))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.CompleteRelease(release1); err != nil {
		t.Fatalf("exact completed release retry must remain successful: %v", err)
	}
	record, err := store.Inspect("sandbox-a")
	if err != nil {
		t.Fatal(err)
	}
	if record.Active == nil || record.Active.LeaseID != prepared2.Lease.LeaseID {
		t.Fatalf("old CompleteRelease retry changed replacement: %+v", record.Active)
	}
	_, err = store.Prepare(prepareRequest(3, "release-1", "digest-3"))
	requireCode(t, err, codes.InvalidArgument)
}
