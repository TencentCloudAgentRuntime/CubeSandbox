// Copyright (c) 2019 Ant Financial
//
// SPDX-License-Identifier: Apache-2.0
//

use std::ffi::CString;
use std::fmt;
use std::fs;
use std::fs::create_dir_all;
use std::fs::{File, OpenOptions};
use std::future::Future;
use std::io;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::FileExt;
#[cfg(target_arch = "aarch64")]
use std::os::unix::io::AsRawFd;
use std::os::unix::prelude::PermissionsExt;
use std::path::Path;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use cgroups::freezer::FreezerState;
use cube::rootfs;
use cube::rootfs::ANNO_PROPAGATION_CONTAINER_UMNTS;
use cube::rootfs::ANNO_PROPAGATION_EXEC_MNTS;
use cube::utils::ANNO_APP_SNAPSHOT_CONTAINER_ID;
use cube::utils::ANNO_CONTAINER_LOG_FORWARDING;
use libc::{self, c_char, c_ushort, pid_t, winsize, TIOCSWINSZ};
use nix::errno::Errno;
use nix::mount::{MntFlags, MsFlags};
use nix::sys::{stat, statfs};
use nix::unistd::{self, Pid};
use nix::unistd::{Gid, Uid};
use oci::{LinuxNamespace, Mount, Root, Spec};
use opentelemetry::global;
use protobuf::MessageDyn;
use protobuf::MessageField;
use protocols::agent::{
    self, AddSwapRequest, AgentDetails, CopyFileRequest, GetIPTablesRequest, GetIPTablesResponse,
    GuestDetailsResponse, Interfaces, Metrics, OOMEvent, ReadStreamResponse, Routes,
    SetIPTablesRequest, SetIPTablesResponse, StatsContainerResponse, VolumeStatsRequest,
    WaitProcessResponse, WriteStreamResponse,
};
use protocols::csi::{volume_usage, VolumeCondition, VolumeStatsResponse, VolumeUsage};
use protocols::empty::Empty;
use protocols::health::health_check_response::ServingStatus;
use protocols::health::{AgentCapability, HealthCheckResponse, VersionCheckResponse};
use protocols::types::Interface;
use rustjail::cgroups::notifier;
use rustjail::cgroups::Manager;
use rustjail::container::{
    start_exec_process, BaseContainer, Container, LinuxContainer, ResourcePreconditionError,
    EXEC_FIFO_FILENAME,
};
use rustjail::process::Process;
use rustjail::process::ProcessOperations;
use rustjail::specconv::{CreateOpts, ResourceV2Config};
use rustjail::{pipestream::PipeStream, process::StreamType};
use tokio::io::{AsyncReadExt, AsyncWriteExt, ReadHalf};
use tokio::sync::Mutex;
use tracing::instrument;
use tracing::span;
use tracing_opentelemetry::OpenTelemetrySpanExt;
use ttrpc::{
    self,
    error::get_rpc_status,
    r#async::{Server as TtrpcServer, TtrpcContext},
};

use crate::device::{
    add_devices, get_virtio_blk_pci_device_name, update_device_cgroup, update_env_pci,
    wait_for_pci_net,
};
use crate::linux_abi::*;
use crate::metrics::get_metrics;
use crate::mount::add_virtiofs_storages;
use crate::mount::{add_storages, baremount, STORAGE_HANDLER_LIST};
use crate::namespace::{NSTYPEIPC, NSTYPEPID, NSTYPEUTS};
use crate::network::setup_guest_dns;
use crate::pci;
use crate::random;
use crate::sandbox::{PendingCreateActivity, Sandbox};
use crate::time::start_time_sync_task;
use crate::trace_rpc_call;
use crate::tracer::extract_carrier_from_ttrpc;
use crate::version::{AGENT_VERSION, API_VERSION};
use crate::AGENT_CONFIG;
const CONTAINER_BASE: &str = "/run/cube-containers";
const RUNTIME_SHARE: &str = "/run/share_runtime/";

const IPTABLES_SAVE: &str = "/sbin/iptables-save";
const IPTABLES_RESTORE: &str = "/sbin/iptables-restore";
const IP6TABLES_SAVE: &str = "/sbin/ip6tables-save";
const IP6TABLES_RESTORE: &str = "/sbin/ip6tables-restore";

const ERR_CANNOT_GET_WRITER: &str = "Cannot get writer";
const ERR_INVALID_BLOCK_SIZE: &str = "Invalid block size";
const ERR_NO_LINUX_FIELD: &str = "Spec does not contain linux field";
const ERR_NO_SANDBOX_PIDNS: &str = "Sandbox does not have sandbox_pidns";
// The Shim-side Agent client has a 10-second deadline. Finish first or cancel
// the in-Guest launch so a timed-out ExecProcess cannot retain the Sandbox and
// global process-launch locks after the caller has already given up.
const EXEC_PROCESS_START_TIMEOUT: Duration = Duration::from_secs(8);

async fn bounded_exec_process_start<F>(timeout: Duration, operation: F) -> Option<Result<()>>
where
    F: Future<Output = Result<()>>,
{
    match tokio::time::timeout(timeout, operation).await {
        Ok(result) => Some(result),
        Err(_) => None,
    }
}

// IPTABLES_RESTORE_WAIT_SEC is the timeout value provided to iptables-restore --wait. Since we
// don't expect other writers to iptables, we don't expect contention for grabbing the iptables
// filesystem lock. Based on this, 5 seconds seems a resonable timeout period in case the lock is
// not available.
const IPTABLES_RESTORE_WAIT_SEC: u64 = 5;

const ANNOTATION_K_ROOTFS_WL_PATH: &str = "cube.rootfs.wlayer.path";
const PROC_PATH_NFS_CLIENT_IDENT: &str = "/sys/fs/nfs/net/nfs_client/identifier";
const CONTAINER_CUSTOM_FILE_BASE: &str = "/run/custom_file";

// Convenience macro to obtain the scope logger
macro_rules! sl {
    () => {
        slog_scope::logger()
    };
}

// Convenience macro to wrap an error and response to ttrpc client
macro_rules! ttrpc_error {
    ($code:expr, $err:expr $(,)?) => {
        get_rpc_status($code, format!("{:?}", $err))
    };
}

macro_rules! is_allowed {
    ($req:ident) => {
        if !AGENT_CONFIG
            .read()
            .await
            .is_allowed_endpoint($req.descriptor_dyn().name())
        {
            return Err(ttrpc_error!(
                ttrpc::Code::UNIMPLEMENTED,
                format!("{} is blocked", $req.descriptor_dyn().name()),
            ));
        }
    };
}

#[derive(Clone, Debug)]
pub struct AgentService {
    sandbox: Arc<Mutex<Sandbox>>,
    create_lock: Arc<Mutex<()>>,
}

struct ActiveCreateGuard(Arc<PendingCreateActivity>);

impl Drop for ActiveCreateGuard {
    fn drop(&mut self) {
        self.0.finish();
    }
}

struct WorkingDirectoryGuard(PathBuf);

impl Drop for WorkingDirectoryGuard {
    fn drop(&mut self) {
        let _ = unistd::chdir(&self.0);
    }
}

async fn request_pending_create_cleanup<State, Lookup>(
    state: &Arc<Mutex<State>>,
    timeout: Option<Duration>,
    lookup: Lookup,
) -> Result<Option<Arc<PendingCreateActivity>>>
where
    Lookup: FnOnce(&State) -> Option<Arc<PendingCreateActivity>>,
{
    // Only hold the state lock long enough to clone the activity token.  In
    // particular, the create path must not hold this lock while it awaits the
    // guest process start; otherwise RemoveContainer cannot begin its timeout.
    let activity = {
        let state = state.lock().await;
        lookup(&state)
    };
    let Some(activity) = activity else {
        return Ok(None);
    };

    activity.request_cancel();
    match timeout {
        None => activity.wait_inactive().await,
        Some(timeout) => {
            tokio::time::timeout(timeout, activity.wait_inactive())
                .await
                .map_err(|_| anyhow!(nix::Error::ETIME))?;
        }
    }

    Ok(Some(activity))
}

fn runtime_operation_error_code(error: &anyhow::Error) -> ttrpc::Code {
    if error.downcast_ref::<ResourcePreconditionError>().is_some() {
        ttrpc::Code::FAILED_PRECONDITION
    } else {
        ttrpc::Code::INTERNAL
    }
}

fn update_container_error_code(error: &anyhow::Error) -> ttrpc::Code {
    error
        .downcast_ref::<rustjail::cgroups::fs::resources_v2::TransactionError>()
        .map(|error| error.kind)
        .filter(|kind| {
            matches!(
                kind,
                rustjail::cgroups::fs::resources_v2::TransactionFailureKind::Degraded
                    | rustjail::cgroups::fs::resources_v2::TransactionFailureKind::Recovered
            )
        })
        .map(|_| ttrpc::Code::FAILED_PRECONDITION)
        .unwrap_or(ttrpc::Code::INTERNAL)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ContainerResourceOperation {
    Start,
    Exec,
    Stats,
    Signal,
    Wait,
    Remove,
}

impl ContainerResourceOperation {
    fn name(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Exec => "exec",
            Self::Stats => "collect stats",
            Self::Signal => "signal",
            Self::Wait => "wait",
            Self::Remove => "remove",
        }
    }

    fn blocked_while_degraded(self) -> bool {
        matches!(self, Self::Start | Self::Exec | Self::Stats)
    }
}

fn check_container_resource_operation(
    container: &LinuxContainer,
    operation: ContainerResourceOperation,
) -> Result<()> {
    check_resource_operation_state(
        &container.id,
        container.resource_degraded.as_ref(),
        operation,
    )
}

fn check_resource_operation_state(
    container_id: &str,
    degraded: Option<&rustjail::container::ResourceDegraded>,
    operation: ContainerResourceOperation,
) -> Result<()> {
    if operation.blocked_while_degraded() {
        if let Some(degraded) = degraded {
            return Err(anyhow!(ResourcePreconditionError {
                container_id: container_id.to_string(),
                operation: operation.name().to_string(),
                degraded: degraded.clone(),
            }));
        }
        Ok(())
    } else {
        Ok(())
    }
}

fn prepare_container_resource_update<Recover>(
    resources: &protocols::oci::LinuxResources,
    recover: Recover,
) -> ttrpc::Result<(oci::LinuxResources, Option<Vec<u8>>)>
where
    Recover:
        FnOnce() -> std::result::Result<(), rustjail::cgroups::fs::resources_v2::TransactionError>,
{
    // Recovery must precede transport selection and decoding.  Otherwise a
    // legacy request (or an invalid V2 envelope) could bypass the persisted
    // rollback journal and mutate an already-degraded cgroup.
    recover().map_err(|error| ttrpc_error!(ttrpc::Code::FAILED_PRECONDITION, anyhow!(error)))?;
    rustjail::resources::resources_from_grpc(resources, false)
        .map_err(|error| ttrpc_error!(ttrpc::Code::INVALID_ARGUMENT, error))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SerializedContainerOperation {
    Update,
    Remove,
    Stats,
}

async fn lock_container_state<State>(
    state: &Arc<Mutex<State>>,
    _operation: SerializedContainerOperation,
) -> tokio::sync::MutexGuard<'_, State> {
    state.lock().await
}

impl AgentService {
    fn new(sandbox: Arc<Mutex<Sandbox>>) -> Self {
        Self {
            sandbox,
            create_lock: Arc::new(Mutex::new(())),
        }
    }

    async fn cleanup_pending_create(&self, cid: &str) -> Result<()> {
        let sandbox = self.sandbox.clone();
        let mut sandbox = sandbox.lock().await;
        Self::cleanup_pending_create_locked(&mut sandbox, cid).await
    }

    async fn cleanup_pending_create_locked(sandbox: &mut Sandbox, cid: &str) -> Result<()> {
        if !sandbox.pending_creates.contains_key(cid) {
            return Ok(());
        }
        if sandbox
            .pending_creates
            .get(cid)
            .expect("pending owner disappeared during cleanup")
            .activity
            .is_active()
        {
            return Err(anyhow!("container {cid} create is still active"));
        }

        let mut errors = Vec::new();
        let container = sandbox
            .pending_creates
            .get(cid)
            .and_then(|pending| pending.container.clone());
        if let Some(container) = container {
            let mut container = container.lock().await;
            if let Err(error) = container.abort_create() {
                errors.push(format!("abort container: {error:#}"));
            } else {
                drop(container);
                sandbox
                    .pending_creates
                    .get_mut(cid)
                    .expect("pending owner disappeared during cleanup")
                    .container = None;
            }
        }

        sandbox.bind_watcher.remove_container(cid).await;

        let storage_refs = sandbox
            .pending_creates
            .get(cid)
            .expect("pending owner disappeared during cleanup")
            .storage_refs
            .clone();
        for storage in storage_refs {
            match sandbox.cleanup_pending_storage(&storage) {
                Ok(()) => {
                    let pending = sandbox
                        .pending_creates
                        .get_mut(cid)
                        .expect("pending owner disappeared during cleanup");
                    if let Some(index) = pending
                        .storage_refs
                        .iter()
                        .position(|value| value == &storage)
                    {
                        pending.storage_refs.remove(index);
                    }
                }
                Err(error) => errors.push(format!("release storage {storage}: {error:#}")),
            }
        }

        let bundle_path = sandbox
            .pending_creates
            .get(cid)
            .expect("pending owner disappeared during cleanup")
            .bundle_path
            .clone();
        let has_container = sandbox
            .pending_creates
            .get(cid)
            .and_then(|pending| pending.container.as_ref())
            .is_some();
        if !has_container {
            let rootfs_path = bundle_path.join("rootfs");
            let rootfs_detached =
                match nix::mount::umount2(rootfs_path.as_path(), MntFlags::MNT_DETACH) {
                    Ok(()) | Err(Errno::EINVAL) | Err(Errno::ENOENT) => true,
                    Err(error) => {
                        errors.push(format!(
                            "detach pending rootfs {}: {error}",
                            rootfs_path.display()
                        ));
                        false
                    }
                };
            if rootfs_detached {
                match fs::remove_dir_all(&bundle_path) {
                    Ok(()) => {}
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                    Err(error) => errors.push(format!(
                        "remove pending bundle {}: {error}",
                        bundle_path.display()
                    )),
                }
            }
            let custom_file_path = Path::new(CONTAINER_CUSTOM_FILE_BASE).join(cid);
            match fs::remove_dir_all(&custom_file_path) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => errors.push(format!(
                    "remove pending custom files {}: {error}",
                    custom_file_path.display()
                )),
            }
        }

