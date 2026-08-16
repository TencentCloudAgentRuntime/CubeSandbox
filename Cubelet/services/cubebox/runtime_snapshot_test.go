// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package cubebox

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	cubeboxv1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/cubebox/v1"
	errorcodev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/errorcode/v1"
)

func TestRuntimeCheckpointFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "network", "intent.json")
	require.NoError(t, writeRuntimeJSON(path, runtimeNetworkIntent{IP: "192.0.2.10"}))
	digest, size, err := digestRuntimePath(path)
	require.NoError(t, err)
	assert.Positive(t, size)
	assert.Regexp(t, `^sha256:[0-9a-f]{64}$`, digest)
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Contains(t, string(data), `"ip": "192.0.2.10"`)
}

func TestDigestRuntimeFilesCoversEveryVMStateFile(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"config.json", "metadata.json", "state.json"} {
		require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte(name), 0o600))
	}
	before, err := digestRuntimeFiles(dir, "config.json", "metadata.json", "state.json")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "config.json"), []byte("changed"), 0o600))
	after, err := digestRuntimeFiles(dir, "config.json", "metadata.json", "state.json")
	require.NoError(t, err)
	assert.NotEqual(t, before, after)
}

func TestRuntimeSnapshotFailure(t *testing.T) {
	rsp := runtimeSnapshotFailure(&cubeboxv1.SnapshotRuntimeResponse{Ret: &errorcodev1.Ret{}}, errorcodev1.ErrorCode_PreConditionFailed, "already exists")
	assert.Equal(t, errorcodev1.ErrorCode_PreConditionFailed, rsp.GetRet().GetRetCode())
	assert.Equal(t, "already exists", rsp.GetRet().GetRetMsg())
}
