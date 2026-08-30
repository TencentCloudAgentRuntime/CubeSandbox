// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"errors"
	"sync"

	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// LifecycleStore is the durable half of the RuntimeResource lifecycle.
type LifecycleStore interface {
	Prepare(state.PrepareRequest) (*state.PrepareResult, error)
	MarkReady(string, uint64, string, string) (*state.Lease, error)
	BeginRelease(state.ReleaseRequest) (*state.ReleaseResult, error)
	CompleteRelease(state.ReleaseRequest) error
	Inspect(string) (*state.Record, error)
}

// Coordinator freezes lifecycle lock order as:
//
//	Coordinator.mu -> handoff.Registry.mu -> state.Store.mu
//
// Acquire takes only Registry.mu. Store methods never call back into Registry.
type Coordinator struct {
	mu        sync.Mutex
	store     LifecycleStore
	handoff   *handoff.Registry
	uncertain map[string]state.ReleaseRequest
}

func NewCoordinator(store LifecycleStore, registry *handoff.Registry) (*Coordinator, error) {
	if store == nil || registry == nil {
		return nil, errors.New("runtime lifecycle store/registry is nil")
	}
	return &Coordinator{
		store: store, handoff: registry, uncertain: make(map[string]state.ReleaseRequest),
	}, nil
}

func (c *Coordinator) Prepare(request state.PrepareRequest) (*state.PrepareResult, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.store.Prepare(request)
}

// MarkReadyAndPublish persists READY before publishing its exact FD binding.
// A publication failure is fail-closed: the caller must retry or recover before
// serving the sandbox.
func (c *Coordinator) MarkReadyAndPublish(sandboxID string, generation uint64, leaseID, networkHandle string) (*state.Lease, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	lease, err := c.store.MarkReady(sandboxID, generation, leaseID, networkHandle)
	if err != nil {
		return nil, err
	}
	if err := c.handoff.Publish(bindingFromLease(sandboxID, lease)); err != nil {
		return nil, err
	}
	return lease, nil
}

// BeginReleaseAndFence is the single Release linearization boundary. For the
// current READY lease it holds Registry.mu while Store.BeginRelease fsyncs the
// RELEASING record, then removes the binding before unlocking. Thus a duplicate
// already in progress completes first; after this method returns no new one can.
func (c *Coordinator) BeginReleaseAndFence(request state.ReleaseRequest) (*state.ReleaseResult, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.store.Inspect(request.SandboxID)
	if err != nil {
		return nil, err
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
				c.uncertain[request.SandboxID] = request
			}
			return nil, err
		}
		delete(c.uncertain, request.SandboxID)
		return result, nil
	}
	// PREPARING has never been published. RELEASING and tombstone retries are
	// already fenced. Mismatched requests are rejected by the durable store.
	result, err := c.store.BeginRelease(request)
	if err == nil {
		if uncertain, ok := c.uncertain[request.SandboxID]; ok && uncertain == request {
			delete(c.uncertain, request.SandboxID)
		}
	}
	return result, err
}

func (c *Coordinator) CompleteRelease(request state.ReleaseRequest) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.uncertain[request.SandboxID]; ok {
		return status.Error(codes.FailedPrecondition, "release durability is commit-unknown; resynchronize before cleanup")
	}
	return c.store.CompleteRelease(request)
}

// RecoverSandbox is called before accepting RuntimeResource/FD traffic. READY
// is republished from durable identity; PREPARING/RELEASING/released remain
// absent, so a crash between persist and invalidate cannot reopen a lease.
func (c *Coordinator) RecoverSandbox(sandboxID string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	record, err := c.store.Inspect(sandboxID)
	if err != nil {
		return err
	}
	if record.Active != nil && record.Active.Phase == state.PhaseReady {
		if err := c.handoff.Publish(bindingFromLease(sandboxID, record.Active)); err != nil {
			return err
		}
		delete(c.uncertain, sandboxID)
		return nil
	}
	if err := c.handoff.EnsureAbsent(sandboxID); err != nil {
		return err
	}
	delete(c.uncertain, sandboxID)
	return nil
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
