// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

pub mod container_mgr;
pub mod exec;
pub(crate) mod resources;
pub mod rootfs;
use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use agent::CustomFile;
use chrono::{DateTime, Utc};
use container_mgr::{ContainerInfo, ContainerState, TaskState};
use containerd_shim::protos::protobuf::MessageDyn;
use containerd_shim::{Error, Result};
use exec::{Exec, Tty};
use oci_spec::runtime::{Capability, LinuxResources, Mount, Process, Spec};
use protoc::{agent, agent_ttrpc, oci};
use serde_json;
use tokio::sync::mpsc::Sender;
use tokio::sync::Mutex;
use ttrpc::context::{self, Context};

use crate::common::types::PropagationContainerMount;
use crate::common::utils::{AsyncUtils, CPath, Utils};
use crate::common::{
    self, CResult, ANNO_PROPAGATION_CONTAINER_MNTS, CUBE_BIND_SHARE_GUEST_BASE_DIR,
    CUBE_BIND_SHARE_TYPE, MOUNT_TYPE_BIND, MOUNT_TYPE_RBIND,
};
use crate::container::rootfs::ANNO_CONTAINER_CUSTOM_FILE;
use crate::log::{stat_defer, stat_defer::StatDefer, Log};
use crate::sandbox::config::{Config, ANNO_APP_SNAPSHOT_CREATE};
use crate::{infof, warnf};

pub const GUEST_DEV_SHM: &str = "/run/cube-containers/sandbox/shm";
pub const ANNO_APP_SNAPSHOT_CONTAINER_ID: &str = "cube.appsnapshot.container.id";

/// Node-local opt-in for Kubernetes `securityContext.privileged=true`.
/// containerd and every Cube shim inherit this value from the containerd
/// service environment. Privileged workloads remain disabled when it is
/// absent.
pub const CUBE_ALLOW_PRIVILEGED_ENV: &str = "CUBE_ALLOW_PRIVILEGED";

/// Upper bound on the dedicated vsock connect in start_log_forward.  It runs
/// while holding log_forward_lifecycle, so an unbounded connect would serialize
/// and stall all other log-forward lifecycle operations on this container.
const LOG_FORWARD_CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Translate the containerd OCI process used for an exec into the Agent
/// protobuf without inventing, sorting, or dropping supported process fields.
///
/// Keep AppArmor, OOM score, and SELinux at their existing PoC defaults: the
/// create path does not transport SELinux and these policies are outside the
/// first-version support matrix. Capabilities, rlimits, and no-new-privileges
/// are representable by the Agent protobuf and must not be silently cleared.
fn exec_process_for_agent(source: &Process, terminal: bool) -> CResult<oci::Process> {
    validate_exec_process_transport(source)?;
    let json =
        serde_json::to_string(source).map_err(|e| format!("serialize exec process failed:{e}"))?;
    let mut process: oci::Process =
        serde_json::from_str(&json).map_err(|e| format!("deserialize exec process failed:{e}"))?;
    process.set_terminal(terminal);
    process.clear_apparmorProfile();
    process.clear_oomScoreAdj();
    process.clear_selinuxLabel();
    Ok(process)
}

/// Fail closed for OCI exec fields that the current Cube Agent protobuf does
/// not carry. Generated protobuf serde accepts unknown JSON fields, so relying
/// on the serde round trip alone would silently discard these requests.
fn validate_exec_process_transport(process: &Process) -> CResult<()> {
    let unsupported = [
        (process.user().umask().is_some(), "user.umask"),
        (process.command_line().is_some(), "commandLine"),
        (process.io_priority().is_some(), "ioPriority"),
        (process.scheduler().is_some(), "scheduler"),
        (process.exec_cpu_affinity().is_some(), "execCPUAffinity"),
    ];

    if let Some((_, field)) = unsupported.into_iter().find(|(present, _)| *present) {
        return Err(format!(
            "unsupported OCI exec process field {field}: not representable by Cube Agent protobuf"
        ));
    }

    Ok(())
}

/// Reject OCI seccomp values that the current Cube Agent protobuf cannot
/// represent without changing their meaning. Keep this check ahead of the
/// serde conversion: generated protobuf serde ignores fields absent from its
/// schema, which would otherwise turn a requested security policy into a
/// silent downgrade.
fn validate_seccomp_transport(spec: &Spec) -> CResult<()> {
    let Some(linux) = spec.linux().as_ref() else {
        return Ok(());
    };
    let Some(seccomp) = linux.seccomp().as_ref() else {
        return Ok(());
    };

    if seccomp.default_errno_ret().is_some() {
        return Err(
            "unsupported OCI seccomp field defaultErrnoRet: not representable by Cube Agent protobuf"
                .to_string(),
        );
    }
    if seccomp.listener_path().is_some() {
        return Err(
            "unsupported OCI seccomp field listenerPath: not representable by Cube Agent protobuf"
                .to_string(),
        );
    }
    if seccomp.listener_metadata().is_some() {
        return Err(
            "unsupported OCI seccomp field listenerMetadata: not representable by Cube Agent protobuf"
                .to_string(),
        );
    }
    if let Some(syscalls) = seccomp.syscalls() {
        for (index, syscall) in syscalls.iter().enumerate() {
            if syscall.errno_ret() == Some(0) {
                return Err(format!(
                    "unsupported OCI seccomp field syscalls[{index}].errnoRet=0: protobuf presence would be lost"
                ));
            }
        }
    }

    Ok(())
}

/// containerd emits this OCI device-cgroup rule only for privileged
/// containers when the Cube runtime is configured with
/// `privileged_without_host_devices_all_devices_allowed=true`. Keep the
/// check on the original OCI spec: the protobuf uses -1 rather than absent
/// major/minor values to represent a wildcard.
fn is_canonical_all_devices_rule(device: &oci_spec::runtime::LinuxDeviceCgroup) -> bool {
    device.allow()
        && device.typ().is_none()
        && device.major().is_none()
        && device.minor().is_none()
        && device.access().as_deref() == Some("rwm")
}

fn contains_all_devices_rule(spec: &Spec) -> bool {
    spec.linux()
        .as_ref()
        .and_then(|linux| linux.resources().as_ref())
        .and_then(|resources| resources.devices().as_ref())
        .is_some_and(|devices| devices.iter().any(is_canonical_all_devices_rule))
}

fn has_exact_all_devices_rule(spec: &Spec) -> bool {
    spec.linux()
        .as_ref()
        .and_then(|linux| linux.resources().as_ref())
        .and_then(|resources| resources.devices().as_ref())
        .is_some_and(|devices| devices.len() == 1 && is_canonical_all_devices_rule(&devices[0]))
}

fn validate_unchanged_device_update(spec: &Spec, update: &LinuxResources) -> CResult<()> {
    let Some(requested) = update.devices().as_ref() else {
        return Ok(());
    };
    let current = spec
        .linux()
        .as_ref()
        .and_then(|linux| linux.resources().as_ref())
        .and_then(|resources| resources.devices().as_ref())
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    if requested.as_slice() != current {
        return Err(
            "resources.devices updates are not supported; device policy is create-only and the requested rules differ from the create-time policy"
                .to_string(),
        );
    }
    Ok(())
}

/// Fail closed for a maximally elevated OCI input even if the containerd
/// all-devices marker was accidentally disabled. A non-privileged Kubernetes
/// container keeps the default masked/readonly paths, so this fallback does
/// not classify ordinary capability additions as privileged.
fn has_privileged_capability_signature(spec: &Spec) -> bool {
    let Some(process) = spec.process().as_ref() else {
        return false;
    };
    let Some(capabilities) = process.capabilities().as_ref() else {
        return false;
    };
    let has_elevated_caps = [
        capabilities.bounding(),
        capabilities.effective(),
        capabilities.permitted(),
    ]
    .into_iter()
    .all(|set| {
        set.as_ref().is_some_and(|set| {
            set.contains(&Capability::SysAdmin)
                && set.contains(&Capability::SysModule)
                && set.contains(&Capability::SysRawio)
        })
    });
    if !has_elevated_caps {
        return false;
    }

    spec.linux().as_ref().is_some_and(|linux| {
        linux
            .masked_paths()
            .as_ref()
            .map_or(true, |paths| paths.is_empty())
            && linux
                .readonly_paths()
                .as_ref()
                .map_or(true, |paths| paths.is_empty())
            && linux.seccomp().is_none()
    })
}

fn requests_guest_privileged(spec: &Spec) -> bool {
    contains_all_devices_rule(spec) || has_privileged_capability_signature(spec)
}

fn is_host_dev_path(source: &Path) -> bool {
    source == Path::new("/dev") || source.starts_with("/dev/")
}

fn reject_host_dev_bind_sources(spec: &Spec) -> CResult<()> {
    if let Some(mount) = spec.mounts().as_ref().into_iter().flatten().find(|mount| {
        mount.typ().as_deref() == Some("bind")
            && mount
                .source()
                .as_ref()
                .is_some_and(|source| is_host_dev_path(source))
    }) {
        return Err(format!(
            "privileged OCI request contains Host /dev mount source {:?}",
            mount.source()
        ));
    }
    Ok(())
}

/// Resolve privileged Host bind sources while they still refer to the
/// original OCI paths, then replace the sources in the spec with those
/// canonical paths. Standard-rootfs preparation later exports exactly these
/// rewritten paths rather than reusing a caller-controlled symlink. Any
/// resolution failure is rejected before Task reservation or rootfs effects.
pub(crate) fn resolve_guest_privileged_bind_sources(spec: &mut Spec) -> CResult<()> {
    if !requests_guest_privileged(spec) {
        return Ok(());
    }

    let Some(mounts) = spec.mounts_mut().as_mut() else {
        return Ok(());
    };
    for mount in mounts.iter_mut() {
        if mount.typ().as_deref() != Some("bind") {
            continue;
        }
        let source = mount.source().as_ref().ok_or_else(|| {
            format!(
                "privileged host bind mount for {:?} has no source",
                mount.destination()
            )
        })?;
        if !source.is_absolute() {
            return Err(format!(
                "privileged host bind mount source must be absolute for {:?}: {}",
                mount.destination(),
                source.display()
            ));
        }
        let resolved = std::fs::canonicalize(source).map_err(|error| {
            format!(
                "resolve privileged host bind mount source {} for {:?} failed: {error}",
                source.display(),
                mount.destination()
            )
        })?;
        if is_host_dev_path(&resolved) {
            return Err(format!(
                "privileged OCI request contains Host /dev mount source {:?} resolved from {}",
                resolved,
                source.display()
            ));
        }
        mount.set_source(Some(resolved));
    }

    Ok(())
}

