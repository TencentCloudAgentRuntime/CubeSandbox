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
	"golang.org/x/sys/unix"
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

type prepareStage string

const (
	stageIntent     prepareStage = "INTENT"
	stageSharedRoot prepareStage = "SHARED_ROOT"
	stagePrepared   prepareStage = "PREPARED"
)

type adapter struct {
	mu          sync.Mutex
	stateDir    string
	assets      Assets
	network     NetworkOps
	persistHook func(prepareStage, *diskRecord) error
	tapFiles    map[string]*os.File
}

type diskRecord struct {
	Stage         prepareStage                 `json:"stage"`
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

// NewNodeAdapter builds the production Linux RuntimeResource adapter used by
// Cubelet and by privileged end-to-end validation. The returned interface keeps
// the implementation details private while allowing a standalone service to
// exercise the exact asset, network, TAP, and cleanup path.
func NewNodeAdapter(stateDir string, assets Assets) (runtimeservice.Adapter, error) {
	return newAdapter(stateDir, assets, newLinuxNetwork())
}

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
	return &adapter{stateDir: stateDir, assets: assets, network: network, tapFiles: make(map[string]*os.File)}, nil
}

func (a *adapter) Prepare(ctx context.Context, request *runtimev1.PrepareSandboxRequest, lease state.Lease) (*runtimev1.PreparedSandbox, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if record, err := a.load(request.GetSandboxId()); err == nil {
		if record.Generation != request.GetGeneration() || record.LeaseID != lease.LeaseID {
			return nil, errors.New("sandbox already has a different runtime resource lease")
		}
		return a.resumePrepare(ctx, record)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	tapName := nameFor("cb", request.GetSandboxId(), request.GetGeneration())
	sharedRoot := filepath.Join(a.assets.SharedRootBase, nameFor("sb-", request.GetSandboxId(), request.GetGeneration()))
	handle := nameFor("net-", request.GetSandboxId()+lease.LeaseID, request.GetGeneration())
	record := &diskRecord{
		Stage: stageIntent, SandboxID: request.GetSandboxId(), Generation: request.GetGeneration(), LeaseID: lease.LeaseID,
		NetworkHandle: handle, NetNSPath: request.GetNetwork().GetNetnsPath(), InterfaceName: request.GetNetwork().GetInterfaceName(), TapName: tapName,
		Assets:  &runtimev1.RuntimeAssets{KernelPath: a.assets.KernelPath, AgentPath: a.assets.AgentPath, GuestImagePath: a.assets.GuestImagePath, SharedRoot: sharedRoot},
		Network: &runtimev1.NetworkAttachment{NetworkHandle: handle, TapName: tapName, GuestInterfaceName: "eth0"},
	}
	if err := a.persistStage(record, stageIntent); err != nil {
		return nil, err
	}
	return a.resumePrepare(ctx, record)
}

func (a *adapter) resumePrepare(ctx context.Context, record *diskRecord) (*runtimev1.PreparedSandbox, error) {
	switch record.Stage {
	case stageIntent:
		if err := os.MkdirAll(record.Assets.GetSharedRoot(), 0o711); err != nil {
			return nil, err
		}
		if err := a.persistStage(record, stageSharedRoot); err != nil {
			return nil, err
		}
		fallthrough
	case stageSharedRoot:
		network, err := a.network.Prepare(ctx, record.NetNSPath, record.InterfaceName, record.TapName)
		if err != nil {
			if rollbackErr := a.rollbackPreparing(ctx, record); rollbackErr != nil {
				return nil, fmt.Errorf("prepare network: %v; rollback: %v", err, rollbackErr)
			}
			return nil, err
		}
		if network == nil {
			err := errors.New("network adapter returned no attachment")
			if rollbackErr := a.rollbackPreparing(ctx, record); rollbackErr != nil {
				return nil, fmt.Errorf("%v; rollback: %v", err, rollbackErr)
			}
			return nil, err
		}
		network.NetworkHandle = record.NetworkHandle
		network.TapName = record.TapName
		if network.GuestInterfaceName == "" {
			network.GuestInterfaceName = "eth0"
		}
		record.Network = network
		if err := a.persistStage(record, stagePrepared); err != nil {
			return nil, err
		}
	case stagePrepared:
	default:
		return nil, fmt.Errorf("unsupported runtime resource prepare stage %q", record.Stage)
	}
	return preparedFromRecord(record), nil
}

func (a *adapter) rollbackPreparing(ctx context.Context, record *diskRecord) error {
	if file := a.tapFiles[record.SandboxID]; file != nil {
		if err := file.Close(); err != nil {
			return err
		}
		delete(a.tapFiles, record.SandboxID)
	}
	if err := a.network.Release(ctx, record.NetNSPath, record.InterfaceName, record.TapName); err != nil {
		return err
	}
	if err := os.RemoveAll(record.Assets.GetSharedRoot()); err != nil {
		return err
	}
	if err := os.Remove(a.path(record.SandboxID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return syncDir(a.stateDir)
}

func (a *adapter) persistStage(record *diskRecord, stage prepareStage) error {
	record.Stage = stage
	if a.persistHook != nil {
		if err := a.persistHook(stage, record); err != nil {
			return err
		}
	}
	return a.persist(record)
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
	if file := a.tapFiles[record.SandboxID]; file != nil {
		if err := file.Close(); err != nil {
			return err
		}
		delete(a.tapFiles, record.SandboxID)
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
	if record.Stage != stagePrepared || record.Generation != binding.Generation || record.LeaseID != binding.LeaseID || record.NetworkHandle != binding.NetworkHandle {
		return nil, handoff.ErrStaleLease
	}
	file := a.tapFiles[binding.SandboxID]
	if file == nil {
		file, err = a.network.Open(record.NetNSPath, record.TapName)
		if err != nil {
			return nil, err
		}
		a.tapFiles[binding.SandboxID] = file
	}
	descriptor, err := unix.FcntlInt(file.Fd(), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil {
		if a.tapFiles[binding.SandboxID] == file {
			_ = file.Close()
			delete(a.tapFiles, binding.SandboxID)
		}
		return nil, err
	}
	return os.NewFile(uintptr(descriptor), file.Name()), nil
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
	if record.Stage == "" {
		// Records created before staged WAL support were persisted only after all side effects.
		record.Stage = stagePrepared
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
