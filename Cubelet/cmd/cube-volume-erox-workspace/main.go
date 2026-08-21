package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

const defaultEROXBinary = "/usr/local/services/cubetoolbox/Cubelet/plugin/erox-snapshotter"
const defaultAWVStateDir = "/data/cubelet/awv-state"

type privateData struct {
	UpperVolumeID string `json:"upper_volume_id"`
	CheckpointRef string `json:"checkpoint_ref"`
	Backend       string `json:"backend,omitempty"`
	Artifact      string `json:"artifact,omitempty"`
}

type workspaceStatus struct {
	WorkspaceID string `json:"workspace_id"`
	Phase       string `json:"phase"`
	MergedDir   string `json:"merged_dir"`
}

type attachResponse struct {
	HostPath string            `json:"host_path,omitempty"`
	Metadata map[string]string `json:"metadata,omitempty"`
	Error    string            `json:"error,omitempty"`
}

type mountIdentity struct {
	Source string
	FSType string
}

type mountOps struct {
	mount   func(string, string, string, uintptr, string) error
	unmount func(string, int) error
	inspect func(string) (mountIdentity, bool, error)
}

type commandRunner interface {
	run(env []string, args ...string) ([]byte, error)
}

type execRunner struct {
	binary string
}

type awvRuntimeState struct {
	VolumeID string `json:"volumeID"`
	Device   string `json:"device"`
}