fn parse_privileged_node_switch(value: Option<&OsStr>) -> CResult<bool> {
    let Some(value) = value else {
        return Ok(false);
    };
    let value = value.to_str().ok_or_else(|| {
        format!("invalid non-UTF-8 {CUBE_ALLOW_PRIVILEGED_ENV} value: expected true or false")
    })?;
    match value {
        "false" => Ok(false),
        "true" => Ok(true),
        value => Err(format!(
            "invalid {CUBE_ALLOW_PRIVILEGED_ENV} value {value:?}: expected true or false"
        )),
    }
}

/// Enforce the VM-runtime form of privileged: elevation is confined to the
/// Guest kernel and containerd must not enumerate Host device nodes into the
/// OCI input. Explicit device passthrough can be designed separately rather
/// than becoming an accidental side effect of `privileged=true`.
fn validate_guest_privileged_input(spec: &Spec, node_allows_privileged: bool) -> CResult<bool> {
    let requested = requests_guest_privileged(spec);
    if !requested {
        return Ok(false);
    }
    if !node_allows_privileged {
        return Err(format!(
            "privileged OCI request rejected: node switch {CUBE_ALLOW_PRIVILEGED_ENV}=true is required"
        ));
    }

    if let Some(devices) = spec
        .linux()
        .as_ref()
        .and_then(|linux| linux.devices().as_ref())
    {
        if let Some(device) = devices.first() {
            return Err(format!(
                "privileged OCI request contains Host device candidate {:?}; Cube Guest device nodes must not come from OCI linux.devices, configure containerd privileged_without_host_devices=true",
                device.path()
            ));
        }
    }

    reject_host_dev_bind_sources(spec)?;

    if !has_exact_all_devices_rule(spec) {
        return Err(
            "privileged OCI request must contain exactly one canonical Guest all-devices rule and no additional device rules; configure containerd privileged_without_host_devices_all_devices_allowed=true"
                .to_string(),
        );
    }

    Ok(true)
}

fn guest_all_devices_rule() -> oci::LinuxDeviceCgroup {
    oci::LinuxDeviceCgroup {
        allow: true,
        field_type: "a".to_string(),
        major: -1,
        minor: -1,
        access: "rwm".to_string(),
        ..Default::default()
    }
}

#[derive(Default)]
struct LogForward {
    handle: Option<tokio::task::JoinHandle<()>>,
    cancel: Option<tokio::sync::watch::Sender<bool>>,
}

/// Shared, clone-safe owner of the init log-forwarding background task.
///
/// `Container` is `#[derive(Clone)]` and clones are pulled out of the map in
/// paths like delete/wait, so the task must be owned through a single shared
/// slot rather than a per-clone `Arc<JoinHandle>`.  `lifecycle` (permits = 1)
/// serializes start/stop across all clones so exactly one caller drains the
/// task to completion instead of falling back to `abort()`.
#[derive(Clone)]
struct LogForwardHandle {
    slot: Arc<Mutex<LogForward>>,
    lifecycle: Arc<tokio::sync::Semaphore>,
}

impl LogForwardHandle {
    fn new() -> Self {
        Self {
            slot: Arc::new(Mutex::new(LogForward::default())),
            lifecycle: Arc::new(tokio::sync::Semaphore::new(1)),
        }
    }

    /// Acquire the start/stop serialization permit.  Held for the whole
    /// duration of a start or stop so the two never interleave across clones.
    async fn acquire(&self) -> tokio::sync::OwnedSemaphorePermit {
        self.lifecycle
            .clone()
            .acquire_owned()
            .await
            .expect("log-forward lifecycle semaphore closed")
    }

    /// Cancel and await the current task to completion.  Caller must hold the
    /// lifecycle permit.  The slot mutex is released before the `.await` so it
    /// is never held across task termination.
    ///
    /// The `handle.await` is intentionally unbounded: draining instead of
    /// aborting is the whole point of the fix, and a bounded drain + `abort()`
    /// fallback would reintroduce the skipped-IO-drain hazard this removes.  In
    /// the pathological case (the task stuck mid-`file.write_all` on a hung log
    /// file rather than parked on `cancel.changed()`), this blocks while holding
    /// the lifecycle permit.  On the `disconnect_agent`/`resume`/`kill_container`
    /// paths the drain additionally runs under the sandbox `containers` mutex
    /// (the map is iterated in place via `unset_client`, or the entry is borrowed
    /// via `get_mut` in `kill_container` -> `signal_container`), so a wedged task
    /// stalls every other lifecycle op on the sandbox.  On the clone path (`delete_container`,
    /// which drains via `destroy_container` -> `signal_container`) the container
    /// is cloned out of the map and the `containers` lock is released before the
    /// drain — but the service layer still holds the sandbox-wide `Mutex<SandBox>`
    /// across the whole RPC (task_srv serializes every op on it), so a wedged
    /// drain freezes pause/resume/kill/delete for the whole sandbox on this path
    /// too, and this path previously took the `abort()` fallback and returned
    /// promptly, so draining is a deliberate *new* blocking point on it, not a
    /// pre-existing one.  (`wait_container` clones out of the map too but never
    /// drains.)  We accept it: the forwarding loops append to local log files
    /// whose writes do not normally stall.
    async fn drain(&self) {
        let (cancel, handle) = {
            let mut slot = self.slot.lock().await;
            (slot.cancel.take(), slot.handle.take())
        };
        if let Some(tx) = cancel {
            let _ = tx.send(true);
        }
        if let Some(handle) = handle {
            let _ = handle.await;
        }
    }

    /// Install a freshly started task.  Caller must hold the lifecycle permit
    /// and must have already drained any previous task.
    async fn store(
        &self,
        cancel: tokio::sync::watch::Sender<bool>,
        handle: tokio::task::JoinHandle<()>,
    ) {
        let mut slot = self.slot.lock().await;
        slot.cancel = Some(cancel);
        slot.handle = Some(handle);
    }
}

fn validate_log_path_component(id: &str) -> CResult<()> {
    if id.is_empty() || id.contains('/') || id.contains("..") || id.contains('\0') {
        return Err(format!("invalid container id for log path: {}", id));
    }
    Ok(())
}

#[derive(Clone)]
pub struct Container {
    sandbox_id: String,
    id: String,
    real_id: String,
    spec: Spec,
    client: Option<Arc<Mutex<agent_ttrpc::AgentServiceClient>>>,
    ctx: Context,
    log: Log,
    sb_conf: Config,
    info: ContainerInfo,
    state: Option<ContainerState>,
    tx_containerd: Sender<(String, Box<dyn MessageDyn>)>,
    execs: Arc<Mutex<HashMap<String, Exec>>>,
    app_snapshot: bool,
    /// Canonical, strictly validated OCI linux.resources JSON for the
    /// negotiated V2 transport. `None` preserves the legacy Cubebox path.
    resources_v2: Option<Vec<u8>>,
    /// Background task forwarding container stdout/stderr to log files.
    /// Template creation: /data/log/template/<id>/stdout|stderr (755 dir).
    /// Normal sandbox: ./stdout and ./stderr relative to the bundle directory.
    /// Clones share the task ownership so exactly one caller takes and awaits
    /// it; start/stop are serialized across clones by an internal semaphore.
    log_forward: LogForwardHandle,
}

