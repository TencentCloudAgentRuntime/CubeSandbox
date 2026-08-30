// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// cube-sandbox-probe is an explicitly opt-in S0 probe. It combines
// containerd's runc Task service with a minimal Sandbox service so the
// containerd 2.3 shim-sandbox call sequence can be measured before the same
// bootstrap and service registration support is ported to the Rust CubeShim.
package main

import (
	"context"
	"io"

	bootapi "github.com/containerd/containerd/api/runtime/bootstrap/v1"
	apitypes "github.com/containerd/containerd/api/types"
	_ "github.com/containerd/containerd/v2/cmd/containerd-shim-runc-v2/task/plugin"
	"github.com/containerd/containerd/v2/pkg/shim"
)

const runtimeName = "io.containerd.cube-s0.v1"

type tracedShim struct {
	inner shim.Shim
}

func (s tracedShim) Name() string {
	return runtimeName
}

func (s tracedShim) Start(ctx context.Context, params *bootapi.BootstrapParams) (*bootapi.BootstrapResult, error) {
	record("bootstrap.start", map[string]any{
		"instance_id": params.GetInstanceID(),
		"namespace":   params.GetNamespace(),
		"socket_dir":  params.GetSocketDir(),
	})
	result, err := s.inner.Start(ctx, params)
	fields := map[string]any{"instance_id": params.GetInstanceID()}
	if result != nil {
		fields["address"] = result.GetAddress()
		fields["protocol"] = result.GetProtocol()
		fields["version"] = result.GetVersion()
	}
	recordResult("bootstrap.started", fields, err)
	return result, err
}

func (s tracedShim) Stop(ctx context.Context, id string) (shim.StopStatus, error) {
	record("bootstrap.delete", map[string]any{"instance_id": id})
	status, err := s.inner.Stop(ctx, id)
	recordResult("bootstrap.deleted", map[string]any{
		"instance_id": id,
		"pid":         status.Pid,
		"exit_status": status.ExitStatus,
	}, err)
	return status, err
}

func (s tracedShim) Info(ctx context.Context, options io.Reader) (*apitypes.RuntimeInfo, error) {
	return s.inner.Info(ctx, options)
}

func main() {
	shim.RunShim(context.Background(), tracedShim{inner: newProbeManager()})
}
