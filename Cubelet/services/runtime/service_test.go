// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type serviceFakeAdapter struct {
	mu           sync.Mutex
	records      map[string]*runtimev1.PreparedSandbox
	prepareCalls int
	releaseCalls int
}

func newServiceFakeAdapter() *serviceFakeAdapter {
	return &serviceFakeAdapter{records: make(map[string]*runtimev1.PreparedSandbox)}
}

func (a *serviceFakeAdapter) Prepare(_ context.Context, request *runtimev1.PrepareSandboxRequest, lease state.Lease) (*runtimev1.PreparedSandbox, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.prepareCalls++
	if prepared := a.records[request.GetSandboxId()]; prepared != nil {
		if prepared.GetGeneration() != request.GetGeneration() || prepared.GetLeaseId() != lease.LeaseID {
			return nil, errors.New("different fake lease already exists")
		}
		return prepared, nil
	}
	prepared := &runtimev1.PreparedSandbox{
		SandboxId: request.GetSandboxId(), Generation: request.GetGeneration(), LeaseId: lease.LeaseID,
		Assets: &runtimev1.RuntimeAssets{
			KernelPath: "/opt/cube/kernel", AgentPath: "/opt/cube/agent",
			GuestImagePath: "/opt/cube/guest", SharedRoot: "/data/cubelet/shared/" + request.GetSandboxId(),
		},
		Network: &runtimev1.NetworkAttachment{
			NetworkHandle: "network-" + request.GetSandboxId(), TapName: "cb123",
			GuestInterfaceName: "eth0", Mac: "02:00:00:00:00:01", Mtu: 1450,
			Ips: []string{"10.0.0.2/24"},
		},
	}
	a.records[request.GetSandboxId()] = prepared
	return prepared, nil
}

func (a *serviceFakeAdapter) Release(_ context.Context, request state.ReleaseRequest, networkHandle string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	prepared := a.records[request.SandboxID]
	if prepared == nil {
		return nil
	}
	if prepared.GetGeneration() != request.Generation || prepared.GetLeaseId() != request.LeaseID ||
		(networkHandle != "" && prepared.GetNetwork().GetNetworkHandle() != networkHandle) {
		return errors.New("fake release identity mismatch")
	}
	a.releaseCalls++
	delete(a.records, request.SandboxID)
	return nil
}

func (a *serviceFakeAdapter) Inspect(_ context.Context, sandboxID string, lease state.Lease) (*runtimev1.PreparedSandbox, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	prepared := a.records[sandboxID]
	if prepared == nil {
		return nil, os.ErrNotExist
	}
	if prepared.GetGeneration() != lease.Generation || prepared.GetLeaseId() != lease.LeaseID {
		return nil, errors.New("fake inspect identity mismatch")
	}
	return prepared, nil
}

func (a *serviceFakeAdapter) OpenTap(handoff.Binding) (*os.File, error) {
	return os.Open("/dev/null")
}

func serviceGenerator() state.ValueGenerator {
	next := 0
	return func() (string, error) {
		next++
		return fmt.Sprintf("service-value-%d", next), nil
	}
}

func serviceRequest(id string, generation uint64, key string) *runtimev1.PrepareSandboxRequest {
	return &runtimev1.PrepareSandboxRequest{
		SandboxId: id, Generation: generation, IdempotencyKey: key,
		Pod:       &runtimev1.PodIdentity{Uid: "uid-" + id, Namespace: "default", Name: "pod-" + id},
		Resources: &runtimev1.ResourceRequest{VcpuCount: 2, MemoryBytes: 512 * 1024 * 1024},
		Network:   &runtimev1.NetworkIntent{NetnsPath: "/run/netns/" + id, InterfaceName: "eth0", Dns: []string{"10.96.0.10"}},
	}
}

func newTestService(t *testing.T, store *state.Store, adapter Adapter) (*Service, *handoff.Registry) {
	t.Helper()
	service, registry, err := NewService(store, adapter, "/run/cube/runtime-fd.sock")
	if err != nil {
		t.Fatal(err)
	}
	return service, registry
}

