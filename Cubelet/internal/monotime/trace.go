// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package monotime

import (
	"context"
	"sync"

	CubeLog "github.com/tencentcloud/CubeSandbox/cubelog"
)

// TraceBuffer defers performance-log formatting and I/O until the owner has
// released lifecycle locks. It is request-scoped: child layers only append
// immutable scalar arguments, and the outer RPC flushes after its keyed lock
// has been released.
type TraceBuffer struct {
	enabled bool
	mu      sync.Mutex
	records []traceRecord
}

type traceRecord struct {
	format string
	args   []any
}

type traceContextKey struct{}

// NewTraceBuffer returns a request-local buffer. Disabled buffers retain no
// records, keeping the normal path to one predictable branch per trace point.
func NewTraceBuffer() *TraceBuffer {
	return &TraceBuffer{enabled: TraceEnabled()}
}

// WithTraceBuffer makes a request-owned trace buffer available to adapter and
// network layers without changing their public interfaces.
func WithTraceBuffer(ctx context.Context, buffer *TraceBuffer) context.Context {
	if buffer == nil {
		return ctx
	}
	return context.WithValue(ctx, traceContextKey{}, buffer)
}

// TraceBufferFromContext returns the request-owned buffer, if any.
func TraceBufferFromContext(ctx context.Context) *TraceBuffer {
	if ctx == nil {
		return nil
	}
	buffer, _ := ctx.Value(traceContextKey{}).(*TraceBuffer)
	return buffer
}

// Addf records an unformatted message. Callers must pass scalar values rather
// than mutable pointers so the values remain stable until Flush.
func (b *TraceBuffer) Addf(format string, args ...any) {
	if b == nil || !b.enabled {
		return
	}
	copied := append([]any(nil), args...)
	b.mu.Lock()
	b.records = append(b.records, traceRecord{format: format, args: copied})
	b.mu.Unlock()
}

// Flush formats and writes all records after the request's lifecycle locks
// have been released. A buffer is single-use; repeated Flush calls are safe.
func (b *TraceBuffer) Flush() {
	if b == nil || !b.enabled {
		return
	}
	b.mu.Lock()
	records := b.records
	b.records = nil
	b.mu.Unlock()
	logger := CubeLog.WithContext(context.Background())
	for _, record := range records {
		logger.Infof(record.format, record.args...)
	}
}