        if errors.is_empty() {
            sandbox.pending_creates.remove(cid);
            Ok(())
        } else {
            let summary = errors.join("; ");
            sandbox
                .pending_creates
                .get_mut(cid)
                .expect("pending owner disappeared during cleanup")
                .last_cleanup_error = Some(summary.clone());
            Err(anyhow!(summary))
        }
    }

    #[instrument]
    async fn do_create_container(
        &self,
        req: protocols::agent::CreateContainerRequest,
    ) -> Result<()> {
        let mut start = Instant::now();
        let cid = req.container_id.clone();
        info!(sl!(), "[cube-strace]recv create container");

        let mut oci_spec = req.OCI.clone();
        let use_sandbox_pidns = req.sandbox_pidns();

        let mut oci = match oci_spec.as_mut() {
            Some(spec) => rustjail::grpc_to_oci(spec),
            None => {
                error!(sl!(), "no oci spec in the create container request!");
                return Err(anyhow!(nix::Error::EINVAL));
            }
        };
        let resources_v2_canonical = match oci_spec.as_ref() {
            Some(spec) => rustjail::resources::replace_spec_resources_from_grpc(&mut oci, spec)?,
            None => None,
        };
        let anno = oci.annotations.clone();
        if let Some(id) = anno.get(ANNO_APP_SNAPSHOT_CONTAINER_ID) {
            info!(sl!(), "create container by restore");

            let mut proc_io = None;
            if crate::passfd_io::has_passfd_ports(req.stdin_port, req.stdout_port, req.stderr_port)
            {
                proc_io = Some(
                    crate::passfd_io::create_process_io(
                        req.stdin_port,
                        req.stdout_port,
                        req.stderr_port,
                    )
                    .await?,
                );
            }

            let pid = {
                let sandbox = self.sandbox.clone();
                let mut s: tokio::sync::MutexGuard<'_, Sandbox> = sandbox.lock().await;
                let process = s.find_container_process(id, &"")?;

                if let Some(io) = proc_io {
                    info!(sl!(), "reconnecting passfd for restored container {}", id);
                    process.reconnect_passfd(io).await?;
                }

                process.pid
            };

            debug!(sl!(), "container pid:{}", pid);
            start_exec_process(
                pid,
                anno.get(ANNO_PROPAGATION_EXEC_MNTS),
                anno.get(ANNO_PROPAGATION_CONTAINER_UMNTS),
            )
            .await
            .map_err(|e| anyhow!(format!("Exec mount failed:{}", e.to_string())))?;
            return Ok(());
        }

        let activity = {
            let sandbox = self.sandbox.clone();
            let mut sandbox = sandbox.lock().await;
            sandbox.begin_pending_create(&cid, Path::new(CONTAINER_BASE).join(&cid))?
        };
        let active_create = ActiveCreateGuard(activity.clone());

        let create_result: Result<()> = async {
            // Some devices need some extra processing (the ones invoked with
            // --device for instance), and that's what this call is doing. It
            // updates the devices listed in the OCI spec, so that they actually
            // match real devices inside the VM. This step is necessary since we
            // cannot predict everything from the caller.
            add_devices(&req.devices.to_vec(), &mut oci, &self.sandbox).await?;
            activity.check_cancelled()?;
            let duration_add_devices = start.elapsed().as_millis();
            start = Instant::now();
            // Both rootfs and volumes (invoked with --volume for instance) will
            // be processed the same way. The idea is to always mount any provided
            // storage to the specified MountPoint, so that it will match what's
            // inside oci.Mounts.
            add_storages(
                sl!(),
                req.storages.to_vec(),
                self.sandbox.clone(),
                Some(cid.clone()),
            )
            .await?;
            activity.check_cancelled()?;

            let duration_add_storage = start.elapsed().as_millis();
            start = Instant::now();
            let _serialized_create = self.create_lock.lock().await;
            activity.check_cancelled()?;
            let (container, _working_directory, initialization_error) = {
                let sandbox = self.sandbox.clone();
                let mut sandbox = sandbox.lock().await;
                activity.check_cancelled()?;
                update_container_namespaces(&sandbox, &mut oci, use_sandbox_pidns)?;

                // Add the root partition to the device cgroup to prevent access.
                update_device_cgroup(&mut oci)?;
                append_guest_hooks(&sandbox, &mut oci)?;

                let olddir = setup_bundle(&cid, &mut oci, req.custom_files.to_vec())?;
                let working_directory = WorkingDirectoryGuard(olddir);
                let opts = CreateOpts {
                    cgroup_name: "".to_string(),
                    use_systemd_cgroup: false,
                    no_pivot_root: sandbox.no_pivot_root,
                    no_new_keyring: false,
                    spec: Some(oci.clone()),
                    rootless_euid: false,
                    rootless_cgroup: false,
                    resources_v2: resources_v2_canonical.map(|canonical| ResourceV2Config {
                        version: rustjail::resources::RESOURCE_V2_VERSION,
                        canonical,
                    }),
                };
                let creation = LinuxContainer::new_owned(
                    cid.as_str(),
                    CONTAINER_BASE,
                    opts,
                    &sl!(),
                )?;
                let initialization_error = creation.initialization_error;
                let ctr = Arc::new(Mutex::new(creation.container));
                sandbox
                    .pending_creates
                    .get_mut(&cid)
                    .ok_or_else(|| anyhow!("container {cid} lost pending create owner"))?
                    .container = Some(ctr.clone());
                (ctr, working_directory, initialization_error)
            };
            if let Some(error) = initialization_error {
                return Err(error.context("initialize container cgroup"));
            }
            let duration_setup_bundle = start.elapsed().as_millis();
            start = Instant::now();
            let mut ctr = container.lock().await;
            if ctr.config.resources_v2.is_some() {
                ctr.apply_resources_v2_create()
                    .map_err(|error| anyhow!(error))?;
                let resources = ctr
                    .config
                    .spec
                    .as_ref()
                    .and_then(|spec| spec.linux.as_ref())
                    .and_then(|linux| linux.resources.as_ref())
                    .ok_or_else(|| anyhow!("resources-v2 create has no Linux resources"))?;
                rustjail::cgroups::fs::resources_v2::validate_init_process_create(resources)?;
            }

            let pipe_size = AGENT_CONFIG.read().await.container_pipe_size;
            let mut process = if let Some(process) = oci.process {
                Process::new(&sl!(), &process, cid.as_str(), true, pipe_size)?
            } else {
                info!(sl!(), "no process configurations!");
                return Err(anyhow!(nix::Error::EINVAL));
            };
            process.container_id = cid.clone();
            let duration_init_container = start.elapsed().as_millis();
            start = Instant::now();
            process.log_forwarding = oci
                .annotations
                .get(ANNO_CONTAINER_LOG_FORWARDING)
                .map(|value| value.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            if crate::passfd_io::has_passfd_ports(
                req.stdin_port,
                req.stdout_port,
                req.stderr_port,
            ) {
                process.proc_io = Some(
                    crate::passfd_io::create_process_io(
                        req.stdin_port,
                        req.stdout_port,
                        req.stderr_port,
                    )
                    .await?,
                );
            }
            activity.check_cancelled()?;
            process.open_io(&sl!(), None).map_err(|error| anyhow!(error))?;
            ctr.start(process).await?;
            activity.check_cancelled()?;
            drop(ctr);
            drop(container);

            let sandbox = self.sandbox.clone();
            let mut sandbox = sandbox.lock().await;
            activity.check_cancelled()?;
            let mut pending = sandbox
                .pending_creates
                .remove(&cid)
                .ok_or_else(|| anyhow!("container {cid} lost pending create owner at commit"))?;
            let container = pending
                .container
                .take()
                .ok_or_else(|| anyhow!("container {cid} lost pending container at commit"))?;
            let ctr = match Arc::try_unwrap(container) {
                Ok(container) => container.into_inner(),
                Err(container) => {
                    pending.container = Some(container);
                    sandbox.pending_creates.insert(cid.clone(), pending);
                    return Err(anyhow!(
                        "container {cid} still has an active create reference at commit"
                    ));
                }
            };
            if let Err(error) = sandbox.update_shared_pidns(&ctr) {
                pending.container = Some(Arc::new(Mutex::new(ctr)));
                sandbox.pending_creates.insert(cid.clone(), pending);
                return Err(error);
            }
            let storage_refs = crate::sandbox::take_pending_storage_refs(&mut pending);
            sandbox.container_mounts.insert(cid.clone(), storage_refs);
            sandbox.add_container(ctr);
            let duration_start_container = start.elapsed().as_millis();
            info!(sl!(), "created container!, add_devices: {}ms, add storage:{}ms, setup bundle:{}ms, init container:{}ms, start container:{}ms",
                duration_add_devices, duration_add_storage, duration_setup_bundle, duration_init_container, duration_start_container);
            Ok(())
        }
        .await;
        drop(active_create);

        if let Err(error) = create_result {
            return match self.cleanup_pending_create(&cid).await {
                Ok(()) => Err(anyhow!("{error:#}; cleanup=complete")),
                Err(cleanup_error) => Err(anyhow!("{error:#}; cleanup=pending: {cleanup_error:#}")),
            };
        }

        start_time_sync_task().await;
        Ok(())
    }

    #[instrument]
    async fn do_start_container(&self, req: protocols::agent::StartContainerRequest) -> Result<()> {
        let cid = req.container_id;

        let sandbox = self.sandbox.clone();
        let mut s = sandbox.lock().await;
        let sid = s.id.clone();

        let ctr = s
            .get_container(&cid)
            .ok_or_else(|| anyhow!("Invalid container id"))?;

        check_container_resource_operation(ctr, ContainerResourceOperation::Start)?;

        // Arm the OOM watcher before releasing the exec FIFO. Otherwise an
        // immediately OOMing init process can increment oom_kill and exit
        // before the notifier establishes its baseline and inotify watches.
        let oom_notifier = if sid != cid {
            match ctr
                .cgroup_manager
                .as_ref()
                .and_then(|manager| manager.get_cg_path("memory"))
            {
                Some(cg_path) => {
                    Some(notifier::notify_oom(cid.as_str(), cg_path.to_string()).await?)
                }
                None => None,
            }
        } else {
            None
        };

        if let Err(error) = ctr.exec().await {
            if let Some(notifier) = oom_notifier {
                notifier.cancel().await;
            }
            return Err(error);
        }

        if let Some(notifier) = oom_notifier {
            s.run_oom_event_monitor(notifier, cid.clone()).await;
        }

        Ok(())
    }

    #[instrument]
    async fn do_remove_container(
        &self,
        req: protocols::agent::RemoveContainerRequest,
    ) -> Result<()> {
        let cid = req.container_id.clone();
        let pending_activity = request_pending_create_cleanup(
            &self.sandbox,
            (req.timeout != 0).then(|| Duration::from_secs(req.timeout.into())),
            |sandbox| {
                sandbox
                    .pending_creates
                    .get(&cid)
                    .map(|pending| pending.activity.clone())
            },
        )
        .await?;
        if let Some(activity) = pending_activity {
            debug_assert!(!activity.is_active());
            let sandbox = self.sandbox.clone();
            let mut sandbox =
                lock_container_state(&sandbox, SerializedContainerOperation::Remove).await;
            if sandbox.pending_creates.contains_key(&cid) {
                return Self::cleanup_pending_create_locked(&mut sandbox, &cid).await;
            }
            if !sandbox.containers.contains_key(&cid) {
                return Ok(());
            }
        }
        let remove_container_resources = |sandbox: &mut Sandbox| -> Result<()> {
            let mounts = sandbox
                .container_mounts
                .get(&cid)
                .cloned()
                .unwrap_or_default();
            let mut errors = Vec::new();
            for mount in mounts {
                match sandbox.cleanup_pending_storage(&mount) {
                    Ok(()) => {
                        if let Some(container_mounts) = sandbox.container_mounts.get_mut(&cid) {
                            if let Some(index) =
                                container_mounts.iter().position(|value| value == &mount)
                            {
                                container_mounts.remove(index);
                            }
                        }
                    }
                    Err(error) => {
                        errors.push(format!("release container storage {mount}: {error:#}"))
                    }
                }
            }
            if !errors.is_empty() {
                return Err(anyhow!(errors.join("; ")));
            }
            sandbox.container_mounts.remove(cid.as_str());
            sandbox.containers.remove(cid.as_str());
            Ok(())
        };

        if req.timeout == 0 {
            let s = Arc::clone(&self.sandbox);
            let mut sandbox = lock_container_state(&s, SerializedContainerOperation::Remove).await;

            sandbox.bind_watcher.remove_container(&cid).await;

            let container = sandbox
                .get_container(&cid)
                .ok_or_else(|| anyhow!("Invalid container id"))?;
            check_container_resource_operation(container, ContainerResourceOperation::Remove)?;
            container.destroy().await?;

            remove_container_resources(&mut sandbox)?;

            return Ok(());
        }

        // timeout != 0
        let s = self.sandbox.clone();
        tokio::time::timeout(Duration::from_secs(req.timeout.into()), async {
            let mut sandbox = lock_container_state(&s, SerializedContainerOperation::Remove).await;
            let container = sandbox
                .get_container(&cid)
                .ok_or_else(|| anyhow!("Invalid container id"))?;
            check_container_resource_operation(container, ContainerResourceOperation::Remove)?;
            container.destroy().await?;
            sandbox.bind_watcher.remove_container(&cid).await;
            remove_container_resources(&mut sandbox)
        })
        .await
        .map_err(|_| anyhow!(nix::Error::ETIME))??;

        Ok(())
    }

    #[instrument]
    async fn do_exec_process(&self, req: protocols::agent::ExecProcessRequest) -> Result<()> {
        let cid = req.container_id.clone();
        let exec_id = req.exec_id.clone();

        info!(sl!(), "do_exec_process cid: {} eid: {}", cid, exec_id);

        // Every exec that enters the serialized Sandbox section carries its
        // own launch deadline. Start the deadline only after acquiring the
        // lock so a queued exec can never cancel another operation's pending
        // process.
        let mut sandbox = self.sandbox.lock().await;
        let sandbox_ref = &mut *sandbox;
        let operation_cid = cid.clone();
        let operation_exec_id = exec_id.clone();
        let operation = async move {
            let mut process = req
                .process
                .into_option()
                .ok_or_else(|| anyhow!(nix::Error::EINVAL))?;

            // Apply any necessary corrections for PCI addresses.
            update_env_pci(&mut process.Env, &sandbox_ref.pcimap)?;

            let pipe_size = AGENT_CONFIG.read().await.container_pipe_size;
            let ocip = rustjail::process_grpc_to_oci(&process);
            let mut p = Process::new(&sl!(), &ocip, operation_exec_id.as_str(), false, pipe_size)?;
            p.container_id = operation_cid.clone();
            if crate::passfd_io::has_passfd_ports(req.stdin_port, req.stdout_port, req.stderr_port)
            {
                p.proc_io = Some(
                    crate::passfd_io::create_process_io(
                        req.stdin_port,
                        req.stdout_port,
                        req.stderr_port,
                    )
                    .await?,
                );
            }
            let ctr = sandbox_ref
                .get_container(&operation_cid)
                .ok_or_else(|| anyhow!("Invalid container id"))?;

            check_container_resource_operation(ctr, ContainerResourceOperation::Exec)?;

            if req.runtime_unix_addr.is_empty() {
                p.open_io(&sl!(), None).map_err(|e| anyhow!(e))?;
            } else {
                p.open_io(&sl!(), Some(&req.runtime_unix_addr))
                    .map_err(|e| anyhow!(e))?;
            }

            ctr.run(p).await
        };

        match bounded_exec_process_start(EXEC_PROCESS_START_TIMEOUT, operation).await {
            Some(result) => result?,
            None => {
                let cleanup = sandbox
                    .get_container(&cid)
                    .ok_or_else(|| anyhow!("Invalid container id during timed-out exec cleanup"))?
                    .abort_exec_start(&exec_id);
                let message = format!(
                    "exec process start timed out after {} milliseconds",
                    EXEC_PROCESS_START_TIMEOUT.as_millis()
                );
                match cleanup {
                    Ok(()) => return Err(anyhow!(message)),
                    Err(error) => {
                        return Err(anyhow!(
                            "{message}; timed-out exec cleanup failed: {error:#}"
                        ))
                    }
                }
            }
        }
        Ok(())
    }

    async fn do_reconnect_container_io(
        &self,
        req: protocols::agent::ReconnectContainerIORequest,
    ) -> Result<()> {
        let cid = req.container_id.clone();

        if !crate::passfd_io::has_passfd_ports(req.stdin_port, req.stdout_port, req.stderr_port) {
            return Ok(());
        }

        let proc_io =
            crate::passfd_io::create_process_io(req.stdin_port, req.stdout_port, req.stderr_port)
                .await?;

        let s = self.sandbox.clone();
        let mut sandbox = s.lock().await;
        let process = sandbox.find_container_process(&cid, "")?;

        if process.exited {
            return Err(anyhow!("cannot reconnect IO for exited container {}", cid));
        }

        info!(sl!(), "reconnecting passfd for container {}", cid);
        process.reconnect_passfd(proc_io).await?;

        Ok(())
    }

    #[instrument]
    async fn do_signal_process(&self, req: protocols::agent::SignalProcessRequest) -> Result<()> {
        let cid = req.container_id.clone();
        let eid = req.exec_id.clone();
        let s = self.sandbox.clone();

        info!(sl!(), "signal process cid: {} eid: {}", cid, eid);

        let mut sig: libc::c_int = req.signal as libc::c_int;
        {
            let mut sandbox = s.lock().await;
            if let Some(container) = sandbox.get_container(&cid) {
                check_container_resource_operation(container, ContainerResourceOperation::Signal)?;
            }
            let p = sandbox.find_container_process(cid.as_str(), eid.as_str())?;
            // For container initProcess, if it hasn't installed handler for "SIGTERM" signal,
            // it will ignore the "SIGTERM" signal sent to it, thus send it "SIGKILL" signal
            // instead of "SIGTERM" to terminate it.
            let proc_status_file = format!("/proc/{}/status", p.pid);
            if p.init && sig == libc::SIGTERM && !is_signal_handled(&proc_status_file, sig as u32) {
                sig = libc::SIGKILL;
            }
            p.signal(sig)?;

            if p.init && sig == libc::SIGKILL {
                let ctr = sandbox
                    .get_container(&cid)
                    .ok_or_else(|| anyhow!("Invalid container id"))?;
                let fifo_file = format!("{}/{}", &ctr.root, EXEC_FIFO_FILENAME);
                unistd::unlink(fifo_file.as_str())?;
            }
        }

        if eid.is_empty() {
            // eid is empty, signal all the remaining processes in the container cgroup
            info!(
                sl!(),
                "signal all the remaining processes cid: {} eid: {}", cid, eid
            );

            if let Err(err) = self.freeze_cgroup(&cid, FreezerState::Frozen).await {
                warn!(
                    sl!(),
                    "freeze cgroup failed";
                    "container-id" => cid.clone(),
                    "exec-id" => eid.clone(),
                    "error" => format!("{:?}", err),
                );
            }

            let pids = self.get_pids(&cid).await?;
            for pid in pids.iter() {
                let res = unsafe { libc::kill(*pid, sig) };
                if let Err(err) = Errno::result(res).map(drop) {
                    warn!(
                        sl!(),
                        "signal failed";
                        "container-id" => cid.clone(),
                        "exec-id" => eid.clone(),
                        "pid" => pid,
                        "error" => format!("{:?}", err),
                    );
                }
            }
            if let Err(err) = self.freeze_cgroup(&cid, FreezerState::Thawed).await {
                warn!(
                    sl!(),
                    "unfreeze cgroup failed";
                    "container-id" => cid.clone(),
                    "exec-id" => eid.clone(),
                    "error" => format!("{:?}", err),
                );
            }
        }
        Ok(())
    }

    async fn freeze_cgroup(&self, cid: &str, state: FreezerState) -> Result<()> {
        let s = self.sandbox.clone();
        let mut sandbox = s.lock().await;
        let ctr = sandbox
            .get_container(cid)
            .ok_or_else(|| anyhow!("Invalid container id {}", cid))?;
        let cm = ctr
            .cgroup_manager
            .as_ref()
            .ok_or_else(|| anyhow!("cgroup manager not exist"))?;
        cm.freeze(state)?;
        Ok(())
    }

    async fn get_pids(&self, cid: &str) -> Result<Vec<i32>> {
        let s = self.sandbox.clone();
        let mut sandbox = s.lock().await;
        let ctr = sandbox
            .get_container(cid)
            .ok_or_else(|| anyhow!("Invalid container id {}", cid))?;
        let cm = ctr
            .cgroup_manager
            .as_ref()
            .ok_or_else(|| anyhow!("cgroup manager not exist"))?;
        let pids = cm.get_pids()?;
        Ok(pids)
    }

    #[instrument]
    async fn do_wait_process(
        &self,
        req: protocols::agent::WaitProcessRequest,
    ) -> Result<protocols::agent::WaitProcessResponse> {
        let total_start = Instant::now();
        let cid = req.container_id.clone();
        let eid = req.exec_id;
        let s = self.sandbox.clone();
        let mut resp = WaitProcessResponse::new();
        let pid: pid_t;

        let (exit_send, mut exit_recv) = tokio::sync::mpsc::channel(100);

        info!(sl!(), "wait process cid: {} eid: {}", cid, eid);

        let find_start = Instant::now();
        let exit_rx = {
            let mut sandbox = s.lock().await;
            if let Some(container) = sandbox.get_container(&cid) {
                check_container_resource_operation(container, ContainerResourceOperation::Wait)?;
            }
            let p = sandbox.find_container_process(cid.as_str(), eid.as_str())?;

            p.exit_watchers.push(exit_send.clone());
            if p.exited {
                let _ = exit_send.try_send(p.exit_code);
            }
            pid = p.pid;

            p.exit_rx.clone()
        };
        let find_ms = find_start.elapsed().as_millis();

        let wait_exit_start = Instant::now();
        if let Some(mut exit_rx) = exit_rx {
            while exit_rx.changed().await.is_ok() {}
            info!(sl!(), "process exited cid: {} eid: {}", &cid, &eid);
        }
        let wait_exit_ms = wait_exit_start.elapsed().as_millis();

        let relock_start = Instant::now();
        let mut sandbox = s.lock().await;
        let ctr = sandbox
            .get_container(&cid)
            .ok_or_else(|| anyhow!("Invalid container id"))?;
        let relock_ms = relock_start.elapsed().as_millis();

        let (status, cleanup_ms, notify_ms) = match ctr.processes.get_mut(&pid) {
            Some(p) => {
                let cleanup_start = Instant::now();
                // need to close all fd
                // ignore errors for some fd might be closed by stream
                p.cleanup_process_stream();
                let cleanup_ms = cleanup_start.elapsed().as_millis();

                let status = p.exit_code;
                resp.status = status;
                let notify_start = Instant::now();
                // broadcast exit code to all parallel watchers
                for s in p.exit_watchers.iter_mut() {
                    // Just ignore errors in case any watcher quits unexpectedly
                    let _ = s.send(p.exit_code).await;
                }
                let notify_ms = notify_start.elapsed().as_millis();

                (status, cleanup_ms, notify_ms)
            }
            None => {
                // Lost race, pick up exit code from channel
                let recv_start = Instant::now();
                resp.status = exit_recv
                    .recv()
                    .await
                    .ok_or_else(|| anyhow!("Failed to receive exit code"))?;
                info!(
                    sl!(),
                    "wait process summary cid: {} eid: {} pid: {} status: {} missing_process: true find_ms: {} wait_exit_ms: {} relock_ms: {} exit_recv_ms: {} total_ms: {}",
                    cid,
                    eid,
                    pid,
                    resp.status,
                    find_ms,
                    wait_exit_ms,
                    relock_ms,
                    recv_start.elapsed().as_millis(),
                    total_start.elapsed().as_millis()
                );

                return Ok(resp);
            }
        };

        let remove_start = Instant::now();
        ctr.processes.remove(&pid);
        let remove_ms = remove_start.elapsed().as_millis();

        info!(
            sl!(),
            "wait process summary cid: {} eid: {} pid: {} status: {} missing_process: false find_ms: {} wait_exit_ms: {} relock_ms: {} cleanup_ms: {} notify_ms: {} remove_ms: {} total_ms: {}",
            cid,
            eid,
            pid,
            status,
            find_ms,
            wait_exit_ms,
            relock_ms,
            cleanup_ms,
            notify_ms,
            remove_ms,
            total_start.elapsed().as_millis()
        );

        Ok(resp)
    }

    async fn do_write_stream(
        &self,
        req: protocols::agent::WriteStreamRequest,
    ) -> Result<protocols::agent::WriteStreamResponse> {
        let cid = req.container_id.clone();
        let eid = req.exec_id.clone();

        let writer = {
            let s = self.sandbox.clone();
            let mut sandbox = s.lock().await;
            let p = sandbox.find_container_process(cid.as_str(), eid.as_str())?;

            // use ptmx io
            if p.term_master.is_some() {
                p.get_writer(StreamType::TermMaster)
            } else {
                // use piped io
                p.get_writer(StreamType::ParentStdin)
            }
        };

        let writer = writer.ok_or_else(|| anyhow!(ERR_CANNOT_GET_WRITER))?;
        writer.lock().await.write_all(req.data.as_slice()).await?;

        let mut resp = WriteStreamResponse::new();
        resp.set_len(req.data.len() as u32);

        Ok(resp)
    }

    async fn do_read_stream(
        &self,
        req: protocols::agent::ReadStreamRequest,
        stdout: bool,
    ) -> Result<protocols::agent::ReadStreamResponse> {
        let cid = req.container_id;
        let eid = req.exec_id;

        let mut term_exit_notifier = Arc::new(tokio::sync::Notify::new());
        let reader = {
            let s = self.sandbox.clone();
            let mut sandbox = s.lock().await;

            let p = sandbox.find_container_process(cid.as_str(), eid.as_str())?;

            if p.term_master.is_some() {
                term_exit_notifier = p.term_exit_notifier.clone();
                p.get_reader(StreamType::TermMaster)
            } else if stdout {
                if p.parent_stdout.is_some() {
                    p.get_reader(StreamType::ParentStdout)
                } else {
                    None
                }
            } else {
                p.get_reader(StreamType::ParentStderr)
            }
        };

        if reader.is_none() {
            return Err(anyhow!(nix::Error::EINVAL));
        }

        let reader = reader.ok_or_else(|| anyhow!("cannot get stream reader"))?;

        tokio::select! {
            _ = term_exit_notifier.notified() => {
                Err(anyhow!("eof"))
            }
            v = read_stream(reader, req.len as usize)  => {
                let vector = v?;
                let mut resp = ReadStreamResponse::new();
                resp.set_data(vector);

                Ok(resp)
            }
        }
    }
}

