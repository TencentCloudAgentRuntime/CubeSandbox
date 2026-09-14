// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

// Package tracebridge shares request trace context across local Cube CRI
// processes without requiring containerd patches.
package tracebridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
)

const (
	DefaultDir = "/run/cube-cri/trace-context"
	envDir     = "CUBE_CRI_TRACE_BRIDGE_DIR"
)

var safeKey = regexp.MustCompile(`[^A-Za-z0-9_.-]`)

type record struct {
	Carrier   map[string]string `json:"carrier"`
	ExpiresAt time.Time         `json:"expiresAt"`
}

// StoreContext persists the W3C trace context for podUID.
func StoreContext(ctx context.Context, podUID string, ttl time.Duration) error {
	return StoreContextKey(ctx, podUID, ttl)
}

// StoreContextKey persists the W3C trace context for a local bridge key.
func StoreContextKey(ctx context.Context, key string, ttl time.Duration) error {
	key = strings.TrimSpace(key)
	if key == "" {
		return nil
	}
	if ttl <= 0 {
		ttl = 10 * time.Minute
	}
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	if carrier.Get("traceparent") == "" {
		return nil
	}
	rec := record{Carrier: map[string]string(carrier), ExpiresAt: time.Now().Add(ttl).UTC()}
	data, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	dir := Dir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := PathForKey(key)
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ContextForPod returns ctx with a remote parent extracted from the local
// bridge store. Expired or missing records leave ctx unchanged.
func ContextForPod(ctx context.Context, podUID string) context.Context {
	return ContextForKey(ctx, podUID)
}

// ContextForKey returns ctx with a remote parent extracted from the local
// bridge store. Expired or missing records leave ctx unchanged.
func ContextForKey(ctx context.Context, key string) context.Context {
	key = strings.TrimSpace(key)
	if key == "" {
		return ctx
	}
	path := PathForKey(key)
	data, err := os.ReadFile(path)
	if err != nil {
		return ctx
	}
	var rec record
	if err := json.Unmarshal(data, &rec); err != nil {
		return ctx
	}
	if time.Now().After(rec.ExpiresAt) {
		_ = os.Remove(path)
		return ctx
	}
	return otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier(rec.Carrier))
}

// RemoveContext deletes any bridge context for podUID.
func RemoveContext(podUID string) error {
	podUID = strings.TrimSpace(podUID)
	if podUID == "" {
		return nil
	}
	err := os.Remove(PathForPodUID(podUID))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func Dir() string {
	if dir := strings.TrimSpace(os.Getenv(envDir)); dir != "" {
		return dir
	}
	return DefaultDir
}

func PathForPodUID(podUID string) string {
	return PathForKey(podUID)
}

func PathForKey(key string) string {
	name := safeKey.ReplaceAllString(strings.TrimSpace(key), "_")
	return filepath.Join(Dir(), name+".json")
}
