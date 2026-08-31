// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/containerd/log"

	"github.com/containerd/containerd/v2/plugins"
	"github.com/containerd/plugin"
	"github.com/containerd/plugin/registry"
	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/constants"
	runtimeservice "github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"google.golang.org/grpc"
)

const pluginID = "runtime-resource"

type Config struct {
	Enabled        bool   `toml:"enabled"`
	StateDir       string `toml:"state_dir"`
	SharedRoot     string `toml:"shared_root"`
	FDHandoff      string `toml:"fd_handoff"`
	ReaperDir      string `toml:"reaper_dir"`
	KernelPath     string `toml:"kernel_path"`
	AgentPath      string `toml:"agent_path"`
	GuestImagePath string `toml:"guest_image_path"`
	PeerUID        uint32 `toml:"peer_uid"`
	PeerGID        uint32 `toml:"peer_gid"`
	SocketMode     uint32 `toml:"socket_mode"`
}

type disabled struct{}

type servicePlugin struct {
	service  *runtimeservice.Service
	listener *handoff.Listener
}

func init() {
	registry.Register(&plugin.Registration{
		Type:   constants.CubeboxServicePlugin,
		ID:     pluginID,
		Config: &Config{},
		InitFn: initPlugin,
	})
}

func initPlugin(ic *plugin.InitContext) (interface{}, error) {
	config := ic.Config.(*Config)
	if !config.Enabled {
		return &disabled{}, nil
	}
	root := ic.Properties[plugins.PropertyRootDir]
	volatile := ic.Properties[plugins.PropertyStateDir]
	if config.StateDir == "" {
		config.StateDir = filepath.Join(root, pluginID)
	}
	if config.SharedRoot == "" {
		config.SharedRoot = filepath.Join(root, pluginID, "shared")
	}
	if config.FDHandoff == "" {
		config.FDHandoff = filepath.Join(volatile, pluginID+"-fd.sock")
	}
	if config.ReaperDir == "" {
		config.ReaperDir = runtimeservice.DefaultReaperRoot
	}
	if config.SocketMode == 0 {
		config.SocketMode = 0o660
	}

	leaseStore, err := state.Open(filepath.Join(config.StateDir, "leases"), nil)
	if err != nil {
		return nil, fmt.Errorf("open runtime resource lease store: %w", err)
	}
	adapter, err := newAdapter(filepath.Join(config.StateDir, "resources"), Assets{
		KernelPath: config.KernelPath, AgentPath: config.AgentPath,
		GuestImagePath: config.GuestImagePath, SharedRootBase: config.SharedRoot,
	}, newLinuxNetwork())
	if err != nil {
		return nil, err
	}
	service, handoffRegistry, err := runtimeservice.NewService(leaseStore, adapter, config.FDHandoff)
	if err != nil {
		return nil, err
	}
	if err := service.Recover(ic.Context); err != nil {
		return nil, fmt.Errorf("recover runtime resources before serving: %w", err)
	}
	if err := service.RecoverReaperJobs(ic.Context, config.ReaperDir); err != nil {
		return nil, fmt.Errorf("recover durable RuntimeResource reaper jobs before serving: %w", err)
	}
	listener, err := handoff.Listen(config.FDHandoff, os.FileMode(config.SocketMode), handoffRegistry,
		handoff.AuthorizePeerIDs(syscall.Ucred{Uid: config.PeerUID, Gid: config.PeerGID}))
	if err != nil {
		return nil, err
	}
	instance := &servicePlugin{service: service, listener: listener}
	go service.RunReaperSupervisor(ic.Context, config.ReaperDir, time.Second, func(err error) {
		log.G(ic.Context).WithError(err).Error("retry durable RuntimeResource reaper jobs")
	})
	go func() {
		<-ic.Context.Done()
		_ = instance.listener.Close()
	}()
	return instance, nil
}

func (s *servicePlugin) Register(server *grpc.Server) error {
	return runtimeservice.Register(server, s.service)
}
