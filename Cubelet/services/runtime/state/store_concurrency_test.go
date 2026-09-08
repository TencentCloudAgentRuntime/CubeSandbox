// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package state

import (
	"fmt"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestStoreDifferentSandboxesPersistConcurrently(t *testing.T) {
	entered := make(chan struct{}, 2)
	proceed := make(chan struct{})
	store, err := Open(t.TempDir(), deterministicGenerator(), WithPersistenceHooks(PersistenceHooks{
		BeforeRename: func() error {
			entered <- struct{}{}
			<-proceed
			return nil
		},
	}))
	if err != nil {
		t.Fatal(err)
	}

	results := make(chan error, 2)
	for _, sandboxID := range []string{"sandbox-a", "sandbox-b"} {
		sandboxID := sandboxID
		go func() {
			_, err := store.Prepare(PrepareRequest{
				SandboxID: sandboxID, Generation: 1,
				IdempotencyKey: "prepare-" + sandboxID, PayloadDigest: "digest-" + sandboxID,
			})
			results <- err
		}()
	}

	for range 2 {
		select {
		case <-entered:
		case <-time.After(time.Second):
			close(proceed)
			t.Fatal("different sandbox durable writes did not overlap")
		}
	}
	close(proceed)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
}

func TestListSandboxIDsDuringConcurrentPersistenceIsConsistent(t *testing.T) {
	const writers = 16
	renameEntered := make(chan struct{}, writers)
	parentSyncEntered := make(chan struct{}, writers)
	allowRename := make(chan struct{})
	allowParentSync := make(chan struct{})
	var renameCalls atomic.Int32
	var parentSyncCalls atomic.Int32
	store, err := Open(t.TempDir(), deterministicGenerator(), WithPersistenceHooks(PersistenceHooks{
		BeforeRename: func() error {
			if renameCalls.Add(1) <= writers {
				renameEntered <- struct{}{}
				<-allowRename
			}
			return nil
		},
		BeforeParentSync: func() error {
			if parentSyncCalls.Add(1) <= writers {
				parentSyncEntered <- struct{}{}
				<-allowParentSync
			}
			return nil
		},
	}))
	if err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	errorsByWriter := make(chan error, writers)
	var writersDone sync.WaitGroup
	for index := range writers {
		sandboxID := fmt.Sprintf("sandbox-%02d", index)
		writersDone.Add(1)
		go func() {
			defer writersDone.Done()
			<-start
			prepared, err := store.Prepare(PrepareRequest{
				SandboxID: sandboxID, Generation: 1,
				IdempotencyKey: "prepare-" + sandboxID, PayloadDigest: "digest-" + sandboxID,
			})
			if err != nil {
				errorsByWriter <- err
				return
			}
			lease, err := store.MarkReady(sandboxID, 1, prepared.Lease.LeaseID, "network-"+sandboxID, nil)
			if err != nil {
				errorsByWriter <- err
				return
			}
			release := ReleaseRequest{
				SandboxID: sandboxID, Generation: 1, LeaseID: lease.LeaseID,
				IdempotencyKey: ExpectedReleaseKey(sandboxID, 1, lease.LeaseID),
			}
			if _, err := store.BeginRelease(release); err != nil {
				errorsByWriter <- err
				return
			}
			if err := store.CompleteRelease(release); err != nil {
				errorsByWriter <- err
			}
		}()
	}
	close(start)

	waitForWindow := func(name string, entered <-chan struct{}) {
		t.Helper()
		for range writers {
			select {
			case <-entered:
			case <-time.After(5 * time.Second):
				t.Fatalf("writers did not enter %s persistence window", name)
			}
		}
	}
	assertLists := func(name string, wantCount int) {
		t.Helper()
		for range 100 {
			ids, err := store.ListSandboxIDs()
			if err != nil {
				t.Fatalf("ListSandboxIDs during %s: %v", name, err)
			}
			if !sort.StringsAreSorted(ids) {
				t.Fatalf("sandbox IDs during %s are not sorted: %v", name, ids)
			}
			seen := make(map[string]struct{}, len(ids))
			for _, id := range ids {
				if _, duplicate := seen[id]; duplicate {
					t.Fatalf("duplicate sandbox ID %q during %s", id, name)
				}
				seen[id] = struct{}{}
			}
			if len(ids) != wantCount {
				t.Fatalf("sandbox IDs during %s=%v, want count %d", name, ids, wantCount)
			}
		}
	}

	// Every writer has a fully synced temp file, but no rename is visible yet.
	waitForWindow("before-rename", renameEntered)
	assertLists("before-rename", 0)
	close(allowRename)
	// Every rename is visible, while all parent-directory fsync calls are held.
	waitForWindow("before-parent-sync", parentSyncEntered)
	assertLists("before-parent-sync", writers)
	close(allowParentSync)

	writersDone.Wait()
	close(errorsByWriter)
	for err := range errorsByWriter {
		if err != nil {
			t.Fatal(err)
		}
	}
	ids, err := store.ListSandboxIDs()
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != writers {
		t.Fatalf("final sandbox IDs=%v, want %d", ids, writers)
	}
	for index, id := range ids {
		if want := fmt.Sprintf("sandbox-%02d", index); id != want {
			t.Fatalf("final sandbox ID[%d]=%q, want %q", index, id, want)
		}
	}
}
