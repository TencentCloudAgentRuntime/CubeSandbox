// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use containerd_shim::event::Event;
use containerd_shim::{
    asynchronous::{publisher::RemotePublisher, ExitSignal},
    protos::events::task::{
        TaskCreate, TaskDelete, TaskExecAdded, TaskExecStarted, TaskIO, TaskStart,
    },
    protos::{
        api,
        cgroups::metrics::{CPUStat, CPUUsage, MemoryEntry, MemoryStat, Metrics, Throttle},
        protobuf::MessageDyn,
        shim_async::Task,
        ttrpc::Error::Others,
        ttrpc::{self, r#async::TtrpcContext, Code},
        types::task,
    },
    Context, Error, TtrpcResult,
};
use protobuf::{Enum, Message};
use tokio::sync::mpsc::{channel, Receiver, Sender};
use tokio::sync::Mutex;

use crate::common::utils::Utils;
use crate::container::resources;
use crate::container::{container_mgr::ContainerInfo, exec::Tty};
use crate::log::{stat_defer, Log, LogLevel};
use crate::sandbox::sb;
use crate::service::host_cgroup::{
    lifecycle_from_env, BeginCreateError, Classification, CreateAdmission, CreatePublisherGuard,
    CreateWaiterGuard, PersistedCreateResult,
};
use crate::service::sandbox_srv::{SandboxLifecycle, TaskMode};
use crate::service::standard_rootfs::{self, PreparedRootfs};
use crate::service::update_ext;
use crate::{debugf, errf, infof, warnf};
const MODULE: &str = "Shim";
const INTERNAL_PROBE_EXEC_ID_PREFIX: &str = "cubesandbox-internal-probe-";
const CGROUP_V1_METRICS_TYPE_URL: &str = "io.containerd.cgroups.v1.Metrics";
const RESOURCE_METRICS_VERSION_V1: u32 = 1;

fn create_error_with_rootfs_cleanup(
    prepared_rootfs: &mut Option<PreparedRootfs>,
    message: String,
) -> Error {
    if let Some(rootfs) = prepared_rootfs.take() {
        if let Err(cleanup_error) = rootfs.cleanup() {
            return Error::Other(format!(
                "{message}; cleanup standard rootfs failed:{cleanup_error}"
            ));
        }
    }
    Error::Other(message)
}

fn validate_create_spec_before_rootfs_prepare(
    spec: &mut oci_spec::runtime::Spec,
) -> Result<(), String> {
    crate::container::resolve_guest_privileged_bind_sources(spec)
}

fn task_status(code: Code, message: impl Into<String>) -> ttrpc::Error {
    ttrpc::Error::RpcStatus(ttrpc::get_status(code, message.into()))
}

fn task_code_from_name(name: &str) -> Code {
    match name {
        "CANCELLED" => Code::CANCELLED,
        "INVALID_ARGUMENT" => Code::INVALID_ARGUMENT,
        "NOT_FOUND" => Code::NOT_FOUND,
        "ALREADY_EXISTS" => Code::ALREADY_EXISTS,
        "FAILED_PRECONDITION" => Code::FAILED_PRECONDITION,
        "UNAVAILABLE" => Code::UNAVAILABLE,
        "INTERNAL" => Code::INTERNAL,
        _ => Code::UNKNOWN,
    }
}

fn task_failure_identity(error: &ttrpc::Error) -> (String, String) {
    match error {
        ttrpc::Error::RpcStatus(status) => {
            (format!("{:?}", status.code()), status.message().to_string())
        }
        error => ("UNKNOWN".to_string(), error.to_string()),
    }
}

async fn persist_legacy_create_failure(
    publisher: Option<CreatePublisherGuard>,
    code: &str,
    message: &str,
) -> TtrpcResult<()> {
    let Some(publisher) = publisher else {
        return Ok(());
    };
    let code = code.to_string();
    let message = message.to_string();
    tokio::spawn(async move {
        publisher.failure_until_durable(&code, &message).await;
    })
    .await
    .map_err(|error| {
        task_status(
            Code::INTERNAL,
            format!("join legacy result publisher: {error}"),
        )
    })
}

async fn persist_legacy_create_result<T>(
    publisher: Option<CreatePublisherGuard>,
    result: &TtrpcResult<T>,
) -> TtrpcResult<()> {
    let Some(publisher) = publisher else {
        return Ok(());
    };
    let outcome = match result {
        Ok(_) => None,
        Err(error) => {
            let (code, message) = task_failure_identity(error);
            Some((code, message))
        }
    };
    tokio::spawn(async move {
        match outcome {
            Some((code, message)) => publisher.failure_until_durable(&code, &message).await,
            None => publisher.success_until_durable().await,
        }
    })
    .await
    .map_err(|error| {
        task_status(
            Code::INTERNAL,
            format!("join legacy result publisher: {error}"),
        )
    })
}

fn normalize_guest_stats(stats: &protoc::agent::StatsContainerResponse) -> Result<Metrics, String> {
    let version = stats.get_resource_metrics_version();
    if version != RESOURCE_METRICS_VERSION_V1 {
        return Err(format!(
            "guest does not support resource metrics version {} (reported version {})",
            RESOURCE_METRICS_VERSION_V1, version
        ));
    }
    if !stats.has_cgroup_stats() {
        return Err("guest response is missing cgroup stats".to_string());
    }
    let guest = stats.get_cgroup_stats();
    if !guest.has_cpu_stats() || !guest.has_memory_stats() {
        return Err("guest response is missing CPU or memory stats".to_string());
    }
    let guest_cpu = guest.get_cpu_stats();
    if !guest_cpu.has_cpu_usage() || !guest_cpu.has_throttling_data() {
        return Err("guest response is missing CPU usage or throttling stats".to_string());
    }
    if !guest.get_memory_stats().has_usage() {
        return Err("guest response is missing memory usage stats".to_string());
    }
    let guest_usage = guest_cpu.get_cpu_usage();
    let guest_throttling = guest_cpu.get_throttling_data();
    let guest_memory = guest.get_memory_stats().get_usage();

    let cpu = CPUStat {
        usage: Some(CPUUsage {
            total: guest_usage.get_total_usage(),
            kernel: guest_usage.get_usage_in_kernelmode(),
            user: guest_usage.get_usage_in_usermode(),
            per_cpu: guest_usage.get_percpu_usage().to_vec(),
            ..Default::default()
        })
        .into(),
        throttling: Some(Throttle {
            periods: guest_throttling.get_periods(),
            throttled_periods: guest_throttling.get_throttled_periods(),
            throttled_time: guest_throttling.get_throttled_time(),
            ..Default::default()
        })
        .into(),
        ..Default::default()
    };
    let memory = MemoryStat {
        usage: Some(MemoryEntry {
            usage: guest_memory.get_usage(),
            max: guest_memory.get_max_usage(),
            failcnt: guest_memory.get_failcnt(),
            limit: guest_memory.get_limit(),
            ..Default::default()
        })
        .into(),
        ..Default::default()
    };

    Ok(Metrics {
        cpu: Some(cpu).into(),
        memory: Some(memory).into(),
        ..Default::default()
    })
}

fn encode_guest_stats(
    stats: &protoc::agent::StatsContainerResponse,
) -> Result<protobuf::well_known_types::any::Any, String> {
    let metrics = normalize_guest_stats(stats)?;
    let value = metrics
        .write_to_bytes()
        .map_err(|e| format!("encode cgroup metrics failed: {}", e))?;
    Ok(protobuf::well_known_types::any::Any {
        type_url: CGROUP_V1_METRICS_TYPE_URL.to_string(),
        value,
        ..Default::default()
    })
}

#[cfg(test)]
mod stats_tests {
    use super::{encode_guest_stats, normalize_guest_stats, CGROUP_V1_METRICS_TYPE_URL};
    use protoc::agent::{
        CgroupStats, CpuStats, CpuUsage as GuestCpuUsage, MemoryData, MemoryStats,
        StatsContainerResponse, ThrottlingData,
    };

    fn complete_guest_stats_response() -> StatsContainerResponse {
        let mut response = StatsContainerResponse::new();
        let mut cgroup = CgroupStats::new();
        let mut cpu = CpuStats::new();
        cpu.set_cpu_usage(GuestCpuUsage {
            // cube-agent normalizes cgroup v2 microsecond counters to
            // nanoseconds before returning StatsContainerResponse.
            total_usage: 101_000,
            usage_in_kernelmode: 31_000,
            usage_in_usermode: 70_000,
            percpu_usage: vec![40_000, 61_000],
            ..Default::default()
        });
        cpu.set_throttling_data(ThrottlingData {
            periods: 9,
            throttled_periods: 3,
            throttled_time: 17,
            ..Default::default()
        });
        cgroup.set_cpu_stats(cpu);

        let mut memory = MemoryStats::new();
        memory.set_usage(MemoryData {
            usage: 4096,
            max_usage: 8192,
            failcnt: 2,
            limit: 16384,
            ..Default::default()
        });
        cgroup.set_memory_stats(memory);
        response.set_cgroup_stats(cgroup);
        response.set_resource_metrics_version(1);
        response
    }

    #[test]
    fn normalizes_guest_cpu_and_memory_into_containerd_metrics() {
        let response = complete_guest_stats_response();

        let metrics = normalize_guest_stats(&response).unwrap();
        assert_eq!(metrics.cpu().usage().total, 101_000);
        assert_eq!(metrics.cpu().usage().kernel, 31_000);
        assert_eq!(metrics.cpu().usage().user, 70_000);
        assert_eq!(metrics.cpu().throttling().periods, 9);
        assert_eq!(metrics.cpu().throttling().throttled_periods, 3);
        assert_eq!(metrics.cpu().throttling().throttled_time, 17);
        assert_eq!(metrics.memory().usage().usage, 4096);
        assert_eq!(metrics.memory().usage().max, 8192);
        assert_eq!(metrics.memory().usage().failcnt, 2);
        assert_eq!(metrics.memory().usage().limit, 16384);

        let encoded = encode_guest_stats(&response).unwrap();
        assert_eq!(encoded.type_url, CGROUP_V1_METRICS_TYPE_URL);
        assert!(!encoded.value.is_empty());
    }

    #[test]
    fn rejects_incomplete_guest_cpu_and_memory_stats() {
        let mut missing_cpu_stats = complete_guest_stats_response();
        missing_cpu_stats.mut_cgroup_stats().clear_cpu_stats();

        let mut missing_memory_stats = complete_guest_stats_response();
        missing_memory_stats.mut_cgroup_stats().clear_memory_stats();

        let mut missing_cpu_usage = complete_guest_stats_response();
        missing_cpu_usage
            .mut_cgroup_stats()
            .mut_cpu_stats()
            .clear_cpu_usage();

        let mut missing_throttling = complete_guest_stats_response();
        missing_throttling
            .mut_cgroup_stats()
            .mut_cpu_stats()
            .clear_throttling_data();

        let mut missing_memory_usage = complete_guest_stats_response();
        missing_memory_usage
            .mut_cgroup_stats()
            .mut_memory_stats()
            .clear_usage();

        for (name, response, expected) in [
            (
                "cpu stats",
                missing_cpu_stats,
                "guest response is missing CPU or memory stats",
            ),
            (
                "memory stats",
                missing_memory_stats,
                "guest response is missing CPU or memory stats",
            ),
            (
                "CPU usage",
                missing_cpu_usage,
                "guest response is missing CPU usage or throttling stats",
            ),
            (
                "CPU throttling",
                missing_throttling,
                "guest response is missing CPU usage or throttling stats",
            ),
            (
                "memory usage",
                missing_memory_usage,
                "guest response is missing memory usage stats",
            ),
        ] {
            assert_eq!(
                normalize_guest_stats(&response).unwrap_err(),
                expected,
                "{name}"
            );
        }
    }

    #[test]
    fn rejects_missing_guest_cgroup_stats() {
        let mut response = StatsContainerResponse::new();
        response.set_resource_metrics_version(1);
        let err = normalize_guest_stats(&response).unwrap_err();
        assert_eq!(err, "guest response is missing cgroup stats");
    }

    #[test]
    fn rejects_guest_without_resource_metrics_capability() {
        let err = normalize_guest_stats(&StatsContainerResponse::new()).unwrap_err();
        assert_eq!(
            err,
            "guest does not support resource metrics version 1 (reported version 0)"
        );
    }

    #[test]
    fn rejects_unknown_resource_metrics_capability_version() {
        let mut response = StatsContainerResponse::new();
        response.set_resource_metrics_version(2);
        let err = normalize_guest_stats(&response).unwrap_err();
        assert_eq!(
            err,
            "guest does not support resource metrics version 1 (reported version 2)"
        );
    }
}

#[derive(Clone)]
pub struct TaskService {
    sandbox_id: String,
    //ns: String,
    sandbox: Arc<Mutex<sb::SandBox>>,
    standard_rootfs: Arc<Mutex<HashMap<String, PreparedRootfs>>>,
    sandbox_lifecycle: Arc<SandboxLifecycle>,
    log: Log,
    //debug: bool,
    exit: Arc<ExitSignal>,
    tx_containerd: Sender<(String, Box<dyn MessageDyn>)>,
}

impl TaskService {
    pub async fn new(
        id: String,
        ns: String,
        debug: bool,
        exit: Arc<ExitSignal>,
        publisher: RemotePublisher,
    ) -> Self {
        let mut level = LogLevel::Info;
        if debug {
            level = LogLevel::Debug;
        }

        let log = Log::new(id.clone(), MODULE.to_string(), level);

        let (tx, rx) = channel::<(String, Box<dyn MessageDyn>)>(128);

        forward_event(rx, publisher, ns.clone(), log.clone()).await;

        let sb = sb::SandBox::new(id.clone(), log.clone(), debug, tx.clone());
        TaskService {
            sandbox_id: id,
            //ns,
            sandbox: Arc::new(Mutex::new(sb)),
            standard_rootfs: Arc::new(Mutex::new(HashMap::new())),
            sandbox_lifecycle: Arc::new(SandboxLifecycle::default()),
            log,
            //debug: debug,
            exit,
            tx_containerd: tx,
        }
    }

    pub(super) fn sandbox_id(&self) -> &str {
        &self.sandbox_id
    }

    pub(super) fn sandbox(&self) -> Arc<Mutex<sb::SandBox>> {
        self.sandbox.clone()
    }

    pub(super) fn sandbox_lifecycle(&self) -> Arc<SandboxLifecycle> {
        self.sandbox_lifecycle.clone()
    }

    pub(super) fn exit_signal(&self) -> Arc<ExitSignal> {
        self.exit.clone()
    }

    async fn tx_event(&self, topic: String, event: Box<dyn MessageDyn>) {
        self.tx_containerd
            .try_send((topic.clone(), event))
            .unwrap_or_else(|e| warnf!(self.log, "tx event:{} to publisher failed:{}", topic, e));
    }
}

#[async_trait]
impl Task for TaskService {
    async fn create(
        &self,
        _ctx: &TtrpcContext,
        req: api::CreateTaskRequest,
    ) -> TtrpcResult<api::CreateTaskResponse> {
        infof!(self.log, "create req start");
        let start = Instant::now();
        let mut stat = stat_defer::StatDefer::new(
            req.id.clone(),
            stat_defer::CALLEE_SHIM.to_string(),
            stat_defer::ACT_CREATE.to_string(),
            stat_defer::CALLEE_ACT_CREATE_POD_CONTAINER.to_string(),
            self.log.clone(),
        );

        let bundle = req.bundle.as_str();
        let lifecycle = lifecycle_from_env().map_err(Error::FailedPreconditionError)?;
        let preliminary_mode = match lifecycle.as_ref() {
            Some(lifecycle)
                if lifecycle
                    .classification()
                    .map_err(Error::FailedPreconditionError)?
                    == Classification::ManagedSandbox =>
            {
                self.sandbox_lifecycle
                    .managed_task_mode()
                    .await
                    .map_err(|error| {
                        Error::Other(format!("Create task before sandbox ready: {error}"))
                    })?
            }
            Some(_) => TaskMode::Legacy,
            None => self.sandbox_lifecycle.task_mode().await.map_err(|error| {
                Error::Other(format!("Create task before sandbox ready: {error}"))
            })?,
        };
        let mut host_waiter: Option<CreateWaiterGuard> = None;
        let mut host_publisher: Option<CreatePublisherGuard> = None;
        if matches!(preliminary_mode, TaskMode::Legacy) {
            if let Some(lifecycle) = lifecycle.as_ref() {
                let fingerprint = req.write_to_bytes().map_err(|error| {
                    Error::Other(format!("encode legacy CreateTask fingerprint: {error}"))
                })?;
                let admission = lifecycle
                    .begin_legacy_create(Path::new(bundle), &req.id, &fingerprint)
                    .map_err(|error| match error {
                        BeginCreateError::Conflict(message) => {
                            task_status(Code::ALREADY_EXISTS, message)
                        }
                        BeginCreateError::Invalid(message) => {
                            task_status(Code::FAILED_PRECONDITION, message)
                        }
                    })?;
                let waiter = lifecycle.create_waiter_guard();
                if admission != CreateAdmission::First {
                    let durable = lifecycle.wait_create_result(Duration::from_secs(45)).await;
                    if let Err(error) = waiter.finish() {
                        return Err(task_status(
                            Code::INTERNAL,
                            format!("finish legacy CreateTask waiter: {error}"),
                        ));
                    }
                    return match durable {
                        Ok(PersistedCreateResult::Succeeded) => {
                            let sb = self.sandbox.lock().await;
                            match sb.get_container_info(&req.id, &String::new()).await {
                                Ok(_) => Ok(api::CreateTaskResponse {
                                    pid: sb.pid(),
                                    ..Default::default()
                                }),
                                Err(error) => Err(task_status(
                                    Code::INTERNAL,
                                    format!(
                                        "durable legacy CreateTask success has no matching local container: {error}"
                                    ),
                                )),
                            }
                        }
                        Ok(PersistedCreateResult::Failed { code, message }) => {
                            Err(task_status(task_code_from_name(&code), message))
                        }
                        Err(error) => Err(task_status(Code::INTERNAL, error)),
                    };
                }
                host_waiter = Some(waiter);
                host_publisher = Some(lifecycle.create_publisher_guard());
                if let Err(error) = lifecycle.commit_legacy_takeover() {
                    let message = format!("commit legacy CreateTask takeover: {error}");
                    persist_legacy_create_failure(host_publisher.take(), "INTERNAL", &message)
                        .await?;
                    if let Some(waiter) = host_waiter.take() {
                        waiter.finish().map_err(|finish_error| {
                            task_status(
                                Code::INTERNAL,
                                format!("finish failed legacy takeover waiter: {finish_error}"),
                            )
                        })?;
                    }
                    return Err(task_status(Code::INTERNAL, message));
                }
                lifecycle.wait_test_failpoint("after-create-commit").await;
            }
        }

        let task_reservation = match self.sandbox_lifecycle.reserve_task_create(&req.id).await {
            Ok(reservation) => reservation,
            Err(error) => {
                let message = format!("Create task before sandbox ready: {error}");
                persist_legacy_create_failure(
                    host_publisher.take(),
                    "FAILED_PRECONDITION",
                    &message,
                )
                .await?;
                if let Some(waiter) = host_waiter.take() {
                    waiter.finish().map_err(|error| {
                        task_status(
                            Code::INTERNAL,
                            format!("finish rejected legacy CreateTask waiter: {error}"),
                        )
                    })?;
                }
                return Err(task_status(Code::FAILED_PRECONDITION, message));
            }
        };
        let task_mode = task_reservation.mode().clone();

        let result: TtrpcResult<api::CreateTaskResponse> = async {
            let (spec, resources_v2) = match &task_mode {
                TaskMode::Legacy => (Utils::load_spec(bundle), None),
                TaskMode::ManagedReady { .. } => {
                    let raw = Utils::read_spec(bundle);
                    match raw {
                        Ok(raw) => {
                            let payload = resources::canonicalize_create_config(&raw);
                            match payload {
                                Ok(payload) => (Utils::parse_spec(&raw, bundle), Some(payload)),
                                Err(error) => (Err(error), None),
                            }
                        }
                        Err(error) => (Err(error), None),
                    }
                }
            };
            let mut spec = spec.map_err(|e| {
                errf!(self.log, "Load spec failed:{}", e.clone());
                Others(format!("Load spec failed:{}", e))
            })?;
            validate_create_spec_before_rootfs_prepare(&mut spec).map_err(|e| {
                errf!(self.log, "Validate OCI bind sources failed:{}", e);
                Others(format!("Validate OCI bind sources failed:{}", e))
            })?;
            let mut prepared_rootfs = match &task_mode {
                TaskMode::Legacy => standard_rootfs::prepare_legacy(
                    &self.sandbox_id,
                    &req.id,
                    &req.rootfs,
                    &mut spec,
                ),
                TaskMode::ManagedReady { shared_root } => {
                    standard_rootfs::prepare_managed(shared_root, &req.id, &req.rootfs, &mut spec)
                        .map(Some)
                }
            }
            .map_err(|e| {
                errf!(self.log, "Prepare standard rootfs failed:{}", e);
                Error::Other(format!("Prepare standard rootfs failed:{}", e))
            })?;
            if let Some(rootfs) = prepared_rootfs.as_ref() {
                infof!(
                    self.log,
                    "standard rootfs mounted at {}",
                    rootfs.target().display()
                );
            }

            infof!(
                self.log,
                "load spec finish at:{}",
                start.elapsed().as_millis()
            );

            let mut sb = self.sandbox.lock().await;
            if sb.paused().await {
                let message = "sandbox not in normal state".to_string();
                errf!(self.log, "{}", message);
                return Err(create_error_with_rootfs_cleanup(&mut prepared_rootfs, message).into());
            }
            if !sb.inited() {
                if matches!(task_mode, TaskMode::ManagedReady { .. }) {
                    let message =
                        "managed sandbox is ready but Cube configuration is not initialized"
                            .to_string();
                    return Err(
                        create_error_with_rootfs_cleanup(&mut prepared_rootfs, message).into(),
                    );
                }
                stat.set_callee_act(stat_defer::CALLEE_ACT_CREATE_POD_SANDBOX.to_string());
                infof!(self.log, "shim pid {}", std::process::id());
                if let Err(e) = Utils::record_pid() {
                    let message = format!("Create pid file failed:{}", e);
                    errf!(self.log, "{}", message);
                    return Err(
                        create_error_with_rootfs_cleanup(&mut prepared_rootfs, message).into(),
                    );
                }
                if let Err(e) = sb.init(spec.clone()) {
                    let message = format!("Init sandbox config failed:{}", e);
                    errf!(self.log, "{}", message);
                    return Err(
                        create_error_with_rootfs_cleanup(&mut prepared_rootfs, message).into(),
                    );
                }

                if let Err(e) = sb.create_sandbox().await {
                    let message = format!("Create sandbox failed:{}", e);
                    errf!(self.log, "{}", message);
                    return Err(
                        create_error_with_rootfs_cleanup(&mut prepared_rootfs, message).into(),
                    );
                }
            }

            infof!(
                self.log,
                "start sandbox finish at:{}",
                start.elapsed().as_millis()
            );
            let info = ContainerInfo {
                id: req.id.clone(),
                bundle: req.bundle.clone(),
                stdin: req.stdin.clone(),
                stdout: req.stdout.clone(),
                stderr: req.stderr.clone(),
                terminal: req.terminal,
                ..Default::default()
            };
            if let Err(e) = sb
                .create_container(req.id.clone(), spec, info, resources_v2)
                .await
            {
                let message = format!("Create container failed:{}", e);
                errf!(self.log, "{}", message);
                return Err(create_error_with_rootfs_cleanup(&mut prepared_rootfs, message).into());
            }
            if let Some(rootfs) = prepared_rootfs {
                self.standard_rootfs
                    .lock()
                    .await
                    .insert(req.id.clone(), rootfs);
            }
            infof!(
                self.log,
                "start container finish at:{}",
                start.elapsed().as_millis()
            );

            let io = TaskIO {
                stdin: req.stdin.clone(),
                stdout: req.stdout.clone(),
                stderr: req.stderr.clone(),
                terminal: req.terminal,
                ..Default::default()
            };
            let event = TaskCreate {
                container_id: req.id.clone(),
                bundle: req.bundle.clone(),
                rootfs: req.rootfs.clone(),
                checkpoint: req.checkpoint.clone(),
                pid: sb.pid(),
                io: Some(io).into(),
                ..Default::default()
            };
            let topic = event.topic();
            self.tx_event(topic, Box::new(event)).await;
            stat.set_ok();
            infof!(self.log, "create req finish");
            Ok(api::CreateTaskResponse {
                pid: sb.pid(),
                ..Default::default()
            })
        }
        .await;
        persist_legacy_create_result(host_publisher.take(), &result).await?;
        if let Some(waiter) = host_waiter.take() {
            waiter.finish().map_err(|error| {
                task_status(
                    Code::INTERNAL,
                    format!("finish legacy CreateTask waiter: {error}"),
                )
            })?;
        }
        // Publish the external result before releasing the local reservation,
        // so a same-fingerprint waiter can distinguish completion from a
        // cancelled RPC. Drop still runs automatically on cancellation.
        drop(task_reservation);
        result
    }
    async fn start(
        &self,
        _ctx: &TtrpcContext,
        req: api::StartRequest,
    ) -> TtrpcResult<api::StartResponse> {
        let start_at = Instant::now();
        infof!(
            self.log,
            "start request, id:{}, execid:{}",
            req.id(),
            req.exec_id()
        );
        let sb = {
            let sb = self.sandbox.lock().await;
            if sb.paused().await {
                errf!(self.log, "sandbox not in normal state");
                return Err(Others(format!("sandbox not in normal state")));
            }
            sb.clone()
        };
        if req.exec_id().is_empty() {
            sb.start_container(&req.id).await.map_err(|e| {
                errf!(self.log, "Start container failed:{}", e);
                e
            })?;

            let event = TaskStart {
                container_id: req.id.clone(),
                pid: sb.pid(),
                ..Default::default()
            };
            let topic = event.topic();
            self.tx_event(topic, Box::new(event)).await;
        } else {
            sb.start_exec(&req.id, &req.exec_id).await.map_err(|e| {
                errf!(self.log, "Start exec failed:{}", e);
                e
            })?;

            let event = TaskExecStarted {
                container_id: req.id.clone(),
                exec_id: req.exec_id.clone(),
                pid: sb.pid(),
                ..Default::default()
            };
            let topic = event.topic();
            self.tx_event(topic, Box::new(event)).await;
        }
        infof!(
            self.log,
            "start req finish, id:{}, execid:{}, cost_ms:{}",
            req.id(),
            req.exec_id(),
            start_at.elapsed().as_millis()
        );
        Ok(api::StartResponse {
            pid: sb.pid(),
            ..Default::default()
        })
    }

    async fn wait(
        &self,
        _ctx: &TtrpcContext,
        req: api::WaitRequest,
    ) -> TtrpcResult<api::WaitResponse> {
        let start_at = Instant::now();
        infof!(
            self.log,
            "wait req start, id:{}, execid:{}",
            req.id(),
            req.exec_id()
        );

        let sb = {
            let sb = self.sandbox.lock().await;
            sb.clone()
        };
        if sb.paused().await {
            errf!(self.log, "sandbox not in normal state");
            return Err(Others(format!("sandbox not in normal state")));
        }

        let (code, tm) = sb
            .wait_container(&req.id, &req.exec_id)
            .await
            .map_err(|e| {
                errf!(self.log, "wait failed:{}", e);
                e
            })?;
        let e_tm: protobuf::well_known_types::timestamp::Timestamp =
            protobuf::well_known_types::timestamp::Timestamp {
                seconds: tm.timestamp(),
                ..Default::default()
            };
        infof!(
            self.log,
            "wait req finish, id:{}, execid:{}, exit_status:{}, cost_ms:{}",
            req.id(),
            req.exec_id(),
            code,
            start_at.elapsed().as_millis()
        );
        Ok(api::WaitResponse {
            exit_status: code,
            exited_at: Some(e_tm).into(),
            ..Default::default()
        })
    }

    async fn stats(
        &self,
        _ctx: &TtrpcContext,
        req: api::StatsRequest,
    ) -> TtrpcResult<api::StatsResponse> {
        if req.id.is_empty() {
            return Err(Error::InvalidArgument("stats request id is empty".to_string()).into());
        }

        let sb = {
            let sb = self.sandbox.lock().await;
            sb.clone()
        };
        let guest_stats = sb.stats_container(&req.id).await.map_err(|e| {
            errf!(self.log, "StatsContainer failed for {}: {}", req.id, e);
            e
        })?;
        let stats = encode_guest_stats(&guest_stats).map_err(Error::FailedPreconditionError)?;

        Ok(api::StatsResponse {
            stats: Some(stats).into(),
            ..Default::default()
        })
    }

    async fn delete(
        &self,
        _ctx: &TtrpcContext,
        req: api::DeleteRequest,
    ) -> TtrpcResult<api::DeleteResponse> {
        let start_at = Instant::now();
        infof!(
            self.log,
            "delete req start, id:{}, execid:{}",
            req.id(),
            req.exec_id()
        );
        let mut stat = stat_defer::StatDefer::new(
            req.id.clone(),
            stat_defer::CALLEE_SHIM.to_string(),
            stat_defer::ACT_DELETE.to_string(),
            stat_defer::CALLEE_ACT_DEL_CONTAINER.to_string(),
            self.log.clone(),
        );
        let mut sb = self.sandbox.lock().await;
        // After PauseToSnapshot the MicroVM is already gone; Cubelet Destroy may
        // still call Delete to reap the task. Treat delete-while-paused as
        // success and exit the shim (same as shutdown).
        if sb.paused().await {
            infof!(
                self.log,
                "delete after pause-to-snapshot; treating as success and exiting shim"
            );
            let exit_tm = protobuf::well_known_types::timestamp::Timestamp {
                seconds: chrono::Utc::now().timestamp(),
                ..Default::default()
            };
            let pid = sb.pid();
            drop(sb);
            let exit = self.exit.clone();
            let log = self.log.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(50)).await;
                infof!(log, "pause-to-snapshot delete: signaling shim exit");
                exit.signal();
            });
            stat.set_ok();
            return Ok(api::DeleteResponse {
                pid,
                exit_status: 0,
                exited_at: Some(exit_tm).into(),
                ..Default::default()
            });
        }
        let (exit_code, exit_tm) = {
            if req.exec_id.is_empty() {
                match sb.delete_container(&req.id).await {
                    Err(e) => {
                        errf!(self.log, "delete container failed:{}", e);
                        return Err(e.into());
                    }
                    Ok((code, tm)) => {
                        let e_tm = protobuf::well_known_types::timestamp::Timestamp {
                            seconds: tm.timestamp(),
                            ..Default::default()
                        };
                        let rootfs = { self.standard_rootfs.lock().await.remove(&req.id) };
                        if let Some(rootfs) = rootfs {
                            if let Err(e) = rootfs.cleanup() {
                                // Drop performs a lazy-unmount fallback. The S0
                                // replay separately asserts no mount remains.
                                warnf!(self.log, "cleanup standard rootfs failed:{}", e);
                            }
                        }
                        let event = TaskDelete {
                            container_id: req.id.clone(),
                            pid: sb.pid(),
                            exit_status: code,
                            exited_at: Some(e_tm.clone()).into(),
                            ..Default::default()
                        };
                        let topic = event.topic();
                        self.tx_event(topic, Box::new(event)).await;
                        (code, e_tm)
                    }
                }
            } else {
                match sb.delete_exec(&req.id, &req.exec_id).await {
                    Err(e) => {
                        errf!(self.log, "delete exec failed:{}", e);
                        return Err(e.into());
                    }

                    Ok((code, tm)) => {
                        let e_tm = protobuf::well_known_types::timestamp::Timestamp {
                            seconds: tm.timestamp(),
                            ..Default::default()
                        };
                        (code, e_tm)
                    }
                }
            }
        };
        stat.set_ok();
        infof!(
            self.log,
            "delete req finish, id:{}, execid:{}, exit_status:{}, cost_ms:{}",
            req.id(),
            req.exec_id(),
            exit_code,
            start_at.elapsed().as_millis()
        );

        Ok(api::DeleteResponse {
            pid: sb.pid(),
            exit_status: exit_code,
            exited_at: Some(exit_tm).into(),
            ..Default::default()
        })
    }

    async fn kill(&self, _ctx: &TtrpcContext, req: api::KillRequest) -> TtrpcResult<api::Empty> {
        infof!(
            self.log,
            "kill req start, id:{} execid:{}",
            req.id(),
            req.exec_id()
        );
        let mut exec_id = req.exec_id.clone();
        if req.all {
            exec_id = "".to_string();
        }
        let sb = self.sandbox.lock().await;
        if sb.paused().await {
            errf!(self.log, "sandbox not in normal state");
            return Err(Others(format!("sandbox not in normal state")));
        }
        sb.kill_container(&req.id, &exec_id, req.signal())
            .await
            .map_err(|e| {
                errf!(self.log, "Kill container failed:{}", e);
                e
            })?;

        infof!(self.log, "kill req finish");
        Ok(api::Empty::default())
    }

    async fn update(
        &self,
        _ctx: &TtrpcContext,
        req: api::UpdateTaskRequest,
    ) -> TtrpcResult<api::Empty> {
        infof!(self.log, "update req start, id:{}", &req.id);
        let managed = self.sandbox_lifecycle.is_managed().await;
        let parsed_resources = if let Some(resource) = req.resources.as_ref() {
            let resources_v2 = if managed {
                if resource.type_url != resources::OCI_LINUX_RESOURCES_TYPE_URL {
                    return Err(Error::Other(format!(
                        "Invalid resource type URL {:?}; expected {}",
                        resource.type_url,
                        resources::OCI_LINUX_RESOURCES_TYPE_URL
                    ))
                    .into());
                }
                Some(
                    resources::canonicalize_update(resource.value.as_slice()).map_err(|error| {
                        Error::Other(format!("Invalid raw resource config:{error}"))
                    })?,
                )
            } else {
                None
            };
            let resources = Utils::get_oci_res(resource.value.as_slice())
                .map_err(|e| Error::Other(format!("Invalid format process config:{}", e)))?;
            Some((resources, resources_v2))
        } else {
            None
        };
        let sb = {
            let sb = self.sandbox.lock().await;
            if sb.paused().await {
                errf!(self.log, "sandbox not in normal state");
                return Err(Others(format!("sandbox not in normal state")));
            }
            sb.clone()
        };
        if let Some((resources, resources_v2)) = parsed_resources.as_ref() {
            sb.update_container(&req.id, resources, resources_v2.as_deref())
                .await
                .map_err(|e| {
                    errf!(self.log, "update container failed:{}", e);
                    e
                })?;
        }

        let outcome = {
            let mut sb = self.sandbox.lock().await;
            if sb.paused().await {
                errf!(self.log, "sandbox not in normal state");
                return Err(Others(format!("sandbox not in normal state")));
            }
            sb.update_sandbox(&req.annotations).await.map_err(|e| {
                errf!(self.log, "update sandbox failed:{}", e.clone());
                Error::Other(format!("update sandbox failed:{}", e))
            })?;

            update_ext::update_route(&mut sb, &req.annotations, &self.log)
                .await
                .map_err(|e| {
                    errf!(self.log, "update sandbox failed:{}", e.clone());
                    Error::Other(format!("update sandbox failed:{}", e))
                })?
        };

        // Optional self-exit after Update (PauseToSnapshot does not use this;
        // Cubelet reaps the paused shim via Delete / keep_tombstone).
        if outcome.exit_shim {
            let exit = self.exit.clone();
            let log = self.log.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(50)).await;
                infof!(log, "pause to snapshot: signaling shim exit");
                exit.signal();
            });
        }

        infof!(self.log, "update req finish");
        Ok(api::Empty::default())
    }

    async fn connect(
        &self,
        _ctx: &TtrpcContext,
        _req: api::ConnectRequest,
    ) -> TtrpcResult<api::ConnectResponse> {
        debugf!(self.log, "connect request");
        let pid = std::process::id();
        Ok(api::ConnectResponse {
            shim_pid: pid,
            task_pid: pid,
            ..Default::default()
        })
    }

    async fn shutdown(
        &self,
        _ctx: &TtrpcContext,
        _req: api::ShutdownRequest,
    ) -> TtrpcResult<api::Empty> {
        infof!(self.log, "shutdown req start");

        if self.sandbox_lifecycle.is_managed().await {
            infof!(
                self.log,
                "managed sandbox ignores Task.Shutdown; Sandbox.Shutdown owns the shim"
            );
            return Ok(api::Empty::default());
        }

        let mut sb = self.sandbox.lock().await;
        // After PauseToSnapshot the sandbox is Paused (MicroVM already gone).
        // Allow shutdown so Cubelet can reap the shim; skip destroy_sandbox
        // when already paused because there is no live VM to tear down.
        let already_paused = sb.paused().await;
        if !already_paused && !sb.is_empty().await {
            infof!(
                self.log,
                "sandbox not empty, do nothing, shutdown req finish"
            );
            return Ok(api::Empty::default());
        }
        if !already_paused {
            if let Err(e) = sb.destroy_sandbox().await {
                errf!(self.log, "shutdown failed:{}", e)
            } else {
                infof!(self.log, "shutdown req finish");
            }
        } else {
            infof!(
                self.log,
                "shutdown after pause-to-snapshot; signaling shim exit"
            );
        }
        self.exit.signal();
        Ok(api::Empty::default())
    }

    async fn state(
        &self,
        _ctx: &TtrpcContext,
        req: api::StateRequest,
    ) -> TtrpcResult<api::StateResponse> {
        let sb = self.sandbox.lock().await;
        match sb.get_container_info(&req.id, &req.exec_id).await {
            Ok(c) => {
                let state = protobuf::EnumOrUnknown::new(
                    task::Status::from_i32(c.state as i32).unwrap_or(task::Status::default()),
                );
                let mut rsp = api::StateResponse {
                    id: req.id.clone(),
                    exec_id: req.exec_id.clone(),
                    status: state,
                    bundle: c.bundle,
                    pid: sb.pid(),
                    stdout: c.stdout,
                    stderr: c.stderr,
                    terminal: c.terminal,
                    exit_status: c.exit_code,
                    ..Default::default()
                };

                if let Some(exit_tm) = c.exit_tm {
                    rsp.exited_at = Some(protobuf::well_known_types::timestamp::Timestamp {
                        seconds: exit_tm.timestamp(),
                        ..Default::default()
                    })
                    .into();
                }
                if sb.paused().await {
                    rsp.status = protobuf::EnumOrUnknown::new(task::Status::PAUSED);
                }
                return Ok(rsp);
            }
            Err(e) => {
                errf!(self.log, "state request error:{}", e);
                Err(e.into())
            }
        }
    }

    async fn exec(
        &self,
        _ctx: &TtrpcContext,
        req: api::ExecProcessRequest,
    ) -> TtrpcResult<api::Empty> {
        let start_at = Instant::now();
        infof!(
            self.log,
            "exec req start, id:{}, execid:{}",
            req.id(),
            req.exec_id()
        );
        let sb = self.sandbox.lock().await;
        if sb.app_snapshot_create() && !is_internal_probe_exec_id(req.exec_id()) {
            infof!(self.log, "exec disabled while app snapshotting");
            return Err(Others("exec disabled while app snapshotting".to_string()));
        }
        if sb.paused().await {
            errf!(self.log, "sandbox not in normal state");
            return Err(Others(format!("sandbox not in normal state")));
        }
        let proc = match req.spec.as_ref() {
            Some(v) => Utils::get_oci_proc(v.value.as_slice()).map_err(|e| {
                errf!(self.log, "Invalid format process config:{}", e.clone());
                Error::Other(format!("Invalid format process config:{}", e))
            })?,
            None => {
                return Err(Others("Not found process config".to_string()));
            }
        };

        let tty = Tty {
            stdout: req.stdout.clone(),
            stderr: req.stderr.clone(),
            stdin: req.stdin.clone(),
            terminal: req.terminal,
            ..Default::default()
        };

        sb.exec_container(&req.id, &req.exec_id, tty, proc)
            .await
            .map_err(|e| {
                errf!(self.log, "Exec container:{} failed:{}", req.id.clone(), e);
                e
            })?;

        let event = TaskExecAdded {
            container_id: req.id.clone(),
            exec_id: req.exec_id.clone(),
            ..Default::default()
        };
        let topic = event.topic();
        self.tx_event(topic, Box::new(event)).await;
        infof!(
            self.log,
            "exec req finish, id:{}, execid:{}, cost_ms:{}",
            req.id(),
            req.exec_id(),
            start_at.elapsed().as_millis()
        );
        Ok(api::Empty::default())
    }

    async fn close_io(
        &self,
        _ctx: &TtrpcContext,
        req: api::CloseIORequest,
    ) -> TtrpcResult<api::Empty> {
        let start_at = Instant::now();
        infof!(
            self.log,
            "close_io req start, id:{}, execid:{}",
            req.id(),
            req.exec_id()
        );

        if !req.stdin {
            infof!(
                self.log,
                "close_io req finish, id:{}, execid:{}, stdin:false, cost_ms:{}",
                req.id(),
                req.exec_id(),
                start_at.elapsed().as_millis()
            );
            return Ok(api::Empty::default());
        }

        let sb = self.sandbox.lock().await;
        if sb.paused().await {
            errf!(self.log, "sandbox not in normal state");
            return Err(Others(format!("sandbox not in normal state")));
        }

        sb.close_io(&req.id, &req.exec_id).await.map_err(|e| {
            errf!(self.log, "close_io failed:{}", e);
            e
        })?;

        infof!(
            self.log,
            "close_io req finish, id:{}, execid:{}, stdin:true, cost_ms:{}",
            req.id(),
            req.exec_id(),
            start_at.elapsed().as_millis()
        );
        Ok(api::Empty::default())
    }

    async fn resize_pty(
        &self,
        _ctx: &TtrpcContext,
        _req: api::ResizePtyRequest,
    ) -> TtrpcResult<api::Empty> {
        Ok(api::Empty::default())
    }

    async fn pids(
        &self,
        _ctx: &TtrpcContext,
        _req: api::PidsRequest,
    ) -> TtrpcResult<api::PidsResponse> {
        let sb = self.sandbox.lock().await;
        let rsp = api::PidsResponse {
            processes: vec![task::ProcessInfo {
                pid: sb.pid(),
                ..Default::default()
            }],
            ..Default::default()
        };
        Ok(rsp)
    }

    async fn pause(&self, ctx: &TtrpcContext, _req: api::PauseRequest) -> TtrpcResult<api::Empty> {
        infof!(self.log, "pause req start");
        if ctx.metadata.get("pod_scope").is_none() {
            return Err(Others(
                "current pause operations are only supported at the pod level".to_string(),
            ));
        }
        let mut sb: tokio::sync::MutexGuard<'_, sb::SandBox> = self.sandbox.lock().await;
        if !sb.normal().await {
            errf!(self.log, "sandbox not in normal state");
            return Err(Others(format!("sandbox not in normal state")));
        }

        sb.pause_vm().await.map_err(|e| {
            errf!(self.log, "pause vm failed:{}", e);
            Error::Other(format!("Pause vm failed:{}", e))
        })?;

        infof!(self.log, "pause req finish");
        Ok(api::Empty::default())
    }

    async fn resume(
        &self,
        ctx: &TtrpcContext,
        _req: api::ResumeRequest,
    ) -> TtrpcResult<api::Empty> {
        infof!(self.log, "resume req start");
        if ctx.metadata.get("pod_scope").is_none() {
            return Err(Others(
                "current resume operations are only supported at the pod level.".to_string(),
            ));
        }
        let mut sb: tokio::sync::MutexGuard<'_, sb::SandBox> = self.sandbox.lock().await;
        if !sb.paused().await {
            errf!(self.log, "sandbox not in paused state");
            return Err(Others(format!("sandbox not in paused state")));
        }
        sb.resume_vm().await.map_err(|e| {
            errf!(self.log, "resume vm failed:{}", e);
            Error::Other(format!("Resume vm failed:{}", e))
        })?;
        infof!(self.log, "resume req finish");
        Ok(api::Empty::default())
    }
}

