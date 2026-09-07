// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//go:build linux

// Package monotime exposes Linux CLOCK_MONOTONIC for performance correlation
// across Cubelet, CubeShim, and the per-Pod VMM worker.
package monotime

import (
	"os"

	"golang.org/x/sys/unix"
)

// TraceEnabled reports whether opt-in startup performance tracing is enabled.
// Callers should check this before collecting timestamps or formatting logs so
// the default runtime path has negligible observability overhead.
func TraceEnabled() bool {
	return os.Getenv("CUBE_PERF_TRACE") == "1"
}

// Micros returns CLOCK_MONOTONIC in microseconds. A zero value means the
// underlying clock read failed and must not be used as an ordering point.
func Micros() int64 {
	var value unix.Timespec
	if err := unix.ClockGettime(unix.CLOCK_MONOTONIC, &value); err != nil {
		return 0
	}
	return value.Sec*1_000_000 + value.Nsec/1_000
}
