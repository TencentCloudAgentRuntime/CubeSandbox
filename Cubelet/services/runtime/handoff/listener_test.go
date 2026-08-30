// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package handoff

import (
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
)

func TestListenerServesOneSCMRightsFDAndRemovesSocket(t *testing.T) {
	registry, err := NewRegistry(devNullOpener)
	if err != nil {
		t.Fatal(err)
	}
	binding := testBinding(1, "lease-1", "network-1", "token-1", true)
	if err := registry.Publish(binding); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "runtime-fd.sock")
	listener, err := Listen(path, 0o660, registry, AuthorizePeerIDs(syscall.Ucred{
		Uid: uint32(os.Getuid()), Gid: uint32(os.Getgid()),
	}))
	if err != nil {
		t.Fatal(err)
	}

	conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	frame, err := marshalFrame(requestFor(binding))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write(frame); err != nil {
		t.Fatal(err)
	}
	response, fds := readResponse(t, conn)
	conn.Close()
	for _, fd := range fds {
		syscall.Close(fd)
	}
	if response.GetCode() != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK || response.GetFdCount() != 1 || len(fds) != 1 {
		t.Fatalf("response=%+v fds=%v", response, fds)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("listener socket remains after close: %v", err)
	}
}
