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
	"strconv"
	"testing"
	"time"

	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/handoff"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"golang.org/x/sys/unix"
)

const (
	privilegedHelperStage = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_HELPER_STAGE"
	privilegedStateDir    = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_STATE_DIR"
	privilegedAssetsDir   = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_ASSETS_DIR"
	privilegedNetNSPath   = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_NETNS"
	privilegedVMMSocketFD = "CUBE_RUNTIME_RESOURCE_PRIVILEGED_VMM_SOCKET_FD"
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
		socketFD, err := strconv.Atoi(os.Getenv(privilegedVMMSocketFD))
		if err != nil {
			t.Fatal(err)
		}
		if err := unix.Sendmsg(socketFD, []byte{1}, unix.UnixRights(int(one.Fd())), nil, 0); err != nil {
			t.Fatalf("transfer TAP queue to simulated VMM: %v", err)
		}
		one.Close()
		two.Close()
		// The canonical descriptor closes when this simulated Cubelet exits;
		// the parent retains the transferred VMM duplicate.
	case "restart-with-live-vmm":
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
	case "release":
		prepared, err := current.Inspect(ctx, request.SandboxId, lease)
		if err != nil {
			t.Fatal(err)
		}
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
// processes prove same-process duplicate retry plus multi-queue reopening from
// a fresh Cubelet while a simulated VMM still owns the original transferred queue.
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
	runHelper := func(stage string, extra *os.File) {
		command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestPrivilegedAdapterRealTapProcessHelper$")
		command.Env = append(helperEnv, privilegedHelperStage+"="+stage)
		if extra != nil {
			command.ExtraFiles = []*os.File{extra}
			command.Env = append(command.Env, privilegedVMMSocketFD+"=3")
		}
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("privileged TAP helper %s: %v:\n%s", stage, err, output)
		}
	}

	sockets, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	receiver := os.NewFile(uintptr(sockets[0]), "simulated-vmm-receiver")
	sender := os.NewFile(uintptr(sockets[1]), "cubelet-helper-sender")
	defer receiver.Close()

	runHelper("prepare-and-retry", sender)
	sender.Close()
	data := make([]byte, 1)
	oob := make([]byte, unix.CmsgSpace(4))
	_, oobn, flags, _, err := unix.Recvmsg(int(receiver.Fd()), data, oob, 0)
	if err != nil {
		t.Fatalf("receive simulated VMM TAP queue: %v", err)
	}
	if flags&unix.MSG_CTRUNC != 0 {
		t.Fatal("simulated VMM TAP queue control message was truncated")
	}
	messages, err := unix.ParseSocketControlMessage(oob[:oobn])
	if err != nil {
		t.Fatal(err)
	}
	var rights []int
	for _, message := range messages {
		descriptors, parseErr := unix.ParseUnixRights(&message)
		if parseErr != nil {
			t.Fatal(parseErr)
		}
		rights = append(rights, descriptors...)
	}
	if len(rights) != 1 {
		for _, descriptor := range rights {
			_ = unix.Close(descriptor)
		}
		t.Fatalf("simulated VMM received %d TAP descriptors, want 1", len(rights))
	}
	vmmQueue := os.NewFile(uintptr(rights[0]), "simulated-vmm-tap-queue")
	runHelper("restart-with-live-vmm", nil)
	if err := vmmQueue.Close(); err != nil {
		t.Fatal(err)
	}
	runHelper("release", nil)
}
