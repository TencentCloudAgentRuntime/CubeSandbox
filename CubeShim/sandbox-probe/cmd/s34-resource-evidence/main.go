// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// s34-resource-evidence captures exact containerd resource inputs and drives
// isolated low-level create/update cases for the S3.4a Kubernetes PoC.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	tasksapi "github.com/containerd/containerd/api/services/tasks/v1"
	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/core/containers"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/containerd/errdefs"
	"github.com/containerd/typeurl/v2"
	specs "github.com/opencontainers/runtime-spec/specs-go"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	runtime "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const (
	commandTimeout           = 2 * time.Minute
	criAPIModuleVersion      = "k8s.io/cri-api@v0.36.4"
	containerMetadataTypeURL = "github.com/containerd/cri/pkg/store/container/Metadata"
	containerMetadataKey     = "io.containerd.cri.container.metadata"
	legacyContainerMetaKey   = "io.cri-containerd.container.metadata"
	sandboxMetadataTypeURL   = "github.com/containerd/cri/pkg/store/sandbox/Metadata"
	ociSpecTypeURL           = "types.containerd.io/opencontainers/runtime-spec/1/Spec"
	ociLinuxResourcesTypeURL = "types.containerd.io/opencontainers/runtime-spec/1/LinuxResources"
	runcRuntimeName          = "io.containerd.runc.v2"
	cubeRuntimeName          = "io.containerd.cube.rs"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "dump-container":
		err = dumpContainerCommand(os.Args[2:], true)
	case "dump-container-persisted":
		err = dumpContainerCommand(os.Args[2:], false)
	case "dump-sandbox":
		err = dumpSandboxCommand(os.Args[2:])
	case "create":
		err = createCommand(os.Args[2:])
	case "update":
		err = updateCommand(os.Args[2:])
	case "cgroup":
		err = cgroupCommand(os.Args[2:])
	case "delete":
		err = deleteCommand(os.Args[2:])
	case "decode-update":
		err = decodeUpdateCommand(os.Args[2:])
	case "schema":
		err = schemaCommand(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  s34-resource-evidence dump-container SOCKET NAMESPACE CONTAINER_ID OUTPUT_DIR
  s34-resource-evidence dump-container-persisted SOCKET NAMESPACE CONTAINER_ID OUTPUT_DIR
  s34-resource-evidence dump-sandbox   SOCKET NAMESPACE SANDBOX_ID OUTPUT_DIR
  s34-resource-evidence create SOCKET NAMESPACE RUNTIME SANDBOX_ID|- IMAGE ID RESOURCES_JSON OUTPUT_DIR
  s34-resource-evidence update SOCKET NAMESPACE CONTAINER_ID RESOURCES_JSON OUTPUT_PREFIX
  s34-resource-evidence cgroup SOCKET NAMESPACE CONTAINER_ID OUTPUT_FILE
  s34-resource-evidence delete SOCKET NAMESPACE CONTAINER_ID confirm-owned-s34-resource-probe
  s34-resource-evidence decode-update cri|task INPUT_PB OUTPUT_PREFIX
  s34-resource-evidence schema`)
	os.Exit(2)
}

func dumpContainerCommand(args []string, captureLiveBundle bool) error {
	if len(args) != 4 {
		usage()
	}
	client, ctx, cancel, err := newClient(args[0], args[1])
	if err != nil {
		return err
	}
	defer client.Close()
	defer cancel()
	container, err := client.LoadContainer(ctx, args[2])
	if err != nil {
		return err
	}
	info, err := container.Info(ctx)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(args[3], 0o755); err != nil {
		return err
	}
	if err := dumpAny(filepath.Join(args[3], "container-spec"), info.Spec, ociSpecTypeURL, decodeSpec); err != nil {
		return err
	}
	if captureLiveBundle {
		if err := captureBundleConfigs(args[2], args[3], true); err != nil {
			return err
		}
	}
	keys := make([]string, 0, len(info.Extensions))
	for key := range info.Extensions {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		decoder := decodeJSON
		expectedTypeURL := ""
		if key == containerMetadataKey || key == legacyContainerMetaKey {
			decoder = decodeContainerMetadata
			expectedTypeURL = containerMetadataTypeURL
		}
		if err := dumpAny(filepath.Join(args[3], "extension-"+safeName(key)), info.Extensions[key], expectedTypeURL, decoder); err != nil {
			return err
		}
	}
	return writeJSON(filepath.Join(args[3], "container-info.json"), info)
}

func dumpSandboxCommand(args []string) error {
	if len(args) != 4 {
		usage()
	}
	client, ctx, cancel, err := newClient(args[0], args[1])
	if err != nil {
		return err
	}
	defer client.Close()
	defer cancel()
	sandbox, err := client.SandboxStore().Get(ctx, args[2])
	if err != nil {
		return err
	}
	if err := os.MkdirAll(args[3], 0o755); err != nil {
		return err
	}
	if err := dumpAny(filepath.Join(args[3], "sandbox-spec"), sandbox.Spec, ociSpecTypeURL, decodeSpec); err != nil {
		return err
	}
	bundleRequired, err := sandboxBundleRequired(sandbox.Runtime.Name)
	if err != nil {
		return err
	}
	if err := captureBundleConfigs(args[2], args[3], bundleRequired); err != nil {
		return err
	}
	keys := make([]string, 0, len(sandbox.Extensions))
	for key := range sandbox.Extensions {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		decoder := decodeJSON
		expectedTypeURL := ""
		if key == "metadata" || key == "io.containerd.cri.sandbox.metadata" {
			decoder = decodeSandboxMetadata
			expectedTypeURL = sandboxMetadataTypeURL
		}
		if err := dumpAny(filepath.Join(args[3], "extension-"+safeName(key)), sandbox.Extensions[key], expectedTypeURL, decoder); err != nil {
			return err
		}
	}
	return writeJSON(filepath.Join(args[3], "sandbox-info.json"), sandbox)
}

func createCommand(args []string) error {
	if len(args) != 9 {
		usage()
	}
	socket, namespace, runtimeName, sandboxID := args[0], args[1], args[2], args[3]
	imageRef, id, resourcesPath, outputDir := args[4], args[5], args[6], args[7]
	if args[8] != "confirm-owned-s34-resource-probe" {
		return errors.New("missing create ownership confirmation")
	}
	resources, err := readResources(resourcesPath)
	if err != nil {
		return err
	}
	client, ctx, cancel, err := newClient(socket, namespace)
	if err != nil {
		return err
	}
	defer client.Close()
	defer cancel()
	image, err := client.GetImage(ctx, imageRef)
	if err != nil {
		return err
	}
	unpacked, err := image.IsUnpacked(ctx, "overlayfs")
	if err != nil {
		return err
	}
	if !unpacked {
		return fmt.Errorf("image %q is not unpacked for overlayfs", imageRef)
	}
	opts := []containerd.NewContainerOpts{
		containerd.WithRuntime(runtimeName, nil),
		containerd.WithImage(image),
		containerd.WithSnapshotter("overlayfs"),
		containerd.WithNewSnapshot(id+"-snapshot", image),
		containerd.WithContainerLabels(map[string]string{"cubesandbox.io/s34-owned": "true"}),
		containerd.WithNewSpec(oci.WithImageConfig(image), withProbeProcess(resources)),
	}
	var container containerd.Container
	if sandboxID == "-" {
		container, err = client.NewContainer(ctx, id, opts...)
	} else {
		sandbox, loadErr := client.LoadSandbox(ctx, sandboxID)
		if loadErr != nil {
			return loadErr
		}
		container, err = sandbox.NewContainer(ctx, id, opts...)
	}
	if err != nil {
		return err
	}
	created := true
	defer func() {
		if created {
			_ = container.Delete(context.Background(), containerd.WithSnapshotCleanup)
		}
	}()
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return err
	}
	if err := dumpLoadedContainer(ctx, container, outputDir); err != nil {
		return err
	}
	task, err := container.NewTask(ctx, cio.NullIO)
	if err != nil {
		_ = captureBundleConfigs(id, outputDir, true)
		_ = os.WriteFile(filepath.Join(outputDir, "create.result.txt"), []byte("error="+err.Error()+"\n"), 0o644)
		return err
	}
	taskCreated := true
	defer func() {
		if taskCreated {
			_, _ = task.Delete(context.Background(), containerd.WithProcessKill)
		}
	}()
	if err := task.Start(ctx); err != nil {
		_ = captureBundleConfigs(id, outputDir, true)
		_ = os.WriteFile(filepath.Join(outputDir, "create.result.txt"), []byte("error="+err.Error()+"\n"), 0o644)
		return err
	}
	if err := captureBundleConfigs(id, outputDir, true); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(outputDir, "task-pid.txt"), []byte(fmt.Sprintf("%d\n", task.Pid())), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(outputDir, "create.result.txt"), []byte("success\n"), 0o644); err != nil {
		return err
	}
	created, taskCreated = false, false
	fmt.Printf("S34_CREATE_OK id=%s runtime=%s sandbox=%s pid=%d\n", id, runtimeName, sandboxID, task.Pid())
	return nil
}

func updateCommand(args []string) error {
	if len(args) != 5 {
		usage()
	}
	resources, err := readResources(args[3])
	if err != nil {
		return err
	}
	client, ctx, cancel, err := newClient(args[0], args[1])
	if err != nil {
		return err
	}
	defer client.Close()
	defer cancel()
	marshaled, err := typeurl.MarshalAny(resources)
	if err != nil {
		return err
	}
	if marshaled.GetTypeUrl() != ociLinuxResourcesTypeURL {
		return fmt.Errorf("LinuxResources type URL = %q, want %q", marshaled.GetTypeUrl(), ociLinuxResourcesTypeURL)
	}
	request := &tasksapi.UpdateTaskRequest{
		ContainerID: args[2],
		Resources:   typeurl.MarshalProto(marshaled),
	}
	if err := dumpUpdate(args[4], request, resources); err != nil {
		return err
	}
	_, updateErr := client.TaskService().Update(ctx, request)
	result := "success\n"
	if updateErr != nil {
		result = "error=" + updateErr.Error() + "\n"
	}
	if err := os.WriteFile(args[4]+".result.txt", []byte(result), 0o644); err != nil {
		return err
	}
	return updateErr
}

func cgroupCommand(args []string) error {
	if len(args) != 4 {
		usage()
	}
	client, ctx, cancel, err := newClient(args[0], args[1])
	if err != nil {
		return err
	}
	defer client.Close()
	defer cancel()
	container, err := client.LoadContainer(ctx, args[2])
	if err != nil {
		return err
	}
	info, err := container.Info(ctx)
	if err != nil {
		return err
	}
	if info.Runtime.Name != runcRuntimeName && info.Runtime.Name != cubeRuntimeName {
		return fmt.Errorf("cgroup capture does not support runtime %q", info.Runtime.Name)
	}
	task, err := container.Task(ctx, nil)
	if err != nil {
		return err
	}
	var stdout, stderr bytes.Buffer
	execID := fmt.Sprintf("s34-cgroup-%d", time.Now().UnixNano())
	process, err := task.Exec(ctx, execID, cgroupProbeProcess(info.Runtime.Name), cio.NewCreator(cio.WithStreams(nil, &stdout, &stderr)))
	if err != nil {
		return err
	}
	defer func() { _, _ = process.Delete(context.Background()) }()
	wait, err := process.Wait(ctx)
	if err != nil {
		return err
	}
	if err := process.Start(ctx); err != nil {
		return err
	}
	status := <-wait
	code, _, err := status.Result()
	if err != nil {
		return err
	}
	if err := os.WriteFile(args[3], stdout.Bytes(), 0o644); err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("cgroup exec exited %d: stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	return nil
}

func deleteCommand(args []string) error {
	if len(args) != 4 || args[3] != "confirm-owned-s34-resource-probe" {
		usage()
	}
	client, ctx, cancel, err := newClient(args[0], args[1])
	if err != nil {
		return err
	}
	defer client.Close()
	defer cancel()
	container, err := client.LoadContainer(ctx, args[2])
	if err != nil {
		if errdefs.IsNotFound(err) {
			return nil
		}
		return err
	}
	labels, err := container.Labels(ctx)
	if err != nil {
		return err
	}
	if labels["cubesandbox.io/s34-owned"] != "true" {
		return errors.New("refusing to delete container without s34 ownership label")
	}
	task, err := container.Task(ctx, nil)
	if err == nil {
		wait, waitErr := task.Wait(ctx)
		if waitErr == nil {
			_ = task.Kill(ctx, syscall.SIGKILL)
			select {
			case <-wait:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		if _, err = task.Delete(ctx, containerd.WithProcessKill); err != nil && !errdefs.IsNotFound(err) {
			return err
		}
	} else if !errdefs.IsNotFound(err) {
		return err
	}
	return container.Delete(ctx, containerd.WithSnapshotCleanup)
}

func decodeUpdateCommand(args []string) error {
	if len(args) != 3 {
		usage()
	}
	raw, err := os.ReadFile(args[1])
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(args[2]), 0o755); err != nil {
		return err
	}
	switch args[0] {
	case "cri":
		var request runtime.UpdateContainerResourcesRequest
		if err := proto.Unmarshal(raw, &request); err != nil {
			return err
		}
		decoded, err := protojson.MarshalOptions{Indent: "  ", UseProtoNames: true}.Marshal(&request)
		if err != nil {
			return err
		}
		decoded = append(decoded, '\n')
		files := map[string][]byte{
			"request.pb":   raw,
			"decoded.json": decoded,
			"schema.txt":   []byte("runtime.v1.UpdateContainerResourcesRequest\nmodule=" + criAPIModuleVersion + "\n"),
		}
		for suffix, data := range files {
			if err := os.WriteFile(args[2]+"."+suffix, data, 0o644); err != nil {
				return err
			}
		}
		return writeManifest(args[2], files)
	case "task":
		var request tasksapi.UpdateTaskRequest
		if err := proto.Unmarshal(raw, &request); err != nil {
			return err
		}
		if request.GetResources() == nil || request.GetResources().GetTypeUrl() != ociLinuxResourcesTypeURL {
			return fmt.Errorf("Task Update resource type URL = %q, want %q", request.GetResources().GetTypeUrl(), ociLinuxResourcesTypeURL)
		}
		var resources specs.LinuxResources
		if err := typeurl.UnmarshalTo(request.GetResources(), &resources); err != nil {
			return err
		}
		if err := dumpUpdate(args[2], &request, &resources); err != nil {
			return err
		}
		reencoded, err := os.ReadFile(args[2] + ".request.pb")
		if err != nil {
			return err
		}
		if !bytes.Equal(raw, reencoded) {
			return errors.New("deterministic Task Update re-encode changed raw request bytes")
		}
		return nil
	default:
		return fmt.Errorf("unknown update kind %q", args[0])
	}
}

func schemaCommand(args []string) error {
	if len(args) != 0 {
		usage()
	}
	_, err := fmt.Printf(`cri_api_module=%s
cri_update=runtime.v1.UpdateContainerResourcesRequest
container_metadata=%s
sandbox_metadata=%s
task_update=containerd.services.tasks.v1.UpdateTaskRequest
oci_spec=%s
oci_linux_resources=%s
`, criAPIModuleVersion, containerMetadataTypeURL, sandboxMetadataTypeURL, ociSpecTypeURL, ociLinuxResourcesTypeURL)
	return err
}

func newClient(socket, namespace string) (*containerd.Client, context.Context, context.CancelFunc, error) {
	client, err := containerd.New(socket)
	if err != nil {
		return nil, nil, nil, err
	}
	ctx, cancel := context.WithTimeout(namespaces.WithNamespace(context.Background(), namespace), commandTimeout)
	return client, ctx, cancel, nil
}

func cgroupProbeProcess(runtimeName string) *specs.Process {
	process := &specs.Process{
		Args: []string{"/bin/sh", "-c", cgroupScript},
		Cwd:  "/",
		Env:  []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
		User: specs.User{UID: 0, GID: 0},
	}
	if runtimeName == runcRuntimeName {
		process.Env = append(process.Env, "S34_CGROUP2_MOUNT_OPTIONAL=runc-lowlevel")
	}
	return process
}

func withProbeProcess(resources *specs.LinuxResources) oci.SpecOpts {
	return func(_ context.Context, _ oci.Client, _ *containers.Container, spec *specs.Spec) error {
		if spec.Process == nil || spec.Linux == nil {
			return errors.New("generated OCI spec has no process or linux section")
		}
		spec.Process.Args = []string{"sh", "-c", "exec sleep 3600"}
		spec.Process.Terminal = false
		spec.Linux.Resources = resources
		cgroupNamespaceCount := 0
		for _, namespace := range spec.Linux.Namespaces {
			if namespace.Type == specs.CgroupNamespace {
				cgroupNamespaceCount++
				if namespace.Path != "" {
					return fmt.Errorf("generated OCI spec cgroup namespace joins %q", namespace.Path)
				}
			}
		}
		if cgroupNamespaceCount > 1 {
			return fmt.Errorf("generated OCI spec contains %d cgroup namespaces", cgroupNamespaceCount)
		}
		for _, mount := range spec.Mounts {
			if mount.Destination == "/sys/fs/cgroup" {
				return errors.New("generated OCI spec already contains /sys/fs/cgroup mount")
			}
		}
		if cgroupNamespaceCount == 0 {
			spec.Linux.Namespaces = append(spec.Linux.Namespaces, specs.LinuxNamespace{Type: specs.CgroupNamespace})
		}
		spec.Mounts = append(spec.Mounts, specs.Mount{
			Destination: "/sys/fs/cgroup",
			Type:        "cgroup",
			Source:      "cgroup",
			Options:     []string{"nosuid", "noexec", "nodev", "relatime", "ro"},
		})
		return nil
	}
}

func readResources(path string) (*specs.LinuxResources, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	var resources specs.LinuxResources
	if err := decoder.Decode(&resources); err != nil {
		return nil, err
	}
	return &resources, nil
}

type anyDecoder func([]byte) ([]byte, error)

func dumpLoadedContainer(ctx context.Context, container containerd.Container, outputDir string) error {
	info, err := container.Info(ctx)
	if err != nil {
		return err
	}
	return dumpAny(filepath.Join(outputDir, "container-spec"), info.Spec, ociSpecTypeURL, decodeSpec)
}

func captureBundleConfigs(id, outputDir string, required bool) error {
	var configs []string
	err := filepath.WalkDir("/run/containerd", func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return filterBundleWalkError(id, path, walkErr)
		}
		if !entry.IsDir() && entry.Name() == "config.json" && pathHasElement(path, id) {
			configs = append(configs, path)
		}
		return nil
	})
	if err != nil {
		return err
	}
	return writeBundleConfigEvidence(id, outputDir, configs, required)
}

func filterBundleWalkError(id, path string, walkErr error) error {
	if errors.Is(walkErr, os.ErrNotExist) && path != "/run/containerd" && !pathHasElement(path, id) {
		return nil
	}
	return walkErr
}

func writeBundleConfigEvidence(id, outputDir string, configs []string, required bool) error {
	if len(configs) == 0 {
		if required {
			return fmt.Errorf("no live bundle config.json found for %q", id)
		}
		absence := []byte(fmt.Sprintf("sandbox_id=%s\nlive_bundle_config=absent\nsearch_root=/run/containerd\n", id))
		if err := os.WriteFile(filepath.Join(outputDir, "bundle-config-absence.txt"), absence, 0o644); err != nil {
			return err
		}
	}
	sort.Strings(configs)
	var paths strings.Builder
	bundleFiles := make(map[string][]byte, len(configs)+2)
	if len(configs) == 0 {
		absence, err := os.ReadFile(filepath.Join(outputDir, "bundle-config-absence.txt"))
		if err != nil {
			return err
		}
		bundleFiles["bundle-config-absence.txt"] = absence
	}
	for index, path := range configs {
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		name := fmt.Sprintf("bundle-config-%02d.json", index)
		if err := os.WriteFile(filepath.Join(outputDir, name), raw, 0o644); err != nil {
			return err
		}
		bundleFiles[name] = raw
		fmt.Fprintf(&paths, "%s\t%s\n", name, path)
	}
	pathBytes := []byte(paths.String())
	if err := os.WriteFile(filepath.Join(outputDir, "bundle-config-paths.tsv"), pathBytes, 0o644); err != nil {
		return err
	}
	bundleFiles["bundle-config-paths.tsv"] = pathBytes
	return writeNamedManifest(filepath.Join(outputDir, "bundle-config.sha256"), bundleFiles)
}

func sandboxBundleRequired(runtimeName string) (bool, error) {
	switch runtimeName {
	case runcRuntimeName:
		return true, nil
	case cubeRuntimeName:
		return false, nil
	default:
		return false, fmt.Errorf("unsupported sandbox runtime %q", runtimeName)
	}
}

func pathHasElement(path, element string) bool {
	for _, part := range strings.Split(filepath.Clean(path), string(filepath.Separator)) {
		if part == element {
			return true
		}
	}
	return false
}

func dumpAny(prefix string, value typeurl.Any, expectedTypeURL string, decoder anyDecoder) error {
	if value == nil {
		return errors.New("cannot dump nil Any")
	}
	if expectedTypeURL != "" && value.GetTypeUrl() != expectedTypeURL {
		return fmt.Errorf("Any type URL = %q, want pinned %q", value.GetTypeUrl(), expectedTypeURL)
	}
	outer := typeurl.MarshalProto(value)
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(outer)
	if err != nil {
		return err
	}
	if err := os.WriteFile(prefix+".any.pb", raw, 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(prefix+".value", value.GetValue(), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(prefix+".type-url.txt", []byte(value.GetTypeUrl()+"\n"), 0o644); err != nil {
		return err
	}
	typeURL := []byte(value.GetTypeUrl() + "\n")
	decoded, err := decoder(value.GetValue())
	if err != nil {
		return fmt.Errorf("decode %s as %s: %w", prefix, value.GetTypeUrl(), err)
	}
	if err := os.WriteFile(prefix+".decoded.json", decoded, 0o644); err != nil {
		return err
	}
	return writeManifest(prefix, map[string][]byte{
		"any.pb": raw, "value": value.GetValue(), "decoded.json": decoded, "type-url.txt": typeURL,
	})
}

func dumpUpdate(prefix string, request *tasksapi.UpdateTaskRequest, resources *specs.LinuxResources) error {
	if err := os.MkdirAll(filepath.Dir(prefix), 0o755); err != nil {
		return err
	}
	rawRequest, err := proto.MarshalOptions{Deterministic: true}.Marshal(request)
	if err != nil {
		return err
	}
	decoded, err := json.MarshalIndent(resources, "", "  ")
	if err != nil {
		return err
	}
	decoded = append(decoded, '\n')
	files := map[string][]byte{
		"request.pb":             rawRequest,
		"resources.value":        request.GetResources().GetValue(),
		"resources.decoded.json": decoded,
		"resources.type-url.txt": []byte(request.GetResources().GetTypeUrl() + "\n"),
		"schema.txt":             []byte("containerd.services.tasks.v1.UpdateTaskRequest\n"),
	}
	for suffix, data := range files {
		if err := os.WriteFile(prefix+"."+suffix, data, 0o644); err != nil {
			return err
		}
	}
	return writeManifest(prefix, files)
}

func writeManifest(prefix string, files map[string][]byte) error {
	named := make(map[string][]byte, len(files))
	for key, data := range files {
		named[filepath.Base(prefix)+"."+key] = data
	}
	return writeNamedManifest(prefix+".sha256", named)
}

func writeNamedManifest(path string, files map[string][]byte) error {
	keys := make([]string, 0, len(files))
	for key := range files {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var output strings.Builder
	for _, key := range keys {
		sum := sha256.Sum256(files[key])
		fmt.Fprintf(&output, "%s  %s\n", hex.EncodeToString(sum[:]), key)
	}
	return os.WriteFile(path, []byte(output.String()), 0o644)
}

func decodeSpec(raw []byte) ([]byte, error) {
	var spec specs.Spec
	if err := typeurl.UnmarshalToByTypeURL(ociSpecTypeURL, raw, &spec); err != nil {
		return nil, err
	}
	return marshalIndented(spec)
}

func decodeJSON(raw []byte) ([]byte, error) {
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, err
	}
	return marshalIndented(value)
}

type containerMetadataEnvelope struct {
	Version  string `json:"Version"`
	Metadata struct {
		ID        string                   `json:"ID"`
		Name      string                   `json:"Name"`
		SandboxID string                   `json:"SandboxID"`
		Config    *runtime.ContainerConfig `json:"Config"`
		ImageRef  string                   `json:"ImageRef"`
		LogPath   string                   `json:"LogPath"`
	} `json:"Metadata"`
}

type sandboxMetadataEnvelope struct {
	Version  string `json:"Version"`
	Metadata struct {
		ID             string                    `json:"ID"`
		Name           string                    `json:"Name"`
		Config         *runtime.PodSandboxConfig `json:"Config"`
		NetNSPath      string                    `json:"NetNSPath"`
		IP             string                    `json:"IP"`
		AdditionalIPs  []string                  `json:"AdditionalIPs"`
		RuntimeHandler string                    `json:"RuntimeHandler"`
	} `json:"Metadata"`
}

func decodeContainerMetadata(raw []byte) ([]byte, error) {
	var value containerMetadataEnvelope
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, err
	}
	if value.Version == "" || value.Metadata.Config == nil {
		return nil, errors.New("container metadata is missing version or CRI config")
	}
	return marshalIndented(value)
}

func decodeSandboxMetadata(raw []byte) ([]byte, error) {
	var value sandboxMetadataEnvelope
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, err
	}
	if value.Version == "" || value.Metadata.Config == nil {
		return nil, errors.New("sandbox metadata is missing version or CRI config")
	}
	return marshalIndented(value)
}

func marshalIndented(value any) ([]byte, error) {
	output, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(output, '\n'), nil
}

func writeJSON(path string, value any) error {
	output, err := marshalIndented(value)
	if err != nil {
		return err
	}
	return os.WriteFile(path, output, 0o644)
}

func safeName(value string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, value)
}

const cgroupScript = `set -eu
printf 'uname='; uname -a
printf 'proc_cgroup='; cat /proc/self/cgroup
cgroup_count=0
cgroup_path=
while IFS= read -r cgroup_line; do
  case "$cgroup_line" in
    0::*)
      if test "$cgroup_count" != 0; then exit 1; fi
      cgroup_count=1
      cgroup_path=${cgroup_line#0::}
      ;;
  esac
done </proc/self/cgroup
if test "$cgroup_count" != 1 || test -z "$cgroup_path"; then exit 1; fi
test "$(printf '%s\n' "$cgroup_path" | wc -l)" -eq 1
case "$cgroup_path" in /*) ;; *) exit 1 ;; esac
IFS=' ' read -r self_pid _ </proc/self/stat
case "$self_pid" in ''|*[!0-9]*) exit 1 ;; esac
printf 'self_pid=%s\n' "$self_pid"
mount_count=0
while IFS=' ' read -r mount_id parent_id major_minor mount_root mount_point mount_rest; do
  case " $mount_rest " in
    *" - cgroup2 "*)
      test "$mount_count" = 0
      mount_count=1
      cgroup_mount_root=$mount_root
      cgroup_mount_point=$mount_point
      ;;
  esac
done </proc/self/mountinfo
if test "$mount_count" = 0; then
  if test "${S34_CGROUP2_MOUNT_OPTIONAL:-}" = runc-lowlevel; then
    printf 'cgroup_path_resolution=cgroup2-mount-absent\n'
    printf 'cgroup_mount_count=0\n'
    exit 0
  fi
  exit 1
fi
test "$mount_count" = 1
case "$cgroup_mount_root" in /*) ;; *) exit 1 ;; esac
case "$cgroup_mount_point" in /*) ;; *) exit 1 ;; esac
if test "$cgroup_mount_root" = /; then
  relative=$cgroup_path
elif test "$cgroup_path" = "$cgroup_mount_root"; then
  relative=/
else
  case "$cgroup_path" in "$cgroup_mount_root"/*) relative=${cgroup_path#"$cgroup_mount_root"} ;; *) exit 1 ;; esac
fi
case "$relative" in /*) ;; *) exit 1 ;; esac
if test "$relative" = /; then dir=$cgroup_mount_point; else dir=$cgroup_mount_point$relative; fi
test -f "$dir/cgroup.procs"
grep -Fxq "$self_pid" "$dir/cgroup.procs"
resolution=mount-root-relative
printf 'cgroup_dir=%s\n' "$dir"
printf 'cgroup_path_resolution=%s\n' "$resolution"
printf 'cgroup_mount_count=1\n'
printf 'cgroup_mount_root=%s\n' "$cgroup_mount_root"
printf 'cgroup_mount_point=%s\n' "$cgroup_mount_point"
printf 'cgroup_mount_relative=%s\n' "$relative"
printf 'cgroup2_mountinfo='; grep ' - cgroup2 ' /proc/self/mountinfo
for name in cgroup.controllers cgroup.subtree_control cpu.max cpu.weight cpuset.cpus cpuset.cpus.effective cpuset.mems cpuset.mems.effective memory.max memory.low memory.swap.max memory.oom.group pids.max; do
  if test -f "$dir/$name"; then value=$(cat "$dir/$name"); printf '%s=%s\n' "$name" "$value"; else printf '%s=ABSENT\n' "$name"; fi
done
for file in "$dir"/hugetlb.*.max; do
  test -e "$file" || continue
  printf '%s=' "${file##*/}"; cat "$file"
done
`
