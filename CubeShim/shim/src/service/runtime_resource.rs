// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Client for Cubelet's node-resources-only RuntimeResource v1 service.

#[cfg(test)]
mod identity_tests;
mod reaper_queue;
#[cfg(test)]
mod reaper_queue_tests;

use hyper_util::rt::TokioIo;
use nix::cmsg_space;
use nix::sys::socket::{recvmsg, MsgFlags};
use oci_spec::runtime::Spec;
use prost::Message;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{IoSliceMut, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;
use tokio::net::UnixStream;
use tonic::codegen::http::uri::PathAndQuery;
use tonic::transport::{Channel, Endpoint};
use tonic::{Request, Status};
use tower::service_fn;

const API_VERSION: u32 = 1;
const FD_PROTOCOL_VERSION: u32 = 1;
const SERVICE_MODE: &str = "node-resources-only";
const DEFAULT_ENDPOINT: &str = "/data/cubelet/cubelet.sock";
const VIRTIOFS_SHARED_DIR: &str = "/data/cubelet";
const ANNO_VM_RES: &str = "cube.vmmres";
const ANNO_VM_KERNEL: &str = "cube.vm.kernel.path";
const ANNO_VM_AGENT: &str = "cube.vm.agent.path";
const ANNO_VM_OS_IMAGE: &str = "cube.vm.os-image.path";
const ANNO_VMM_FS: &str = "cube.fs";
const ANNO_NET: &str = "cube.net";
const ANNO_SNAPSHOT_DISABLE: &str = "cube.snapshot.disable";
const ANNO_USE_PASSFD_IO: &str = "cube.use_passfd_io";
const ANNO_SANDBOX_UID: &str = "io.kubernetes.cri.sandbox-uid";
const ANNO_SANDBOX_NAMESPACE: &str = "io.kubernetes.cri.sandbox-namespace";
const ANNO_SANDBOX_NAME: &str = "io.kubernetes.cri.sandbox-name";
const ANNO_SANDBOX_DNS: &str = "cube.sandbox.dns";
const ANNO_SANDBOX_HOSTNAME: &str = "cube.sandbox.hostname";
const ANNO_SANDBOX_PIDNS: &str = "cube.sandbox.pidns";
const CRI_V1_POD_SANDBOX_CONFIG: &str = "runtime.v1.PodSandboxConfig";
const RUNTIME_CLEANUP_RECORD: &str = "cube-runtime-resource.json";
const RUNTIME_REAPER_ROOT_ENV: &str = "CUBE_RUNTIME_RESOURCE_REAPER_DIR";
const DEFAULT_RUNTIME_REAPER_ROOT: &str = "/data/cubelet/runtime-resource-reaper";
pub(crate) const RUNTIME_REAPER_ACTION: &str = "runtime-resource-reaper";

const REQUIRED_CAPABILITIES: [(&str, u32); 3] = [
    ("io.cubesandbox.runtime.assets", 1),
    ("io.cubesandbox.runtime.network.tcfilter", 1),
    ("io.cubesandbox.runtime.fd-handoff", 1),
];

#[derive(Clone, PartialEq, Message)]
struct GetCapabilitiesRequest {
    #[prost(uint32, tag = "1")]
    client_api_version: u32,
}

#[derive(Clone, PartialEq, Message)]
struct Capability {
    #[prost(string, tag = "1")]
    name: String,
    #[prost(uint32, tag = "2")]
    version: u32,
}

#[derive(Clone, PartialEq, Message)]
struct GetCapabilitiesResponse {
    #[prost(uint32, tag = "1")]
    api_version: u32,
    #[prost(message, repeated, tag = "2")]
    capabilities: Vec<Capability>,
    #[prost(string, tag = "3")]
    service_mode: String,
    #[prost(string, tag = "4")]
    fd_handoff_endpoint: String,
}

#[derive(Clone, PartialEq, Message)]
struct PodIdentity {
    #[prost(string, tag = "1")]
    uid: String,
    #[prost(string, tag = "2")]
    namespace: String,
    #[prost(string, tag = "3")]
    name: String,
    #[prost(uint32, tag = "4")]
    attempt: u32,
}

#[derive(Clone, PartialEq, Message)]
struct ResourceRequest {
    #[prost(uint32, tag = "1")]
    vcpu_count: u32,
    #[prost(uint64, tag = "2")]
    memory_bytes: u64,
}

#[derive(Clone, PartialEq, Message)]
struct NetworkIntent {
    #[prost(string, tag = "1")]
    netns_path: String,
    #[prost(string, tag = "2")]
    interface_name: String,
    #[prost(string, tag = "3")]
    pod_ip: String,
    #[prost(string, repeated, tag = "4")]
    dns: Vec<String>,
}

// Partial CRI v1 messages: prost ignores wire fields CubeShim does not use.
#[derive(Clone, PartialEq, Message)]
pub(crate) struct CriPodSandboxConfig {
    #[prost(message, optional, tag = "1")]
    metadata: Option<CriPodSandboxMetadata>,
    #[prost(message, optional, tag = "4")]
    dns_config: Option<CriDnsConfig>,
    #[prost(map = "string, string", tag = "7")]
    annotations: HashMap<String, String>,
    #[prost(message, optional, tag = "8")]
    linux: Option<CriLinuxPodSandboxConfig>,
    #[prost(string, tag = "2")]
    hostname: String,
}

#[derive(Clone, PartialEq, Message)]
struct CriPodSandboxMetadata {
    #[prost(string, tag = "1")]
    name: String,
    #[prost(string, tag = "2")]
    uid: String,
    #[prost(string, tag = "3")]
    namespace: String,
    #[prost(uint32, tag = "4")]
    attempt: u32,
}

#[derive(Clone, PartialEq, Message)]
struct CriDnsConfig {
    #[prost(string, repeated, tag = "1")]
    servers: Vec<String>,
    #[prost(string, repeated, tag = "2")]
    searches: Vec<String>,
    #[prost(string, repeated, tag = "3")]
    options: Vec<String>,
}

#[derive(Clone, PartialEq, Message)]
struct CriLinuxPodSandboxConfig {
    #[prost(message, optional, tag = "2")]
    security_context: Option<CriLinuxSandboxSecurityContext>,
    #[prost(message, optional, tag = "5")]
    resources: Option<CriLinuxContainerResources>,
}

#[derive(Clone, PartialEq, Message)]
struct CriLinuxSandboxSecurityContext {
    #[prost(message, optional, tag = "1")]
    namespace_options: Option<CriNamespaceOption>,
}

#[derive(Clone, PartialEq, Message)]
struct CriNamespaceOption {
    #[prost(int32, tag = "1")]
    network: i32,
    #[prost(int32, tag = "2")]
    pid: i32,
    #[prost(int32, tag = "3")]
    ipc: i32,
    #[prost(string, tag = "4")]
    target_id: String,
}

#[derive(Clone, PartialEq, Message)]
struct CriLinuxContainerResources {
    #[prost(int64, tag = "1")]
    cpu_period: i64,
    #[prost(int64, tag = "2")]
    cpu_quota: i64,
    #[prost(int64, tag = "3")]
    cpu_shares: i64,
    #[prost(int64, tag = "4")]
    memory_limit_in_bytes: i64,
}

#[derive(Clone, PartialEq, Message)]
struct PrepareSandboxRequest {
    #[prost(string, tag = "1")]
    sandbox_id: String,
    #[prost(string, tag = "2")]
    idempotency_key: String,
    #[prost(uint64, tag = "3")]
    generation: u64,
    #[prost(message, optional, tag = "4")]
    pod: Option<PodIdentity>,
    #[prost(message, optional, tag = "5")]
    resources: Option<ResourceRequest>,
    #[prost(message, optional, tag = "6")]
    network: Option<NetworkIntent>,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct RuntimeAssets {
    #[prost(string, tag = "1")]
    pub(crate) kernel_path: String,
    #[prost(string, tag = "2")]
    pub(crate) agent_path: String,
    #[prost(string, tag = "3")]
    pub(crate) guest_image_path: String,
    #[prost(string, tag = "4")]
    pub(crate) shared_root: String,
}

#[derive(Clone, PartialEq, Message, Serialize)]
pub(crate) struct Route {
    #[prost(string, tag = "1")]
    #[serde(rename = "dest")]
    pub(crate) destination: String,
    #[prost(string, tag = "2")]
    pub(crate) gateway: String,
    #[prost(string, tag = "3")]
    pub(crate) source: String,
    #[prost(string, tag = "4")]
    pub(crate) device: String,
    #[prost(uint32, tag = "5")]
    pub(crate) scope: u32,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct Neighbor {
    #[prost(string, tag = "1")]
    pub(crate) ip: String,
    #[prost(string, tag = "2")]
    pub(crate) mac: String,
    #[prost(string, tag = "3")]
    pub(crate) device: String,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct FdHandoffDescriptor {
    #[prost(uint32, tag = "1")]
    pub(crate) protocol_version: u32,
    #[prost(string, tag = "2")]
    pub(crate) endpoint: String,
    #[prost(string, tag = "3")]
    pub(crate) token: String,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct NetworkAttachment {
    #[prost(string, tag = "1")]
    pub(crate) network_handle: String,
    #[prost(string, tag = "2")]
    pub(crate) tap_name: String,
    #[prost(string, tag = "3")]
    pub(crate) guest_interface_name: String,
    #[prost(string, tag = "4")]
    pub(crate) mac: String,
    #[prost(uint32, tag = "5")]
    pub(crate) mtu: u32,
    #[prost(string, repeated, tag = "6")]
    pub(crate) ips: Vec<String>,
    #[prost(message, repeated, tag = "7")]
    pub(crate) routes: Vec<Route>,
    #[prost(message, repeated, tag = "8")]
    pub(crate) neighbors: Vec<Neighbor>,
    #[prost(message, optional, tag = "9")]
    pub(crate) fd_handoff: Option<FdHandoffDescriptor>,
}

#[derive(Clone, PartialEq, Message)]
pub(crate) struct PreparedSandbox {
    #[prost(string, tag = "1")]
    pub(crate) sandbox_id: String,
    #[prost(string, tag = "2")]
    pub(crate) lease_id: String,
    #[prost(uint64, tag = "3")]
    pub(crate) generation: u64,
    #[prost(message, optional, tag = "4")]
    pub(crate) assets: Option<RuntimeAssets>,
    #[prost(message, optional, tag = "5")]
    pub(crate) network: Option<NetworkAttachment>,
}

#[derive(Clone, PartialEq, Message)]
struct PrepareSandboxResponse {
    #[prost(message, optional, tag = "1")]
    sandbox: Option<PreparedSandbox>,
    #[prost(bool, tag = "2")]
    reused: bool,
}

#[derive(Clone, PartialEq, Message)]
struct ReleaseSandboxRequest {
    #[prost(string, tag = "1")]
    sandbox_id: String,
    #[prost(string, tag = "2")]
    lease_id: String,
    #[prost(uint64, tag = "3")]
    generation: u64,
    #[prost(string, tag = "4")]
    idempotency_key: String,
}

#[derive(Clone, PartialEq, Message)]
struct ReleaseSandboxResponse {
    #[prost(bool, tag = "1")]
    released: bool,
}

#[derive(Clone, PartialEq, Message)]
struct FdHandoffRequestV1 {
    #[prost(uint32, tag = "1")]
    protocol_version: u32,
    #[prost(string, tag = "2")]
    sandbox_id: String,
    #[prost(uint64, tag = "3")]
    generation: u64,
    #[prost(string, tag = "4")]
    lease_id: String,
    #[prost(string, tag = "5")]
    network_handle: String,
    #[prost(string, tag = "6")]
    token: String,
}

#[derive(Clone, PartialEq, Message)]
struct FdHandoffResponseV1 {
    #[prost(uint32, tag = "1")]
    protocol_version: u32,
    #[prost(enumeration = "FdHandoffCode", tag = "2")]
    code: i32,
    #[prost(string, tag = "3")]
    message: String,
    #[prost(uint32, tag = "4")]
    fd_count: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
enum FdHandoffCode {
    Unspecified = 0,
    Ok = 1,
    Malformed = 2,
    Unauthorized = 3,
    Stale = 4,
    NotReady = 5,
    Internal = 6,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct RuntimeCleanupRecord {
    endpoint: String,
    sandbox_id: String,
    lease_id: String,
    generation: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct RuntimeLease {
    endpoint: String,
    pub(crate) sandbox: PreparedSandbox,
}

impl RuntimeLease {
    pub(crate) fn shared_root(&self) -> Result<PathBuf, String> {
        let assets = self
            .sandbox
            .assets
            .as_ref()
            .ok_or_else(|| "RuntimeResource lease has no assets".to_string())?;
        canonical_runtime_shared_root(Path::new(&assets.shared_root))
    }

    #[cfg(test)]
    pub(crate) fn test_with_shared_root(shared_root: &str) -> Self {
        Self {
            endpoint: "/run/cubesandbox-test/runtime-resource.sock".to_string(),
            sandbox: PreparedSandbox {
                sandbox_id: "sandbox-test".to_string(),
                lease_id: "lease-test".to_string(),
                generation: 1,
                assets: Some(RuntimeAssets {
                    shared_root: shared_root.to_string(),
                    ..Default::default()
                }),
                ..Default::default()
            },
        }
    }

    fn cleanup_record(&self) -> RuntimeCleanupRecord {
        RuntimeCleanupRecord {
            endpoint: self.endpoint.clone(),
            sandbox_id: self.sandbox.sandbox_id.clone(),
            lease_id: self.sandbox.lease_id.clone(),
            generation: self.sandbox.generation,
        }
    }

    fn persist_cleanup_record_at(&self, path: &Path) -> Result<(), String> {
        let parent = path
            .parent()
            .ok_or_else(|| format!("cleanup record has no parent: {}", path.display()))?;
        if let Some(existing) = load_cleanup_record_at(path)? {
            if existing == self.cleanup_record() {
                return Ok(());
            }
            return Err(format!(
                "refuse to replace mismatched RuntimeResource cleanup record {}",
                path.display()
            ));
        }
        let temp = path.with_extension(format!("tmp-{}", std::process::id()));
        match std::fs::remove_file(&temp) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "remove stale RuntimeResource cleanup temp {}: {error}",
                    temp.display()
                ))
            }
        }
        let data = serde_json::to_vec(&self.cleanup_record())
            .map_err(|error| format!("encode RuntimeResource cleanup record: {error}"))?;
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temp)
            .map_err(|error| {
                format!(
                    "create RuntimeResource cleanup record {}: {error}",
                    temp.display()
                )
            })?;
        if let Err(error) = file.write_all(&data).and_then(|_| file.sync_all()) {
            let _ = std::fs::remove_file(&temp);
            return Err(format!(
                "persist RuntimeResource cleanup record {}: {error}",
                temp.display()
            ));
        }
        if let Err(error) = std::fs::rename(&temp, path) {
            let _ = std::fs::remove_file(&temp);
            return Err(format!(
                "commit RuntimeResource cleanup record {}: {error}",
                path.display()
            ));
        }
        std::fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| {
                format!(
                    "sync RuntimeResource cleanup record parent {}: {error}",
                    parent.display()
                )
            })
    }

    fn persist_cleanup_record(&self) -> Result<(), String> {
        self.persist_cleanup_record_at(&runtime_cleanup_record_path()?)
    }

    fn remove_cleanup_record_at(&self, path: &Path) -> Result<(), String> {
        let Some(record) = load_cleanup_record_at(path)? else {
            return Ok(());
        };
        if record != self.cleanup_record() {
            return Err("RuntimeResource cleanup record identity changed".to_string());
        }
        std::fs::remove_file(path).map_err(|error| {
            format!(
                "remove RuntimeResource cleanup record {}: {error}",
                path.display()
            )
        })?;
        let parent = path.parent().unwrap();
        std::fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| {
                format!(
                    "sync RuntimeResource cleanup removal {}: {error}",
                    parent.display()
                )
            })
    }

    fn remove_cleanup_record(&self) -> Result<(), String> {
        self.remove_cleanup_record_at(&runtime_cleanup_record_path()?)
    }

    pub(crate) async fn acquire_tap(&self) -> Result<std::fs::File, String> {
        preflight_runtime_environment_at(&self.sandbox, Path::new("/dev/kvm"))?;
        let sandbox = self.sandbox.clone();
        tokio::task::spawn_blocking(move || acquire_tap_blocking(&sandbox))
            .await
            .map_err(|error| format!("join TAP handoff: {error}"))?
    }

    pub(crate) async fn release(&self) -> Result<(), String> {
        let mut client = RuntimeResourceClient::connect(&self.endpoint).await?;
        let request = ReleaseSandboxRequest {
            sandbox_id: self.sandbox.sandbox_id.clone(),
            lease_id: self.sandbox.lease_id.clone(),
            generation: self.sandbox.generation,
            idempotency_key: release_key(&self.sandbox),
        };
        let response: ReleaseSandboxResponse = client
            .unary(
                request,
                "/cubelet.services.runtime.v1.RuntimeResource/ReleaseSandbox",
            )
            .await?;
        if !response.released {
            return Err("Cubelet did not confirm RuntimeResource release".to_string());
        }
        self.remove_cleanup_record()?;
        Ok(())
    }
}

fn runtime_cleanup_record_path() -> Result<PathBuf, String> {
    std::env::current_dir()
        .map(|directory| directory.join(RUNTIME_CLEANUP_RECORD))
        .map_err(|error| format!("resolve RuntimeResource cleanup record directory: {error}"))
}

fn load_cleanup_record_at(path: &Path) -> Result<Option<RuntimeCleanupRecord>, String> {
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "read RuntimeResource cleanup record {}: {error}",
                path.display()
            ))
        }
    };
    let record: RuntimeCleanupRecord = serde_json::from_slice(&data).map_err(|error| {
        format!(
            "decode RuntimeResource cleanup record {}: {error}",
            path.display()
        )
    })?;
    if record.endpoint.is_empty()
        || !Path::new(&record.endpoint).is_absolute()
        || record.sandbox_id.is_empty()
        || record.lease_id.is_empty()
        || record.generation == 0
    {
        return Err("RuntimeResource cleanup record has invalid identity".to_string());
    }
    Ok(Some(record))
}