func (r execRunner) run(env []string, args ...string) ([]byte, error) {
	cmd := exec.Command(r.binary, args...) //nolint:gosec // binary is fixed by trusted node configuration.
	cmd.Env = append(os.Environ(), env...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

func main() {
	binary := strings.TrimSpace(os.Getenv("EROX_SNAPSHOTTER_BIN"))
	if binary == "" {
		binary = defaultEROXBinary
	}
	ops := mountOps{mount: unix.Mount, unmount: unix.Unmount, inspect: inspectMount}
	resolve := func(volumeID string) (string, error) { return resolveAWVDevice(defaultAWVStateDir, volumeID) }
	if err := run(os.Args[1:], os.Stdout, resolve, validateBlockDevice, ops, execRunner{binary: binary}); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string, output io.Writer, resolve func(string) (string, error), validate func(string) error, ops mountOps, runner commandRunner) error {
	flags := flag.NewFlagSet("cube-volume-erox-workspace", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	op := flags.String("op", "", "attach or detach")
	private := flags.String("private-data", "", "JSON workspace description")
	volumeID := flags.String("volume-id", "", "workspace identifier")
	baseDir := flags.String("volume-base-dir", "", "mount base directory")
	refCount := flags.String("ref-count", "0", "volume reference count")
	metadata := flags.String("metadata", "", "attach metadata")
	snapshotOutput := flags.String("snapshot-output", "", "local checkpoint output directory")
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
		return detach(output, *metadata, refs, ops, runner)
	}
	if *op == "snapshot" {
		return snapshot(output, *metadata, *snapshotOutput, runner)
	}
	if *op != "attach" {
		return fmt.Errorf("unsupported operation %q", *op)
	}
	return attach(output, *private, *volumeID, *baseDir, refs, resolve, validate, ops, runner)
}

func attach(output io.Writer, raw, volumeID, baseDir string, refs int64, resolve func(string) (string, error), validate func(string) error, ops mountOps, runner commandRunner) error {
	if volumeID == "" || volumeID == "." || volumeID == ".." || filepath.Base(volumeID) != volumeID {
		return errors.New("volume-id must be a single path component")
	}
	if !filepath.IsAbs(baseDir) {
		return errors.New("volume-base-dir must be absolute")
	}
	if raw == "" {
		return errors.New("private_data is required")
	}
	var data privateData
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		return fmt.Errorf("decode private_data: %w", err)
	}
	if data.UpperVolumeID == "" {
		return errors.New("private_data.upper_volume_id is required")
	}
	if data.CheckpointRef == "" {
		return errors.New("private_data.checkpoint_ref is required")
	}
	devicePath, err := resolve(data.UpperVolumeID)
	if err != nil {
		return fmt.Errorf("resolve AWV volume %s: %w", data.UpperVolumeID, err)
	}
	if err := validate(devicePath); err != nil {
		return err
	}
	mountPath := filepath.Join(filepath.Clean(baseDir), volumeID)
	if err := ensureChildPath(baseDir, mountPath); err != nil {
		return err
	}
	if err := os.MkdirAll(mountPath, 0o750); err != nil {
		return fmt.Errorf("create AWV mount path: %w", err)
	}
	if refs == 0 {
		mounted := false
		if ops.inspect != nil {
			identity, found, err := ops.inspect(mountPath)
			if err != nil {
				return err
			}
			if found {
				if filepath.Clean(identity.Source) != filepath.Clean(devicePath) || identity.FSType != "btrfs" {
					return fmt.Errorf("mount path %s belongs to source=%s fstype=%s", mountPath, identity.Source, identity.FSType)
				}
				mounted = true
			}
		}
		if !mounted {
			if err := ops.mount(devicePath, mountPath, "btrfs", 0, ""); err != nil {
				return fmt.Errorf("mount AWV %s: %w", devicePath, err)
			}
		}
	}
	root := filepath.Join(mountPath, ".erox")
	command := []string{"workspace-prepare", "--root", root, "--workspace-id", volumeID, "--checkpoint-ref", data.CheckpointRef}
	command = append(command, "--upper-volume-id", data.UpperVolumeID, "--upper-mount-path", mountPath)
	if data.Backend != "" {
		command = append(command, "--backend", data.Backend)
	}
	if data.Artifact != "" {
		command = append(command, "--artifact", data.Artifact)
	}
	commandOutput, err := runner.run(workspaceEnv(), command...)
	if err != nil {
		return cleanupFailedAttach(fmt.Errorf("prepare EROX workspace: %w", err), root, volumeID, mountPath, refs, ops, runner)
	}
	status, err := decodeWorkspaceStatus(commandOutput, volumeID)
	if err != nil {
		return cleanupFailedAttach(fmt.Errorf("decode EROX workspace status: %w", err), root, volumeID, mountPath, refs, ops, runner)
	}
	if !filepath.IsAbs(status.MergedDir) {
		return cleanupFailedAttach(fmt.Errorf("unexpected EROX workspace status: workspace_id=%q merged_dir=%q", status.WorkspaceID, status.MergedDir), root, volumeID, mountPath, refs, ops, runner)
	}
	if err := ensureChildPath(mountPath, status.MergedDir); err != nil {
		return cleanupFailedAttach(fmt.Errorf("validate EROX merged path: %w", err), root, volumeID, mountPath, refs, ops, runner)
	}
	return json.NewEncoder(output).Encode(attachResponse{
		HostPath: status.MergedDir,
		Metadata: map[string]string{
			"device_path":     devicePath,
			"upper_volume_id": data.UpperVolumeID,
			"mount_path":      mountPath,
			"workspace_id":    volumeID,
			"workspace_root":  root,
		},
	})
}

func snapshot(output io.Writer, raw, checkpointOutput string, runner commandRunner) error {
	if raw == "" {
		return errors.New("metadata is required")
	}
	if !filepath.IsAbs(checkpointOutput) {
		return errors.New("snapshot-output must be absolute")
	}
	var state map[string]string
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		return fmt.Errorf("decode metadata: %w", err)
	}
	for _, key := range []string{"mount_path", "workspace_root", "workspace_id"} {
		if state[key] == "" {
			return fmt.Errorf("metadata.%s is required", key)
		}
	}
	root := filepath.Clean(state["workspace_root"])
	if err := ensureChildPath(state["mount_path"], root); err != nil {
		return err
	}
	statusOutput, err := runner.run(workspaceEnv(), "workspace-status", "--root", root, "--workspace-id", state["workspace_id"])
	if err != nil {
		return fmt.Errorf("inspect EROX workspace: %w", err)
	}
	status, err := decodeWorkspaceStatus(statusOutput, state["workspace_id"])
	if err != nil {
		return fmt.Errorf("decode EROX workspace status: %w", err)
	}
	if status.Phase != "detached" {
		if _, err := runner.run(workspaceEnv(), "workspace-detach", "--root", root, "--workspace-id", state["workspace_id"]); err != nil {
			return fmt.Errorf("detach EROX workspace: %w", err)
		}
	}
	commitOutput, err := runner.run(workspaceEnv(), "workspace-commit", "--root", root, "--workspace-id", state["workspace_id"], "--output", filepath.Clean(checkpointOutput))
	if err != nil {
		return fmt.Errorf("commit EROX workspace: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(root, "workspaces", state["workspace_id"], "merged"), 0o750); err != nil {
		return fmt.Errorf("restore direct-share path: %w", err)
	}
	_, err = output.Write(commitOutput)
	return err
}

func cleanupFailedAttach(attachErr error, root, workspaceID, mountPath string, refs int64, ops mountOps, runner commandRunner) error {
	if refs != 0 {
		return attachErr
	}
	var cleanupErrs []error
	if _, err := runner.run(workspaceEnv(), "workspace-detach", "--root", root, "--workspace-id", workspaceID); err != nil && !isWorkspaceNotFound(err, workspaceID) {
		cleanupErrs = append(cleanupErrs, fmt.Errorf("cleanup EROX workspace detach: %w", err))
	}
	if _, err := runner.run(workspaceEnv(), "workspace-remove", "--root", root, "--workspace-id", workspaceID); err != nil && !isWorkspaceNotFound(err, workspaceID) {
		cleanupErrs = append(cleanupErrs, fmt.Errorf("cleanup EROX workspace remove: %w", err))
	}
	if err := ops.unmount(mountPath, 0); err != nil && !errors.Is(err, unix.EINVAL) && !errors.Is(err, unix.ENOENT) {
		cleanupErrs = append(cleanupErrs, fmt.Errorf("cleanup AWV unmount: %w", err))
	}
	return errors.Join(append([]error{attachErr}, cleanupErrs...)...)
}

func decodeWorkspaceStatus(output []byte, workspaceID string) (workspaceStatus, error) {
	decoder := json.NewDecoder(strings.NewReader(string(output)))
	for {
		var status workspaceStatus
		if err := decoder.Decode(&status); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return workspaceStatus{}, err
		}
		if status.WorkspaceID == workspaceID {
			return status, nil
		}
	}
	return workspaceStatus{}, fmt.Errorf("workspace %s status not found", workspaceID)
}

