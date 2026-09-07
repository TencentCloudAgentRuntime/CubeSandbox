// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/tencentcloud/CubeSandbox/Cubelet/internal/kmutex"
	"github.com/tencentcloud/CubeSandbox/Cubelet/internal/monotime"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// LifecycleStore is the durable half of the RuntimeResource lifecycle.
type LifecycleStore interface {
	Prepare(state.PrepareRequest) (*state.PrepareResult, error)
	MarkReady(string, uint64, string, string, *monotime.TraceBuffer) (*state.Lease, error)
	AbandonPrepare(string, uint64, string) error
	BeginRelease(state.ReleaseRequest) (*state.ReleaseResult, error)
	ConfirmReleaseDurable(state.ReleaseRequest) (*state.ReleaseResult, error)
	CompleteRelease(state.ReleaseRequest) error
	Inspect(string) (*state.Record, error)
	ListSandboxIDs() ([]string, error)
}

// Coordinator freezes per-sandbox lifecycle lock order as:
//
//	Coordinator.operations[sandbox] -> handoff.Registry.operations[sandbox] -> state.Store.operations[sandbox]
//
// Registry and Store map locks protect only in-memory bookkeeping and are never
// held across callbacks or filesystem I/O. Store methods never call Registry.
type Coordinator struct {
	operations kmutex.KeyedLocker
	store      LifecycleStore
	handoff    *handoff.Registry
	uncertain  sync.Map
	confirmed  sync.Map
}

func NewCoordinator(store LifecycleStore, registry *handoff.Registry) (*Coordinator, error) {
	if store == nil || registry == nil {
		return nil, errors.New("runtime lifecycle store/registry is nil")
	}
	return &Coordinator{
		operations: kmutex.New(), store: store, handoff: registry,
	}, nil
}

func (c *Coordinator) Prepare(request state.PrepareRequest) (result *state.PrepareResult, err error) {
	totalStart := time.Now()
	lockStart := totalStart
	if err := c.operations.Lock(context.Background(), request.SandboxID); err != nil {
		return nil, err
	}
	defer c.operations.Unlock(request.SandboxID)
	lockWait := time.Since(lockStart)
	storeStart := time.Now()
	defer func() {
		if !request.Trace.Enabled() {
			return
		}
		request.Trace.Addf(
			"cube_perf component=cubelet operation=create phase=coordinator-prepare sandbox_id=%s pod_uid=%s operation_id=%s generation=%d ts_mono_us=%d duration_us=%d success=%t lock_wait_us=%d store_us=%d",
			request.SandboxID, request.PodUID, request.SandboxID, request.Generation, monotime.Micros(), time.Since(totalStart).Microseconds(),
			err == nil, lockWait.Microseconds(), time.Since(storeStart).Microseconds(),
		)
	}()
	return c.store.Prepare(request)
}

// AbandonPrepare is called only after every PREPARING side effect is rolled back.
func (c *Coordinator) AbandonPrepare(sandboxID string, generation uint64, leaseID string) error {
	if err := c.operations.Lock(context.Background(), sandboxID); err != nil {
		return err
	}
	defer c.operations.Unlock(sandboxID)
	if err := c.handoff.EnsureAbsent(sandboxID); err != nil {
		return err
	}
	return c.store.AbandonPrepare(sandboxID, generation, leaseID)
}

// MarkReadyAndPublish persists READY before publishing its exact FD binding.
// A publication failure is fail-closed: the caller must retry or recover before
// serving the sandbox.
func (c *Coordinator) MarkReadyAndPublish(sandboxID string, generation uint64, leaseID, networkHandle string, trace *monotime.TraceBuffer) (lease *state.Lease, err error) {
	totalStart := time.Now()
	lockStart := totalStart
	if err := c.operations.Lock(context.Background(), sandboxID); err != nil {
		return nil, err
	}
	defer c.operations.Unlock(sandboxID)
	lockWait := time.Since(lockStart)
	storeStart := time.Now()
	defer func() {
		if !trace.Enabled() {
			return
		}
		podUID := ""
		if lease != nil {
			podUID = lease.PodUID
		}
		trace.Addf(
			"cube_perf component=cubelet operation=create phase=coordinator-ready sandbox_id=%s pod_uid=%s operation_id=%s generation=%d ts_mono_us=%d duration_us=%d success=%t lock_wait_us=%d store_publish_us=%d",
			sandboxID, podUID, sandboxID, generation, monotime.Micros(), time.Since(totalStart).Microseconds(), err == nil,
			lockWait.Microseconds(), time.Since(storeStart).Microseconds(),
		)
	}()
	lease, err = c.store.MarkReady(sandboxID, generation, leaseID, networkHandle, trace)
	if err != nil {
		return nil, err
	}
	if err := c.handoff.Publish(bindingFromLease(sandboxID, lease)); err != nil {
		return nil, err
	}
	return lease, nil
}