pub(crate) async fn release_persisted() -> Result<(), String> {
    let path = runtime_cleanup_record_path()?;
    let Some(record) = load_cleanup_record_at(&path)? else {
        return Ok(());
    };
    RuntimeLease {
        endpoint: record.endpoint,
        sandbox: PreparedSandbox {
            sandbox_id: record.sandbox_id,
            lease_id: record.lease_id,
            generation: record.generation,
            ..Default::default()
        },
    }
    .release()
    .await
}

pub(crate) async fn release_persisted_until_done() {
    retry_until_success(
        release_persisted,
        Duration::from_millis(100),
        Duration::from_secs(5),
    )
    .await;
}

fn reaper_root() -> Result<PathBuf, String> {
    let root = std::env::var_os(RUNTIME_REAPER_ROOT_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_RUNTIME_REAPER_ROOT));
    if !root.is_absolute() {
        return Err(format!(
            "{RUNTIME_REAPER_ROOT_ENV} must be an absolute path: {}",
            root.display()
        ));
    }
    Ok(root)
}

fn reaper_job_id(record: &RuntimeCleanupRecord) -> Result<String, String> {
    let data = serde_json::to_vec(record)
        .map_err(|error| format!("encode RuntimeResource reaper identity: {error}"))?;
    Ok(format!("{:x}", Sha256::digest(data)))
}

