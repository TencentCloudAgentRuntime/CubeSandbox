// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

fn main() {
    if let Err(error) = containerd_shim_cube_rs::hypervisor::worker::run_from_env() {
        eprintln!("cube-vmm-worker: {error}");
        std::process::exit(1);
    }
}
