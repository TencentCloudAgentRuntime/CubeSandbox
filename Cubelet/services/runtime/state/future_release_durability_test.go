// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package state

import (
	"errors"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestFutureReleaseResponseLossConvergesToDurableFence(t *testing.T) {
	dir := t.TempDir()
	injected := errors.New("injected parent fsync failure after rename")
	store, err := Open(dir, deterministicGenerator(), WithPersistenceHooks(PersistenceHooks{
		BeforeParentSync: func() error { return injected },
	}))
	if err != nil {
		t.Fatal(err)
	}
	prepare := cubeShimPrepareRequest("sandbox-response-loss", 4)
	release := exactFutureRelease(prepare)
	if _, err := store.BeginRelease(release); status.Code(err) != codes.Unavailable || !IsCommitUnknown(err) {
		t.Fatalf("future Release error=%v code=%s commitUnknown=%t", err, status.Code(err), IsCommitUnknown(err))
	}

	restarted := openTestStore(t, dir, deterministicGenerator())
	result, err := restarted.BeginRelease(release)
	if err != nil || !result.Reused {
		t.Fatalf("future Release after response loss=%+v err=%v", result, err)
	}
	if _, err := restarted.Prepare(prepare); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("late Prepare error=%v code=%s", err, status.Code(err))
	}
	record, err := restarted.Inspect(prepare.SandboxID)
	if err != nil || record.Active != nil || record.HighWatermark != prepare.Generation {
		t.Fatalf("record=%+v err=%v", record, err)
	}
}
