// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

use crate::common::utils::{ADDRESS_FILE, SHIM_PID_FILE};
use crate::service::{runtime_resource, tools};
use crate::{common::utils, service::task_srv::TaskService};
use async_trait::async_trait;
use containerd_shim::{
    asynchronous::{publisher::RemotePublisher, spawn, ExitSignal, Shim},
    protos::api,
    Config, Error, Flags, StartOpts,
};

use nix::sys::signal::Signal;
use std::{fs, io::Read, sync::Arc};

#[derive(Clone)]
pub struct Service {
    id: String,
    ns: String,
    exit: Arc<ExitSignal>,
    debug: bool,
}

#[async_trait]
impl Shim for Service {
    type T = TaskService;

    async fn new(_runtime: &str, flags: &Flags, _config: &mut Config) -> Self {
        Service {
            id: flags.id.clone(),
            ns: flags.namespace.clone(),
            exit: Arc::new(ExitSignal::default()),
            debug: flags.debug,
        }
    }

    async fn start_shim(&mut self, opts: StartOpts) -> Result<String, Error> {
        // containerd 2.3 writes BootstrapParams to the start action's stdin, but
        // containerd-shim 0.9.0's start path never consumes that request. Drain
        // it before using the library's legacy address-response path; flags and
        // environment still carry the inputs needed to spawn the server. Remove
        // this adapter when CubeShim moves to a bootstrap-aware shim library.
        consume_start_input(std::io::stdin().lock()).map_err(|err| Error::IoError {
            context: "read containerd bootstrap input".to_string(),
            err,
        })?;
        let grouping = opts.id.clone();
        let address: String = spawn(opts, &grouping, Vec::new()).await?;
        fs::write(ADDRESS_FILE, address.as_bytes()).map_err(|e| Error::IoError {
            context: "write address file failed".to_string(),
            err: e,
        })?;

        /*
        fs::write(SHIM_PID_FILE, format!("{}", "0")).map_err(|e| Error::IoError {
            context: "write pid file failed".to_string(),
            err: e,
        })?;
        */
        Ok(address)
    }

    async fn delete_shim(&mut self) -> Result<api::DeleteResponse, Error> {
        //return Ok(api::DeleteResponse::new());
        //kill shim
        if let Ok(shim_pid) = tools::read_number_from_file(SHIM_PID_FILE) {
            if let Ok(()) = tools::signal(shim_pid, None) {
                let _ = tools::signal(shim_pid, Some(Signal::SIGKILL));
            }
        }

        runtime_resource::release_persisted()
            .await
            .map_err(|error| Error::Other(format!("release persisted RuntimeResource: {error}")))?;

        if let Ok(sk_file) = tools::read_address(ADDRESS_FILE) {
            let _ = fs::remove_file(sk_file.as_str());
        }

        utils::Utils::clean_sandbox_resource(&self.id).map_err(Error::Other)?;

        Ok(api::DeleteResponse::new())
    }

    async fn wait(&mut self) {
        self.exit.wait().await;
    }

    async fn create_task_service(&self, publisher: RemotePublisher) -> Self::T {
        TaskService::new(
            self.id.clone(),
            self.ns.clone(),
            self.debug,
            self.exit.clone(),
            publisher,
        )
        .await
    }
}

fn consume_start_input(mut input: impl Read) -> std::io::Result<usize> {
    let mut data = Vec::new();
    input.read_to_end(&mut data)
}

#[cfg(test)]
mod tests {
    use super::consume_start_input;
    use std::io::Cursor;

    #[test]
    fn consume_start_input_drains_bootstrap_payload() {
        let payload = b"containerd-2.3-bootstrap";
        let mut input = Cursor::new(payload);

        let consumed = consume_start_input(&mut input).unwrap();

        assert_eq!(consumed, payload.len());
        assert_eq!(input.position(), payload.len() as u64);
    }
}