/// Move dead-shim cleanup ownership out of the containerd bundle before the
/// delete action returns. containerd kills delete helpers after a short fixed
/// timeout, so the exact lease is retried by a session-detached reaper whose
/// durable record is not removed with the bundle.
pub(crate) fn handoff_persisted_to_reaper() -> Result<(), String> {
    let source = runtime_cleanup_record_path()?;
    let Some(record) = load_cleanup_record_at(&source)? else {
        return Ok(());
    };
    let root = reaper_root()?;
    let job = reaper_queue::persist_reaper_job_at(&root, &record)?;

    let executable = std::env::current_exe()
        .map_err(|error| format!("resolve RuntimeResource reaper executable: {error}"))?;
    let mut command = Command::new(executable);
    command
        .current_dir(&job)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .args([
            "-namespace",
            "cube-runtime-reaper",
            "-id",
            record.sandbox_id.as_str(),
            RUNTIME_REAPER_ACTION,
        ]);
    // SAFETY: setsid is async-signal-safe and the closure performs no
    // allocation or other work between fork and exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    match command.spawn() {
        Ok(_) => Ok(()),
        Err(error) => {
            if load_cleanup_record_at(&job.join(RUNTIME_CLEANUP_RECORD))?.is_none() {
                return Ok(());
            }
            Err(format!(
                "spawn RuntimeResource reaper for {}: {error}",
                record.sandbox_id
            ))
        }
    }
}

pub(crate) async fn run_persisted_reaper() -> Result<(), String> {
    release_persisted_until_done().await;
    let job = std::env::current_dir()
        .map_err(|error| format!("resolve RuntimeResource reaper job: {error}"))?;
    reaper_queue::remove_reaper_job_directory(&job)
}

async fn retry_until_success<F, Fut>(mut operation: F, initial_delay: Duration, max_delay: Duration)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<(), String>>,
{
    let mut delay = initial_delay;
    loop {
        match operation().await {
            Ok(()) => return,
            Err(error) => {
                eprintln!("retry persisted RuntimeResource release after error: {error}");
                tokio::time::sleep(delay).await;
                delay = std::cmp::min(delay.saturating_mul(2), max_delay);
            }
        }
    }
}

struct RuntimeResourceClient {
    inner: tonic::client::Grpc<Channel>,
}

impl RuntimeResourceClient {
    async fn connect(path: &str) -> Result<Self, String> {
        if !Path::new(path).is_absolute() {
            return Err(format!("RuntimeResource endpoint must be absolute: {path}"));
        }
        let socket = path.to_string();
        let channel = Endpoint::try_from("http://[::]:50051")
            .map_err(|error| format!("create RuntimeResource endpoint: {error}"))?
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(30))
            .connect_with_connector(service_fn(move |_| {
                let socket = socket.clone();
                async move { UnixStream::connect(socket).await.map(TokioIo::new) }
            }))
            .await
            .map_err(|error| format!("connect RuntimeResource {path}: {error}"))?;
        Ok(Self {
            inner: tonic::client::Grpc::new(channel),
        })
    }

    async fn unary<Req, Resp>(&mut self, request: Req, path: &'static str) -> Result<Resp, String>
    where
        Req: Message + Default + Send + Sync + 'static,
        Resp: Message + Default + Send + Sync + 'static,
    {
        self.inner
            .ready()
            .await
            .map_err(|error| format!("RuntimeResource is not ready: {error}"))?;
        let codec = tonic_prost::ProstCodec::default();
        self.inner
            .unary(
                Request::new(request),
                PathAndQuery::from_static(path),
                codec,
            )
            .await
            .map(tonic::Response::into_inner)
            .map_err(status_string)
    }
}

pub(crate) fn decode_cri_config(
    type_url: &str,
    value: &[u8],
) -> Result<CriPodSandboxConfig, String> {
    if type_url != CRI_V1_POD_SANDBOX_CONFIG
        && !type_url.ends_with(&format!("/{CRI_V1_POD_SANDBOX_CONFIG}"))
    {
        return Err(format!("unsupported sandbox options type {type_url}"));
    }
    if value.is_empty() {
        return Err("CRI PodSandboxConfig payload is empty".to_string());
    }
    let config = CriPodSandboxConfig::decode(value)
        .map_err(|error| format!("decode CRI PodSandboxConfig: {error}"))?;
    pod_metadata(&config)?;
    Ok(config)
}

fn hash_fingerprint_part(hasher: &mut Sha256, value: &[u8]) {
    hasher.update((value.len() as u64).to_be_bytes());
    hasher.update(value);
}

pub(crate) fn cri_semantic_fingerprint(config: &CriPodSandboxConfig) -> String {
    let mut hasher = Sha256::new();
    hash_fingerprint_part(&mut hasher, config.hostname.as_bytes());
    if let Some(metadata) = &config.metadata {
        for value in [
            metadata.name.as_bytes(),
            metadata.uid.as_bytes(),
            metadata.namespace.as_bytes(),
            &metadata.attempt.to_be_bytes(),
        ] {
            hash_fingerprint_part(&mut hasher, value);
        }
    } else {
        hash_fingerprint_part(&mut hasher, b"no-metadata");
    }
    if let Some(dns) = &config.dns_config {
        for values in [&dns.servers, &dns.searches, &dns.options] {
            hash_fingerprint_part(&mut hasher, &(values.len() as u64).to_be_bytes());
            for value in values {
                hash_fingerprint_part(&mut hasher, value.as_bytes());
            }
        }
    } else {
        hash_fingerprint_part(&mut hasher, b"no-dns");
    }
    let mut annotations: Vec<_> = config.annotations.iter().collect();
    annotations.sort_by(|left, right| left.0.cmp(right.0));
    for (key, value) in annotations {
        hash_fingerprint_part(&mut hasher, key.as_bytes());
        hash_fingerprint_part(&mut hasher, value.as_bytes());
    }
    if let Some(resources) = config
        .linux
        .as_ref()
        .and_then(|linux| linux.resources.as_ref())
    {
        for value in [
            resources.cpu_period,
            resources.cpu_quota,
            resources.cpu_shares,
            resources.memory_limit_in_bytes,
        ] {
            hash_fingerprint_part(&mut hasher, &value.to_be_bytes());
        }
    } else {
        hash_fingerprint_part(&mut hasher, b"no-linux-resources");
    }
    if let Some(options) = namespace_options(config) {
        for value in [options.network, options.pid, options.ipc] {
            hash_fingerprint_part(&mut hasher, &value.to_be_bytes());
        }
        hash_fingerprint_part(&mut hasher, options.target_id.as_bytes());
    } else {
        hash_fingerprint_part(&mut hasher, b"no-namespace-options");
    }
    format!("{:x}", hasher.finalize())
}

fn namespace_options(config: &CriPodSandboxConfig) -> Option<&CriNamespaceOption> {
    config
        .linux
        .as_ref()
        .and_then(|linux| linux.security_context.as_ref())
        .and_then(|security| security.namespace_options.as_ref())
}

