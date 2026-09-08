// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package monotime

import (
	"context"
	"testing"
)

func TestDisabledTraceBufferRetainsNothing(t *testing.T) {
	t.Setenv("CUBE_PERF_TRACE", "")
	buffer := NewTraceBuffer()
	if buffer.Enabled() {
		t.Fatal("disabled buffer reported enabled")
	}
	buffer.Addf("should not be retained: %s", "value")
	if len(buffer.records) != 0 {
		t.Fatalf("disabled buffer retained %d records", len(buffer.records))
	}
}

func TestTraceBufferCopiesArgumentsAndIsSingleUse(t *testing.T) {
	t.Setenv("CUBE_PERF_TRACE", "1")
	buffer := NewTraceBuffer()
	if !buffer.Enabled() {
		t.Fatal("enabled buffer reported disabled")
	}
	buffer.Addf("value=%s", "fixed")
	if len(buffer.records) != 1 || len(buffer.records[0].args) != 1 || buffer.records[0].args[0] != "fixed" {
		t.Fatalf("unexpected buffered record: %#v", buffer.records)
	}
	records := buffer.records
	buffer.records = nil
	if len(records) != 1 || len(buffer.records) != 0 {
		t.Fatal("buffer was not consumable exactly once")
	}
}

func TestTraceBufferContextRoundTrip(t *testing.T) {
	buffer := &TraceBuffer{}
	ctx := WithTraceBuffer(context.Background(), buffer)
	if got := TraceBufferFromContext(ctx); got != buffer {
		t.Fatalf("context returned %p, want %p", got, buffer)
	}
}
