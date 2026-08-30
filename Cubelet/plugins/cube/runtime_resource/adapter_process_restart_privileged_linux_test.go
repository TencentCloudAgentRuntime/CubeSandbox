//go:build linux

// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
)

const (
	privilegedHelperStage = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_HELPER_STAGE"
	privilegedStateDir    = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_STATE_DIR"
	privilegedAssetsDir   = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_ASSETS_DIR"
	privilegedNetNSPath   = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_NETNS"
)

func privilegedAssets(root string) Assets {
	return Assets{
		KernelPath: filepath.Join(root, "kernel"), AgentPath: filepath.Join(root, "agent"),
		GuestImagePath: filepath.Join(root, "guest"), SharedRootBase: filepath.Join(root, "shared"),
	}
}

func TestPrivilegedAdapterRealTapProcessHelper(t *testing.T) {
	stage := os.Getenv(privilegedHelperStage)
	if stage == "" {
		t.Skip("privileged TAP subprocess helper")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	current, err := newAdapter(os.Getenv(privilegedStateDir), privilegedAssets(os.Getenv(privilegedAssetsDir)), realTapNetwork{})
	if err != nil {
		t.Fatal(err)
	}
	request := adapterRequest()
	request.Network.NetnsPath = os.Getenv(privilegedNetNSPath)
	lease := state.Lease{Generation: request.Generation, LeaseID: "lease-real-tap-process"}
	binding := handoff.Binding{SandboxID: request.SandboxId, Generation: request.Generation, LeaseID: lease.LeaseID}
	switch stage {
	case "prepare-and-retry":
		prepared, err := current.Prepare(ctx, request, lease)
		if err != nil {
			t.Fatal(err)
		}
		binding.NetworkHandle = prepared.GetNetwork().GetNetworkHandle()
		one, err := current.OpenTap(binding)
		if err != nil {
			t.Fatalf("first TAP handoff: %v", err)
		}
		two, err := current.OpenTap(binding)
		if err != nil {
			one.Close()
			t.Fatalf("retry TAP handoff: %v", err)
		}
		if one.Fd() == two.Fd() {
			t.Fatalf("retry returned the same descriptor %d", one.Fd())
		}
		one.Close()
		two.Close()
		// The canonical descriptor intentionally remains open. Helper exit closes
		// it exactly as the kernel would close it on a real Cubelet process exit.
	case "restart-and-release":
		prepared, err := current.Inspect(ctx, request.SandboxId, lease)
		if err != nil {
			t.Fatal(err)
		}
		binding.NetworkHandle = prepared.GetNetwork().GetNetworkHandle()
		afterRestart, err := current.OpenTap(binding)
		if err != nil {
			t.Fatalf("TAP handoff after Cubelet process restart: %v", err)
		}
		afterRestart.Close()
		if err := current.Release(ctx, state.ReleaseRequest{
			SandboxID: request.SandboxId, Generation: request.Generation, LeaseID: lease.LeaseID,
		}, prepared.GetNetwork().GetNetworkHandle()); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("unknown privileged helper stage %q", stage)
	}
}

// This test must run on an isolated privileged Linux host. Separate helper
// processes prove both real IFF_ONE_QUEUE retry semantics and reopening the
// persistent TAP from a fresh Cubelet process over the durable adapter WAL.
func TestPrivilegedAdapterRealTapAcrossProcessRestart(t *testing.T) {
	if os.Getenv(privilegedRuntimeResourceTest) != "1" {
		t.Skip("set " + privilegedRuntimeResourceTest + "=1 on an isolated privileged Linux host")
	}
	if os.Geteuid() != 0 {
		t.Fatal("privileged RuntimeResource integration test must run as root")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	name := fmt.Sprintf("cube-rrp-%d", os.Getpid())
	if output, err := exec.CommandContext(ctx, "ip", "netns", "add", name).CombinedOutput(); err != nil {
		t.Fatalf("create network namespace: %v: %s", err, output)
	}
	defer func() {
		if output, err := exec.Command("ip", "netns", "del", name).CombinedOutput(); err != nil {
			t.Errorf("delete network namespace: %v: %s", err, output)
		}
	}()

	assetsRoot := t.TempDir()
	for _, asset := range []string{"kernel", "agent", "guest"} {
		if err := os.WriteFile(filepath.Join(assetsRoot, asset), []byte(asset), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	helperEnv := append(os.Environ(),
		privilegedStateDir+"="+filepath.Join(t.TempDir(), "resources"),
		privilegedAssetsDir+"="+assetsRoot,
		privilegedNetNSPath+"="+filepath.Join("/run/netns", name),
	)
	for _, stage := range []string{"prepare-and-retry", "restart-and-release"} {
		command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestPrivilegedAdapterRealTapProcessHelper$")
		command.Env = append(helperEnv, privilegedHelperStage+"="+stage)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("privileged TAP helper %s: %v:\n%s", stage, err, output)
		}
	}
}