impl Container {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        sandbox_id: String,
        real_id: String,
        spec: Spec,
        client: Arc<Mutex<agent_ttrpc::AgentServiceClient>>,
        log: Log,
        sb_conf: Config,
        info: ContainerInfo,
        tx_containerd: Sender<(String, Box<dyn MessageDyn>)>,
        app_snapshot: bool,
        resources_v2: Option<Vec<u8>>,
    ) -> CResult<Self> {
        let mut id = real_id.clone();
        if let Some(annos) = spec.annotations().as_ref() {
            if let Some(cid) = annos.get(ANNO_APP_SNAPSHOT_CONTAINER_ID) {
                id = cid.clone();
                if sb_conf.app_snapshot_create {
                    return Err(format!(
                        "{} conflicts with {}",
                        ANNO_APP_SNAPSHOT_CONTAINER_ID, ANNO_APP_SNAPSHOT_CREATE
                    ));
                }
            }
        }
        let c = Container {
            sandbox_id,
            id,
            real_id,
            spec,
            client: Some(client),
            log,
            sb_conf,
            info,
            ctx: context::with_timeout(1000 * 1000 * 1000 * 10),
            state: None,
            execs: Arc::new(Mutex::new(HashMap::new())),
            tx_containerd,
            app_snapshot,
            resources_v2,
            log_forward: LogForwardHandle::new(),
        };
        Ok(c)
    }

    pub async fn pause_vm_forbidding(&self) -> bool {
        let execs = self.execs.lock().await;
        if execs.is_empty() {
            return false;
        }
        true
    }

    pub async fn set_client(
        &mut self,
        client: Arc<Mutex<agent_ttrpc::AgentServiceClient>>,
    ) -> CResult<()> {
        self.client = Some(client.clone());
        self.state = Some(ContainerState::new(self.log.clone()));
        let cli = self.client.as_ref().unwrap().lock().await;

        let state = self.state.as_mut().unwrap();
        let client_wait = cli.clone();
        let cid = self.id.clone();
        let real_id = self.real_id.clone();
        let tx_containerd = self.tx_containerd.clone();

        state
            .wait_process(client_wait, cid, real_id, String::new(), tx_containerd)
            .await;

        // Drop the client lock before attempting the async vsock connection.
        drop(cli);

        if self.passfd_io_enabled() {
            self.reconnect_passfd_io().await?;
        } else {
            // Restart legacy log forwarding after resume. Errors are non-fatal:
            // the container keeps running; we just lose log streaming for this session.
            if let Err(e) = self.start_log_forward().await {
                warnf!(self.log, "restart log forward failed after resume: {}", e);
            }
        }

        Ok(())
    }

    /// Stop init log forwarding (stdout/stderr).  Wakes the select! loops in
    /// forward_init_log_stdout/stderr and awaits the background task so vsock
    /// reads are finished before pause, snapshot, or destroy proceeds.
    pub async fn stop_log_forward(&mut self) {
        let _lifecycle = self.log_forward.acquire().await;
        self.log_forward.drain().await;
    }

    pub async fn unset_client(&mut self) {
        self.stop_log_forward().await;
        //terminate the wait req
        if self.state.is_some() {
            self.state.as_ref().unwrap().notify_vm_pause().await;
            self.state = None;
        }
        self.client = None;
    }

    fn get_storages(&mut self) -> CResult<Vec<agent::Storage>> {
        let mut storages = Vec::new();
        let spec = self.spec.clone();
        let mounts = self.spec.mounts_mut().as_mut().unwrap();
        //bind-share
        for m in mounts.iter_mut() {
            if let Some(t) = m.typ() {
                if t == CUBE_BIND_SHARE_TYPE {
                    let mut source = CPath::new(CUBE_BIND_SHARE_GUEST_BASE_DIR);

                    source.join(
                        m.source()
                            .clone()
                            .unwrap_or(PathBuf::new())
                            .to_str()
                            .unwrap_or(""),
                    );
                    m.set_source(Some(source.to_path_buf()));
                    m.set_typ(Some(common::MOUNT_TYPE_BIND.to_string()));

                    let s = agent::Storage {
                        driver: CUBE_BIND_SHARE_TYPE.to_string(),
                        mount_point: source.to_str().unwrap_or("").to_string(),
                        ..Default::default()
                    };
                    storages.push(s);
                    continue;
                }
            }

            if let Some(src) = m.source() {
                if let Some(i) = self.sb_conf.disk_path_map.get(src.to_str().unwrap()) {
                    let index = *i as usize;
                    let disk = self.sb_conf.disk.get(index).unwrap_or_else(|| {
                        panic!("BUG: sandbox.conf.disk, invalid index:{}", index)
                    });
                    let src = disk.guest_bind_source(*i, m.options());
                    m.set_typ(Some(common::MOUNT_TYPE_BIND.to_string()));
                    m.set_source(Some(PathBuf::from(src)));
                    continue;
                }

                if let Some(i) = self.sb_conf.pmem_path_map.get(src.to_str().unwrap()) {
                    let index = *i as usize;
                    let pmem = self.sb_conf.pmem.get(index).unwrap_or_else(|| {
                        panic!("BUG: sandbox.conf.pmem, invalid index:{}", index)
                    });
                    let src = pmem.guest_bind_source(*i);
                    m.set_typ(Some(common::MOUNT_TYPE_BIND.to_string()));
                    m.set_source(Some(PathBuf::from(src)));
                    continue;
                }

                if let Some(i) = self.sb_conf.vfio_disk_path_map.get(src.to_str().unwrap()) {
                    let index = *i as usize;
                    let vfio_disk = self.sb_conf.vfio_disks.get(index).unwrap_or_else(|| {
                        panic!("BUG: sandbox.conf.vfio_disks, invalid index:{}", index)
                    });
                    let src = vfio_disk.guest_pci_source(m.options());
                    m.set_typ(Some(common::MOUNT_TYPE_BIND.to_string()));
                    m.set_source(Some(PathBuf::from(src)));
                    continue;
                }
            }
        }

        let anno = spec.annotations().as_ref().unwrap();
        if let Some(mount_str) = anno.get(ANNO_PROPAGATION_CONTAINER_MNTS) {
            let pmounts = Utils::anno_to_obj::<Vec<PropagationContainerMount>>(mount_str)?;
            for mnt in pmounts {
                let mut m = Mount::default();
                m.set_typ(Some(common::MOUNT_TYPE_BIND.to_string()));
                m.set_destination(PathBuf::from(mnt.container_dir.clone()));
                let mut mpath = CPath::new(CUBE_BIND_SHARE_GUEST_BASE_DIR);
                mpath.join(mnt.name.as_str());
                m.set_source(Some(mpath.to_path_buf()));
                //propagation-mnt: Tell the agent not to overwrite the mountpoint if the path already exists
                m.set_options(Some(vec![
                    "propagation-mnt".to_string(),
                    "bind".to_string(),
                    "rslave".to_string(),
                ]));
                mounts.push(m);
            }
        }

        Ok(storages)
    }

    fn get_pb_spec(&mut self) -> CResult<oci::Spec> {
        let node_allows_privileged = if requests_guest_privileged(&self.spec) {
            parse_privileged_node_switch(std::env::var_os(CUBE_ALLOW_PRIVILEGED_ENV).as_deref())?
        } else {
            false
        };
        self.get_pb_spec_with_privileged_policy(node_allows_privileged)
    }

    fn get_pb_spec_with_privileged_policy(
        &mut self,
        node_allows_privileged: bool,
    ) -> CResult<oci::Spec> {
        validate_seccomp_transport(&self.spec)?;
        let guest_privileged = validate_guest_privileged_input(&self.spec, node_allows_privileged)?;

        let json_str = serde_json::to_string(&self.spec)
            .map_err(|e| format!("serialize spec failed:{}", e))?;

        let mut spec: oci::Spec = serde_json::from_str(&json_str)
            .map_err(|e| format!("deserialize spec failed:{}", e))?;

        let proc = spec.mut_process();
        proc.set_selinuxLabel(String::new());

        let res = spec.mut_linux().mut_resources();
        res.clear_devices();
        if guest_privileged {
            res.mut_devices().push(guest_all_devices_rule());
        }
        res.clear_pids();
        res.clear_blockIO();

        res.mut_cpu().clear_cpus();
        res.mut_cpu().clear_mems();
        if let Some(payload) = self.resources_v2.as_ref() {
            res.set_resourceV2(resources::envelope(payload.clone()));
        }

        let mut nss = Vec::new();
        for ns in spec.get_linux().get_namespaces() {
            if ns.field_type == common::NS_CGROUP
                || ns.field_type == common::NS_NET
                || ns.field_type == common::NS_PID
            {
                continue;
            }
            let mut n = ns.clone();
            n.set_path(String::new());
            nss.push(n);
        }
        spec.mut_linux().set_namespaces(nss.into());

        //rootfs is writeable
        let anno = spec.mut_annotations();
        if let Some(path) = anno.get(common::ANNO_ROOTFS_WLAYER_PATH) {
            let subdir = anno.get(common::ANNO_ROOTFS_WLAYER_PATH_SUBDIR);
            if let Some(i) = self.sb_conf.disk_path_map.get(path) {
                let index = *i as usize;
                let disk =
                    self.sb_conf.disk.get(index).unwrap_or_else(|| {
                        panic!("BUG: sandbox.conf.disk, invalid index:{}", index)
                    });

                let src = if let Some(subdir) = subdir {
                    disk.guest_bind_source_with_subdir(*i, &None, subdir.clone())
                } else {
                    disk.guest_bind_source(*i, &None)
                };
                anno.insert(common::ANNO_ROOTFS_WLAYER_PATH.to_string(), src);
            } else {
                // cbs系统盘
                if let Some(i) = self.sb_conf.vfio_disk_path_map.get(path).cloned() {
                    let disk = self.sb_conf.vfio_disks.get(i as usize).unwrap_or_else(|| {
                        panic!("BUG: sandbox.conf.vfio_disks, invalid index:{}", i)
                    });
                    if disk.platform {
                        let src = if let Some(subdir) = subdir {
                            disk.guest_pci_source_with_subdir(&None, subdir.clone())
                        } else {
                            disk.guest_pci_source(&None)
                        };

                        anno.insert(common::ANNO_ROOTFS_WLAYER_PATH.to_string(), src);
                    }
                }
            }
        }

        //rootfs by pmem
        if let Some(pmem_rootfs) = anno.get(rootfs::ANNOTATION_K_ROOTFS_INFO) {
            let mut rootfs = rootfs::RootfsInfo::new(pmem_rootfs)?;

            if self.app_snapshot && (rootfs.overlay_info.is_some() || rootfs.mounts.is_some()) {
                rootfs.overlay_info = None;
                rootfs.mounts = None;
            }

            if let Some(pmem_file) = rootfs.pmem_file.clone() {
                if let Some(i) = self.sb_conf.pmem_path_map.get(&pmem_file) {
                    let index = *i as usize;
                    let pmem = self.sb_conf.pmem.get(index).unwrap_or_else(|| {
                        panic!("BUG: sandbox.conf.pmem, invalid index:{}", index)
                    });
                    let src = pmem.guest_bind_source(*i);
                    rootfs.pmem_file = Some(src);
                }
            } else if let Some(ero_image) = rootfs.ero_image.as_mut() {
                if let Some(i) = self.sb_conf.disk_path_map.get(&ero_image.path) {
                    let index = *i as usize;
                    let disk = self.sb_conf.disk.get(index).unwrap_or_else(|| {
                        panic!("BUG: sandbox.conf.pmem, invalid index:{}", index)
                    });
                    ero_image.path = disk.guest_bind_source(*i, &None);
                }
            }
            rootfs.fix_virtiofs();
            let rootfs_str = serde_json::to_string(&rootfs)
                .map_err(|e| format!("Serialize rootfs failed:{}", e))?;
            anno.insert(rootfs::ANNOTATION_K_ROOTFS_INFO.to_string(), rootfs_str);
        }

        for m in spec.mut_mounts().iter_mut() {
            if m.get_destination() == "/dev/shm" {
                m.set_source(GUEST_DEV_SHM.to_string());
                m.set_field_type(MOUNT_TYPE_BIND.to_string());
                m.set_options(vec![MOUNT_TYPE_RBIND.to_string()].into());
                break;
            }
        }

        // Signal to the agent that this shim supports container log forwarding.
        // The agent reads this annotation in do_create_container and sets
        // p.log_forwarding = true causes open_io() to create init log pipes only
        // (exec processes are unaffected; they use the pre-log-forwarding path).
        spec.mut_annotations().insert(
            common::ANNO_CONTAINER_LOG_FORWARDING.to_string(),
            "true".to_string(),
        );

        Ok(spec)
    }

    fn get_custom_files(&mut self) -> CResult<Vec<CustomFile>> {
        if self.spec.annotations().is_none() {
            return Ok(Vec::<CustomFile>::new());
        }

        let data = self
            .spec
            .annotations()
            .as_ref()
            .unwrap()
            .get(ANNO_CONTAINER_CUSTOM_FILE);
        if data.is_none() {
            return Ok(Vec::<CustomFile>::new());
        }

        let data = data.unwrap();
        let files = serde_json::from_str::<Vec<CustomFile>>(data)
            .map_err(|e| format!("deserialize custom file failed:{}", e))?;

        Ok(files)
    }

    fn new_stat(&self, callee_act: String) -> StatDefer {
        stat_defer::StatDefer::new(
            self.real_id.clone(),
            stat_defer::CALLEE_AGENT.to_string(),
            stat_defer::ACT_CREATE.to_string(),
            callee_act,
            self.log.clone(),
        )
    }

    fn is_cold_start(&self) -> bool {
        self.id == self.real_id
    }

    /// Template creation writes stdout/stderr to regular files under
    /// /data/log/template. Regular files cannot be registered with epoll, so
    /// keep that path on the legacy RPC log forwarder even when passfd is the
    /// sandbox default.
    fn passfd_io_enabled(&self) -> bool {
        self.sb_conf.use_passfd_io && !self.sb_conf.app_snapshot_create
    }

    pub async fn create_container(&mut self) -> CResult<()> {
        let mut stat = self.new_stat(stat_defer::CALLEE_ACT_CREATE_CONTAINER.to_string());

        let (stdin_port, stdout_port, stderr_port) = if self.passfd_io_enabled() {
            let (i, o, e) = crate::common::utils::AsyncUtils::setup_passfd_streams(
                &self.sandbox_id,
                &self.info.stdin,
                &self.info.stdout,
                &self.info.stderr,
            )
            .await?;
            infof!(
                self.log,
                "passfd streams ready for create, id:{}, stdin_port:{}, stdout_port:{}, stderr_port:{}",
                self.real_id,
                i,
                o,
                e
            );
            (i, o, e)
        } else {
            (0, 0, 0)
        };

        let req = agent::CreateContainerRequest {
            container_id: self.id.clone(),
            exec_id: self.id.clone(),
            storages: self.get_storages()?.into(),
            OCI: Some(self.get_pb_spec()?).into(),
            custom_files: self.get_custom_files()?.into(),
            stdin_port,
            stdout_port,
            stderr_port,
            sandbox_pidns: self.sb_conf.sandbox_pidns,
            ..Default::default()
        };

        let client = self.client.as_ref().unwrap().lock().await;

        client
            .create_container(self.ctx.clone(), &req)
            .await
            .map_err(|e: ttrpc::Error| format!("create container failed:{}", e))?;

        self.state = Some(ContainerState::new(self.log.clone()));
        stat.set_ok();
        Ok(())
    }

    async fn reconnect_passfd_io(&mut self) -> CResult<()> {
        let (stdin_port, stdout_port, stderr_port) = AsyncUtils::setup_passfd_streams(
            &self.sandbox_id,
            &self.info.stdin,
            &self.info.stdout,
            &self.info.stderr,
        )
        .await?;

        if stdin_port == 0 && stdout_port == 0 && stderr_port == 0 {
            return Ok(());
        }

        infof!(
            self.log,
            "passfd streams ready for reconnect, id:{}, stdin_port:{}, stdout_port:{}, stderr_port:{}",
            self.real_id,
            stdin_port,
            stdout_port,
            stderr_port
        );

        let req = agent::ReconnectContainerIORequest {
            container_id: self.id.clone(),
            stdin_port,
            stdout_port,
            stderr_port,
            ..Default::default()
        };

        let client = self.client.as_ref().unwrap().lock().await;
        client
            .reconnect_container_io(self.ctx.clone(), &req)
            .await
            .map_err(|e| format!("reconnect container io failed:{}", e))?;

        Ok(())
    }

    pub async fn start_container(&mut self) -> CResult<()> {
        if !self.passfd_io_enabled() {
            self.start_log_forward().await?;
        }

        let client = self.client.as_ref().unwrap().lock().await;
        if self.is_cold_start() {
            let req = agent::StartContainerRequest {
                container_id: self.id.clone(),
                ..Default::default()
            };
            client
                .start_container(self.ctx.clone(), &req)
                .await
                .map_err(|e| format!("start container failed:{}", e))?;
        }
        if !self.sb_conf.app_snapshot_create {
            if self.state.is_none() {
                return Err("BUG: start container failed, state is none".to_string());
            }
            let state = self.state.as_mut().unwrap();
            let client_wait = client.clone();
            let cid = self.id.clone();
            let real_id = self.real_id.clone();
            let tx_containerd = self.tx_containerd.clone();
            state
                .wait_process(client_wait, cid, real_id, String::new(), tx_containerd)
                .await;
        }

        Ok(())
    }

    /// Spawn a background task that streams container stdout/stderr from the
    /// agent (via a fresh vsock connection) and appends them to log files.
    /// Template creation writes to `/data/log/template/<id>/stdout|stderr`;
    /// normal sandbox restore writes to `./stdout` and `./stderr` relative
    /// to the shim's current working directory (the bundle directory).
    ///
    /// The task exits cleanly when `stop_log_forward` is called (pause /
    /// snapshot / kill / destroy): a watch cancel signal is sent first so the
    /// forwarding loops
    /// wake immediately, then the caller awaits the handle to confirm the vsock
    /// read has stopped before proceeding.
    pub async fn start_log_forward(&mut self) -> CResult<()> {
        // Cancel and await any previous instance before starting a new one.
        let _lifecycle = self.log_forward.acquire().await;
        self.log_forward.drain().await;

        // Open a dedicated vsock connection for streaming I/O so that the
        // main client connection used for control-plane RPCs is never blocked.
        // Bound the connect: it runs while holding log_forward_lifecycle, so a
        // hung agent would otherwise wedge every start/stop (pause, snapshot,
        // kill, destroy) on this container and its clones indefinitely.
        let log_conn = tokio::time::timeout(
            LOG_FORWARD_CONNECT_TIMEOUT,
            AsyncUtils::connect_agent(&self.sandbox_id),
        )
        .await
        .map_err(|_| {
            format!(
                "connect agent for log forwarding timed out after {}s",
                LOG_FORWARD_CONNECT_TIMEOUT.as_secs()
            )
        })?
        .map_err(|e| format!("connect agent for log forwarding failed:{}", e))?;
        let log_client = agent_ttrpc::AgentServiceClient::new(log_conn);

        // Write log files:
        //   - template creation: /data/log/template/<id>/stdout|stderr
        //   - sandbox (restore): current working directory (bundle dir)
        let (stdout_path, stderr_path) = if self.sb_conf.app_snapshot_create {
            validate_log_path_component(&self.info.id)?;
            let log_dir = format!("/data/log/template/{}", self.info.id);
            tokio::fs::create_dir_all(&log_dir)
                .await
                .map_err(|e| format!("create log dir {} failed: {}", log_dir, e))?;
            // Do NOT call set_permissions/chmod here: chmod(2) is blocked by
            // the VM's seccomp policy and triggers SIGSYS. The directory
            // created by create_dir_all() inherits the process umask which is
            // already restrictive enough for log files.
            (format!("{}/stdout", log_dir), format!("{}/stderr", log_dir))
        } else {
            ("stdout".to_string(), "stderr".to_string())
        };

        // Init log forwarding is separate from exec I/O relay (forward_std).
        // exec_id must be empty so agent read_stdout/read_stderr target the init process.
        let log_exec = Exec {
            container_id: self.id.clone(),
            id: String::new(),
            tty: Tty {
                stdin: String::new(),
                stdout: stdout_path.clone(),
                stderr: stderr_path.clone(),
                ..Default::default()
            },
            state: self.state.clone(),
            ..Default::default()
        };

        infof!(
            self.log,
            "starting log forwarding for container:{} stdout:{} stderr:{}",
            self.real_id,
            stdout_path,
            stderr_path
        );

        // Create a watch cancel channel.  The tx is stored in the log_forward
        // slot; on stop (pause / snapshot / kill / destroy) `stop_log_forward`
        // calls `LogForwardHandle::drain()`, which takes the tx and sends true.
        // The rx is cloned into each of forward_init_log_stdout and
        // forward_init_log_stderr so both loops wake and exit immediately via
        // tokio::select!.
        let (cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);

        let handle = log_exec
            .start_log_forward(log_client, self.log.clone(), cancel_rx)
            .await;
        self.log_forward.store(cancel_tx, handle).await;

        Ok(())
    }

    async fn do_signal_container(&mut self, exec_id: &String, sig: u32) -> CResult<()> {
        infof!(
            self.log,
            "signal {} to container:{}, exec:{}",
            sig,
            &self.real_id,
            exec_id
        );
        let req = agent::SignalProcessRequest {
            container_id: self.id.clone(),
            exec_id: exec_id.clone(),
            signal: sig,
            ..Default::default()
        };
        let client = self.client.as_ref().unwrap().lock().await;

        if let Err(err) = client.signal_process(self.ctx.clone(), &req).await {
            let err_msg = err.to_string();
            if sig == libc::SIGPIPE as u32 && err_msg.contains("Invalid exec id") {
                warnf!(
                    self.log,
                    "ignore SIGPIPE for exited exec:{}, container:{}",
                    exec_id,
                    &self.real_id
                );
                return Ok(());
            }

            let e = format!(
                "signal process failed:{}, execid:{}, sig:{}",
                err_msg,
                exec_id.to_owned(),
                sig
            );
            //forcibly change the result of the kill request to success,
            //so that the cubelet can successfully complete the destruction work.
            if sig != (libc::SIGKILL as u32) && sig != (libc::SIGTERM as u32) {
                return Err(e);
            }
        }

        Ok(())
    }

    pub async fn close_io(&self, exec_id: &String) -> Result<()> {
        let req = agent::CloseStdinRequest {
            container_id: self.id.clone(),
            exec_id: exec_id.clone(),
            ..Default::default()
        };
        let client = self.client.as_ref().unwrap().lock().await;

        if let Err(err) = client.close_stdin(self.ctx.clone(), &req).await {
            let err_msg = err.to_string();
            warnf!(self.log, "close_io failed:{}, execid:{}", err_msg, exec_id);
            return Err(Error::Other(format!("close_io failed: {}", err_msg)));
        }

        Ok(())
    }

    pub async fn signal_container(&mut self, exec_id: &String, sig: u32) -> Result<()> {
        {
            let state = self.state.as_ref().unwrap();
            if !state.is_running().await {
                if sig == (libc::SIGKILL as u32) || sig == (libc::SIGTERM as u32) {
                    //stop the container to unblock the hanging 'wait' call
                    if self.sb_conf.app_snapshot_create {
                        state.set_container_stoped().await;
                    }
                    if exec_id.is_empty() {
                        self.stop_log_forward().await;
                    }
                    return Ok(());
                }
                infof!(
                    self.log,
                    "container:{} has exited, can't be killed",
                    &self.real_id
                );
                return Err(Error::Other(format!(
                    "container:{} has exited",
                    &self.real_id
                )));
            }
        }

        if !exec_id.is_empty() {
            let exec = {
                let execs = self.execs.lock().await;
                let exec = execs.get(exec_id);
                if exec.is_none() {
                    warnf!(
                        self.log,
                        "not found exec:{} in container:{}, can't be signaled",
                        exec_id,
                        &self.real_id
                    );
                    return Err(Error::NotFoundError(format!(
                        "not found exec:{} in container:{}, can't be signaled",
                        exec_id, &self.real_id
                    )));
                }
                exec.cloned().unwrap()
            };

            if !exec.state.as_ref().unwrap().is_running().await {
                if sig == (libc::SIGKILL as u32) || sig == (libc::SIGTERM as u32) {
                    return Ok(());
                }
                infof!(self.log, "exec:{} has exited, can't be killed", &exec_id);
                return Err(Error::Other(format!(
                    "container:{} exec:{} has exited, can't be killed",
                    &self.real_id, exec_id
                )));
            }
        }

        self.do_signal_container(exec_id, sig)
            .await
            .map_err(|e| Error::Other(e.to_string()))?;

        if exec_id.is_empty() && (sig == (libc::SIGKILL as u32) || sig == (libc::SIGTERM as u32)) {
            self.stop_log_forward().await;
        }

        Ok(())
    }

    pub async fn destroy_container(&mut self) -> Result<(u32, DateTime<Utc>)> {
        // kill then stop log forwarding (also done inside signal_container)
        self.signal_container(&"".to_string(), libc::SIGKILL as u32)
            .await?;

        //remove
        //todo:remove container in guest
        //be lazy here
        Ok(self.state.as_ref().unwrap().get_exit_info().await)
    }

    pub async fn get_container_info(&self, exec_id: &String) -> Result<ContainerInfo> {
        if exec_id.is_empty() {
            let mut info = self.info.clone();
            if self.state.is_some() {
                let task_state = self.state.as_ref().unwrap();
                info.state = task_state.state().await;
                if info.state == TaskState::STOPPED {
                    let (code, tm) = task_state.get_exit_info().await;
                    info.exit_code = code;
                    info.exit_tm = Some(tm);
                }
            }
            return Ok(info);
        }
        let execs = self.execs.lock().await;
        let exec = match execs.get(exec_id) {
            Some(e) => e,
            None => {
                return Err(Error::NotFoundError(format!(
                    "Exec id:{} not found, container:{}",
                    exec_id, &self.real_id
                )))
            }
        };

        let mut ci = ContainerInfo {
            id: exec.id.clone(),
            bundle: self.info.bundle.clone(),
            stdout: exec.tty.stdout.clone(),
            stderr: exec.tty.stderr.clone(),
            terminal: exec.tty.terminal,
            ..Default::default()
        };

        let task_state = exec.state.as_ref().unwrap();
        ci.state = task_state.state().await;
        if ci.state == TaskState::STOPPED {
            let (code, tm) = task_state.get_exit_info().await;
            ci.exit_code = code;
            ci.exit_tm = Some(tm);
        }
        Ok(ci)
    }

    pub async fn wait_container(&mut self, exec_id: &String) -> Result<(u32, DateTime<Utc>)> {
        if *exec_id == self.real_id {
            if self.state.is_none() {
                return Err(Error::Other(
                    "BUG: start container failed, state is none".to_string(),
                ));
            }
            let (code, tm) = self.state.as_ref().unwrap().wait_exit_info().await;
            return Ok((code, tm));
        }

        let exec = {
            let execs = self.execs.lock().await;
            let exec = match execs.get(exec_id) {
                Some(e) => e,
                None => {
                    return Err(Error::NotFoundError(format!(
                        "Exec id:{} not found, container:{}",
                        exec_id, &self.real_id
                    )))
                }
            };
            exec.clone()
        };

        let (code, tm) = exec.state.as_ref().unwrap().wait_exit_info().await;
        Ok((code, tm))
    }

    pub async fn create_exec(&mut self, exec_id: &String, tty: Tty, proc: Process) -> CResult<()> {
        let mut execs = self.execs.lock().await;
        if execs.contains_key(exec_id) {
            return Err(format!(
                "Exec id:{} has exists, container:{}",
                exec_id, &self.real_id
            ));
        }
        let _cs = ContainerState::new(self.log.clone());

        let exec = Exec {
            container_id: self.id.clone(),
            id: exec_id.clone(),
            tty,
            proc,
            state: Some(ContainerState::new(self.log.clone())),
        };
        execs.insert(exec.id.clone(), exec);
        Ok(())
    }

    pub async fn start_exec(&mut self, exec_id: &String) -> Result<()> {
        let exec = {
            let execs = self.execs.lock().await;
            let exec = match execs.get(exec_id) {
                Some(e) => e,
                None => {
                    return Err(Error::NotFoundError(format!(
                        "Exec id:{} not found, container:{}",
                        exec_id, &self.real_id
                    )))
                }
            };
            exec.clone()
        };

        let proc = exec_process_for_agent(&exec.proc, exec.tty.terminal).map_err(Error::Other)?;

        let (stdin_port, stdout_port, stderr_port) = if self.passfd_io_enabled() {
            let (i, o, e) = crate::common::utils::AsyncUtils::setup_passfd_streams(
                &self.sandbox_id,
                &exec.tty.stdin,
                &exec.tty.stdout,
                &exec.tty.stderr,
            )
            .await
            .map_err(Error::Other)?;
            infof!(
                self.log,
                "passfd streams ready for exec, id:{}, execid:{}, stdin_port:{}, stdout_port:{}, stderr_port:{}",
                self.real_id,
                exec_id,
                i,
                o,
                e
            );
            (i, o, e)
        } else {
            (0, 0, 0)
        };

        let mut req = agent::ExecProcessRequest {
            container_id: self.id.clone(),
            exec_id: exec_id.clone(),
            process: Some(proc).into(),
            stdin_port,
            stdout_port,
            stderr_port,
            ..Default::default()
        };

        let runtime_prefix = "runtime:unix://";
        if exec.tty.stdin.starts_with(runtime_prefix) {
            req.runtime_unix_addr = exec
                .tty
                .stdin
                .strip_prefix(runtime_prefix)
                .unwrap_or("")
                .to_string();
        }
        let client = self.client.as_ref().unwrap().lock().await;

        let _ = client
            .exec_process(self.ctx.clone(), &req)
            .await
            .map_err(|e| Error::Other(format!("start execid:{} failed:{}", exec_id, e)))?;
        let mut state = exec.state.clone().unwrap();
        let client_wait = client.clone();
        let cid = self.id.clone();
        let real_id = self.real_id.clone();
        let exec_id = exec_id.clone();
        let tx_containerd = self.tx_containerd.clone();

        state
            .wait_process(client_wait, cid, real_id, exec_id, tx_containerd)
            .await;

        if !self.passfd_io_enabled() {
            let conn = AsyncUtils::connect_agent(&self.sandbox_id)
                .await
                .map_err(|e| Error::Other(e.to_string()))?;
            let std_client = agent_ttrpc::AgentServiceClient::new(conn);
            exec.forward_std(exec.state.clone().unwrap(), std_client, self.log.clone())
                .await;
        }

        Ok(())
    }

    pub async fn destroy_exec(&mut self, exec_id: &String) -> CResult<(u32, DateTime<Utc>)> {
        let mut exit_code = 255;
        let mut exit_tm = Utc::now();
        //delete exec
        let exec = {
            let execs = self.execs.lock().await;
            let exec = execs.get(exec_id);
            if exec.is_none() {
                warnf!(
                    self.log,
                    "destroy exec:not found exec:{} in container:{}",
                    exec_id,
                    &self.real_id
                );
                return Ok((exit_code, exit_tm));
            }
            exec.cloned().unwrap()
        };

        if exec.state.as_ref().unwrap().is_running().await {
            self.do_signal_container(exec_id, libc::SIGKILL as u32)
                .await?;
        }

        (exit_code, exit_tm) = exec.state.as_ref().unwrap().get_exit_info().await;

        let mut execs = self.execs.lock().await;
        let _ = execs.remove(exec_id);

        Ok((exit_code, exit_tm))
    }

    pub async fn update(&self, res: &LinuxResources, resources_v2: Option<&[u8]>) -> CResult<()> {
        validate_unchanged_device_update(&self.spec, res)?;
        let mut pb_res = oci::LinuxResources::default();

        if let Some(c) = res.cpu() {
            let cpu = pb_res.mut_cpu();

            if let Some(v) = c.shares() {
                cpu.set_shares(v);
            }

            if let Some(v) = c.quota() {
                cpu.set_quota(v);
            }

            if let Some(v) = c.period() {
                cpu.set_period(v);
            }

            if let Some(v) = c.cpus() {
                cpu.set_cpus(v.clone());
            }
        }

        if let Some(mem) = res.memory() {
            if let Some(limit) = mem.limit() {
                pb_res.mut_memory().set_limit(limit);
            }
        }
        if let Some(payload) = resources_v2 {
            pb_res.set_resourceV2(resources::envelope(payload.to_vec()));
        }

        let req = agent::UpdateContainerRequest {
            container_id: self.id.clone(),
            resources: Some(pb_res).into(),
            ..Default::default()
        };
        let client = self.client.as_ref().unwrap().lock().await;

        let _ = client
            .update_container(self.ctx.clone(), &req)
            .await
            .map_err(|e| format!("update container:{} failed:{}", &self.real_id, e))?;
        Ok(())
    }

    pub async fn notify_vm_shutdown(&self) {
        if let Some(state) = &self.state {
            state.notify_vm_shutdown().await;
        }

        let execs = self.execs.lock().await;
        for (_, exec) in execs.iter() {
            if let Some(state) = &exec.state {
                state.notify_vm_shutdown().await;
            }
        }
    }

    pub fn get_id(&self) -> String {
        self.id.clone()
    }
}