fn is_internal_probe_exec_id(exec_id: &str) -> bool {
    exec_id.starts_with(INTERNAL_PROBE_EXEC_ID_PREFIX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn privileged_spec_with_mount(source: &std::path::Path) -> oci_spec::runtime::Spec {
        serde_json::from_value(serde_json::json!({
            "ociVersion": "1.0.2",
            "process": {
                "user": {"uid": 0, "gid": 0},
                "args": ["true"],
                "cwd": "/",
                "capabilities": {
                    "bounding": ["CAP_SYS_ADMIN", "CAP_SYS_MODULE", "CAP_SYS_RAWIO"],
                    "effective": ["CAP_SYS_ADMIN", "CAP_SYS_MODULE", "CAP_SYS_RAWIO"],
                    "permitted": ["CAP_SYS_ADMIN", "CAP_SYS_MODULE", "CAP_SYS_RAWIO"]
                }
            },
            "mounts": [{
                "destination": "/host-dev",
                "type": "bind",
                "source": source,
                "options": ["rbind", "rw"]
            }],
            "linux": {
                "devices": [],
                "resources": {"devices": [{"allow": true, "access": "rwm"}]},
                "maskedPaths": [],
                "readonlyPaths": []
            }
        }))
        .unwrap()
    }

    #[test]
    fn internal_probe_exec_requires_exec_id_prefix() {
        assert!(is_internal_probe_exec_id(
            "cubesandbox-internal-probe-4e7d6a"
        ));
        assert!(!is_internal_probe_exec_id("internal-probe-4e7d6a"));
        assert!(!is_internal_probe_exec_id(
            "user-cubesandbox-internal-probe-4e7d6a"
        ));
    }

    #[test]
    fn create_rejects_direct_host_dev_before_rootfs_prepare() {
        let mut spec = privileged_spec_with_mount(std::path::Path::new("/dev"));
        let error = validate_create_spec_before_rootfs_prepare(&mut spec).unwrap_err();
        assert!(error.contains("Host /dev mount source"));
    }

    #[cfg(target_family = "unix")]
    #[test]
    fn create_rejects_host_dev_symlink_before_rootfs_prepare() {
        use std::os::unix::fs::symlink;

        let test_root = std::env::temp_dir().join(format!(
            "cubesandbox-privileged-dev-alias-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&test_root).unwrap();
        let alias = test_root.join("host-dev");
        symlink("/dev", &alias).unwrap();

        let mut spec = privileged_spec_with_mount(&alias);
        let error = validate_create_spec_before_rootfs_prepare(&mut spec).unwrap_err();
        assert!(error.contains("Host /dev mount source"));

        std::fs::remove_dir_all(test_root).unwrap();
    }

    #[test]
    fn create_fails_closed_when_privileged_bind_source_cannot_be_resolved() {
        let source = std::env::temp_dir().join(format!(
            "cubesandbox-missing-privileged-bind-{}",
            uuid::Uuid::new_v4()
        ));
        let mut spec = privileged_spec_with_mount(&source);
        let error = validate_create_spec_before_rootfs_prepare(&mut spec).unwrap_err();
        assert!(error.contains("resolve privileged host bind mount source"));
        assert!(error.contains("failed"));
    }

    #[cfg(target_family = "unix")]
    #[test]
    fn create_freezes_resolved_bind_source_before_symlink_switch() {
        use std::os::unix::fs::symlink;

        let test_root = std::env::temp_dir().join(format!(
            "cubesandbox-privileged-bind-freeze-{}",
            uuid::Uuid::new_v4()
        ));
        let safe = test_root.join("safe");
        std::fs::create_dir_all(&safe).unwrap();
        let alias = test_root.join("source");
        symlink(&safe, &alias).unwrap();

        let mut spec = privileged_spec_with_mount(&alias);
        validate_create_spec_before_rootfs_prepare(&mut spec).unwrap();
        let frozen = spec.mounts().as_ref().unwrap()[0]
            .source()
            .as_ref()
            .unwrap()
            .clone();
        assert_eq!(frozen, std::fs::canonicalize(&safe).unwrap());
        assert_ne!(frozen, alias);

        std::fs::remove_file(&alias).unwrap();
        symlink("/dev", &alias).unwrap();
        assert_eq!(spec.mounts().as_ref().unwrap()[0].source(), &Some(frozen));

        std::fs::remove_dir_all(test_root).unwrap();
    }
}

async fn forward_event(
    mut rx: Receiver<(String, Box<dyn MessageDyn>)>,
    publisher: RemotePublisher,
    ns: String,
    log: Log,
) {
    tokio::spawn(async move {
        let mut publisher = publisher;
        const TTRPC_ADDRESS: &str = "TTRPC_ADDRESS";
        while let Some((topic, evt)) = rx.recv().await {
            let ret = publisher
                .publish(Context::default(), &topic, &ns, evt.clone())
                .await;

            if let Err(e) = ret {
                warnf!(log, "publish {} to containerd failed: {}", topic, e);
                if let Ok(ttrpc_address) = std::env::var(TTRPC_ADDRESS) {
                    match RemotePublisher::new(ttrpc_address).await {
                        Ok(p) => {
                            publisher = p;
                            publisher
                                .publish(Context::default(), &topic, &ns, evt)
                                .await
                                .unwrap_or_else(|e| {
                                    warnf!(log, "publish {} to containerd failed: {}", topic, e)
                                });
                        }
                        Err(e) => warnf!(log, "RemotePublisher reconnect failed:{}", e),
                    }
                } else {
                    warnf!(log, "not found env {} can't reconnect", TTRPC_ADDRESS);
                }
            }
        }
    });
}
