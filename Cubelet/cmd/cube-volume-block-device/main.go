package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

type privateData struct {
	DevicePath string `json:"device_path"`
}

type attachResponse struct {
	HostPath string            `json:"host_path,omitempty"`
	Metadata map[string]string `json:"metadata,omitempty"`
	Error    string            `json:"error,omitempty"`
}

type mountOps struct {
	mount   func(string, string, string, uintptr, string) error
	unmount func(string, int) error
}

func main() {
	ops := mountOps{mount: unix.Mount, unmount: unix.Unmount}
	if err := run(os.Args[1:], os.Stdout, validateBlockDevice, ops); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string, output io.Writer, validate func(string) error, ops mountOps) error {
	flags := flag.NewFlagSet("cube-volume-block-device", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	op := flags.String("op", "", "attach or detach")
	private := flags.String("private-data", "", "JSON device description")
	volumeID := flags.String("volume-id", "", "volume identifier")
	baseDir := flags.String("volume-base-dir", "", "mount base directory")
	refCount := flags.String("ref-count", "0", "volume reference count")
	metadata := flags.String("metadata", "", "attach metadata")
	for _, name := range []string{"sandbox-id", "namespace"} {
		flags.String(name, "", "")
	}
	if err := flags.Parse(args); err != nil {
		return err
	}
	refs, err := strconv.ParseInt(*refCount, 10, 64)
	if err != nil || refs < 0 {
		return fmt.Errorf("invalid ref-count %q", *refCount)
	}
	if *op == "detach" {
		if refs == 0 {
			var state map[string]string
			if err := json.Unmarshal([]byte(*metadata), &state); err != nil {
				return fmt.Errorf("decode metadata: %w", err)
			}
			if state["mount_path"] == "" {
				return errors.New("metadata.mount_path is required")
			}
			if err := ops.unmount(state["mount_path"], 0); err != nil {
				return fmt.Errorf("unmount %s: %w", state["mount_path"], err)
			}
			if err := os.Remove(state["mount_path"]); err != nil && !errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("remove mount path: %w", err)
			}
		}
		return json.NewEncoder(output).Encode(attachResponse{})
	}
	if *op != "attach" {
		return fmt.Errorf("unsupported operation %q", *op)
	}
	if *volumeID == "" || *volumeID == "." || *volumeID == ".." || filepath.Base(*volumeID) != *volumeID {
		return errors.New("volume-id must be a single path component")
	}
	if !filepath.IsAbs(*baseDir) {
		return errors.New("volume-base-dir must be absolute")
	}
	var data privateData
	if err := json.Unmarshal([]byte(*private), &data); err != nil {
		return fmt.Errorf("decode private_data: %w", err)
	}
	if data.DevicePath == "" {
		return errors.New("private_data.device_path is required")
	}
	if err := validate(data.DevicePath); err != nil {
		return err
	}
	mountPath := filepath.Join(*baseDir, *volumeID)
	rel, err := filepath.Rel(filepath.Clean(*baseDir), mountPath)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return errors.New("volume-id resolves outside volume-base-dir")
	}
	if refs == 0 {
		if err := os.MkdirAll(mountPath, 0755); err != nil {
			return fmt.Errorf("create mount path: %w", err)
		}
		if err := ops.mount(data.DevicePath, mountPath, "btrfs", 0, ""); err != nil {
			_ = os.Remove(mountPath)
			return fmt.Errorf("mount %s: %w", data.DevicePath, err)
		}
	}
	return json.NewEncoder(output).Encode(attachResponse{
		HostPath: mountPath,
		Metadata: map[string]string{"mount_path": mountPath},
	})
}

func validateBlockDevice(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("device_path must be absolute")
	}
	var stat unix.Stat_t
	if err := unix.Stat(path, &stat); err != nil {
		return fmt.Errorf("stat device_path %s: %w", path, err)
	}
	if stat.Mode&unix.S_IFMT != unix.S_IFBLK {
		return fmt.Errorf("device_path %s is not a block device", path)
	}
	return nil
}
