// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package handoff

import (
	"bytes"
	"encoding/binary"
	"errors"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"google.golang.org/protobuf/proto"
)

func testBinding(generation uint64, lease, handle, token string, ready bool) Binding {
	return Binding{
		SandboxID:     "sandbox-a",
		Generation:    generation,
		LeaseID:       lease,
		NetworkHandle: handle,
		Token:         token,
		Ready:         ready,
	}
}

func requestFor(binding Binding) *runtimev1.FDHandoffRequestV1 {
	return &runtimev1.FDHandoffRequestV1{
		ProtocolVersion: ProtocolVersion,
		SandboxId:       binding.SandboxID,
		Generation:      binding.Generation,
		LeaseId:         binding.LeaseID,
		NetworkHandle:   binding.NetworkHandle,
		Token:           binding.Token,
	}
}

func devNullOpener(Binding) (*os.File, error) {
	return os.Open("/dev/null")
}

func TestRegistryReplacementFencesDelayedOldGeneration(t *testing.T) {
	registry, err := NewRegistry(devNullOpener)
	if err != nil {
		t.Fatal(err)
	}
	oldBinding := testBinding(1, "lease-1", "network-1", "token-1", true)
	newBinding := testBinding(2, "lease-2", "network-2", "token-2", true)
	if err := registry.Publish(oldBinding); err != nil {
		t.Fatal(err)
	}
	if !registry.Invalidate(oldBinding) {
		t.Fatal("old binding was not invalidated")
	}
	if err := registry.Publish(newBinding); err != nil {
		t.Fatal(err)
	}

	file, code, err := registry.Acquire(requestFor(oldBinding))
	if file != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_STALE || !errors.Is(err, ErrStaleLease) {
		t.Fatalf("delayed old acquire=(%v,%s,%v), want nil, STALE, ErrStaleLease", file, code, err)
	}

	file, code, err = registry.Acquire(requestFor(newBinding))
	if err != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK || file == nil {
		t.Fatalf("new acquire=(%v,%s,%v), want one OK file", file, code, err)
	}
	file.Close()
}

func TestRegistryRejectsEveryMismatchedFenceAndReleasedLease(t *testing.T) {
	registry, err := NewRegistry(devNullOpener)
	if err != nil {
		t.Fatal(err)
	}
	binding := testBinding(7, "lease-7", "network-7", "token-7", true)
	if err := registry.Publish(binding); err != nil {
		t.Fatal(err)
	}

	mutations := []struct {
		name   string
		mutate func(*runtimev1.FDHandoffRequestV1)
	}{
		{"generation", func(request *runtimev1.FDHandoffRequestV1) { request.Generation++ }},
		{"lease", func(request *runtimev1.FDHandoffRequestV1) { request.LeaseId += "-stale" }},
		{"network", func(request *runtimev1.FDHandoffRequestV1) { request.NetworkHandle += "-stale" }},
		{"token", func(request *runtimev1.FDHandoffRequestV1) { request.Token += "-stale" }},
	}
	for _, test := range mutations {
		t.Run(test.name, func(t *testing.T) {
			request := requestFor(binding)
			test.mutate(request)
			file, code, err := registry.Acquire(request)
			if file != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_STALE || !errors.Is(err, ErrStaleLease) {
				t.Fatalf("Acquire=(%v,%s,%v), want nil, STALE, ErrStaleLease", file, code, err)
			}
		})
	}

	if !registry.Invalidate(binding) {
		t.Fatal("binding was not invalidated")
	}
	file, code, err := registry.Acquire(requestFor(binding))
	if file != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_STALE || !errors.Is(err, ErrStaleLease) {
		t.Fatalf("released acquire=(%v,%s,%v), want nil, STALE, ErrStaleLease", file, code, err)
	}
}

func TestRegistryRetryReturnsFreshCallerOwnedDuplicate(t *testing.T) {
	registry, err := NewRegistry(devNullOpener)
	if err != nil {
		t.Fatal(err)
	}
	binding := testBinding(1, "lease-1", "network-1", "token-1", true)
	if err := registry.Publish(binding); err != nil {
		t.Fatal(err)
	}
	first, firstCode, firstErr := registry.Acquire(requestFor(binding))
	if firstErr != nil || firstCode != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK {
		t.Fatalf("first acquire=(%s,%v)", firstCode, firstErr)
	}
	defer first.Close()
	second, secondCode, secondErr := registry.Acquire(requestFor(binding))
	if secondErr != nil || secondCode != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK {
		t.Fatalf("second acquire=(%s,%v)", secondCode, secondErr)
	}
	defer second.Close()
	if first.Fd() == second.Fd() {
		t.Fatalf("retry reused fd %d, want fresh duplicate", first.Fd())
	}
}

