package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func testResolveAWV(string) (string, error) { return "/dev/nbd7", nil }

type commandCall struct {
	env  []string
	args []string
}

type recordingRunner struct {
	calls         []commandCall
	prepareOutput []byte
	statusPhase   string
	errors        map[string]error
}

func (r *recordingRunner) run(env []string, args ...string) ([]byte, error) {
	r.calls = append(r.calls, commandCall{env: append([]string(nil), env...), args: append([]string(nil), args...)})
	if len(args) > 0 && r.errors[args[0]] != nil {
		return nil, r.errors[args[0]]
	}
	if len(args) > 0 && args[0] == "workspace-prepare" {
		if r.prepareOutput != nil {
			return r.prepareOutput, nil
		}
		var root, workspaceID string
		for i := 1; i+1 < len(args); i += 2 {
			switch args[i] {
			case "--root":
				root = args[i+1]
			case "--workspace-id":
				workspaceID = args[i+1]
			}
		}
		return []byte(`{"workspace_id":"` + workspaceID + `","phase":"prepared","merged_dir":"` + root + `/workspaces/` + workspaceID + `/merged"}`), nil
	}
	if len(args) > 0 && args[0] == "workspace-status" {
		phase := r.statusPhase
		if phase == "" {
			phase = "prepared"
		}
		return []byte(`{"workspace_id":"workspace-1","phase":"` + phase + `"}`), nil
	}
	return []byte("ok"), nil
}

func TestAttachUnmountsAWVWhenEROXReturnsInvalidStatus(t *testing.T) {
	base := t.TempDir()
	var unmounted string
	ops := mountOps{
		mount:   func(string, string, string, uintptr, string) error { return nil },
		unmount: func(path string, _ int) error { unmounted = path; return nil },
	}
	err := run([]string{
		"--op", "attach",
		"--volume-id", "workspace-1",
		"--volume-base-dir", base,
		"--private-data", `{"upper_volume_id":"awv-1","checkpoint_ref":"sha256:base"}`,
	}, &bytes.Buffer{}, testResolveAWV, func(string) error { return nil }, ops, &recordingRunner{prepareOutput: []byte("invalid")})
	if err == nil {
		t.Fatal("run accepted invalid EROX status")
	}
	if unmounted != base+"/workspace-1" {
		t.Fatalf("unmounted = %q", unmounted)
	}
}

func TestAttachCleansPartialEROXWorkspaceBeforeUnmount(t *testing.T) {
	base := t.TempDir()
	runner := &recordingRunner{errors: map[string]error{"workspace-prepare": errors.New("prepare failed")}}
	var unmounted bool
	err := run([]string{
		"--op", "attach", "--volume-id", "workspace-1", "--volume-base-dir", base,
		"--private-data", `{"upper_volume_id":"awv-1","checkpoint_ref":"sha256:base"}`,
	}, &bytes.Buffer{}, testResolveAWV, func(string) error { return nil }, mountOps{
		mount: func(string, string, string, uintptr, string) error { return nil },
		unmount: func(string, int) error {
			unmounted = true
			return nil
		},
	}, runner)
	if err == nil || !unmounted {
		t.Fatalf("err = %v, unmounted = %v", err, unmounted)
	}
	want := []string{"workspace-prepare", "workspace-detach", "workspace-remove"}
	for i, command := range want {
		if runner.calls[i].args[0] != command {
			t.Fatalf("call[%d] = %#v, want %s", i, runner.calls[i], command)
		}
	}
}

func TestAttachIgnoresStructuredLogBeforeEROXStatus(t *testing.T) {
	base := t.TempDir()
	status := []byte(`{"LogContent":"workspace prepared"}
{"workspace_id":"workspace-1","merged_dir":"` + base + `/workspace-1/.erox/workspaces/workspace-1/merged"}`)
	ops := mountOps{mount: func(string, string, string, uintptr, string) error { return nil }}
	err := run([]string{
		"--op", "attach",
		"--volume-id", "workspace-1",
		"--volume-base-dir", base,
		"--private-data", `{"upper_volume_id":"awv-1","checkpoint_ref":"sha256:base"}`,
	}, &bytes.Buffer{}, testResolveAWV, func(string) error { return nil }, ops, &recordingRunner{prepareOutput: status})
	if err != nil {
		t.Fatalf("run attach: %v", err)
	}
}

