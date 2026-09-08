// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
)

const (
	// DefaultReaperRoot is shared with CubeShim. It must reside on persistent
	// node storage rather than /run so job-only recovery survives reboot.
	DefaultReaperRoot = "/data/cubelet/runtime-resource-reaper"
	reaperRecordName  = "cube-runtime-resource.json"
)

type reaperRecord struct {
	Endpoint   string `json:"endpoint"`
	SandboxID  string `json:"sandbox_id"`
	LeaseID    string `json:"lease_id"`
	Generation uint64 `json:"generation"`
}

// RecoverReaperJobs consumes the durable queue written outside containerd
// bundles. It is safe to run concurrently with the detached CubeShim reaper:
// Release is exact/idempotent and job removal tolerates a racing consumer.
func (s *Service) RecoverReaperJobs(ctx context.Context, root string) error {
	if !filepath.IsAbs(root) {
		return fmt.Errorf("RuntimeResource reaper root must be absolute: %q", root)
	}
	s.reaperMu.Lock()
	defer s.reaperMu.Unlock()
	if err := ensureDirectoryDurable(root); err != nil {
		return fmt.Errorf("prepare RuntimeResource reaper root: %w", err)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return fmt.Errorf("list RuntimeResource reaper jobs: %w", err)
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		job := filepath.Join(root, entry.Name())
		recordPath := filepath.Join(job, reaperRecordName)
		data, err := os.ReadFile(recordPath)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return fmt.Errorf("read RuntimeResource reaper job %s: %w", job, err)
		}
		record := new(reaperRecord)
		if err := json.Unmarshal(data, record); err != nil {
			return fmt.Errorf("decode RuntimeResource reaper job %s: %w", job, err)
		}
		if !filepath.IsAbs(record.Endpoint) || record.SandboxID == "" || record.LeaseID == "" || record.Generation == 0 {
			return fmt.Errorf("RuntimeResource reaper job %s has invalid identity", job)
		}
		if err := s.lockOperation(ctx, record.SandboxID); err != nil {
			return err
		}
		releaseErr := s.releaseLocked(ctx, state.ReleaseRequest{
			SandboxID: record.SandboxID, Generation: record.Generation, LeaseID: record.LeaseID,
			IdempotencyKey: state.ExpectedReleaseKey(record.SandboxID, record.Generation, record.LeaseID),
		})
		s.operations.Unlock(record.SandboxID)
		if releaseErr != nil {
			return fmt.Errorf("release RuntimeResource reaper job %s: %w", job, releaseErr)
		}
		if err := removeReaperJob(root, job, recordPath); err != nil {
			return err
		}
	}
	return nil
}

// RunReaperSupervisor scans immediately and then periodically until ctx ends.
// Errors are reported but do not discard the durable job; the next scan retries.
func (s *Service) RunReaperSupervisor(ctx context.Context, root string, interval time.Duration, report func(error)) {
	if interval <= 0 {
		interval = time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if err := s.RecoverReaperJobs(ctx, root); err != nil && report != nil {
			report(err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func removeReaperJob(root, job, recordPath string) error {
	if err := os.Remove(recordPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove RuntimeResource reaper record %s: %w", recordPath, err)
	}
	if err := syncDirectory(job); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("sync RuntimeResource reaper job %s: %w", job, err)
	}
	if err := os.Remove(job); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove RuntimeResource reaper job %s: %w", job, err)
	}
	if err := syncDirectory(root); err != nil {
		return fmt.Errorf("sync RuntimeResource reaper root %s: %w", root, err)
	}
	return nil
}

func ensureDirectoryDurable(path string) error {
	clean := filepath.Clean(path)
	missing := make([]string, 0)
	for current := clean; ; current = filepath.Dir(current) {
		_, err := os.Stat(current)
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		missing = append(missing, current)
		parent := filepath.Dir(current)
		if parent == current {
			return fmt.Errorf("no existing ancestor for %s", clean)
		}
	}
	for index := len(missing) - 1; index >= 0; index-- {
		directory := missing[index]
		if err := os.Mkdir(directory, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		if err := syncDirectory(filepath.Dir(directory)); err != nil {
			return err
		}
	}
	return syncDirectory(clean)
}

func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
