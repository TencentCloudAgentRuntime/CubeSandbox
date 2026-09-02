// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

mod bootstrap;
mod host_cgroup;
mod runner;
mod runtime_resource;
mod sandbox_srv;
mod srv;
mod standard_rootfs;
mod task_srv;
mod tools;
mod update_ext;
pub use runner::run;
pub use srv::Service;

/// Run before argument parsing or Tokio creates worker threads.  A server
/// spawned by the bootstrap helper must publish its immutable identity and
/// pass the inherited placement gate before it can bind the shim socket.
pub fn early_server_gate() -> Result<(), String> {
    host_cgroup::early_server_gate()
}
