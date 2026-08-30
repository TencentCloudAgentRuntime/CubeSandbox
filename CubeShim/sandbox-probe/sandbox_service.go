// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"sync"
	"time"

	sandboxapi "github.com/containerd/containerd/api/runtime/sandbox/v1"
	apitypes "github.com/containerd/containerd/api/types"
	"github.com/containerd/containerd/v2/pkg/shim"
	"github.com/containerd/containerd/v2/pkg/shutdown"
	"github.com/containerd/containerd/v2/plugins"
	"github.com/containerd/plugin"
	"github.com/containerd/plugin/registry"
	"github.com/containerd/ttrpc"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func init() {
	registry.Register(&plugin.Registration{
		Type:     plugins.TTRPCPlugin,
		ID:       "cube-s0-sandbox",
		Requires: []plugin.Type{plugins.InternalPlugin},
		InitFn: func(ic *plugin.InitContext) (any, error) {
			service, err := ic.GetByID(plugins.InternalPlugin, "shutdown")
			if err != nil {
				return nil, err
			}
			return newSandboxService(service.(shutdown.Service)), nil
		},
	})
}

var (
	_ shim.TTRPCService              = (*sandboxService)(nil)
	_ shim.TTRPCServerUnaryOptioner  = (*sandboxService)(nil)
	_ sandboxapi.TTRPCSandboxService = (*sandboxService)(nil)
)

type sandboxService struct {
	mu        sync.Mutex
	id        string
	state     string
	createdAt time.Time
	exitedAt  time.Time
	stopped   chan struct{}
	stopOnce  sync.Once
	shutdown  shutdown.Service
}

func newSandboxService(sd shutdown.Service) *sandboxService {
	return &sandboxService{
		state:    "SANDBOX_NOTREADY",
		stopped:  make(chan struct{}),
		shutdown: sd,
	}
}

func (s *sandboxService) RegisterTTRPC(server *ttrpc.Server) error {
	sandboxapi.RegisterTTRPCSandboxService(server, s)
	return nil
}

func (s *sandboxService) UnaryServerInterceptor() ttrpc.UnaryServerInterceptor {
	return func(ctx context.Context, unmarshal ttrpc.Unmarshaler, info *ttrpc.UnaryServerInfo, method ttrpc.Method) (any, error) {
		record("rpc.begin", map[string]any{"method": info.FullMethod})
		response, err := method(ctx, unmarshal)
		recordResult("rpc.end", map[string]any{"method": info.FullMethod}, err)
		return response, err
	}
}

func (s *sandboxService) CreateSandbox(_ context.Context, request *sandboxapi.CreateSandboxRequest) (*sandboxapi.CreateSandboxResponse, error) {
	if failpointEnabled("crash-create") {
		record("failpoint.crash-create", map[string]any{"sandbox_id": request.GetSandboxID()})
		os.Exit(86)
	}
	if failpointEnabled("fail-create") {
		err := fmt.Errorf("cube S0 failpoint: CreateSandbox")
		recordResult("failpoint.fail-create", map[string]any{"sandbox_id": request.GetSandboxID()}, err)
		return nil, err
	}
	if failpointEnabled("delay-create") {
		record("failpoint.delay-create", map[string]any{"sandbox_id": request.GetSandboxID()})
		time.Sleep(10 * time.Second)
	}
	now := time.Now().UTC()
	s.mu.Lock()
	s.id = request.GetSandboxID()
	s.state = "SANDBOX_NOTREADY"
	s.createdAt = now
	s.mu.Unlock()
	record("sandbox.create", map[string]any{
		"sandbox_id":       request.GetSandboxID(),
		"bundle_path":      request.GetBundlePath(),
		"netns_path":       request.GetNetnsPath(),
		"rootfs_mounts":    len(request.GetRootfs()),
		"annotation_count": len(request.GetAnnotations()),
	})
	return &sandboxapi.CreateSandboxResponse{}, nil
}

