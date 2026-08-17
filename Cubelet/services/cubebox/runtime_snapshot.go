// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package cubebox

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/tencentcloud/CubeSandbox/Cubelet/api/services/cubebox/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/api/services/errorcode/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/pathutil"
)

type runtimeCheckpoint struct {
	SchemaVersion int                     `json:"schema_version"`
	Type          string                  `json:"type"`
	Runtime       string                  `json:"runtime"`
	Memory        runtimeCheckpointFile   `json:"memory"`
	VMState       runtimeCheckpointFile   `json:"vm_state"`
	Network       runtimeCheckpointFile   `json:"network"`
	Compatibility runtimeCheckpointCompat `json:"compatibility"`
}

type runtimeCheckpointFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size,omitempty"`
	Digest string `json:"digest"`
}

type runtimeCheckpointCompat struct {
	Arch                   string `json:"arch"`
	KernelVersion          string `json:"kernel_version"`
	CloudHypervisorVersion string `json:"cloud_hypervisor_version"`
	GuestImageVersion      string `json:"guest_image_version"`
}

type runtimeSnapshotMetadata struct {
	KernelVersion string `json:"kernel_version"`
	ImageVersion  string `json:"image_version"`
	CHVersion     string `json:"ch_version"`
}

type runtimeNetworkIntent struct {
	IP string `json:"ip,omitempty"`
}

const runtimeControlJSONMaxBytes = 1 << 20

func (s *service) SnapshotRuntime(ctx context.Context, req *cubebox.SnapshotRuntimeRequest) (*cubebox.SnapshotRuntimeResponse, error) {
	rsp := &cubebox.SnapshotRuntimeResponse{
		RequestID:  req.GetRequestID(),
		SandboxID:  req.GetSandboxID(),
		StagingDir: filepath.Clean(req.GetStagingDir()),
		Ret:        &errorcode.Ret{RetCode: errorcode.ErrorCode_Success},
	}
	if strings.TrimSpace(req.GetSandboxID()) == "" {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_InvalidParamFormat, "sandboxID is required"), nil
	}
	if _, err := pathutil.ValidatePathUnderBase(DefaultSnapshotDir, rsp.StagingDir); err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_InvalidParamFormat, fmt.Sprintf("invalid staging_dir: %v", err)), nil
	}
	if _, err := os.Lstat(rsp.StagingDir); err == nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_PreConditionFailed, "staging_dir already exists"), nil
	} else if !os.IsNotExist(err) {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("check staging_dir: %v", err)), nil
	}

	unlock := s.sandboxLifecycleLocks.Lock(rsp.SandboxID)
	defer unlock()
	cb, err := s.cubeboxMgr.cubeboxManger.Get(ctx, rsp.SandboxID)
	if err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_PreConditionFailed, fmt.Sprintf("sandbox is not found: %v", err)), nil
	}
	spec, err := s.getCubeboxSnapshotSpec(ctx, rsp.SandboxID)
	if err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("get sandbox spec: %v", err)), nil
	}
	if len(spec.Resource) == 0 {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_InvalidParamFormat, "sandbox resource spec is empty"), nil
	}
	var resource ResourceSpec
	if err := json.Unmarshal(spec.Resource, &resource); err != nil || resource.CPU <= 0 || resource.Memory <= 0 {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_InvalidParamFormat, "invalid sandbox resource spec"), nil
	}

	if err := os.MkdirAll(filepath.Dir(rsp.StagingDir), 0o750); err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("create staging parent: %v", err)), nil
	}
	tmp, err := os.MkdirTemp(filepath.Dir(rsp.StagingDir), "."+filepath.Base(rsp.StagingDir)+".tmp-")
	if err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("create private staging directory: %v", err)), nil
	}
	defer os.RemoveAll(tmp) // NOCC:Path Traversal -- validated under the snapshot base above.
	memoryPath := filepath.Join(tmp, "memory", "memory.raw")
	if err := os.MkdirAll(filepath.Dir(memoryPath), 0o750); err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("create memory staging: %v", err)), nil
	}
	memory, err := os.OpenFile(memoryPath, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
	if err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("create memory file: %v", err)), nil
	}
	if err = memory.Truncate(int64(snapshotMemorySizeBytes(resource.Memory))); err == nil {
		err = memory.Close()
	} else {
		_ = memory.Close()
	}
	if err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("prepare memory file: %v", err)), nil
	}

	vmState := filepath.Join(tmp, "vm-state")
	if err := s.executeCubeRuntimeSnapshot(ctx, rsp.SandboxID, spec, vmState, memoryPath, snapshotTypeFull); err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, err.Error()), nil
	}
	for _, name := range []string{"config.json", "state.json"} {
		if err := os.Rename(filepath.Join(vmState, "snapshot", name), filepath.Join(vmState, name)); err != nil {
			return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("stage vm state %s: %v", name, err)), nil
		}
	}
	if err := os.Remove(filepath.Join(vmState, "snapshot")); err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("remove empty snapshot directory: %v", err)), nil
	}

	networkPath := filepath.Join(tmp, "network", "intent.json")
	if err := writeRuntimeJSON(networkPath, runtimeNetworkIntent{IP: cb.IP}); err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("write network intent: %v", err)), nil
	}
	memoryDigest, memorySize, err := digestRuntimePath(memoryPath)
	if err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, err.Error()), nil
	}
	stateDigest, err := digestRuntimeFiles(vmState, "config.json", "metadata.json", "state.json")
	if err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, err.Error()), nil
	}
	metadataData, err := readRuntimeControlJSON(filepath.Join(vmState, "metadata.json"))
	if err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("read runtime metadata: %v", err)), nil
	}
	if len(metadataData) == 0 {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_InvalidParamFormat, "runtime metadata is empty"), nil
	}
	var metadata runtimeSnapshotMetadata
	if err := json.Unmarshal(metadataData, &metadata); err != nil || metadata.KernelVersion == "" || metadata.ImageVersion == "" || metadata.CHVersion == "" {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_InvalidParamFormat, "invalid runtime metadata compatibility fields"), nil
	}
	networkDigest, _, err := digestRuntimePath(networkPath)
	if err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, err.Error()), nil
	}
	checkpoint := runtimeCheckpoint{
		SchemaVersion: 1,
		Type:          "cube-runtime",
		Runtime:       "cloud-hypervisor",
		Memory:        runtimeCheckpointFile{Path: "memory/memory.raw", Size: memorySize, Digest: memoryDigest},
		VMState:       runtimeCheckpointFile{Path: "vm-state", Digest: stateDigest},
		Network:       runtimeCheckpointFile{Path: "network/intent.json", Digest: networkDigest},
		Compatibility: runtimeCheckpointCompat{
			Arch: runtime.GOARCH, KernelVersion: metadata.KernelVersion,
			CloudHypervisorVersion: metadata.CHVersion, GuestImageVersion: metadata.ImageVersion,
		},
	}
	if err := writeRuntimeJSON(filepath.Join(tmp, "checkpoint.json"), checkpoint); err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("write checkpoint: %v", err)), nil
	}
	if err := os.Rename(tmp, rsp.StagingDir); err != nil {
		return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("publish staging directory: %v", err)), nil
	}
	if req.GetStopAfterSnapshot() {
		container, err := s.cubeboxMgr.client.LoadContainer(ctx, rsp.SandboxID)
		if err != nil {
			return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("snapshot published but load sandbox before stop failed: %v", err)), nil
		}
		if err := s.cubeboxMgr.stopTask(ctx, container); err != nil {
			return runtimeSnapshotFailure(rsp, errorcode.ErrorCode_Unknown, fmt.Sprintf("snapshot published but stop sandbox failed: %v", err)), nil
		}
	}
	return rsp, nil
}

