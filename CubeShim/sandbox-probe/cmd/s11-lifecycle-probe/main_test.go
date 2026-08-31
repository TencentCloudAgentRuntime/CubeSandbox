// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
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
