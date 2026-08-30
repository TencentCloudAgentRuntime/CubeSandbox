// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const (
	APIVersion          uint32 = 1
	ServiceMode                = "node-resources-only"
	CapabilityAssets           = "io.cubesandbox.runtime.assets"
	CapabilityNetwork          = "io.cubesandbox.runtime.network.tcfilter"
	CapabilityFDHandoff        = "io.cubesandbox.runtime.fd-handoff"
)

// Adapter owns only node-local assets and a CNI-netns attachment. It must not
// create containerd sandboxes, tasks, images, or snapshots. Prepare and Release
// are exact-lease idempotent; OpenTap returns a fresh caller-owned descriptor.
type Adapter interface {
	Prepare(context.Context, *runtimev1.PrepareSandboxRequest, state.Lease) (*runtimev1.PreparedSandbox, error)
	Release(context.Context, state.ReleaseRequest, string) error
	Inspect(context.Context, string, state.Lease) (*runtimev1.PreparedSandbox, error)
	OpenTap(handoff.Binding) (*os.File, error)
}

type Service struct {
	runtimev1.UnimplementedRuntimeResourceServer
	coordinator *Coordinator
	store       LifecycleStore
	adapter     Adapter
	fdEndpoint  string
}

func NewService(store LifecycleStore, adapter Adapter, fdEndpoint string) (*Service, *handoff.Registry, error) {
	if store == nil || adapter == nil {
		return nil, nil, errors.New("runtime resource store/adapter is nil")
	}
	if strings.TrimSpace(fdEndpoint) == "" {
		return nil, nil, errors.New("runtime resource FD endpoint is empty")
	}
	registry, err := handoff.NewRegistry(adapter.OpenTap)
	if err != nil {
		return nil, nil, err
	}
	coordinator, err := NewCoordinator(store, registry)
	if err != nil {
		return nil, nil, err
	}
	return &Service{coordinator: coordinator, store: store, adapter: adapter, fdEndpoint: fdEndpoint}, registry, nil
}

// Recover resolves every durable lease before either RuntimeResource RPC or FD
// traffic is accepted. READY is republished; interrupted prepare/release work is
// completed against the node adapter.
func (s *Service) Recover(ctx context.Context) error {
	ids, err := s.store.ListSandboxIDs()
	if err != nil {
		return err
	}
	for _, sandboxID := range ids {
		record, err := s.store.Inspect(sandboxID)
		if err != nil {
			return err
		}
		if record.Active == nil {
			if err := s.coordinator.RecoverSandbox(sandboxID); err != nil {
				return fmt.Errorf("recover released sandbox %s: %w", sandboxID, err)
			}
			continue
		}
		lease := *record.Active
		switch lease.Phase {
		case state.PhaseReady:
			if _, err := s.adapter.Inspect(ctx, sandboxID, lease); err != nil {
				return fmt.Errorf("recover READY resources for %s: %w", sandboxID, err)
			}
			if err := s.coordinator.RecoverSandbox(sandboxID); err != nil {
				return fmt.Errorf("republish READY sandbox %s: %w", sandboxID, err)
			}
		case state.PhasePreparing:
			prepared, inspectErr := s.adapter.Inspect(ctx, sandboxID, lease)
			if inspectErr != nil && !errors.Is(inspectErr, os.ErrNotExist) {
				return fmt.Errorf("inspect PREPARING resources for %s: %w", sandboxID, inspectErr)
			}
			if inspectErr == nil {
				if err := s.adapter.Release(ctx, state.ReleaseRequest{
					SandboxID: sandboxID, Generation: lease.Generation, LeaseID: lease.LeaseID,
				}, networkHandle(prepared)); err != nil {
					return fmt.Errorf("rollback PREPARING resources for %s: %w", sandboxID, err)
				}
			}
			if err := s.coordinator.AbandonPrepare(sandboxID, lease.Generation, lease.LeaseID); err != nil {
				return fmt.Errorf("tombstone PREPARING sandbox %s: %w", sandboxID, err)
			}
		case state.PhaseReleasing:
			release := state.ReleaseRequest{
				SandboxID: sandboxID, Generation: lease.Generation, LeaseID: lease.LeaseID,
				IdempotencyKey: lease.ReleaseKey,
			}
			if err := s.coordinator.RecoverSandbox(sandboxID); err != nil {
				return fmt.Errorf("recover RELEASING fence for %s: %w", sandboxID, err)
			}
			if err := s.adapter.Release(ctx, release, lease.NetworkHandle); err != nil {
				return fmt.Errorf("finish RELEASING resources for %s: %w", sandboxID, err)
			}
			if err := s.coordinator.CompleteRelease(release); err != nil {
				return fmt.Errorf("tombstone RELEASING sandbox %s: %w", sandboxID, err)
			}
		default:
			return fmt.Errorf("sandbox %s has unsupported phase %q", sandboxID, lease.Phase)
		}
	}
	return nil
}