#[async_trait]
impl protocols::agent_ttrpc::AgentService for AgentService {
    async fn create_container(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::CreateContainerRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "create_container", req);
        is_allowed!(req);
        match self.do_create_container(req).await {
            Err(e) => Err(ttrpc_error!(ttrpc::Code::INTERNAL, e)),
            Ok(_) => Ok(Empty::new()),
        }
    }

    async fn start_container(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::StartContainerRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "start_container", req);
        is_allowed!(req);
        match self.do_start_container(req).await {
            Err(e) => Err(ttrpc_error!(runtime_operation_error_code(&e), e)),
            Ok(_) => Ok(Empty::new()),
        }
    }

    async fn remove_container(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::RemoveContainerRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "remove_container", req);
        is_allowed!(req);

        match self.do_remove_container(req).await {
            Err(e) => Err(ttrpc_error!(ttrpc::Code::INTERNAL, e)),
            Ok(_) => Ok(Empty::new()),
        }
    }

    async fn exec_process(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::ExecProcessRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "exec_process", req);
        is_allowed!(req);
        match self.do_exec_process(req).await {
            Err(e) => Err(ttrpc_error!(runtime_operation_error_code(&e), e)),
            Ok(_) => Ok(Empty::new()),
        }
    }

    async fn signal_process(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::SignalProcessRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "signal_process", req);
        is_allowed!(req);
        match self.do_signal_process(req).await {
            Err(e) => Err(ttrpc_error!(ttrpc::Code::INTERNAL, e)),
            Ok(_) => Ok(Empty::new()),
        }
    }

    async fn wait_process(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::WaitProcessRequest,
    ) -> ttrpc::Result<WaitProcessResponse> {
        trace_rpc_call!(ctx, "wait_process", req);
        is_allowed!(req);
        self.do_wait_process(req)
            .await
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))
    }

    async fn update_container(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::UpdateContainerRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "update_container", req);
        is_allowed!(req);
        let cid = req.container_id.clone();
        let res = req.resources;
        let s = Arc::clone(&self.sandbox);
        let mut sandbox = lock_container_state(&s, SerializedContainerOperation::Update).await;

        let ctr = sandbox.get_container(&cid).ok_or_else(|| {
            ttrpc_error!(
                ttrpc::Code::INVALID_ARGUMENT,
                "invalid container id".to_string(),
            )
        })?;

        let resp = Empty::new();

        if let Some(res) = res.as_ref() {
            let (oci_res, resources_v2_canonical) =
                prepare_container_resource_update(res, || ctr.recover_resources_v2())?;
            let result = if resources_v2_canonical.is_some() {
                ctr.set_resources_v2(oci_res).map_err(anyhow::Error::from)
            } else {
                ctr.set(oci_res)
            };
            match result {
                Err(e) => {
                    let code = update_container_error_code(&e);
                    return Err(ttrpc_error!(code, e));
                }

                Ok(_) => return Ok(resp),
            }
        }

        Ok(resp)
    }

    async fn stats_container(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::StatsContainerRequest,
    ) -> ttrpc::Result<StatsContainerResponse> {
        trace_rpc_call!(ctx, "stats_container", req);
        is_allowed!(req);
        let cid = req.container_id;
        let s = Arc::clone(&self.sandbox);
        let mut sandbox = lock_container_state(&s, SerializedContainerOperation::Stats).await;

        let ctr = sandbox.get_container(&cid).ok_or_else(|| {
            ttrpc_error!(
                ttrpc::Code::INVALID_ARGUMENT,
                "invalid container id".to_string(),
            )
        })?;

        check_container_resource_operation(ctr, ContainerResourceOperation::Stats)
            .map_err(|error| ttrpc_error!(runtime_operation_error_code(&error), error))?;

        ctr.stats()
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))
    }

    async fn pause_container(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::PauseContainerRequest,
    ) -> ttrpc::Result<protocols::empty::Empty> {
        trace_rpc_call!(ctx, "pause_container", req);
        is_allowed!(req);
        let cid = req.container_id();
        let s = Arc::clone(&self.sandbox);
        let mut sandbox = s.lock().await;

        let ctr = sandbox.get_container(cid).ok_or_else(|| {
            ttrpc_error!(
                ttrpc::Code::INVALID_ARGUMENT,
                "invalid container id".to_string(),
            )
        })?;

        ctr.pause()
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        Ok(Empty::new())
    }

    async fn resume_container(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::ResumeContainerRequest,
    ) -> ttrpc::Result<protocols::empty::Empty> {
        trace_rpc_call!(ctx, "resume_container", req);
        is_allowed!(req);
        let cid = req.container_id();
        let s = Arc::clone(&self.sandbox);
        let mut sandbox = s.lock().await;

        let ctr = sandbox.get_container(cid).ok_or_else(|| {
            ttrpc_error!(
                ttrpc::Code::INVALID_ARGUMENT,
                "invalid container id".to_string(),
            )
        })?;

        ctr.resume()
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        Ok(Empty::new())
    }

    async fn write_stdin(
        &self,
        _ctx: &TtrpcContext,
        req: protocols::agent::WriteStreamRequest,
    ) -> ttrpc::Result<WriteStreamResponse> {
        is_allowed!(req);
        self.do_write_stream(req)
            .await
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))
    }

    async fn read_stdout(
        &self,
        _ctx: &TtrpcContext,
        req: protocols::agent::ReadStreamRequest,
    ) -> ttrpc::Result<ReadStreamResponse> {
        is_allowed!(req);
        self.do_read_stream(req, true)
            .await
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))
    }

    async fn read_stderr(
        &self,
        _ctx: &TtrpcContext,
        req: protocols::agent::ReadStreamRequest,
    ) -> ttrpc::Result<ReadStreamResponse> {
        is_allowed!(req);
        self.do_read_stream(req, false)
            .await
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))
    }

    async fn close_stdin(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::CloseStdinRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "close_stdin", req);
        is_allowed!(req);

        let cid = req.container_id.clone();
        let eid = req.exec_id;
        let s = Arc::clone(&self.sandbox);
        let mut sandbox = s.lock().await;

        let p = sandbox
            .find_container_process(cid.as_str(), eid.as_str())
            .map_err(|e| {
                ttrpc_error!(
                    ttrpc::Code::INVALID_ARGUMENT,
                    format!("invalid argument: {:?}", e),
                )
            })?;

        p.close_stdin().await;

        Ok(Empty::new())
    }

    async fn tty_win_resize(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::TtyWinResizeRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "tty_win_resize", req);
        is_allowed!(req);

        let cid = req.container_id.clone();
        let eid = req.exec_id.clone();
        let s = Arc::clone(&self.sandbox);
        let mut sandbox = s.lock().await;
        let p = sandbox
            .find_container_process(cid.as_str(), eid.as_str())
            .map_err(|e| {
                ttrpc_error!(
                    ttrpc::Code::UNAVAILABLE,
                    format!("invalid argument: {:?}", e),
                )
            })?;

        if let Some(fd) = p.term_master {
            unsafe {
                let win = winsize {
                    ws_row: req.row as c_ushort,
                    ws_col: req.column as c_ushort,
                    ws_xpixel: 0,
                    ws_ypixel: 0,
                };

                let err = libc::ioctl(fd, TIOCSWINSZ, &win);
                Errno::result(err).map(drop).map_err(|e| {
                    ttrpc_error!(ttrpc::Code::INTERNAL, format!("ioctl error: {:?}", e))
                })?;
            }
        } else {
            return Err(ttrpc_error!(ttrpc::Code::UNAVAILABLE, "no tty".to_string()));
        }

        Ok(Empty::new())
    }

    async fn reconnect_container_io(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::ReconnectContainerIORequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "reconnect_container_io", req);
        is_allowed!(req);
        match self.do_reconnect_container_io(req).await {
            Err(e) => Err(ttrpc_error!(ttrpc::Code::INTERNAL, e)),
            Ok(_) => Ok(Empty::new()),
        }
    }

    async fn update_interface(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::UpdateInterfaceRequest,
    ) -> ttrpc::Result<Interface> {
        trace_rpc_call!(ctx, "update_interface", req);
        is_allowed!(req);

        let interface = req.interface.into_option().ok_or_else(|| {
            ttrpc_error!(
                ttrpc::Code::INVALID_ARGUMENT,
                "empty update interface request".to_string(),
            )
        })?;

        self.sandbox
            .lock()
            .await
            .rtnl
            .update_interface(&interface)
            .await
            .map_err(|e| {
                ttrpc_error!(ttrpc::Code::INTERNAL, format!("update interface: {:?}", e))
            })?;

        Ok(interface)
    }

    async fn update_routes(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::UpdateRoutesRequest,
    ) -> ttrpc::Result<Routes> {
        trace_rpc_call!(ctx, "update_routes", req);
        is_allowed!(req);

        let new_routes = req
            .routes
            .into_option()
            .map(|r| r.Routes.to_vec())
            .ok_or_else(|| {
                ttrpc_error!(
                    ttrpc::Code::INVALID_ARGUMENT,
                    "empty update routes request".to_string(),
                )
            })?;

        let mut sandbox = self.sandbox.lock().await;

        sandbox.rtnl.update_routes(new_routes).await.map_err(|e| {
            ttrpc_error!(
                ttrpc::Code::INTERNAL,
                format!("Failed to update routes: {:?}", e),
            )
        })?;

        let list = sandbox.rtnl.list_routes().await.map_err(|e| {
            ttrpc_error!(
                ttrpc::Code::INTERNAL,
                format!("Failed to list routes after update: {:?}", e),
            )
        })?;

        Ok(protocols::agent::Routes {
            Routes: list,
            ..Default::default()
        })
    }

    async fn get_ip_tables(
        &self,
        ctx: &TtrpcContext,
        req: GetIPTablesRequest,
    ) -> ttrpc::Result<GetIPTablesResponse> {
        trace_rpc_call!(ctx, "get_iptables", req);
        is_allowed!(req);

        info!(sl!(), "get_ip_tables: request received");

        let cmd = if req.is_ipv6 {
            IP6TABLES_SAVE
        } else {
            IPTABLES_SAVE
        }
        .to_string();

        match Command::new(cmd.clone()).output() {
            Ok(output) => Ok(GetIPTablesResponse {
                data: output.stdout,
                ..Default::default()
            }),
            Err(e) => {
                warn!(sl!(), "failed to run {}: {:?}", cmd, e.kind());
                return Err(ttrpc_error!(ttrpc::Code::INTERNAL, e));
            }
        }
    }

    async fn set_ip_tables(
        &self,
        ctx: &TtrpcContext,
        req: SetIPTablesRequest,
    ) -> ttrpc::Result<SetIPTablesResponse> {
        trace_rpc_call!(ctx, "set_iptables", req);
        is_allowed!(req);

        info!(sl!(), "set_ip_tables request received");

        let cmd = if req.is_ipv6 {
            IP6TABLES_RESTORE
        } else {
            IPTABLES_RESTORE
        }
        .to_string();

        let mut child = match Command::new(cmd.clone())
            .arg("--wait")
            .arg(IPTABLES_RESTORE_WAIT_SEC.to_string())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(child) => child,
            Err(e) => {
                warn!(sl!(), "failure to spawn {}: {:?}", cmd, e.kind());
                return Err(ttrpc_error!(ttrpc::Code::INTERNAL, e));
            }
        };

        let mut stdin = match child.stdin.take() {
            Some(si) => si,
            None => {
                println!("failed to get stdin from child");
                return Err(ttrpc_error!(
                    ttrpc::Code::INTERNAL,
                    "failed to take stdin from child".to_string()
                ));
            }
        };

        let (tx, rx) = tokio::sync::oneshot::channel::<i32>();
        let handle = tokio::spawn(async move {
            let _ = match stdin.write_all(&req.data) {
                Ok(o) => o,
                Err(e) => {
                    warn!(sl!(), "error writing stdin: {:?}", e.kind());
                    return;
                }
            };
            if tx.send(1).is_err() {
                warn!(sl!(), "stdin writer thread receiver dropped");
            };
        });

        if tokio::time::timeout(Duration::from_secs(IPTABLES_RESTORE_WAIT_SEC), rx)
            .await
            .is_err()
        {
            return Err(ttrpc_error!(
                ttrpc::Code::INTERNAL,
                "timeout waiting for stdin writer to complete".to_string()
            ));
        }

        if handle.await.is_err() {
            return Err(ttrpc_error!(
                ttrpc::Code::INTERNAL,
                "stdin writer thread failure".to_string()
            ));
        }

        let output = match child.wait_with_output() {
            Ok(o) => o,
            Err(e) => {
                warn!(
                    sl!(),
                    "failure waiting for spawned {} to complete: {:?}",
                    cmd,
                    e.kind()
                );
                return Err(ttrpc_error!(ttrpc::Code::INTERNAL, e));
            }
        };

        if !output.status.success() {
            warn!(sl!(), "{} failed: {:?}", cmd, output.stderr);
            return Err(ttrpc_error!(
                ttrpc::Code::INTERNAL,
                format!(
                    "{} failed: {:?}",
                    cmd,
                    String::from_utf8_lossy(&output.stderr)
                )
            ));
        }

        Ok(SetIPTablesResponse {
            data: output.stdout,
            ..Default::default()
        })
    }

    async fn list_interfaces(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::ListInterfacesRequest,
    ) -> ttrpc::Result<Interfaces> {
        trace_rpc_call!(ctx, "list_interfaces", req);
        is_allowed!(req);

        let list = self
            .sandbox
            .lock()
            .await
            .rtnl
            .list_interfaces()
            .await
            .map_err(|e| {
                ttrpc_error!(
                    ttrpc::Code::INTERNAL,
                    format!("Failed to list interfaces: {:?}", e),
                )
            })?;

        Ok(protocols::agent::Interfaces {
            Interfaces: list,
            ..Default::default()
        })
    }

    async fn list_routes(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::ListRoutesRequest,
    ) -> ttrpc::Result<Routes> {
        trace_rpc_call!(ctx, "list_routes", req);
        is_allowed!(req);

        let list = self
            .sandbox
            .lock()
            .await
            .rtnl
            .list_routes()
            .await
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, format!("list routes: {:?}", e)))?;

        Ok(protocols::agent::Routes {
            Routes: list,
            ..Default::default()
        })
    }

    async fn create_sandbox(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::CreateSandboxRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "create_sandbox", req);
        is_allowed!(req);
        info!(sl!(), "receive create sandbox");
        let mut start = Instant::now();

        if req.start_mode == protocols::agent::StartMode::RESTORE.into() {
            match add_virtiofs_storages(sl!(), req.storages.to_vec()).await {
                Ok(_) => {}
                Err(e) => {
                    error!(sl!(), "add storages failed:{:?}", e);
                    return Err(ttrpc_error!(
                        ttrpc::Code::INTERNAL,
                        format!("add storages failed:{:?}", e)
                    ));
                }
            };
            let duration_storage = start.elapsed().as_millis();
            info!(sl!(), "create sandbox!, add storage:{}ms", duration_storage);
            return Ok(Empty::new());
        }

        if req.cube_mvm_monitor {
            do_enable_cube_mvm_monitor()
                .await
                .map_err(|e| {
                    error!(sl!(), "enable cube mvm monitor failed, {:}", e);
                })
                .ok();
        }

        {
            let interfaces = req.interfaces.to_vec();
            for i in interfaces {
                if !i.pciPath.is_empty() {
                    let sandbox = self.sandbox.clone();
                    let pcipath = pci::Path::from_str(i.pciPath.as_str()).map_err(|e| {
                        ttrpc_error!(
                            ttrpc::Code::INTERNAL,
                            format!("pci::Path::from_str failed, pciPath:{},{}", i.pciPath, e)
                        )
                    })?;
                    let addr = wait_for_pci_net(&sandbox, &pcipath).await.map_err(|e| {
                        ttrpc_error!(
                            ttrpc::Code::INTERNAL,
                            format!("Failed to wait pci: {:?}", e)
                        )
                    })?;
                    info!(sl!(), "wait a pci:{:}", addr)
                }
                self.sandbox
                    .lock()
                    .await
                    .rtnl
                    .update_interface(&i)
                    .await
                    .map_err(|e| {
                        ttrpc_error!(
                            ttrpc::Code::INTERNAL,
                            format!("Failed to update interface: {:?}", e)
                        )
                    })?;
            }
        }

        {
            let routes = req.routes.to_vec();
            self.sandbox
                .lock()
                .await
                .rtnl
                .update_routes(routes)
                .await
                .map_err(|e| {
                    ttrpc_error!(
                        ttrpc::Code::INTERNAL,
                        format!("Failed to update routes: {:?}", e),
                    )
                })?;
        }

        {
            let arps = req.ARPNeighbors.to_vec();
            self.sandbox
                .lock()
                .await
                .rtnl
                .add_arp_neighbors(arps)
                .await
                .map_err(|e| {
                    ttrpc_error!(
                        ttrpc::Code::INTERNAL,
                        format!("Failed to add ARP neighbours: {:?}", e),
                    )
                })?;
        }
        let duration_net = start.elapsed().as_millis();

        {
            let sandbox = self.sandbox.clone();
            let mut s = sandbox.lock().await;

            let _ = fs::remove_dir_all(CONTAINER_BASE);
            let _ = fs::create_dir_all(CONTAINER_BASE);
            let _ = fs::create_dir_all(RUNTIME_SHARE);

            s.hostname = req.hostname.clone();
            s.running = true;

            if !req.sandbox_id.is_empty() {
                s.id = req.sandbox_id.clone();
            }

            s.setup_shared_namespaces(req.sandbox_pidns())
                .await
                .map_err(|e| {
                    ttrpc_error!(
                        ttrpc::Code::INTERNAL,
                        format!("setup shared namespaces failed:{:?}", e)
                    )
                })?;
        }
        debug!(sl!(), "add storage:{:?}", req.storages.to_vec());
        start = Instant::now();
        match add_storages(sl!(), req.storages.to_vec(), self.sandbox.clone(), None).await {
            Ok(m) => {
                let sandbox = self.sandbox.clone();
                let mut s = sandbox.lock().await;
                s.mounts = m
            }
            Err(e) => {
                return Err(ttrpc_error!(
                    ttrpc::Code::INTERNAL,
                    format!("add storages failed:{:?}", e)
                ))
            }
        };
        let duration_storage = start.elapsed().as_millis();
        start = Instant::now();

        match std::fs::write(PROC_PATH_NFS_CLIENT_IDENT, req.sandbox_id) {
            Ok(_) => {}
            Err(e) => error!(sl!(), "config nfs client identifier failed:{:}", e),
        }
        let duration_proc = start.elapsed().as_millis();
        match setup_guest_dns(sl!(), req.dns.to_vec()) {
            Ok(_) => {
                let sandbox = self.sandbox.clone();
                let mut s = sandbox.lock().await;
                let _dns = req
                    .dns
                    .to_vec()
                    .iter()
                    .map(|dns| s.network.set_dns(dns.to_string()));
            }
            Err(e) => {
                return Err(ttrpc_error!(
                    ttrpc::Code::INTERNAL,
                    format!("setup dns failed:{:?}", e)
                ))
            }
        };

        info!(
            sl!(),
            "create sandbox!, config net:{}ms, add storage:{}ms, write proc:{}ms",
            duration_net,
            duration_storage,
            duration_proc,
        );

        Ok(Empty::new())
    }

    async fn destroy_sandbox(
        &self,
        _: &TtrpcContext,
        _: protocols::agent::DestroySandboxRequest,
    ) -> ttrpc::Result<Empty> {
        info!(sl!(), "receive destroy sandbox");

        let s = Arc::clone(&self.sandbox);
        let mut sandbox = s.lock().await;

        sandbox
            .sender
            .take()
            .ok_or_else(|| {
                ttrpc_error!(
                    ttrpc::Code::INTERNAL,
                    "failed to get sandbox sender channel".to_string(),
                )
            })?
            .send(1)
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        Ok(Empty::new())
    }

    async fn add_arp_neighbors(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::AddARPNeighborsRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "add_arp_neighbors", req);
        is_allowed!(req);

        let neighs = req
            .neighbors
            .into_option()
            .map(|n| n.ARPNeighbors.to_vec())
            .ok_or_else(|| {
                ttrpc_error!(
                    ttrpc::Code::INVALID_ARGUMENT,
                    "empty add arp neighbours request".to_string(),
                )
            })?;

        self.sandbox
            .lock()
            .await
            .rtnl
            .add_arp_neighbors(neighs)
            .await
            .map_err(|e| {
                ttrpc_error!(
                    ttrpc::Code::INTERNAL,
                    format!("Failed to add ARP neighbours: {:?}", e),
                )
            })?;

        Ok(Empty::new())
    }

    async fn online_cpu_mem(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::OnlineCPUMemRequest,
    ) -> ttrpc::Result<Empty> {
        is_allowed!(req);
        let s = Arc::clone(&self.sandbox);
        let sandbox = s.lock().await;
        trace_rpc_call!(ctx, "online_cpu_mem", req);

        sandbox
            .online_cpu_memory(&req)
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        Ok(Empty::new())
    }

    async fn reseed_random_dev(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::ReseedRandomDevRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "reseed_random_dev", req);
        is_allowed!(req);

        random::reseed_rng(req.data.as_slice())
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        Ok(Empty::new())
    }

    async fn get_guest_details(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::GuestDetailsRequest,
    ) -> ttrpc::Result<GuestDetailsResponse> {
        trace_rpc_call!(ctx, "get_guest_details", req);
        is_allowed!(req);

        debug!(sl!(), "get guest details!");
        let mut resp = GuestDetailsResponse::new();
        // to get memory block size
        match get_memory_info(
            req.mem_block_size,
            req.mem_hotplug_probe,
            SYSFS_MEMORY_BLOCK_SIZE_PATH,
            SYSFS_MEMORY_HOTPLUG_PROBE_PATH,
        ) {
            Ok((u, v)) => {
                resp.mem_block_size_bytes = u;
                resp.support_mem_hotplug_probe = v;
            }
            Err(e) => {
                info!(sl!(), "fail to get memory info!");
                return Err(ttrpc_error!(ttrpc::Code::INTERNAL, e));
            }
        }

        // to get agent details
        let detail = get_agent_details();
        resp.agent_details = MessageField::some(detail);

        Ok(resp)
    }

    async fn mem_hotplug_by_probe(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::MemHotplugByProbeRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "mem_hotplug_by_probe", req);
        is_allowed!(req);

        do_mem_hotplug_by_probe(&req.memHotplugProbeAddr)
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        Ok(Empty::new())
    }

    async fn set_guest_date_time(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::SetGuestDateTimeRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "set_guest_date_time", req);
        is_allowed!(req);

        do_set_guest_date_time(req.Sec, req.Usec)
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        Ok(Empty::new())
    }

    async fn copy_file(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::CopyFileRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "copy_file", req);
        is_allowed!(req);

        do_copy_file(&req).map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        Ok(Empty::new())
    }

    async fn get_metrics(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::GetMetricsRequest,
    ) -> ttrpc::Result<Metrics> {
        trace_rpc_call!(ctx, "get_metrics", req);
        is_allowed!(req);

        match get_metrics(&req) {
            Err(e) => Err(ttrpc_error!(ttrpc::Code::INTERNAL, e)),
            Ok(s) => {
                let mut metrics = Metrics::new();
                metrics.set_metrics(s);
                Ok(metrics)
            }
        }
    }

    async fn get_oom_event(
        &self,
        _ctx: &TtrpcContext,
        req: protocols::agent::GetOOMEventRequest,
    ) -> ttrpc::Result<OOMEvent> {
        is_allowed!(req);
        let mut rx = {
            let sandbox = self.sandbox.clone();
            let s = sandbox.lock().await;
            if s.event_tx.is_none() {
                return Err(ttrpc_error!(ttrpc::Code::INTERNAL, ""));
            }

            let rx = s.event_tx.as_ref().unwrap().subscribe();
            rx
        };

        if let Ok(container_id) = rx.recv().await {
            info!(sl!(), "get_oom_event return {}", &container_id);

            let mut resp = OOMEvent::new();
            resp.container_id = container_id;

            return Ok(resp);
        }

        Err(ttrpc_error!(ttrpc::Code::INTERNAL, ""))
    }

    async fn get_volume_stats(
        &self,
        ctx: &TtrpcContext,
        req: VolumeStatsRequest,
    ) -> ttrpc::Result<VolumeStatsResponse> {
        trace_rpc_call!(ctx, "get_volume_stats", req);
        is_allowed!(req);

        info!(sl!(), "get volume stats!");
        let mut resp = VolumeStatsResponse::new();

        let mut condition = VolumeCondition::new();

        match File::open(&req.volume_guest_path) {
            Ok(_) => {
                condition.abnormal = false;
                condition.message = String::from("OK");
            }
            Err(e) => {
                info!(sl!(), "failed to open the volume");
                return Err(ttrpc_error!(ttrpc::Code::INTERNAL, e));
            }
        };

        let mut usage_vec = Vec::new();

        // to get volume capacity stats
        get_volume_capacity_stats(&req.volume_guest_path)
            .map(|u| usage_vec.push(u))
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        // to get volume inode stats
        get_volume_inode_stats(&req.volume_guest_path)
            .map(|u| usage_vec.push(u))
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        resp.usage = usage_vec;
        resp.volume_condition = MessageField::some(condition);
        Ok(resp)
    }

    async fn add_swap(
        &self,
        ctx: &TtrpcContext,
        req: protocols::agent::AddSwapRequest,
    ) -> ttrpc::Result<Empty> {
        trace_rpc_call!(ctx, "add_swap", req);
        is_allowed!(req);

        do_add_swap(&self.sandbox, &req)
            .await
            .map_err(|e| ttrpc_error!(ttrpc::Code::INTERNAL, e))?;

        Ok(Empty::new())
    }
}