// BeginReleaseAndFence is the single Release linearization boundary. For the
// current READY lease it holds the Registry's sandbox lock while
// Store.BeginRelease fsyncs the RELEASING record, then removes the binding
// before unlocking. Thus a duplicate already in progress completes first;
// after this method returns no new one can.
func (c *Coordinator) BeginReleaseAndFence(request state.ReleaseRequest) (*state.ReleaseResult, error) {
	if err := c.operations.Lock(context.Background(), request.SandboxID); err != nil {
		return nil, err
	}
	defer c.operations.Unlock(request.SandboxID)
	record, err := c.store.Inspect(request.SandboxID)
	if status.Code(err) == codes.NotFound {
		result, beginErr := c.store.BeginRelease(request)
		if state.IsCommitUnknown(beginErr) {
			c.uncertain.Store(request.SandboxID, request)
			c.confirmed.Delete(request.SandboxID)
		} else if beginErr == nil {
			c.uncertain.Delete(request.SandboxID)
			c.confirmed.Delete(request.SandboxID)
		}
		return result, beginErr
	}
	if err != nil {
		return nil, err
	}
	if record.Active != nil && record.Active.Generation == request.Generation &&
		record.Active.LeaseID == request.LeaseID && record.Active.Phase == state.PhaseReleasing &&
		record.Active.ReleaseKey == request.IdempotencyKey {
		return c.confirmReleaseDurable(request)
	}
	if record.Active != nil && record.Active.Generation == request.Generation &&
		record.Active.LeaseID == request.LeaseID && record.Active.Phase == state.PhaseReady {
		binding := bindingFromLease(request.SandboxID, record.Active)
		var result *state.ReleaseResult
		if err := c.handoff.FenceCurrent(binding, func() error {
			var persistErr error
			result, persistErr = c.store.BeginRelease(request)
			return persistErr
		}); err != nil {
			if state.IsCommitUnknown(err) {
				c.uncertain.Store(request.SandboxID, request)
				c.confirmed.Delete(request.SandboxID)
			}
			return nil, err
		}
		c.uncertain.Delete(request.SandboxID)
		c.confirmed.Store(request.SandboxID, request)
		return result, nil
	}
	// PREPARING has never been published. RELEASING and tombstone retries are
	// already fenced. Mismatched requests are rejected by the durable store.
	result, err := c.store.BeginRelease(request)
	if err != nil {
		if state.IsCommitUnknown(err) {
			c.uncertain.Store(request.SandboxID, request)
			c.confirmed.Delete(request.SandboxID)
		}
		return nil, err
	}
	if record.Active != nil && record.Active.Generation == request.Generation &&
		record.Active.LeaseID == request.LeaseID {
		c.uncertain.Delete(request.SandboxID)
		c.confirmed.Store(request.SandboxID, request)
	} else {
		c.uncertain.Delete(request.SandboxID)
		c.confirmed.Delete(request.SandboxID)
	}
	return result, nil
}

func (c *Coordinator) CompleteRelease(request state.ReleaseRequest) error {
	if err := c.operations.Lock(context.Background(), request.SandboxID); err != nil {
		return err
	}
	defer c.operations.Unlock(request.SandboxID)
	if _, ok := c.uncertain.Load(request.SandboxID); ok {
		return status.Error(codes.FailedPrecondition, "release durability is commit-unknown; resynchronize before cleanup")
	}
	confirmedValue, ok := c.confirmed.Load(request.SandboxID)
	confirmed, valid := confirmedValue.(state.ReleaseRequest)
	if !ok || !valid || confirmed != request {
		return status.Error(codes.FailedPrecondition, "release durability is not confirmed; recover before cleanup")
	}
	if err := c.store.CompleteRelease(request); err != nil {
		return err
	}
	c.confirmed.Delete(request.SandboxID)
	return nil
}

// RecoverSandbox is called before accepting RuntimeResource/FD traffic. READY
// is republished from durable identity; PREPARING/RELEASING/released remain
// absent, so a crash between persist and invalidate cannot reopen a lease.
func (c *Coordinator) RecoverSandbox(sandboxID string) error {
	if err := c.operations.Lock(context.Background(), sandboxID); err != nil {
		return err
	}
	defer c.operations.Unlock(sandboxID)
	record, err := c.store.Inspect(sandboxID)
	if err != nil {
		return err
	}
	if record.Active != nil && record.Active.Phase == state.PhaseReady {
		if err := c.handoff.Publish(bindingFromLease(sandboxID, record.Active)); err != nil {
			return err
		}
		c.uncertain.Delete(sandboxID)
		c.confirmed.Delete(sandboxID)
		return nil
	}
	if err := c.handoff.EnsureAbsent(sandboxID); err != nil {
		return err
	}
	if record.Active != nil && record.Active.Phase == state.PhaseReleasing {
		request := state.ReleaseRequest{
			SandboxID: sandboxID, Generation: record.Active.Generation,
			LeaseID: record.Active.LeaseID, IdempotencyKey: record.Active.ReleaseKey,
		}
		_, err := c.confirmReleaseDurable(request)
		return err
	}
	c.uncertain.Delete(sandboxID)
	c.confirmed.Delete(sandboxID)
	return nil
}

func (c *Coordinator) confirmReleaseDurable(request state.ReleaseRequest) (*state.ReleaseResult, error) {
	result, err := c.store.ConfirmReleaseDurable(request)
	if err != nil {
		if state.IsCommitUnknown(err) {
			c.uncertain.Store(request.SandboxID, request)
			c.confirmed.Delete(request.SandboxID)
		}
		return nil, err
	}
	c.uncertain.Delete(request.SandboxID)
	c.confirmed.Store(request.SandboxID, request)
	return result, nil
}

func bindingFromLease(sandboxID string, lease *state.Lease) handoff.Binding {
	return handoff.Binding{
		SandboxID:     sandboxID,
		Generation:    lease.Generation,
		LeaseID:       lease.LeaseID,
		NetworkHandle: lease.NetworkHandle,
		Token:         lease.HandoffToken,
		Ready:         lease.Phase == state.PhaseReady,
	}
}