func readRuntimeControlJSON(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > runtimeControlJSONMaxBytes {
		return nil, fmt.Errorf("runtime control file must be regular and no larger than %d bytes", runtimeControlJSONMaxBytes)
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, runtimeControlJSONMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > runtimeControlJSONMaxBytes {
		return nil, fmt.Errorf("runtime control file exceeds %d bytes", runtimeControlJSONMaxBytes)
	}
	return data, nil
}

func runtimeSnapshotFailure(rsp *cubebox.SnapshotRuntimeResponse, code errorcode.ErrorCode, message string) *cubebox.SnapshotRuntimeResponse {
	rsp.Ret.RetCode = code
	rsp.Ret.RetMsg = message
	return rsp
}

func writeRuntimeJSON(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(path, data, 0o600)
}

func digestRuntimePath(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, fmt.Errorf("open %s: %w", path, err)
	}
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, file)
	if err != nil {
		return "", 0, fmt.Errorf("digest %s: %w", path, err)
	}
	return "sha256:" + hex.EncodeToString(hash.Sum(nil)), size, nil
}

func digestRuntimeFiles(base string, names ...string) (string, error) {
	hash := sha256.New()
	for _, name := range names {
		if _, err := io.WriteString(hash, name+"\x00"); err != nil {
			return "", err
		}
		file, err := os.Open(filepath.Join(base, name))
		if err != nil {
			return "", fmt.Errorf("open runtime state %s: %w", name, err)
		}
		_, copyErr := io.Copy(hash, file)
		closeErr := file.Close()
		if copyErr != nil {
			return "", fmt.Errorf("digest runtime state %s: %w", name, copyErr)
		}
		if closeErr != nil {
			return "", closeErr
		}
	}
	return "sha256:" + hex.EncodeToString(hash.Sum(nil)), nil
}
