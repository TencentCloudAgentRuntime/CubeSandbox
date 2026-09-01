// Copyright (c) 2019 Ant Financial
//
// SPDX-License-Identifier: Apache-2.0
//

// looks like we can use caps to manipulate capabilities
// conveniently, use caps to do it directly.. maybe

use anyhow::{anyhow, Result};
use caps::{self, runtime, CapSet, Capability, CapsHashSet};
use oci::LinuxCapabilities;
use std::os::unix::io::RawFd;
use std::str::FromStr;

fn to_capshashset(field: &str, capabilities: &[String]) -> Result<CapsHashSet> {
    let mut r = CapsHashSet::new();

    for capability in capabilities {
        let parsed = Capability::from_str(capability)
            .map_err(|_| anyhow!("invalid Linux capability {capability} in OCI {field} set"))?;
        r.insert(parsed);
    }

    Ok(r)
}

struct CapabilitySets {
    bounding: CapsHashSet,
    effective: CapsHashSet,
    permitted: CapsHashSet,
    inheritable: CapsHashSet,
    ambient: CapsHashSet,
}

fn parse_capability_sets(capabilities: &LinuxCapabilities) -> Result<CapabilitySets> {
    Ok(CapabilitySets {
        bounding: to_capshashset("bounding", capabilities.bounding.as_ref())?,
        effective: to_capshashset("effective", capabilities.effective.as_ref())?,
        permitted: to_capshashset("permitted", capabilities.permitted.as_ref())?,
        inheritable: to_capshashset("inheritable", capabilities.inheritable.as_ref())?,
        ambient: to_capshashset("ambient", capabilities.ambient.as_ref())?,
    })
}

pub fn get_all_caps() -> CapsHashSet {
    let mut caps_set =
        runtime::procfs_all_supported(None).unwrap_or_else(|_| runtime::thread_all_supported());
    if caps_set.is_empty() {
        caps_set = caps::all();
    }
    caps_set
}

pub fn reset_effective() -> Result<()> {
    let all = get_all_caps();
    caps::set(None, CapSet::Effective, &all).map_err(|e| anyhow!(e.to_string()))?;
    Ok(())
}

pub fn drop_privileges(_cfd_log: RawFd, caps: &LinuxCapabilities) -> Result<()> {
    let all = get_all_caps();
    // Parse every OCI set before changing the process so an invalid name
    // cannot be silently ignored or leave a partially modified process.
    let parsed = parse_capability_sets(caps)?;

    for c in all.difference(&parsed.bounding) {
        caps::drop(None, CapSet::Bounding, *c).map_err(|e| anyhow!(e.to_string()))?;
    }

    caps::set(None, CapSet::Effective, &parsed.effective).map_err(|e| anyhow!(e.to_string()))?;
    caps::set(None, CapSet::Permitted, &parsed.permitted).map_err(|e| anyhow!(e.to_string()))?;
    caps::set(None, CapSet::Inheritable, &parsed.inheritable)
        .map_err(|e| anyhow!(e.to_string()))?;
    caps::set(None, CapSet::Ambient, &parsed.ambient).map_err(|e| anyhow!(e.to_string()))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_empty_capability_set() {
        assert!(to_capshashset("effective", &[]).unwrap().is_empty());
    }

    #[test]
    fn parses_selective_and_highest_linux_66_capabilities() {
        let parsed = to_capshashset(
            "bounding",
            &[
                "CAP_NET_BIND_SERVICE".to_string(),
                "CAP_NET_RAW".to_string(),
                "CAP_CHECKPOINT_RESTORE".to_string(),
            ],
        )
        .unwrap();

        assert_eq!(parsed.len(), 3);
        assert!(parsed.contains(&Capability::CAP_NET_BIND_SERVICE));
        assert!(parsed.contains(&Capability::CAP_NET_RAW));
        assert!(parsed.contains(&Capability::CAP_CHECKPOINT_RESTORE));
    }

    #[test]
    fn rejects_unknown_capability_in_every_set_before_application() {
        for field in [
            "bounding",
            "effective",
            "permitted",
            "inheritable",
            "ambient",
        ] {
            let mut capabilities = LinuxCapabilities::default();
            match field {
                "bounding" => capabilities.bounding = vec!["CAP_NOT_A_REAL_CAPABILITY".into()],
                "effective" => capabilities.effective = vec!["CAP_NOT_A_REAL_CAPABILITY".into()],
                "permitted" => capabilities.permitted = vec!["CAP_NOT_A_REAL_CAPABILITY".into()],
                "inheritable" => {
                    capabilities.inheritable = vec!["CAP_NOT_A_REAL_CAPABILITY".into()]
                }
                "ambient" => capabilities.ambient = vec!["CAP_NOT_A_REAL_CAPABILITY".into()],
                _ => unreachable!(),
            }

            let error = parse_capability_sets(&capabilities)
                .err()
                .expect("unknown capability must be rejected");
            assert_eq!(
                error.to_string(),
                format!("invalid Linux capability CAP_NOT_A_REAL_CAPABILITY in OCI {field} set")
            );
        }
    }
}