func TestAttachMountsAWVAndPreparesEROXWorkspace(t *testing.T) {
	base := t.TempDir()
	var source, target, fsType string
	ops := mountOps{mount: func(src, dst, typ string, _ uintptr, _ string) error {
		source, target, fsType = src, dst, typ
		return nil
	}}
	runner := &recordingRunner{}
	var output bytes.Buffer
	err := run([]string{
		"--op", "attach",
		"--volume-id", "workspace-1",
		"--volume-base-dir", base,
		"--private-data", `{"upper_volume_id":"awv-1","checkpoint_ref":"sha256:base","artifact":"/checkpoints/base"}`,
	}, &output, testResolveAWV, func(string) error { return nil }, ops, runner)
	if err != nil {
		t.Fatalf("run attach: %v", err)
	}
	if source != "/dev/nbd7" || target != base+"/workspace-1" || fsType != "btrfs" {
		t.Fatalf("mount = (%q, %q, %q)", source, target, fsType)
	}
	if len(runner.calls) != 1 {
		t.Fatalf("command calls = %#v", runner.calls)
	}
	wantArgs := []string{"workspace-prepare", "--root", base + "/workspace-1/.erox", "--workspace-id", "workspace-1", "--checkpoint-ref", "sha256:base", "--upper-volume-id", "awv-1", "--upper-mount-path", base + "/workspace-1", "--artifact", "/checkpoints/base"}
	if !reflect.DeepEqual(runner.calls[0].args, wantArgs) {
		t.Fatalf("prepare args = %#v, want %#v", runner.calls[0].args, wantArgs)
	}
	if !reflect.DeepEqual(runner.calls[0].env, []string{"EROX_WORKSPACE_ENABLE_REAL_MOUNT=1", "EROX_WORKSPACE_ENABLE_ADVANCED_OVERLAY=1"}) {
		t.Fatalf("prepare env = %#v", runner.calls[0].env)
	}
	var response attachResponse
	if err := json.Unmarshal(output.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.HostPath != base+"/workspace-1/.erox/workspaces/workspace-1/merged" {
		t.Fatalf("host path = %q", response.HostPath)
	}
	if response.Metadata["workspace_root"] != base+"/workspace-1/.erox" || response.Metadata["mount_path"] != base+"/workspace-1" {
		t.Fatalf("metadata = %#v", response.Metadata)
	}
}

func TestDetachRemovesEROXWorkspaceBeforeUnmountingAWV(t *testing.T) {
	runner := &recordingRunner{}
	var unmounted string
	ops := mountOps{unmount: func(path string, _ int) error { unmounted = path; return nil }}
	var output bytes.Buffer
	err := run([]string{
		"--op", "detach",
		"--ref-count", "0",
		"--metadata", `{"mount_path":"/volume/workspace-1","workspace_root":"/volume/workspace-1/.erox","workspace_id":"workspace-1"}`,
	}, &output, testResolveAWV, func(string) error { return nil }, ops, runner)
	if err != nil {
		t.Fatalf("run detach: %v", err)
	}
	if len(runner.calls) != 3 || runner.calls[0].args[0] != "workspace-status" || runner.calls[1].args[0] != "workspace-detach" || runner.calls[2].args[0] != "workspace-remove" {
		t.Fatalf("command calls = %#v", runner.calls)
	}
	if unmounted != "/volume/workspace-1" {
		t.Fatalf("unmounted = %q", unmounted)
	}
}

func TestDetachRemovesAlreadyDetachedWorkspace(t *testing.T) {
	runner := &recordingRunner{statusPhase: "detached"}
	err := detach(&bytes.Buffer{}, `{"mount_path":"/volume/workspace-1","workspace_root":"/volume/workspace-1/.erox","workspace_id":"workspace-1"}`, 0,
		mountOps{unmount: func(string, int) error { return nil }}, runner)
	if err != nil {
		t.Fatalf("detach: %v", err)
	}
	if len(runner.calls) != 2 || runner.calls[0].args[0] != "workspace-status" || runner.calls[1].args[0] != "workspace-remove" {
		t.Fatalf("command calls = %#v", runner.calls)
	}
}

func TestDetachUnmountsAWVWhenEROXWorkspaceIsAlreadyRemoved(t *testing.T) {
	runner := &recordingRunner{errors: map[string]error{"workspace-status": errors.New("workspace workspace-1 not found")}}
	var unmounted string
	err := detach(&bytes.Buffer{}, `{"mount_path":"/volume/workspace-1","workspace_root":"/volume/workspace-1/.erox","workspace_id":"workspace-1"}`, 0,
		mountOps{unmount: func(path string, _ int) error { unmounted = path; return nil }}, runner)
	if err != nil {
		t.Fatalf("detach: %v", err)
	}
	if unmounted != "/volume/workspace-1" || len(runner.calls) != 1 {
		t.Fatalf("unmounted = %q, calls = %#v", unmounted, runner.calls)
	}
}

func TestAttachRejectsMissingCheckpoint(t *testing.T) {
	err := run([]string{
		"--op", "attach",
		"--volume-id", "workspace-1",
		"--volume-base-dir", t.TempDir(),
		"--private-data", `{"upper_volume_id":"awv-1"}`,
	}, &bytes.Buffer{}, testResolveAWV, func(string) error { return nil }, mountOps{}, &recordingRunner{})
	if err == nil {
		t.Fatal("run accepted missing checkpoint_ref")
	}
}

func TestResolveAWVDeviceBindsVolumeIdentity(t *testing.T) {
	dir := t.TempDir()
	data := []byte(`{"volumeID":"awv-1","device":"/dev/nbd7"}`)
	sum := sha256.Sum256([]byte("awv-1"))
	if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("%x.json", sum[:])), data, 0o600); err != nil {
		t.Fatal(err)
	}
	device, err := resolveAWVDevice(dir, "awv-1")
	if err != nil || device != "/dev/nbd7" {
		t.Fatalf("device = %q, err = %v", device, err)
	}
	if _, err := resolveAWVDevice(dir, "awv-2"); err == nil {
		t.Fatal("resolved a different AWV identity")
	}
}

func TestSnapshotDetachesAndCommitsWorkspace(t *testing.T) {
	runner := &recordingRunner{}
	var output bytes.Buffer
	mountPath := t.TempDir()
	metadata := fmt.Sprintf(`{"mount_path":%q,"workspace_root":%q,"workspace_id":"workspace-1"}`, mountPath, filepath.Join(mountPath, ".erox"))
	err := snapshot(&output, metadata, "/checkpoints/snapshot-1", runner)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	want := []string{"workspace-status", "workspace-detach", "workspace-commit"}
	for i, command := range want {
		if runner.calls[i].args[0] != command {
			t.Fatalf("call[%d] = %#v, want %s", i, runner.calls[i], command)
		}
	}
}