func TestRegistryRejectsNotReadyLease(t *testing.T) {
	registry, err := NewRegistry(devNullOpener)
	if err != nil {
		t.Fatal(err)
	}
	binding := testBinding(1, "lease-1", "network-1", "token-1", false)
	if err := registry.Publish(binding); err != nil {
		t.Fatal(err)
	}
	file, code, err := registry.Acquire(requestFor(binding))
	if file != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_NOT_READY || !errors.Is(err, ErrLeaseNotReady) {
		t.Fatalf("Acquire=(%v,%s,%v), want nil, NOT_READY, ErrLeaseNotReady", file, code, err)
	}
}

func TestReadRequestRejectsMalformedAndPartialFrames(t *testing.T) {
	valid := requestFor(testBinding(1, "lease", "network", "token", true))
	frame, err := marshalFrame(valid)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ReadRequest(bytes.NewReader(frame[:2])); !errors.Is(err, ErrMalformedRequest) {
		t.Fatalf("partial header error=%v", err)
	}
	if _, err := ReadRequest(bytes.NewReader(frame[:len(frame)-1])); !errors.Is(err, ErrMalformedRequest) {
		t.Fatalf("partial payload error=%v", err)
	}
	oversized := make([]byte, 4)
	binary.BigEndian.PutUint32(oversized, MaxFrameSize+1)
	if _, err := ReadRequest(bytes.NewReader(oversized)); !errors.Is(err, ErrMalformedRequest) {
		t.Fatalf("oversized frame error=%v", err)
	}
	invalidProto := []byte{0, 0, 0, 1, 0xff}
	if _, err := ReadRequest(bytes.NewReader(invalidProto)); !errors.Is(err, ErrMalformedRequest) {
		t.Fatalf("invalid protobuf error=%v", err)
	}
}

func unixConnPair(t *testing.T) (*net.UnixConn, *net.UnixConn) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "handoff.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })

	accepted := make(chan *net.UnixConn, 1)
	acceptErr := make(chan error, 1)
	go func() {
		conn, err := listener.AcceptUnix()
		if err != nil {
			acceptErr <- err
			return
		}
		accepted <- conn
	}()

	client, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case server := <-accepted:
		return server, client
	case err := <-acceptErr:
		client.Close()
		t.Fatal(err)
	case <-time.After(2 * time.Second):
		client.Close()
		t.Fatal("accept Unix connection timed out")
	}
	return nil, nil
}

func readResponse(t *testing.T, conn *net.UnixConn) (*runtimev1.FDHandoffResponseV1, []int) {
	t.Helper()
	data := make([]byte, MaxFrameSize+4)
	oob := make([]byte, syscall.CmsgSpace(4))
	n, oobn, _, _, err := conn.ReadMsgUnix(data, oob)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := readFrame(bytes.NewReader(data[:n]))
	if err != nil {
		t.Fatal(err)
	}
	response := new(runtimev1.FDHandoffResponseV1)
	if err := proto.Unmarshal(payload, response); err != nil {
		t.Fatal(err)
	}
	var fds []int
	if oobn > 0 {
		messages, err := syscall.ParseSocketControlMessage(oob[:oobn])
		if err != nil {
			t.Fatal(err)
		}
		for _, message := range messages {
			rights, err := syscall.ParseUnixRights(&message)
			if err != nil {
				t.Fatal(err)
			}
			fds = append(fds, rights...)
		}
	}
	return response, fds
}

func TestSendResponseErrorCarriesNoFDAndSuccessCarriesExactlyOne(t *testing.T) {
	t.Run("error", func(t *testing.T) {
		server, client := unixConnPair(t)
		defer server.Close()
		defer client.Close()
		file, err := os.Open("/dev/null")
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		if err := SendResponse(server, &runtimev1.FDHandoffResponseV1{
			Code:    runtimev1.FDHandoffCode_FD_HANDOFF_CODE_STALE,
			FdCount: 99,
		}, file); err != nil {
			t.Fatal(err)
		}
		response, fds := readResponse(t, client)
		if response.GetFdCount() != 0 || len(fds) != 0 {
			t.Fatalf("error response fd_count=%d rights=%v, want zero", response.GetFdCount(), fds)
		}
	})

	t.Run("success", func(t *testing.T) {
		server, client := unixConnPair(t)
		defer server.Close()
		defer client.Close()
		file, err := os.Open("/dev/null")
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		if err := SendResponse(server, &runtimev1.FDHandoffResponseV1{
			Code: runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK,
		}, file); err != nil {
			t.Fatal(err)
		}
		response, fds := readResponse(t, client)
		defer func() {
			for _, fd := range fds {
				syscall.Close(fd)
			}
		}()
		if response.GetFdCount() != 1 || len(fds) != 1 {
			t.Fatalf("success response fd_count=%d rights=%v, want exactly one", response.GetFdCount(), fds)
		}
	})
}

