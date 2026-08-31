// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package state

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// ExpectedPrepareKey derives the deterministic CubeShim Prepare operation key.
// It lets an exact cleanup identity be verified even when Release reaches
// Cubelet before the corresponding Prepare request.
func ExpectedPrepareKey(sandboxID string, generation uint64) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("cube-runtime-prepare-v1:%s:%d", sandboxID, generation)))
	return hex.EncodeToString(sum[:])
}

// ExpectedLeaseIDForCubeShim derives the lease CubeShim writes to its cleanup
// record before issuing Prepare.
func ExpectedLeaseIDForCubeShim(sandboxID string, generation uint64) string {
	return ExpectedLeaseIDForPrepare(PrepareRequest{
		SandboxID: sandboxID, Generation: generation,
		IdempotencyKey: ExpectedPrepareKey(sandboxID, generation),
	})
}
