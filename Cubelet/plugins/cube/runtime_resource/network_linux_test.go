//go:build linux

// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"errors"
	"strings"
	"testing"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"golang.org/x/sys/unix"
)

func TestPrepareTapForHandoffMatchesVMMHeaderContract(t *testing.T) {
	originalHeader := runtimeResourceIoctlSetPointerInt
	originalOffload := runtimeResourceIoctlSetTunOffload
	t.Cleanup(func() {
		runtimeResourceIoctlSetPointerInt = originalHeader
		runtimeResourceIoctlSetTunOffload = originalOffload
	})

	var gotFD, gotHeaderSize int
	var gotRequest uint
	var gotOffload uintptr
	runtimeResourceIoctlSetPointerInt = func(fd int, request uint, value int) error {
		gotFD, gotRequest, gotHeaderSize = fd, request, value
		return nil
	}
	runtimeResourceIoctlSetTunOffload = func(fd int, features uintptr) error {
		if fd != gotFD {
			t.Fatalf("offload fd=%d, want %d", fd, gotFD)
		}
		gotOffload = features
		return nil
	}

	if err := prepareTapForHandoff(41); err != nil {
		t.Fatal(err)
	}
	if gotFD != 41 || gotRequest != unix.TUNSETVNETHDRSZ || gotHeaderSize != runtimeResourceVnetHeaderSize {
		t.Fatalf("vnet header fd=%d request=%d size=%d", gotFD, gotRequest, gotHeaderSize)
	}
	if gotOffload != 0 {
		t.Fatalf("offloads=%#x, want disabled", gotOffload)
	}
}

func TestPrepareTapForHandoffStopsAfterHeaderFailure(t *testing.T) {
	originalHeader := runtimeResourceIoctlSetPointerInt
	originalOffload := runtimeResourceIoctlSetTunOffload
	t.Cleanup(func() {
		runtimeResourceIoctlSetPointerInt = originalHeader
		runtimeResourceIoctlSetTunOffload = originalOffload
	})

	want := errors.New("header failed")
	runtimeResourceIoctlSetPointerInt = func(int, uint, int) error { return want }
	offloadCalled := false
	runtimeResourceIoctlSetTunOffload = func(int, uintptr) error {
		offloadCalled = true
		return nil
	}

	err := prepareTapForHandoff(42)
	if !errors.Is(err, want) {
		t.Fatalf("prepareTapForHandoff error=%v, want %v", err, want)
	}
	if offloadCalled {
		t.Fatal("offload configured after vnet header failure")
	}
}

func TestPrepareTapForHandoffReportsOffloadFailure(t *testing.T) {
	originalHeader := runtimeResourceIoctlSetPointerInt
	originalOffload := runtimeResourceIoctlSetTunOffload
	t.Cleanup(func() {
		runtimeResourceIoctlSetPointerInt = originalHeader
		runtimeResourceIoctlSetTunOffload = originalOffload
	})

	want := errors.New("offload failed")
	runtimeResourceIoctlSetPointerInt = func(int, uint, int) error { return nil }
	runtimeResourceIoctlSetTunOffload = func(int, uintptr) error { return want }

	if err := prepareTapForHandoff(43); !errors.Is(err, want) {
		t.Fatalf("prepareTapForHandoff error=%v, want %v", err, want)
	}
}

type scriptedRunner struct {
	commands         []string
	badLink          bool
	ipv6Only         bool
	dualStack        bool
	gatewayHostRoute bool
	clsact           bool
}