func (s *Service) GetCapabilities(_ context.Context, request *runtimev1.GetCapabilitiesRequest) (*runtimev1.GetCapabilitiesResponse, error) {
	if request == nil || request.GetClientApiVersion() == 0 {
		return nil, status.Error(codes.InvalidArgument, "client_api_version must be non-zero")
	}
	if request.GetClientApiVersion() != APIVersion {
		return nil, status.Errorf(codes.FailedPrecondition, "unsupported client api version %d; server supports %d", request.GetClientApiVersion(), APIVersion)
	}
	return &runtimev1.GetCapabilitiesResponse{
		ApiVersion: APIVersion,
		Capabilities: []*runtimev1.Capability{
			{Name: CapabilityAssets, Version: 1},
			{Name: CapabilityNetwork, Version: 1},
			{Name: CapabilityFDHandoff, Version: handoff.ProtocolVersion},
		},
		ServiceMode:       ServiceMode,
		FdHandoffEndpoint: s.fdEndpoint,
	}, nil
}

func (s *Service) PrepareSandbox(ctx context.Context, request *runtimev1.PrepareSandboxRequest) (*runtimev1.PrepareSandboxResponse, error) {
	if err := validatePrepare(request); err != nil {
		return nil, err
	}
	digest, err := desiredDigest(request)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	result, err := s.coordinator.Prepare(state.PrepareRequest{
		SandboxID: request.GetSandboxId(), Generation: request.GetGeneration(),
		IdempotencyKey: request.GetIdempotencyKey(), PayloadDigest: digest,
	})
	if err != nil {
		return nil, err
	}

	prepared, err := s.adapter.Prepare(ctx, request, result.Lease)
	if err != nil {
		if result.Lease.Phase == state.PhasePreparing {
			rollbackErr := s.adapter.Release(ctx, state.ReleaseRequest{
				SandboxID: request.GetSandboxId(), Generation: request.GetGeneration(), LeaseID: result.Lease.LeaseID,
			}, result.Lease.NetworkHandle)
			if rollbackErr == nil {
				rollbackErr = s.coordinator.AbandonPrepare(request.GetSandboxId(), request.GetGeneration(), result.Lease.LeaseID)
			}
			if rollbackErr != nil {
				return nil, status.Errorf(codes.Internal, "prepare resources: %v; rollback: %v", err, rollbackErr)
			}
		}
		return nil, status.Errorf(codes.Internal, "prepare resources: %v", err)
	}
	if err := validatePrepared(request, prepared); err != nil {
		if result.Lease.Phase == state.PhasePreparing {
			_ = s.adapter.Release(ctx, state.ReleaseRequest{
				SandboxID: request.GetSandboxId(), Generation: request.GetGeneration(), LeaseID: result.Lease.LeaseID,
			}, networkHandle(prepared))
			_ = s.coordinator.AbandonPrepare(request.GetSandboxId(), request.GetGeneration(), result.Lease.LeaseID)
		}
		return nil, status.Error(codes.Internal, err.Error())
	}
	lease, err := s.coordinator.MarkReadyAndPublish(request.GetSandboxId(), request.GetGeneration(), result.Lease.LeaseID, prepared.GetNetwork().GetNetworkHandle())
	if err != nil {
		return nil, err
	}
	bindPrepared(prepared, request.GetSandboxId(), request.GetGeneration(), lease, s.fdEndpoint)
	return &runtimev1.PrepareSandboxResponse{Sandbox: prepared, Reused: result.Reused}, nil
}

