// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// Package state implements the durable RuntimeResource v1 lease state machine.
package state

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"sync"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Phase string

const (
	PhasePreparing Phase = "PREPARING"
	PhaseReady     Phase = "READY"
	PhaseReleasing Phase = "RELEASING"
)

type Operation string

const (
	OperationPrepare Operation = "PREPARE"
	OperationRelease Operation = "RELEASE"
)

type PrepareRequest struct {
	SandboxID      string
	Generation     uint64
	IdempotencyKey string
	PayloadDigest  string
}

type ReleaseRequest struct {
	SandboxID      string
	Generation     uint64
	LeaseID        string
	IdempotencyKey string
}

type Lease struct {
	Generation    uint64 `json:"generation"`
	LeaseID       string `json:"leaseID"`
	PrepareKey    string `json:"prepareKey"`
	PayloadDigest string `json:"payloadDigest"`
	HandoffToken  string `json:"handoffToken"`
	NetworkHandle string `json:"networkHandle,omitempty"`
	ReleaseKey    string `json:"releaseKey,omitempty"`
	Phase         Phase  `json:"phase"`
}

type Tombstone struct {
	Generation    uint64 `json:"generation"`
	LeaseID       string `json:"leaseID"`
	PrepareKey    string `json:"prepareKey"`
	PayloadDigest string `json:"payloadDigest"`
	ReleaseKey    string `json:"releaseKey"`
}

type KeyUse struct {
	Operation     Operation `json:"operation"`
	Generation    uint64    `json:"generation"`
	LeaseID       string    `json:"leaseID,omitempty"`
	PayloadDigest string    `json:"payloadDigest,omitempty"`
}

type Record struct {
	SandboxID       string               `json:"sandboxID"`
	HighWatermark   uint64               `json:"highWatermark"`
	Active          *Lease               `json:"active,omitempty"`
	Tombstones      map[string]Tombstone `json:"tombstones,omitempty"`
	IdempotencyKeys map[string]KeyUse    `json:"idempotencyKeys,omitempty"`
}

type PrepareResult struct {
	Lease  Lease
	Reused bool
}

type ReleaseResult struct {
	Lease  Lease
	Reused bool
}

// ValueGenerator returns a durable opaque value. Production uses crypto/rand;
// tests inject a deterministic generator.
type ValueGenerator func() (string, error)

// PersistenceHooks are deterministic durability fault-injection points. A
// BeforeRename failure is definitely not committed; BeforeParentSync runs
// after rename and therefore produces a commit-unknown result.
type PersistenceHooks struct {
	BeforeRename     func() error
	BeforeParentSync func() error
}

type OpenOption func(*Store)

func WithPersistenceHooks(hooks PersistenceHooks) OpenOption {
	return func(store *Store) { store.hooks = hooks }
}

// PersistenceError preserves whether a failed durable write may already be
// visible. It also maps to gRPC UNAVAILABLE without losing outcome metadata.
type PersistenceError struct {
	stage         string
	cause         error
	commitUnknown bool
}

func (e *PersistenceError) Error() string {
	return fmt.Sprintf("persist runtime state at %s (commit_unknown=%t): %v", e.stage, e.commitUnknown, e.cause)
}

func (e *PersistenceError) Unwrap() error { return e.cause }

func (e *PersistenceError) CommitUnknown() bool { return e.commitUnknown }

func (e *PersistenceError) GRPCStatus() *status.Status {
	return status.New(codes.Unavailable, e.Error())
}

func IsCommitUnknown(err error) bool {
	var persistenceError *PersistenceError
	return errors.As(err, &persistenceError) && persistenceError.CommitUnknown()
}

func persistenceFailure(stage string, commitUnknown bool, err error) error {
	return &PersistenceError{stage: stage, cause: err, commitUnknown: commitUnknown}
}

type Store struct {
	dir      string
	generate ValueGenerator
	hooks    PersistenceHooks
	mu       sync.Mutex
}

