//go:build linux

// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

type kernelNetlinkFault struct {
	mu        sync.Mutex
	operation string
	failAt    int
	seen      int
	fired     bool
}

func (f *kernelNetlinkFault) arm(operation string, failAt int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.operation = operation
	f.failAt = failAt
	f.seen = 0
	f.fired = false
}

func (f *kernelNetlinkFault) inject(operation string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.operation != operation || f.fired {
		return nil
	}
	f.seen++
	if f.seen != f.failAt {
		return nil
	}
	f.fired = true
	return fmt.Errorf("injected real-kernel failure at %s", operation)
}

type faultingKernelNetlinkHandle struct {
	netlinkHandle
	fault *kernelNetlinkFault
}

func (h *faultingKernelNetlinkHandle) LinkSetMTU(link netlink.Link, mtu int) error {
	if err := h.fault.inject("link-set-mtu"); err != nil {
		return err
	}
	return h.netlinkHandle.LinkSetMTU(link, mtu)
}

func (h *faultingKernelNetlinkHandle) FilterReplace(filter netlink.Filter) error {
	if err := h.fault.inject("filter-replace"); err != nil {
		return err
	}
	return h.netlinkHandle.FilterReplace(filter)
}

func (h *faultingKernelNetlinkHandle) FilterDel(filter netlink.Filter) error {
	if err := h.fault.inject("filter-del"); err != nil {
		return err
	}
	return h.netlinkHandle.FilterDel(filter)
}

func (h *faultingKernelNetlinkHandle) LinkDel(link netlink.Link) error {
	if err := h.fault.inject("link-del"); err != nil {
		return err
	}
	return h.netlinkHandle.LinkDel(link)
}

type faultingKernelNetlinkExecutor struct {
	base  netlinkNamespaceExecutor
	fault *kernelNetlinkFault
}

func (e faultingKernelNetlinkExecutor) Run(ctx context.Context, path string, operation func(netlinkHandle) error) error {
	return e.base.Run(ctx, path, func(handle netlinkHandle) error {
		return operation(&faultingKernelNetlinkHandle{netlinkHandle: handle, fault: e.fault})
	})
}

type privilegedNamespaceResult struct {
	err error
}

func createPrivilegedNamedNamespace(t *testing.T, name string) string {
	t.Helper()
	result := make(chan privilegedNamespaceResult, 1)
	go func() {
		runtime.LockOSThread()
		terminateThread := false
		defer func() {
			if !terminateThread {
				runtime.UnlockOSThread()
			}
		}()
		original, err := netns.Get()
		if err != nil {
			result <- privilegedNamespaceResult{err: err}
			return
		}
		defer original.Close()
		created, err := netns.NewNamed(name)
		if err != nil {
			result <- privilegedNamespaceResult{err: err}
			return
		}
		created.Close()
		if err := netns.Set(original); err != nil {
			terminateThread = true
			result <- privilegedNamespaceResult{err: fmt.Errorf("restore namespace after creating %s: %w", name, err)}
			return
		}
		result <- privilegedNamespaceResult{}
	}()
	if err := (<-result).err; err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := netns.DeleteNamed(name); err != nil && !os.IsNotExist(err) {
			t.Errorf("delete namespace %s: %v", name, err)
		}
	})
	return filepath.Join("/run/netns", name)
}