#[cfg(test)]
mod identity_translation_tests {
    use super::*;
    use nix::sys::socket::{socketpair, AddressFamily, SockFlag, SockType};
    use std::os::fd::IntoRawFd;
    use tokio::sync::mpsc::channel;

    fn sorted_capabilities(values: &[String]) -> Vec<&str> {
        let mut sorted: Vec<_> = values.iter().map(String::as_str).collect();
        sorted.sort_unstable();
        sorted
    }

    fn container_with_spec(spec_json: serde_json::Value) -> Container {
        let spec: Spec = serde_json::from_value(spec_json).unwrap();
        let (client_fd, _peer_fd) = socketpair(
            AddressFamily::Unix,
            SockType::Stream,
            None,
            SockFlag::empty(),
        )
        .unwrap();
        let client = ttrpc::r#async::Client::new(client_fd.into_raw_fd());
        let agent_client = Arc::new(Mutex::new(agent_ttrpc::AgentServiceClient::new(client)));
        let (tx, _) = channel::<(String, Box<dyn MessageDyn>)>(8);
        Container::new(
            "identity-sandbox".to_string(),
            "identity-container".to_string(),
            spec,
            agent_client,
            Log::default(),
            Config::default(),
            ContainerInfo::default(),
            tx,
            false,
            None,
        )
        .unwrap()
    }

