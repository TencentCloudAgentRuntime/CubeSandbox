// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package monotime

import "testing"

func TestMicrosIsAvailableAndMonotonic(t *testing.T) {
	first := Micros()
	second := Micros()
	if first <= 0 {
		t.Fatalf("CLOCK_MONOTONIC is unavailable: %d", first)
	}
	if second < first {
		t.Fatalf("CLOCK_MONOTONIC moved backwards: first=%d second=%d", first, second)
	}
}

func TestTraceEnabledRequiresExactOptIn(t *testing.T) {
	t.Setenv("CUBE_PERF_TRACE", "")
	if TraceEnabled() {
		t.Fatal("trace unexpectedly enabled for an empty value")
	}

	t.Setenv("CUBE_PERF_TRACE", "true")
	if TraceEnabled() {
		t.Fatal("trace unexpectedly enabled for a non-canonical value")
	}

	t.Setenv("CUBE_PERF_TRACE", "1")
	if !TraceEnabled() {
		t.Fatal("trace was not enabled for CUBE_PERF_TRACE=1")
	}
}