func (s *sandboxService) StartSandbox(_ context.Context, request *sandboxapi.StartSandboxRequest) (*sandboxapi.StartSandboxResponse, error) {
	if failpointEnabled("fail-start") {
		err := fmt.Errorf("cube S0 failpoint: StartSandbox")
		recordResult("failpoint.fail-start", map[string]any{"sandbox_id": request.GetSandboxID()}, err)
		return nil, err
	}
	s.mu.Lock()
	s.state = "SANDBOX_READY"
	createdAt := s.createdAt
	s.mu.Unlock()
	record("sandbox.start", map[string]any{"sandbox_id": request.GetSandboxID()})
	return &sandboxapi.StartSandboxResponse{
		Pid:       uint32(os.Getpid()),
		CreatedAt: timestamppb.New(createdAt),
	}, nil
}

func (s *sandboxService) Platform(_ context.Context, request *sandboxapi.PlatformRequest) (*sandboxapi.PlatformResponse, error) {
	record("sandbox.platform", map[string]any{"sandbox_id": request.GetSandboxID()})
	return &sandboxapi.PlatformResponse{Platform: &apitypes.Platform{
		OS:           runtime.GOOS,
		Architecture: runtime.GOARCH,
	}}, nil
}

func (s *sandboxService) StopSandbox(_ context.Context, request *sandboxapi.StopSandboxRequest) (*sandboxapi.StopSandboxResponse, error) {
	s.markStopped()
	record("sandbox.stop", map[string]any{
		"sandbox_id":   request.GetSandboxID(),
		"timeout_secs": request.GetTimeoutSecs(),
	})
	return &sandboxapi.StopSandboxResponse{}, nil
}

func (s *sandboxService) WaitSandbox(ctx context.Context, request *sandboxapi.WaitSandboxRequest) (*sandboxapi.WaitSandboxResponse, error) {
	record("sandbox.wait", map[string]any{"sandbox_id": request.GetSandboxID()})
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-s.stopped:
	}
	s.mu.Lock()
	exitedAt := s.exitedAt
	s.mu.Unlock()
	return &sandboxapi.WaitSandboxResponse{
		ExitStatus: 0,
		ExitedAt:   timestamppb.New(exitedAt),
	}, nil
}

func (s *sandboxService) SandboxStatus(_ context.Context, request *sandboxapi.SandboxStatusRequest) (*sandboxapi.SandboxStatusResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	record("sandbox.status", map[string]any{
		"sandbox_id": request.GetSandboxID(),
		"state":      s.state,
		"verbose":    request.GetVerbose(),
	})
	response := &sandboxapi.SandboxStatusResponse{
		SandboxID: s.id,
		Pid:       uint32(os.Getpid()),
		State:     s.state,
		CreatedAt: timestamppb.New(s.createdAt),
	}
	if !s.exitedAt.IsZero() {
		response.ExitedAt = timestamppb.New(s.exitedAt)
	}
	return response, nil
}

func (s *sandboxService) PingSandbox(_ context.Context, request *sandboxapi.PingRequest) (*sandboxapi.PingResponse, error) {
	record("sandbox.ping", map[string]any{"sandbox_id": request.GetSandboxID()})
	return &sandboxapi.PingResponse{}, nil
}

func (s *sandboxService) ShutdownSandbox(_ context.Context, request *sandboxapi.ShutdownSandboxRequest) (*sandboxapi.ShutdownSandboxResponse, error) {
	s.markStopped()
	record("sandbox.shutdown", map[string]any{"sandbox_id": request.GetSandboxID()})
	go s.shutdown.Shutdown()
	return &sandboxapi.ShutdownSandboxResponse{}, nil
}

func (s *sandboxService) SandboxMetrics(_ context.Context, request *sandboxapi.SandboxMetricsRequest) (*sandboxapi.SandboxMetricsResponse, error) {
	record("sandbox.metrics", map[string]any{"sandbox_id": request.GetSandboxID()})
	return &sandboxapi.SandboxMetricsResponse{Metrics: &apitypes.Metric{
		Timestamp: timestamppb.Now(),
	}}, nil
}

func (s *sandboxService) markStopped() {
	s.mu.Lock()
	s.state = "SANDBOX_NOTREADY"
	if s.exitedAt.IsZero() {
		s.exitedAt = time.Now().UTC()
	}
	s.mu.Unlock()
	s.stopOnce.Do(func() { close(s.stopped) })
}

func failpointEnabled(name string) bool {
	_, err := os.Stat("/run/cube-s0/" + name)
	return err == nil
}
