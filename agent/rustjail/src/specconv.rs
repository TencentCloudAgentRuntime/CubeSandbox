// Copyright (c) 2019 Ant Financial
//
// SPDX-License-Identifier: Apache-2.0
//

use oci::Spec;

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
pub struct ResourceV2Config {
    pub version: u32,
    pub canonical: Vec<u8>,
}

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
pub struct CreateOpts {
    pub cgroup_name: String,
    pub use_systemd_cgroup: bool,
    pub no_pivot_root: bool,
    pub no_new_keyring: bool,
    pub spec: Option<Spec>,
    pub rootless_euid: bool,
    pub rootless_cgroup: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resources_v2: Option<ResourceV2Config>,
}
