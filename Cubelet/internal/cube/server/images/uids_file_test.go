package images

import (
	"testing"

	"github.com/stretchr/testify/require"
	"golang.org/x/sys/unix"
)

func TestIsReadOnlyMount(t *testing.T) {
	require.False(t, isReadOnlyMount(t.TempDir()))
	require.True(t, isReadOnlyMountFlags(unix.ST_RDONLY))
	require.False(t, isReadOnlyMountFlags(0))
}