    fn container_with_process(process_json: serde_json::Value) -> Container {
        container_with_spec(serde_json::json!({
            "ociVersion": "1.0.2",
            "process": process_json,
            "linux": {}
        }))
    }

    fn resources_with_devices(devices: serde_json::Value) -> LinuxResources {
        serde_json::from_value(serde_json::json!({"devices": devices})).unwrap()
    }

    #[test]
    fn update_allows_absent_or_create_time_device_policy() {
        let spec: Spec = serde_json::from_value(serde_json::json!({
            "ociVersion": "1.0.2",
            "linux": {"resources": {"devices": [
                {"allow": true, "type": "c", "major": 1, "minor": 3, "access": "rwm"},
                {"allow": true, "type": "c", "major": 1, "minor": 5, "access": "rw"}
            ]}}
        }))
        .unwrap();
        let absent: LinuxResources = serde_json::from_value(serde_json::json!({})).unwrap();
        let unchanged = resources_with_devices(serde_json::json!([
            {"allow": true, "type": "c", "major": 1, "minor": 3, "access": "rwm"},
            {"allow": true, "type": "c", "major": 1, "minor": 5, "access": "rw"}
        ]));
        assert!(validate_unchanged_device_update(&spec, &absent).is_ok());
        assert!(validate_unchanged_device_update(&spec, &unchanged).is_ok());

        let no_policy: Spec = serde_json::from_value(serde_json::json!({
            "ociVersion": "1.0.2",
            "linux": {"resources": {}}
        }))
        .unwrap();
        let empty = resources_with_devices(serde_json::json!([]));
        assert!(validate_unchanged_device_update(&no_policy, &empty).is_ok());
    }

