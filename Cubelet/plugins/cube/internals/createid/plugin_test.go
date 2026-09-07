// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package createid

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	cubeboxv1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/cubebox/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/constants"
	"github.com/tencentcloud/CubeSandbox/Cubelet/plugins/workflow"
)

func TestCreateUsesRuntimeRestoreSandboxID(t *testing.T) {
	opts := &workflow.CreateContext{ReqInfo: &cubeboxv1.RunCubeSandboxRequest{Annotations: map[string]string{
		constants.AnnotationAppSnapshotRestore:            "true",
		constants.MasterAnnotationRuntimeRestoreSandboxID: "source-sandbox",
	}}}
	require.NoError(t, (&local{}).Create(context.Background(), opts))
	assert.Equal(t, "source-sandbox", opts.SandboxID)
}

func TestCreateRejectsRuntimeRestoreSandboxIDWithoutRestore(t *testing.T) {
	opts := &workflow.CreateContext{ReqInfo: &cubeboxv1.RunCubeSandboxRequest{Annotations: map[string]string{
		constants.MasterAnnotationRuntimeRestoreSandboxID: "source-sandbox",
	}}}
	assert.Error(t, (&local{}).Create(context.Background(), opts))
}

func TestCreateValidatesDesiredSandboxID(t *testing.T) {
	for _, test := range []struct {
		name    string
		id      string
		wantErr bool
	}{
		{name: "valid", id: "sandbox-a"},
		{name: "current directory", id: ".", wantErr: true},
		{name: "parent directory", id: "..", wantErr: true},
		{name: "nested path", id: "sandbox/a", wantErr: true},
		{name: "absolute path", id: "/sandbox-a", wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			opts := &workflow.CreateContext{ReqInfo: &cubeboxv1.RunCubeSandboxRequest{Annotations: map[string]string{
				constants.MasterAnnotationDesiredSandboxID: test.id,
			}}}
			err := (&local{}).Create(context.Background(), opts)
			if test.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, test.id, opts.SandboxID)
		})
	}
}