func TestServicePrepareReleaseIsIdempotentAndLeaseScoped(t *testing.T) {
	ctx := context.Background()
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	adapter := newServiceFakeAdapter()
	service, registry := newTestService(t, store, adapter)

	capabilities, err := service.GetCapabilities(ctx, &runtimev1.GetCapabilitiesRequest{ClientApiVersion: APIVersion})
	if err != nil || capabilities.GetApiVersion() != APIVersion || capabilities.GetServiceMode() != ServiceMode || len(capabilities.GetCapabilities()) != 3 {
		t.Fatalf("capabilities=%+v err=%v", capabilities, err)
	}
	request := serviceRequest("sandbox-a", 1, "prepare-a")
	first, err := service.PrepareSandbox(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := service.PrepareSandbox(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	if second.GetReused() != true || first.GetSandbox().GetLeaseId() != second.GetSandbox().GetLeaseId() {
		t.Fatalf("prepare retry first=%+v second=%+v", first, second)
	}

	changed := serviceRequest("sandbox-a", 1, "prepare-a")
	changed.Resources.VcpuCount = 4
	if _, err := service.PrepareSandbox(ctx, changed); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("changed retry error=%v code=%s", err, status.Code(err))
	}

	prepared := first.GetSandbox()
	descriptor := prepared.GetNetwork().GetFdHandoff()
	file, code, err := registry.Acquire(&runtimev1.FDHandoffRequestV1{
		ProtocolVersion: handoff.ProtocolVersion, SandboxId: prepared.GetSandboxId(),
		Generation: prepared.GetGeneration(), LeaseId: prepared.GetLeaseId(),
		NetworkHandle: prepared.GetNetwork().GetNetworkHandle(), Token: descriptor.GetToken(),
	})
	if err != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK || file == nil {
		t.Fatalf("acquire=(%v,%s,%v)", file, code, err)
	}
	file.Close()

	release := &runtimev1.ReleaseSandboxRequest{
		SandboxId: prepared.GetSandboxId(), Generation: prepared.GetGeneration(),
		LeaseId: prepared.GetLeaseId(), IdempotencyKey: "release-a",
	}
	if _, err := service.ReleaseSandbox(ctx, release); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ReleaseSandbox(ctx, release); err != nil {
		t.Fatalf("release retry: %v", err)
	}
	if adapter.releaseCalls != 1 {
		t.Fatalf("adapter release calls=%d, want 1", adapter.releaseCalls)
	}
	inspection, err := service.InspectSandbox(ctx, &runtimev1.InspectSandboxRequest{SandboxId: "sandbox-a"})
	if err != nil || inspection.GetState() != runtimev1.SandboxResourceState_SANDBOX_RESOURCE_STATE_RELEASED {
		t.Fatalf("inspection=%+v err=%v", inspection, err)
	}
	if _, err := service.ReleaseSandbox(ctx, &runtimev1.ReleaseSandboxRequest{
		SandboxId: "sandbox-a", Generation: 1, LeaseId: "stale", IdempotencyKey: "release-stale",
	}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("stale release error=%v code=%s", err, status.Code(err))
	}
}

func TestServiceRecoverRepublishesReadyBeforeTraffic(t *testing.T) {
	ctx := context.Background()
	store, err := state.Open(t.TempDir(), serviceGenerator())
	if err != nil {
		t.Fatal(err)
	}
	adapter := newServiceFakeAdapter()
	first, _ := newTestService(t, store, adapter)
	response, err := first.PrepareSandbox(ctx, serviceRequest("sandbox-ready", 1, "prepare-ready"))
	if err != nil {
		t.Fatal(err)
	}

	restarted, registry := newTestService(t, store, adapter)
	if err := restarted.Recover(ctx); err != nil {
		t.Fatal(err)
	}
	prepared := response.GetSandbox()
	file, code, err := registry.Acquire(&runtimev1.FDHandoffRequestV1{
		ProtocolVersion: handoff.ProtocolVersion, SandboxId: prepared.GetSandboxId(),
		Generation: prepared.GetGeneration(), LeaseId: prepared.GetLeaseId(),
		NetworkHandle: prepared.GetNetwork().GetNetworkHandle(), Token: prepared.GetNetwork().GetFdHandoff().GetToken(),
	})
	if err != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK || file == nil {
		t.Fatalf("recovered acquire=(%v,%s,%v)", file, code, err)
	}
	file.Close()
}

func TestServiceRecoverCompletesPreparingAndReleasing(t *testing.T) {
	ctx := context.Background()
	t.Run("preparing", func(t *testing.T) {
		store, err := state.Open(t.TempDir(), serviceGenerator())
		if err != nil {
			t.Fatal(err)
		}
		adapter := newServiceFakeAdapter()
		request := serviceRequest("sandbox-preparing", 1, "prepare-preparing")
		digest, err := desiredDigest(request)
		if err != nil {
			t.Fatal(err)
		}
		result, err := store.Prepare(state.PrepareRequest{SandboxID: request.GetSandboxId(), Generation: 1, IdempotencyKey: request.GetIdempotencyKey(), PayloadDigest: digest})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := adapter.Prepare(ctx, request, result.Lease); err != nil {
			t.Fatal(err)
		}
		service, _ := newTestService(t, store, adapter)
		if err := service.Recover(ctx); err != nil {
			t.Fatal(err)
		}
		record, err := store.Inspect(request.GetSandboxId())
		if err != nil || record.Active != nil || adapter.releaseCalls != 1 {
			t.Fatalf("record=%+v releases=%d err=%v", record, adapter.releaseCalls, err)
		}
	})

	t.Run("releasing", func(t *testing.T) {
		store, err := state.Open(t.TempDir(), serviceGenerator())
		if err != nil {
			t.Fatal(err)
		}
		adapter := newServiceFakeAdapter()
		first, _ := newTestService(t, store, adapter)
		response, err := first.PrepareSandbox(ctx, serviceRequest("sandbox-releasing", 1, "prepare-releasing"))
		if err != nil {
			t.Fatal(err)
		}
		prepared := response.GetSandbox()
		release := state.ReleaseRequest{SandboxID: prepared.GetSandboxId(), Generation: 1, LeaseID: prepared.GetLeaseId(), IdempotencyKey: "release-restarting"}
		if _, err := store.BeginRelease(release); err != nil {
			t.Fatal(err)
		}
		restarted, _ := newTestService(t, store, adapter)
		if err := restarted.Recover(ctx); err != nil {
			t.Fatal(err)
		}
		record, err := store.Inspect(prepared.GetSandboxId())
		if err != nil || record.Active != nil || adapter.releaseCalls != 1 {
			t.Fatalf("record=%+v releases=%d err=%v", record, adapter.releaseCalls, err)
		}
	})
}
