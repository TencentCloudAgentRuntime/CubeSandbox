//go:build linux

// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"slices"
	"testing"
)

func TestLinuxNetworkSupportsIPv6OnlyAndDualStack(t *testing.T) {
	for _, test := range []struct {
		name      string
		runner    *scriptedRunner
		wantIPs   []string
		wantRoute int
		wantNeigh int
	}{
		{name: "ipv6-only", runner: &scriptedRunner{ipv6Only: true}, wantIPs: []string{"2001:db8::2/64"}, wantRoute: 3, wantNeigh: 1},
		{name: "dual-stack", runner: &scriptedRunner{dualStack: true}, wantIPs: []string{"10.0.0.2/24", "2001:db8::2/64"}, wantRoute: 6, wantNeigh: 2},
	} {
		t.Run(test.name, func(t *testing.T) {
			attachment, err := (&linuxNetwork{runner: test.runner}).Prepare(context.Background(), t.TempDir(), "eth0", "cb123")
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(attachment.GetIps(), test.wantIPs) || len(attachment.GetRoutes()) != test.wantRoute || len(attachment.GetNeighbors()) != test.wantNeigh {
				t.Fatalf("attachment=%+v", attachment)
			}
		})
	}
}
