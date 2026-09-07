// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use containerd_shim::asynchronous::{publisher::RemotePublisher, Shim};
use containerd_shim::protos::protobuf::Message;
use containerd_shim::protos::{
    sandbox_async::create_sandbox,
    shim_async::{create_task, Task as TaskRpc},
    ttrpc::{self, r#async::Server},
};
use containerd_shim::{Config, Error, Flags};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Instant;
use tokio::io;
use tokio::process::Command;

use crate::common::utils::ADDRESS_FILE;
use crate::service::bootstrap::{BootstrapParams, BootstrapResult};
use crate::service::host_cgroup::{self, BootstrapSession};
use crate::service::runtime_resource;
use crate::service::sandbox_srv::SandboxService;
use crate::service::srv::Service;

const DEFAULT_SOCKET_DIR: &str = "/run/containerd/s";
const TTRPC_ADDRESS_ENV: &str = "TTRPC_ADDRESS";
const TASK_SERVICE_V2: &str = "containerd.task.v2.Task";
const TASK_SERVICE_V3: &str = "containerd.task.v3.Task";

pub async fn run(runtime_id: &str, flags: Flags) -> Result<(), Error> {
    match flags.action.as_str() {
        "start" => start(flags).await,
        "delete" => delete(runtime_id, flags).await,
        runtime_resource::RUNTIME_REAPER_ACTION => runtime_resource::run_persisted_reaper()
            .await
            .map_err(Error::Other),
        host_cgroup::WATCHDOG_ACTION => host_cgroup::run_watchdog().await.map_err(Error::Other),
        host_cgroup::SYSTEMD_PROBE_ACTION => host_cgroup::run_systemd_probe().map_err(Error::Other),
        _ => serve(runtime_id, flags).await,
    }
}

async fn start(flags: Flags) -> Result<(), Error> {
    let start_entered = Instant::now();
    let params =
        BootstrapParams::read_from(std::io::stdin().lock()).map_err(|err| Error::IoError {
            context: "read containerd bootstrap params".to_string(),
            err,
        })?;
    crate::cube_perf!(
        "cube_perf component=bootstrap operation_id={} phase=params-read ts_mono_us={} duration_us={}",
        params.instance_id,
        crate::common::utils::Utils::monotonic_time_micros(),
        start_entered.elapsed().as_micros()
    );
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
    let prepare_started = Instant::now();
    let mut session = BootstrapSession::prepare(&params, &cwd, &address, &executable, debug)
        .map_err(Error::Other)?;
    crate::cube_perf!(
        "cube_perf component=bootstrap operation_id={} phase=session-prepare ts_mono_us={} duration_us={}",
        params.instance_id,
        crate::common::utils::Utils::monotonic_time_micros(),
        prepare_started.elapsed().as_micros()
    );
    let result = async {
        let place_started = Instant::now();
        session.place_helper().map_err(Error::Other)?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=place-helper ts_mono_us={} duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            place_started.elapsed().as_micros()
        );
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

        session
            .configure_child(&mut command)
            .map_err(Error::Other)?;

        let spawn_started = Instant::now();
        let mut child = command.spawn().map_err(|err| Error::IoError {
            context: "spawn CubeShim server".to_string(),
            err,
        })?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=server-spawn ts_mono_us={} duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            spawn_started.elapsed().as_micros()
        );
        session.child_spawned();
        let child_pid = i32::try_from(child.id().ok_or_else(|| {
            Error::Other("spawned CubeShim server did not report a pid".to_string())
        })?)
        .map_err(|error| Error::Other(format!("CubeShim server pid does not fit i32: {error}")))?;
        let register_started = Instant::now();
        session
            .register_spawned_server(child_pid)
            .map_err(Error::Other)?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=register-spawned-server ts_mono_us={} duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            register_started.elapsed().as_micros()
        );
        let identity_started = Instant::now();
        session
            .wait_server_identity(child_pid)
            .await
            .map_err(Error::Other)?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=wait-server-identity ts_mono_us={} duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            identity_started.elapsed().as_micros()
        );
        let oom_started = Instant::now();
        #[cfg(target_os = "linux")]
        containerd_shim::cgroup::adjust_oom_score(child.id().unwrap())?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=adjust-oom-score ts_mono_us={} duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            oom_started.elapsed().as_micros()
        );
        let release_started = Instant::now();
        session.release_gate().map_err(Error::Other)?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=release-gate ts_mono_us={} duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            release_started.elapsed().as_micros()
        );

        let mut ready_pipe = child
            .stdout
            .take()
            .ok_or_else(|| Error::Other("CubeShim child has no readiness pipe".to_string()))?;
        let readiness_started = Instant::now();
        io::copy(&mut ready_pipe, &mut io::stderr())
            .await
            .map_err(|err| Error::IoError {
                context: "wait for CubeShim server readiness".to_string(),
                err,
            })?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=wait-server-readiness ts_mono_us={} duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            readiness_started.elapsed().as_micros()
        );
        if let Some(status) = child.try_wait().map_err(|err| Error::IoError {
            context: "inspect CubeShim child".to_string(),
            err,
        })? {
            return Err(Error::Other(format!(
                "CubeShim server exited before readiness: {status}"
            )));
        }

        let restore_started = Instant::now();
        session.restore_helper().map_err(Error::Other)?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=restore-helper ts_mono_us={} duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            restore_started.elapsed().as_micros()
        );

        let address_started = Instant::now();
        durable_write_file(Path::new(ADDRESS_FILE), address.as_bytes()).map_err(|err| {
            Error::IoError {
                context: "persist CubeShim address".to_string(),
                err,
            }
        })?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=persist-address ts_mono_us={} duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            address_started.elapsed().as_micros()
        );
        let response_started = Instant::now();
        let mut stdout = std::io::stdout().lock();
        BootstrapResult::ttrpc(address)
            .write_to(&mut stdout)
            .map_err(|err| Error::IoError {
                context: "write containerd bootstrap result".to_string(),
                err,
            })?;
        stdout.flush().map_err(|err| Error::IoError {
            context: "flush containerd bootstrap result".to_string(),
            err,
        })?;
        crate::cube_perf!(
            "cube_perf component=bootstrap operation_id={} phase=bootstrap-response ts_mono_us={} duration_us={} total_duration_us={}",
            params.instance_id,
            crate::common::utils::Utils::monotonic_time_micros(),
            response_started.elapsed().as_micros(),
            start_entered.elapsed().as_micros()
        );
        Ok(())
    }
    .await;
    if let Err(error) = result {
        let primary = format!("{error}");
        return match session.abort(&primary).await {
            Ok(()) => Err(error),
            Err(cleanup) => Err(Error::Other(format!(
                "{primary}; bootstrap cleanup: {cleanup}"
            ))),
        };
    }
    Ok(())
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
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(&data).map_err(|err| Error::IoError {
        context: "write delete response".to_string(),
        err,
    })?;
    stdout.flush().map_err(|err| Error::IoError {
        context: "flush delete response".to_string(),
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

    let host_lifecycle = host_cgroup::lifecycle_from_env().map_err(Error::Other)?;
    let socket_guard = host_lifecycle
        .as_ref()
        .map(|lifecycle| lifecycle.acquire_socket_path_guard(&flags.socket))
        .transpose()
        .map_err(Error::Other)?;
    prepare_socket(&flags.socket)?;
    let mut config = Config {
        no_reaper: true,
        no_setup_logger: true,
        no_sub_reaper: true,
        ..Default::default()
    };
    let mut shim = <Service as Shim>::new(runtime_id, &flags, &mut config).await;
    let publisher = RemotePublisher::new(&ttrpc_address).await?;
    let task = Arc::new(shim.create_task_service(publisher).await);
    let sandbox = SandboxService::new(&task);
    let exit = task.exit_signal();

    let task: Arc<dyn TaskRpc + Send + Sync> = task;
    let task_v2_service = create_task(task.clone());
    let task_v3_service = create_task_v3(task)?;
    let sandbox_service = create_sandbox(Arc::new(sandbox));
    let mut server = Server::new()
        .bind(&flags.socket)
        .map_err(|error| Error::Other(format!("bind CubeShim socket: {error}")))?
        .register_service(task_v2_service)
        .register_service(task_v3_service)
        .register_service(sandbox_service);
    server
        .start()
        .await
        .map_err(|error| Error::Other(format!("start CubeShim ttrpc server: {error}")))?;
    if let Some(lifecycle) = host_lifecycle {
        lifecycle
            .mark_socket_ready(&flags.socket)
            .map_err(Error::Other)?;
    }
    drop(socket_guard);
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
    if let Some(lifecycle) = host_cgroup::lifecycle_from_env().map_err(Error::Other)? {
        lifecycle
            .request_cleanup("CubeShim server exited gracefully")
            .map_err(Error::Other)?;
    }
    Ok(())
}

fn create_task_v3(
    task: Arc<dyn TaskRpc + Send + Sync>,
) -> Result<HashMap<String, ttrpc::r#async::Service>, Error> {
    // containerd 2.3 changed the Task protobuf package from v2 to v3 without
    // changing its messages or RPC methods. rust-extensions 0.11.0 still only
    // generates the v2 service, so reuse a second generated handler set under
    // the v3 service name. Keep v2 registered as well for older containerd.
    let mut services = create_task(task);
    if services.contains_key(TASK_SERVICE_V3) {
        return Err(Error::Other(format!(
            "generated Task services already contain {TASK_SERVICE_V3}"
        )));
    }
    let service = services.remove(TASK_SERVICE_V2).ok_or_else(|| {
        Error::Other(format!(
            "generated Task services do not contain {TASK_SERVICE_V2}"
        ))
    })?;
    services.insert(TASK_SERVICE_V3.to_string(), service);
    Ok(services)
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
    let address = format!("unix://{}", path.display());
    let canonical = host_cgroup::unix_socket_path(&address).map_err(Error::InvalidArgument)?;
    Ok(format!("unix://{}", canonical.display()))
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
        return Err(Error::Other(format!(
            "refuse to replace existing CubeShim socket path: {address}"
        )));
    }
    Ok(())
}