    #[test]
    fn update_rejects_changed_or_reordered_device_policy() {
        let spec: Spec = serde_json::from_value(serde_json::json!({
            "ociVersion": "1.0.2",
            "linux": {"resources": {"devices": [
                {"allow": true, "type": "c", "major": 1, "minor": 3, "access": "rwm"},
                {"allow": true, "type": "c", "major": 1, "minor": 5, "access": "rw"}
            ]}}
        }))
        .unwrap();
        for changed in [
            resources_with_devices(serde_json::json!([
                {"allow": true, "type": "c", "major": 1, "minor": 5, "access": "rw"},
                {"allow": true, "type": "c", "major": 1, "minor": 3, "access": "rwm"}
            ])),
            resources_with_devices(serde_json::json!([
                {"allow": false, "type": "c", "major": 1, "minor": 3, "access": "rwm"},
                {"allow": true, "type": "c", "major": 1, "minor": 5, "access": "rw"}
            ])),
        ] {
            let error = validate_unchanged_device_update(&spec, &changed).unwrap_err();
            assert!(error.contains("device policy is create-only"), "{error}");
        }
    }

    fn privileged_spec_json() -> serde_json::Value {
        serde_json::json!({
            "ociVersion": "1.0.2",
            "process": {
                "user": {"uid": 0, "gid": 0},
                "args": ["true"],
                "cwd": "/",
                "capabilities": {
                    "bounding": ["CAP_SYS_ADMIN", "CAP_SYS_MODULE", "CAP_SYS_RAWIO"],
                    "effective": ["CAP_SYS_ADMIN", "CAP_SYS_MODULE", "CAP_SYS_RAWIO"],
                    "inheritable": [],
                    "permitted": ["CAP_SYS_ADMIN", "CAP_SYS_MODULE", "CAP_SYS_RAWIO"],
                    "ambient": []
                }
            },
            "linux": {
                "devices": [],
                "resources": {
                    "devices": [{"allow":true, "access":"rwm"}]
                },
                "maskedPaths": [],
                "readonlyPaths": []
            }
        })
    }

    #[tokio::test]
    async fn create_process_preserves_numeric_identity_and_group_order() {
        let mut container = container_with_process(serde_json::json!({
            "user": {
                "uid": 1234,
                "gid": 2345,
                "additionalGids": [2345, 4567, 3456, 2345]
            },
            "args": ["id"],
            "cwd": "/"
        }));

        let spec = container.get_pb_spec().unwrap();
        let user = spec.get_process().get_user();
        assert_eq!(user.get_uid(), 1234);
        assert_eq!(user.get_gid(), 2345);
        assert_eq!(user.get_additionalGids(), &[2345, 4567, 3456, 2345]);
    }

    #[tokio::test]
    async fn create_process_does_not_synthesize_additional_groups() {
        let mut container = container_with_process(serde_json::json!({
            "user": {"uid": 65534, "gid": 65533},
            "args": ["id"],
            "cwd": "/"
        }));

        let spec = container.get_pb_spec().unwrap();
        let user = spec.get_process().get_user();
        assert_eq!(user.get_uid(), 65534);
        assert_eq!(user.get_gid(), 65533);
        assert!(user.get_additionalGids().is_empty());
    }

    #[tokio::test]
    async fn create_process_preserves_capability_sets_and_readonly_rootfs() {
        let mut container = container_with_spec(serde_json::json!({
            "ociVersion": "1.0.2",
            "process": {
                "user": {"uid": 0, "gid": 0},
                "args": ["id"],
                "cwd": "/",
                "capabilities": {
                    "bounding": ["CAP_NET_RAW", "CAP_NET_BIND_SERVICE", "CAP_CHECKPOINT_RESTORE"],
                    "effective": ["CAP_CHECKPOINT_RESTORE", "CAP_NET_RAW"],
                    "inheritable": ["CAP_NET_BIND_SERVICE"],
                    "permitted": ["CAP_CHECKPOINT_RESTORE", "CAP_NET_RAW", "CAP_NET_BIND_SERVICE"],
                    "ambient": ["CAP_NET_BIND_SERVICE"]
                }
            },
            "root": {"path": "rootfs", "readonly": true},
            "linux": {}
        }));

        let spec = container.get_pb_spec().unwrap();
        assert!(spec.has_process());
        assert!(spec.get_process().has_capabilities());
        assert!(spec.has_root());
        assert_eq!(spec.get_root().get_path(), "rootfs");
        let capabilities = spec.get_process().get_capabilities();
        assert_eq!(
            sorted_capabilities(capabilities.get_bounding()),
            [
                "CAP_CHECKPOINT_RESTORE",
                "CAP_NET_BIND_SERVICE",
                "CAP_NET_RAW",
            ]
        );
        assert_eq!(
            sorted_capabilities(capabilities.get_effective()),
            ["CAP_CHECKPOINT_RESTORE", "CAP_NET_RAW"]
        );
        assert_eq!(
            sorted_capabilities(capabilities.get_inheritable()),
            ["CAP_NET_BIND_SERVICE"]
        );
        assert_eq!(
            sorted_capabilities(capabilities.get_permitted()),
            [
                "CAP_CHECKPOINT_RESTORE",
                "CAP_NET_BIND_SERVICE",
                "CAP_NET_RAW",
            ]
        );
        assert_eq!(
            sorted_capabilities(capabilities.get_ambient()),
            ["CAP_NET_BIND_SERVICE"]
        );
        assert!(spec.get_root().get_readonly());
    }

