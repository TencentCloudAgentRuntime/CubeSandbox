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