/// Validate the Linux namespace modes carried by CRI before allocating a VM.
///
/// CRI NamespaceMode is POD=0, CONTAINER=1, NODE=2 and TARGET=3. Kubernetes
/// sends PID=CONTAINER for a normal Pod and PID=POD for
/// shareProcessNamespace. Network and IPC can only be POD for the Cube
/// RuntimeClass: NODE would expose host namespace intent which a VM runtime
/// cannot implement faithfully, while CONTAINER/TARGET are not Pod sandbox
/// modes accepted from kubelet.
pub(crate) fn shared_pid_namespace(config: &CriPodSandboxConfig) -> Result<bool, String> {
    let Some(options) = namespace_options(config) else {
        // Preserve the existing Kubernetes path for older callers that omit
        // namespace_options: one network/IPC namespace per Pod and one PID
        // namespace per container.
        return Ok(false);
    };

    match options.network {
        0 => {}
        2 => return Err("hostNetwork is not supported by RuntimeClass cube".to_string()),
        mode => {
            return Err(format!(
                "unsupported CRI network namespace mode {mode}; RuntimeClass cube requires POD"
            ))
        }
    }
    match options.ipc {
        0 => {}
        2 => return Err("hostIPC is not supported by RuntimeClass cube".to_string()),
        mode => {
            return Err(format!(
                "unsupported CRI IPC namespace mode {mode}; RuntimeClass cube requires POD"
            ))
        }
    }
    match options.pid {
        0 => Ok(true),
        1 => Ok(false),
        2 => Err("hostPID is not supported by RuntimeClass cube".to_string()),
        mode => Err(format!(
            "unsupported CRI PID namespace mode {mode}; RuntimeClass cube supports POD or CONTAINER"
        )),
    }
}

pub(crate) fn merge_cri_annotations(
    spec: &mut Spec,
    config: &CriPodSandboxConfig,
    request_annotations: &HashMap<String, String>,
) -> Result<(), String> {
    let metadata = pod_metadata(config)?;
    let shared_pidns = shared_pid_namespace(config)?;
    let mut annotations = spec.annotations().as_ref().cloned().unwrap_or_default();
    annotations.extend(config.annotations.clone());
    annotations.extend(request_annotations.clone());
    annotations.insert(ANNO_SANDBOX_UID.to_string(), metadata.uid.clone());
    annotations.insert(
        ANNO_SANDBOX_NAMESPACE.to_string(),
        metadata.namespace.clone(),
    );
    annotations.insert(ANNO_SANDBOX_NAME.to_string(), metadata.name.clone());
    annotations.insert(
        ANNO_SANDBOX_HOSTNAME.to_string(),
        if config.hostname.trim().is_empty() {
            metadata.name.clone()
        } else {
            config.hostname.clone()
        },
    );
    annotations.insert(ANNO_SANDBOX_PIDNS.to_string(), shared_pidns.to_string());
    if config.dns_config.is_some() {
        let dns = cri_dns_entries(config.dns_config.as_ref())?;
        annotations.insert(
            ANNO_SANDBOX_DNS.to_string(),
            serde_json::to_string(&dns).map_err(|error| format!("encode CRI DNS: {error}"))?,
        );
    }
    spec.set_annotations(Some(annotations));
    Ok(())
}

fn cri_dns_entries(config: Option<&CriDnsConfig>) -> Result<Vec<String>, String> {
    let Some(config) = config else {
        return Ok(Vec::new());
    };
    let mut entries = Vec::new();
    for server in &config.servers {
        let server = server.trim();
        server
            .parse::<std::net::IpAddr>()
            .map_err(|_| format!("invalid CRI DNS server {server}"))?;
        entries.push(format!("nameserver {server}"));
    }
    let searches: Vec<&str> = config
        .searches
        .iter()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .collect();
    if !searches.is_empty() {
        entries.push(format!("search {}", searches.join(" ")));
    }
    let options: Vec<&str> = config
        .options
        .iter()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .collect();
    if !options.is_empty() {
        entries.push(format!("options {}", options.join(" ")));
    }
    Ok(entries)
}

pub(crate) async fn prepare(
    sandbox_id: &str,
    netns_path: &str,
    config: &CriPodSandboxConfig,
    spec: &mut Spec,
) -> Result<RuntimeLease, String> {
    let endpoint = std::env::var("CUBE_RUNTIME_RESOURCE_ENDPOINT")
        .unwrap_or_else(|_| DEFAULT_ENDPOINT.to_string());
    let mut client = RuntimeResourceClient::connect(&endpoint).await?;
    let capabilities: GetCapabilitiesResponse = client
        .unary(
            GetCapabilitiesRequest {
                client_api_version: API_VERSION,
            },
            "/cubelet.services.runtime.v1.RuntimeResource/GetCapabilities",
        )
        .await?;
    validate_capabilities(&capabilities)?;

    let metadata = pod_metadata(config)?;
    let annotations = spec.annotations().as_ref().cloned().unwrap_or_default();
    let resources = resources_from_config(&annotations, config)?;
    let generation = u64::from(metadata.attempt) + 1;
    let dns = cri_dns_entries(config.dns_config.as_ref())?;
    let idempotency_key = prepare_key(sandbox_id, generation);
    let expected_lease_id = lease_id_for_prepare(sandbox_id, generation, &idempotency_key);
    let cleanup_lease = RuntimeLease {
        endpoint: endpoint.clone(),
        sandbox: PreparedSandbox {
            sandbox_id: sandbox_id.to_string(),
            lease_id: expected_lease_id.clone(),
            generation,
            ..Default::default()
        },
    };
    cleanup_lease.persist_cleanup_record().map_err(|error| {
        format!("persist RuntimeResource cleanup identity before Prepare: {error}")
    })?;
    let request = PrepareSandboxRequest {
        sandbox_id: sandbox_id.to_string(),
        idempotency_key,
        generation,
        pod: Some(PodIdentity {
            uid: metadata.uid.clone(),
            namespace: metadata.namespace.clone(),
            name: metadata.name.clone(),
            attempt: metadata.attempt,
        }),
        resources: Some(resources.clone()),
        network: Some(NetworkIntent {
            netns_path: netns_path.to_string(),
            interface_name: "eth0".to_string(),
            pod_ip: String::new(),
            dns,
        }),
    };
    let response: PrepareSandboxResponse = match client
        .unary(
            request,
            "/cubelet.services.runtime.v1.RuntimeResource/PrepareSandbox",
        )
        .await
    {
        Ok(response) => response,
        Err(error) => return Err(release_after_prepare_error(&cleanup_lease, error).await),
    };
    let mut sandbox = match response.sandbox {
        Some(sandbox) => sandbox,
        None => {
            return Err(release_after_prepare_error(
                &cleanup_lease,
                "Cubelet returned no prepared sandbox".to_string(),
            )
            .await)
        }
    };
    let shared_root = match validate_prepared(sandbox_id, generation, &expected_lease_id, &sandbox)
    {
        Ok(shared_root) => shared_root,
        Err(error) => return Err(release_after_prepare_error(&cleanup_lease, error).await),
    };
    // From this point on both the virtiofs annotation and Task rootfs bridge
    // use the canonical path that was validated as a strict /data/cubelet
    // descendant. Do not retain a server-supplied symlink spelling.
    sandbox.assets.as_mut().unwrap().shared_root = shared_root.display().to_string();
    if let Err(error) = inject_annotations(spec, &resources, &sandbox) {
        return Err(release_after_prepare_error(&cleanup_lease, error).await);
    }
    Ok(RuntimeLease { endpoint, sandbox })
}

async fn release_after_prepare_error(lease: &RuntimeLease, error: String) -> String {
    match lease.release().await {
        Ok(()) => error,
        Err(release_error) => {
            format!("{error}; release RuntimeResource: {release_error}")
        }
    }
}

fn preflight_runtime_environment_at(
    sandbox: &PreparedSandbox,
    kvm_path: &Path,
) -> Result<(), String> {
    let assets = sandbox
        .assets
        .as_ref()
        .ok_or_else(|| "Cubelet returned no runtime assets".to_string())?;
    for (name, path) in [
        ("kernel", assets.kernel_path.as_str()),
        ("agent", assets.agent_path.as_str()),
        ("guest image", assets.guest_image_path.as_str()),
    ] {
        let path = Path::new(path);
        if !path.is_absolute() {
            return Err(format!(
                "RuntimeResource {name} path must be absolute: {}",
                path.display()
            ));
        }
        let metadata = path
            .metadata()
            .map_err(|error| format!("stat RuntimeResource {name} {}: {error}", path.display()))?;
        if !metadata.is_file() {
            return Err(format!(
                "RuntimeResource {name} is not a file: {}",
                path.display()
            ));
        }
    }
    let shared_root = Path::new(&assets.shared_root);
    let metadata = shared_root.metadata().map_err(|error| {
        format!(
            "stat RuntimeResource shared root {}: {error}",
            shared_root.display()
        )
    })?;
    if !metadata.is_dir() {
        return Err(format!(
            "RuntimeResource shared root is not a directory: {}",
            shared_root.display()
        ));
    }
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(kvm_path)
        .map_err(|error| format!("open KVM device {}: {error}", kvm_path.display()))?;
    Ok(())
}

