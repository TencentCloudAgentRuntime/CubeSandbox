// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package state

import "testing"

func TestLeaseIDForPrepareMatchesCrossLanguageVector(t *testing.T) {
	request := PrepareRequest{
		SandboxID:      "sandbox-a",
		Generation:     1,
		IdempotencyKey: "4052897b8ee1b4cf29095801bb054adb0ee3aad39fedc00a32c83d0c8f35c013",
	}
	const want = "98f6f3bda4b778a3c2667ad283522c898878638fee09660857c500ff1b3060b8"
	if got := ExpectedLeaseIDForPrepare(request); got != want {
		t.Fatalf("lease ID=%q, want %q", got, want)
	}
}