func (r *scriptedRunner) Run(_ context.Context, _ string, command ...string) ([]byte, error) {
	line := strings.Join(command, " ")
	r.commands = append(r.commands, line)
	switch line {
	case "ip -j link show dev eth0":
		if r.badLink {
			return []byte("[]"), nil
		}
		return []byte(`[{"address":"02:00:00:00:00:01","mtu":1450}]`), nil
	case "ip link show dev cb123":
		return nil, errors.New("not found")
	case "ip -j addr show dev eth0":
		if r.ipv6Only {
			return []byte(`[{"addr_info":[{"local":"2001:db8::2","prefixlen":64,"scope":"global"}]}]`), nil
		}
		if r.dualStack {
			return []byte(`[{"addr_info":[{"local":"10.0.0.2","prefixlen":24,"scope":"global"},{"local":"2001:db8::2","prefixlen":64,"scope":"global"}]}]`), nil
		}
		return []byte(`[{"addr_info":[{"local":"10.0.0.2","prefixlen":24,"scope":"global"}]}]`), nil
	case "ip -j -4 route show":
		if r.ipv6Only {
			return []byte(`[]`), nil
		}
		if r.gatewayHostRoute {
			return []byte(`[{"dst":"default","gateway":"10.0.0.1","dev":"eth0","prefsrc":"10.0.0.2"},{"dst":"10.0.0.1","dev":"eth0","scope":"link"}]`), nil
		}
		return []byte(`[{"dst":"default","gateway":"10.0.0.1","dev":"eth0","prefsrc":"10.0.0.2"},{"dst":"10.0.0.0/24","dev":"eth0","scope":"link"}]`), nil
	case "ip -j -6 route show":
		if r.ipv6Only || r.dualStack {
			return []byte(`[{"dst":"default","gateway":"fe80::1","dev":"eth0","prefsrc":"2001:db8::2"},{"dst":"2001:db8::/64","dev":"eth0","scope":"link"}]`), nil
		}
		return []byte(`[]`), nil
	case "ip -j neigh show dev eth0":
		if r.ipv6Only {
			return []byte(`[{"dst":"fe80::1","lladdr":"02:00:00:00:00:06","dev":"eth0"}]`), nil
		}
		if r.dualStack {
			return []byte(`[{"dst":"10.0.0.1","lladdr":"02:00:00:00:00:02","dev":"eth0"},{"dst":"fe80::1","lladdr":"02:00:00:00:00:06","dev":"eth0"}]`), nil
		}
		return []byte(`[{"dst":"10.0.0.1","lladdr":"02:00:00:00:00:02","dev":"eth0"}]`), nil
	case "tc qdisc show dev eth0", "tc qdisc show dev cb123":
		if r.clsact {
			return []byte("qdisc clsact ffff: parent ffff:fff1"), nil
		}
		return nil, nil
	default:
		return nil, nil
	}
}

func TestLinuxNetworkDoesNotDuplicateCNIProvidedGatewayHostRoute(t *testing.T) {
	attachment, err := (&linuxNetwork{runner: &scriptedRunner{gatewayHostRoute: true}}).Prepare(context.Background(), t.TempDir(), "eth0", "cb123")
	if err != nil {
		t.Fatal(err)
	}
	if len(attachment.GetRoutes()) != 2 {
		t.Fatalf("routes=%+v, want the CNI gateway host route and default route only", attachment.GetRoutes())
	}
	gatewayRoutes := 0
	for _, route := range attachment.GetRoutes() {
		if hasGatewayHostRoute([]*runtimev1.Route{route}, "10.0.0.1") {
			gatewayRoutes++
		}
	}
	if gatewayRoutes != 1 {
		t.Fatalf("gateway host routes=%d routes=%+v", gatewayRoutes, attachment.GetRoutes())
	}
}

func TestHasGatewayHostRoute(t *testing.T) {
	for _, test := range []struct {
		name        string
		destination string
		gateway     string
		routeVia    string
		device      string
		want        bool
	}{
		{name: "IPv4 bare host", destination: "10.0.0.1", gateway: "10.0.0.1", device: "eth0", want: true},
		{name: "IPv4 host CIDR", destination: "10.0.0.1/32", gateway: "10.0.0.1", device: "eth0", want: true},
		{name: "IPv4 subnet", destination: "10.0.0.0/24", gateway: "10.0.0.1", device: "eth0"},
		{name: "different IPv4 host", destination: "10.0.0.2/32", gateway: "10.0.0.1", device: "eth0"},
		{name: "route via another gateway", destination: "10.0.0.1/32", gateway: "10.0.0.1", routeVia: "10.0.0.254", device: "eth0"},
		{name: "wrong guest device", destination: "10.0.0.1/32", gateway: "10.0.0.1", device: "eth1"},
		{name: "IPv6 bare host", destination: "fe80::1", gateway: "fe80::1", device: "eth0", want: true},
		{name: "IPv6 host CIDR", destination: "fe80::1/128", gateway: "fe80::1", device: "eth0", want: true},
		{name: "IPv6 subnet", destination: "fe80::/64", gateway: "fe80::1", device: "eth0"},
	} {
		t.Run(test.name, func(t *testing.T) {
			route := &runtimev1.Route{Destination: test.destination, Gateway: test.routeVia, Device: test.device}
			if got := hasGatewayHostRoute([]*runtimev1.Route{route}, test.gateway); got != test.want {
				t.Fatalf("hasGatewayHostRoute()=%t, want %t", got, test.want)
			}
		})
	}
}

