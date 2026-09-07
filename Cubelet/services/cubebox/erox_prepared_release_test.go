package cubebox

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestReleaseEROXPreparedRootFSUsesSandboxScopedRoot(t *testing.T) {
	original := runEROXPreparedRelease
	t.Cleanup(func() { runEROXPreparedRelease = original })
	var got string
	runEROXPreparedRelease = func(_ context.Context, root string) error {
		got = root
		return nil
	}

	require.NoError(t, releaseEROXPreparedRootFS(t.Context(), "sandbox-a", "/data/awv/snapshots/mounts"))
	require.Equal(t, filepath.Join("/data/awv/snapshots/mounts", "sandbox-a"), got)
	for _, invalidID := range []string{".", "..", "a/b", "/absolute"} {
		got = ""
		require.Error(t, releaseEROXPreparedRootFS(t.Context(), invalidID, "/data/awv/snapshots/mounts"))
		require.Empty(t, got, "release runner must not be called for %q", invalidID)
	}
}
