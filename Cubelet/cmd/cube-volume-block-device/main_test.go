package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestRunMountsBlockDeviceAsHostPath(t *testing.T) {
	base := t.TempDir()
	var source, target, fsType string
	ops := mountOps{mount: func(src, dst, typ string, _ uintptr, _ string) error {
		source, target, fsType = src, dst, typ
		return nil
	}}
	var out bytes.Buffer
	err := run([]string{
		"--op", "attach", "--volume-id", "vol-1", "--volume-base-dir", base,
		"--private-data", `{"device_path":"/dev/nbd7"}`,
	}, &out, func(string) error { return nil }, ops)
	if err != nil {
		t.Fatalf("run() error = %v", err)
	}
	var response attachResponse
	if err := json.Unmarshal(out.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if source != "/dev/nbd7" || target != response.HostPath || fsType != "btrfs" {
		t.Fatalf("mount = (%q, %q, %q), response = %#v", source, target, fsType, response)
	}
	if response.Metadata["mount_path"] != response.HostPath {
		t.Fatalf("metadata = %#v", response.Metadata)
	}
}

func TestRunDetachUnmountsLastReference(t *testing.T) {
	mountPath := t.TempDir() + "/vol-1"
	var unmounted string
	ops := mountOps{unmount: func(path string, _ int) error { unmounted = path; return nil }}
	var out bytes.Buffer
	err := run([]string{
		"--op", "detach", "--ref-count", "0",
		"--metadata", `{"mount_path":"` + mountPath + `"}`,
	}, &out, func(string) error { return nil }, ops)
	if err != nil {
		t.Fatalf("run() error = %v", err)
	}
	if unmounted != mountPath {
		t.Fatalf("unmounted = %q", unmounted)
	}
}

func TestRunRejectsMissingDevice(t *testing.T) {
	var out bytes.Buffer
	err := run([]string{
		"--op", "attach", "--volume-id", "vol-1", "--volume-base-dir", t.TempDir(),
		"--private-data", `{}`,
	}, &out, func(string) error { return nil }, mountOps{})
	if err == nil {
		t.Fatal("run() accepted missing device_path")
	}
}

func TestRunRejectsParentVolumeID(t *testing.T) {
	err := run([]string{
		"--op", "attach", "--volume-id", "..", "--volume-base-dir", t.TempDir(),
		"--private-data", `{"device_path":"/dev/nbd7"}`,
	}, &bytes.Buffer{}, func(string) error { return nil }, mountOps{})
	if err == nil {
		t.Fatal("run() accepted parent directory volume-id")
	}
}
