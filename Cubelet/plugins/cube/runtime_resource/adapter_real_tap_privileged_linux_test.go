//go:build linux

// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"fmt"
	"os"
	"os/exec"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
)

const privilegedRuntimeResourceTest = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_TEST"

type realTapNetwork struct{}

func (realTapNetwork) Prepare(ctx context.Context, netnsPath, _, tapName string) (*runtimev1.NetworkAttachment, error) {
	if output, err := exec.CommandContext(ctx, "nsenter", "--net="+netnsPath, "--", "ip", "tuntap", "add", "dev", tapName, "mode", "tap", "multi_queue", "vnet_hdr").CombinedOutput(); err != nil {
		return nil, fmt.Errorf("create integration TAP: %w: %s", err, output)
	}
	return &runtimev1.NetworkAttachment{
		TapName: tapName, GuestInterfaceName: "eth0", Mac: "02:00:00:00:00:01", Mtu: 1500,
		Ips: []string{"192.0.2.2/24"},
	}, nil
}

func (realTapNetwork) Release(ctx context.Context, netnsPath, _, tapName string) error {
	output, err := exec.CommandContext(ctx, "nsenter", "--net="+netnsPath, "--", "ip", "tuntap", "del", "dev", tapName, "mode", "tap").CombinedOutput()
	if err != nil {
		return fmt.Errorf("delete integration TAP: %w: %s", err, output)
	}
	return nil
}

func (realTapNetwork) Open(netnsPath, tapName string) (*os.File, error) {
	return newLinuxNetwork().Open(netnsPath, tapName)
}
