package cubeboxcbri

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/constants"
)

func TestPreparedSnapshotRestoreAnnotations(t *testing.T) {
	mountRoot, base, memory, image := preparedRestorePaths(t)
	input := map[string]string{
		constants.AnnotationAppSnapshotRestore:            "true",
		constants.AnnotationVMSnapshotPath:                base,
		constants.AnnotationVMSnapshotMemoryVolURL:        "file://" + memory,
		constants.AnnotationAppSnapshotContainerID:        "sandbox-1",
		constants.MasterAnnotationRuntimeRestoreSandboxID: "sandbox-1",
	}

	got, ok, err := preparedSnapshotRestoreAnnotationsUnder(input, "sandbox-1", []string{image}, mountRoot)
	require.NoError(t, err)
	require.True(t, ok)
	require.Equal(t, input[constants.AnnotationVMSnapshotPath], got[constants.AnnotationVMSnapshotPath])
	require.Equal(t, input[constants.AnnotationVMSnapshotMemoryVolURL], got[constants.AnnotationVMSnapshotMemoryVolURL])
	require.Equal(t, input[constants.AnnotationAppSnapshotContainerID], got[constants.AnnotationAppSnapshotContainerID])
}

func TestPreparedSnapshotRestoreAnnotationsRejectsPartialHandle(t *testing.T) {
	_, ok, err := preparedSnapshotRestoreAnnotations(map[string]string{
		constants.AnnotationAppSnapshotRestore: "true",
		constants.AnnotationVMSnapshotPath:     "/data/awv/runtime",
	}, "", nil)
	require.Error(t, err)
	require.False(t, ok)
}

func TestPreparedSnapshotRestoreAnnotationsIgnoresOrdinaryCreate(t *testing.T) {
	got, ok, err := preparedSnapshotRestoreAnnotations(nil, "", nil)
	require.NoError(t, err)
	require.False(t, ok)
	require.Nil(t, got)
}

func TestPreparedSnapshotRestoreAnnotationsIgnoresOrdinaryMultiContainerPreparedRootFS(t *testing.T) {
	got, ok, err := preparedSnapshotRestoreAnnotations(nil, "", []string{"/prepared/one", "/prepared/two"})
	require.NoError(t, err)
	require.False(t, ok)
	require.Nil(t, got)
}

func TestPreparedSnapshotRestoreAnnotationsRejectsPathOutsideSandbox(t *testing.T) {
	_, ok, err := preparedSnapshotRestoreAnnotations(map[string]string{
		constants.AnnotationAppSnapshotRestore:            "true",
		constants.AnnotationVMSnapshotPath:                "/etc",
		constants.AnnotationVMSnapshotMemoryVolURL:        "file:///data/awv/snapshots/mounts/sandbox-1/memory/memory.raw",
		constants.AnnotationAppSnapshotContainerID:        "sandbox-1",
		constants.MasterAnnotationRuntimeRestoreSandboxID: "sandbox-1",
	}, "sandbox-1", []string{"/data/awv/snapshots/mounts/sandbox-1/image/image"})
	require.Error(t, err)
	require.False(t, ok)
}

func TestPreparedSnapshotRestoreAnnotationsLeavesTemplateRestoreAlone(t *testing.T) {
	got, ok, err := preparedSnapshotRestoreAnnotations(map[string]string{
		constants.AnnotationAppSnapshotRestore:          "true",
		constants.AnnotationVMSnapshotMemoryVolURL:      "file:///data/awv/template-memory.raw",
		constants.MasterAnnotationAppSnapshotTemplateID: "template-1",
	}, "", nil)
	require.NoError(t, err)
	require.False(t, ok)
	require.Nil(t, got)
}

func TestPreparedSnapshotRestoreAnnotationsRejectsMismatchedIdentity(t *testing.T) {
	mountRoot, base, memory, image := preparedRestorePaths(t)
	_, ok, err := preparedSnapshotRestoreAnnotationsUnder(map[string]string{
		constants.AnnotationAppSnapshotRestore:            "true",
		constants.AnnotationVMSnapshotPath:                base,
		constants.AnnotationVMSnapshotMemoryVolURL:        "file://" + memory,
		constants.AnnotationAppSnapshotContainerID:        "container-2",
		constants.MasterAnnotationRuntimeRestoreSandboxID: "sandbox-1",
	}, "container-2", []string{image}, mountRoot)
	require.Error(t, err)
	require.False(t, ok)
}

func TestPreparedSnapshotRestoreAnnotationsRejectsOtherPreparedContainer(t *testing.T) {
	mountRoot, base, memory, image := preparedRestorePaths(t)
	_, ok, err := preparedSnapshotRestoreAnnotationsUnder(map[string]string{
		constants.AnnotationAppSnapshotRestore:            "true",
		constants.AnnotationVMSnapshotPath:                base,
		constants.AnnotationVMSnapshotMemoryVolURL:        "file://" + memory,
		constants.AnnotationAppSnapshotContainerID:        "sandbox-1",
		constants.MasterAnnotationRuntimeRestoreSandboxID: "sandbox-1",
	}, "sidecar", []string{image}, mountRoot)
	require.Error(t, err)
	require.False(t, ok)
}

func TestPreparedSnapshotRestoreAnnotationsRejectsSymlinkEscape(t *testing.T) {
	mountRoot, base, memory, image := preparedRestorePaths(t)
	outside := t.TempDir()
	escape := filepath.Join(mountRoot, "sandbox-1", "escape")
	require.NoError(t, os.Symlink(outside, escape))
	_, ok, err := preparedSnapshotRestoreAnnotationsUnder(map[string]string{
		constants.AnnotationAppSnapshotRestore:            "true",
		constants.AnnotationVMSnapshotPath:                base,
		constants.AnnotationVMSnapshotMemoryVolURL:        "file://" + memory,
		constants.AnnotationAppSnapshotContainerID:        "sandbox-1",
		constants.MasterAnnotationRuntimeRestoreSandboxID: "sandbox-1",
	}, "sandbox-1", []string{image, escape}, mountRoot)
	require.Error(t, err)
	require.False(t, ok)
}

func preparedRestorePaths(t *testing.T) (mountRoot, base, memory, image string) {
	t.Helper()
	mountRoot = t.TempDir()
	sandboxRoot := filepath.Join(mountRoot, "sandbox-1")
	base = filepath.Join(sandboxRoot, "cube-runtime")
	memory = filepath.Join(sandboxRoot, "memory", "memory.raw")
	image = filepath.Join(sandboxRoot, "image", "image")
	for _, path := range []string{base, memory, image} {
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
		require.NoError(t, os.WriteFile(path, nil, 0o600))
	}
	return mountRoot, base, memory, image
}
