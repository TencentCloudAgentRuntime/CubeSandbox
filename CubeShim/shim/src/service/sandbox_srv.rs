// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use async_trait::async_trait;
use containerd_shim::asynchronous::ExitSignal;
use containerd_shim::protos::protobuf::{well_known_types::timestamp::Timestamp, MessageField};
use containerd_shim::protos::ttrpc::{r#async::TtrpcContext, Code, Error as TtrpcError};
use containerd_shim::protos::types::platform::Platform;
use containerd_shim::protos::{sandbox_api as api, sandbox_async::Sandbox};
use containerd_shim::TtrpcResult;
use oci_spec::runtime::Spec;
use sha2::{Digest, Sha256};
use std::path::Path;
use std::sync::Arc;
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
            runtime: None,
            created_at: None,
            exited_at: None,
            exit_status: 0,
            last_error: None,
        }
    }
}

#[derive(Default)]
pub(crate) struct SandboxLifecycle {
    state: Mutex<LifecycleState>,
    changed: Notify,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TaskMode {
    Legacy,
    ManagedReady,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ShutdownAction {
    AlreadyComplete,
    WaitForExisting,
    Run,
}

impl SandboxLifecycle {
    async fn begin_shutdown(&self) -> ShutdownAction {
        loop {
            let notified = self.changed.notified();
            let mut state = self.state.lock().await;
            match state.phase {
                Phase::Creating | Phase::Starting | Phase::Stopping => {
                    drop(state);
                    notified.await;
                }
                Phase::Shutdown => return ShutdownAction::AlreadyComplete,
                Phase::ShuttingDown => return ShutdownAction::WaitForExisting,
                _ => {
                    state.phase = Phase::ShuttingDown;
                    return ShutdownAction::Run;
                }
            }
        }
    }

    pub(crate) async fn task_mode(&self) -> Result<TaskMode, String> {
        match self.state.lock().await.phase {
            Phase::Unmanaged => Ok(TaskMode::Legacy),
            Phase::Ready => Ok(TaskMode::ManagedReady),
            phase => Err(format!(
                "sandbox is managed by Sandbox Service but is not ready (phase {phase:?})"
            )),
        }
    }

    pub(crate) async fn is_managed(&self) -> bool {
        self.state.lock().await.phase != Phase::Unmanaged
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

    async fn run_shutdown(self) {
        let release = if let Some(lease) = self.lifecycle.state.lock().await.runtime.clone() {
            lease.release().await
        } else {
            Ok(())
        };
        let abort = {
            let mut sandbox = self.sandbox.lock().await;
            let result = sandbox.abort_sandbox().await;
            sandbox.clear_runtime_tap();
            result
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
        let should_create = {
            let mut state = self.lifecycle.state.lock().await;
            match state.phase {
                Phase::Unmanaged => {
                    state.phase = Phase::Creating;
                    state.create_request = Some(fingerprint.clone());
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
        let should_shutdown = match self.lifecycle.begin_shutdown().await {
            ShutdownAction::AlreadyComplete => return Ok(api::ShutdownSandboxResponse::new()),
            ShutdownAction::WaitForExisting => false,
            ShutdownAction::Run => true,
        };
        if should_shutdown {
            tokio::spawn(self.clone().run_shutdown());
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
        let lifecycle = SandboxLifecycle::default();
        assert_eq!(lifecycle.task_mode().await.unwrap(), TaskMode::Legacy);
        assert!(!lifecycle.is_managed().await);
    }

    #[tokio::test]
    async fn managed_task_is_rejected_until_ready() {
        let lifecycle = SandboxLifecycle::default();
        lifecycle.state.lock().await.phase = Phase::Created;
        assert!(lifecycle
            .task_mode()
            .await
            .unwrap_err()
            .contains("not ready"));
        lifecycle.state.lock().await.phase = Phase::Ready;
        assert_eq!(lifecycle.task_mode().await.unwrap(), TaskMode::ManagedReady);
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
        assert_eq!(waiter.await.unwrap(), ShutdownAction::Run);
        assert_eq!(lifecycle.state.lock().await.phase, Phase::ShuttingDown);
        assert_eq!(
            lifecycle.begin_shutdown().await,
            ShutdownAction::WaitForExisting
        );
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
    fn timestamps_include_nanoseconds() {
        let timestamp = now_timestamp();
        assert!(timestamp.seconds > 0);
        assert!((0..1_000_000_000).contains(&timestamp.nanos));
    }
}
