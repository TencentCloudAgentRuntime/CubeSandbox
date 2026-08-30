// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use containerd_shim::asynchronous::{publisher::RemotePublisher, Shim};
use containerd_shim::protos::protobuf::Message;
use containerd_shim::protos::{
    sandbox_async::create_sandbox, shim_async::create_task, ttrpc::r#async::Server,
};
use containerd_shim::{Config, Error, Flags};
use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use tokio::io;
use tokio::process::Command;

use crate::common::utils::ADDRESS_FILE;
use crate::service::bootstrap::{BootstrapParams, BootstrapResult};
use crate::service::sandbox_srv::SandboxService;
use crate::service::srv::Service;

const DEFAULT_SOCKET_DIR: &str = "/run/containerd/s";
const TTRPC_ADDRESS_ENV: &str = "TTRPC_ADDRESS";

pub async fn run(runtime_id: &str, flags: Flags) -> Result<(), Error> {
    match flags.action.as_str() {
        "start" => start(flags).await,
        "delete" => delete(runtime_id, flags).await,
        _ => serve(runtime_id, flags).await,
    }
}

async fn start(flags: Flags) -> Result<(), Error> {
    let params =
        BootstrapParams::read_from(std::io::stdin().lock()).map_err(|err| Error::IoError {
            context: "read containerd bootstrap params".to_string(),
            err,
        })?;
    let socket_dir = params.socket_dir.as_deref().unwrap_or(DEFAULT_SOCKET_DIR);
    let address = socket_address(
        socket_dir,
        &params.containerd_grpc_address,
        &params.namespace,
        &params.instance_id,
    )?;

    let executable = env::current_exe().map_err(|err| Error::IoError {
        context: "resolve shim executable".to_string(),
        err,
    })?;
    let cwd = env::current_dir().map_err(|err| Error::IoError {
        context: "resolve shim bundle directory".to_string(),
        err,
    })?;
    let debug = flags.debug || params.log_level <= -4;
    let mut command = Command::new(executable);
    command
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env(TTRPC_ADDRESS_ENV, &params.containerd_ttrpc_address)
        .args([
            "-namespace",
            &params.namespace,
            "-id",
            &params.instance_id,
            "-address",
            &params.containerd_grpc_address,
            "-socket",
            &address,
        ]);
    if debug {
        command.arg("-debug");
    }

    let mut child = command.spawn().map_err(|err| Error::IoError {
        context: "spawn CubeShim server".to_string(),
        err,
    })?;
    #[cfg(target_os = "linux")]
    containerd_shim::cgroup::set_cgroup_and_oom_score(child.id().unwrap())?;

    let mut ready_pipe = child
        .stdout
        .take()
        .ok_or_else(|| Error::Other("CubeShim child has no readiness pipe".to_string()))?;
    io::copy(&mut ready_pipe, &mut io::stderr())
        .await
        .map_err(|err| Error::IoError {
            context: "wait for CubeShim server readiness".to_string(),
            err,
        })?;
    if let Some(status) = child.try_wait().map_err(|err| Error::IoError {
        context: "inspect CubeShim child".to_string(),
        err,
    })? {
        return Err(Error::Other(format!(
            "CubeShim server exited before readiness: {status}"
        )));
    }

    fs::write(ADDRESS_FILE, address.as_bytes()).map_err(|err| Error::IoError {
        context: "persist CubeShim address".to_string(),
        err,
    })?;
    BootstrapResult::ttrpc(address)
        .write_to(std::io::stdout().lock())
        .map_err(|err| Error::IoError {
            context: "write containerd bootstrap result".to_string(),
            err,
        })
}

async fn delete(runtime_id: &str, flags: Flags) -> Result<(), Error> {
    let mut config = Config {
        no_reaper: true,
        no_setup_logger: true,
        no_sub_reaper: true,
        ..Default::default()
    };
    let mut shim = <Service as Shim>::new(runtime_id, &flags, &mut config).await;
    let response = shim.delete_shim().await?;
    let data = response.write_to_bytes()?;
    std::io::stdout()
        .lock()
        .write_all(&data)
        .map_err(|err| Error::IoError {
            context: "write delete response".to_string(),
            err,
        })
}

