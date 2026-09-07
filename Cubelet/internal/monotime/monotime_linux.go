// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//go:build linux

// Package monotime exposes Linux CLOCK_MONOTONIC for performance correlation
// across Cubelet, CubeShim, and the per-Pod VMM worker.
package monotime

import "golang.org/x/sys/unix"

// Micros returns CLOCK_MONOTONIC in microseconds. A zero value means the
// underlying clock read failed and must not be used as an ordering point.
func Micros() int64 {
	var value unix.Timespec
	if err := unix.ClockGettime(unix.CLOCK_MONOTONIC, &value); err != nil {
		return 0
	}
	return value.Sec*1_000_000 + value.Nsec/1_000
}