const AGENT_PROTOCOL_VERSION: u32 = 1;
const AGENT_CAPABILITIES: &[(&str, u32)] = &[
    ("io.cubesandbox.agent.sandbox.lifecycle", 1),
    ("io.cubesandbox.agent.container.lifecycle", 1),
    ("io.cubesandbox.agent.container.exec", 1),
    ("io.cubesandbox.agent.container.stats", 1),
    ("io.cubesandbox.agent.sandbox.shared-pidns", 1),
    ("io.cubesandbox.agent.mount.dynamic", 1),
    ("io.cubesandbox.agent.stdio.passfd", 1),
    (rustjail::resources::RESOURCE_V2_CAPABILITY, 1),
];

fn agent_version_response() -> VersionCheckResponse {
    let mut response = VersionCheckResponse::new();
    response.set_agent_version(AGENT_VERSION.to_string());
    response.set_grpc_version(API_VERSION.to_string());
    response.set_protocol_version(AGENT_PROTOCOL_VERSION);
    response.set_capabilities(
        AGENT_CAPABILITIES
            .iter()
            .map(|(name, version)| {
                let mut capability = AgentCapability::new();
                capability.set_name((*name).to_string());
                capability.set_version(*version);
                capability
            })
            .collect(),
    );
    response
}

#[derive(Clone)]
struct HealthService;