func TestLinuxNetworkPrepareBuildsTcRedirectAndGuestConfig(t *testing.T) {
	runner := new(scriptedRunner)
	network := &linuxNetwork{runner: runner}
	netnsPath := t.TempDir()
	attachment, err := network.Prepare(context.Background(), netnsPath, "eth0", "cb123")
	if err != nil {
		t.Fatal(err)
	}
	if attachment.GetTapName() != "cb123" || attachment.GetMac() != "02:00:00:00:00:01" ||
		attachment.GetMtu() != 1450 || len(attachment.GetIps()) != 1 || len(attachment.GetRoutes()) != 3 ||
		len(attachment.GetNeighbors()) != 1 {
		t.Fatalf("attachment=%+v", attachment)
	}
	filters := 0
	for _, command := range runner.commands {
		if strings.HasPrefix(command, "tc filter replace") && strings.Contains(command, "pref "+tcPreference) {
			filters++
		}
	}
	if !strings.Contains(strings.Join(runner.commands, "\n"), "ip tuntap add dev cb123 mode tap multi_queue vnet_hdr") {
		t.Fatalf("multi-queue TAP create missing: %v", runner.commands)
	}
	if filters != 2 {
		t.Fatalf("tc redirect filters=%d commands=%v", filters, runner.commands)
	}
	joined := strings.Join(runner.commands, "\n")
	neighbor := strings.Index(joined, "ip -j neigh show dev eth0")
	redirect := strings.Index(joined, "tc filter replace dev eth0")
	if neighbor < 0 || redirect < 0 || neighbor > redirect {
		t.Fatalf("gateway neighbors must be resolved before ingress redirect: %v", runner.commands)
	}
}

func TestLinuxNetworkMalformedLinkHasActionableError(t *testing.T) {
	network := &linuxNetwork{runner: &scriptedRunner{badLink: true}}
	_, err := network.Prepare(context.Background(), t.TempDir(), "eth0", "cb123")
	if err == nil || !strings.Contains(err.Error(), "one link with MAC and MTU") || strings.Contains(err.Error(), "%!w") {
		t.Fatalf("error=%v", err)
	}
}

func TestLinuxNetworkReleaseDeletesOnlyReservedPreferenceAndTap(t *testing.T) {
	runner := new(scriptedRunner)
	network := &linuxNetwork{runner: runner}
	if err := network.Release(context.Background(), t.TempDir(), "eth0", "cb123"); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.commands, "\n")
	for _, expected := range []string{
		"tc filter del dev eth0 parent ffff: pref " + tcPreference,
		"tc filter del dev cb123 parent ffff: pref " + tcPreference,
		"ip tuntap del dev cb123 mode tap multi_queue",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("missing %q in commands:\n%s", expected, joined)
		}
	}
}

func TestLinuxCommandNetworkUsesClsactIngressParent(t *testing.T) {
	runner := &scriptedRunner{clsact: true}
	network := &linuxNetwork{runner: runner}
	if _, err := network.Prepare(context.Background(), t.TempDir(), "eth0", "cb123"); err != nil {
		t.Fatal(err)
	}
	if err := network.Release(context.Background(), t.TempDir(), "eth0", "cb123"); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.commands, "\n")
	for _, expected := range []string{
		"tc filter replace dev eth0 parent ffff:fff2",
		"tc filter replace dev cb123 parent ffff:fff2",
		"tc filter del dev eth0 parent ffff:fff2 pref " + tcPreference,
		"tc filter del dev cb123 parent ffff:fff2 pref " + tcPreference,
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("missing %q in commands:\n%s", expected, joined)
		}
	}
}
