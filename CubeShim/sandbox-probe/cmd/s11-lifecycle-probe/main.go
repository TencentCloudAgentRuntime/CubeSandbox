// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// s11-lifecycle-probe drives one Cube sandbox through the public containerd
// Sandbox Controller API and verifies the externally visible lifecycle.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	bootapi "github.com/containerd/containerd/api/runtime/bootstrap/v1"
	runtimeapi "github.com/containerd/containerd/api/runtime/sandbox/v1"
	controllerapi "github.com/containerd/containerd/api/services/sandbox/v1"
	typesapi "github.com/containerd/containerd/api/types"
	"github.com/containerd/ttrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	grpcstatus "google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/types/known/anypb"
)

const sandboxer = "shim"

func main() {
	if len(os.Args) != 5 {
		panic("usage: s11-lifecycle-probe CONTAINERD_SOCKET STATE_DIR NETNS_PATH SANDBOX_ID")
	}
	socket, stateDir, netnsPath, sandboxID := os.Args[1], os.Args[2], os.Args[3], os.Args[4]
	for name, value := range map[string]string{"containerd socket": socket, "state dir": stateDir, "netns path": netnsPath, "sandbox ID": sandboxID} {
		if strings.TrimSpace(value) == "" {
			panic(name + " is empty")
		}
	}
	if !filepath.IsAbs(stateDir) || !filepath.IsAbs(netnsPath) {
		panic("state dir and netns path must be absolute")
	}
	if _, err := os.Stat(netnsPath); err != nil {
		panic(fmt.Sprintf("netns path: %v", err))
	}

	connection, err := grpc.NewClient("passthrough:///containerd",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		}),
	)
	must(err)
	defer connection.Close()
	controller := controllerapi.NewControllerClient(connection)
	bundle := filepath.Join(stateDir, "io.containerd.sandbox.controller.v1.shim", "s11-live", sandboxID)
	preflightCtx, preflightCancel := requestContext(30 * time.Second)
	preflight, preflightErr := controller.Status(preflightCtx, &controllerapi.ControllerStatusRequest{SandboxID: sandboxID, Verbose: false, Sandboxer: sandboxer})
	preflightCancel()
	if preflightErr != nil {
		panic(fmt.Sprintf("check sandbox ID availability: %v", preflightErr))
	}
	if preflight.GetSandboxID() != sandboxID || preflight.GetState() != "" || preflight.GetPid() != 0 {
		panic(fmt.Sprintf("sandbox ID is already in use: state=%q pid=%d", preflight.GetState(), preflight.GetPid()))
	}
	if _, statErr := os.Stat(bundle); statErr == nil {
		panic("sandbox ID has an existing shim bundle")
	} else if !errors.Is(statErr, os.ErrNotExist) {
		panic(fmt.Sprintf("inspect sandbox bundle: %v", statErr))
	}
	cleanupOwned, shutdown := true, false
	defer func() {
		if !cleanupOwned || shutdown {
			return
		}
		stopCtx, stopCancel := requestContext(30 * time.Second)
		_, stopErr := controller.Stop(stopCtx, &controllerapi.ControllerStopRequest{SandboxID: sandboxID, TimeoutSecs: 10, Sandboxer: sandboxer})
		stopCancel()
		if stopErr != nil {
			fmt.Fprintf(os.Stderr, "S11_CLEANUP_STOP_ERROR sandbox=%s error=%v\n", sandboxID, stopErr)
		}
		shutdownCtx, shutdownCancel := requestContext(30 * time.Second)
		_, shutdownErr := controller.Shutdown(shutdownCtx, &controllerapi.ControllerShutdownRequest{SandboxID: sandboxID, Sandboxer: sandboxer})
		shutdownCancel()
		if shutdownErr != nil {
			fmt.Fprintf(os.Stderr, "S11_CLEANUP_SHUTDOWN_ERROR sandbox=%s error=%v\n", sandboxID, shutdownErr)
		}
	}()

	ctx, cancel := requestContext(2 * time.Minute)
	create, err := controller.Create(ctx, &controllerapi.ControllerCreateRequest{
		SandboxID:   sandboxID,
		Options:     &anypb.Any{TypeUrl: "runtime.v1.PodSandboxConfig", Value: criPodSandboxConfig()},
		NetnsPath:   netnsPath,
		Annotations: map[string]string{"s11.cubesandbox.io/lifecycle": "true"},
		Sandboxer:   sandboxer,
		Sandbox: &typesapi.Sandbox{
			SandboxID: sandboxID,
			Sandboxer: sandboxer,
			Runtime:   &typesapi.Sandbox_Runtime{Name: "io.containerd.cube.rs"},
		},
	})
	cancel()
	if createCollision(err, bundle) {
		cleanupOwned = false
	}
	must(err)
	if create.GetSandboxID() != sandboxID {
		panic(fmt.Sprintf("Create sandbox ID = %q, want %q", create.GetSandboxID(), sandboxID))
	}
	record := filepath.Join(bundle, "cube-runtime-resource.json")
	must(waitFor(30*time.Second, func() bool { return directory(bundle) && regularFile(record) }))

	createdStatus := status(controller, sandboxID)
	assertStatus(createdStatus, "SANDBOX_NOTREADY", "Created")
	lease := createdStatus.GetInfo()["runtime_lease"]
	generation := createdStatus.GetInfo()["runtime_generation"]
	if lease == "" || generation != "1" {
		panic(fmt.Sprintf("invalid RuntimeResource identity lease=%q generation=%q", lease, generation))
	}

	platform, err := sandboxPlatform(controller, bundle, sandboxID)
	must(err)
	if platform.GetOS() != "linux" || platform.GetArchitecture() != "amd64" {
		panic(fmt.Sprintf("unexpected platform: %v", platform))
	}

	ctx, cancel = requestContext(3 * time.Minute)
	started, err := controller.Start(ctx, &controllerapi.ControllerStartRequest{SandboxID: sandboxID, Sandboxer: sandboxer})
	cancel()
	must(err)
	if started.GetPid() == 0 || started.GetCreatedAt() == nil {
		panic(fmt.Sprintf("invalid Start response pid=%d created_at=%v", started.GetPid(), started.GetCreatedAt()))
	}
	readyStatus := status(controller, sandboxID)
	assertStatus(readyStatus, "SANDBOX_READY", "Ready")
	if readyStatus.GetInfo()["runtime_lease"] != lease || readyStatus.GetInfo()["runtime_generation"] != generation {
		panic("RuntimeResource identity changed during Start")
	}

	ctx, cancel = requestContext(2 * time.Minute)
	_, err = controller.Stop(ctx, &controllerapi.ControllerStopRequest{SandboxID: sandboxID, TimeoutSecs: 30, Sandboxer: sandboxer})
	cancel()
	must(err)
	stoppedStatus := status(controller, sandboxID)
	assertStatus(stoppedStatus, "SANDBOX_NOTREADY", "Stopped")
	if stoppedStatus.GetInfo()["runtime_lease"] != "" || stoppedStatus.GetInfo()["runtime_generation"] != "" {
		panic("RuntimeResource identity survived Stop")
	}
	must(waitFor(30*time.Second, func() bool {
		_, err := os.Stat(record)
		return errors.Is(err, os.ErrNotExist)
	}))
	if !directory(bundle) {
		panic("sandbox bundle disappeared before Shutdown")
	}

	ctx, cancel = requestContext(30 * time.Second)
	waited, err := controller.Wait(ctx, &controllerapi.ControllerWaitRequest{SandboxID: sandboxID, Sandboxer: sandboxer})
	cancel()
	must(err)
	if waited.GetExitStatus() != 0 || waited.GetExitedAt() == nil {
		panic(fmt.Sprintf("invalid Wait response exit=%d exited_at=%v", waited.GetExitStatus(), waited.GetExitedAt()))
	}

	ctx, cancel = requestContext(30 * time.Second)
	_, err = controller.Shutdown(ctx, &controllerapi.ControllerShutdownRequest{SandboxID: sandboxID, Sandboxer: sandboxer})
	cancel()
	must(err)
	shutdown = true
	must(waitFor(60*time.Second, func() bool {
		_, err := os.Stat(bundle)
		return errors.Is(err, os.ErrNotExist)
	}))
	fmt.Printf("S11_CUBE_LIFECYCLE_OK sandbox=%s lease=%s generation=%s pid=%d\n", sandboxID, lease, generation, started.GetPid())
}