func detach(output io.Writer, raw string, refs int64, ops mountOps, runner commandRunner) error {
	if refs != 0 {
		return json.NewEncoder(output).Encode(attachResponse{})
	}
	if raw == "" {
		return errors.New("metadata is required")
	}
	var state map[string]string
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		return fmt.Errorf("decode metadata: %w", err)
	}
	for _, key := range []string{"mount_path", "workspace_root", "workspace_id"} {
		if state[key] == "" {
			return fmt.Errorf("metadata.%s is required", key)
		}
	}
	root := filepath.Clean(state["workspace_root"])
	if err := ensureChildPath(state["mount_path"], root); err != nil {
		return err
	}
	statusOutput, err := runner.run(workspaceEnv(), "workspace-status", "--root", root, "--workspace-id", state["workspace_id"])
	workspaceExists := true
	if err != nil && !isWorkspaceNotFound(err, state["workspace_id"]) {
		return fmt.Errorf("inspect EROX workspace: %w", err)
	}
	if err != nil {
		workspaceExists = false
	}
	status, decodeErr := decodeWorkspaceStatus(statusOutput, state["workspace_id"])
	if decodeErr != nil && workspaceExists && !isWorkspaceNotFound(decodeErr, state["workspace_id"]) {
		return fmt.Errorf("decode EROX workspace status: %w", decodeErr)
	}
	if decodeErr != nil {
		workspaceExists = false
	}
	if workspaceExists && status.Phase != "detached" {
		if _, err := runner.run(workspaceEnv(), "workspace-detach", "--root", root, "--workspace-id", state["workspace_id"]); err != nil {
			return fmt.Errorf("detach EROX workspace: %w", err)
		}
	}
	if workspaceExists {
		_, err = runner.run(workspaceEnv(), "workspace-remove", "--root", root, "--workspace-id", state["workspace_id"])
	}
	if err != nil && !isWorkspaceNotFound(err, state["workspace_id"]) {
		return fmt.Errorf("remove EROX workspace: %w", err)
	}
	mounted := true
	if ops.inspect != nil {
		identity, found, err := ops.inspect(state["mount_path"])
		if err != nil {
			return err
		}
		mounted = found
		if found && state["device_path"] != "" && filepath.Clean(identity.Source) != filepath.Clean(state["device_path"]) {
			return fmt.Errorf("refuse to unmount %s from unexpected source %s", state["mount_path"], identity.Source)
		}
	}
	if mounted {
		if err := ops.unmount(state["mount_path"], 0); err != nil && !errors.Is(err, unix.EINVAL) && !errors.Is(err, unix.ENOENT) {
			return fmt.Errorf("unmount AWV %s: %w", state["mount_path"], err)
		}
	}
	if err := os.Remove(state["mount_path"]); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove AWV mount path: %w", err)
	}
	return json.NewEncoder(output).Encode(attachResponse{})
}

