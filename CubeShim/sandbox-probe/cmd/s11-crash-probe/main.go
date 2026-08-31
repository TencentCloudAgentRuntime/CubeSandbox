// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// s11-crash-probe verifies containerd's dead-shim delete action against a
// CubeShim sandbox that has already acquired a durable RuntimeResource lease.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	controllerapi "github.com/containerd/containerd/api/services/sandbox/v1"
	typesapi "github.com/containerd/containerd/api/types"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/types/known/anypb"
)

func main() {
	if len(os.Args) != 5 {
		panic("usage: s11-crash-probe CONTAINERD_SOCKET STATE_DIR RELEASE_MARKER SANDBOX_ID")
	}
	socket, stateDir, marker, sandboxID := os.Args[1], os.Args[2], os.Args[3], os.Args[4]
	ctx, cancel := context.WithTimeout(metadata.NewOutgoingContext(context.Background(), metadata.Pairs("containerd-namespace", "s11-crash")), 30*time.Second)
	defer cancel()
	connection, err := grpc.NewClient("passthrough:///containerd",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		}),
	)
	must(err)
	defer connection.Close()
	controller := controllerapi.NewControllerClient(connection)
	_, err = controller.Create(ctx, &controllerapi.ControllerCreateRequest{
		SandboxID:   sandboxID,
		Options:     &anypb.Any{TypeUrl: "runtime.v1.PodSandboxConfig", Value: criPodSandboxConfig()},
		NetnsPath:   "/proc/self/ns/net",
		Annotations: map[string]string{"request.example/crash": "true"},
		Sandboxer:   "shim",
		Sandbox: &typesapi.Sandbox{
			SandboxID: sandboxID,
			Sandboxer: "shim",
			Runtime:   &typesapi.Sandbox_Runtime{Name: "io.containerd.cube.rs"},
		},
	})
	must(err)

	bundle := filepath.Join(stateDir, "io.containerd.sandbox.controller.v1.shim", "s11-crash", sandboxID)
	record := filepath.Join(bundle, "cube-runtime-resource.json")
	must(waitFor(5*time.Second, func() bool { return regularFile(record) }))
	readyFile, continueFile := os.Getenv("S11_CRASH_READY_FILE"), os.Getenv("S11_CRASH_CONTINUE_FILE")
	if (readyFile == "") != (continueFile == "") {
		panic("S11_CRASH_READY_FILE and S11_CRASH_CONTINUE_FILE must be set together")
	}
	if readyFile != "" {
		must(os.WriteFile(readyFile, []byte(record+"\n"), 0o600))
		must(waitFor(60*time.Second, func() bool { return regularFile(continueFile) }))
	}
	pid, err := findShimPID(sandboxID)
	must(err)
	must(syscall.Kill(pid, syscall.SIGKILL))
	must(waitFor(60*time.Second, func() bool { return regularFile(marker) }))
	must(waitFor(60*time.Second, func() bool {
		_, err := os.Stat(bundle)
		return errors.Is(err, os.ErrNotExist)
	}))
	data, err := os.ReadFile(marker)
	must(err)
	if !strings.Contains(string(data), "released "+sandboxID+" 1 ") {
		panic(fmt.Sprintf("unexpected release marker: %q", data))
	}
	if regularFile(record) {
		panic("RuntimeResource cleanup record survived dead-shim delete action")
	}
	result := "S11_SHIM_KILL_RELEASE_OK"
	if readyFile != "" {
		result = "S11_SHIM_KILL_RETRY_RELEASE_OK"
	}
	fmt.Printf("%s pid=%d marker=%s", result, pid, data)
}

func criPodSandboxConfig() []byte {
	metadata := appendString(nil, 1, "s11-crash")
	metadata = appendString(metadata, 2, "s11-crash-uid")
	metadata = appendString(metadata, 3, "default")

	dns := appendString(nil, 1, "10.96.0.10")
	dns = appendString(dns, 2, "default.svc.cluster.local")
	dns = appendString(dns, 3, "ndots:5")

	annotation := appendString(nil, 1, "s11.example/crash")
	annotation = appendString(annotation, 2, "true")

	config := appendMessage(nil, 1, metadata)
	config = appendMessage(config, 4, dns)
	return appendMessage(config, 7, annotation)
}

func appendString(buffer []byte, field protowire.Number, value string) []byte {
	buffer = protowire.AppendTag(buffer, field, protowire.BytesType)
	return protowire.AppendString(buffer, value)
}

func appendMessage(buffer []byte, field protowire.Number, value []byte) []byte {
	buffer = protowire.AppendTag(buffer, field, protowire.BytesType)
	return protowire.AppendBytes(buffer, value)
}

func regularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func waitFor(timeout time.Duration, condition func() bool) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("timed out waiting for integration condition")
}

func findShimPID(sandboxID string) (int, error) {
	entries, err := filepath.Glob("/proc/[0-9]*/cmdline")
	if err != nil {
		return 0, err
	}
	for _, path := range entries {
		data, err := os.ReadFile(path)
		if err != nil || !bytes.Contains(data, []byte("containerd-shim-cube-rs")) || !bytes.Contains(data, []byte(sandboxID)) {
			continue
		}
		pid, err := strconv.Atoi(filepath.Base(filepath.Dir(path)))
		if err == nil && pid != os.Getpid() {
			return pid, nil
		}
	}
	return 0, fmt.Errorf("CubeShim process for %s not found", sandboxID)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
