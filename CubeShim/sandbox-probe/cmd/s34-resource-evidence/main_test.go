// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	tasksapi "github.com/containerd/containerd/api/services/tasks/v1"
	"github.com/containerd/containerd/v2/core/containers"
	"github.com/containerd/typeurl/v2"
	specs "github.com/opencontainers/runtime-spec/specs-go"
	"google.golang.org/protobuf/proto"
	runtime "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestReadResourcesRejectsUnknownField(t *testing.T) {
	path := filepath.Join(t.TempDir(), "resources.json")
	if err := os.WriteFile(path, []byte(`{"cpu":{"shares":42},"unexpected":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readResources(path); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("readResources error = %v, want unknown field", err)
	}
}

func TestRetryCleanupRetriesTransientFailure(t *testing.T) {
	attempts := 0
	pauses := 0
	err := retryCleanup(3, time.Millisecond, func(time.Duration) { pauses++ }, func() (bool, error) {
		attempts++
		if attempts < 3 {
			return false, errors.New("busy")
		}
		return true, nil
	})
	if err != nil {
		t.Fatalf("retryCleanup: %v", err)
	}
	if attempts != 3 || pauses != 2 {
		t.Fatalf("attempts=%d pauses=%d, want 3 and 2", attempts, pauses)
	}
}

func TestRetryCleanupReportsLastFailure(t *testing.T) {
	err := retryCleanup(2, 0, func(time.Duration) {}, func() (bool, error) {
		return false, errors.New("still busy")
	})
	if err == nil || !strings.Contains(err.Error(), "after 2 attempts: still busy") {
		t.Fatalf("retryCleanup error = %v", err)
	}
}

func TestRetryCleanupRejectsZeroAttempts(t *testing.T) {
	err := retryCleanup(0, 0, func(time.Duration) {}, func() (bool, error) {
		t.Fatal("operation must not run")
		return true, nil
	})
	if err == nil || !strings.Contains(err.Error(), "at least one attempt") {
		t.Fatalf("retryCleanup error = %v", err)
	}
}

func TestDumpLoadedContainerInfoIncludesRuntimeIdentity(t *testing.T) {
	specAny, err := typeurl.MarshalAny(&specs.Spec{Version: specs.Version})
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	info := containers.Container{
		ID:      "s34-low-cube-test",
		Runtime: containers.RuntimeInfo{Name: cubeRuntimeName},
		Spec:    specAny,
	}
	if err := dumpLoadedContainerInfo(directory, info); err != nil {
		t.Fatal(err)
	}
	var captured struct {
		ID      string
		Runtime struct{ Name string }
	}
	content, err := os.ReadFile(filepath.Join(directory, "container-info.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(content, &captured); err != nil {
		t.Fatal(err)
	}
	if captured.ID != info.ID || captured.Runtime.Name != cubeRuntimeName {
		t.Fatalf("captured container identity = id:%q runtime:%q", captured.ID, captured.Runtime.Name)
	}
	if _, err := os.Stat(filepath.Join(directory, "container-spec.any.pb")); err != nil {
		t.Fatalf("raw OCI spec evidence: %v", err)
	}
}

func TestCgroupProbeProcessUsesAbsoluteShellPath(t *testing.T) {
	process := cgroupProbeProcess(cubeRuntimeName)
	if len(process.Args) != 3 || process.Args[0] != "/bin/sh" || process.Args[1] != "-c" || process.Args[2] != cgroupScript {
		t.Fatalf("cgroup probe args = %q, want absolute /bin/sh invocation", process.Args)
	}
	if process.Cwd != "/" || process.User.UID != 0 || process.User.GID != 0 {
		t.Fatalf("cgroup probe identity/cwd = uid:%d gid:%d cwd:%q", process.User.UID, process.User.GID, process.Cwd)
	}
	for _, marker := range []string{"cgroup_count=0", "if test \"$cgroup_count\" != 0; then exit 1; fi", "if test \"$cgroup_count\" != 1 || test -z \"$cgroup_path\"; then exit 1; fi", "cgroup_path=${cgroup_line#0::}", "read -r self_pid _ </proc/self/stat", "S34_CGROUP2_MOUNT_OPTIONAL", "cgroup2-mount-absent", "cgroup_mount_root", "relative=${cgroup_path#\"$cgroup_mount_root\"}", "grep -Fxq \"$self_pid\"", "cube-agent-parent", "agent-parent-with-runtime-leaf", "/runtime) resource_relative=/", "resource_relative=${relative%/runtime}", "resource_pid_match=$?", "case \"$resource_pid_match\" in 0) exit 1 ;; 1) ;; *) exit 1 ;; esac", "cgroup_process_dir", "cgroup_resource_dir", "process.%s", "mount-root-relative", "hugetlb.*.max"} {
		if !strings.Contains(process.Args[2], marker) {
			t.Fatalf("cgroup probe script does not contain %q", marker)
		}
	}
	cubeEnv := strings.Join(process.Env, "\n")
	if strings.Contains(cubeEnv, "S34_CGROUP2_MOUNT_OPTIONAL=") {
		t.Fatalf("Cube cgroup probe unexpectedly permits a missing cgroup2 mount: %q", process.Env)
	}
	if !strings.Contains(cubeEnv, "S34_CGROUP_LAYOUT=cube-agent-parent") {
		t.Fatalf("Cube cgroup probe does not select the Agent parent layout: %q", process.Env)
	}
	runcProcess := cgroupProbeProcess(runcRuntimeName)
	runcEnv := strings.Join(runcProcess.Env, "\n")
	if !strings.Contains(runcEnv, "S34_CGROUP2_MOUNT_OPTIONAL=runc-lowlevel") {
		t.Fatalf("runc low-level cgroup probe does not declare its mount exception: %q", runcProcess.Env)
	}
	if !strings.Contains(runcEnv, "S34_CGROUP_LAYOUT=runc-process-leaf") {
		t.Fatalf("runc cgroup probe does not select the process leaf layout: %q", runcProcess.Env)
	}
}

func TestWithProbeProcessAddsStandardReadOnlyCgroupMount(t *testing.T) {
	resources := &specs.LinuxResources{CPU: &specs.LinuxCPU{Shares: uint64Pointer(512)}}
	spec := &specs.Spec{
		Process: &specs.Process{},
		Linux:   &specs.Linux{},
		Mounts:  []specs.Mount{{Destination: "/proc", Type: "proc", Source: "proc"}},
	}
	if err := withProbeProcess(resources)(context.Background(), nil, nil, spec); err != nil {
		t.Fatal(err)
	}
	if spec.Linux.Resources != resources {
		t.Fatal("probe resources pointer was not preserved")
	}
	if got := spec.Process.Args; len(got) != 3 || got[0] != "sh" || got[1] != "-c" || got[2] != "exec sleep 3600" {
		t.Fatalf("probe process args = %q", got)
	}
	var cgroupMounts []specs.Mount
	for _, mount := range spec.Mounts {
		if mount.Destination == "/sys/fs/cgroup" {
			cgroupMounts = append(cgroupMounts, mount)
		}
	}
	if len(cgroupMounts) != 1 {
		t.Fatalf("cgroup mount count = %d, want 1", len(cgroupMounts))
	}
	want := specs.Mount{
		Destination: "/sys/fs/cgroup",
		Type:        "cgroup",
		Source:      "cgroup",
		Options:     []string{"nosuid", "noexec", "nodev", "relatime", "ro"},
	}
	if !reflect.DeepEqual(cgroupMounts[0], want) {
		t.Fatalf("cgroup mount = %+v, want %+v", cgroupMounts[0], want)
	}
	if countNamespaces(spec.Linux.Namespaces, specs.CgroupNamespace) != 1 {
		t.Fatalf("cgroup namespace count = %d, want 1", countNamespaces(spec.Linux.Namespaces, specs.CgroupNamespace))
	}
}

func TestWithProbeProcessRejectsIncompleteSpec(t *testing.T) {
	for _, spec := range []*specs.Spec{{}, {Process: &specs.Process{}}, {Linux: &specs.Linux{}}} {
		if err := withProbeProcess(&specs.LinuxResources{})(context.Background(), nil, nil, spec); err == nil {
			t.Fatalf("incomplete spec %+v unexpectedly accepted", spec)
		}
	}
}

func TestWithProbeProcessRejectsDuplicateCgroupMount(t *testing.T) {
	spec := &specs.Spec{
		Process: &specs.Process{},
		Linux:   &specs.Linux{},
		Mounts:  []specs.Mount{{Destination: "/sys/fs/cgroup", Type: "cgroup", Source: "cgroup"}},
	}
	err := withProbeProcess(&specs.LinuxResources{})(context.Background(), nil, nil, spec)
	if err == nil || !strings.Contains(err.Error(), "already contains /sys/fs/cgroup") {
		t.Fatalf("duplicate cgroup mount error = %v", err)
	}
}

func TestWithProbeProcessPreservesSingleCgroupNamespace(t *testing.T) {
	spec := &specs.Spec{
		Process: &specs.Process{},
		Linux: &specs.Linux{Namespaces: []specs.LinuxNamespace{
			{Type: specs.PIDNamespace},
			{Type: specs.CgroupNamespace},
		}},
	}
	if err := withProbeProcess(&specs.LinuxResources{})(context.Background(), nil, nil, spec); err != nil {
		t.Fatal(err)
	}
	if countNamespaces(spec.Linux.Namespaces, specs.CgroupNamespace) != 1 {
		t.Fatalf("cgroup namespace count = %d, want 1", countNamespaces(spec.Linux.Namespaces, specs.CgroupNamespace))
	}
}

func TestWithProbeProcessRejectsDuplicateCgroupNamespaces(t *testing.T) {
	spec := &specs.Spec{
		Process: &specs.Process{},
		Linux: &specs.Linux{Namespaces: []specs.LinuxNamespace{
			{Type: specs.CgroupNamespace},
			{Type: specs.CgroupNamespace},
		}},
	}
	err := withProbeProcess(&specs.LinuxResources{})(context.Background(), nil, nil, spec)
	if err == nil || !strings.Contains(err.Error(), "contains 2 cgroup namespaces") {
		t.Fatalf("duplicate cgroup namespace error = %v", err)
	}
}

func TestWithProbeProcessRejectsJoinedCgroupNamespace(t *testing.T) {
	spec := &specs.Spec{
		Process: &specs.Process{},
		Linux: &specs.Linux{Namespaces: []specs.LinuxNamespace{
			{Type: specs.CgroupNamespace, Path: "/proc/1/ns/cgroup"},
		}},
	}
	err := withProbeProcess(&specs.LinuxResources{})(context.Background(), nil, nil, spec)
	if err == nil || !strings.Contains(err.Error(), "cgroup namespace joins") {
		t.Fatalf("joined cgroup namespace error = %v", err)
	}
}

func TestMetadataDecodersUsePinnedCRIShape(t *testing.T) {
	containerRaw := []byte(`{"Version":"v1","Metadata":{"ID":"container","Config":{"metadata":{"name":"app"},"linux":{"resources":{"cpu_shares":42}}}}}`)
	decoded, err := decodeContainerMetadata(containerRaw)
	if err != nil {
		t.Fatal(err)
	}
	var container containerMetadataEnvelope
	if err := json.Unmarshal(decoded, &container); err != nil {
		t.Fatal(err)
	}
	if got := container.Metadata.Config.GetLinux().GetResources().GetCpuShares(); got != 42 {
		t.Fatalf("container cpu shares = %d, want 42", got)
	}

	sandboxRaw := []byte(`{"Version":"v1","Metadata":{"ID":"sandbox","Config":{"metadata":{"name":"pod"},"linux":{"resources":{"cpu_shares":84}}}}}`)
	decoded, err = decodeSandboxMetadata(sandboxRaw)
	if err != nil {
		t.Fatal(err)
	}
	var sandbox sandboxMetadataEnvelope
	if err := json.Unmarshal(decoded, &sandbox); err != nil {
		t.Fatal(err)
	}
	if got := sandbox.Metadata.Config.GetLinux().GetResources().GetCpuShares(); got != 84 {
		t.Fatalf("sandbox cpu shares = %d, want 84", got)
	}

	if _, err := decodeContainerMetadata([]byte(`{"Version":"v1","Metadata":{}}`)); err == nil {
		t.Fatal("metadata without CRI config unexpectedly decoded")
	}
}

func TestContainerMetadataKeysCoverLiveAndCurrentStores(t *testing.T) {
	if containerMetadataKey != "io.containerd.cri.container.metadata" {
		t.Fatalf("current container metadata key = %q", containerMetadataKey)
	}
	if legacyContainerMetaKey != "io.cri-containerd.container.metadata" {
		t.Fatalf("live container metadata key = %q", legacyContainerMetaKey)
	}
}

func TestDumpUpdatePreservesExactRequestAndResources(t *testing.T) {
	resources := &specs.LinuxResources{CPU: &specs.LinuxCPU{Shares: uint64Pointer(512)}}
	anyResources, err := typeurl.MarshalAny(resources)
	if err != nil {
		t.Fatal(err)
	}
	if anyResources.GetTypeUrl() != ociLinuxResourcesTypeURL {
		t.Fatalf("type URL = %q, want %q", anyResources.GetTypeUrl(), ociLinuxResourcesTypeURL)
	}
	request := &tasksapi.UpdateTaskRequest{
		ContainerID: "owned-container",
		Resources:   typeurl.MarshalProto(anyResources),
	}
	prefix := filepath.Join(t.TempDir(), "update")
	if err := dumpUpdate(prefix, request, resources); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(prefix + ".request.pb")
	if err != nil {
		t.Fatal(err)
	}
	var restored tasksapi.UpdateTaskRequest
	if err := proto.Unmarshal(raw, &restored); err != nil {
		t.Fatal(err)
	}
	if restored.GetContainerID() != request.GetContainerID() || restored.GetResources().GetTypeUrl() != ociLinuxResourcesTypeURL {
		t.Fatalf("restored request = %+v", &restored)
	}
	if string(restored.GetResources().GetValue()) != string(anyResources.GetValue()) {
		t.Fatal("resource Any value changed in captured request")
	}
	manifest, err := os.ReadFile(prefix + ".sha256")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(manifest), "update.request.pb") || !strings.Contains(string(manifest), "update.resources.value") {
		t.Fatalf("manifest missing raw artifacts:\n%s", manifest)
	}
}

func TestPathHasElement(t *testing.T) {
	if !pathHasElement("/run/containerd/ns/owned-id/config.json", "owned-id") {
		t.Fatal("exact path element was not found")
	}
	if pathHasElement("/run/containerd/ns/owned-id-other/config.json", "owned-id") {
		t.Fatal("substring path element was accepted")
	}
}

func TestFilterBundleWalkErrorOnlyIgnoresUnrelatedDisappearance(t *testing.T) {
	notExist := &os.PathError{Op: "open", Path: "/run/containerd/runtime/unrelated", Err: os.ErrNotExist}
	if err := filterBundleWalkError("owned-id", "/run/containerd/runtime/unrelated", notExist); err != nil {
		t.Fatalf("unrelated disappearance was not ignored: %v", err)
	}
	if err := filterBundleWalkError("owned-id", "/run/containerd/runtime/owned-id", notExist); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("target disappearance error = %v, want ErrNotExist", err)
	}
	if err := filterBundleWalkError("owned-id", "/run/containerd", notExist); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("search root disappearance error = %v, want ErrNotExist", err)
	}
	permission := &os.PathError{Op: "open", Path: "/run/containerd/runtime/unrelated", Err: os.ErrPermission}
	if err := filterBundleWalkError("owned-id", "/run/containerd/runtime/unrelated", permission); !errors.Is(err, os.ErrPermission) {
		t.Fatalf("unrelated permission error = %v, want ErrPermission", err)
	}
}

func TestWriteBundleConfigEvidenceRecordsOptionalSandboxAbsence(t *testing.T) {
	directory := t.TempDir()
	if err := writeBundleConfigEvidence("sandbox-id", directory, nil, false); err != nil {
		t.Fatal(err)
	}
	absence, err := os.ReadFile(filepath.Join(directory, "bundle-config-absence.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(absence) != "sandbox_id=sandbox-id\nlive_bundle_config=absent\nsearch_root=/run/containerd\n" {
		t.Fatalf("absence evidence = %q", absence)
	}
	paths, err := os.ReadFile(filepath.Join(directory, "bundle-config-paths.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) != 0 {
		t.Fatalf("optional missing bundle paths = %q, want empty", paths)
	}
	manifest, err := os.ReadFile(filepath.Join(directory, "bundle-config.sha256"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(manifest), "bundle-config-absence.txt") || !strings.Contains(string(manifest), "bundle-config-paths.tsv") {
		t.Fatalf("optional absence manifest is incomplete:\n%s", manifest)
	}
}

func TestWriteBundleConfigEvidenceRequiresContainerBundle(t *testing.T) {
	if err := writeBundleConfigEvidence("container-id", t.TempDir(), nil, true); err == nil || !strings.Contains(err.Error(), "no live bundle config.json") {
		t.Fatalf("required bundle error = %v", err)
	}
}

func TestSandboxBundleRequirementIsRuntimeSpecific(t *testing.T) {
	required, err := sandboxBundleRequired(runcRuntimeName)
	if err != nil || !required {
		t.Fatalf("runc bundle requirement = %v, %v", required, err)
	}
	required, err = sandboxBundleRequired(cubeRuntimeName)
	if err != nil || required {
		t.Fatalf("Cube bundle requirement = %v, %v", required, err)
	}
	if _, err := sandboxBundleRequired("unknown.runtime"); err == nil {
		t.Fatal("unknown sandbox runtime unexpectedly accepted")
	}
}

func TestDecodeUpdateCommandPreservesCRIBytes(t *testing.T) {
	request := &runtime.UpdateContainerResourcesRequest{
		ContainerId: "owned-container",
		Linux:       &runtime.LinuxContainerResources{CpuShares: 512, MemoryLimitInBytes: 268435456},
	}
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	input := filepath.Join(directory, "input.pb")
	if err := os.WriteFile(input, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	prefix := filepath.Join(directory, "decoded")
	if err := decodeUpdateCommand([]string{"cri", input, prefix}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(prefix + ".request.pb")
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(raw) {
		t.Fatal("decoded CRI trace did not preserve raw bytes")
	}
	schema, err := os.ReadFile(prefix + ".schema.txt")
	if err != nil {
		t.Fatal(err)
	}
	if string(schema) != "runtime.v1.UpdateContainerResourcesRequest\nmodule=k8s.io/cri-api@v0.36.4\n" {
		t.Fatalf("CRI schema pin = %q", schema)
	}
}

func uint64Pointer(value uint64) *uint64 { return &value }

func countNamespaces(namespaces []specs.LinuxNamespace, namespaceType specs.LinuxNamespaceType) int {
	count := 0
	for _, namespace := range namespaces {
		if namespace.Type == namespaceType {
			count++
		}
	}
	return count
}
