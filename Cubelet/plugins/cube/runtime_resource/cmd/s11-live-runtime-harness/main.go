// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// s11-live-runtime-harness serves the production Linux RuntimeResource adapter
// without starting the rest of Cubelet. It is only for privileged S1.1 cloud
// validation against a real CNI-created Pod network namespace.
package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	runtimeresource "github.com/tencentcloud/CubeSandbox/Cubelet/plugins/cube/runtime_resource"
	runtimeservice "github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc"
)

func main() {
	if len(os.Args) != 5 && len(os.Args) != 6 {
		panic("usage: s11-live-runtime-harness STATE_DIR GRPC_SOCKET FD_SOCKET ASSET_DIR [REAPER_DIR]")
	}
	stateDir, grpcPath, fdPath, assetDir := os.Args[1], os.Args[2], os.Args[3], os.Args[4]
	reaperDir := filepath.Join(stateDir, "reaper")
	if len(os.Args) == 6 {
		reaperDir = os.Args[5]
	}
	sharedRoot := os.Getenv("S11_RUNTIME_HARNESS_SHARED_ROOT")
	if sharedRoot == "" {
		sharedRoot = "/data/cubelet/s11-runtime-harness/shared"
	}
	sharedRoot = filepath.Clean(sharedRoot)
	relative, err := filepath.Rel("/data/cubelet", sharedRoot)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		panic("S11_RUNTIME_HARNESS_SHARED_ROOT must be a subdirectory of /data/cubelet")
	}
	for _, directory := range []string{stateDir, filepath.Dir(grpcPath), filepath.Dir(fdPath)} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			panic(err)
		}
	}
	store, err := state.Open(filepath.Join(stateDir, "leases"), nil)
	if err != nil {
		panic(err)
	}
	adapter, err := runtimeresource.NewNodeAdapter(filepath.Join(stateDir, "adapter"), runtimeresource.Assets{
		KernelPath: filepath.Join(assetDir, "kernel"), AgentPath: filepath.Join(assetDir, "agent"),
		GuestImagePath: filepath.Join(assetDir, "guest.img"), SharedRootBase: sharedRoot,
	})
	if err != nil {
		panic(err)
	}
	service, registry, err := runtimeservice.NewService(store, adapter, fdPath)
	if err != nil {
		panic(err)
	}
	if err := service.Recover(context.Background()); err != nil {
		panic(err)
	}
	if err := service.RecoverReaperJobs(context.Background(), reaperDir); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go service.RunReaperSupervisor(ctx, reaperDir, 100*time.Millisecond, func(err error) {
		fmt.Fprintf(os.Stderr, "RuntimeResource reaper retry: %v\n", err)
	})
	fdListener, err := handoff.Listen(fdPath, 0o660, registry, handoff.AuthorizePeerIDs(syscall.Ucred{Uid: uint32(os.Getuid()), Gid: uint32(os.Getgid())}))
	if err != nil {
		panic(err)
	}
	defer fdListener.Close()
	_ = os.Remove(grpcPath)
	listener, err := net.Listen("unix", grpcPath)
	if err != nil {
		panic(err)
	}
	server := grpc.NewServer()
	if err := runtimeservice.Register(server, service); err != nil {
		panic(err)
	}
	fmt.Printf("S11_LIVE_RUNTIME_HARNESS_READY %s shared_root=%s\n", grpcPath, sharedRoot)
	if err := server.Serve(listener); err != nil {
		panic(err)
	}
}
