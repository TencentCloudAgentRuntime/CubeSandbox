package images

import (
	"testing"

	cubebox "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/cubebox/v1"
)

func TestRequiresImageEnsure(t *testing.T) {
	tests := []struct {
		name      string
		container *cubebox.ContainerConfig
		want      bool
	}{
		{name: "nil container", want: false},
		{name: "ordinary image", container: &cubebox.ContainerConfig{}, want: true},
		{
			name: "prepared EROFS rootfs",
			container: &cubebox.ContainerConfig{PreparedRootfs: &cubebox.PreparedRootFS{
				ImageMount: "/data/cubelet/erox/image/mount",
			}},
			want: false,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := requiresImageEnsure(test.container); got != test.want {
				t.Fatalf("requiresImageEnsure() = %t, want %t", got, test.want)
			}
		})
	}
}