func requestContext(timeout time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(metadata.NewOutgoingContext(context.Background(), metadata.Pairs("containerd-namespace", "s11-live")), timeout)
}

func sandboxPlatform(controller controllerapi.ControllerClient, bundle, sandboxID string) (*typesapi.Platform, error) {
	ctx, cancel := requestContext(2 * time.Minute)
	response, err := controller.Platform(ctx, &controllerapi.ControllerPlatformRequest{SandboxID: sandboxID, Sandboxer: sandboxer})
	cancel()
	if err == nil {
		if response.GetPlatform() == nil {
			return nil, errors.New("containerd Controller.Platform returned no platform")
		}
		return response.GetPlatform(), nil
	}
	if grpcstatus.Code(err) != codes.Unimplemented {
		return nil, fmt.Errorf("containerd Controller.Platform: %w", err)
	}

	platform, directErr := shimPlatform(bundle, sandboxID)
	if directErr != nil {
		return nil, fmt.Errorf("containerd Controller.Platform is unimplemented; direct shim Platform: %w", directErr)
	}
	fmt.Printf("S11_PLATFORM_DIRECT_TTRPC_FALLBACK sandbox=%s\n", sandboxID)
	return platform, nil
}

func shimPlatform(bundle, sandboxID string) (*typesapi.Platform, error) {
	bootstrap, err := os.ReadFile(filepath.Join(bundle, "bootstrap.json"))
	if err != nil {
		return nil, fmt.Errorf("read bootstrap.json: %w", err)
	}
	socket, err := parseShimBootstrap(bootstrap)
	if err != nil {
		return nil, err
	}

	ctx, cancel := requestContext(2 * time.Minute)
	defer cancel()
	connection, err := (&net.Dialer{}).DialContext(ctx, "unix", socket)
	if err != nil {
		return nil, fmt.Errorf("dial CubeShim socket: %w", err)
	}
	client := ttrpc.NewClient(connection)
	defer client.Close()
	response, err := runtimeapi.NewTTRPCSandboxClient(client).Platform(ctx, &runtimeapi.PlatformRequest{SandboxID: sandboxID})
	if err != nil {
		return nil, fmt.Errorf("call CubeShim Platform: %w", err)
	}
	if response.GetPlatform() == nil {
		return nil, errors.New("CubeShim Platform returned no platform")
	}
	return response.GetPlatform(), nil
}

