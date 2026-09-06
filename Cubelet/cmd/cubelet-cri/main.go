// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// cubelet-cri serves only the node RuntimeResource API used by CubeShim.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	adapter "github.com/tencentcloud/CubeSandbox/Cubelet/plugins/cube/runtime_resource"
	runtime "github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	root := flag.String("root", "/data/cubelet/cri", "persistent state and shared mounts")
	socket := flag.String("address", "/run/cube-cri/runtime-resource.sock", "RuntimeResource Unix socket")
	assets := flag.String("assets", "/opt/cube-cri/current/assets", "kernel, agent and guest.img directory")
	reaper := flag.String("reaper", runtime.DefaultReaperRoot, "durable cleanup queue")
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()
	for _, dir := range []string{*root, filepath.Dir(*socket), *reaper} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return err
		}
	}
	// Hold the lock before removing stale sockets or recovering leases.
	lock, err := os.OpenFile(filepath.Join(*root, "service.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return fmt.Errorf("runtime resource already running: %w", err)
	}
	store, err := state.Open(filepath.Join(*root, "leases"), nil)
	if err != nil {
		return err
	}
	node, err := adapter.NewNodeAdapter(filepath.Join(*root, "resources"), adapter.Assets{
		KernelPath: filepath.Join(*assets, "kernel"), AgentPath: filepath.Join(*assets, "agent"),
		GuestImagePath: filepath.Join(*assets, "guest.img"), SharedRootBase: filepath.Join(*root, "shared"),
	})
	if err != nil {
		return err
	}
	fdPath := *socket + ".fd"
	service, registry, err := runtime.NewService(store, node, fdPath)
	if err != nil {
		return err
	}
	if err = service.Recover(ctx); err != nil {
		return err
	}
	if err = service.RecoverReaperJobs(ctx, *reaper); err != nil {
		return err
	}
	fd, err := handoff.Listen(fdPath, 0600, registry, handoff.AuthorizePeerIDs(syscall.Ucred{Uid: 0, Gid: 0}))
	if err != nil {
		return err
	}
	defer fd.Close()
	if err = os.Remove(*socket); err != nil && !os.IsNotExist(err) {
		return err
	}
	listener, err := net.Listen("unix", *socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	if err = os.Chmod(*socket, 0600); err != nil {
		return err
	}
	server := grpc.NewServer()
	if err = runtime.Register(server, service); err != nil {
		return err
	}
	go service.RunReaperSupervisor(ctx, *reaper, time.Second, func(err error) { log.Printf("reaper: %v", err) })
	go func() { <-ctx.Done(); server.Stop() }()
	log.Printf("RuntimeResource ready: %s", *socket)
	return server.Serve(listener)
}
