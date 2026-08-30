// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package runtimeresource

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	runtimeservice "github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime"
	"github.com/tencentcloud/CubeSandbox/Cubelet/services/runtime/state"
)

func TestAdapterWALRecoveryCleansEveryVisiblePrepareStage(t *testing.T) {
	for _, failedStage := range []prepareStage{stageSharedRoot, stagePrepared} {
		t.Run(string(failedStage), func(t *testing.T) {
			ctx := context.Background()
			root := t.TempDir()
			network := new(fakeNetwork)
			assets := testAssets(t)
			adapterState := filepath.Join(root, "adapter")
			adapter, err := newAdapter(adapterState, assets, network)
			if err != nil {
				t.Fatal(err)
			}
			adapter.persistHook = func(stage prepareStage, _ *diskRecord) error {
				if stage == failedStage {
					return fmt.Errorf("injected crash at %s", stage)
				}
				return nil
			}
			store, err := state.Open(filepath.Join(root, "lifecycle"), func() (string, error) { return "wal-value-" + string(failedStage), nil })
			if err != nil {
				t.Fatal(err)
			}
			lease, err := store.Prepare(state.PrepareRequest{
				SandboxID: "sandbox-a", Generation: 3,
				IdempotencyKey: "prepare-" + string(failedStage), PayloadDigest: "payload-" + string(failedStage),
			})
			if err != nil {
				t.Fatal(err)
			}
			_, err = adapter.Prepare(ctx, adapterRequest(), lease.Lease)
			if err == nil || !strings.Contains(err.Error(), "injected crash") {
				t.Fatalf("prepare error=%v", err)
			}
			intent, err := adapter.load("sandbox-a")
			if err != nil {
				t.Fatalf("durable adapter intent: %v", err)
			}
			sharedRoot := intent.Assets.GetSharedRoot()
			if _, err := os.Stat(sharedRoot); err != nil {
				t.Fatalf("expected visible shared-root side effect: %v", err)
			}

			restarted, err := newAdapter(adapterState, assets, network)
			if err != nil {
				t.Fatal(err)
			}
			service, _, err := runtimeservice.NewService(store, restarted, filepath.Join(root, "fd.sock"))
			if err != nil {
				t.Fatal(err)
			}
			if err := service.Recover(ctx); err != nil {
				t.Fatal(err)
			}
			record, err := store.Inspect("sandbox-a")
			if err != nil || record.Active != nil {
				t.Fatalf("lifecycle record=%+v err=%v", record, err)
			}
			if _, err := restarted.load("sandbox-a"); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("adapter intent remains: %v", err)
			}
			if _, err := os.Stat(sharedRoot); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("shared root remains: %v", err)
			}
			if network.releaseCalls != 1 {
				t.Fatalf("network release calls=%d, want 1", network.releaseCalls)
			}
		})
	}
}