pub(crate) fn durable_write_file(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let parent = path
        .parent()
        .filter(|value| !value.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("address"),
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)?;
    let write_result = file.write_all(data).and_then(|()| file.sync_all());
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    if let Err(error) = fs::rename(&temporary, path) {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    File::open(parent)?.sync_all()
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
    use std::io::Read;

    struct FakeTask;

    #[async_trait::async_trait]
    impl TaskRpc for FakeTask {}

    #[test]
    fn task_v3_registration_preserves_generated_rpc_methods() {
        let v2 = create_task(Arc::new(FakeTask));
        let v3 = create_task_v3(Arc::new(FakeTask)).unwrap();
        let expected = [
            "Checkpoint",
            "CloseIO",
            "Connect",
            "Create",
            "Delete",
            "Exec",
            "Kill",
            "Pause",
            "Pids",
            "ResizePty",
            "Resume",
            "Shutdown",
            "Start",
            "State",
            "Stats",
            "Update",
            "Wait",
        ]
        .into_iter()
        .collect::<std::collections::BTreeSet<_>>();

        assert_eq!(v2.len(), 1);
        assert_eq!(v3.len(), 1);
        assert!(v2.contains_key(TASK_SERVICE_V2));
        assert!(v3.contains_key(TASK_SERVICE_V3));
        assert_eq!(
            v2[TASK_SERVICE_V2]
                .methods
                .keys()
                .map(String::as_str)
                .collect::<std::collections::BTreeSet<_>>(),
            expected
        );
        assert_eq!(
            v3[TASK_SERVICE_V3]
                .methods
                .keys()
                .map(String::as_str)
                .collect::<std::collections::BTreeSet<_>>(),
            expected
        );
    }

    #[test]
    fn socket_prepare_never_replaces_existing_path() {
        let root = std::env::temp_dir().join(format!(
            "cube-shim-existing-socket-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("shim.sock");
        fs::write(&path, b"new-generation-owned").unwrap();
        let address = format!("unix://{}", path.display());

        assert!(prepare_socket(&address).is_err());
        let mut contents = Vec::new();
        File::open(&path)
            .unwrap()
            .read_to_end(&mut contents)
            .unwrap();
        assert_eq!(contents, b"new-generation-owned");
        fs::remove_dir_all(root).unwrap();
    }

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
