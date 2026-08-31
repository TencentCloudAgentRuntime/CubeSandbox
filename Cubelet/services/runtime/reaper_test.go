// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func writeReaperJob(t *testing.T, root, name string, record reaperRecord) string {
	t.Helper()
	if err := ensureDirectoryDurable(root); err != nil {
		t.Fatal(err)
	}
	job := filepath.Join(root, name)
	if err := os.Mkdir(job, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := syncDirectory(root); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(job, reaperRecordName)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Sync(); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := syncDirectory(job); err != nil {
		t.Fatal(err)
	}
	if err := syncDirectory(root); err != nil {
		t.Fatal(err)
	}
	return job
}

func TestRecoverReaperJobOnlyReleasesReadyLeaseAfterCubeletRestart(t *testing.T) {
	stateDir := t.TempDir()
	store, err := state.Open(stateDir, serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	adapter := newServiceFakeAdapter()
	first, _ := newTestService(t, store, adapter)
	response, err := first.PrepareSandbox(context.Background(), serviceRequest("sandbox-job-only", 1, "prepare-job-only"))
	if err != nil {
		t.Fatal(err)
	}
	prepared := response.GetSandbox()
	root := filepath.Join(t.TempDir(), "reaper")
	job := writeReaperJob(t, root, "job-ready", reaperRecord{
		Endpoint: "/run/cubelet/runtime.sock", SandboxID: prepared.GetSandboxId(),
		LeaseID: prepared.GetLeaseId(), Generation: prepared.GetGeneration(),
	})

	reopened, err := state.Open(stateDir, serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	restarted, _ := newTestService(t, reopened, adapter)
	if err := restarted.Recover(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := restarted.RecoverReaperJobs(context.Background(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(job); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("reaper job still exists: %v", err)
	}
	record, err := store.Inspect(prepared.GetSandboxId())
	if err != nil || record.Active != nil || len(record.Tombstones) != 1 {
		t.Fatalf("record=%+v err=%v", record, err)
	}
	adapter.mu.Lock()
	defer adapter.mu.Unlock()
	if adapter.releaseCalls != 1 || len(adapter.records) != 0 {
		t.Fatalf("release calls=%d records=%d", adapter.releaseCalls, len(adapter.records))
	}
}

func TestRecoverFutureReaperJobFencesLatePrepare(t *testing.T) {
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	adapter := newServiceFakeAdapter()
	service, _ := newTestService(t, store, adapter)
	prepare := cubeShimServiceRequest("sandbox-future-job", 3)
	release := releaseBeforePrepareRequest(prepare)
	root := filepath.Join(t.TempDir(), "reaper")
	job := writeReaperJob(t, root, "job-future", reaperRecord{
		Endpoint: "/run/cubelet/runtime.sock", SandboxID: release.GetSandboxId(),
		LeaseID: release.GetLeaseId(), Generation: release.GetGeneration(),
	})

	if err := service.RecoverReaperJobs(context.Background(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := service.PrepareSandbox(context.Background(), prepare); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("late Prepare error=%v code=%s", err, status.Code(err))
	}
	if _, err := os.Stat(job); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("future job still exists: %v", err)
	}
	record, err := store.Inspect(prepare.GetSandboxId())
	if err != nil || record.Active != nil || record.HighWatermark != prepare.GetGeneration() {
		t.Fatalf("record=%+v err=%v", record, err)
	}
	adapter.mu.Lock()
	defer adapter.mu.Unlock()
	if adapter.prepareCalls != 0 || adapter.releaseCalls != 0 {
		t.Fatalf("adapter calls prepare=%d release=%d", adapter.prepareCalls, adapter.releaseCalls)
	}
}

func TestReaperSupervisorConsumesJobCreatedAfterStartup(t *testing.T) {
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	service, _ := newTestService(t, store, newServiceFakeAdapter())
	root := filepath.Join(t.TempDir(), "reaper")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	errorsSeen := make(chan error, 1)
	go func() {
		defer close(done)
		service.RunReaperSupervisor(ctx, root, 5*time.Millisecond, func(err error) {
			select {
			case errorsSeen <- err:
			default:
			}
		})
	}()
	prepare := cubeShimServiceRequest("sandbox-periodic-job", 2)
	release := releaseBeforePrepareRequest(prepare)
	job := writeReaperJob(t, root, "job-periodic", reaperRecord{
		Endpoint: "/run/cubelet/runtime.sock", SandboxID: release.GetSandboxId(),
		LeaseID: release.GetLeaseId(), Generation: release.GetGeneration(),
	})

	deadline := time.Now().Add(3 * time.Second)
	for {
		_, statErr := os.Stat(job)
		if errors.Is(statErr, os.ErrNotExist) {
			break
		}
		if statErr != nil {
			t.Fatalf("stat periodic job: %v", statErr)
		}
		select {
		case report := <-errorsSeen:
			t.Fatalf("supervisor error: %v", report)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("periodic reaper did not consume job")
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("reaper supervisor did not stop")
	}
	record, err := store.Inspect(prepare.GetSandboxId())
	if err != nil || record.Active != nil || record.HighWatermark != prepare.GetGeneration() {
		t.Fatalf("record=%+v err=%v", record, err)
	}
}
