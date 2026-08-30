// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"

	bootapi "github.com/containerd/containerd/api/runtime/bootstrap/v1"
)

func TestRemoveProbeSocket(t *testing.T) {
	bundle := t.TempDir()
	socketPath := filepath.Join(t.TempDir(), "shim.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	data, err := json.Marshal(&bootapi.BootstrapResult{
		Version:  3,
		Address:  "unix://" + socketPath,
		Protocol: "ttrpc",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bundle, "bootstrap.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := removeProbeSocket(bundle); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
		t.Fatalf("socket path still exists: %v", err)
	}
	if err := removeProbeSocket(t.TempDir()); err != nil {
		t.Fatalf("missing bootstrap should be idempotent: %v", err)
	}
}