#[async_trait]
impl protocols::health_ttrpc::Health for HealthService {
    async fn check(
        &self,
        _ctx: &TtrpcContext,
        _req: protocols::health::CheckRequest,
    ) -> ttrpc::Result<HealthCheckResponse> {
        let mut resp = HealthCheckResponse::new();
        resp.set_status(ServingStatus::SERVING);

        Ok(resp)
    }

    async fn version(
        &self,
        _ctx: &TtrpcContext,
        req: protocols::health::CheckRequest,
    ) -> ttrpc::Result<VersionCheckResponse> {
        info!(sl!(), "version {:?}", req);
        Ok(agent_version_response())
    }
}

fn get_memory_info(
    block_size: bool,
    hotplug: bool,
    block_size_path: &str,
    hotplug_probe_path: &str,
) -> Result<(u64, bool)> {
    let mut size: u64 = 0;
    let mut plug: bool = false;
    if block_size {
        match fs::read_to_string(block_size_path) {
            Ok(v) => {
                if v.is_empty() {
                    warn!(sl!(), "file {} is empty", block_size_path);
                    return Err(anyhow!(ERR_INVALID_BLOCK_SIZE));
                }

                size = u64::from_str_radix(v.trim(), 16).map_err(|_| {
                    warn!(sl!(), "failed to parse the str {} to hex", size);
                    anyhow!(ERR_INVALID_BLOCK_SIZE)
                })?;
            }
            Err(e) => {
                warn!(sl!(), "memory block size error: {:?}", e.kind());
                if e.kind() != std::io::ErrorKind::NotFound {
                    return Err(anyhow!(e));
                }
            }
        }
    }

    if hotplug {
        match stat::stat(hotplug_probe_path) {
            Ok(_) => plug = true,
            Err(e) => {
                debug!(sl!(), "hotplug memory error: {:?}", e);
                match e {
                    nix::Error::ENOENT => plug = false,
                    _ => return Err(anyhow!(e)),
                }
            }
        }
    }

    Ok((size, plug))
}

fn get_volume_capacity_stats(path: &str) -> Result<VolumeUsage> {
    let mut usage = VolumeUsage::new();

    let stat = statfs::statfs(path)?;
    let block_size = stat.block_size() as u64;
    usage.total = stat.blocks() * block_size;
    usage.available = stat.blocks_free() * block_size;
    usage.used = usage.total - usage.available;
    usage.unit = volume_usage::Unit::BYTES.into();

    Ok(usage)
}

fn get_volume_inode_stats(path: &str) -> Result<VolumeUsage> {
    let mut usage = VolumeUsage::new();

    let stat = statfs::statfs(path)?;
    usage.total = stat.files();
    usage.available = stat.files_free();
    usage.used = usage.total - usage.available;
    usage.unit = volume_usage::Unit::INODES.into();

    Ok(usage)
}

pub fn have_seccomp() -> bool {
    if cfg!(feature = "seccomp") {
        return true;
    }

    false
}

fn get_agent_details() -> AgentDetails {
    let mut detail = AgentDetails::new();

    detail.set_version(AGENT_VERSION.to_string());
    detail.set_supports_seccomp(have_seccomp());
    detail.init_daemon = unistd::getpid() == Pid::from_raw(1);

    detail.device_handlers = Vec::new();
    detail.storage_handlers = STORAGE_HANDLER_LIST
        .to_vec()
        .iter()
        .map(|x| x.to_string())
        .collect();

    detail
}

async fn read_stream(reader: Arc<Mutex<ReadHalf<PipeStream>>>, l: usize) -> Result<Vec<u8>> {
    let mut content = vec![0u8; l];

    let mut reader = reader.lock().await;
    let len = reader.read(&mut content).await?;
    content.resize(len, 0);

    if len == 0 {
        return Err(anyhow!("read meet eof"));
    }

    Ok(content)
}

pub fn start(s: Arc<Mutex<Sandbox>>, server_address: &str) -> Result<TtrpcServer> {
    let agent_worker = Arc::new(AgentService::new(s));

    let health_worker = Arc::new(HealthService {});

    let aservice = protocols::agent_ttrpc::create_agent_service(agent_worker);

    let hservice = protocols::health_ttrpc::create_health(health_worker);

    let server = TtrpcServer::new()
        .bind(server_address)?
        .register_service(aservice)
        .register_service(hservice);
    println!(
        "ttRPC server started at:{}",
        moniclock::Clock::new().elapsed().as_millis()
    );

    Ok(server)
}

pub fn notify_vsock_server_ready() -> Result<()> {
    #[cfg(target_arch = "x86_64")]
    {
        let port: u16 = 0x680;
        let data: u8 = 0x8;
        let ret = unsafe { libc::ioperm(port as u64, 5, 1) };
        if ret != 0 {
            return Err(anyhow!(
                "ioperm for vsock server ready notify port 0x{:x} failed: {}",
                port,
                std::io::Error::last_os_error()
            ));
        }
        let mut ioport = x86_64::instructions::port::Port::new(port);

        unsafe {
            ioport.write(data);
        }
    }

    #[cfg(target_arch = "aarch64")]
    {
        const SYS_CTRL_MMIO_ADDR: libc::off_t = 0x0903_0000;
        const SYS_CTRL_MMIO_SIZE: usize = 0x1000;
        const SYS_VSOCK_SERVER: u8 = 1 << 3;

        let dev_mem = OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/mem")
            .context("open /dev/mem for sys_ctrl mmio notify")?;
        let map = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                SYS_CTRL_MMIO_SIZE,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                dev_mem.as_raw_fd(),
                SYS_CTRL_MMIO_ADDR,
            )
        };
        if map == libc::MAP_FAILED {
            return Err(anyhow!(
                "mmap sys_ctrl mmio notify addr 0x{:x} failed: {}",
                SYS_CTRL_MMIO_ADDR,
                std::io::Error::last_os_error()
            ));
        }

        unsafe {
            std::ptr::write_volatile(map as *mut u8, SYS_VSOCK_SERVER);
            libc::munmap(map, SYS_CTRL_MMIO_SIZE);
        }
    }

    Ok(())
}

// This function updates the container namespaces configuration based on the
// sandbox information. When the sandbox is created, it can be setup in a way
// that all containers will share some specific namespaces. This is the agent
// responsibility to create those namespaces so that they can be shared across
// several containers.
// If the sandbox has not been setup to share namespaces, then we assume all
// containers will be started in their own new namespace.
// The value of a.sandbox.sharedPidNs.path will always override the namespace
// path set by the spec, since we will always ignore it. Indeed, it makes no
// sense to rely on the namespace path provided by the host since namespaces
// are different inside the guest.
fn update_container_namespaces(
    sandbox: &Sandbox,
    spec: &mut Spec,
    sandbox_pidns: bool,
) -> Result<()> {
    let linux = spec
        .linux
        .as_mut()
        .ok_or_else(|| anyhow!(ERR_NO_LINUX_FIELD))?;

    let namespaces = linux.namespaces.as_mut_slice();
    for namespace in namespaces.iter_mut() {
        if namespace.r#type == NSTYPEIPC {
            namespace.path = sandbox.shared_ipcns.path.clone();
            continue;
        }
        if namespace.r#type == NSTYPEUTS {
            namespace.path = sandbox.shared_utsns.path.clone();
            continue;
        }
    }
    // update pid namespace
    let mut pid_ns = LinuxNamespace {
        r#type: NSTYPEPID.to_string(),
        ..Default::default()
    };

    // Use shared pid ns if useSandboxPidns has been set in either
    // the create_sandbox request or create_container request.
    // Else set this to empty string so that a new pid namespace is
    // created for the container.
    if sandbox_pidns {
        if let Some(ref pidns) = &sandbox.sandbox_pidns {
            pid_ns.path = String::from(pidns.path.as_str());
        } else {
            return Err(anyhow!(ERR_NO_SANDBOX_PIDNS));
        }
    }

    linux.namespaces.push(pid_ns);
    Ok(())
}

fn append_guest_hooks(s: &Sandbox, oci: &mut Spec) -> Result<()> {
    if let Some(ref guest_hooks) = s.hooks {
        let mut hooks = oci.hooks.take().unwrap_or_default();
        hooks.prestart.append(&mut guest_hooks.prestart.clone());
        hooks.poststart.append(&mut guest_hooks.poststart.clone());
        hooks.poststop.append(&mut guest_hooks.poststop.clone());
        oci.hooks = Some(hooks);
    }

    Ok(())
}

// Check if the container process installed the
// handler for specific signal.
fn is_signal_handled(proc_status_file: &str, signum: u32) -> bool {
    let shift_count: u64 = if signum == 0 {
        // signum 0 is used to check for process liveness.
        // Since that signal is not part of the mask in the file, we only need
        // to know if the file (and therefore) process exists to handle
        // that signal.
        return fs::metadata(proc_status_file).is_ok();
    } else if signum > 64 {
        // Ensure invalid signum won't break bit shift logic
        warn!(sl!(), "received invalid signum {}", signum);
        return false;
    } else {
        (signum - 1).into()
    };

    // Open the file in read-only mode (ignoring errors).
    let file = match File::open(proc_status_file) {
        Ok(f) => f,
        Err(_) => {
            warn!(sl!(), "failed to open file {}", proc_status_file);
            return false;
        }
    };

    let sig_mask: u64 = 1 << shift_count;
    let reader = BufReader::new(file);

    // read lines start with SigBlk/SigIgn/SigCgt and check any match the signal mask
    reader
        .lines()
        .flatten()
        .filter(|line| {
            line.starts_with("SigBlk:")
                || line.starts_with("SigIgn:")
                || line.starts_with("SigCgt:")
        })
        .any(|line| {
            let mask_vec: Vec<&str> = line.split(':').collect();
            if mask_vec.len() == 2 {
                let sig_str = mask_vec[1].trim();
                if let Ok(sig) = u64::from_str_radix(sig_str, 16) {
                    return sig & sig_mask == sig_mask;
                }
            }
            false
        })
}

