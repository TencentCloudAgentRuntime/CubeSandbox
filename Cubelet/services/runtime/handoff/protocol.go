// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// Package handoff implements the Kubernetes runtime FD handoff v1 contract.
// It is deliberately separate from the legacy cubetap JSON protocol.
package handoff

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"syscall"

	runtimev1 "github.com/tencentcloud/CubeSandbox/Cubelet/api/services/runtime/v1"
	"github.com/tencentcloud/CubeSandbox/Cubelet/internal/kmutex"
	"google.golang.org/protobuf/proto"
)

const (
	ProtocolVersion uint32 = 1
	MaxFrameSize           = 64 * 1024
)

var (
	ErrMalformedRequest = errors.New("malformed fd handoff request")
	ErrStaleLease       = errors.New("stale fd handoff lease")
	ErrLeaseNotReady    = errors.New("fd handoff lease is not ready")
)

// Binding is the exact READY lease identity allowed to receive a TAP FD.
type Binding struct {
	SandboxID     string
	Generation    uint64
	LeaseID       string
	NetworkHandle string
	Token         string
	Ready         bool
}

// TapOpener returns a fresh caller-owned duplicate for a validated binding.
type TapOpener func(binding Binding) (*os.File, error)

// Registry atomically fences FD acquisition against release and replacement.
// A keyed lock is held through TapOpener for one sandbox; the map lock protects
// only lookup/publication so unrelated sandbox FD handoffs can overlap.
type Registry struct {
	operations kmutex.KeyedLocker
	mu         sync.RWMutex
	current    map[string]Binding
	opener     TapOpener
}

func NewRegistry(opener TapOpener) (*Registry, error) {
	if opener == nil {
		return nil, errors.New("fd handoff tap opener is nil")
	}
	return &Registry{
		operations: kmutex.New(),
		current:    make(map[string]Binding),
		opener:     opener,
	}, nil
}

// Publish sets the current durable lease view. S1 calls this only after loading
// or committing the corresponding state-machine record.
func (r *Registry) Publish(binding Binding) error {
	if err := validateBinding(binding); err != nil {
		return err
	}
	if err := r.operations.Lock(context.Background(), binding.SandboxID); err != nil {
		return err
	}
	defer r.operations.Unlock(binding.SandboxID)
	r.mu.Lock()
	defer r.mu.Unlock()
	if current, ok := r.current[binding.SandboxID]; ok && current != binding {
		delete(r.current, binding.SandboxID)
		return fmt.Errorf("sandbox %q had a conflicting published lease; binding was removed", binding.SandboxID)
	}
	r.current[binding.SandboxID] = binding
	return nil
}

// Invalidate removes exactly the matching current binding before cleanup.
func (r *Registry) Invalidate(binding Binding) bool {
	if err := r.operations.Lock(context.Background(), binding.SandboxID); err != nil {
		return false
	}
	defer r.operations.Unlock(binding.SandboxID)
	r.mu.Lock()
	defer r.mu.Unlock()
	current, ok := r.current[binding.SandboxID]
	if !ok || current != binding {
		return false
	}
	delete(r.current, binding.SandboxID)
	return true
}

// Acquire validates all fenced fields and returns one fresh duplicate. Retries
// are allowed and each successful retry returns a new caller-owned FD.
func (r *Registry) Acquire(request *runtimev1.FDHandoffRequestV1) (*os.File, runtimev1.FDHandoffCode, error) {
	if err := validateRequest(request); err != nil {
		return nil, runtimev1.FDHandoffCode_FD_HANDOFF_CODE_MALFORMED, err
	}

	if err := r.operations.Lock(context.Background(), request.GetSandboxId()); err != nil {
		return nil, runtimev1.FDHandoffCode_FD_HANDOFF_CODE_INTERNAL, err
	}
	defer r.operations.Unlock(request.GetSandboxId())

	r.mu.RLock()
	current, ok := r.current[request.GetSandboxId()]
	r.mu.RUnlock()
	if !ok ||
		current.Generation != request.GetGeneration() ||
		current.LeaseID != request.GetLeaseId() ||
		current.NetworkHandle != request.GetNetworkHandle() ||
		current.Token != request.GetToken() {
		return nil, runtimev1.FDHandoffCode_FD_HANDOFF_CODE_STALE, ErrStaleLease
	}
	if !current.Ready {
		return nil, runtimev1.FDHandoffCode_FD_HANDOFF_CODE_NOT_READY, ErrLeaseNotReady
	}

	file, err := r.opener(current)
	if err != nil {
		return nil, runtimev1.FDHandoffCode_FD_HANDOFF_CODE_INTERNAL, err
	}
	if file == nil {
		return nil, runtimev1.FDHandoffCode_FD_HANDOFF_CODE_INTERNAL, errors.New("tap opener returned nil file")
	}
	return file, runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK, nil
}

func validateBinding(binding Binding) error {
	if binding.SandboxID == "" || binding.Generation == 0 || binding.LeaseID == "" ||
		binding.NetworkHandle == "" || binding.Token == "" {
		return fmt.Errorf("%w: binding fields must be non-zero", ErrMalformedRequest)
	}
	return nil
}

