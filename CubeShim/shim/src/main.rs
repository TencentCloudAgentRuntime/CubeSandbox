// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

use containerd_shim::parse;
use containerd_shim_cube_rs::common;
use containerd_shim_cube_rs::service;
use containerd_shim_protos::{
    protobuf::{well_known_types::any::Any, Message, MessageField},
    types::introspection::{RuntimeInfo, RuntimeVersion},
};

use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Read, Write};
use tokio::runtime::Builder;
//const SHIM_VERSION: &str = env!("GIT_COMMIT_INFO");
//const CH_VERSION: &str = env!("CH_GIT_COMMIT_INFO");
fn main() {
    if let Err(error) = service::early_server_gate() {
        eprintln!("CubeShim early server gate failed: {error}");
        unsafe { libc::exit(1) };
    }
    let mut thread_num = 1;
    let os_args: Vec<_> = std::env::args_os().collect();
    if is_version_request(&os_args[1..]) {
        print_version();
        return;
    }
    if is_runtime_info_request(&os_args[1..]) {
        if let Err(err) = handle_runtime_info_request() {
            eprintln!("handle runtime info request failed: {err}");
            unsafe {
                libc::exit(1);
            }
        }
        return;
    }
    let flags = parse(&os_args[1..]).expect("Invalid params");
    if flags.version {
        print_version();
        return;
    }
    if flags.action.is_empty() {
        thread_num = 2;
        set_process();
    }

    let runtime = Builder::new_multi_thread()
        .worker_threads(thread_num)
        .enable_all()
        .build()
        .unwrap();
    if let Err(error) = runtime.block_on(service::run("io.containerd.cube.rs", flags)) {
        eprintln!("io.containerd.cube.rs: {error:?}");
        unsafe { libc::exit(1) };
    }
}

fn is_version_request(args: &[OsString]) -> bool {
    args.iter().any(|arg| {
        arg.to_str()
            .map(|value| matches!(value, "-v" | "-version" | "--version"))
            .unwrap_or(false)
    })
}

fn print_version() {
    println!(
        "containerd-shim-cube-rs {} ({}) built at {}",
        common::SHIM_VERSION,
        common::SHIM_COMMIT,
        common::SHIM_BUILD_TIME
    );
}

fn is_runtime_info_request(args: &[OsString]) -> bool {
    args.iter().any(|arg| {
        arg.to_str()
            .map(|value| matches!(value, "-info" | "--info"))
            .unwrap_or(false)
    })
}

fn handle_runtime_info_request() -> Result<(), Box<dyn std::error::Error>> {
    // containerd writes runtime options to stdin and expects a RuntimeInfo
    // protobuf on stdout. Cube does not consume the options today.
    let mut _options = Vec::new();
    io::stdin().lock().read_to_end(&mut _options)?;
    let encoded = runtime_info().write_to_bytes()?;
    let mut stdout = io::stdout().lock();
    stdout.write_all(&encoded)?;
    stdout.flush()?;
    Ok(())
}

fn runtime_info() -> RuntimeInfo {
    RuntimeInfo {
        name: "io.containerd.cube.rs".to_string(),
        version: MessageField::some(RuntimeVersion {
            version: common::SHIM_VERSION.to_string(),
            revision: common::SHIM_COMMIT.to_string(),
            ..Default::default()
        }),
        features: MessageField::some(Any {
            type_url: "types.containerd.io/opencontainers/runtime-spec/1/features/Features"
                .to_string(),
            value: br#"{"ociVersionMin":"1.0.0","ociVersionMax":"1.2.0","mountOptions":["rro"]}"#
                .to_vec(),
            ..Default::default()
        }),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_info_advertises_recursive_read_only_mounts() {
        let encoded = runtime_info().write_to_bytes().unwrap();
        let decoded = RuntimeInfo::parse_from_bytes(&encoded).unwrap();
        let features = decoded.features.as_ref().unwrap();
        assert_eq!(
            features.type_url,
            "types.containerd.io/opencontainers/runtime-spec/1/features/Features"
        );
        let json: serde_json::Value = serde_json::from_slice(&features.value).unwrap();
        assert_eq!(json["mountOptions"], serde_json::json!(["rro"]));
    }
}

fn set_process() {
    //core dump filter
    let mut filter_file = File::options()
        .write(true)
        .open("/proc/self/coredump_filter")
        .expect("open coredump_filter failed");
    filter_file
        .write_all("0x33".as_bytes())
        .expect("write coredump_filter failed");

    //setrlimit(Resource::CORE, coredump_limit, coredump_limit).expect("set coredump limit failed");
    let coredump_limit = 1024 * 1024 * 1024 * 2;
    let core = libc::rlimit {
        rlim_cur: coredump_limit,
        rlim_max: coredump_limit,
    };
    unsafe {
        if libc::setrlimit(libc::RLIMIT_CORE, &core) < 0 {
            eprintln!("set rlimit core failed:{}", io::Error::last_os_error());
            libc::exit(1);
        }

        let mut nofile = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };

        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut nofile) < 0 {
            eprintln!("get rlimit nofile failed:{}", io::Error::last_os_error());
            libc::exit(1);
        }

        if nofile.rlim_cur < nofile.rlim_max {
            nofile.rlim_cur = nofile.rlim_max;
            if libc::setrlimit(libc::RLIMIT_NOFILE, &nofile) < 0 {
                eprintln!("set rlimit nofile failed:{}", io::Error::last_os_error());
                libc::exit(1);
            }
        }

        // Create dummy socket and dup it to large fd, so that we could trigger
        // expand_files in kernel. And this tricky work will avoid later multi
        // thread try to invoke expand_files at same time, there will be lock
        // contention in expand_files.
        // SAFETY: FFI call
        let dummy = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
        if dummy > 0 {
            libc::dup2(dummy, 512);
        }
    }
}