fn do_mem_hotplug_by_probe(addrs: &[u64]) -> Result<()> {
    for addr in addrs.iter() {
        fs::write(SYSFS_MEMORY_HOTPLUG_PROBE_PATH, format!("{:#X}", *addr))?;
    }
    Ok(())
}

fn do_set_guest_date_time(sec: i64, usec: i64) -> Result<()> {
    let tv = libc::timeval {
        tv_sec: sec,
        tv_usec: usec,
    };

    let ret = unsafe {
        libc::settimeofday(
            &tv as *const libc::timeval,
            std::ptr::null::<libc::timezone>(),
        )
    };

    Errno::result(ret).map(drop)?;

    Ok(())
}

fn do_copy_file(req: &CopyFileRequest) -> Result<()> {
    let path = PathBuf::from(req.path.as_str());

    if !path.starts_with(CONTAINER_BASE) {
        return Err(anyhow!(nix::Error::EINVAL));
    }

    let parent = path.parent();

    let dir = if let Some(parent) = parent {
        parent.to_path_buf()
    } else {
        PathBuf::from("/")
    };

    fs::create_dir_all(&dir).or_else(|e| {
        if e.kind() != std::io::ErrorKind::AlreadyExists {
            return Err(e);
        }

        Ok(())
    })?;

    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(req.dir_mode))?;

    let mut tmpfile = path.clone();
    tmpfile.set_extension("tmp");

    let file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(&tmpfile)?;

    file.write_all_at(req.data.as_slice(), req.offset as u64)?;
    let st = stat::stat(&tmpfile)?;

    if st.st_size != req.file_size {
        return Ok(());
    }

    file.set_permissions(std::fs::Permissions::from_mode(req.file_mode))?;

    unistd::chown(
        &tmpfile,
        Some(Uid::from_raw(req.uid as u32)),
        Some(Gid::from_raw(req.gid as u32)),
    )?;

    fs::rename(tmpfile, path)?;

    Ok(())
}

async fn do_add_swap(sandbox: &Arc<Mutex<Sandbox>>, req: &AddSwapRequest) -> Result<()> {
    let mut slots = Vec::new();
    for slot in &req.PCIPath {
        slots.push(pci::SlotFn::new(*slot, 0)?);
    }
    let pcipath = pci::Path::new(slots)?;
    let dev_name = get_virtio_blk_pci_device_name(sandbox, &pcipath).await?;

    let c_str = CString::new(dev_name)?;
    let ret = unsafe { libc::swapon(c_str.as_ptr() as *const c_char, 0) };
    if ret != 0 {
        return Err(anyhow!(
            "libc::swapon get error {}",
            io::Error::last_os_error()
        ));
    }

    Ok(())
}

async fn do_enable_cube_mvm_monitor() -> Result<()> {
    const PATH: &str = "/sys/kernel/cube_mon/enabled";
    let mut file = File::options().read(true).write(true).open(PATH)?;
    file.write_all(b"1")?;
    Ok(())
}

// Setup container bundle under CONTAINER_BASE, which is cleaned up
// before removing a container.
// - bundle path is /<CONTAINER_BASE>/<cid>/
// - config.json at /<CONTAINER_BASE>/<cid>/config.json
// - container rootfs bind mounted at /<CONTAINER_BASE>/<cid>/rootfs
// - modify container spec root to point to /<CONTAINER_BASE>/<cid>/rootfs
pub fn setup_bundle(
    cid: &str,
    spec: &mut Spec,
    cust_files: Vec<agent::CustomFile>,
) -> Result<PathBuf> {
    let read_only = requested_rootfs_read_only(spec);
    let lowerdir;
    if let Some(ri_str) = spec.annotations.get(rootfs::ANNOTATION_K_ROOTFS_INFO) {
        info!(sl!(), "annotation rootfs");
        let ri = rootfs::RootfsInfo::new(ri_str).map_err(|e| anyhow!("{}", e))?;

        if ri.pmem_file.is_some() {
            lowerdir = PathBuf::from(ri.pmem_file.unwrap().clone())
                .to_str()
                .unwrap()
                .to_string();
        } else if ri.ero_image.is_some() {
            info!(sl!(), "ero image");
            let mut lower_dirs: Vec<String> = Vec::new();
            let ero_image = ri.ero_image.unwrap();
            for lower in ero_image.lower_dir.iter() {
                let mut dir = PathBuf::from(ero_image.path.clone());
                let low = lower.trim_start_matches('/');
                dir.push(low);
                lower_dirs.push(dir.to_str().unwrap().to_string());
            }
            lowerdir = lower_dirs.join(":");
        } else {
            let mut lower_dirs: Vec<String> = Vec::new();

            if ri.overlay_info.is_none() {
                return Err(anyhow!(format!("overlay info is none")));
            }
            for d in ri.overlay_info.unwrap().virtiofs_lower_dir.iter() {
                lower_dirs.push(d.clone());
            }
            lowerdir = lower_dirs.join(":");
        }
    } else {
        let spec_root = if let Some(sr) = &spec.root {
            sr
        } else {
            return Err(anyhow!(nix::Error::EINVAL));
        };
        lowerdir = spec_root.path.clone();
    }

    let bundle_path = Path::new(CONTAINER_BASE).join(cid);
    let config_path = bundle_path.join("config.json");
    let rootfs_path = bundle_path.join("rootfs");
    let overlay_path = bundle_path.join("overlay");
    let mut work_dir = overlay_path.join("work");
    let mut upper_dir = overlay_path.join("upper");
    let mut opt = fmt::format(format_args!(
        "workdir={},upperdir={},lowerdir={}",
        work_dir.to_str().unwrap(),
        upper_dir.to_str().unwrap(),
        lowerdir,
    ));

    fs::create_dir_all(&rootfs_path)?;
    if let Some(wl_path) = spec.annotations.get(ANNOTATION_K_ROOTFS_WL_PATH) {
        let blk_path = Path::new(wl_path);
        work_dir = blk_path.join("work");
        if let Ok(_) = fs::metadata(work_dir.clone()) {
            warn!(sl!(), "work exists in blk");
        }

        fs::create_dir_all(&work_dir)
            .map_err(|e| anyhow!(e).context("Failed to create work dir for overlayfs"))?;
        upper_dir = blk_path.join("upper");
        if let Ok(_) = fs::metadata(upper_dir.clone()) {
            warn!(sl!(), "upper exists in blk");
        }
        fs::create_dir_all(&upper_dir)
            .map_err(|e| anyhow!(e).context("Failed to create upper dir for overlayfs"))?;
        opt = fmt::format(format_args!(
            "workdir={},upperdir={},lowerdir={}",
            work_dir.to_str().unwrap(),
            upper_dir.to_str().unwrap(),
            lowerdir,
        ));
    } else {
        fs::create_dir_all(&work_dir)
            .map_err(|e| anyhow!(e).context("Failed to create work dir for overlayfs"))?;
        fs::create_dir_all(&upper_dir)
            .map_err(|e| anyhow!(e).context("Failed to create upper dir for overlayfs"))?;
    }
    baremount(
        Path::new("overlay2"),
        &rootfs_path,
        "overlay",
        MsFlags::empty(),
        opt.as_str(),
        &sl!(),
    )
    .map_err(|e| {
        anyhow!(e).context(fmt::format(format_args!(
            "dst:{} opt:{}",
            rootfs_path.to_str().unwrap().to_string(),
            opt
        )))
    })?;
    mount_custom_file(cid, spec, cust_files)?;
    let rootfs_path_name = rootfs_path
        .to_str()
        .ok_or_else(|| anyhow!("failed to convert rootfs to unicode"))?
        .to_string();

    spec.root = Some(Root {
        path: rootfs_path_name,
        readonly: read_only,
    });

    let _ = spec.save(
        config_path
            .to_str()
            .ok_or_else(|| anyhow!("cannot convert path to unicode"))?,
    );

    let olddir = unistd::getcwd().context("cannot getcwd")?;
    unistd::chdir(
        bundle_path
            .to_str()
            .ok_or_else(|| anyhow!("cannot convert bundle path to unicode"))?,
    )?;

    Ok(olddir)
}

fn requested_rootfs_read_only(spec: &Spec) -> bool {
    if spec.annotations.contains_key(ANNOTATION_K_ROOTFS_WL_PATH) {
        return false;
    }
    spec.root.as_ref().map(|root| root.readonly).unwrap_or(true)
}