func isWorkspaceNotFound(err error, workspaceID string) bool {
	want := "workspace " + strings.ToLower(strings.TrimSpace(workspaceID)) + " not found"
	return err != nil && workspaceID != "" && strings.Contains(strings.ToLower(err.Error()), want)
}

func resolveAWVDevice(stateDir, volumeID string) (string, error) {
	if strings.TrimSpace(volumeID) == "" {
		return "", errors.New("AWV volume ID is required")
	}
	sum := sha256.Sum256([]byte(volumeID))
	statePath := filepath.Join(stateDir, fmt.Sprintf("%x.json", sum[:]))
	data, err := os.ReadFile(statePath)
	if err != nil {
		return "", fmt.Errorf("read AWV volume state: %w", err)
	}
	var state awvRuntimeState
	if err := json.Unmarshal(data, &state); err != nil {
		return "", fmt.Errorf("decode AWV volume state: %w", err)
	}
	if state.VolumeID != volumeID {
		return "", fmt.Errorf("AWV state identity %q does not match %q", state.VolumeID, volumeID)
	}
	if !filepath.IsAbs(state.Device) {
		return "", fmt.Errorf("AWV volume %s has invalid device %q", volumeID, state.Device)
	}
	return filepath.Clean(state.Device), nil
}

func workspaceEnv() []string {
	return []string{"EROX_WORKSPACE_ENABLE_REAL_MOUNT=1", "EROX_WORKSPACE_ENABLE_ADVANCED_OVERLAY=1"}
}

func ensureChildPath(parent, child string) error {
	parent = filepath.Clean(parent)
	child = filepath.Clean(child)
	rel, err := filepath.Rel(parent, child)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("path %s must be a child of %s", child, parent)
	}
	return nil
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

func inspectMount(target string) (mountIdentity, bool, error) {
	file, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return mountIdentity{}, false, err
	}
	defer func() { _ = file.Close() }()
	target = filepath.Clean(target)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		separator := -1
		for i, field := range fields {
			if field == "-" {
				separator = i
				break
			}
		}
		if separator < 0 || separator+2 >= len(fields) || len(fields) < 5 || unescapeMountInfo(fields[4]) != target {
			continue
		}
		return mountIdentity{FSType: fields[separator+1], Source: unescapeMountInfo(fields[separator+2])}, true, nil
	}
	if err := scanner.Err(); err != nil {
		return mountIdentity{}, false, err
	}
	return mountIdentity{}, false, nil
}

func unescapeMountInfo(value string) string {
	replacer := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`)
	return replacer.Replace(value)
}