func (s *Service) ReleaseSandbox(ctx context.Context, request *runtimev1.ReleaseSandboxRequest) (*runtimev1.ReleaseSandboxResponse, error) {
	if request == nil || request.GetSandboxId() == "" || request.GetLeaseId() == "" || request.GetGeneration() == 0 || request.GetIdempotencyKey() == "" {
		return nil, status.Error(codes.InvalidArgument, "release fields must be non-zero")
	}
	release := state.ReleaseRequest{SandboxID: request.GetSandboxId(), Generation: request.GetGeneration(), LeaseID: request.GetLeaseId(), IdempotencyKey: request.GetIdempotencyKey()}
	before, inspectErr := s.store.Inspect(request.GetSandboxId())
	result, err := s.coordinator.BeginReleaseAndFence(release)
	if err != nil {
		return nil, err
	}
	if inspectErr == nil && before.Active == nil {
		return &runtimev1.ReleaseSandboxResponse{Released: true}, nil
	}
	if err := s.adapter.Release(ctx, release, result.Lease.NetworkHandle); err != nil {
		return nil, status.Errorf(codes.Internal, "release node resources: %v", err)
	}
	if err := s.coordinator.CompleteRelease(release); err != nil {
		return nil, err
	}
	return &runtimev1.ReleaseSandboxResponse{Released: true}, nil
}

func (s *Service) InspectSandbox(ctx context.Context, request *runtimev1.InspectSandboxRequest) (*runtimev1.InspectSandboxResponse, error) {
	if request == nil || request.GetSandboxId() == "" {
		return nil, status.Error(codes.InvalidArgument, "sandbox_id is empty")
	}
	record, err := s.store.Inspect(request.GetSandboxId())
	if status.Code(err) == codes.NotFound {
		return &runtimev1.InspectSandboxResponse{}, nil
	}
	if err != nil {
		return nil, err
	}
	response := &runtimev1.InspectSandboxResponse{Found: true}
	if record.Active == nil {
		response.State = runtimev1.SandboxResourceState_SANDBOX_RESOURCE_STATE_RELEASED
		return response, nil
	}
	switch record.Active.Phase {
	case state.PhasePreparing:
		response.State = runtimev1.SandboxResourceState_SANDBOX_RESOURCE_STATE_PREPARING
	case state.PhaseReady:
		response.State = runtimev1.SandboxResourceState_SANDBOX_RESOURCE_STATE_READY
	case state.PhaseReleasing:
		response.State = runtimev1.SandboxResourceState_SANDBOX_RESOURCE_STATE_RELEASING
	default:
		response.State = runtimev1.SandboxResourceState_SANDBOX_RESOURCE_STATE_ERROR
	}
	prepared, adapterErr := s.adapter.Inspect(ctx, request.GetSandboxId(), *record.Active)
	if adapterErr != nil {
		response.LastError = adapterErr.Error()
		return response, nil
	}
	bindPrepared(prepared, request.GetSandboxId(), record.Active.Generation, record.Active, s.fdEndpoint)
	response.Sandbox = prepared
	return response, nil
}