func TestAuthorizePeerIDsMatchesExactUnixPeer(t *testing.T) {
	server, client := unixConnPair(t)
	defer server.Close()
	defer client.Close()

	allowed := AuthorizePeerIDs(syscall.Ucred{
		Uid: uint32(os.Getuid()),
		Gid: uint32(os.Getgid()),
	})
	if err := allowed(server); err != nil {
		t.Fatalf("current peer was rejected: %v", err)
	}

	rejected := AuthorizePeerIDs(syscall.Ucred{Uid: ^uint32(0), Gid: ^uint32(0)})
	if err := rejected(server); err == nil {
		t.Fatal("unexpected UID/GID pair was accepted")
	}
}

func TestServeConnErrorsNeverCarryFD(t *testing.T) {
	tests := []struct {
		name      string
		authorize PeerAuthorizer
		write     func(*net.UnixConn) error
		wantCode  runtimev1.FDHandoffCode
	}{
		{
			name: "unauthorized",
			authorize: func(*net.UnixConn) error {
				return errors.New("peer denied")
			},
			wantCode: runtimev1.FDHandoffCode_FD_HANDOFF_CODE_UNAUTHORIZED,
		},
		{
			name: "malformed frame",
			write: func(conn *net.UnixConn) error {
				_, err := conn.Write([]byte{0, 0, 0, 1, 0xff})
				return err
			},
			wantCode: runtimev1.FDHandoffCode_FD_HANDOFF_CODE_MALFORMED,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			registry, err := NewRegistry(devNullOpener)
			if err != nil {
				t.Fatal(err)
			}
			server, client := unixConnPair(t)
			defer server.Close()
			defer client.Close()

			serveErr := make(chan error, 1)
			go func() { serveErr <- ServeConn(server, registry, test.authorize) }()
			if test.write != nil {
				if err := test.write(client); err != nil {
					t.Fatal(err)
				}
			}
			response, fds := readResponse(t, client)
			defer func() {
				for _, fd := range fds {
					syscall.Close(fd)
				}
			}()
			if response.GetCode() != test.wantCode || response.GetFdCount() != 0 || len(fds) != 0 {
				t.Fatalf("response=(%s, fd_count=%d, rights=%v), want %s with no FD",
					response.GetCode(), response.GetFdCount(), fds, test.wantCode)
			}
			if err := <-serveErr; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestRegistryAcquireIsAtomicWithReplacement(t *testing.T) {
	opened := make(chan struct{})
	allowDuplicate := make(chan struct{})
	opener := func(Binding) (*os.File, error) {
		close(opened)
		<-allowDuplicate
		return os.Open("/dev/null")
	}
	registry, err := NewRegistry(opener)
	if err != nil {
		t.Fatal(err)
	}
	oldBinding := testBinding(1, "lease-1", "network-1", "token-1", true)
	newBinding := testBinding(2, "lease-2", "network-2", "token-2", true)
	if err := registry.Publish(oldBinding); err != nil {
		t.Fatal(err)
	}

	type acquireResult struct {
		file *os.File
		code runtimev1.FDHandoffCode
		err  error
	}
	acquired := make(chan acquireResult, 1)
	go func() {
		file, code, err := registry.Acquire(requestFor(oldBinding))
		acquired <- acquireResult{file: file, code: code, err: err}
	}()
	<-opened

	replaced := make(chan error, 1)
	go func() {
		if !registry.Invalidate(oldBinding) {
			replaced <- errors.New("old binding was not invalidated")
			return
		}
		replaced <- registry.Publish(newBinding)
	}()
	select {
	case err := <-replaced:
		t.Fatalf("replacement passed validation/duplication critical section: %v", err)
	case <-time.After(20 * time.Millisecond):
	}

	close(allowDuplicate)
	result := <-acquired
	if result.err != nil || result.code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK || result.file == nil {
		t.Fatalf("in-flight acquire=(%v,%s,%v), want one OK file", result.file, result.code, result.err)
	}
	result.file.Close()
	if err := <-replaced; err != nil {
		t.Fatal(err)
	}
	file, code, err := registry.Acquire(requestFor(oldBinding))
	if file != nil || code != runtimev1.FDHandoffCode_FD_HANDOFF_CODE_STALE || !errors.Is(err, ErrStaleLease) {
		t.Fatalf("post-replacement old acquire=(%v,%s,%v), want STALE without file", file, code, err)
	}
}
