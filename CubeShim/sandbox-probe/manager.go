// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	bootapi "github.com/containerd/containerd/api/runtime/bootstrap/v1"
	apitypes "github.com/containerd/containerd/api/types"
	"github.com/containerd/containerd/v2/defaults"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/shim"
	"github.com/containerd/containerd/v2/version"
	"github.com/containerd/errdefs"
)

type probeManager struct{}

func newProbeManager() shim.Shim {
	return probeManager{}
}

func (probeManager) Name() string {
	return runtimeName
}

type probeSocket struct {
	address  string
	listener *net.UnixListener
	file     *os.File
}

func (s *probeSocket) close() {
	if s.listener != nil {
		_ = s.listener.Close()
	}
	if s.file != nil {
		_ = s.file.Close()
	}
	_ = shim.RemoveSocket(s.address)
}

func newProbeSocket(ctx context.Context, root, containerdAddress, id string) (*probeSocket, error) {
	address, err := shim.CreateSocketAddress(ctx, root, containerdAddress, id, false)
	if err != nil {
		return nil, err
	}
	listener, err := shim.NewSocket(address)
	if err != nil {
		if !shim.SocketEaddrinuse(err) {
			return nil, fmt.Errorf("create shim socket: %w", err)
		}
		if shim.CanConnect(address) {
			return &probeSocket{address: address}, errdefs.ErrAlreadyExists
		}
		if err := shim.RemoveSocket(address); err != nil {
			return nil, fmt.Errorf("remove stale shim socket: %w", err)
		}
		listener, err = shim.NewSocket(address)
		if err != nil {
			return nil, fmt.Errorf("recreate shim socket: %w", err)
		}
	}
	socket := &probeSocket{address: address, listener: listener}
	file, err := listener.File()
	if err != nil {
		socket.close()
		return nil, err
	}
	socket.file = file
	return socket, nil
}

func newProbeCommand(ctx context.Context, id, containerdAddress string) (*exec.Cmd, error) {
	namespace, err := namespaces.NamespaceRequired(ctx)
	if err != nil {
		return nil, err
	}
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	command := exec.Command(self,
		"-namespace", namespace,
		"-id", id,
		"-address", containerdAddress,
	)
	command.Dir = cwd
	command.Env = append(os.Environ(), "GOMAXPROCS=4")
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return command, nil
}

func (probeManager) Start(ctx context.Context, params *bootapi.BootstrapParams) (_ *bootapi.BootstrapResult, retErr error) {
	id := params.GetInstanceID()
	command, err := newProbeCommand(ctx, id, params.GetContainerdGrpcAddress())
	if err != nil {
		return nil, err
	}
	socketDir := params.GetSocketDir()
	if socketDir == "" {
		socketDir = filepath.Join(defaults.DefaultStateDir, "s")
	}
	socket, err := newProbeSocket(ctx, socketDir, params.GetContainerdGrpcAddress(), id)
	if err != nil {
		if errdefs.IsAlreadyExists(err) {
			return &bootapi.BootstrapResult{
				Version:  3,
				Address:  socket.address,
				Protocol: "ttrpc",
			}, nil
		}
		return nil, err
	}
	defer func() {
		if retErr != nil {
			socket.close()
		}
	}()
	command.ExtraFiles = append(command.ExtraFiles, socket.file)
	if err := command.Start(); err != nil {
		return nil, err
	}
	defer func() {
		if retErr != nil {
			_ = command.Process.Kill()
		}
	}()
	go func() { _ = command.Wait() }()
	if err := shim.AdjustOOMScore(command.Process.Pid); err != nil {
		return nil, fmt.Errorf("adjust shim OOM score: %w", err)
	}
	return &bootapi.BootstrapResult{
		Version:  3,
		Address:  socket.address,
		Protocol: "ttrpc",
	}, nil
}

func (probeManager) Stop(_ context.Context, id string) (shim.StopStatus, error) {
	record("manager.stop", map[string]any{"instance_id": id})
	return shim.StopStatus{
		Pid:        0,
		ExitStatus: 0,
		ExitedAt:   time.Now().UTC(),
	}, nil
}

func (probeManager) Info(_ context.Context, _ io.Reader) (*apitypes.RuntimeInfo, error) {
	return &apitypes.RuntimeInfo{
		Name: runtimeName,
		Version: &apitypes.RuntimeVersion{
			Version:  version.Version,
			Revision: version.Revision,
		},
	}, nil
}