fn pod_metadata(config: &CriPodSandboxConfig) -> Result<&CriPodSandboxMetadata, String> {
    let metadata = config
        .metadata
        .as_ref()
        .ok_or_else(|| "CRI PodSandboxConfig metadata is missing".to_string())?;
    if metadata.uid.trim().is_empty()
        || metadata.namespace.trim().is_empty()
        || metadata.name.trim().is_empty()
    {
        return Err("CRI PodSandboxConfig identity fields must be non-empty".to_string());
    }
    Ok(metadata)
}

fn validate_capabilities(response: &GetCapabilitiesResponse) -> Result<(), String> {
    if response.api_version != API_VERSION || response.service_mode != SERVICE_MODE {
        return Err(format!(
            "unsupported RuntimeResource api={} mode={}",
            response.api_version, response.service_mode
        ));
    }
    let versions: HashMap<&str, u32> = response
        .capabilities
        .iter()
        .map(|capability| (capability.name.as_str(), capability.version))
        .collect();
    for (name, minimum) in REQUIRED_CAPABILITIES {
        if versions.get(name).copied().unwrap_or_default() < minimum {
            return Err(format!("RuntimeResource lacks {name}>={minimum}"));
        }
    }
    if !Path::new(&response.fd_handoff_endpoint).is_absolute() {
        return Err("RuntimeResource returned a non-absolute FD endpoint".to_string());
    }
    Ok(())
}

fn validate_prepared(
    sandbox_id: &str,
    generation: u64,
    expected_lease_id: &str,
    sandbox: &PreparedSandbox,
) -> Result<PathBuf, String> {
    if sandbox.sandbox_id != sandbox_id
        || sandbox.generation != generation
        || sandbox.lease_id != expected_lease_id
    {
        return Err("Cubelet returned mismatched prepared sandbox identity".to_string());
    }
    let assets = sandbox
        .assets
        .as_ref()
        .ok_or_else(|| "Cubelet returned no runtime assets".to_string())?;
    let network = sandbox
        .network
        .as_ref()
        .ok_or_else(|| "Cubelet returned no network attachment".to_string())?;
    let descriptor = network
        .fd_handoff
        .as_ref()
        .ok_or_else(|| "Cubelet returned no FD handoff descriptor".to_string())?;
    if assets.kernel_path.is_empty()
        || assets.agent_path.is_empty()
        || assets.guest_image_path.is_empty()
        || assets.shared_root.is_empty()
        || network.network_handle.is_empty()
        || network.tap_name.is_empty()
        || network.mac.is_empty()
        || network.mtu == 0
        || network.ips.is_empty()
        || descriptor.protocol_version != FD_PROTOCOL_VERSION
        || descriptor.token.is_empty()
        || !Path::new(&descriptor.endpoint).is_absolute()
    {
        return Err("Cubelet returned incomplete RuntimeResource data".to_string());
    }
    canonical_runtime_shared_root(Path::new(&assets.shared_root))
}

/// Resolve a server-provided virtiofs export without permitting lexical or
/// symlink traversal outside Cubelet's owned directory. The base directory
/// itself is deliberately not a valid per-Sandbox export.
pub(crate) fn canonical_runtime_shared_root(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::RootDir | Component::Normal(_)))
    {
        return Err(format!(
            "RuntimeResource shared root must be an absolute normalized path below {VIRTIOFS_SHARED_DIR}: {}",
            path.display()
        ));
    }

    let base = std::fs::canonicalize(VIRTIOFS_SHARED_DIR).map_err(|error| {
        format!("canonicalize RuntimeResource shared root base {VIRTIOFS_SHARED_DIR}: {error}")
    })?;
    let canonical = std::fs::canonicalize(path).map_err(|error| {
        format!(
            "canonicalize RuntimeResource shared root {}: {error}",
            path.display()
        )
    })?;
    let metadata = canonical.metadata().map_err(|error| {
        format!(
            "stat RuntimeResource shared root {}: {error}",
            canonical.display()
        )
    })?;
    if !metadata.is_dir() {
        return Err(format!(
            "RuntimeResource shared root is not a directory: {}",
            canonical.display()
        ));
    }
    if canonical == base || !canonical.starts_with(&base) {
        return Err(format!(
            "RuntimeResource shared root {} is not a strict descendant of {}",
            canonical.display(),
            base.display()
        ));
    }
    Ok(canonical)
}

fn inject_annotations(
    spec: &mut Spec,
    resources: &ResourceRequest,
    sandbox: &PreparedSandbox,
) -> Result<(), String> {
    let assets = sandbox.assets.as_ref().unwrap();
    let network = sandbox.network.as_ref().unwrap();
    let mut annotations = spec.annotations().as_ref().cloned().unwrap_or_default();
    annotations.insert(
        ANNO_VM_RES.to_string(),
        serde_json::json!({
            "cpu": resources.vcpu_count,
            "memory": resources.memory_bytes.div_ceil(1024 * 1024),
        })
        .to_string(),
    );
    annotations.insert(ANNO_VM_KERNEL.to_string(), assets.kernel_path.clone());
    annotations.insert(ANNO_VM_AGENT.to_string(), assets.agent_path.clone());
    annotations.insert(
        ANNO_VM_OS_IMAGE.to_string(),
        assets.guest_image_path.clone(),
    );
    annotations.insert(
        ANNO_VMM_FS.to_string(),
        serde_json::json!({
            "backendfs_config": {
                "shared_dir": VIRTIOFS_SHARED_DIR,
                "allowed_dirs": [assets.shared_root],
                "announce_submounts": false,
                "cache": 2,
                "read_only": true,
            }
        })
        .to_string(),
    );
    annotations.insert(ANNO_NET.to_string(), network_json(network)?);
    annotations.insert(ANNO_SNAPSHOT_DISABLE.to_string(), "true".to_string());
    annotations.insert(ANNO_USE_PASSFD_IO.to_string(), "true".to_string());
    spec.set_annotations(Some(annotations));
    Ok(())
}

#[derive(Serialize)]
struct NetConfig<'a> {
    interfaces: Vec<NetInterface<'a>>,
    routes: Vec<NetRoute<'a>>,
    arps: Vec<Arp<'a>>,
}

#[derive(Serialize)]
struct NetInterface<'a> {
    name: &'a str,
    guest_name: &'a str,
    mac: &'a str,
    mtu: u32,
    ip: &'a str,
    family: u32,
    mask: u32,
    ips: Vec<NetIp<'a>>,
    qos: Option<()>,
}

#[derive(Serialize)]
struct NetIp<'a> {
    ip: &'a str,
    family: u32,
    mask: u32,
}

#[derive(Serialize)]
struct NetRoute<'a> {
    family: u32,
    dest: &'a str,
    gateway: &'a str,
    source: &'a str,
    device: &'a str,
    scope: u32,
    onlink: bool,
}

#[derive(Serialize)]
struct Arp<'a> {
    dest_ip: &'a str,
    device: &'a str,
    ll_addr: &'a str,
    state: u32,
    flags: u32,
    family: u32,
}

fn ip_family(address: &str) -> Result<u32, String> {
    let address = address.split_once('/').map_or(address, |(ip, _)| ip);
    match address.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(_)) => Ok(0),
        Ok(std::net::IpAddr::V6(_)) => Ok(1),
        Err(error) => Err(format!(
            "RuntimeResource returned invalid IP {address}: {error}"
        )),
    }
}

