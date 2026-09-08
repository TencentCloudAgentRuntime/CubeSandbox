// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// RunMetricsSampler keeps state-directory work off the Prometheus request path.
func (s *Service) RunMetricsSampler(ctx context.Context, reaperRoot string, interval time.Duration) {
	if s.metrics == nil {
		return
	}
	if interval <= 0 {
		interval = 15 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		s.metrics.SetStateCollection(s.sampleMetrics(reaperRoot) == nil, time.Now())
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *Service) sampleMetrics(reaperRoot string) error {
	counts := map[string]float64{"PREPARING": 0, "READY": 0, "RELEASING": 0, "UNKNOWN": 0}
	ids, err := s.store.ListSandboxIDs()
	if err != nil {
		return err
	}
	for _, id := range ids {
		record, err := s.store.Inspect(id)
		if err != nil {
			return err
		}
		if record.Active == nil {
			continue
		}
		phase := string(record.Active.Phase)
		if _, known := counts[phase]; !known {
			phase = "UNKNOWN"
		}
		counts[phase]++
	}
	entries, err := os.ReadDir(reaperRoot)
	if err != nil {
		return err
	}
	var pending, oldest float64
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		info, err := os.Stat(filepath.Join(reaperRoot, entry.Name(), reaperRecordName))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		pending++
		timestamp := float64(info.ModTime().Unix())
		if oldest == 0 || timestamp < oldest {
			oldest = timestamp
		}
	}
	for phase, count := range counts {
		s.metrics.SetLeaseCount(phase, count)
	}
	s.metrics.SetReaper(pending, oldest)
	return nil
}

func (s *Service) lockOperation(ctx context.Context, sandboxID string) error {
	started := time.Now()
	err := s.operations.Lock(ctx, sandboxID)
	s.metrics.ObserveLockWait("sandbox_operation", started)
	return err
}
