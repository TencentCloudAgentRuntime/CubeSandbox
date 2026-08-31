// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use async_trait::async_trait;
use containerd_shim::asynchronous::ExitSignal;
use containerd_shim::protos::protobuf::{
    well_known_types::{any::Any, timestamp::Timestamp},
    MessageField,
};
use containerd_shim::protos::ttrpc::{r#async::TtrpcContext, Code, Error as TtrpcError};
use containerd_shim::protos::types::platform::Platform;
use containerd_shim::protos::{sandbox_api as api, sandbox_async::Sandbox};
use containerd_shim::TtrpcResult;
use oci_spec::runtime::Spec;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::{Mutex, Notify};
use tokio::time::{sleep, Duration};

use crate::common::utils::Utils;
use crate::sandbox::sb;
use crate::service::runtime_resource::{self, RuntimeLease};
use crate::service::task_srv::TaskService;

const READY: &str = "SANDBOX_READY";
const NOT_READY: &str = "SANDBOX_NOTREADY";
const REQUIRED_SANDBOX_CAPABILITY: &str = "io.cubesandbox.agent.sandbox.lifecycle";
const OCI_SPEC_TYPE_URL: &str = "types.containerd.io/opencontainers/runtime-spec/1/Spec";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Phase {
    Unmanaged,
    Creating,
    Created,
    Starting,
    Ready,
    Stopping,
    Stopped,
    Failed,
    ShuttingDown,
    Shutdown,
}

#[derive(Debug)]
struct LifecycleState {
    phase: Phase,
    create_request: Option<Vec<u8>>,
    sandbox_spec: Option<Any>,
    runtime: Option<RuntimeLease>,
    created_at: Option<Timestamp>,
    exited_at: Option<Timestamp>,
    exit_status: u32,
    last_error: Option<String>,
}

impl Default for LifecycleState {
    fn default() -> Self {
        Self {
            phase: Phase::Unmanaged,
            create_request: None,
            sandbox_spec: None,
            runtime: None,
            created_at: None,
            exited_at: None,
            exit_status: 0,
            last_error: None,
        }
    }
}

pub(crate) struct SandboxLifecycle {
    state: Mutex<LifecycleState>,
    task_creates: StdMutex<HashSet<String>>,
    changed: Notify,
}

impl Default for SandboxLifecycle {
    fn default() -> Self {
        Self {
            state: Mutex::new(LifecycleState::default()),
            task_creates: StdMutex::new(HashSet::new()),
            changed: Notify::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum TaskMode {
    Legacy,
    ManagedReady { shared_root: PathBuf },
}

pub(crate) struct TaskCreateReservation {
    lifecycle: Arc<SandboxLifecycle>,
    task_id: String,
    mode: TaskMode,
}

impl TaskCreateReservation {
    pub(crate) fn mode(&self) -> &TaskMode {
        &self.mode
    }
}

impl Drop for TaskCreateReservation {
    fn drop(&mut self) {
        self.lifecycle
            .task_creates
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&self.task_id);
        self.lifecycle.changed.notify_waiters();
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ShutdownAction {
    AlreadyComplete,
    WaitForExisting,
    Run { force_abort: bool },
}

impl SandboxLifecycle {
    async fn begin_shutdown(&self) -> ShutdownAction {
        loop {
            let notified = self.changed.notified();
            let mut state = self.state.lock().await;
            if self.has_task_creates() {
                drop(state);
                notified.await;
                continue;
            }
            match state.phase {
                Phase::Creating | Phase::Starting | Phase::Stopping => {
                    drop(state);
                    notified.await;
                }
                Phase::Shutdown => return ShutdownAction::AlreadyComplete,
                Phase::ShuttingDown => return ShutdownAction::WaitForExisting,
                Phase::Stopped => {
                    state.phase = Phase::ShuttingDown;
                    return ShutdownAction::Run { force_abort: false };
                }
                _ => {
                    state.phase = Phase::ShuttingDown;
                    return ShutdownAction::Run { force_abort: true };
                }
            }
        }
    }

    pub(crate) async fn reserve_task_create(
        self: &Arc<Self>,
        task_id: &str,
    ) -> Result<TaskCreateReservation, String> {
        let state = self.state.lock().await;
        let mode = match state.phase {
            Phase::Unmanaged => Ok(TaskMode::Legacy),
            Phase::Ready => {
                let runtime = state
                    .runtime
                    .as_ref()
                    .ok_or_else(|| "ready sandbox has no RuntimeResource lease".to_string())?;
                Ok(TaskMode::ManagedReady {
                    shared_root: runtime.shared_root()?,
                })
            }
            phase => Err(format!(
                "sandbox is managed by Sandbox Service but is not ready (phase {phase:?})"
            )),
        }?;
        let inserted = self
            .task_creates
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(task_id.to_string());
        if !inserted {
            return Err(format!("task {task_id} Create is already in progress"));
        }
        Ok(TaskCreateReservation {
            lifecycle: self.clone(),
            task_id: task_id.to_string(),
            mode,
        })
    }

    pub(crate) async fn is_managed(&self) -> bool {
        self.state.lock().await.phase != Phase::Unmanaged
    }

    fn has_task_creates(&self) -> bool {
        !self
            .task_creates
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .is_empty()
    }
}

#[derive(Clone)]
pub struct SandboxService {
    id: String,
    sandbox: Arc<Mutex<sb::SandBox>>,
    lifecycle: Arc<SandboxLifecycle>,
    exit: Arc<ExitSignal>,
}

impl SandboxService {
    pub fn new(task: &TaskService) -> Self {
        Self {
            id: task.sandbox_id().to_string(),
            sandbox: task.sandbox(),
            lifecycle: task.sandbox_lifecycle(),
            exit: task.exit_signal(),
        }
    }

    fn validate_id(&self, id: &str) -> TtrpcResult<()> {
        if id.is_empty() {
            return Err(rpc_error(Code::INVALID_ARGUMENT, "sandbox_id is empty"));
        }
        if id != self.id {
            return Err(rpc_error(
                Code::NOT_FOUND,
                format!("sandbox_id {id} does not match shim {}", self.id),
            ));
        }
        Ok(())
    }

    async fn run_create(
        self,
        mut spec: Spec,
        netns_path: String,
        config: runtime_resource::CriPodSandboxConfig,
    ) {
        let result = match runtime_resource::prepare(&self.id, &netns_path, &config, &mut spec).await {
            Ok(lease) => match self.sandbox.lock().await.init(spec) {
                Ok(()) => Ok(lease),
                Err(error) => match lease.release().await {
                    Ok(()) => Err((format!("initialize Cube sandbox: {error}"), None)),
                    Err(release_error) => Err((format!("initialize Cube sandbox: {error}; release RuntimeResource: {release_error}"), Some(lease))),
                },
            },
            Err(error) => Err((format!("prepare RuntimeResource: {error}"), None)),
        };
        let mut state = self.lifecycle.state.lock().await;
        match result {
            Ok(lease) => {
                state.phase = Phase::Created;
                state.runtime = Some(lease);
                state.last_error = None;
            }
            Err((error, lease)) => {
                state.phase = Phase::Failed;
                state.runtime = lease;
                state.exit_status = 1;
                state.exited_at = Some(now_timestamp());
                state.last_error = Some(error);
            }
        }
        drop(state);
        self.lifecycle.changed.notify_waiters();
    }

    async fn wait_for_create(&self) -> TtrpcResult<api::CreateSandboxResponse> {
        loop {
            let notified = self.lifecycle.changed.notified();
            let state = self.lifecycle.state.lock().await;
            match state.phase {
                Phase::Created | Phase::Starting | Phase::Ready => {
                    return Ok(api::CreateSandboxResponse::new())
                }
                Phase::Failed => {
                    return Err(rpc_error(
                        Code::FAILED_PRECONDITION,
                        state
                            .last_error
                            .clone()
                            .unwrap_or_else(|| "sandbox create failed".to_string()),
                    ))
                }
                Phase::Creating => {
                    drop(state);
                    notified.await;
                }
                phase => {
                    return Err(rpc_error(
                        Code::FAILED_PRECONDITION,
                        format!("sandbox cannot finish create from phase {phase:?}"),
                    ))
                }
            }
        }
    }

    async fn run_start(self) {
        let lease = self.lifecycle.state.lock().await.runtime.clone();
        let result = if let Some(lease) = lease {
            match lease.acquire_tap().await {
                Ok(tap) => {
                    let mut sandbox = self.sandbox.lock().await;
                    sandbox.set_runtime_tap(tap);
                    let started = async {
                        Utils::record_pid().map_err(|error| format!("record shim pid: {error}"))?;
                        sandbox.create_sandbox().await?;
                        if !sandbox.agent_supports(REQUIRED_SANDBOX_CAPABILITY, 1) {
                            return Err(format!("guest agent lacks required capability {REQUIRED_SANDBOX_CAPABILITY}>=1"));
                        }
                        Ok::<(), String>(())
                    }.await;
                    match started {
                        Ok(()) => Ok(()),
                        Err(error) => {
                            let rollback_error = sandbox.abort_sandbox().await.err();
                            sandbox.clear_runtime_tap();
                            drop(sandbox);
                            let release_error = lease.release().await.err();
                            let released = release_error.is_none();
                            let error = append_error(error, "rollback VM", rollback_error);
                            Err((
                                append_error(error, "release RuntimeResource", release_error),
                                released,
                            ))
                        }
                    }
                }
                Err(error) => {
                    let release_error = lease.release().await.err();
                    let released = release_error.is_none();
                    Err((
                        append_error(
                            format!("acquire RuntimeResource TAP: {error}"),
                            "release RuntimeResource",
                            release_error,
                        ),
                        released,
                    ))
                }
            }
        } else {
            Err(("sandbox has no RuntimeResource lease".to_string(), true))
        };
        self.finish_start(result).await;
    }

    async fn finish_start(&self, result: Result<(), (String, bool)>) {
        let mut state = self.lifecycle.state.lock().await;
        match result {
            Ok(()) => {
                state.phase = Phase::Ready;
                state.created_at = Some(now_timestamp());
                state.last_error = None;
            }
            Err((error, released)) => {
                state.phase = Phase::Failed;
                if released {
                    state.runtime = None;
                }
                state.exit_status = 1;
                state.exited_at = Some(now_timestamp());
                state.last_error = Some(error);
            }
        }
        let ready = state.phase == Phase::Ready;
        drop(state);
        self.lifecycle.changed.notify_waiters();
        if ready {
            tokio::spawn(self.clone().monitor_vm_exit());
        }
    }

    async fn monitor_vm_exit(self) {
        loop {
            sleep(Duration::from_millis(500)).await;
            if self.lifecycle.state.lock().await.phase != Phase::Ready {
                return;
            }
            if self.sandbox.lock().await.vm_exited().await {
                let mut state = self.lifecycle.state.lock().await;
                if state.phase == Phase::Ready {
                    state.phase = Phase::Failed;
                    state.exit_status = 1;
                    state.exited_at = Some(now_timestamp());
                    state.last_error = Some("Cube VM exited unexpectedly".to_string());
                }
                drop(state);
                self.lifecycle.changed.notify_waiters();
                return;
            }
        }
    }

    async fn wait_for_start(&self) -> TtrpcResult<api::StartSandboxResponse> {
        loop {
            let notified = self.lifecycle.changed.notified();
            let state = self.lifecycle.state.lock().await;
            match state.phase {
                Phase::Ready => {
                    return Ok(api::StartSandboxResponse {
                        pid: std::process::id(),
                        created_at: state.created_at.clone().into(),
                        spec: state.sandbox_spec.clone().into(),
                        ..Default::default()
                    })
                }
                Phase::Failed => {
                    return Err(rpc_error(
                        Code::FAILED_PRECONDITION,
                        state
                            .last_error
                            .clone()
                            .unwrap_or_else(|| "sandbox start failed".to_string()),
                    ))
                }
                Phase::Starting => {
                    drop(state);
                    notified.await;
                }
                phase => {
                    return Err(rpc_error(
                        Code::FAILED_PRECONDITION,
                        format!("sandbox cannot finish start from phase {phase:?}"),
                    ))
                }
            }
        }
    }

    async fn run_stop(self, previous: Phase) {
        if !self.sandbox.lock().await.is_empty().await {
            self.finish_stop(
                previous,
                Err("sandbox still contains containers".to_string()),
                false,
            )
            .await;
            return;
        }
        if let Some(lease) = self.lifecycle.state.lock().await.runtime.clone() {
            if let Err(error) = lease.release().await {
                self.finish_stop(
                    previous,
                    Err(format!("release RuntimeResource: {error}")),
                    false,
                )
                .await;
                return;
            }
        }
        let result = {
            let mut sandbox = self.sandbox.lock().await;
            let destroyed = if previous == Phase::Failed {
                sandbox.abort_sandbox().await
            } else {
                sandbox.destroy_sandbox().await
            };
            match destroyed {
                Ok(()) => {
                    sandbox.clear_runtime_tap();
                    Ok(())
                }
                Err(error) => {
                    let rollback = sandbox.abort_sandbox().await;
                    sandbox.clear_runtime_tap();
                    Err(append_error(
                        format!("destroy sandbox: {error}"),
                        "forced rollback",
                        rollback.err(),
                    ))
                }
            }
        };
        self.finish_stop(previous, result, true).await;
    }

    async fn finish_stop(&self, previous: Phase, result: Result<(), String>, released: bool) {
        let mut state = self.lifecycle.state.lock().await;
        if released {
            state.runtime = None;
        }
        match result {
            Ok(()) => {
                state.phase = Phase::Stopped;
                state.exit_status = 0;
                state.exited_at = Some(now_timestamp());
                state.last_error = None;
            }
            Err(error) => {
                if error == "sandbox still contains containers"
                    || error.starts_with("release RuntimeResource:")
                {
                    state.phase = previous;
                } else {
                    state.phase = Phase::Failed;
                    state.exit_status = 1;
                    state.exited_at = Some(now_timestamp());
                }
                state.last_error = Some(error);
            }
        }
        drop(state);
        self.lifecycle.changed.notify_waiters();
    }

    async fn wait_for_stop(&self) -> TtrpcResult<()> {
        loop {
            let notified = self.lifecycle.changed.notified();
            let state = self.lifecycle.state.lock().await;
            match state.phase {
                Phase::Stopped | Phase::Shutdown => return Ok(()),
                Phase::Failed | Phase::Ready | Phase::Created if state.last_error.is_some() => {
                    return Err(rpc_error(
                        Code::FAILED_PRECONDITION,
                        state.last_error.clone().unwrap(),
                    ))
                }
                Phase::Stopping => {
                    drop(state);
                    notified.await;
                }
                phase => {
                    return Err(rpc_error(
                        Code::FAILED_PRECONDITION,
                        format!("sandbox cannot finish stop from phase {phase:?}"),
                    ))
                }
            }
        }
    }

    async fn run_shutdown(self, force_abort: bool) {
        let release = if let Some(lease) = self.lifecycle.state.lock().await.runtime.clone() {
            lease.release().await
        } else {
            Ok(())
        };
        let abort = if force_abort {
            let mut sandbox = self.sandbox.lock().await;
            let result = sandbox.abort_sandbox().await;
            sandbox.clear_runtime_tap();
            result
        } else {
            Ok(())
        };
        let released = release.is_ok();
        let result = match (release, abort) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(error), Ok(())) => Err(format!("release RuntimeResource: {error}")),
            (Ok(()), Err(error)) => Err(format!("force shutdown sandbox: {error}")),
            (Err(release), Err(abort)) => Err(format!(
                "release RuntimeResource: {release}; force shutdown sandbox: {abort}"
            )),
        };
        let mut state = self.lifecycle.state.lock().await;
        if released {
            state.runtime = None;
        }
        match result {
            Ok(()) => {
                state.phase = Phase::Shutdown;
                state.last_error = None;
                if state.exited_at.is_none() {
                    state.exited_at = Some(now_timestamp());
                }
            }
            Err(error) => {
                state.phase = Phase::Failed;
                state.exit_status = 1;
                state.exited_at = Some(now_timestamp());
                state.last_error = Some(error);
            }
        }
        let shutdown = state.phase == Phase::Shutdown;
        drop(state);
        self.lifecycle.changed.notify_waiters();
        if shutdown {
            self.exit.signal();
        }
    }

    async fn wait_for_shutdown(&self) -> TtrpcResult<api::ShutdownSandboxResponse> {
        loop {
            let notified = self.lifecycle.changed.notified();
            let state = self.lifecycle.state.lock().await;
            match state.phase {
                Phase::Shutdown => return Ok(api::ShutdownSandboxResponse::new()),
                Phase::Failed => {
                    return Err(rpc_error(
                        Code::INTERNAL,
                        state
                            .last_error
                            .clone()
                            .unwrap_or_else(|| "sandbox shutdown failed".to_string()),
                    ))
                }
                Phase::ShuttingDown => {
                    drop(state);
                    notified.await;
                }
                phase => {
                    return Err(rpc_error(
                        Code::FAILED_PRECONDITION,
                        format!("sandbox cannot finish shutdown from phase {phase:?}"),
                    ))
                }
            }
        }
    }
}

fn hash_create_part(hasher: &mut Sha256, value: &[u8]) {
    hasher.update((value.len() as u64).to_be_bytes());
    hasher.update(value);
}

fn create_request_fingerprint(
    request: &api::CreateSandboxRequest,
    cri_fingerprint: &str,
) -> Vec<u8> {
    let mut hasher = Sha256::new();
    for value in [
        request.sandbox_id.as_bytes(),
        request.bundle_path.as_bytes(),
        request.netns_path.as_bytes(),
        cri_fingerprint.as_bytes(),
    ] {
        hash_create_part(&mut hasher, value);
    }
    hash_create_part(&mut hasher, &(request.rootfs.len() as u64).to_be_bytes());
    for mount in &request.rootfs {
        for value in [
            mount.type_.as_bytes(),
            mount.source.as_bytes(),
            mount.target.as_bytes(),
        ] {
            hash_create_part(&mut hasher, value);
        }
        hash_create_part(&mut hasher, &(mount.options.len() as u64).to_be_bytes());
        for option in &mount.options {
            hash_create_part(&mut hasher, option.as_bytes());
        }
    }
    let mut annotations: Vec<_> = request.annotations.iter().collect();
    annotations.sort_by(|left, right| left.0.cmp(right.0));
    for (key, value) in annotations {
        hash_create_part(&mut hasher, key.as_bytes());
        hash_create_part(&mut hasher, value.as_bytes());
    }
    hasher.finalize().to_vec()
}

fn encode_sandbox_spec(spec: &Spec) -> Result<Any, String> {
    let value = serde_json::to_vec(spec)
        .map_err(|error| format!("serialize OCI sandbox spec failed: {error}"))?;
    Ok(Any {
        type_url: OCI_SPEC_TYPE_URL.to_string(),
        value,
        ..Default::default()
    })
}

#[async_trait]
impl Sandbox for SandboxService {
    async fn create_sandbox(
        &self,
        _ctx: &TtrpcContext,
        req: api::CreateSandboxRequest,
    ) -> TtrpcResult<api::CreateSandboxResponse> {
        self.validate_id(&req.sandbox_id)?;
        if req.bundle_path.is_empty() || !Path::new(&req.bundle_path).is_absolute() {
            return Err(rpc_error(
                Code::INVALID_ARGUMENT,
                "bundle_path must be absolute",
            ));
        }
        if req.netns_path.is_empty() || !Path::new(&req.netns_path).is_absolute() {
            return Err(rpc_error(
                Code::INVALID_ARGUMENT,
                "netns_path must be absolute; host-network sandboxes are not supported",
            ));
        }
        let options = req.options.as_ref().ok_or_else(|| {
            rpc_error(
                Code::INVALID_ARGUMENT,
                "sandbox options must contain CRI v1 PodSandboxConfig",
            )
        })?;
        let config = runtime_resource::decode_cri_config(&options.type_url, &options.value)
            .map_err(|error| rpc_error(Code::INVALID_ARGUMENT, error))?;
        let fingerprint =
            create_request_fingerprint(&req, &runtime_resource::cri_semantic_fingerprint(&config));
        let config_path = Path::new(&req.bundle_path).join("config.json");
        let mut spec: Spec = if config_path.is_file() {
            Utils::load_spec(&req.bundle_path).map_err(|error| {
                rpc_error(
                    Code::INVALID_ARGUMENT,
                    format!("load sandbox bundle spec: {error}"),
                )
            })?
        } else {
            Spec::default()
        };
        runtime_resource::merge_cri_annotations(&mut spec, &config, &req.annotations)
            .map_err(|error| rpc_error(Code::INVALID_ARGUMENT, error))?;
        let sandbox_spec =
            encode_sandbox_spec(&spec).map_err(|error| rpc_error(Code::INVALID_ARGUMENT, error))?;
        let should_create = {
            let mut state = self.lifecycle.state.lock().await;
            match state.phase {
                Phase::Unmanaged => {
                    state.phase = Phase::Creating;
                    state.create_request = Some(fingerprint.clone());
                    state.sandbox_spec = Some(sandbox_spec);
                    true
                }
                _ if state.create_request.as_deref() == Some(fingerprint.as_slice()) => false,
                phase => {
                    return Err(rpc_error(
                        Code::ALREADY_EXISTS,
                        format!(
                            "sandbox was already created in phase {phase:?} with different input"
                        ),
                    ))
                }
            }
        };
        if should_create {
            tokio::spawn(self.clone().run_create(spec, req.netns_path, config));
        }
        self.wait_for_create().await
    }

    async fn start_sandbox(
        &self,
        _ctx: &TtrpcContext,
        req: api::StartSandboxRequest,
    ) -> TtrpcResult<api::StartSandboxResponse> {
        self.validate_id(&req.sandbox_id)?;
        let should_start = {
            let mut state = self.lifecycle.state.lock().await;
            match state.phase {
                Phase::Created => {
                    state.phase = Phase::Starting;
                    true
                }
                Phase::Starting | Phase::Ready => false,
                phase => {
                    return Err(rpc_error(
                        Code::FAILED_PRECONDITION,
                        format!("sandbox cannot start from phase {phase:?}"),
                    ))
                }
            }
        };
        if should_start {
            tokio::spawn(self.clone().run_start());
        }
        self.wait_for_start().await
    }

    async fn platform(
        &self,
        _ctx: &TtrpcContext,
        req: api::PlatformRequest,
    ) -> TtrpcResult<api::PlatformResponse> {
        self.validate_id(&req.sandbox_id)?;
        Ok(api::PlatformResponse {
            platform: MessageField::some(Platform {
                os: "linux".to_string(),
                architecture: "amd64".to_string(),
                ..Default::default()
            }),
            ..Default::default()
        })
    }

    async fn stop_sandbox(
        &self,
        _ctx: &TtrpcContext,
        req: api::StopSandboxRequest,
    ) -> TtrpcResult<api::StopSandboxResponse> {
        self.validate_id(&req.sandbox_id)?;
        let (should_stop, previous) = loop {
            let notified = self.lifecycle.changed.notified();
            let mut state = self.lifecycle.state.lock().await;
            if self.lifecycle.has_task_creates() {
                drop(state);
                notified.await;
                continue;
            }
            match state.phase {
                Phase::Creating | Phase::Starting => {
                    drop(state);
                    notified.await;
                }
                Phase::Created | Phase::Ready | Phase::Failed => {
                    let previous = state.phase;
                    state.phase = Phase::Stopping;
                    break (true, previous);
                }
                Phase::Stopping => break (false, Phase::Stopping),
                Phase::Stopped | Phase::Shutdown => return Ok(api::StopSandboxResponse::new()),
                phase => {
                    return Err(rpc_error(
                        Code::FAILED_PRECONDITION,
                        format!("sandbox cannot stop from phase {phase:?}"),
                    ))
                }
            }
        };
        if should_stop {
            tokio::spawn(self.clone().run_stop(previous));
        }
        self.wait_for_stop().await?;
        Ok(api::StopSandboxResponse::new())
    }

    async fn wait_sandbox(
        &self,
        _ctx: &TtrpcContext,
        req: api::WaitSandboxRequest,
    ) -> TtrpcResult<api::WaitSandboxResponse> {
        self.validate_id(&req.sandbox_id)?;
        loop {
            let notified = self.lifecycle.changed.notified();
            let state = self.lifecycle.state.lock().await;
            match state.phase {
                Phase::Stopped | Phase::Failed | Phase::Shutdown => {
                    return Ok(api::WaitSandboxResponse {
                        exit_status: state.exit_status,
                        exited_at: state.exited_at.clone().into(),
                        ..Default::default()
                    })
                }
                _ => {
                    drop(state);
                    notified.await;
                }
            }
        }
    }

    async fn sandbox_status(
        &self,
        _ctx: &TtrpcContext,
        req: api::SandboxStatusRequest,
    ) -> TtrpcResult<api::SandboxStatusResponse> {
        self.validate_id(&req.sandbox_id)?;
        let state = self.lifecycle.state.lock().await;
        let mut info = std::collections::HashMap::new();
        if req.verbose {
            info.insert("phase".to_string(), format!("{:?}", state.phase));
            if let Some(error) = state.last_error.as_ref() {
                info.insert("last_error".to_string(), error.clone());
            }
            if let Some(runtime) = state.runtime.as_ref() {
                info.insert(
                    "runtime_lease".to_string(),
                    runtime.sandbox.lease_id.clone(),
                );
                info.insert(
                    "runtime_generation".to_string(),
                    runtime.sandbox.generation.to_string(),
                );
            }
        }
        Ok(api::SandboxStatusResponse {
            sandbox_id: self.id.clone(),
            pid: std::process::id(),
            state: if state.phase == Phase::Ready {
                READY.to_string()
            } else {
                NOT_READY.to_string()
            },
            info,
            created_at: state.created_at.clone().into(),
            exited_at: state.exited_at.clone().into(),
            ..Default::default()
        })
    }

    async fn ping_sandbox(
        &self,
        _ctx: &TtrpcContext,
        req: api::PingRequest,
    ) -> TtrpcResult<api::PingResponse> {
        self.validate_id(&req.sandbox_id)?;
        if self.lifecycle.state.lock().await.phase == Phase::Shutdown {
            return Err(rpc_error(Code::UNAVAILABLE, "sandbox shim is shut down"));
        }
        Ok(api::PingResponse::new())
    }

    async fn shutdown_sandbox(
        &self,
        _ctx: &TtrpcContext,
        req: api::ShutdownSandboxRequest,
    ) -> TtrpcResult<api::ShutdownSandboxResponse> {
        self.validate_id(&req.sandbox_id)?;
        let force_abort = match self.lifecycle.begin_shutdown().await {
            ShutdownAction::AlreadyComplete => return Ok(api::ShutdownSandboxResponse::new()),
            ShutdownAction::WaitForExisting => None,
            ShutdownAction::Run { force_abort } => Some(force_abort),
        };
        if let Some(force_abort) = force_abort {
            tokio::spawn(self.clone().run_shutdown(force_abort));
        }
        self.wait_for_shutdown().await
    }

    async fn sandbox_metrics(
        &self,
        _ctx: &TtrpcContext,
        req: api::SandboxMetricsRequest,
    ) -> TtrpcResult<api::SandboxMetricsResponse> {
        self.validate_id(&req.sandbox_id)?;
        Ok(api::SandboxMetricsResponse::new())
    }
}

fn append_error(base: String, operation: &str, error: Option<String>) -> String {
    match error {
        Some(error) => format!("{base}; {operation}: {error}"),
        None => base,
    }
}

fn rpc_error(code: Code, message: impl Into<String>) -> TtrpcError {
    TtrpcError::RpcStatus(containerd_shim::protos::ttrpc::get_status(
        code,
        message.into(),
    ))
}

fn now_timestamp() -> Timestamp {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    Timestamp {
        seconds: duration.as_secs() as i64,
        nanos: duration.subsec_nanos() as i32,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn unmanaged_task_mode_preserves_legacy_runtime() {
        let lifecycle = Arc::new(SandboxLifecycle::default());
        let reservation = lifecycle.reserve_task_create("legacy-task").await.unwrap();
        assert_eq!(reservation.mode(), &TaskMode::Legacy);
        assert!(!lifecycle.is_managed().await);
    }

    #[tokio::test]
    async fn managed_task_is_rejected_until_ready() {
        let lifecycle = Arc::new(SandboxLifecycle::default());
        lifecycle.state.lock().await.phase = Phase::Created;
        assert!(lifecycle
            .reserve_task_create("task-before-ready")
            .await
            .err()
            .unwrap()
            .contains("not ready"));
        let shared_root = PathBuf::from(format!(
            "/data/cubelet/s11/shared/sb-test-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&shared_root).unwrap();
        {
            let mut state = lifecycle.state.lock().await;
            state.phase = Phase::Ready;
            state.runtime = Some(RuntimeLease::test_with_shared_root(
                shared_root.to_str().unwrap(),
            ));
        }
        let reservation = lifecycle.reserve_task_create("task-ready").await.unwrap();
        assert_eq!(
            reservation.mode(),
            &TaskMode::ManagedReady {
                shared_root: shared_root.clone()
            }
        );
        drop(reservation);
        std::fs::remove_dir_all(&shared_root).unwrap();
    }

    #[tokio::test]
    async fn task_create_reservation_rejects_duplicate_and_blocks_shutdown() {
        let lifecycle = Arc::new(SandboxLifecycle::default());
        let shared_root = PathBuf::from(format!(
            "/data/cubelet/s11/shared/sb-reservation-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&shared_root).unwrap();
        {
            let mut state = lifecycle.state.lock().await;
            state.phase = Phase::Ready;
            state.runtime = Some(RuntimeLease::test_with_shared_root(
                shared_root.to_str().unwrap(),
            ));
        }

        let reservation = lifecycle.reserve_task_create("same-task").await.unwrap();
        assert!(lifecycle
            .reserve_task_create("same-task")
            .await
            .err()
            .unwrap()
            .contains("already in progress"));
        let shutdown = {
            let lifecycle = lifecycle.clone();
            tokio::spawn(async move { lifecycle.begin_shutdown().await })
        };
        tokio::task::yield_now().await;
        assert!(!shutdown.is_finished());

        drop(reservation);
        assert_eq!(
            shutdown.await.unwrap(),
            ShutdownAction::Run { force_abort: true }
        );
        std::fs::remove_dir_all(&shared_root).unwrap();
    }

    #[tokio::test]
    async fn managed_sandbox_allows_distinct_task_creates_and_waits_for_all() {
        let lifecycle = Arc::new(SandboxLifecycle::default());
        let shared_root = PathBuf::from(format!(
            "/data/cubelet/s11/shared/sb-multitask-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&shared_root).unwrap();
        {
            let mut state = lifecycle.state.lock().await;
            state.phase = Phase::Ready;
            state.runtime = Some(RuntimeLease::test_with_shared_root(
                shared_root.to_str().unwrap(),
            ));
        }

        let alpha = lifecycle.reserve_task_create("alpha").await.unwrap();
        let beta = lifecycle.reserve_task_create("beta").await.unwrap();
        assert_eq!(
            alpha.mode(),
            &TaskMode::ManagedReady {
                shared_root: shared_root.clone()
            }
        );
        assert_eq!(alpha.mode(), beta.mode());

        let shutdown = {
            let lifecycle = lifecycle.clone();
            tokio::spawn(async move { lifecycle.begin_shutdown().await })
        };
        tokio::task::yield_now().await;
        assert!(!shutdown.is_finished());
        drop(alpha);
        tokio::task::yield_now().await;
        assert!(!shutdown.is_finished());
        drop(beta);
        assert_eq!(
            shutdown.await.unwrap(),
            ShutdownAction::Run { force_abort: true }
        );

        std::fs::remove_dir_all(&shared_root).unwrap();
    }

    #[tokio::test]
    async fn shutdown_waits_for_detached_operation_before_transitioning() {
        let lifecycle = Arc::new(SandboxLifecycle::default());
        lifecycle.state.lock().await.phase = Phase::Creating;
        let waiter = {
            let lifecycle = lifecycle.clone();
            tokio::spawn(async move { lifecycle.begin_shutdown().await })
        };
        tokio::task::yield_now().await;
        assert!(!waiter.is_finished());

        lifecycle.state.lock().await.phase = Phase::Created;
        lifecycle.changed.notify_waiters();
        assert_eq!(
            waiter.await.unwrap(),
            ShutdownAction::Run { force_abort: true }
        );
        assert_eq!(lifecycle.state.lock().await.phase, Phase::ShuttingDown);
        assert_eq!(
            lifecycle.begin_shutdown().await,
            ShutdownAction::WaitForExisting
        );
    }

    #[tokio::test]
    async fn shutdown_after_stop_skips_redundant_force_abort() {
        let lifecycle = SandboxLifecycle::default();
        lifecycle.state.lock().await.phase = Phase::Stopped;
        assert_eq!(
            lifecycle.begin_shutdown().await,
            ShutdownAction::Run { force_abort: false }
        );
        assert_eq!(lifecycle.state.lock().await.phase, Phase::ShuttingDown);
    }

    #[test]
    fn create_retry_fingerprint_ignores_annotation_map_iteration_order() {
        let mut first = api::CreateSandboxRequest {
            sandbox_id: "sandbox-a".to_string(),
            bundle_path: "/run/containerd/bundle".to_string(),
            netns_path: "/run/netns/pod-a".to_string(),
            ..Default::default()
        };
        first
            .annotations
            .insert("z.example/key".to_string(), "z".to_string());
        first
            .annotations
            .insert("a.example/key".to_string(), "a".to_string());
        let mut second = api::CreateSandboxRequest {
            sandbox_id: first.sandbox_id.clone(),
            bundle_path: first.bundle_path.clone(),
            netns_path: first.netns_path.clone(),
            ..Default::default()
        };
        second
            .annotations
            .insert("a.example/key".to_string(), "a".to_string());
        second
            .annotations
            .insert("z.example/key".to_string(), "z".to_string());
        assert_eq!(
            create_request_fingerprint(&first, "cri-fingerprint"),
            create_request_fingerprint(&second, "cri-fingerprint")
        );
        second
            .annotations
            .insert("z.example/key".to_string(), "changed".to_string());
        assert_ne!(
            create_request_fingerprint(&first, "cri-fingerprint"),
            create_request_fingerprint(&second, "cri-fingerprint")
        );
    }

    #[test]
    fn sandbox_spec_uses_containerd_oci_type_url_and_json_encoding() {
        let mut spec = Spec::default();
        spec.set_hostname(Some("cube-sandbox".to_string()));

        let encoded = encode_sandbox_spec(&spec).unwrap();

        assert_eq!(encoded.type_url, OCI_SPEC_TYPE_URL);
        let decoded: serde_json::Value = serde_json::from_slice(&encoded.value).unwrap();
        assert_eq!(decoded["hostname"], "cube-sandbox");
        assert!(decoded.get("ociVersion").is_some());
    }

    #[test]
    fn timestamps_include_nanoseconds() {
        let timestamp = now_timestamp();
        assert!(timestamp.seconds > 0);
        assert!((0..1_000_000_000).contains(&timestamp.nanos));
    }
}