async fn serve(runtime_id: &str, flags: Flags) -> Result<(), Error> {
    if flags.id.is_empty() || flags.namespace.is_empty() {
        return Err(Error::InvalidArgument(
            "shim id and namespace cannot be empty".to_string(),
        ));
    }
    if flags.socket.is_empty() {
        return Err(Error::InvalidArgument(
            "shim socket cannot be empty".to_string(),
        ));
    }
    let ttrpc_address = env::var(TTRPC_ADDRESS_ENV)
        .map_err(|error| Error::Other(format!("{TTRPC_ADDRESS_ENV} is unavailable: {error}")))?;

    prepare_socket(&flags.socket)?;
    let mut config = Config {
        no_reaper: true,
        no_setup_logger: true,
        no_sub_reaper: true,
        ..Default::default()
    };
    let mut shim = <Service as Shim>::new(runtime_id, &flags, &mut config).await;
    let publisher = RemotePublisher::new(&ttrpc_address).await?;
    let task = shim.create_task_service(publisher).await;
    let sandbox = SandboxService::new(&task);
    let exit = task.exit_signal();

    let task_service = create_task(Arc::new(task));
    let sandbox_service = create_sandbox(Arc::new(sandbox));
    let mut server = Server::new()
        .bind(&flags.socket)
        .map_err(|error| Error::Other(format!("bind CubeShim socket: {error}")))?
        .register_service(task_service)
        .register_service(sandbox_service);
    server
        .start()
        .await
        .map_err(|error| Error::Other(format!("start CubeShim ttrpc server: {error}")))?;
    signal_server_started()?;

    #[cfg(unix)]
    tokio::spawn(async move {
        use tokio::signal::unix::{signal, SignalKind};
        let mut terminate = signal(SignalKind::terminate()).ok();
        let mut interrupt = signal(SignalKind::interrupt()).ok();
        match (terminate.as_mut(), interrupt.as_mut()) {
            (Some(terminate), Some(interrupt)) => {
                tokio::select! {
                    _ = terminate.recv() => {},
                    _ = interrupt.recv() => {},
                }
            }
            (Some(terminate), None) => {
                terminate.recv().await;
            }
            (None, Some(interrupt)) => {
                interrupt.recv().await;
            }
            (None, None) => return,
        }
        exit.signal();
    });

    shim.wait().await;
    server.shutdown().await.unwrap_or_default();
    remove_socket(&flags.socket);
    Ok(())
}

fn socket_address(
    socket_dir: &str,
    containerd_address: &str,
    namespace: &str,
    id: &str,
) -> Result<String, Error> {
    let logical_path = PathBuf::from(containerd_address)
        .join(namespace)
        .join(id)
        .display()
        .to_string();
    let digest = Sha256::digest(logical_path.as_bytes());
    let path = Path::new(socket_dir).join(format!("{digest:x}"));
    if path.as_os_str().len() >= 104 {
        return Err(Error::InvalidArgument(format!(
            "shim socket path is too long: {} bytes",
            path.as_os_str().len()
        )));
    }
    Ok(format!("unix://{}", path.display()))
}

fn prepare_socket(address: &str) -> Result<(), Error> {
    let path = address.strip_prefix("unix://").ok_or_else(|| {
        Error::InvalidArgument(format!(
            "only unix CubeShim sockets are supported: {address}"
        ))
    })?;
    if let Some(parent) = Path::new(path).parent() {
        fs::create_dir_all(parent).map_err(|err| Error::IoError {
            context: format!("create CubeShim socket directory {}", parent.display()),
            err,
        })?;
    }
    if Path::new(path).exists() {
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            return Err(Error::Other(format!(
                "CubeShim socket is already serving: {address}"
            )));
        }
        fs::remove_file(path).map_err(|err| Error::IoError {
            context: format!("remove stale CubeShim socket {path}"),
            err,
        })?;
    }
    Ok(())
}

fn remove_socket(address: &str) {
    if let Some(path) = address.strip_prefix("unix://") {
        let _ = fs::remove_file(path);
    }
}

fn signal_server_started() -> Result<(), Error> {
    let result = unsafe { libc::dup2(libc::STDERR_FILENO, libc::STDOUT_FILENO) };
    if result < 0 {
        return Err(Error::IoError {
            context: "close CubeShim readiness pipe".to_string(),
            err: std::io::Error::last_os_error(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_address_uses_requested_short_directory() {
        let address = socket_address(
            "/run/containerd/s",
            "/run/containerd/containerd.sock",
            "k8s.io",
            "pod-1",
        )
        .unwrap();
        assert!(address.starts_with("unix:///run/containerd/s/"));
        assert_eq!(address.len(), "unix:///run/containerd/s/".len() + 64);
    }

    #[test]
    fn socket_address_rejects_long_unix_path() {
        let directory = format!("/tmp/{}", "x".repeat(80));
        let error =
            socket_address(&directory, "/run/containerd.sock", "k8s.io", "pod-1").unwrap_err();
        assert!(error.to_string().contains("too long"));
    }
}
