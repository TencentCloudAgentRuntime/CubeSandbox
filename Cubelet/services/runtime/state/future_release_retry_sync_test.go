// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package state

import (
	"errors"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestFutureReleaseRetryAfterRestartRepeatsParentSync(t *testing.T) {
	dir := t.TempDir()
	first, err := Open(dir, deterministicGenerator(), WithPersistenceHooks(PersistenceHooks{
		BeforeParentSync: func() error { return errors.New("injected first parent fsync failure") },
	}))
	if err != nil {
		t.Fatal(err)
	}
	prepare := cubeShimPrepareRequest("sandbox-retry-sync", 6)
	release := exactFutureRelease(prepare)
	if _, err := first.BeginRelease(release); status.Code(err) != codes.Unavailable || !IsCommitUnknown(err) {
		t.Fatalf("first Release error=%v code=%s commitUnknown=%t", err, status.Code(err), IsCommitUnknown(err))
	}

	retrySyncs := 0
	restarted, err := Open(dir, deterministicGenerator(), WithPersistenceHooks(PersistenceHooks{
		BeforeParentSync: func() error {
			retrySyncs++
			return nil
		},
	}))
	if err != nil {
		t.Fatal(err)
	}
	result, err := restarted.BeginRelease(release)
	if err != nil || !result.Reused {
		t.Fatalf("Release retry=%+v err=%v", result, err)
	}
	if retrySyncs != 1 {
		t.Fatalf("Release retry parent sync hooks=%d, want 1", retrySyncs)
	}
	if _, err := restarted.Prepare(prepare); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("late Prepare error=%v code=%s", err, status.Code(err))
	}
}