func validateRequest(request *runtimev1.FDHandoffRequestV1) error {
	if request == nil || request.GetProtocolVersion() != ProtocolVersion ||
		request.GetSandboxId() == "" || request.GetGeneration() == 0 ||
		request.GetLeaseId() == "" || request.GetNetworkHandle() == "" ||
		request.GetToken() == "" {
		return ErrMalformedRequest
	}
	return nil
}

// ReadRequest reads one four-byte big-endian length-prefixed protobuf frame.
func ReadRequest(reader io.Reader) (*runtimev1.FDHandoffRequestV1, error) {
	payload, err := readFrame(reader)
	if err != nil {
		return nil, err
	}
	request := new(runtimev1.FDHandoffRequestV1)
	if err := proto.Unmarshal(payload, request); err != nil {
		return nil, fmt.Errorf("%w: decode request: %v", ErrMalformedRequest, err)
	}
	if err := validateRequest(request); err != nil {
		return nil, err
	}
	return request, nil
}

func readFrame(reader io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, fmt.Errorf("%w: read frame header: %v", ErrMalformedRequest, err)
	}
	size := binary.BigEndian.Uint32(header[:])
	if size == 0 || size > MaxFrameSize {
		return nil, fmt.Errorf("%w: invalid frame size %d", ErrMalformedRequest, size)
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return nil, fmt.Errorf("%w: read frame payload: %v", ErrMalformedRequest, err)
	}
	return payload, nil
}

func marshalFrame(message proto.Message) ([]byte, error) {
	payload, err := proto.Marshal(message)
	if err != nil {
		return nil, err
	}
	if len(payload) == 0 || len(payload) > MaxFrameSize {
		return nil, fmt.Errorf("invalid encoded frame size %d", len(payload))
	}
	frame := make([]byte, 4+len(payload))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(payload)))
	copy(frame[4:], payload)
	return frame, nil
}

// SendResponse sends one framed response. OK requires exactly one FD; every
// error response is normalized to fd_count=0 and carries no ancillary data.
func SendResponse(conn *net.UnixConn, response *runtimev1.FDHandoffResponseV1, file *os.File) error {
	if conn == nil || response == nil {
		return errors.New("fd handoff response connection/message is nil")
	}
	response.ProtocolVersion = ProtocolVersion
	var rights []byte
	if response.GetCode() == runtimev1.FDHandoffCode_FD_HANDOFF_CODE_OK {
		if file == nil {
			return errors.New("successful fd handoff response has no file")
		}
		response.FdCount = 1
		rights = syscall.UnixRights(int(file.Fd()))
	} else {
		response.FdCount = 0
		file = nil
	}
	frame, err := marshalFrame(response)
	if err != nil {
		return err
	}
	written, oobWritten, err := conn.WriteMsgUnix(frame, rights, nil)
	if err != nil {
		return err
	}
	if written != len(frame) || oobWritten != len(rights) {
		return fmt.Errorf("short fd handoff response: data=%d/%d oob=%d/%d", written, len(frame), oobWritten, len(rights))
	}
	return nil
}

// FenceCurrent serializes a durable lifecycle transition with FD acquisition.
// Lock order is Registry.operations[sandbox] followed by the durable Store
// operation lock for that sandbox. The registry map lock is never held while
// persist performs filesystem I/O.
// A definitely-uncommitted failure leaves READY published. A commit-unknown
// failure removes it fail-closed; success also removes it before blocked Acquire continues.
func (r *Registry) FenceCurrent(binding Binding, persist func() error) error {
	if err := validateBinding(binding); err != nil {
		return err
	}
	if persist == nil {
		return errors.New("fd handoff durable fence callback is nil")
	}
	if err := r.operations.Lock(context.Background(), binding.SandboxID); err != nil {
		return err
	}
	defer r.operations.Unlock(binding.SandboxID)
	r.mu.RLock()
	current, ok := r.current[binding.SandboxID]
	r.mu.RUnlock()
	if !ok || current != binding {
		return ErrStaleLease
	}
	if err := persist(); err != nil {
		var outcome interface{ CommitUnknown() bool }
		if errors.As(err, &outcome) && outcome.CommitUnknown() {
			r.mu.Lock()
			delete(r.current, binding.SandboxID)
			r.mu.Unlock()
		}
		return err
	}
	r.mu.Lock()
	delete(r.current, binding.SandboxID)
	r.mu.Unlock()
	return nil
}

// EnsureAbsent verifies that restart recovery did not publish a non-READY
// sandbox. A newly constructed Registry is empty; READY recovery uses Publish.
func (r *Registry) EnsureAbsent(sandboxID string) error {
	if sandboxID == "" {
		return fmt.Errorf("%w: sandbox id is empty", ErrMalformedRequest)
	}
	if err := r.operations.Lock(context.Background(), sandboxID); err != nil {
		return err
	}
	defer r.operations.Unlock(sandboxID)
	r.mu.RLock()
	defer r.mu.RUnlock()
	if _, ok := r.current[sandboxID]; ok {
		return fmt.Errorf("sandbox %q unexpectedly has a published FD binding", sandboxID)
	}
	return nil
}
