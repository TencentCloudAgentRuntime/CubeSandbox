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
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/crimetrics"
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
	templateRoot := flag.String("template-root", "/data/cubelet/cri/templates", "published CRI VM template manifests")
	templateBuilder := flag.String("template-builder", "", "command that builds and publishes a missing template profile; empty uses cube-template-builder")
	reaper := flag.String("reaper", runtime.DefaultReaperRoot, "durable cleanup queue")
	metricsAddress := flag.String("metrics-address", ":10098", "Prometheus HTTP listen address; empty disables metrics")
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
	var metrics *crimetrics.Metrics
	if *metricsAddress != "" {
		registry := prometheus.NewRegistry()
		metrics = crimetrics.New(registry)
		registry.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
		eventSocket := filepath.Join(filepath.Dir(*socket), "metrics.sock")
		events, err := metrics.ListenEvents(eventSocket)
		if err != nil {
			return err
		}
		defer events.Close()
		defer os.Remove(eventSocket)
		metricsListener, err := net.Listen("tcp", *metricsAddress)
		if err != nil {
			return err
		}
		metricsServer := &http.Server{
			Handler:           promhttp.HandlerFor(registry, promhttp.HandlerOpts{MaxRequestsInFlight: 2, Timeout: 10 * time.Second}),
			ReadHeaderTimeout: 5 * time.Second,
			WriteTimeout:      15 * time.Second,
			IdleTimeout:       30 * time.Second,
		}
		defer metricsServer.Close()
		go func() {
			if serveErr := metricsServer.Serve(metricsListener); serveErr != nil && serveErr != http.ErrServerClosed {
				log.Printf("Prometheus metrics server: %v", serveErr)
				cancel()
			}
		}()
		log.Printf("Prometheus metrics ready: %s/metrics", metricsListener.Addr())
	}
	store, err := state.Open(filepath.Join(*root, "leases"), nil)
	if err != nil {
		return err
	}
	builderCommand := *templateBuilder
	if builderCommand == "" {
		builderCommand = fmt.Sprintf(
			"/opt/cube-cri/current/bin/cube-template-builder --kernel %s --os-image %s --agent %s",
			filepath.Join(*assets, "kernel"), filepath.Join(*assets, "guest.img"), filepath.Join(*assets, "agent"),
		)
	}
	node, err := adapter.NewNodeAdapter(filepath.Join(*root, "resources"), adapter.Assets{
		KernelPath: filepath.Join(*assets, "kernel"), AgentPath: filepath.Join(*assets, "agent"),
		GuestImagePath: filepath.Join(*assets, "guest.img"), SharedRootBase: filepath.Join(*root, "shared"),
		TemplateRoot: *templateRoot, TemplateBuilder: builderCommand,
	}, metrics)
	if err != nil {
		return err
	}
	fdPath := *socket + ".fd"
	service, registry, err := runtime.NewService(store, node, fdPath, metrics)
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
	options := make([]grpc.ServerOption, 0, 1)
	if metrics != nil {
		options = append(options, grpc.UnaryInterceptor(metrics.UnaryInterceptor))
	}
	server := grpc.NewServer(options...)
	if err = runtime.Register(server, service); err != nil {
		return err
	}
	go service.RunMetricsSampler(ctx, *reaper, 15*time.Second)
	go service.RunReaperSupervisor(ctx, *reaper, time.Second, func(err error) { log.Printf("reaper: %v", err) })
	go func() { <-ctx.Done(); server.Stop() }()
	log.Printf("RuntimeResource ready: %s", *socket)
	return server.Serve(listener)
}