    #[tokio::test]
    async fn create_process_preserves_empty_capability_sets_and_writable_rootfs() {
        let mut container = container_with_spec(serde_json::json!({
            "ociVersion": "1.0.2",
            "process": {
                "user": {"uid": 0, "gid": 0},
                "args": ["id"],
                "cwd": "/",
                "capabilities": {
                    "bounding": [],
                    "effective": [],
                    "inheritable": [],
                    "permitted": [],
                    "ambient": []
                }
            },
            "root": {"path": "rootfs", "readonly": false},
            "linux": {}
        }));

        let spec = container.get_pb_spec().unwrap();
        assert!(spec.has_process());
        assert!(spec.get_process().has_capabilities());
        assert!(spec.has_root());
        assert_eq!(spec.get_root().get_path(), "rootfs");
        let capabilities = spec.get_process().get_capabilities();
        assert!(capabilities.get_bounding().is_empty());
        assert!(capabilities.get_effective().is_empty());
        assert!(capabilities.get_inheritable().is_empty());
        assert!(capabilities.get_permitted().is_empty());
        assert!(capabilities.get_ambient().is_empty());
        assert!(!spec.get_root().get_readonly());
    }

    #[tokio::test]
    async fn create_process_preserves_no_new_privileges_and_runtime_default_seccomp() {
        let mut container = container_with_spec(serde_json::json!({
            "ociVersion": "1.0.2",
            "process": {
                "user": {"uid": 1000, "gid": 1000},
                "args": ["sh", "-c", "true"],
                "cwd": "/",
                "noNewPrivileges": true
            },
            "linux": {
                "seccomp": {
                    "defaultAction": "SCMP_ACT_ERRNO",
                    "architectures": [
                        "SCMP_ARCH_X86_64",
                        "SCMP_ARCH_X86",
                        "SCMP_ARCH_X32"
                    ],
                    "syscalls": [
                        {
                            "names": ["read", "write"],
                            "action": "SCMP_ACT_ALLOW"
                        },
                        {
                            "names": ["clone"],
                            "action": "SCMP_ACT_ERRNO",
                            "errnoRet": 38,
                            "args": [{
                                "index": 0,
                                "value": 2114060288,
                                "valueTwo": 0,
                                "op": "SCMP_CMP_MASKED_EQ"
                            }]
                        }
                    ]
                }
            }
        }));

        let spec = container.get_pb_spec().unwrap();
        assert!(spec.get_process().get_noNewPrivileges());
        assert!(spec.get_linux().has_seccomp());

        let seccomp = spec.get_linux().get_seccomp();
        assert_eq!(seccomp.get_defaultAction(), "SCMP_ACT_ERRNO");
        assert_eq!(
            seccomp.get_architectures(),
            &["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"]
        );
        assert!(seccomp.get_flags().is_empty());
        assert_eq!(seccomp.get_syscalls().len(), 2);
        assert_eq!(seccomp.get_syscalls()[0].get_names(), &["read", "write"]);
        assert_eq!(seccomp.get_syscalls()[0].get_action(), "SCMP_ACT_ALLOW");
        assert_eq!(seccomp.get_syscalls()[0].get_errnoRet(), 0);
        assert!(seccomp.get_syscalls()[0].get_args().is_empty());
        assert_eq!(seccomp.get_syscalls()[1].get_names(), &["clone"]);
        assert_eq!(seccomp.get_syscalls()[1].get_action(), "SCMP_ACT_ERRNO");
        assert_eq!(seccomp.get_syscalls()[1].get_errnoRet(), 38);
        assert_eq!(seccomp.get_syscalls()[1].get_args().len(), 1);
        let arg = &seccomp.get_syscalls()[1].get_args()[0];
        assert_eq!(arg.get_index(), 0);
        assert_eq!(arg.get_value(), 2114060288);
        assert_eq!(arg.get_valueTwo(), 0);
        assert_eq!(arg.get_op(), "SCMP_CMP_MASKED_EQ");
    }

    #[tokio::test]
    async fn create_process_preserves_false_no_new_privileges_without_seccomp() {
        let mut container = container_with_process(serde_json::json!({
            "user": {"uid": 0, "gid": 0},
            "args": ["true"],
            "cwd": "/",
            "noNewPrivileges": false
        }));

        let spec = container.get_pb_spec().unwrap();
        assert!(!spec.get_process().get_noNewPrivileges());
        assert!(!spec.get_linux().has_seccomp());
    }

    #[tokio::test]
    async fn create_process_rejects_seccomp_fields_missing_from_agent_protocol() {
        let cases = [
            (
                "defaultErrnoRet",
                serde_json::json!({
                    "defaultAction": "SCMP_ACT_ERRNO",
                    "defaultErrnoRet": 13
                }),
            ),
            (
                "listenerPath",
                serde_json::json!({
                    "defaultAction": "SCMP_ACT_NOTIFY",
                    "listenerPath": "/run/seccomp-listener.sock"
                }),
            ),
            (
                "listenerMetadata",
                serde_json::json!({
                    "defaultAction": "SCMP_ACT_NOTIFY",
                    "listenerMetadata": "opaque"
                }),
            ),
            (
                "errnoRet=0",
                serde_json::json!({
                    "defaultAction": "SCMP_ACT_ALLOW",
                    "syscalls": [{
                        "names": ["unshare"],
                        "action": "SCMP_ACT_ERRNO",
                        "errnoRet": 0
                    }]
                }),
            ),
        ];

        for (expected_error, seccomp) in cases {
            let mut container = container_with_spec(serde_json::json!({
                "ociVersion": "1.0.2",
                "process": {
                    "user": {"uid": 0, "gid": 0},
                    "args": ["true"],
                    "cwd": "/",
                    "noNewPrivileges": true
                },
                "linux": {"seccomp": seccomp}
            }));

            let error = container.get_pb_spec().unwrap_err();
            assert!(
                error.contains(expected_error),
                "expected {expected_error:?} in {error:?}"
            );
        }
    }

    #[test]
    fn privileged_node_switch_is_explicit_and_defaults_off() {
        assert!(!parse_privileged_node_switch(None).unwrap());
        assert!(!parse_privileged_node_switch(Some(OsStr::new("false"))).unwrap());
        assert!(parse_privileged_node_switch(Some(OsStr::new("true"))).unwrap());
        let error = parse_privileged_node_switch(Some(OsStr::new("1"))).unwrap_err();
        assert!(error.contains(CUBE_ALLOW_PRIVILEGED_ENV));
        assert!(error.contains("expected true or false"));
    }

    #[tokio::test]
    async fn privileged_request_requires_node_opt_in() {
        let mut container = container_with_spec(privileged_spec_json());
        let error = container
            .get_pb_spec_with_privileged_policy(false)
            .unwrap_err();
        assert!(error.contains("privileged OCI request rejected"));
        assert!(error.contains("CUBE_ALLOW_PRIVILEGED=true"));
    }

    #[tokio::test]
    async fn privileged_request_keeps_elevation_guest_only() {
        let mut container = container_with_spec(privileged_spec_json());
        let spec = container.get_pb_spec_with_privileged_policy(true).unwrap();

        assert!(spec.get_linux().get_devices().is_empty());
        let rules = spec.get_linux().get_resources().get_devices();
        assert_eq!(rules.len(), 1);
        assert!(rules[0].get_allow());
        assert_eq!(rules[0].get_field_type(), "a");
        assert_eq!(rules[0].get_major(), -1);
        assert_eq!(rules[0].get_minor(), -1);
        assert_eq!(rules[0].get_access(), "rwm");
    }

    #[tokio::test]
    async fn privileged_request_rejects_host_device_enumeration() {
        let mut spec = privileged_spec_json();
        spec["linux"]["devices"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({
                "path":"/dev/kvm", "type":"c", "major":10, "minor":232
            }));
        let mut container = container_with_spec(spec);
        let error = container
            .get_pb_spec_with_privileged_policy(true)
            .unwrap_err();
        assert!(error.contains("Host device candidate"));
        assert!(error.contains("/dev/kvm"));
        assert!(error.contains("privileged_without_host_devices=true"));
    }

    #[tokio::test]
    async fn privileged_request_rejects_host_dev_mount() {
        let mut spec = privileged_spec_json();
        spec["mounts"] = serde_json::json!([{
            "destination":"/host-dev",
            "type":"bind",
            "source":"/dev",
            "options":["rbind", "rw"]
        }]);
        let mut container = container_with_spec(spec);
        let error = container
            .get_pb_spec_with_privileged_policy(true)
            .unwrap_err();
        assert!(error.contains("Host /dev mount source"));
    }

    #[tokio::test]
    async fn privileged_signature_requires_containerd_guest_device_marker() {
        let mut spec = privileged_spec_json();
        spec["linux"]["resources"]["devices"] = serde_json::json!([]);
        let mut container = container_with_spec(spec);
        let error = container
            .get_pb_spec_with_privileged_policy(true)
            .unwrap_err();
        assert!(error.contains("exactly one canonical Guest all-devices rule"));
        assert!(error.contains("privileged_without_host_devices_all_devices_allowed=true"));
    }

    #[tokio::test]
    async fn privileged_request_rejects_marker_followed_by_deny_rule() {
        let mut spec = privileged_spec_json();
        spec["linux"]["resources"]["devices"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({
                "allow": false,
                "type": "c",
                "major": 10,
                "minor": 232,
                "access": "rwm"
            }));
        let mut container = container_with_spec(spec);
        let error = container
            .get_pb_spec_with_privileged_policy(true)
            .unwrap_err();
        assert!(error.contains("exactly one canonical Guest all-devices rule"));
        assert!(error.contains("no additional device rules"));
    }

    #[tokio::test]
    async fn privileged_request_rejects_duplicate_all_devices_markers() {
        let mut spec = privileged_spec_json();
        spec["linux"]["resources"]["devices"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({"allow": true, "access": "rwm"}));
        let mut container = container_with_spec(spec);
        let error = container
            .get_pb_spec_with_privileged_policy(true)
            .unwrap_err();
        assert!(error.contains("exactly one canonical Guest all-devices rule"));
        assert!(error.contains("no additional device rules"));
    }