func parseShimBootstrap(data []byte) (string, error) {
	var result bootapi.BootstrapResult
	if err := json.Unmarshal(data, &result); err != nil {
		return "", fmt.Errorf("decode bootstrap.json: %w", err)
	}
	if result.GetVersion() != 3 {
		return "", fmt.Errorf("bootstrap.json version = %d, want 3", result.GetVersion())
	}
	if result.GetProtocol() != "ttrpc" {
		return "", fmt.Errorf("bootstrap.json protocol = %q, want ttrpc", result.GetProtocol())
	}
	const unixPrefix = "unix://"
	if !strings.HasPrefix(result.GetAddress(), unixPrefix) {
		return "", fmt.Errorf("bootstrap.json address = %q, want unix:// absolute path", result.GetAddress())
	}
	socket := strings.TrimPrefix(result.GetAddress(), unixPrefix)
	if !filepath.IsAbs(socket) {
		return "", fmt.Errorf("bootstrap.json socket = %q, want absolute path", socket)
	}
	return socket, nil
}

func status(controller controllerapi.ControllerClient, sandboxID string) *controllerapi.ControllerStatusResponse {
	ctx, cancel := requestContext(30 * time.Second)
	defer cancel()
	response, err := controller.Status(ctx, &controllerapi.ControllerStatusRequest{SandboxID: sandboxID, Verbose: true, Sandboxer: sandboxer})
	must(err)
	return response
}

func assertStatus(response *controllerapi.ControllerStatusResponse, state, phase string) {
	if response.GetState() != state || response.GetInfo()["phase"] != phase {
		panic(fmt.Sprintf("Status state=%q phase=%q, want state=%q phase=%q", response.GetState(), response.GetInfo()["phase"], state, phase))
	}
}

func createCollision(err error, bundle string) bool {
	if grpcstatus.Code(err) == codes.AlreadyExists {
		return true
	}
	if grpcstatus.Code(err) != codes.Unknown {
		return false
	}
	want := "mkdir " + bundle + ": file exists"
	return strings.Contains(grpcstatus.Convert(err).Message(), want)
}

func criPodSandboxConfig() []byte {
	meta := appendString(nil, 1, "s11-live")
	meta = appendString(meta, 2, "s11-live-uid")
	meta = appendString(meta, 3, "default")
	dns := appendString(nil, 1, "10.96.0.10")
	dns = appendString(dns, 2, "default.svc.cluster.local")
	dns = appendString(dns, 3, "ndots:5")
	annotation := appendString(nil, 1, "s11.cubesandbox.io/lifecycle")
	annotation = appendString(annotation, 2, "true")
	config := appendMessage(nil, 1, meta)
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

func directory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func regularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
