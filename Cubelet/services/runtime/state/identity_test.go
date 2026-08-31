// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package state

import "testing"

func TestCubeShimOperationIdentityVectors(t *testing.T) {
	const prepareKey = "4052897b8ee1b4cf29095801bb054adb0ee3aad39fedc00a32c83d0c8f35c013"
	if got := ExpectedPrepareKey("sandbox-a", 1); got != prepareKey {
		t.Fatalf("Prepare key=%q, want %q", got, prepareKey)
	}
	const leaseID = "98f6f3bda4b778a3c2667ad283522c898878638fee09660857c500ff1b3060b8"
	if got := ExpectedLeaseIDForCubeShim("sandbox-a", 1); got != leaseID {
		t.Fatalf("lease ID=%q, want %q", got, leaseID)
	}
	const releaseKey = "6b690a98c53ebf31c970977f96208e1541c319c1269b2b427a4709b753cbd9b2"
	if got := ExpectedReleaseKey("sandbox-a", 1, leaseID); got != releaseKey {
		t.Fatalf("Release key=%q, want %q", got, releaseKey)
	}
}
