// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use protobuf::Message;
use protocols::oci::LinuxResources;

// Must remain byte-identical to CubeShim/protoc/tests/resources_v2.rs.
const RESOURCE_V2_WIRE_GOLDEN: &[u8] = &[
    0x42, 0x09, 0x08, 0x01, 0x12, 0x01, 0x6d, 0x1a, 0x02, 0x7b, 0x7d,
];

#[test]
fn resources_v2_wire_tag_matches_shim_golden() {
    let resources = LinuxResources::parse_from_bytes(RESOURCE_V2_WIRE_GOLDEN).unwrap();
    assert!(resources.has_ResourceV2());
    assert_eq!(resources.ResourceV2().Version(), 1);
    assert_eq!(resources.ResourceV2().MediaType(), "m");
    assert_eq!(resources.ResourceV2().Value(), b"{}");
    assert_eq!(resources.write_to_bytes().unwrap(), RESOURCE_V2_WIRE_GOLDEN);
}