    #[tokio::test]
    async fn ordinary_container_is_not_elevated_when_node_switch_is_on() {
        let mut container = container_with_spec(serde_json::json!({
            "ociVersion": "1.0.2",
            "process": {
                "user": {"uid": 0, "gid": 0},
                "args": ["true"],
                "cwd": "/",
                "capabilities": {
                    "bounding": ["CAP_NET_BIND_SERVICE"],
                    "effective": ["CAP_NET_BIND_SERVICE"],
                    "permitted": ["CAP_NET_BIND_SERVICE"]
                }
            },
            "linux": {
                "resources": {"devices": [{
                    "allow":true, "type":"c", "major":1, "minor":3, "access":"rwm"
                }]},
                "maskedPaths": ["/proc/kcore"],
                "readonlyPaths": ["/proc/sys"]
            }
        }));
        let spec = container.get_pb_spec_with_privileged_policy(true).unwrap();
        assert!(spec.get_linux().get_resources().get_devices().is_empty());
        assert_eq!(
            sorted_capabilities(spec.get_process().get_capabilities().get_effective()),
            ["CAP_NET_BIND_SERVICE"]
        );
        assert_eq!(spec.get_linux().get_maskedPaths(), &["/proc/kcore"]);
        assert_eq!(spec.get_linux().get_readonlyPaths(), &["/proc/sys"]);
    }

    #[test]
    fn exec_process_preserves_identity_and_group_order() {
        let source: Process = serde_json::from_value(serde_json::json!({
            "user": {
                "uid": 4321,
                "gid": 5432,
                "additionalGids": [5432, 7654, 6543, 5432],
                "username": "identity-user"
            },
            "args": ["sh", "-c", "id"],
            "env": ["IDENTITY_TEST=1"],
            "cwd": "/work"
        }))
        .unwrap();

        let process = exec_process_for_agent(&source, false).unwrap();
        let user = process.get_user();
        assert_eq!(user.get_uid(), 4321);
        assert_eq!(user.get_gid(), 5432);
        assert_eq!(user.get_additionalGids(), &[5432, 7654, 6543, 5432]);
        assert_eq!(user.get_username(), "identity-user");
        assert!(!process.get_terminal());
        assert_eq!(process.get_args(), &["sh", "-c", "id"]);
        assert_eq!(process.get_env(), &["IDENTITY_TEST=1"]);
        assert_eq!(process.get_cwd(), "/work");
        assert!(!process.has_capabilities());
        assert!(process.get_rlimits().is_empty());
        assert!(!process.get_noNewPrivileges());
    }

    #[test]
    fn exec_process_preserves_representable_security_fields() {
        let source: Process = serde_json::from_value(serde_json::json!({
            "terminal": true,
            "user": {"uid": 1000, "gid": 3000, "additionalGids": [2000, 4000]},
            "args": ["sh", "-c", "true"],
            "env": ["SECURITY_TEST=1"],
            "cwd": "/work",
            "capabilities": {
                "bounding": ["CAP_NET_RAW"],
                "effective": ["CAP_NET_RAW"],
                "inheritable": [],
                "permitted": ["CAP_NET_RAW"],
                "ambient": []
            },
            "rlimits": [{"type": "RLIMIT_NOFILE", "hard": 4096, "soft": 2048}],
            "noNewPrivileges": true,
            "apparmorProfile": "deferred-profile",
            "oomScoreAdj": 123,
            "selinuxLabel": "deferred-label"
        }))
        .unwrap();

        let process = exec_process_for_agent(&source, false).unwrap();
        let caps = process.get_capabilities();
        assert_eq!(caps.get_bounding(), &["CAP_NET_RAW"]);
        assert_eq!(caps.get_effective(), &["CAP_NET_RAW"]);
        assert!(caps.get_inheritable().is_empty());
        assert_eq!(caps.get_permitted(), &["CAP_NET_RAW"]);
        assert!(caps.get_ambient().is_empty());
        assert_eq!(process.get_rlimits().len(), 1);
        assert_eq!(process.get_rlimits()[0].get_field_type(), "RLIMIT_NOFILE");
        assert_eq!(process.get_rlimits()[0].get_hard(), 4096);
        assert_eq!(process.get_rlimits()[0].get_soft(), 2048);
        assert!(process.get_noNewPrivileges());
        assert!(!process.get_terminal());
        assert!(process.get_apparmorProfile().is_empty());
        assert_eq!(process.get_oomScoreAdj(), 0);
        assert!(process.get_selinuxLabel().is_empty());
    }

    #[test]
    fn exec_process_rejects_unrepresentable_fields() {
        let cases = [
            (
                "user.umask",
                serde_json::json!({
                    "user": {"uid": 1000, "gid": 3000, "umask": 18}
                }),
            ),
            (
                "commandLine",
                serde_json::json!({"commandLine": "cmd.exe /c echo test"}),
            ),
            (
                "ioPriority",
                serde_json::json!({
                    "ioPriority": {"class": "IOPRIO_CLASS_BE", "priority": 4}
                }),
            ),
            (
                "scheduler",
                serde_json::json!({
                    "scheduler": {"policy": "SCHED_OTHER", "nice": 1}
                }),
            ),
            (
                "execCPUAffinity",
                serde_json::json!({
                    // oci-spec 0.6.8's derived serde spelling is
                    // `execCpuAffinity`; the validation error uses the OCI
                    // specification's canonical `execCPUAffinity` name.
                    "execCpuAffinity": {"cpu_affinity_initial": "0", "cpu_affinity_final": "1"}
                }),
            ),
        ];

        for (field, override_value) in cases {
            let mut value = serde_json::to_value(Process::default()).unwrap();
            let object = value.as_object_mut().unwrap();
            object.extend(override_value.as_object().unwrap().clone());
            let source: Process = serde_json::from_value(value).unwrap();

            let error = exec_process_for_agent(&source, false).unwrap_err();
            assert!(
                error.contains(field),
                "expected rejection for {field}, got {error}"
            );
        }
    }
}

#[cfg(test)]
mod log_forward_tests {
    use super::LogForwardHandle;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    /// Spawn a task that mimics a log-forward loop: it runs until cancelled,
    /// then records a clean exit.  This is what the pre-fix `abort()` fallback
    /// used to skip.
    async fn install_task(handle: &LogForwardHandle, drained: Arc<AtomicUsize>) {
        let (cancel_tx, mut cancel_rx) = tokio::sync::watch::channel(false);
        let task = tokio::spawn(async move {
            loop {
                if cancel_rx.changed().await.is_err() {
                    return;
                }
                if *cancel_rx.borrow() {
                    // Simulate the IO drain that pause/snapshot/destroy rely on.
                    tokio::time::sleep(Duration::from_millis(10)).await;
                    drained.fetch_add(1, Ordering::SeqCst);
                    return;
                }
            }
        });
        let _permit = handle.acquire().await;
        handle.store(cancel_tx, task).await;
    }

    /// The core invariant of the fix: a task installed through the shared slot
    /// is always drained to completion, even when a *clone* of the handle stops
    /// it.  The pre-fix code fell back to `abort()` here and skipped the drain.
    #[tokio::test]
    async fn drain_completes_when_stopped_through_clone() {
        let handle = LogForwardHandle::new();
        let drained = Arc::new(AtomicUsize::new(0));

        install_task(&handle, drained.clone()).await;

        let clone = handle.clone();
        let _permit = clone.acquire().await;
        clone.drain().await;

        assert_eq!(
            drained.load(Ordering::SeqCst),
            1,
            "task must be awaited to a clean exit, not aborted"
        );
    }

    /// Concurrent stops from two clones must serialize and both observe a clean
    /// slot: exactly one drains the task, neither aborts.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_stops_serialize_and_drain() {
        let handle = LogForwardHandle::new();
        let drained = Arc::new(AtomicUsize::new(0));

        install_task(&handle, drained.clone()).await;

        let a = handle.clone();
        let b = handle.clone();
        let stop_a = tokio::spawn(async move {
            let _permit = a.acquire().await;
            a.drain().await;
        });
        let stop_b = tokio::spawn(async move {
            let _permit = b.acquire().await;
            b.drain().await;
        });
        let (ra, rb) = tokio::join!(stop_a, stop_b);
        ra.unwrap();
        rb.unwrap();

        assert_eq!(
            drained.load(Ordering::SeqCst),
            1,
            "exactly one caller must drain the task to completion"
        );
    }

    /// A stop arriving while a start holds the permit mid-connect must wait for
    /// the start to install its task, then drain that task to completion — never
    /// racing the half-built slot. This is the interleaving the semaphore
    /// serializes.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stop_waits_for_in_flight_start_then_drains() {
        let handle = LogForwardHandle::new();
        let drained = Arc::new(AtomicUsize::new(0));

        // Simulate start_log_forward holding the permit through its connect
        // before it stores a task: acquire the permit and keep it.
        let start_permit = handle.acquire().await;

        // A concurrent stop tries to acquire; it must block behind the start.
        let stop_handle = handle.clone();
        let stop_drained = drained.clone();
        let stop = tokio::spawn(async move {
            let _permit = stop_handle.acquire().await;
            stop_handle.drain().await;
            stop_drained.load(Ordering::SeqCst)
        });

        // Finish the start: install the task, then release the permit.
        let (cancel_tx, mut cancel_rx) = tokio::sync::watch::channel(false);
        let task_drained = drained.clone();
        let task = tokio::spawn(async move {
            loop {
                if cancel_rx.changed().await.is_err() {
                    return;
                }
                if *cancel_rx.borrow() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                    task_drained.fetch_add(1, Ordering::SeqCst);
                    return;
                }
            }
        });
        handle.store(cancel_tx, task).await;
        drop(start_permit);

        let observed = stop.await.unwrap();
        assert_eq!(
            observed, 1,
            "stop must drain the task the start installed, not abort it"
        );
    }
}