func configurePrivilegedKernelFixture(t *testing.T, executor netlinkNamespaceExecutor, path string, index int) {
	t.Helper()
	err := executor.Run(context.Background(), path, func(generic netlinkHandle) error {
		handle, ok := generic.(*netlink.Handle)
		if !ok {
			return fmt.Errorf("fixture received %T, want *netlink.Handle", generic)
		}
		loopback, err := handle.LinkByName("lo")
		if err != nil {
			return err
		}
		if err := handle.LinkSetUp(loopback); err != nil {
			return err
		}
		device := &netlink.Dummy{LinkAttrs: netlink.LinkAttrs{Name: "eth0"}}
		if err := handle.LinkAdd(device); err != nil {
			return err
		}
		link, err := handle.LinkByName("eth0")
		if err != nil {
			return err
		}
		mac, err := net.ParseMAC(fmt.Sprintf("02:75:00:00:%02x:02", index))
		if err != nil {
			return err
		}
		if err := handle.LinkSetHardwareAddr(link, mac); err != nil {
			return err
		}
		if err := handle.LinkSetMTU(link, 1450); err != nil {
			return err
		}
		if err := handle.LinkSetUp(link); err != nil {
			return err
		}
		address, err := netlink.ParseAddr(fmt.Sprintf("10.75.%d.2/24", index))
		if err != nil {
			return err
		}
		if err := handle.AddrAdd(link, address); err != nil {
			return err
		}
		gateway := net.ParseIP(fmt.Sprintf("10.75.%d.1", index))
		gatewayMAC, err := net.ParseMAC(fmt.Sprintf("02:75:00:00:%02x:01", index))
		if err != nil {
			return err
		}
		if err := handle.NeighSet(&netlink.Neigh{
			LinkIndex: link.Attrs().Index, IP: gateway, HardwareAddr: gatewayMAC, State: netlink.NUD_PERMANENT,
		}); err != nil {
			return err
		}
		if err := handle.RouteAdd(&netlink.Route{
			LinkIndex: link.Attrs().Index, Gw: gateway, Flags: int(netlink.FLAG_ONLINK),
		}); err != nil {
			return err
		}
		return handle.QdiscAdd(&netlink.Clsact{QdiscAttrs: netlink.QdiscAttrs{
			LinkIndex: link.Attrs().Index,
			Handle:    netlink.MakeHandle(0xffff, 0),
			Parent:    netlink.HANDLE_CLSACT,
		}})
	})
	if err != nil {
		t.Fatal(err)
	}
}