fn network_json(network: &NetworkAttachment) -> Result<String, String> {
    let mut ips = Vec::with_capacity(network.ips.len());
    for address in &network.ips {
        let (ip, mask) = address
            .split_once('/')
            .ok_or_else(|| format!("RuntimeResource returned invalid CIDR {address}"))?;
        ips.push(NetIp {
            ip,
            family: ip_family(ip)?,
            mask: mask
                .parse()
                .map_err(|error| format!("parse CIDR {address}: {error}"))?,
        });
    }
    let config = NetConfig {
        interfaces: vec![NetInterface {
            name: &network.tap_name,
            guest_name: &network.guest_interface_name,
            mac: &network.mac,
            mtu: network.mtu,
            ip: "",
            family: 0,
            mask: 0,
            ips,
            qos: None,
        }],
        routes: network
            .routes
            .iter()
            .map(|route| {
                let family_source = [&route.destination, &route.gateway, &route.source]
                    .into_iter()
                    .find(|value| !value.is_empty())
                    .ok_or_else(|| {
                        "RuntimeResource returned route without an address".to_string()
                    })?;
                Ok(NetRoute {
                    family: ip_family(family_source)?,
                    dest: &route.destination,
                    gateway: &route.gateway,
                    source: &route.source,
                    device: &route.device,
                    scope: route.scope,
                    onlink: false,
                })
            })
            .collect::<Result<Vec<_>, String>>()?,
        arps: network
            .neighbors
            .iter()
            .map(|neighbor| {
                Ok(Arp {
                    dest_ip: &neighbor.ip,
                    device: &neighbor.device,
                    ll_addr: &neighbor.mac,
                    state: 128,
                    flags: 0,
                    family: ip_family(&neighbor.ip)?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?,
    };
    serde_json::to_string(&config).map_err(|error| format!("serialize Cube network: {error}"))
}

fn cmsg_align(length: usize) -> usize {
    let alignment = std::mem::size_of::<usize>();
    (length + alignment - 1) & !(alignment - 1)
}

fn visible_scm_rights(control: &[u8]) -> Vec<RawFd> {
    let header_size = std::mem::size_of::<libc::cmsghdr>();
    let data_offset = cmsg_align(header_size);
    let mut descriptors = Vec::new();
    let mut offset = 0;
    while control.len().saturating_sub(offset) >= header_size {
        // recvmsg initialized this aligned control buffer. read_unaligned also
        // keeps this parser correct if a future allocator changes alignment.
        let header = unsafe {
            std::ptr::read_unaligned(control.as_ptr().add(offset).cast::<libc::cmsghdr>())
        };
        let message_len = header.cmsg_len as usize;
        if message_len < data_offset {
            break;
        }
        let available_end = std::cmp::min(offset.saturating_add(message_len), control.len());
        let data_start = offset + data_offset;
        if header.cmsg_level == libc::SOL_SOCKET && header.cmsg_type == libc::SCM_RIGHTS {
            for chunk in
                control[data_start..available_end].chunks_exact(std::mem::size_of::<RawFd>())
            {
                let descriptor = i32::from_ne_bytes(chunk.try_into().unwrap());
                if descriptor >= 0 {
                    descriptors.push(descriptor);
                }
            }
        }
        if offset.saturating_add(message_len) > control.len() {
            break;
        }
        offset = offset.saturating_add(cmsg_align(message_len));
    }
    descriptors
}

fn acquire_tap_blocking(sandbox: &PreparedSandbox) -> Result<std::fs::File, String> {
    let network = sandbox.network.as_ref().unwrap();
    let descriptor = network.fd_handoff.as_ref().unwrap();
    let request = FdHandoffRequestV1 {
        protocol_version: FD_PROTOCOL_VERSION,
        sandbox_id: sandbox.sandbox_id.clone(),
        generation: sandbox.generation,
        lease_id: sandbox.lease_id.clone(),
        network_handle: network.network_handle.clone(),
        token: descriptor.token.clone(),
    };
    let payload = request.encode_to_vec();
    if payload.is_empty() || payload.len() > 64 * 1024 {
        return Err("invalid FD handoff request frame size".to_string());
    }
    let mut stream = StdUnixStream::connect(&descriptor.endpoint)
        .map_err(|error| format!("connect FD handoff {}: {error}", descriptor.endpoint))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|error| format!("set FD handoff timeout: {error}"))?;
    stream
        .write_all(&(payload.len() as u32).to_be_bytes())
        .and_then(|_| stream.write_all(&payload))
        .map_err(|error| format!("write FD handoff request: {error}"))?;

    let mut header = [0_u8; 4];
    let mut iov = [IoSliceMut::new(&mut header)];
    let mut control = cmsg_space!([RawFd; 1]);
    control.resize(control.capacity(), 0);
    let (received, truncated) = {
        let message = recvmsg::<()>(
            stream.as_raw_fd(),
            &mut iov,
            Some(&mut control),
            MsgFlags::MSG_CMSG_CLOEXEC,
        )
        .map_err(|error| format!("receive FD handoff response: {error}"))?;
        (message.bytes, message.flags.contains(MsgFlags::MSG_CTRUNC))
    };
    let descriptors = visible_scm_rights(&control);
    drop(iov);
    if truncated {
        close_raw_fds(&descriptors);
        return Err("truncated FD handoff control message".to_string());
    }
    if received == 0 {
        close_raw_fds(&descriptors);
        return Err("empty FD handoff response header".to_string());
    }
    if received < header.len() {
        if let Err(error) = stream.read_exact(&mut header[received..]) {
            close_raw_fds(&descriptors);
            return Err(format!(
                "read remaining FD handoff response header: {error}"
            ));
        }
    }
    let size = u32::from_be_bytes(header) as usize;
    if size == 0 || size > 64 * 1024 {
        close_raw_fds(&descriptors);
        return Err(format!("invalid FD handoff response size {size}"));
    }
    let mut payload = vec![0_u8; size];
    if let Err(error) = stream.read_exact(&mut payload) {
        close_raw_fds(&descriptors);
        return Err(format!("read FD handoff response: {error}"));
    }
    let response = FdHandoffResponseV1::decode(payload.as_slice()).map_err(|error| {
        close_raw_fds(&descriptors);
        format!("decode FD handoff response: {error}")
    })?;
    if response.protocol_version != FD_PROTOCOL_VERSION
        || response.code != FdHandoffCode::Ok as i32
        || response.fd_count != 1
        || descriptors.len() != 1
    {
        close_raw_fds(&descriptors);
        return Err(format!(
            "FD handoff rejected: code={} count={} message={}",
            response.code, response.fd_count, response.message
        ));
    }
    // SAFETY: SCM_RIGHTS returned a new descriptor and ownership transfers to File.
    Ok(unsafe { std::fs::File::from_raw_fd(descriptors[0]) })
}

fn close_raw_fds(descriptors: &[RawFd]) {
    for descriptor in descriptors {
        let _ = nix::unistd::close(*descriptor);
    }
}

fn resources_from_config(
    annotations: &HashMap<String, String>,
    config: &CriPodSandboxConfig,
) -> Result<ResourceRequest, String> {
    #[derive(serde::Deserialize)]
    struct VmResource {
        cpu: Option<u32>,
        memory: Option<u64>,
    }
    let configured = annotations
        .get(ANNO_VM_RES)
        .map(|value| serde_json::from_str::<VmResource>(value))
        .transpose()
        .map_err(|error| format!("parse {ANNO_VM_RES}: {error}"))?;
    let aggregate = config
        .linux
        .as_ref()
        .and_then(|linux| linux.resources.as_ref());

    let inferred_cpu = aggregate
        .and_then(|resources| {
            if resources.cpu_quota > 0 && resources.cpu_period > 0 {
                Some(
                    resources.cpu_quota / resources.cpu_period
                        + i64::from(resources.cpu_quota % resources.cpu_period != 0),
                )
            } else if resources.cpu_shares > 0 {
                Some(resources.cpu_shares / 1024 + i64::from(resources.cpu_shares % 1024 != 0))
            } else {
                None
            }
        })
        .unwrap_or(1);
    let cpu = match configured.as_ref().and_then(|value| value.cpu) {
        Some(cpu) => cpu,
        None => u32::try_from(inferred_cpu)
            .map_err(|_| format!("CRI aggregate CPU {inferred_cpu} exceeds u32"))?,
    };

    let inferred_memory = aggregate
        .map(|resources| resources.memory_limit_in_bytes)
        .filter(|memory| *memory > 0)
        .map(|memory| memory as u64)
        .unwrap_or(256 * 1024 * 1024);
    let memory_bytes = match configured.as_ref().and_then(|value| value.memory) {
        Some(memory_mib) => memory_mib
            .checked_mul(1024 * 1024)
            .ok_or_else(|| "Cube VM memory annotation overflows bytes".to_string())?,
        None => inferred_memory,
    };
    if cpu == 0 || memory_bytes == 0 {
        return Err("Cube VM CPU and memory must be non-zero".to_string());
    }
    Ok(ResourceRequest {
        vcpu_count: cpu,
        memory_bytes,
    })
}

fn lease_id_for_prepare(sandbox_id: &str, generation: u64, idempotency_key: &str) -> String {
    let generation = generation.to_string();
    let mut hasher = Sha256::new();
    for value in [
        "cube-runtime-resource-lease-v1".as_bytes(),
        sandbox_id.as_bytes(),
        generation.as_bytes(),
        idempotency_key.as_bytes(),
    ] {
        hash_fingerprint_part(&mut hasher, value);
    }
    format!("{:x}", hasher.finalize())
}

fn prepare_key(sandbox_id: &str, generation: u64) -> String {
    digest(format!("cube-runtime-prepare-v1:{sandbox_id}:{generation}"))
}

fn release_key(sandbox: &PreparedSandbox) -> String {
    digest(format!(
        "cube-runtime-release-v1:{}:{}:{}",
        sandbox.sandbox_id, sandbox.generation, sandbox.lease_id
    ))
}

fn digest(value: String) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn status_string(status: Status) -> String {
    format!("RuntimeResource {}: {}", status.code(), status.message())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn sample_network() -> NetworkAttachment {
        NetworkAttachment {
            tap_name: "cb123".to_string(),
            guest_interface_name: "eth0".to_string(),
            mac: "02:00:00:00:00:01".to_string(),
            mtu: 1450,
            ips: vec!["10.0.0.2/24".to_string()],
            routes: vec![Route {
                destination: "0.0.0.0/0".to_string(),
                gateway: "10.0.0.1".to_string(),
                source: "10.0.0.2".to_string(),
                device: "eth0".to_string(),
                scope: 0,
            }],
            neighbors: vec![Neighbor {
                ip: "10.0.0.1".to_string(),
                mac: "02:00:00:00:00:02".to_string(),
                device: "eth0".to_string(),
            }],
            ..Default::default()
        }
    }

    #[test]
    fn network_attachment_maps_to_legacy_agent_contract() {
        let json = network_json(&sample_network()).unwrap();
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["interfaces"][0]["name"], "cb123");
        assert_eq!(value["interfaces"][0]["ips"][0]["mask"], 24);
        assert_eq!(value["routes"][0]["dest"], "0.0.0.0/0");
        assert_eq!(value["routes"][0]["family"], 0);
        assert_eq!(value["arps"][0]["state"], 128);
        assert_eq!(value["arps"][0]["family"], 0);
    }

    #[test]
    fn network_attachment_derives_ipv6_family() {
        let mut network = sample_network();
        network.ips = vec!["2001:db8::2/64".to_string()];
        network.routes[0].destination = "::/0".to_string();
        network.routes[0].gateway = "2001:db8::1".to_string();
        network.routes[0].source = "2001:db8::2".to_string();
        network.neighbors[0].ip = "2001:db8::1".to_string();
        let value: serde_json::Value =
            serde_json::from_str(&network_json(&network).unwrap()).unwrap();
        assert_eq!(value["interfaces"][0]["ips"][0]["family"], 1);
        assert_eq!(value["routes"][0]["family"], 1);
        assert_eq!(value["arps"][0]["family"], 1);
    }

    #[test]
    fn network_attachment_rejects_invalid_ip() {
        let mut network = sample_network();
        network.ips = vec!["not-an-ip/24".to_string()];
        assert!(network_json(&network).unwrap_err().contains("invalid IP"));
    }

    #[test]
    fn runtime_preflight_checks_assets_shared_root_and_kvm() {
        let root =
            std::env::temp_dir().join(format!("cube-runtime-preflight-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join("shared")).unwrap();
        for name in ["kernel", "agent", "guest.img", "kvm"] {
            std::fs::write(root.join(name), b"test").unwrap();
        }
        let sandbox = PreparedSandbox {
            assets: Some(RuntimeAssets {
                kernel_path: root.join("kernel").display().to_string(),
                agent_path: root.join("agent").display().to_string(),
                guest_image_path: root.join("guest.img").display().to_string(),
                shared_root: root.join("shared").display().to_string(),
            }),
            ..Default::default()
        };
        preflight_runtime_environment_at(&sandbox, &root.join("kvm")).unwrap();
        std::fs::remove_file(root.join("kernel")).unwrap();
        assert!(
            preflight_runtime_environment_at(&sandbox, &root.join("kvm"))
                .unwrap_err()
                .contains("stat RuntimeResource kernel")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn runtime_shared_root_requires_normalized_strict_descendant() {
        let root = PathBuf::from(format!(
            "/data/cubelet/runtime-shared-root-test-{}",
            uuid::Uuid::new_v4()
        ));
        let valid = root.join("valid");
        std::fs::create_dir_all(&valid).unwrap();

        assert_eq!(
            canonical_runtime_shared_root(&valid).unwrap(),
            valid.canonicalize().unwrap()
        );
        assert!(canonical_runtime_shared_root(Path::new("/data/cubelet")).is_err());
        assert!(canonical_runtime_shared_root(Path::new(
            "/data/cubelet/../cubelet/runtime-shared-root-test"
        ))
        .is_err());

        let outside = std::env::temp_dir().join(format!(
            "runtime-shared-root-outside-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&outside).unwrap();
        let escape = root.join("escape");
        symlink(&outside, &escape).unwrap();
        assert!(canonical_runtime_shared_root(&escape).is_err());

        std::fs::remove_dir_all(&root).unwrap();
        std::fs::remove_dir_all(&outside).unwrap();
    }

    fn handoff_sandbox(endpoint: String) -> PreparedSandbox {
        PreparedSandbox {
            sandbox_id: "sandbox-fd".to_string(),
            lease_id: "lease-fd".to_string(),
            generation: 1,
            network: Some(NetworkAttachment {
                network_handle: "network-fd".to_string(),
                fd_handoff: Some(FdHandoffDescriptor {
                    protocol_version: FD_PROTOCOL_VERSION,
                    endpoint,
                    token: "token-fd".to_string(),
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn spawn_handoff_server(
        listener: std::os::unix::net::UnixListener,
        fragment_header: bool,
        descriptor_count: usize,
        descriptor_root: Option<PathBuf>,
    ) -> std::thread::JoinHandle<()> {
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request_size = [0_u8; 4];
            stream.read_exact(&mut request_size).unwrap();
            let mut request = vec![0_u8; u32::from_be_bytes(request_size) as usize];
            stream.read_exact(&mut request).unwrap();
            FdHandoffRequestV1::decode(request.as_slice()).unwrap();

            let response = FdHandoffResponseV1 {
                protocol_version: FD_PROTOCOL_VERSION,
                code: FdHandoffCode::Ok as i32,
                message: "ok".to_string(),
                fd_count: 1,
            }
            .encode_to_vec();
            let header = (response.len() as u32).to_be_bytes();
            let files: Vec<_> = (0..descriptor_count)
                .map(|index| match &descriptor_root {
                    Some(root) => {
                        let path = root.join(format!("sent-fd-{index}"));
                        std::fs::write(&path, b"fd").unwrap();
                        std::fs::File::open(path).unwrap()
                    }
                    None => std::fs::File::open("/dev/null").unwrap(),
                })
                .collect();
            let rights: Vec<_> = files.iter().map(|file| file.as_raw_fd()).collect();
            let header_bytes = if fragment_header {
                &header[..1]
            } else {
                &header[..]
            };
            let iov = [std::io::IoSlice::new(header_bytes)];
            nix::sys::socket::sendmsg::<()>(
                stream.as_raw_fd(),
                &iov,
                &[nix::sys::socket::ControlMessage::ScmRights(&rights)],
                MsgFlags::empty(),
                None,
            )
            .unwrap();
            if fragment_header {
                stream.write_all(&header[1..]).unwrap();
            }
            stream.write_all(&response).unwrap();
        })
    }

    #[test]
    fn fd_handoff_accepts_fragmented_stream_header_with_scm_rights() {
        let root = std::env::temp_dir().join(format!("cube-runtime-fd-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let socket = root.join("handoff.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let server = spawn_handoff_server(listener, true, 1, None);
        let file = acquire_tap_blocking(&handoff_sandbox(socket.display().to_string())).unwrap();
        assert!(file.metadata().is_ok());
        drop(file);
        server.join().unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn fd_handoff_rejects_truncated_control_message() {
        let root =
            std::env::temp_dir().join(format!("cube-runtime-fd-trunc-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let socket = root.join("handoff.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let descriptor_root = root.join("descriptors");
        std::fs::create_dir_all(&descriptor_root).unwrap();
        let server = spawn_handoff_server(listener, false, 8, Some(descriptor_root.clone()));
        let error =
            acquire_tap_blocking(&handoff_sandbox(socket.display().to_string())).unwrap_err();
        assert!(
            error.contains("truncated FD handoff control message"),
            "{error}"
        );
        server.join().unwrap();
        let leaked = std::fs::read_dir("/proc/self/fd")
            .unwrap()
            .filter_map(Result::ok)
            .filter_map(|entry| std::fs::read_link(entry.path()).ok())
            .filter(|target| target.starts_with(&descriptor_root))
            .collect::<Vec<_>>();
        assert!(leaked.is_empty(), "truncated SCM_RIGHTS leaked {leaked:?}");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn persisted_release_retries_until_cubelet_recovers() {
        let attempts = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let observed = attempts.clone();
        retry_until_success(
            move || {
                let attempts = attempts.clone();
                async move {
                    if attempts.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < 2 {
                        Err("Cubelet unavailable".to_string())
                    } else {
                        Ok(())
                    }
                }
            },
            Duration::from_millis(1),
            Duration::from_millis(2),
        )
        .await;
        assert_eq!(observed.load(std::sync::atomic::Ordering::SeqCst), 3);
    }

    #[test]
    fn cleanup_record_is_durable_and_exact_lease_scoped() {
        let root = std::env::temp_dir().join(format!(
            "cube-runtime-cleanup-record-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join(RUNTIME_CLEANUP_RECORD);
        let lease = RuntimeLease {
            endpoint: "/run/cubelet/runtime.sock".to_string(),
            sandbox: PreparedSandbox {
                sandbox_id: "sandbox-a".to_string(),
                lease_id: "lease-a".to_string(),
                generation: 3,
                ..Default::default()
            },
        };
        lease.persist_cleanup_record_at(&path).unwrap();
        assert_eq!(
            load_cleanup_record_at(&path).unwrap(),
            Some(lease.cleanup_record())
        );

        let mut stale = lease.clone();
        stale.sandbox.lease_id = "stale".to_string();
        lease.persist_cleanup_record_at(&path).unwrap();
        assert!(stale
            .persist_cleanup_record_at(&path)
            .unwrap_err()
            .contains("refuse to replace mismatched"));
        assert_eq!(
            reaper_job_id(&lease.cleanup_record()).unwrap(),
            "6360089b3563afc1bf4bfc9295655f16b89c3219fed1fd26fec9c1755e1b0f1a"
        );
        assert!(stale
            .remove_cleanup_record_at(&path)
            .unwrap_err()
            .contains("identity changed"));
        assert!(path.is_file());
        lease.remove_cleanup_record_at(&path).unwrap();
        assert_eq!(load_cleanup_record_at(&path).unwrap(), None);
        let retry_path = root.join("retry.json");
        let retry_temp = retry_path.with_extension(format!("tmp-{}", std::process::id()));
        std::fs::write(&retry_temp, b"incomplete").unwrap();
        lease.persist_cleanup_record_at(&retry_path).unwrap();
        assert_eq!(
            load_cleanup_record_at(&retry_path).unwrap(),
            Some(lease.cleanup_record())
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn retry_keys_are_stable_and_operation_scoped() {
        let sandbox = PreparedSandbox {
            sandbox_id: "sandbox-a".to_string(),
            lease_id: "lease-a".to_string(),
            generation: 1,
            ..Default::default()
        };
        assert_eq!(prepare_key("sandbox-a", 1), prepare_key("sandbox-a", 1));
        assert_eq!(
            lease_id_for_prepare("sandbox-a", 1, &prepare_key("sandbox-a", 1)),
            "98f6f3bda4b778a3c2667ad283522c898878638fee09660857c500ff1b3060b8"
        );
        assert_eq!(release_key(&sandbox), release_key(&sandbox));
        assert_ne!(prepare_key("sandbox-a", 1), release_key(&sandbox));
    }

    fn sample_cri() -> CriPodSandboxConfig {
        CriPodSandboxConfig {
            metadata: Some(CriPodSandboxMetadata {
                name: "pod-a".to_string(),
                uid: "uid-a".to_string(),
                namespace: "ns-a".to_string(),
                attempt: 2,
            }),
            dns_config: Some(CriDnsConfig {
                servers: vec!["10.96.0.10".to_string()],
                searches: vec!["ns-a.svc.cluster.local".to_string()],
                options: vec!["ndots:5".to_string()],
            }),
            annotations: HashMap::from([("pod.example/key".to_string(), "value".to_string())]),
            hostname: "pod-hostname".to_string(),
            linux: Some(CriLinuxPodSandboxConfig {
                security_context: Some(CriLinuxSandboxSecurityContext {
                    namespace_options: Some(CriNamespaceOption {
                        network: 0,
                        pid: 1,
                        ipc: 0,
                        target_id: String::new(),
                    }),
                }),
                resources: Some(CriLinuxContainerResources {
                    cpu_period: 100_000,
                    cpu_quota: 150_000,
                    cpu_shares: 0,
                    memory_limit_in_bytes: 768 * 1024 * 1024,
                }),
            }),
        }
    }

    #[test]
    fn cri_v1_options_decode_preserves_required_pod_fields() {
        let expected = sample_cri();
        let decoded = decode_cri_config(
            CRI_V1_POD_SANDBOX_CONFIG,
            expected.encode_to_vec().as_slice(),
        )
        .unwrap();
        let metadata = pod_metadata(&decoded).unwrap();
        assert_eq!(metadata.uid, "uid-a");
        assert_eq!(metadata.namespace, "ns-a");
        assert_eq!(metadata.name, "pod-a");
        assert_eq!(metadata.attempt, 2);
        assert_eq!(decoded.dns_config.unwrap().servers, ["10.96.0.10"]);
        assert_eq!(decoded.hostname, "pod-hostname");
    }

    #[test]
    fn cri_v1_options_reject_wrong_type_and_missing_identity() {
        assert!(decode_cri_config("other.Type", &[1]).is_err());
        let empty = CriPodSandboxConfig::default().encode_to_vec();
        assert!(decode_cri_config(CRI_V1_POD_SANDBOX_CONFIG, &empty).is_err());
    }

    #[test]
    fn cri_annotations_construct_default_sandbox_spec() {
        let mut spec = Spec::default();
        merge_cri_annotations(
            &mut spec,
            &sample_cri(),
            &HashMap::from([("request.example/key".to_string(), "request".to_string())]),
        )
        .unwrap();
        let annotations = spec.annotations().as_ref().unwrap();
        assert_eq!(annotations[ANNO_SANDBOX_UID], "uid-a");
        assert_eq!(annotations[ANNO_SANDBOX_NAMESPACE], "ns-a");
        assert_eq!(annotations[ANNO_SANDBOX_NAME], "pod-a");
        assert_eq!(annotations[ANNO_SANDBOX_HOSTNAME], "pod-hostname");
        assert_eq!(annotations[ANNO_SANDBOX_PIDNS], "false");
        assert_eq!(annotations["pod.example/key"], "value");
        assert_eq!(annotations["request.example/key"], "request");
        let dns: Vec<String> = serde_json::from_str(&annotations[ANNO_SANDBOX_DNS]).unwrap();
        assert_eq!(
            dns,
            [
                "nameserver 10.96.0.10",
                "search ns-a.svc.cluster.local",
                "options ndots:5",
            ]
        );
    }

    #[test]
    fn cri_namespace_modes_map_pid_sharing_and_reject_host_namespaces() {
        let mut config = sample_cri();
        assert!(!shared_pid_namespace(&config).unwrap());

        config
            .linux
            .as_mut()
            .unwrap()
            .security_context
            .as_mut()
            .unwrap()
            .namespace_options
            .as_mut()
            .unwrap()
            .pid = 0;
        assert!(shared_pid_namespace(&config).unwrap());

        for (field, expected) in [
            ("network", "hostNetwork"),
            ("pid", "hostPID"),
            ("ipc", "hostIPC"),
        ] {
            let mut host = sample_cri();
            let options = host
                .linux
                .as_mut()
                .unwrap()
                .security_context
                .as_mut()
                .unwrap()
                .namespace_options
                .as_mut()
                .unwrap();
            match field {
                "network" => options.network = 2,
                "pid" => options.pid = 2,
                "ipc" => options.ipc = 2,
                _ => unreachable!(),
            }
            assert!(shared_pid_namespace(&host).unwrap_err().contains(expected));
        }
    }

    #[test]
    fn cri_namespace_options_absent_preserves_container_pid_default() {
        let config = CriPodSandboxConfig {
            metadata: sample_cri().metadata,
            hostname: String::new(),
            ..Default::default()
        };
        assert!(!shared_pid_namespace(&config).unwrap());
        let mut spec = Spec::default();
        merge_cri_annotations(&mut spec, &config, &HashMap::new()).unwrap();
        let annotations = spec.annotations().as_ref().unwrap();
        assert_eq!(annotations[ANNO_SANDBOX_PIDNS], "false");
        assert_eq!(annotations[ANNO_SANDBOX_HOSTNAME], "pod-a");
    }

    #[test]
    fn cri_dns_rejects_invalid_server_before_resource_prepare() {
        let mut config = sample_cri();
        config.dns_config.as_mut().unwrap().servers = vec!["not-an-ip".to_string()];
        let mut spec = Spec::default();
        assert!(merge_cri_annotations(&mut spec, &config, &HashMap::new())
            .unwrap_err()
            .contains("invalid CRI DNS server"));
    }

    #[test]
    fn vm_resources_use_cri_aggregate_and_annotation_override() {
        let config = sample_cri();
        let resources = resources_from_config(&HashMap::new(), &config).unwrap();
        assert_eq!(resources.vcpu_count, 2);
        assert_eq!(resources.memory_bytes, 768 * 1024 * 1024);

        let annotations = HashMap::from([(
            ANNO_VM_RES.to_string(),
            r#"{"cpu":4,"memory":1024}"#.to_string(),
        )]);
        let resources = resources_from_config(&annotations, &config).unwrap();
        assert_eq!(resources.vcpu_count, 4);
        assert_eq!(resources.memory_bytes, 1024 * 1024 * 1024);
    }

    #[test]
    fn vm_resources_default_to_poc_floor() {
        let config = CriPodSandboxConfig {
            metadata: sample_cri().metadata,
            ..Default::default()
        };
        let resources = resources_from_config(&HashMap::new(), &config).unwrap();
        assert_eq!(resources.vcpu_count, 1);
        assert_eq!(resources.memory_bytes, 256 * 1024 * 1024);
    }
}
