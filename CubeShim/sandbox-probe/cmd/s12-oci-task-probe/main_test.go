// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"strings"
	"syscall"
	"testing"
	"time"

	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/errdefs"
	"google.golang.org/grpc/codes"
	grpcstatus "google.golang.org/grpc/status"
)

func TestTaskMountTargetsFromSelectsOnlyRequestedTask(t *testing.T) {
	mountinfo := strings.Join([]string{
		"10 1 0:1 / /data/cubelet/s12/shared/sandbox/rootfs/task-a-42-1/layers/000 rw - none /source rw",
		"11 1 0:2 / /data/cubelet/s12/shared/sandbox/rootfs/task-b-42-2/merged rw - overlay overlay rw",
		"12 1 0:3 / /data/cubelet/s12/shared/sandbox/rootfs/task-a-42-1/layers/001 rw - none /source2 rw",
	}, "\n")

	targets, err := taskMountTargetsFrom(strings.NewReader(mountinfo), "task-a")
	if err != nil {
		t.Fatal(err)
	}
	if len(targets) != 2 {
		t.Fatalf("targets = %v, want two task-a mounts", targets)
	}
	for _, target := range targets {
		root, err := sharedRootFromMount(target)
		if err != nil {
			t.Fatal(err)
		}
		if root != "/data/cubelet/s12/shared/sandbox" {
			t.Fatalf("shared root = %q", root)
		}
	}
}

func TestCreateCollisionDoesNotClaimExistingSandbox(t *testing.T) {
	bundle := "/run/cubesandbox-s12/state/io.containerd.sandbox.controller.v1.shim/s12-live/sandbox"
	if !createCollision(grpcstatus.Error(codes.AlreadyExists, "sandbox already exists"), bundle) {
		t.Fatal("AlreadyExists was not classified as a collision")
	}
	if !createCollision(grpcstatus.Error(codes.Unknown, "mkdir "+bundle+": file exists"), bundle) {
		t.Fatal("bundle collision was not classified as a collision")
	}
	if createCollision(grpcstatus.Error(codes.Unknown, "publish sandbox create event: unavailable"), bundle) {
		t.Fatal("ambiguous post-create failure was incorrectly classified as a collision")
	}
}

func TestSharedRootFromMountRejectsUnrelatedPath(t *testing.T) {
	if _, err := sharedRootFromMount("/data/cubelet/no-export"); err == nil {
		t.Fatal("sharedRootFromMount accepted path without rootfs component")
	}
}

type fakeCleanupProcess struct {
	status      containerd.ProcessStatus
	waited      chan containerd.ExitStatus
	taskIO      cio.IO
	signalExit  bool
	killCalls   int
	deleteCalls int
	deleteErr   error
}

func (f *fakeCleanupProcess) ID() string { return "cleanup-task" }
func (f *fakeCleanupProcess) IO() cio.IO { return f.taskIO }
func (f *fakeCleanupProcess) Status(context.Context) (containerd.Status, error) {
	return containerd.Status{Status: f.status}, nil
}
func (f *fakeCleanupProcess) Wait(context.Context) (<-chan containerd.ExitStatus, error) {
	return f.waited, nil
}
func (f *fakeCleanupProcess) Kill(context.Context, syscall.Signal, ...containerd.KillOpts) error {
	f.killCalls++
	f.status = containerd.Stopped
	if f.signalExit {
		f.waited <- *containerd.NewExitStatus(137, time.Now(), nil)
	}
	return nil
}
func (f *fakeCleanupProcess) Delete(context.Context, ...containerd.ProcessDeleteOpts) (*containerd.ExitStatus, error) {
	f.deleteCalls++
	return containerd.NewExitStatus(137, time.Now(), f.deleteErr), f.deleteErr
}

func freshTestContext() (context.Context, context.CancelFunc) {
	return context.WithCancel(context.Background())
}

