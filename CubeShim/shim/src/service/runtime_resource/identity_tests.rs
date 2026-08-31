// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use super::{lease_id_for_prepare, prepare_key, release_key, PreparedSandbox};

#[test]
fn operation_identity_matches_go_vectors() {
    let prepare = prepare_key("sandbox-a", 1);
    assert_eq!(
        prepare,
        "4052897b8ee1b4cf29095801bb054adb0ee3aad39fedc00a32c83d0c8f35c013"
    );
    let lease = lease_id_for_prepare("sandbox-a", 1, &prepare);
    assert_eq!(
        lease,
        "98f6f3bda4b778a3c2667ad283522c898878638fee09660857c500ff1b3060b8"
    );
    assert_eq!(
        release_key(&PreparedSandbox {
            sandbox_id: "sandbox-a".to_string(),
            generation: 1,
            lease_id: lease,
            ..Default::default()
        }),
        "6b690a98c53ebf31c970977f96208e1541c319c1269b2b427a4709b753cbd9b2"
    );
}
