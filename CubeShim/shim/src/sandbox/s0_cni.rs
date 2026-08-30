// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

//! S0-only adapter for consuming a CNI-created Pod network namespace.
//!
//! The probe follows Kata Containers' tcfilter model: the probe script creates
//! a TAP beside the CNI interface and installs bidirectional tc redirects. This
//! module only opens that TAP from the Pod netns and donates its FD to the
//! embedded hypervisor. S1 must source the netns path from SandboxService and
//! move this lifecycle behind the Cubelet network adapter.

use std::fs::File;
use std::os::fd::AsRawFd;
use std::path::Path;
use std::thread;

use net_util::Tap;
use oci_spec::runtime::Spec;

use crate::common::CResult;
use crate::hypervisor::config::VmConfig;

pub const ANNO_S0_CNI_NETNS: &str = "io.containerd.cube.s0.cni-netns";

pub struct PreparedNetwork {
    _taps: Vec<Tap>,
}

impl PreparedNetwork {
    pub fn requested(spec: &Spec) -> bool {
        annotation(spec, ANNO_S0_CNI_NETNS).is_some()
    }

    pub fn prepare(spec: &Spec, vm: &mut VmConfig) -> CResult<Option<Self>> {
        let Some(netns_path) = annotation(spec, ANNO_S0_CNI_NETNS) else {
            return Ok(None);
        };
        if !Path::new(netns_path).is_absolute() {
            return Err(format!("{} must be an absolute path", ANNO_S0_CNI_NETNS));
        }

        let nets = vm
            .nets
            .as_mut()
            .ok_or_else(|| format!("{} requires a VM network", ANNO_S0_CNI_NETNS))?;
        if nets.is_empty() {
            return Err(format!("{} requires a VM network", ANNO_S0_CNI_NETNS));
        }

        let tap_names = nets
            .iter()
            .map(|net| {
                net.tap
                    .as_ref()
                    .filter(|name| !name.is_empty())
                    .cloned()
                    .ok_or_else(|| {
                        format!("{} requires one TAP name per VM network", ANNO_S0_CNI_NETNS)
                    })
            })
            .collect::<CResult<Vec<_>>>()?;

        let taps = open_taps_in_netns(netns_path.to_string(), tap_names)?;
        if taps.len() != nets.len() {
            return Err("S0 CNI TAP count does not match VM network count".to_string());
        }

        for (net, tap) in nets.iter_mut().zip(taps.iter()) {
            net.tap = None;
            net.fds = Some(vec![tap.as_raw_fd()]);
            net.fds_from_other_netns = true;
            net.num_queues = 2;
        }

        Ok(Some(Self { _taps: taps }))
    }
}

fn annotation<'a>(spec: &'a Spec, key: &str) -> Option<&'a str> {
    spec.annotations()
        .as_ref()
        .and_then(|annotations| annotations.get(key))
        .map(String::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn open_taps_in_netns(netns_path: String, tap_names: Vec<String>) -> CResult<Vec<Tap>> {
    thread::Builder::new()
        .name("cube-s0-cni-netns".to_string())
        .spawn(move || {
            let netns = File::open(&netns_path)
                .map_err(|error| format!("open CNI netns {} failed: {}", netns_path, error))?;
            let result = unsafe { libc::setns(netns.as_raw_fd(), libc::CLONE_NEWNET) };
            if result < 0 {
                return Err(format!(
                    "enter CNI netns {} failed: {}",
                    netns_path,
                    std::io::Error::last_os_error()
                ));
            }

            tap_names
                .iter()
                .map(|name| {
                    let tap = Tap::open_named(name, 1, None)
                        .map_err(|error| format!("open CNI TAP {} failed: {}", name, error))?;
                    tap.prepare_for_cross_netns().map_err(|error| {
                        format!(
                            "prepare CNI TAP {} for cross-netns use failed: {}",
                            name, error
                        )
                    })?;
                    Ok(tap)
                })
                .collect()
        })
        .map_err(|error| format!("start CNI netns worker failed: {}", error))?
        .join()
        .map_err(|_| "CNI netns worker panicked".to_string())?
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use oci_spec::runtime::SpecBuilder;

    use super::*;

    fn spec_with_annotation(value: &str) -> Spec {
        SpecBuilder::default()
            .annotations(HashMap::from([(
                ANNO_S0_CNI_NETNS.to_string(),
                value.to_string(),
            )]))
            .build()
            .unwrap()
    }

    #[test]
    fn feature_gate_is_opt_in() {
        assert_eq!(annotation(&Spec::default(), ANNO_S0_CNI_NETNS), None);
        assert_eq!(
            annotation(&spec_with_annotation("/proc/123/ns/net"), ANNO_S0_CNI_NETNS),
            Some("/proc/123/ns/net")
        );
    }

    #[test]
    fn relative_netns_path_is_rejected_before_io() {
        let mut vm = VmConfig::new("/tmp/os", "/tmp/agent");
        let error = PreparedNetwork::prepare(&spec_with_annotation("relative/netns"), &mut vm)
            .err()
            .unwrap();
        assert!(error.contains("absolute path"));
    }

    #[test]
    fn gated_network_requires_a_tap() {
        let mut vm = VmConfig::new("/tmp/os", "/tmp/agent");
        let error = PreparedNetwork::prepare(&spec_with_annotation("/proc/123/ns/net"), &mut vm)
            .err()
            .unwrap();
        assert!(error.contains("requires a VM network"));
    }
}
