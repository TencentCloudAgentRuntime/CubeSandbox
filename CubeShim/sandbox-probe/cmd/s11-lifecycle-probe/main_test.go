// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	grpcstatus "google.golang.org/grpc/status"
)

func TestCreateCollision(t *testing.T) {
	bundle := "/run/cubesandbox-s11/state/io.containerd.sandbox.controller.v1.shim/s11-live/sandbox"
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{name: "already exists", err: grpcstatus.Error(codes.AlreadyExists, "sandbox already running"), want: true},
		{name: "containerd raw bundle EEXIST", err: grpcstatus.Error(codes.Unknown, "mkdir "+bundle+": file exists"), want: true},
		{name: "wrapped containerd raw bundle EEXIST", err: grpcstatus.Error(codes.Unknown, "create bundle: mkdir "+bundle+": file exists"), want: true},
		{name: "different bundle", err: grpcstatus.Error(codes.Unknown, "mkdir "+bundle+"-other: file exists"), want: false},
		{name: "publisher failure remains ambiguous", err: grpcstatus.Error(codes.Unknown, "publish sandbox create event: unavailable"), want: false},
		{name: "deadline remains ambiguous", err: grpcstatus.Error(codes.DeadlineExceeded, "request timed out"), want: false},
		{name: "ordinary error", err: errors.New("local error"), want: false},
		{name: "success", err: nil, want: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := createCollision(test.err, bundle); got != test.want {
				t.Fatalf("createCollision() = %t, want %t", got, test.want)
			}
		})
	}
}

func TestParseShimBootstrap(t *testing.T) {
	tests := []struct {
		name    string
		data    string
		want    string
		wantErr string
	}{
		{
			name: "containerd shim v3 ttrpc",
			data: `{"version":3,"address":"unix:///run/containerd/s/cube.sock","protocol":"ttrpc"}`,
			want: "/run/containerd/s/cube.sock",
		},
		{
			name:    "invalid JSON",
			data:    `{`,
			wantErr: "decode bootstrap.json",
		},
		{
			name:    "unsupported version",
			data:    `{"version":2,"address":"unix:///run/containerd/s/cube.sock","protocol":"ttrpc"}`,
			wantErr: "version = 2, want 3",
		},
		{
			name:    "unsupported protocol",
			data:    `{"version":3,"address":"unix:///run/containerd/s/cube.sock","protocol":"grpc"}`,
			wantErr: `protocol = "grpc", want ttrpc`,
		},
		{
			name:    "non-unix address",
			data:    `{"version":3,"address":"vsock://3:1024","protocol":"ttrpc"}`,
			wantErr: "want unix:// absolute path",
		},
		{
			name:    "relative unix path",
			data:    `{"version":3,"address":"unix://run/cube.sock","protocol":"ttrpc"}`,
			wantErr: "want absolute path",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := parseShimBootstrap([]byte(test.data))
			if test.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantErr) {
					t.Fatalf("parseShimBootstrap() error = %v, want substring %q", err, test.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseShimBootstrap() error = %v", err)
			}
			if got != test.want {
				t.Fatalf("parseShimBootstrap() = %q, want %q", got, test.want)
			}
		})
	}
}
