// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// s11-runtime-harness is a durable RuntimeResource test endpoint. It exists
// only for the S1.1 containerd/shim crash probes and is not a Cubelet daemon.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	runtimeservice "github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc"
)

type durableAdapter struct {
	mu       sync.Mutex
	dir      string
	marker   string
	assetDir string
}

func (a *durableAdapter) Prepare(_ context.Context, request *runtimev1.PrepareSandboxRequest, lease state.Lease) (*runtimev1.PreparedSandbox, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if prepared, err := a.load(request.GetSandboxId()); err == nil {
		if prepared.GetGeneration() != request.GetGeneration() || prepared.GetLeaseId() != lease.LeaseID {
			return nil, errors.New("durable adapter record belongs to another lease")
		}
		return prepared, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	prepared := &runtimev1.PreparedSandbox{
		SandboxId: request.GetSandboxId(), Generation: request.GetGeneration(), LeaseId: lease.LeaseID,
		Assets: &runtimev1.RuntimeAssets{
			KernelPath: filepath.Join(a.assetDir, "kernel"), AgentPath: filepath.Join(a.assetDir, "agent"),
			GuestImagePath: filepath.Join(a.assetDir, "guest.img"), SharedRoot: filepath.Join("/data/cubelet/s11-harness", request.GetSandboxId()),
		},
		Network: &runtimev1.NetworkAttachment{
			NetworkHandle: "network-" + request.GetSandboxId(), TapName: "cbharness",
			GuestInterfaceName: "eth0", Mac: "02:00:00:00:00:01", Mtu: 1450,
			Ips:       []string{"192.0.2.2/24"},
			Routes:    []*runtimev1.Route{{Destination: "0.0.0.0/0", Gateway: "192.0.2.1", Source: "192.0.2.2", Device: "eth0"}},
			Neighbors: []*runtimev1.Neighbor{{Ip: "192.0.2.1", Mac: "02:00:00:00:00:02", Device: "eth0"}},
		},
	}
	if err := a.persist(prepared); err != nil {
		return nil, err
	}
	return prepared, nil
}

func (a *durableAdapter) Release(_ context.Context, request state.ReleaseRequest, _ string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	prepared, err := a.load(request.SandboxID)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if prepared.GetGeneration() != request.Generation || prepared.GetLeaseId() != request.LeaseID {
		return errors.New("release identity does not match durable adapter record")
	}
	if err := os.Remove(a.path(request.SandboxID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := syncDir(a.dir); err != nil {
		return err
	}
	return os.WriteFile(a.marker, []byte(fmt.Sprintf("released %s %d %s\n", request.SandboxID, request.Generation, request.LeaseID)), 0o600)
}

func (a *durableAdapter) Inspect(_ context.Context, sandboxID string, lease state.Lease) (*runtimev1.PreparedSandbox, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	prepared, err := a.load(sandboxID)
	if err != nil {
		return nil, err
	}
	if prepared.GetGeneration() != lease.Generation || prepared.GetLeaseId() != lease.LeaseID {
		return nil, errors.New("inspect identity does not match durable adapter record")
	}
	return prepared, nil
}

func (*durableAdapter) OpenTap(handoff.Binding) (*os.File, error) { return os.Open("/dev/null") }

func (a *durableAdapter) path(sandboxID string) string {
	sum := sha256.Sum256([]byte(sandboxID))
	return filepath.Join(a.dir, hex.EncodeToString(sum[:])+".json")
}

func (a *durableAdapter) load(sandboxID string) (*runtimev1.PreparedSandbox, error) {
	data, err := os.ReadFile(a.path(sandboxID))
	if err != nil {
		return nil, err
	}
	prepared := new(runtimev1.PreparedSandbox)
	if err := json.Unmarshal(data, prepared); err != nil {
		return nil, err
	}
	if prepared.GetSandboxId() != sandboxID {
		return nil, errors.New("durable adapter sandbox identity mismatch")
	}
	return prepared, nil
}

func (a *durableAdapter) persist(prepared *runtimev1.PreparedSandbox) error {
	data, err := json.Marshal(prepared)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(a.dir, ".prepared-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, a.path(prepared.GetSandboxId())); err != nil {
		return err
	}
	return syncDir(a.dir)
}

func syncDir(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func main() {
	if len(os.Args) != 6 {
		panic("usage: s11-runtime-harness STATE_DIR GRPC_SOCKET FD_SOCKET RELEASE_MARKER ASSET_DIR")
	}
	stateDir, grpcPath, fdPath, marker, assetDir := os.Args[1], os.Args[2], os.Args[3], os.Args[4], os.Args[5]
	for _, directory := range []string{stateDir, filepath.Join(stateDir, "adapter"), filepath.Dir(grpcPath), filepath.Dir(fdPath), filepath.Dir(marker)} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			panic(err)
		}
	}
	store, err := state.Open(filepath.Join(stateDir, "leases"), nil)
	if err != nil {
		panic(err)
	}
	adapter := &durableAdapter{dir: filepath.Join(stateDir, "adapter"), marker: marker, assetDir: assetDir}
	service, registry, err := runtimeservice.NewService(store, adapter, fdPath)
	if err != nil {
		panic(err)
	}
	if err := service.Recover(context.Background()); err != nil {
		panic(err)
	}
	fdListener, err := handoff.Listen(fdPath, 0o660, registry, handoff.AuthorizePeerIDs(syscall.Ucred{Uid: uint32(os.Getuid()), Gid: uint32(os.Getgid())}))
	if err != nil {
		panic(err)
	}
	defer fdListener.Close()
	_ = os.Remove(grpcPath)
	listener, err := net.Listen("unix", grpcPath)
	if err != nil {
		panic(err)
	}
	server := grpc.NewServer()
	if err := runtimeservice.Register(server, service); err != nil {
		panic(err)
	}
	fmt.Printf("S11_RUNTIME_HARNESS_READY %s\n", grpcPath)
	if err := server.Serve(listener); err != nil {
		panic(err)
	}
}