func Open(dir string, generator ValueGenerator, options ...OpenOption) (*Store, error) {
	if dir == "" {
		return nil, errors.New("runtime state directory is empty")
	}
	if generator == nil {
		generator = randomValue
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	store := &Store{dir: dir, generate: generator}
	for _, option := range options {
		if option != nil {
			option(store)
		}
	}
	return store, nil
}

func leaseIDForPrepare(request PrepareRequest) string {
	hasher := sha256.New()
	for _, part := range [][]byte{[]byte("cube-runtime-resource-lease-v1"), []byte(request.SandboxID), []byte(strconv.FormatUint(request.Generation, 10)), []byte(request.IdempotencyKey)} {
		var size [8]byte
		binary.BigEndian.PutUint64(size[:], uint64(len(part)))
		_, _ = hasher.Write(size[:])
		_, _ = hasher.Write(part)
	}
	return hex.EncodeToString(hasher.Sum(nil))
}

func randomValue() (string, error) {
	var value [32]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}

// Prepare accepts only a strictly newer generation when no active lease
// exists. The same key and payload retry returns the durable result.
func (s *Store) Prepare(request PrepareRequest) (*PrepareResult, error) {
	if request.SandboxID == "" || request.Generation == 0 ||
		request.IdempotencyKey == "" || request.PayloadDigest == "" {
		return nil, status.Error(codes.InvalidArgument, "prepare fields must be non-zero")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	record, err := s.loadOrNew(request.SandboxID)
	if err != nil {
		return nil, status.Error(codes.Unavailable, err.Error())
	}
	if use, ok := record.IdempotencyKeys[request.IdempotencyKey]; ok {
		if use.Operation != OperationPrepare || use.Generation != request.Generation ||
			use.PayloadDigest != request.PayloadDigest {
			return nil, status.Error(codes.InvalidArgument, "idempotency key was reused for another operation or desired state")
		}
		if record.Active != nil && record.Active.PrepareKey == request.IdempotencyKey {
			return &PrepareResult{Lease: *record.Active, Reused: true}, nil
		}
		return nil, status.Error(codes.FailedPrecondition, "prepare generation is already released and cannot be resurrected")
	}

	if record.Active != nil {
		switch {
		case request.Generation < record.Active.Generation:
			return nil, status.Error(codes.FailedPrecondition, "prepare generation is stale")
		case request.Generation == record.Active.Generation && request.PayloadDigest != record.Active.PayloadDigest:
			return nil, status.Error(codes.FailedPrecondition, "same generation has a different desired payload")
		case request.Generation == record.Active.Generation:
			return nil, status.Error(codes.FailedPrecondition, "same generation must retry with its original idempotency key")
		default:
			return nil, status.Error(codes.FailedPrecondition, "release the active generation before preparing a newer generation")
		}
	}
	if request.Generation <= record.HighWatermark {
		return nil, status.Error(codes.FailedPrecondition, "prepare generation is at or below the durable high-watermark")
	}

	leaseID := leaseIDForPrepare(request)
	token, err := s.generate()
	if err != nil {
		return nil, status.Error(codes.Unavailable, err.Error())
	}
	lease := &Lease{
		Generation:    request.Generation,
		LeaseID:       leaseID,
		PrepareKey:    request.IdempotencyKey,
		PayloadDigest: request.PayloadDigest,
		HandoffToken:  token,
		Phase:         PhasePreparing,
	}
	record.HighWatermark = request.Generation
	record.Active = lease
	record.IdempotencyKeys[request.IdempotencyKey] = KeyUse{
		Operation:     OperationPrepare,
		Generation:    request.Generation,
		LeaseID:       leaseID,
		PayloadDigest: request.PayloadDigest,
	}
	if err := s.persist(record); err != nil {
		return nil, err
	}
	return &PrepareResult{Lease: *lease}, nil
}

// MarkReady binds the network handle to the exact current lease. It is
// idempotent for an identical READY record.
func (s *Store) MarkReady(sandboxID string, generation uint64, leaseID, networkHandle string) (*Lease, error) {
	if sandboxID == "" || generation == 0 || leaseID == "" || networkHandle == "" {
		return nil, status.Error(codes.InvalidArgument, "ready fields must be non-zero")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.load(sandboxID)
	if err != nil {
		return nil, stateLoadError(err)
	}
	if record.Active == nil || record.Active.Generation != generation || record.Active.LeaseID != leaseID {
		return nil, status.Error(codes.FailedPrecondition, "ready identity does not match the current lease")
	}
	switch record.Active.Phase {
	case PhasePreparing:
		record.Active.Phase = PhaseReady
		record.Active.NetworkHandle = networkHandle
	case PhaseReady:
		if record.Active.NetworkHandle != networkHandle {
			return nil, status.Error(codes.FailedPrecondition, "ready retry changed the network handle")
		}
		return cloneLease(record.Active), nil
	default:
		return nil, status.Error(codes.FailedPrecondition, "releasing lease cannot become ready")
	}
	if err := s.persist(record); err != nil {
		return nil, err
	}
	return cloneLease(record.Active), nil
}

// BeginRelease durably fences FD handoff before cleanup. A release key is valid
// only for this exact generation and lease.
func (s *Store) BeginRelease(request ReleaseRequest) (*ReleaseResult, error) {
	if request.SandboxID == "" || request.Generation == 0 || request.LeaseID == "" || request.IdempotencyKey == "" {
		return nil, status.Error(codes.InvalidArgument, "release fields must be non-zero")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.load(request.SandboxID)
	if err != nil {
		return nil, stateLoadError(err)
	}
	if use, ok := record.IdempotencyKeys[request.IdempotencyKey]; ok {
		if use.Operation != OperationRelease || use.Generation != request.Generation || use.LeaseID != request.LeaseID {
			return nil, status.Error(codes.InvalidArgument, "idempotency key was reused for another operation or lease")
		}
		if record.Active != nil && record.Active.Generation == request.Generation &&
			record.Active.LeaseID == request.LeaseID && record.Active.ReleaseKey == request.IdempotencyKey {
			return &ReleaseResult{Lease: *record.Active, Reused: true}, nil
		}
		if tombstone, ok := record.Tombstones[generationKey(request.Generation)]; ok &&
			tombstone.LeaseID == request.LeaseID && tombstone.ReleaseKey == request.IdempotencyKey {
			return &ReleaseResult{Lease: leaseFromTombstone(tombstone), Reused: true}, nil
		}
		return nil, status.Error(codes.FailedPrecondition, "release key has no matching current or tombstoned lease")
	}
	if record.Active == nil {
		if request.Generation > record.HighWatermark {
			return nil, status.Error(codes.NotFound, "release generation was never prepared")
		}
		return nil, status.Error(codes.FailedPrecondition, "release does not match a durable tombstone")
	}
	if record.Active.Generation != request.Generation || record.Active.LeaseID != request.LeaseID {
		return nil, status.Error(codes.FailedPrecondition, "release identity does not match the current lease")
	}
	if record.Active.ReleaseKey != "" {
		return nil, status.Error(codes.FailedPrecondition, "release must retry with its original idempotency key")
	}
	record.Active.ReleaseKey = request.IdempotencyKey
	record.Active.Phase = PhaseReleasing
	record.IdempotencyKeys[request.IdempotencyKey] = KeyUse{
		Operation:  OperationRelease,
		Generation: request.Generation,
		LeaseID:    request.LeaseID,
	}
	if err := s.persist(record); err != nil {
		return nil, err
	}
	return &ReleaseResult{Lease: *record.Active}, nil
}

// ConfirmReleaseDurable validates the exact releasing identity and fsyncs the
// parent directory. It is the only operation that resolves a post-rename
// commit-unknown result; both retry and restart recovery call it.
func (s *Store) ConfirmReleaseDurable(request ReleaseRequest) (*ReleaseResult, error) {
	if request.SandboxID == "" || request.Generation == 0 || request.LeaseID == "" || request.IdempotencyKey == "" {
		return nil, status.Error(codes.InvalidArgument, "release confirmation fields must be non-zero")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.load(request.SandboxID)
	if err != nil {
		return nil, stateLoadError(err)
	}
	if record.Active != nil && record.Active.Phase == PhaseReleasing &&
		record.Active.Generation == request.Generation && record.Active.LeaseID == request.LeaseID &&
		record.Active.ReleaseKey == request.IdempotencyKey {
		if err := s.syncParent("confirm-release"); err != nil {
			return nil, err
		}
		return &ReleaseResult{Lease: *record.Active, Reused: true}, nil
	}
	if tombstone, ok := record.Tombstones[generationKey(request.Generation)]; ok &&
		tombstone.LeaseID == request.LeaseID && tombstone.ReleaseKey == request.IdempotencyKey {
		if err := s.syncParent("confirm-tombstone"); err != nil {
			return nil, err
		}
		return &ReleaseResult{Lease: leaseFromTombstone(tombstone), Reused: true}, nil
	}
	return nil, status.Error(codes.FailedPrecondition, "release durability confirmation does not match persistent state")
}

// CompleteRelease writes a tombstone and removes the active lease. Exact
// retries remain successful across restarts.
func (s *Store) CompleteRelease(request ReleaseRequest) error {
	if request.SandboxID == "" || request.Generation == 0 || request.LeaseID == "" || request.IdempotencyKey == "" {
		return status.Error(codes.InvalidArgument, "complete release fields must be non-zero")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.load(request.SandboxID)
	if err != nil {
		return stateLoadError(err)
	}
	if tombstone, ok := record.Tombstones[generationKey(request.Generation)]; ok &&
		tombstone.LeaseID == request.LeaseID && tombstone.ReleaseKey == request.IdempotencyKey {
		return nil
	}
	if record.Active == nil {
		return status.Error(codes.FailedPrecondition, "complete release does not match a tombstone")
	}
	if record.Active.Generation != request.Generation || record.Active.LeaseID != request.LeaseID ||
		record.Active.ReleaseKey != request.IdempotencyKey || record.Active.Phase != PhaseReleasing {
		return status.Error(codes.FailedPrecondition, "complete release does not match the releasing lease")
	}
	record.Tombstones[generationKey(request.Generation)] = Tombstone{
		Generation:    record.Active.Generation,
		LeaseID:       record.Active.LeaseID,
		PrepareKey:    record.Active.PrepareKey,
		PayloadDigest: record.Active.PayloadDigest,
		ReleaseKey:    record.Active.ReleaseKey,
	}
	record.Active = nil
	if err := s.persist(record); err != nil {
		return err
	}
	return nil
}

// AbandonPrepare tombstones a failed PREPARING lease so delayed Prepare cannot
// resurrect its generation. Resource cleanup must finish before calling this.
func (s *Store) AbandonPrepare(sandboxID string, generation uint64, leaseID string) error {
	if sandboxID == "" || generation == 0 || leaseID == "" {
		return status.Error(codes.InvalidArgument, "abandon fields must be non-zero")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.load(sandboxID)
	if err != nil {
		return stateLoadError(err)
	}
	if record.Active == nil || record.Active.Phase != PhasePreparing ||
		record.Active.Generation != generation || record.Active.LeaseID != leaseID {
		return status.Error(codes.FailedPrecondition, "abandon identity does not match the preparing lease")
	}
	record.Tombstones[generationKey(generation)] = Tombstone{
		Generation:    generation,
		LeaseID:       leaseID,
		PrepareKey:    record.Active.PrepareKey,
		PayloadDigest: record.Active.PayloadDigest,
	}
	record.Active = nil
	if err := s.persist(record); err != nil {
		return err
	}
	return nil
}

func (s *Store) ListSandboxIDs() ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, status.Error(codes.Unavailable, err.Error())
	}
	ids := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(s.dir, entry.Name()))
		if err != nil {
			return nil, status.Error(codes.Unavailable, err.Error())
		}
		record := new(Record)
		if err := json.Unmarshal(data, record); err != nil {
			return nil, status.Errorf(codes.Unavailable, "decode runtime state %s: %v", entry.Name(), err)
		}
		if record.SandboxID == "" || filepath.Base(s.recordPath(record.SandboxID)) != entry.Name() {
			return nil, status.Errorf(codes.Unavailable, "runtime state file %s has invalid sandbox identity", entry.Name())
		}
		ids = append(ids, record.SandboxID)
	}
	sort.Strings(ids)
	return ids, nil
}

func (s *Store) Inspect(sandboxID string) (*Record, error) {
	if sandboxID == "" {
		return nil, status.Error(codes.InvalidArgument, "sandbox id is empty")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.load(sandboxID)
	if err != nil {
		return nil, stateLoadError(err)
	}
	copy := *record
	if record.Active != nil {
		copy.Active = cloneLease(record.Active)
	}
	copy.Tombstones = cloneTombstones(record.Tombstones)
	copy.IdempotencyKeys = cloneKeys(record.IdempotencyKeys)
	return &copy, nil
}

func (s *Store) loadOrNew(sandboxID string) (*Record, error) {
	record, err := s.load(sandboxID)
	if err == nil {
		return record, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return &Record{
		SandboxID:       sandboxID,
		Tombstones:      make(map[string]Tombstone),
		IdempotencyKeys: make(map[string]KeyUse),
	}, nil
}

func (s *Store) load(sandboxID string) (*Record, error) {
	data, err := os.ReadFile(s.recordPath(sandboxID))
	if err != nil {
		return nil, err
	}
	record := new(Record)
	if err := json.Unmarshal(data, record); err != nil {
		return nil, err
	}
	if record.SandboxID != sandboxID {
		return nil, fmt.Errorf("runtime state sandbox mismatch: got %q want %q", record.SandboxID, sandboxID)
	}
	if record.Tombstones == nil {
		record.Tombstones = make(map[string]Tombstone)
	}
	if record.IdempotencyKeys == nil {
		record.IdempotencyKeys = make(map[string]KeyUse)
	}
	return record, nil
}

func (s *Store) persist(record *Record) error {
	data, err := json.Marshal(record)
	if err != nil {
		return persistenceFailure("encode", false, err)
	}
	temp, err := os.CreateTemp(s.dir, ".runtime-state-*")
	if err != nil {
		return persistenceFailure("create-temp", false, err)
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return persistenceFailure("chmod-temp", false, err)
	}
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return persistenceFailure("write-temp", false, err)
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return persistenceFailure("sync-temp", false, err)
	}
	if err := temp.Close(); err != nil {
		return persistenceFailure("close-temp", false, err)
	}
	if s.hooks.BeforeRename != nil {
		if err := s.hooks.BeforeRename(); err != nil {
			return persistenceFailure("before-rename", false, err)
		}
	}
	if err := os.Rename(tempName, s.recordPath(record.SandboxID)); err != nil {
		return persistenceFailure("rename", false, err)
	}
	return s.syncParent("commit")
}

func (s *Store) syncParent(operation string) error {
	if s.hooks.BeforeParentSync != nil {
		if err := s.hooks.BeforeParentSync(); err != nil {
			return persistenceFailure(operation+"-before-parent-sync", true, err)
		}
	}
	dir, err := os.Open(s.dir)
	if err != nil {
		return persistenceFailure(operation+"-open-parent", true, err)
	}
	defer dir.Close()
	if err := dir.Sync(); err != nil {
		return persistenceFailure(operation+"-sync-parent", true, err)
	}
	return nil
}

func (s *Store) recordPath(sandboxID string) string {
	sum := sha256.Sum256([]byte(sandboxID))
	return filepath.Join(s.dir, hex.EncodeToString(sum[:])+".json")
}

func generationKey(generation uint64) string {
	return strconv.FormatUint(generation, 10)
}

func stateLoadError(err error) error {
	if errors.Is(err, os.ErrNotExist) {
		return status.Error(codes.NotFound, "runtime sandbox state not found")
	}
	return status.Error(codes.Unavailable, err.Error())
}

func cloneLease(lease *Lease) *Lease {
	if lease == nil {
		return nil
	}
	copy := *lease
	return &copy
}

func cloneTombstones(source map[string]Tombstone) map[string]Tombstone {
	result := make(map[string]Tombstone, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

func cloneKeys(source map[string]KeyUse) map[string]KeyUse {
	result := make(map[string]KeyUse, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

func leaseFromTombstone(tombstone Tombstone) Lease {
	return Lease{
		Generation:    tombstone.Generation,
		LeaseID:       tombstone.LeaseID,
		PrepareKey:    tombstone.PrepareKey,
		PayloadDigest: tombstone.PayloadDigest,
		ReleaseKey:    tombstone.ReleaseKey,
		Phase:         PhaseReleasing,
	}
}
