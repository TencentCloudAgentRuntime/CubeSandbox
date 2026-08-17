package images

import (
	"os"
	"path/filepath"
	"testing"

	containerdimages "github.com/containerd/containerd/v2/core/images"
	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"

	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/constants"
)

func TestIsUidFilesDir(t *testing.T) {
	dir := t.TempDir()
	require.True(t, isUidFilesDir(dir))
	require.False(t, isUidFilesDir(filepath.Join(dir, "missing")))

	file := filepath.Join(dir, "file")
	require.NoError(t, os.WriteFile(file, nil, 0o600))
	require.False(t, isUidFilesDir(file))
}

func TestHasUidFilesReference(t *testing.T) {
	const path = "/uids/shared"
	imageList := []containerdimages.Image{{Labels: map[string]string{constants.LabelImageUidFiles: path}}}
	require.True(t, hasUidFilesReference(imageList, path))
	require.False(t, hasUidFilesReference(imageList, "/uids/other"))
}

func TestIsReadOnlyMount(t *testing.T) {
	require.False(t, isReadOnlyMount(t.TempDir()))
	require.True(t, isReadOnlyMountFlags(unix.ST_RDONLY))
	require.False(t, isReadOnlyMountFlags(0))
}