func (s *Service) ReconcileSandboxes(ctx context.Context, request *runtimev1.ReconcileSandboxesRequest) (*runtimev1.ReconcileSandboxesResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "reconcile request is nil")
	}
	ids := append([]string(nil), request.GetLiveSandboxIds()...)
	sort.Strings(ids)
	response := &runtimev1.ReconcileSandboxesResponse{}
	for _, id := range ids {
		if id == "" {
			return nil, status.Error(codes.InvalidArgument, "live sandbox id is empty")
		}
		record, err := s.store.Inspect(id)
		entry := &runtimev1.ReconcileEntry{SandboxId: id}
		if status.Code(err) == codes.NotFound {
			entry.Disposition = runtimev1.ReconcileDisposition_RECONCILE_DISPOSITION_MISSING
			entry.Detail = "no durable RuntimeResource lease"
		} else if err != nil {
			return nil, err
		} else {
			entry.Disposition = runtimev1.ReconcileDisposition_RECONCILE_DISPOSITION_LIVE
			if record.Active != nil {
				entry.Generation = record.Active.Generation
			}
		}
		response.Entries = append(response.Entries, entry)
	}
	return response, nil
}

func validatePrepare(request *runtimev1.PrepareSandboxRequest) error {
	if request == nil || request.GetSandboxId() == "" || request.GetIdempotencyKey() == "" || request.GetGeneration() == 0 || request.GetPod() == nil || request.GetResources() == nil || request.GetNetwork() == nil {
		return status.Error(codes.InvalidArgument, "prepare identity, pod, resources, and network must be non-zero")
	}
	if request.GetPod().GetUid() == "" || request.GetResources().GetVcpuCount() == 0 || request.GetResources().GetMemoryBytes() == 0 || request.GetNetwork().GetNetnsPath() == "" || request.GetNetwork().GetInterfaceName() == "" {
		return status.Error(codes.InvalidArgument, "prepare pod/resource/network fields must be non-zero")
	}
	if !strings.HasPrefix(request.GetNetwork().GetNetnsPath(), "/") {
		return status.Error(codes.InvalidArgument, "network netns_path must be absolute")
	}
	return nil
}

func desiredDigest(request *runtimev1.PrepareSandboxRequest) (string, error) {
	desired := &runtimev1.PrepareSandboxRequest{SandboxId: request.GetSandboxId(), Generation: request.GetGeneration(), Pod: request.GetPod(), Resources: request.GetResources(), Network: request.GetNetwork()}
	wire, err := proto.MarshalOptions{Deterministic: true}.Marshal(desired)
	if err != nil {
		return "", fmt.Errorf("encode normalized desired state: %w", err)
	}
	sum := sha256.Sum256(wire)
	return hex.EncodeToString(sum[:]), nil
}

func validatePrepared(request *runtimev1.PrepareSandboxRequest, prepared *runtimev1.PreparedSandbox) error {
	if prepared == nil || prepared.GetAssets() == nil || prepared.GetNetwork() == nil {
		return errors.New("resource adapter returned incomplete sandbox")
	}
	network := prepared.GetNetwork()
	if prepared.GetSandboxId() != request.GetSandboxId() || prepared.GetGeneration() != request.GetGeneration() || network.GetNetworkHandle() == "" || network.GetTapName() == "" {
		return errors.New("resource adapter returned mismatched sandbox/network identity")
	}
	if network.GetGuestInterfaceName() == "" || network.GetMac() == "" || network.GetMtu() == 0 || len(network.GetIps()) == 0 {
		return errors.New("resource adapter returned incomplete network attachment")
	}
	assets := prepared.GetAssets()
	if assets.GetKernelPath() == "" || assets.GetAgentPath() == "" || assets.GetGuestImagePath() == "" || assets.GetSharedRoot() == "" {
		return errors.New("resource adapter returned incomplete runtime assets")
	}
	return nil
}

func bindPrepared(prepared *runtimev1.PreparedSandbox, sandboxID string, generation uint64, lease *state.Lease, endpoint string) {
	prepared.SandboxId = sandboxID
	prepared.Generation = generation
	prepared.LeaseId = lease.LeaseID
	prepared.Network.FdHandoff = &runtimev1.FDHandoffDescriptor{ProtocolVersion: handoff.ProtocolVersion, Endpoint: endpoint, Token: lease.HandoffToken}
}

func networkHandle(prepared *runtimev1.PreparedSandbox) string {
	if prepared == nil || prepared.GetNetwork() == nil {
		return ""
	}
	return prepared.GetNetwork().GetNetworkHandle()
}