func assertPrivilegedKernelExactZero(t *testing.T, executor netlinkNamespaceExecutor, path, tapName string, adapter *adapter) {
	t.Helper()
	err := executor.Run(context.Background(), path, func(handle netlinkHandle) error {
		if _, err := handle.LinkByName(tapName); !isLinkNotFound(err) {
			return fmt.Errorf("TAP %s remains: %v", tapName, err)
		}
		cni, err := handle.LinkByName("eth0")
		if err != nil {
			return err
		}
		qdiscs, err := handle.QdiscList(cni)
		if err != nil {
			return err
		}
		parent, exists := netlinkIngressParent(qdiscs)
		if !exists {
			return errors.New("fixture clsact qdisc disappeared")
		}
		filters, err := handle.FilterList(cni, parent)
		if err != nil {
			return err
		}
		for _, filter := range filters {
			if filter.Attrs().Priority == tcPriority {
				return fmt.Errorf("reserved filter remains: %+v", filter)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := adapter.load("sandbox-a"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("adapter record remains: %v", err)
	}
	entries, err := os.ReadDir(adapter.assets.SharedRootBase)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("shared-root residue: %v", entries)
	}
}

// This opt-in test must run as root on an isolated Linux host. Unlike the
// deterministic fake-handle matrix, every mutation and rollback below is
// executed by the kernel in a named network namespace.
func TestPrivilegedNetlinkKernelFailureRollback(t *testing.T) {
	if os.Getenv(privilegedRuntimeResourceTest) != "1" {
		t.Skip("set " + privilegedRuntimeResourceTest + "=1 on an isolated privileged Linux host")
	}
	if os.Geteuid() != 0 {
		t.Fatal("privileged RuntimeResource integration test must run as root")
	}
	before, err := os.Readlink("/proc/thread-self/ns/net")
	if err != nil {
		t.Fatal(err)
	}

	prepareCases := []struct {
		operation string
		failAt    int
	}{
		{operation: "link-set-mtu", failAt: 1},
		{operation: "filter-replace", failAt: 2},
	}
	for index, test := range prepareCases {
		t.Run("prepare-"+test.operation, func(t *testing.T) {
			base := threadNetlinkNamespaceExecutor{}
			path := createPrivilegedNamedNamespace(t, fmt.Sprintf("cube-nl-prepare-%d-%d", os.Getpid(), index))
			configurePrivilegedKernelFixture(t, base, path, index+1)
			fault := &kernelNetlinkFault{}
			fault.arm(test.operation, test.failAt)
			executor := faultingKernelNetlinkExecutor{base: base, fault: fault}
			network := &netlinkNetwork{executor: executor, probe: probeGatewayUDP}
			adapter, err := newAdapter(filepath.Join(t.TempDir(), "adapter"), testAssets(t), network)
			if err != nil {
				t.Fatal(err)
			}
			request := adapterRequest()
			request.Network.NetnsPath = path
			tapName := nameFor("cb", request.SandboxId, request.Generation)
			_, err = adapter.Prepare(context.Background(), request, state.Lease{Generation: request.Generation, LeaseID: "lease-a"})
			if err == nil || !fault.fired || !containsKernelFault(err) {
				t.Fatalf("Prepare error=%v fired=%t", err, fault.fired)
			}
			assertPrivilegedKernelExactZero(t, base, path, tapName, adapter)
		})
	}

	releaseCases := []string{"filter-del", "link-del"}
	for index, operation := range releaseCases {
		t.Run("release-"+operation, func(t *testing.T) {
			base := threadNetlinkNamespaceExecutor{}
			path := createPrivilegedNamedNamespace(t, fmt.Sprintf("cube-nl-release-%d-%d", os.Getpid(), index))
			configurePrivilegedKernelFixture(t, base, path, index+20)
			fault := &kernelNetlinkFault{}
			executor := faultingKernelNetlinkExecutor{base: base, fault: fault}
			network := &netlinkNetwork{executor: executor, probe: probeGatewayUDP}
			adapter, err := newAdapter(filepath.Join(t.TempDir(), "adapter"), testAssets(t), network)
			if err != nil {
				t.Fatal(err)
			}
			request := adapterRequest()
			request.Network.NetnsPath = path
			lease := state.Lease{Generation: request.Generation, LeaseID: "lease-a"}
			prepared, err := adapter.Prepare(context.Background(), request, lease)
			if err != nil {
				t.Fatal(err)
			}
			fault.arm(operation, 1)
			release := state.ReleaseRequest{SandboxID: request.SandboxId, Generation: request.Generation, LeaseID: lease.LeaseID}
			if err := adapter.Release(context.Background(), release, prepared.GetNetwork().GetNetworkHandle()); err == nil || !containsKernelFault(err) {
				t.Fatalf("first Release error=%v", err)
			}
			if _, err := adapter.load(request.SandboxId); err != nil {
				t.Fatalf("adapter record not retained after failed release: %v", err)
			}
			if err := adapter.Release(context.Background(), release, prepared.GetNetwork().GetNetworkHandle()); err != nil {
				t.Fatalf("Release retry: %v", err)
			}
			tapName := nameFor("cb", request.SandboxId, request.Generation)
			assertPrivilegedKernelExactZero(t, base, path, tapName, adapter)
		})
	}

	after, err := os.Readlink("/proc/thread-self/ns/net")
	if err != nil {
		t.Fatal(err)
	}
	if before != after {
		t.Fatalf("test goroutine namespace changed: before=%s after=%s", before, after)
	}
	t.Logf("S55C_PRIVILEGED_KERNEL_ROLLBACK_OK prepare_cases=%d release_cases=%d tap=0 reserved_filters=0 adapter_records=0 shared=0 host_netns_restored=true", len(prepareCases), len(releaseCases))
	time.Sleep(time.Millisecond)
}

func containsKernelFault(err error) bool {
	return err != nil && strings.Contains(err.Error(), "injected real-kernel failure")
}
