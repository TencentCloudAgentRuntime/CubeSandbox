// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	runtimeservice "github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
)

type Assets struct {
	KernelPath     string
	AgentPath      string
	GuestImagePath string
	SharedRootBase string
}

type NetworkOps interface {
	Prepare(context.Context, string, string, string) (*runtimev1.NetworkAttachment, error)
	Release(context.Context, string, string, string) error
	Open(string, string) (*os.File, error)
}

type adapter struct {
	mu       sync.Mutex
	stateDir string
	assets   Assets
	network  NetworkOps
}

type diskRecord struct {
	SandboxID     string                       `json:"sandbox_id"`
	Generation    uint64                       `json:"generation"`
	LeaseID       string                       `json:"lease_id"`
	NetworkHandle string                       `json:"network_handle"`
	NetNSPath     string                       `json:"netns_path"`
	InterfaceName string                       `json:"interface_name"`
	TapName       string                       `json:"tap_name"`
	Assets        *runtimev1.RuntimeAssets     `json:"assets"`
	Network       *runtimev1.NetworkAttachment `json:"network"`
}

var _ runtimeservice.Adapter = (*adapter)(nil)

func newAdapter(stateDir string, assets Assets, network NetworkOps) (*adapter, error) {
	if stateDir == "" || network == nil {
		return nil, errors.New("runtime resource adapter state/network is empty")
	}
	for name, path := range map[string]string{"kernel": assets.KernelPath, "agent": assets.AgentPath, "guest image": assets.GuestImagePath} {
		if path == "" {
			return nil, fmt.Errorf("runtime resource %s path is empty", name)
		}
		if _, err := os.Stat(path); err != nil {
			return nil, fmt.Errorf("runtime resource %s %q: %w", name, path, err)
		}
	}
	if assets.SharedRootBase == "" {
		return nil, errors.New("runtime resource shared root is empty")
	}
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(assets.SharedRootBase, 0o711); err != nil {
		return nil, err
	}
	return &adapter{stateDir: stateDir, assets: assets, network: network}, nil
}

func (a *adapter) Prepare(ctx context.Context, request *runtimev1.PrepareSandboxRequest, lease state.Lease) (*runtimev1.PreparedSandbox, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if record, err := a.load(request.GetSandboxId()); err == nil {
		if record.Generation != request.GetGeneration() || record.LeaseID != lease.LeaseID {
			return nil, errors.New("sandbox already has a different runtime resource lease")
		}
		return preparedFromRecord(record), nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	tapName := nameFor("cb", request.GetSandboxId(), request.GetGeneration())
	sharedRoot := filepath.Join(a.assets.SharedRootBase, nameFor("sb-", request.GetSandboxId(), request.GetGeneration()))
	if err := os.MkdirAll(sharedRoot, 0o711); err != nil {
		return nil, err
	}
	network, err := a.network.Prepare(ctx, request.GetNetwork().GetNetnsPath(), request.GetNetwork().GetInterfaceName(), tapName)
	if err != nil {
		_ = a.network.Release(ctx, request.GetNetwork().GetNetnsPath(), request.GetNetwork().GetInterfaceName(), tapName)
		_ = os.RemoveAll(sharedRoot)
		return nil, err
	}
	handle := nameFor("net-", request.GetSandboxId()+lease.LeaseID, request.GetGeneration())
	network.NetworkHandle = handle
	network.TapName = tapName
	if network.GuestInterfaceName == "" {
		network.GuestInterfaceName = "eth0"
	}
	record := &diskRecord{
		SandboxID: request.GetSandboxId(), Generation: request.GetGeneration(), LeaseID: lease.LeaseID,
		NetworkHandle: handle, NetNSPath: request.GetNetwork().GetNetnsPath(), InterfaceName: request.GetNetwork().GetInterfaceName(), TapName: tapName,
		Assets:  &runtimev1.RuntimeAssets{KernelPath: a.assets.KernelPath, AgentPath: a.assets.AgentPath, GuestImagePath: a.assets.GuestImagePath, SharedRoot: sharedRoot},
		Network: network,
	}
	if err := a.persist(record); err != nil {
		_ = a.network.Release(ctx, record.NetNSPath, record.InterfaceName, record.TapName)
		_ = os.RemoveAll(sharedRoot)
		return nil, err
	}
	return preparedFromRecord(record), nil
}

func (a *adapter) Release(ctx context.Context, request state.ReleaseRequest, networkHandle string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	record, err := a.load(request.SandboxID)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if record.Generation != request.Generation || record.LeaseID != request.LeaseID {
		return errors.New("release does not match runtime resource record")
	}
	if networkHandle != "" && record.NetworkHandle != networkHandle {
		return errors.New("release network handle does not match runtime resource record")
	}
	if err := a.network.Release(ctx, record.NetNSPath, record.InterfaceName, record.TapName); err != nil {
		return err
	}
	if record.Assets != nil {
		if err := os.RemoveAll(record.Assets.GetSharedRoot()); err != nil {
			return err
		}
	}
	if err := os.Remove(a.path(request.SandboxID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return syncDir(a.stateDir)
}

func (a *adapter) Inspect(_ context.Context, sandboxID string, lease state.Lease) (*runtimev1.PreparedSandbox, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	record, err := a.load(sandboxID)
	if err != nil {
		return nil, err
	}
	if record.Generation != lease.Generation || record.LeaseID != lease.LeaseID {
		return nil, errors.New("runtime resource record does not match durable lease")
	}
	return preparedFromRecord(record), nil
}

func (a *adapter) OpenTap(binding handoff.Binding) (*os.File, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	record, err := a.load(binding.SandboxID)
	if err != nil {
		return nil, err
	}
	if record.Generation != binding.Generation || record.LeaseID != binding.LeaseID || record.NetworkHandle != binding.NetworkHandle {
		return nil, handoff.ErrStaleLease
	}
	return a.network.Open(record.NetNSPath, record.TapName)
}

func (a *adapter) load(sandboxID string) (*diskRecord, error) {
	data, err := os.ReadFile(a.path(sandboxID))
	if err != nil {
		return nil, err
	}
	record := new(diskRecord)
	if err := json.Unmarshal(data, record); err != nil {
		return nil, err
	}
	if record.SandboxID != sandboxID || record.Assets == nil || record.Network == nil {
		return nil, errors.New("invalid runtime resource adapter record")
	}
	return record, nil
}

func (a *adapter) persist(record *diskRecord) error {
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(a.stateDir, ".runtime-resource-*")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer os.Remove(name)
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, a.path(record.SandboxID)); err != nil {
		return err
	}
	return syncDir(a.stateDir)
}

func (a *adapter) path(sandboxID string) string {
	sum := sha256.Sum256([]byte(sandboxID))
	return filepath.Join(a.stateDir, hex.EncodeToString(sum[:])+".json")
}

func preparedFromRecord(record *diskRecord) *runtimev1.PreparedSandbox {
	return &runtimev1.PreparedSandbox{SandboxId: record.SandboxID, LeaseId: record.LeaseID, Generation: record.Generation, Assets: record.Assets, Network: record.Network}
}

func nameFor(prefix, identity string, generation uint64) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s:%d", identity, generation)))
	return prefix + hex.EncodeToString(sum[:])[:11]
}

func syncDir(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
