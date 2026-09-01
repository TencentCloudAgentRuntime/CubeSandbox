// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use protobuf::Message;
use protoc::oci::LinuxResources;

// LinuxResources.resourceV2 (tag 8), containing version=1, mediaType="m"
// and value="{}". The Agent protocols test consumes the identical bytes.
const RESOURCE_V2_WIRE_GOLDEN: &[u8] = &[
    0x42, 0x09, 0x08, 0x01, 0x12, 0x01, 0x6d, 0x1a, 0x02, 0x7b, 0x7d,
];

#[test]
fn resources_v2_wire_tag_matches_agent_golden() {
    let resources = LinuxResources::parse_from_bytes(RESOURCE_V2_WIRE_GOLDEN).unwrap();
    assert!(resources.has_resourceV2());
    assert_eq!(resources.get_resourceV2().get_version(), 1);
    assert_eq!(resources.get_resourceV2().get_mediaType(), "m");
    assert_eq!(resources.get_resourceV2().get_value(), b"{}");
    assert_eq!(resources.write_to_bytes().unwrap(), RESOURCE_V2_WIRE_GOLDEN);
}
