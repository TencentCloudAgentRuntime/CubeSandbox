package cubebox

import (
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/tencentcloud/CubeSandbox/Cubelet/storage"
)

func TestPluginWritableRootFSPath(t *testing.T) {
	info := &storage.StorageInfo{PluginVolumeBackendInfos: map[string]*storage.PluginVolumeBackendInfo{
		"rootfs":    {Driver: "block-device", HostPath: "/dev/nbd7"},
		"workspace": {Driver: "erox-workspace", HostPath: "/data/workspace"},
	}}

	path, ok := pluginWritableRootFSPath(info, "rootfs")
	require.True(t, ok)
	require.Equal(t, "/dev/nbd7", path)
	_, ok = pluginWritableRootFSPath(info, "workspace")
	require.False(t, ok)
}