pub fn mount_custom_file(
    cid: &str,
    spec: &mut Spec,
    cust_files: Vec<agent::CustomFile>,
) -> Result<()> {
    let mut p = PathBuf::from(CONTAINER_CUSTOM_FILE_BASE);
    p.push(cid);

    let _ = create_dir_all(p.clone())
        .map_err(|e| anyhow!("create container custom dir failed:{:}", e))?;

    for cust_file in cust_files {
        let f = cust_file.path.trim_start_matches('/');
        let file_p = p.join(f);

        match file_p.parent() {
            Some(dir) => {
                let _ = create_dir_all(dir).map_err(|e| {
                    anyhow!(
                        "create container custom dir {} failed:{:}",
                        dir.display(),
                        e
                    )
                })?;
            }
            None => {
                return Err(anyhow!("can't get parent dir:{:}", file_p.display()));
            }
        }

        let mut file = File::create(file_p.clone())?;
        let decoded_data = STANDARD.decode(cust_file.content)?;
        file.write_all(&decoded_data)?;

        let m = Mount {
            destination: cust_file.path.clone(),
            source: file_p.as_os_str().to_str().unwrap().to_string(),
            options: vec!["bind".to_string(), "ro".to_string()],
            r#type: "bind".to_string(),
        };
        spec.mounts.push(m);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use nix::mount;
    use nix::sched::{unshare, CloneFlags};
    use oci::{Hook, Hooks, Linux, LinuxNamespace};
    use tempfile::{tempdir, TempDir};
    use ttrpc::{r#async::TtrpcContext, MessageHeader};

    use super::*;
    use crate::{
        assert_result, namespace::Namespace, protocols::agent_ttrpc::AgentService as _,
        skip_if_no_cap, skip_if_not_root,
    };
    use capctl::caps::Cap;

    #[tokio::test]
    async fn bounded_exec_process_start_cancels_timed_out_launch() {
        struct DropProbe(Arc<std::sync::atomic::AtomicBool>);

        impl Drop for DropProbe {
            fn drop(&mut self) {
                self.0.store(true, std::sync::atomic::Ordering::SeqCst);
            }
        }

        let dropped = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let operation = {
            let probe = DropProbe(dropped.clone());
            async move {
                let _probe = probe;
                std::future::pending::<()>().await;
                Ok(())
            }
        };

        let outcome = bounded_exec_process_start(Duration::from_millis(10), operation).await;
        assert!(outcome.is_none());
        assert!(dropped.load(std::sync::atomic::Ordering::SeqCst));
    }

    #[test]
    fn version_response_advertises_versioned_unique_capabilities() {
        let response = agent_version_response();
        assert_eq!(response.protocol_version(), AGENT_PROTOCOL_VERSION);
        assert!(!response.agent_version().is_empty());
        let mut names = std::collections::HashSet::new();
        for capability in response.capabilities() {
            assert!(capability.version() > 0);
            assert!(names.insert(capability.name().to_string()));
        }
        assert_eq!(names.len(), AGENT_CAPABILITIES.len());
        assert!(names.contains(rustjail::resources::RESOURCE_V2_CAPABILITY));
    }

    #[test]
    fn resource_failures_map_to_retry_safe_rpc_codes() {
        let precondition = anyhow!(ResourcePreconditionError {
            container_id: "test".to_string(),
            operation: "start".to_string(),
            degraded: rustjail::container::ResourceDegraded {
                cause: "rollback failed".to_string(),
                rollback_error: Some("write failed".to_string()),
                journal_path: PathBuf::from("/tmp/resources-v2.undo.json"),
                current_values: Default::default(),
                latest_recovery_error: None,
            },
        });
        assert_eq!(
            runtime_operation_error_code(&precondition),
            ttrpc::Code::FAILED_PRECONDITION
        );
        assert_eq!(
            runtime_operation_error_code(&anyhow!("ordinary failure")),
            ttrpc::Code::INTERNAL
        );

        for kind in [
            rustjail::cgroups::fs::resources_v2::TransactionFailureKind::Degraded,
            rustjail::cgroups::fs::resources_v2::TransactionFailureKind::Recovered,
        ] {
            let error = anyhow!(rustjail::cgroups::fs::resources_v2::TransactionError {
                kind,
                cause: "test".to_string(),
                rollback_error: None,
                journal_path: PathBuf::from("/tmp/resources-v2.undo.json"),
                current_values: Default::default(),
            });
            assert_eq!(
                update_container_error_code(&error),
                ttrpc::Code::FAILED_PRECONDITION
            );
        }

        let unchanged = anyhow!(rustjail::cgroups::fs::resources_v2::TransactionError {
            kind: rustjail::cgroups::fs::resources_v2::TransactionFailureKind::Unchanged,
            cause: "test".to_string(),
            rollback_error: None,
            journal_path: PathBuf::from("/tmp/resources-v2.undo.json"),
            current_values: Default::default(),
        });
        assert_eq!(
            update_container_error_code(&unchanged),
            ttrpc::Code::INTERNAL
        );
    }

    #[tokio::test]
    async fn remove_pending_create_starts_timeout_while_create_phase_is_active() {
        #[derive(Default)]
        struct PendingState {
            activity: Option<Arc<PendingCreateActivity>>,
        }

        let activity = Arc::new(PendingCreateActivity::new());
        let state = Arc::new(Mutex::new(PendingState {
            activity: Some(activity.clone()),
        }));
        let create_lock = Arc::new(Mutex::new(()));
        let create_lock_for_task = create_lock.clone();
        let activity_for_task = activity.clone();
        let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        let create_phase = tokio::spawn(async move {
            let _serialized_create = create_lock_for_task.lock().await;
            entered_tx.send(()).unwrap();
            let _ = release_rx.await;
            activity_for_task.finish();
        });
        entered_rx.await.unwrap();

        let error =
            request_pending_create_cleanup(&state, Some(Duration::from_millis(10)), |state| {
                state.activity.clone()
            })
            .await
            .unwrap_err();
        assert!(error.downcast_ref::<nix::Error>() == Some(&nix::Error::ETIME));
        assert!(activity.check_cancelled().is_err());
        assert!(activity.is_active());

        release_tx.send(()).unwrap();
        create_phase.await.unwrap();
        assert!(request_pending_create_cleanup(
            &state,
            Some(Duration::from_millis(100)),
            |state| state.activity.clone(),
        )
        .await
        .unwrap()
        .is_some());
    }

    #[tokio::test]
    async fn update_remove_and_stats_share_one_serialized_state_lock() {
        let state = Arc::new(Mutex::new(Vec::new()));
        let mut update = lock_container_state(&state, SerializedContainerOperation::Update).await;
        update.push(SerializedContainerOperation::Update);

        let remove_state = state.clone();
        let (remove_tx, mut remove_rx) = tokio::sync::oneshot::channel();
        let remove = tokio::spawn(async move {
            let mut state =
                lock_container_state(&remove_state, SerializedContainerOperation::Remove).await;
            state.push(SerializedContainerOperation::Remove);
            remove_tx.send(()).unwrap();
        });
        let stats_state = state.clone();
        let (stats_tx, mut stats_rx) = tokio::sync::oneshot::channel();
        let stats = tokio::spawn(async move {
            let mut state =
                lock_container_state(&stats_state, SerializedContainerOperation::Stats).await;
            state.push(SerializedContainerOperation::Stats);
            stats_tx.send(()).unwrap();
        });

        assert!(
            tokio::time::timeout(Duration::from_millis(10), &mut remove_rx)
                .await
                .is_err()
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(10), &mut stats_rx)
                .await
                .is_err()
        );
        update.push(SerializedContainerOperation::Update);
        drop(update);

        tokio::time::timeout(Duration::from_millis(100), remove_rx)
            .await
            .unwrap()
            .unwrap();
        tokio::time::timeout(Duration::from_millis(100), stats_rx)
            .await
            .unwrap()
            .unwrap();
        remove.await.unwrap();
        stats.await.unwrap();

        let operations = state.lock().await;
        assert_eq!(
            &operations[..2],
            &[
                SerializedContainerOperation::Update,
                SerializedContainerOperation::Update,
            ]
        );
        assert!(operations.contains(&SerializedContainerOperation::Remove));
        assert!(operations.contains(&SerializedContainerOperation::Stats));
    }

    #[tokio::test]
    async fn pending_create_cleanup_is_retryable_and_exact() {
        skip_if_no_cap!(Cap::NET_ADMIN);
        let logger = slog::Logger::root(slog::Discard, o!());
        let root = tempdir().unwrap();
        let bundle = root.path().join("bundle");
        let rootfs = bundle.join("rootfs");
        fs::create_dir_all(&rootfs).unwrap();
        let storage = root.path().join("storage");
        fs::create_dir_all(&storage).unwrap();
        let blocker = storage.join("still-present");
        fs::write(&blocker, b"block cleanup").unwrap();

        let mut sandbox = match Sandbox::new(&logger) {
            Ok(sandbox) => sandbox,
            Err(error) => {
                eprintln!("skipping pending-create cleanup test: {error:#}");
                return;
            }
        };
        let activity = sandbox
            .begin_pending_create("pending-test", bundle.clone())
            .unwrap();
        assert!(sandbox
            .begin_pending_create("pending-test", bundle.clone())
            .is_err());
        assert!(sandbox.set_sandbox_storage(storage.to_str().unwrap()));
        sandbox
            .record_pending_storage("pending-test", storage.to_str().unwrap())
            .unwrap();
        activity.finish();
        let service = AgentService::new(Arc::new(Mutex::new(sandbox)));

        let first = service.cleanup_pending_create("pending-test").await;
        assert!(first.is_err());
        {
            let mut sandbox = service.sandbox.lock().await;
            let pending = sandbox.pending_creates.get("pending-test").unwrap();
            assert_eq!(pending.storage_refs, vec![storage.display().to_string()]);
            assert!(pending.last_cleanup_error.is_some());
            assert!(!bundle.exists());
            assert_eq!(sandbox.storages.get(storage.to_str().unwrap()), Some(&0));
            assert!(sandbox
                .acquire_sandbox_storage(storage.to_str().unwrap())
                .is_err());
        }

        fs::remove_file(blocker).unwrap();
        service
            .cleanup_pending_create("pending-test")
            .await
            .unwrap();
        let sandbox = service.sandbox.lock().await;
        assert!(!sandbox.pending_creates.contains_key("pending-test"));
        assert!(!sandbox.storages.contains_key(storage.to_str().unwrap()));
        assert!(!storage.exists());
    }

    #[test]
    fn requested_rootfs_read_only_preserves_oci_intent() {
        let mut spec = Spec::default();
        spec.root = Some(Root {
            path: "rootfs".to_string(),
            readonly: false,
        });
        assert!(!requested_rootfs_read_only(&spec));

        spec.root.as_mut().unwrap().readonly = true;
        assert!(requested_rootfs_read_only(&spec));

        spec.annotations.insert(
            ANNOTATION_K_ROOTFS_WL_PATH.to_string(),
            "/write-layer".to_string(),
        );
        assert!(!requested_rootfs_read_only(&spec));
    }

    #[test]
    fn requested_rootfs_read_only_defaults_to_fail_closed_without_root() {
        assert!(requested_rootfs_read_only(&Spec::default()));
    }

    fn mk_ttrpc_context() -> TtrpcContext {
        TtrpcContext {
            fd: -1,
            mh: MessageHeader::default(),
            metadata: std::collections::HashMap::new(),
            timeout_nano: 0,
        }
    }

    fn create_dummy_opts() -> CreateOpts {
        let root = Root {
            path: String::from("/"),
            ..Default::default()
        };

        let spec = Spec {
            linux: Some(oci::Linux::default()),
            root: Some(root),
            ..Default::default()
        };

        CreateOpts {
            cgroup_name: "".to_string(),
            use_systemd_cgroup: false,
            no_pivot_root: false,
            no_new_keyring: false,
            spec: Some(spec),
            rootless_euid: false,
            rootless_cgroup: false,
            resources_v2: None,
        }
    }

    fn create_linuxcontainer() -> (LinuxContainer, TempDir) {
        let dir = tempdir().expect("failed to make tempdir");

        (
            LinuxContainer::new(
                "some_id",
                dir.path().join("rootfs").to_str().unwrap(),
                create_dummy_opts(),
                &slog_scope::logger(),
            )
            .unwrap(),
            dir,
        )
    }

    fn assert_rpc_code(error: ttrpc::Error, expected: ttrpc::Code) {
        match error {
            ttrpc::Error::RpcStatus(status) => assert_eq!(status.code(), expected),
            other => panic!("expected RPC status {expected:?}, got {other:?}"),
        }
    }

    fn test_resource_degraded() -> rustjail::container::ResourceDegraded {
        rustjail::container::ResourceDegraded {
            cause: "injected rollback failure".to_string(),
            rollback_error: Some("restore cpu.max".to_string()),
            journal_path: PathBuf::from("/tmp/resources-v2.undo.json"),
            current_values: Default::default(),
            latest_recovery_error: None,
        }
    }

    fn recovered_transaction_error() -> rustjail::cgroups::fs::resources_v2::TransactionError {
        rustjail::cgroups::fs::resources_v2::TransactionError {
            kind: rustjail::cgroups::fs::resources_v2::TransactionFailureKind::Recovered,
            cause: "previous transaction recovered".to_string(),
            rollback_error: None,
            journal_path: PathBuf::from("/tmp/resources-v2.undo.json"),
            current_values: Default::default(),
        }
    }

    #[test]
    fn degraded_operation_policy_blocks_new_work_but_allows_cleanup() {
        let degraded = test_resource_degraded();

        for operation in [
            ContainerResourceOperation::Start,
            ContainerResourceOperation::Exec,
            ContainerResourceOperation::Stats,
        ] {
            let error =
                check_resource_operation_state("test", Some(&degraded), operation).unwrap_err();
            assert_eq!(
                runtime_operation_error_code(&error),
                ttrpc::Code::FAILED_PRECONDITION,
                "{operation:?} must fail closed"
            );
            assert_eq!(
                error
                    .downcast_ref::<ResourcePreconditionError>()
                    .unwrap()
                    .operation,
                operation.name()
            );
        }

        for operation in [
            ContainerResourceOperation::Signal,
            ContainerResourceOperation::Wait,
            ContainerResourceOperation::Remove,
        ] {
            check_resource_operation_state("test", Some(&degraded), operation)
                .unwrap_or_else(|error| panic!("{operation:?} must remain available: {error:#}"));
        }
    }

    #[test]
    fn resource_update_invokes_recovery_before_legacy_or_v2_decode() {
        let legacy = protocols::oci::LinuxResources::default();
        let invalid_v2 = protocols::oci::LinuxResources {
            ResourceV2: MessageField::some(protocols::oci::LinuxResourcesV2 {
                Version: rustjail::resources::RESOURCE_V2_VERSION + 1,
                MediaType: rustjail::resources::RESOURCE_V2_MEDIA_TYPE.to_string(),
                Value: b"{}".to_vec(),
                ..Default::default()
            }),
            ..Default::default()
        };

        for resources in [&legacy, &invalid_v2] {
            let recovery_called = std::cell::Cell::new(false);
            let error = prepare_container_resource_update(resources, || {
                recovery_called.set(true);
                Err(recovered_transaction_error())
            })
            .unwrap_err();
            assert_rpc_code(error, ttrpc::Code::FAILED_PRECONDITION);
            assert!(recovery_called.get());
        }

        // Once the caller retries after recovery, normal transport validation
        // resumes and the invalid V2 version is reported as an argument error.
        let error = prepare_container_resource_update(&invalid_v2, || Ok(())).unwrap_err();
        assert_rpc_code(error, ttrpc::Code::INVALID_ARGUMENT);
        assert!(prepare_container_resource_update(&legacy, || Ok(())).is_ok());
    }

    #[tokio::test]
    async fn test_append_guest_hooks() {
        let logger = slog::Logger::root(slog::Discard, o!());
        let mut s = Sandbox::new(&logger).unwrap();
        s.hooks = Some(Hooks {
            prestart: vec![Hook {
                path: "foo".to_string(),
                ..Default::default()
            }],
            ..Default::default()
        });
        let mut oci = Spec {
            ..Default::default()
        };
        append_guest_hooks(&s, &mut oci).unwrap();
        assert_eq!(s.hooks, oci.hooks);
    }

    #[tokio::test]
    async fn test_update_interface() {
        let logger = slog::Logger::root(slog::Discard, o!());
        let sandbox = Sandbox::new(&logger).unwrap();

        let agent_service = Box::new(AgentService::new(Arc::new(Mutex::new(sandbox))));

        let req = protocols::agent::UpdateInterfaceRequest::default();
        let ctx = mk_ttrpc_context();

        let result = agent_service.update_interface(&ctx, req).await;

        assert!(result.is_err(), "expected update interface to fail");
    }

    #[tokio::test]
    async fn test_update_routes() {
        let logger = slog::Logger::root(slog::Discard, o!());
        let sandbox = Sandbox::new(&logger).unwrap();

        let agent_service = Box::new(AgentService::new(Arc::new(Mutex::new(sandbox))));

        let req = protocols::agent::UpdateRoutesRequest::default();
        let ctx = mk_ttrpc_context();

        let result = agent_service.update_routes(&ctx, req).await;

        assert!(result.is_err(), "expected update routes to fail");
    }

    #[tokio::test]
    async fn test_add_arp_neighbors() {
        let logger = slog::Logger::root(slog::Discard, o!());
        let sandbox = Sandbox::new(&logger).unwrap();

        let agent_service = Box::new(AgentService::new(Arc::new(Mutex::new(sandbox))));

        let req = protocols::agent::AddARPNeighborsRequest::default();
        let ctx = mk_ttrpc_context();

        let result = agent_service.add_arp_neighbors(&ctx, req).await;

        assert!(result.is_err(), "expected add arp neighbors to fail");
    }

    #[tokio::test]
    async fn test_do_write_stream() {
        // Only the create_container cases build a cgroup (which needs a
        // writable cgroup filesystem); the invalid-container-id and
        // cannot-get-writer cases exercise pure pipe I/O and stay covered
        // even when /sys/fs/cgroup is read-only.
        let have_cgroupfs = crate::test_utils::test_utils::cgroupfs_writable();

        #[derive(Debug)]
        struct TestData<'a> {
            create_container: bool,
            has_fd: bool,
            has_tty: bool,
            break_pipe: bool,

            container_id: &'a str,
            exec_id: &'a str,
            data: Vec<u8>,
            result: Result<protocols::agent::WriteStreamResponse>,
        }

        impl Default for TestData<'_> {
            fn default() -> Self {
                TestData {
                    create_container: true,
                    has_fd: true,
                    has_tty: true,
                    break_pipe: false,

                    container_id: "1",
                    exec_id: "2",
                    data: vec![1, 2, 3],
                    result: Ok(WriteStreamResponse {
                        len: 3,
                        ..WriteStreamResponse::default()
                    }),
                }
            }
        }

        let tests = &[
            TestData {
                ..Default::default()
            },
            TestData {
                has_tty: false,
                ..Default::default()
            },
            TestData {
                break_pipe: true,
                result: Err(anyhow!(std::io::Error::from_raw_os_error(libc::EPIPE))),
                ..Default::default()
            },
            TestData {
                create_container: false,
                result: Err(anyhow!(crate::sandbox::ERR_INVALID_CONTAINER_ID)),
                ..Default::default()
            },
            TestData {
                container_id: "8181",
                result: Err(anyhow!(crate::sandbox::ERR_INVALID_CONTAINER_ID)),
                ..Default::default()
            },
            TestData {
                data: vec![],
                result: Ok(WriteStreamResponse {
                    len: 0,
                    ..WriteStreamResponse::default()
                }),
                ..Default::default()
            },
            TestData {
                has_fd: false,
                result: Err(anyhow!(ERR_CANNOT_GET_WRITER)),
                ..Default::default()
            },
        ];

        for (i, d) in tests.iter().enumerate() {
            let msg = format!("test[{}]: {:?}", i, d);

            if d.create_container && !have_cgroupfs {
                println!(
                    "INFO: skipping {} which needs a writable cgroup filesystem",
                    msg
                );
                continue;
            }

            let logger = slog::Logger::root(slog::Discard, o!());
            let mut sandbox = Sandbox::new(&logger).unwrap();

            let (rfd, wfd) = unistd::pipe().unwrap();
            if d.break_pipe {
                unistd::close(rfd).unwrap();
            }

            if d.create_container {
                let (mut linux_container, _root) = create_linuxcontainer();
                let exec_process_id = 2;

                linux_container.id = "1".to_string();

                let mut exec_process = Process::new(
                    &logger,
                    &oci::Process::default(),
                    &exec_process_id.to_string(),
                    false,
                    1,
                )
                .unwrap();

                let fd = {
                    if d.has_fd {
                        Some(wfd)
                    } else {
                        None
                    }
                };

                if d.has_tty {
                    exec_process.parent_stdin = None;
                    exec_process.term_master = fd;
                } else {
                    exec_process.parent_stdin = fd;
                    exec_process.term_master = None;
                }
                linux_container
                    .processes
                    .insert(exec_process_id, exec_process);

                sandbox.add_container(linux_container);
            }

            let agent_service = Box::new(AgentService::new(Arc::new(Mutex::new(sandbox))));

            let result = agent_service
                .do_write_stream(protocols::agent::WriteStreamRequest {
                    container_id: d.container_id.to_string(),
                    exec_id: d.exec_id.to_string(),
                    data: d.data.clone(),
                    ..Default::default()
                })
                .await;

            if !d.break_pipe {
                unistd::close(rfd).unwrap();
            }
            unistd::close(wfd).unwrap();

            let msg = format!("{}, result: {:?}", msg, result);
            assert_result!(d.result, result, msg);
        }
    }

    #[tokio::test]
    async fn test_update_container_namespaces() {
        #[derive(Debug)]
        struct TestData<'a> {
            has_linux_in_spec: bool,
            sandbox_pidns_path: Option<&'a str>,

            namespaces: Vec<LinuxNamespace>,
            use_sandbox_pidns: bool,
            result: Result<()>,
            expected_namespaces: Vec<LinuxNamespace>,
        }

        impl Default for TestData<'_> {
            fn default() -> Self {
                TestData {
                    has_linux_in_spec: true,
                    sandbox_pidns_path: Some("sharedpidns"),
                    namespaces: vec![
                        LinuxNamespace {
                            r#type: NSTYPEIPC.to_string(),
                            path: "ipcpath".to_string(),
                        },
                        LinuxNamespace {
                            r#type: NSTYPEUTS.to_string(),
                            path: "utspath".to_string(),
                        },
                    ],
                    use_sandbox_pidns: false,
                    result: Ok(()),
                    expected_namespaces: vec![
                        LinuxNamespace {
                            r#type: NSTYPEIPC.to_string(),
                            path: "".to_string(),
                        },
                        LinuxNamespace {
                            r#type: NSTYPEUTS.to_string(),
                            path: "".to_string(),
                        },
                        LinuxNamespace {
                            r#type: NSTYPEPID.to_string(),
                            path: "".to_string(),
                        },
                    ],
                }
            }
        }

        let tests = &[
            TestData {
                ..Default::default()
            },
            TestData {
                use_sandbox_pidns: true,
                expected_namespaces: vec![
                    LinuxNamespace {
                        r#type: NSTYPEIPC.to_string(),
                        path: "".to_string(),
                    },
                    LinuxNamespace {
                        r#type: NSTYPEUTS.to_string(),
                        path: "".to_string(),
                    },
                    LinuxNamespace {
                        r#type: NSTYPEPID.to_string(),
                        path: "sharedpidns".to_string(),
                    },
                ],
                ..Default::default()
            },
            TestData {
                namespaces: vec![],
                use_sandbox_pidns: true,
                expected_namespaces: vec![LinuxNamespace {
                    r#type: NSTYPEPID.to_string(),
                    path: "sharedpidns".to_string(),
                }],
                ..Default::default()
            },
            TestData {
                namespaces: vec![],
                use_sandbox_pidns: false,
                expected_namespaces: vec![LinuxNamespace {
                    r#type: NSTYPEPID.to_string(),
                    path: "".to_string(),
                }],
                ..Default::default()
            },
            TestData {
                namespaces: vec![],
                sandbox_pidns_path: None,
                use_sandbox_pidns: true,
                result: Err(anyhow!(ERR_NO_SANDBOX_PIDNS)),
                expected_namespaces: vec![],
                ..Default::default()
            },
            TestData {
                has_linux_in_spec: false,
                result: Err(anyhow!(ERR_NO_LINUX_FIELD)),
                ..Default::default()
            },
        ];

        for (i, d) in tests.iter().enumerate() {
            let msg = format!("test[{}]: {:?}", i, d);

            let logger = slog::Logger::root(slog::Discard, o!());
            let mut sandbox = Sandbox::new(&logger).unwrap();
            if let Some(pidns_path) = d.sandbox_pidns_path {
                let mut sandbox_pidns = Namespace::new(&logger);
                sandbox_pidns.path = pidns_path.to_string();
                sandbox.sandbox_pidns = Some(sandbox_pidns);
            }

            let mut oci = Spec::default();
            if d.has_linux_in_spec {
                oci.linux = Some(Linux {
                    namespaces: d.namespaces.clone(),
                    ..Default::default()
                });
            }

            let result = update_container_namespaces(&sandbox, &mut oci, d.use_sandbox_pidns);

            let msg = format!("{}, result: {:?}", msg, result);

            assert_result!(d.result, result, msg);
            if let Some(linux) = oci.linux {
                assert_eq!(d.expected_namespaces, linux.namespaces, "{}", msg);
            }
        }
    }

    #[tokio::test]
    async fn test_get_memory_info() {
        #[derive(Debug)]
        struct TestData<'a> {
            // if None is provided, no file will be generated, else the data in the Option will populate the file
            block_size_data: Option<&'a str>,

            hotplug_probe_data: bool,
            get_block_size: bool,
            get_hotplug: bool,
            result: Result<(u64, bool)>,
        }

        let tests = &[
            TestData {
                block_size_data: Some("10000000"),
                hotplug_probe_data: true,
                get_block_size: true,
                get_hotplug: true,
                result: Ok((268435456, true)),
            },
            TestData {
                block_size_data: Some("100"),
                hotplug_probe_data: false,
                get_block_size: true,
                get_hotplug: true,
                result: Ok((256, false)),
            },
            TestData {
                block_size_data: None,
                hotplug_probe_data: false,
                get_block_size: true,
                get_hotplug: true,
                result: Ok((0, false)),
            },
            TestData {
                block_size_data: Some(""),
                hotplug_probe_data: false,
                get_block_size: true,
                get_hotplug: false,
                result: Err(anyhow!(ERR_INVALID_BLOCK_SIZE)),
            },
            TestData {
                block_size_data: Some("-1"),
                hotplug_probe_data: false,
                get_block_size: true,
                get_hotplug: false,
                result: Err(anyhow!(ERR_INVALID_BLOCK_SIZE)),
            },
            TestData {
                block_size_data: Some("    "),
                hotplug_probe_data: false,
                get_block_size: true,
                get_hotplug: false,
                result: Err(anyhow!(ERR_INVALID_BLOCK_SIZE)),
            },
            TestData {
                block_size_data: Some("some data"),
                hotplug_probe_data: false,
                get_block_size: true,
                get_hotplug: false,
                result: Err(anyhow!(ERR_INVALID_BLOCK_SIZE)),
            },
            TestData {
                block_size_data: Some("some data"),
                hotplug_probe_data: true,
                get_block_size: false,
                get_hotplug: false,
                result: Ok((0, false)),
            },
            TestData {
                block_size_data: Some("100"),
                hotplug_probe_data: true,
                get_block_size: false,
                get_hotplug: false,
                result: Ok((0, false)),
            },
            TestData {
                block_size_data: Some("100"),
                hotplug_probe_data: true,
                get_block_size: false,
                get_hotplug: true,
                result: Ok((0, true)),
            },
        ];

        for (i, d) in tests.iter().enumerate() {
            let msg = format!("test[{}]: {:?}", i, d);

            let dir = tempdir().expect("failed to make tempdir");
            let block_size_path = dir.path().join("block_size_bytes");
            let hotplug_probe_path = dir.path().join("probe");

            if let Some(block_size_data) = d.block_size_data {
                fs::write(&block_size_path, block_size_data).unwrap();
            }
            if d.hotplug_probe_data {
                fs::write(&hotplug_probe_path, []).unwrap();
            }

            let result = get_memory_info(
                d.get_block_size,
                d.get_hotplug,
                block_size_path.to_str().unwrap(),
                hotplug_probe_path.to_str().unwrap(),
            );

            let msg = format!("{}, result: {:?}", msg, result);

            assert_result!(d.result, result, msg);
        }
    }

    #[tokio::test]
    async fn test_is_signal_handled() {
        #[derive(Debug)]
        struct TestData<'a> {
            status_file_data: Option<&'a str>,
            signum: u32,
            result: bool,
        }

        let tests = &[
            TestData {
                status_file_data: Some(
                    r#"
SigBlk:0000000000010000
SigCgt:0000000000000001
OtherField:other
                "#,
                ),
                signum: 1,
                result: true,
            },
            TestData {
                status_file_data: Some("SigCgt:000000004b813efb"),
                signum: 4,
                result: true,
            },
            TestData {
                status_file_data: Some("SigCgt:\t000000004b813efb"),
                signum: 4,
                result: true,
            },
            TestData {
                status_file_data: Some("SigCgt: 000000004b813efb"),
                signum: 4,
                result: true,
            },
            TestData {
                status_file_data: Some("SigCgt:000000004b813efb "),
                signum: 4,
                result: true,
            },
            TestData {
                status_file_data: Some("SigCgt:\t000000004b813efb "),
                signum: 4,
                result: true,
            },
            TestData {
                status_file_data: Some("SigCgt:000000004b813efb"),
                signum: 3,
                result: false,
            },
            TestData {
                status_file_data: Some("SigCgt:000000004b813efb"),
                signum: 65,
                result: false,
            },
            TestData {
                status_file_data: Some("SigCgt:000000004b813efb"),
                signum: 0,
                result: true,
            },
            TestData {
                status_file_data: Some("SigCgt:ZZZZZZZZ"),
                signum: 1,
                result: false,
            },
            TestData {
                status_file_data: Some("SigCgt:-1"),
                signum: 1,
                result: false,
            },
            TestData {
                status_file_data: Some("SigCgt"),
                signum: 1,
                result: false,
            },
            TestData {
                status_file_data: Some("any data"),
                signum: 0,
                result: true,
            },
            TestData {
                status_file_data: Some("SigBlk:0000000000000001"),
                signum: 1,
                result: true,
            },
            TestData {
                status_file_data: Some("SigIgn:0000000000000001"),
                signum: 1,
                result: true,
            },
            TestData {
                status_file_data: None,
                signum: 1,
                result: false,
            },
            TestData {
                status_file_data: None,
                signum: 0,
                result: false,
            },
        ];

        for (i, d) in tests.iter().enumerate() {
            let msg = format!("test[{}]: {:?}", i, d);

            let dir = tempdir().expect("failed to make tempdir");
            let proc_status_file_path = dir.path().join("status");

            if let Some(file_data) = d.status_file_data {
                fs::write(&proc_status_file_path, file_data).unwrap();
            }

            let result = is_signal_handled(proc_status_file_path.to_str().unwrap(), d.signum);

            let msg = format!("{}, result: {:?}", msg, result);

            assert_eq!(d.result, result, "{}", msg);
        }
    }

    #[tokio::test]
    async fn test_volume_capacity_stats() {
        skip_if_not_root!();
        // The test mounts a tmpfs, needing CAP_SYS_ADMIN.
        skip_if_no_cap!(Cap::SYS_ADMIN);

        // Verify error if path does not exist
        assert!(get_volume_capacity_stats("/does-not-exist").is_err());

        // Create a new tmpfs mount, and verify the initial values
        let mount_dir = tempfile::tempdir().unwrap();
        mount::mount(
            Some("tmpfs"),
            mount_dir.path().to_str().unwrap(),
            Some("tmpfs"),
            mount::MsFlags::empty(),
            None::<&str>,
        )
        .unwrap();
        let mut stats = get_volume_capacity_stats(mount_dir.path().to_str().unwrap()).unwrap();
        assert_eq!(stats.used, 0);
        assert_ne!(stats.available, 0);
        let available = stats.available;

        // Verify that writing a file will result in increased utilization
        fs::write(mount_dir.path().join("file.dat"), "foobar").unwrap();
        stats = get_volume_capacity_stats(mount_dir.path().to_str().unwrap()).unwrap();

        assert_eq!(stats.used, 4 * 1024);
        assert_eq!(stats.available, available - 4 * 1024);
    }

    #[tokio::test]
    async fn test_get_volume_inode_stats() {
        skip_if_not_root!();
        // The test mounts a tmpfs, needing CAP_SYS_ADMIN.
        skip_if_no_cap!(Cap::SYS_ADMIN);

        // Verify error if path does not exist
        assert!(get_volume_inode_stats("/does-not-exist").is_err());

        // Create a new tmpfs mount, and verify the initial values
        let mount_dir = tempfile::tempdir().unwrap();
        mount::mount(
            Some("tmpfs"),
            mount_dir.path().to_str().unwrap(),
            Some("tmpfs"),
            mount::MsFlags::empty(),
            None::<&str>,
        )
        .unwrap();
        let mut stats = get_volume_inode_stats(mount_dir.path().to_str().unwrap()).unwrap();
        assert_eq!(stats.used, 1);
        assert_ne!(stats.available, 0);
        let available = stats.available;

        // Verify that creating a directory and writing a file will result in increased utilization
        let dir = mount_dir.path().join("foobar");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.as_path().join("file.dat"), "foobar").unwrap();
        stats = get_volume_inode_stats(mount_dir.path().to_str().unwrap()).unwrap();

        assert_eq!(stats.used, 3);
        assert_eq!(stats.available, available - 2);
    }

    #[tokio::test]
    async fn test_ip_tables() {
        skip_if_not_root!();
        // The test unshares a network namespace, needing CAP_SYS_ADMIN.
        skip_if_no_cap!(Cap::SYS_ADMIN);

        let logger = slog::Logger::root(slog::Discard, o!());
        let sandbox = Sandbox::new(&logger).unwrap();
        let agent_service = Box::new(AgentService::new(Arc::new(Mutex::new(sandbox))));

        let ctx = mk_ttrpc_context();

        // Move to a new netns in order to ensure we don't trash the hosts' iptables
        unshare(CloneFlags::CLONE_NEWNET).unwrap();

        // Get initial iptables, we expect to be empty:
        let result = agent_service
            .get_ip_tables(
                &ctx,
                GetIPTablesRequest {
                    is_ipv6: false,
                    ..Default::default()
                },
            )
            .await;
        assert!(result.is_ok(), "get ip tables should succeed");
        assert_eq!(
            result.unwrap().data.len(),
            0,
            "ip tables should be empty initially"
        );

        // Initial ip6 ip tables should also be empty:
        let result = agent_service
            .get_ip_tables(
                &ctx,
                GetIPTablesRequest {
                    is_ipv6: true,
                    ..Default::default()
                },
            )
            .await;
        assert!(result.is_ok(), "get ip6 tables should succeed");
        assert_eq!(
            result.unwrap().data.len(),
            0,
            "ip tables should be empty initially"
        );

        // Verify that attempting to write 'empty' iptables results in no error:
        let empty_rules = "";
        let result = agent_service
            .set_ip_tables(
                &ctx,
                SetIPTablesRequest {
                    is_ipv6: false,
                    data: empty_rules.as_bytes().to_vec(),
                    ..Default::default()
                },
            )
            .await;
        assert!(result.is_ok(), "set ip tables with no data should succeed");

        // Verify that attempting to write "garbage" iptables results in an error:
        let garbage_rules = r#"
this
is
just garbage
"#;
        let result = agent_service
            .set_ip_tables(
                &ctx,
                SetIPTablesRequest {
                    is_ipv6: false,
                    data: garbage_rules.as_bytes().to_vec(),
                    ..Default::default()
                },
            )
            .await;
        assert!(result.is_err(), "set iptables with garbage should fail");

        // Verify setup of valid iptables:Setup  valid set of iptables:
        let valid_rules = r#"
*nat
-A PREROUTING -d 192.168.103.153/32 -j DNAT --to-destination 192.168.188.153

COMMIT

"#;
        let result = agent_service
            .set_ip_tables(
                &ctx,
                SetIPTablesRequest {
                    is_ipv6: false,
                    data: valid_rules.as_bytes().to_vec(),
                    ..Default::default()
                },
            )
            .await;
        assert!(result.is_ok(), "set ip tables should succeed");

        let result = agent_service
            .get_ip_tables(
                &ctx,
                GetIPTablesRequest {
                    is_ipv6: false,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert!(!result.data.is_empty(), "we should have non-zero output:");
        assert!(
            std::str::from_utf8(&*result.data).unwrap().contains(
                "PREROUTING -d 192.168.103.153/32 -j DNAT --to-destination 192.168.188.153"
            ),
            "We should see the resulting rule"
        );

        // Verify setup of valid ip6tables:
        let valid_ipv6_rules = r#"
*filter
-A INPUT -s 2001:db8:100::1/128 -i sit+ -p tcp -m tcp --sport 512:65535

COMMIT

"#;
        let result = agent_service
            .set_ip_tables(
                &ctx,
                SetIPTablesRequest {
                    is_ipv6: true,
                    data: valid_ipv6_rules.as_bytes().to_vec(),
                    ..Default::default()
                },
            )
            .await;
        assert!(result.is_ok(), "set ip6 tables should succeed");

        let result = agent_service
            .get_ip_tables(
                &ctx,
                GetIPTablesRequest {
                    is_ipv6: true,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert!(!result.data.is_empty(), "we should have non-zero output:");
        assert!(
            std::str::from_utf8(&*result.data)
                .unwrap()
                .contains("INPUT -s 2001:db8:100::1/128 -i sit+ -p tcp -m tcp --sport 512:65535"),
            "We should see the resulting rule"
        );
    }
}