func TestCleanupTaskDeletesCreatedThroughTaskService(t *testing.T) {
	task := &fakeCleanupProcess{status: containerd.Created}
	rawDeletes := 0
	err := cleanupTask(context.Background(), task, func(context.Context, string) error {
		rawDeletes++
		return nil
	}, freshTestContext)
	if err != nil {
		t.Fatal(err)
	}
	if rawDeletes != 1 || task.killCalls != 0 || task.deleteCalls != 0 {
		t.Fatalf("raw=%d kill=%d delete=%d", rawDeletes, task.killCalls, task.deleteCalls)
	}
}

func TestCleanupTaskWaitsKillsAndDeletesRunning(t *testing.T) {
	task := &fakeCleanupProcess{
		status:     containerd.Running,
		waited:     make(chan containerd.ExitStatus, 1),
		signalExit: true,
	}
	rawDeletes := 0
	err := cleanupTask(context.Background(), task, func(context.Context, string) error {
		rawDeletes++
		return nil
	}, freshTestContext)
	if err != nil {
		t.Fatal(err)
	}
	if task.killCalls != 1 || task.deleteCalls != 1 || rawDeletes != 0 {
		t.Fatalf("kill=%d delete=%d raw=%d", task.killCalls, task.deleteCalls, rawDeletes)
	}
}

func TestCleanupTaskUsesFreshDeleteContextAfterWaitTimeout(t *testing.T) {
	task := &fakeCleanupProcess{
		status: containerd.Running,
		waited: make(chan containerd.ExitStatus),
	}
	waitCtx, cancelWait := context.WithCancel(context.Background())
	cancelWait()
	freshCalls := 0
	err := cleanupTask(waitCtx, task, func(context.Context, string) error {
		t.Fatal("raw delete should not be needed")
		return nil
	}, func() (context.Context, context.CancelFunc) {
		freshCalls++
		return freshTestContext()
	})
	if err != nil {
		t.Fatal(err)
	}
	if task.killCalls != 1 || task.deleteCalls != 1 || freshCalls != 1 {
		t.Fatalf("kill=%d delete=%d fresh=%d", task.killCalls, task.deleteCalls, freshCalls)
	}
}

type fakeCleanupIO struct {
	cancelCalls int
	waitCalls   int
	closeCalls  int
}

func (f *fakeCleanupIO) Config() cio.Config { return cio.Config{} }
func (f *fakeCleanupIO) Cancel()            { f.cancelCalls++ }
func (f *fakeCleanupIO) Wait()              { f.waitCalls++ }
func (f *fakeCleanupIO) Close() error {
	f.closeCalls++
	return nil
}

func TestCleanupTaskNotFoundClosesOriginalIO(t *testing.T) {
	taskIO := &fakeCleanupIO{}
	task := &fakeCleanupProcess{
		status:    containerd.Stopped,
		taskIO:    taskIO,
		deleteErr: errdefs.ErrNotFound,
	}
	err := cleanupTask(context.Background(), task, func(context.Context, string) error {
		t.Fatal("raw delete should not be called for NotFound")
		return nil
	}, freshTestContext)
	if err != nil {
		t.Fatal(err)
	}
	if taskIO.cancelCalls != 1 || taskIO.waitCalls != 1 || taskIO.closeCalls != 1 {
		t.Fatalf("cancel=%d wait=%d close=%d", taskIO.cancelCalls, taskIO.waitCalls, taskIO.closeCalls)
	}
}

func TestRecoverLoadedTaskCleansAmbiguousCreate(t *testing.T) {
	task := &fakeCleanupProcess{status: containerd.Created}
	loadCalls, cleanupCalls := 0, 0
	err := recoverLoadedTask(
		context.Background(),
		func(context.Context) (cleanupProcess, error) {
			loadCalls++
			return task, nil
		},
		func(got cleanupProcess) error {
			cleanupCalls++
			if got != task {
				t.Fatal("cleanup received a different Task")
			}
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if loadCalls != 1 || cleanupCalls != 1 {
		t.Fatalf("load=%d cleanup=%d", loadCalls, cleanupCalls)
	}
}
