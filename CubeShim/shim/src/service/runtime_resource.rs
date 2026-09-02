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
use std::fs;
use std::io::{IoSliceMut, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;
use tokio::net::UnixStream;
use tonic::codegen::http::uri::PathAndQuery;
use tonic::transport::{Channel, Endpoint};
use tonic::{Request, Status};
use tower::service_fn;

use crate::service::host_cgroup::{lifecycle_from_env, RuntimeOwnerState, RuntimeResourceOwner};

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
const ANNO_VIRTIOFS: &str = "cube.virtiofs";
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
const RUNTIMECLASS_OVERHEAD_CONFIG_ENV: &str = "CUBE_RUNTIMECLASS_OVERHEAD_CONFIG";
const DEFAULT_RUNTIMECLASS_OVERHEAD_CONFIG: &str = "/etc/cubesandbox/runtimeclass-overhead.json";
// Linux 6.6 on the supported x86_64 PoC nodes defines PIDS_MAX as
// PID_MAX_LIMIT + 1 and rejects numeric pids.max values >= PIDS_MAX.
pub(crate) const LINUX_PIDS_MAX_LIMIT: u64 = 4_194_304;
pub(crate) const RUNTIME_REAPER_ACTION: &str = "runtime-resource-reaper";
pub(crate) const MANAGED_VOLUME_EXPORT_DIR: &str = "volumes";
pub(crate) const MANAGED_VOLUME_VIRTIOFS_ID: &str = "cubeVolumes";

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

#[derive(Clone, Eq, PartialEq, Message)]
struct ResourceRequest {
    #[prost(uint32, tag = "1")]
    vcpu_count: u32,
    #[prost(uint64, tag = "2")]
    memory_bytes: u64,
}

/// Static Host-side budget for the CubeShim/VMM leaf. Kubernetes owns the
/// Pod parent and the Guest owns each container cgroup; this budget therefore
/// contains only VM capacity plus RuntimeClass overhead.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct HostResourceCeiling {
    pub(crate) cpu_max: String,
    pub(crate) memory_max: String,
    pub(crate) pids_max: String,
    pub(crate) memory_oom_group: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RuntimePreparePlan {
    resources: ResourceRequest,
    host_ceiling: HostResourceCeiling,
}

impl RuntimePreparePlan {
    pub(crate) fn host_ceiling(&self) -> &HostResourceCeiling {
        &self.host_ceiling
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
struct RuntimeClassOverheadConfig {
    schema_version: u32,
    minimum_cpu_millicores: u64,
    minimum_memory_bytes: u64,
    host_pids_max: u64,
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
    #[prost(string, tag = "1")]
    cgroup_parent: String,
    #[prost(message, optional, tag = "2")]
    security_context: Option<CriLinuxSandboxSecurityContext>,
    #[prost(map = "string, string", tag = "3")]
    sysctls: HashMap<String, String>,
    #[prost(message, optional, tag = "4")]
    overhead: Option<CriLinuxContainerResources>,
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
    #[prost(int64, tag = "5")]
    oom_score_adj: i64,
    #[prost(string, tag = "6")]
    cpuset_cpus: String,
    #[prost(string, tag = "7")]
    cpuset_mems: String,
    #[prost(message, repeated, tag = "8")]
    hugepage_limits: Vec<CriHugepageLimit>,
    #[prost(map = "string, string", tag = "9")]
    unified: HashMap<String, String>,
    #[prost(int64, tag = "10")]
    memory_swap_limit_in_bytes: i64,
}

#[derive(Clone, PartialEq, Message)]
struct CriHugepageLimit {
    #[prost(string, tag = "1")]
    page_size: String,
    #[prost(uint64, tag = "2")]
    limit: u64,
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
struct InspectSandboxRequest {
    #[prost(string, tag = "1")]
    sandbox_id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
enum SandboxResourceState {
    Unspecified = 0,
    Preparing = 1,
    Ready = 2,
    Releasing = 3,
    Released = 4,
    Error = 5,
}

#[derive(Clone, PartialEq, Message)]
struct InspectSandboxResponse {
    #[prost(bool, tag = "1")]
    found: bool,
    #[prost(enumeration = "SandboxResourceState", tag = "2")]
    state: i32,
    #[prost(message, optional, tag = "3")]
    sandbox: Option<PreparedSandbox>,
    #[prost(string, tag = "4")]
    last_error: String,
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
    pub(crate) fn durable_identity(&self) -> (&str, &str, &str, u64) {
        (
            &self.endpoint,
            &self.sandbox.sandbox_id,
            &self.sandbox.lease_id,
            self.sandbox.generation,
        )
    }

    pub(crate) fn shared_root(&self) -> Result<PathBuf, String> {
        let assets = self
            .sandbox
            .assets
            .as_ref()
            .ok_or_else(|| "RuntimeResource lease has no assets".to_string())?;
        canonical_runtime_shared_root(Path::new(&assets.shared_root))
    }

    pub(crate) async fn inspect_exact(&self) -> Result<(), String> {
        let response = inspect_sandbox(&self.endpoint, &self.sandbox.sandbox_id).await?;
        validate_exact_inspection(&self.sandbox, &response)
    }

    pub(crate) fn tap_cleanup_identity(&self) -> Result<String, String> {
        let network = self
            .sandbox
            .network
            .as_ref()
            .ok_or_else(|| "RuntimeResource lease has no network attachment".to_string())?;
        let handoff = network
            .fd_handoff
            .as_ref()
            .ok_or_else(|| "RuntimeResource lease has no FD handoff descriptor".to_string())?;
        Ok(format!(
            "provider-release={}:{}:{}:{};network={};handoff={}",
            self.endpoint,
            self.sandbox.sandbox_id,
            self.sandbox.lease_id,
            self.sandbox.generation,
            network.network_handle,
            handoff.endpoint
        ))
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

    pub(crate) async fn acquire_tap(&self) -> Result<std::fs::File, String> {
        preflight_runtime_environment_at(&self.sandbox, Path::new("/dev/kvm"))?;
        let sandbox = self.sandbox.clone();
        tokio::task::spawn_blocking(move || acquire_tap_blocking(&sandbox))
            .await
            .map_err(|error| format!("join TAP handoff: {error}"))?
    }

    pub(crate) async fn release(&self) -> Result<(), String> {
        let lifecycle = lifecycle_from_env()?;
        let operation = lifecycle
            .as_ref()
            .map(|lifecycle| lifecycle.begin_runtime_release())
            .transpose()?;
        self.release_at(&runtime_cleanup_record_path()?).await?;
        if let Some(operation) = operation {
            operation.mark_released()?;
        }
        Ok(())
    }

    async fn release_at(&self, cleanup_path: &Path) -> Result<(), String> {
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
        self.remove_cleanup_record_at(cleanup_path)?;
        Ok(())
    }
}

async fn inspect_sandbox(
    endpoint: &str,
    sandbox_id: &str,
) -> Result<InspectSandboxResponse, String> {
    let mut client = RuntimeResourceClient::connect(endpoint).await?;
    client
        .unary(
            InspectSandboxRequest {
                sandbox_id: sandbox_id.to_string(),
            },
            "/cubelet.services.runtime.v1.RuntimeResource/InspectSandbox",
        )
        .await
}

fn validate_exact_inspection(
    expected: &PreparedSandbox,
    response: &InspectSandboxResponse,
) -> Result<(), String> {
    if !response.found {
        return Err("RuntimeResource exact readback did not find the sandbox".to_string());
    }
    if response.state != SandboxResourceState::Ready as i32 {
        return Err(format!(
            "RuntimeResource exact readback state is {:?}: {}",
            SandboxResourceState::try_from(response.state).ok(),
            response.last_error
        ));
    }
    if response.sandbox.as_ref() != Some(expected) {
        return Err("RuntimeResource exact readback identity or handles changed".to_string());
    }
    Ok(())
}

fn validate_intent_inspection(
    sandbox_id: &str,
    lease_id: &str,
    generation: u64,
    response: &InspectSandboxResponse,
) -> Result<bool, String> {
    if !response.found {
        return Ok(false);
    }
    let state = SandboxResourceState::try_from(response.state).map_err(|_| {
        format!(
            "RuntimeResource INTENT lookup returned unknown state {}",
            response.state
        )
    })?;
    if state == SandboxResourceState::Released {
        // Inspect does not return tombstone identity.  Continue with the exact
        // ReleaseSandbox tuple below; Cubelet validates lease/generation/key
        // against the durable tombstone and confirms an exact retry.
        return Ok(true);
    }
    if !matches!(
        state,
        SandboxResourceState::Preparing
            | SandboxResourceState::Ready
            | SandboxResourceState::Releasing
    ) {
        return Err(format!(
            "RuntimeResource INTENT lookup is not safely releasable in state {state:?}: {}",
            response.last_error
        ));
    }
    let inspected = response.sandbox.as_ref().ok_or_else(|| {
        format!(
            "RuntimeResource INTENT exists in state {state:?} without exact handles: {}",
            response.last_error
        )
    })?;
    if inspected.sandbox_id != sandbox_id
        || inspected.lease_id != lease_id
        || inspected.generation != generation
    {
        return Err("RuntimeResource INTENT lookup returned a different lease".to_string());
    }
    Ok(true)
}

pub(crate) async fn release_external_owner(owner: &RuntimeResourceOwner) -> Result<(), String> {
    if matches!(
        owner.state(),
        RuntimeOwnerState::Empty | RuntimeOwnerState::Released
    ) {
        return Ok(());
    }
    let (endpoint, sandbox_id, lease_id, generation) = owner
        .release_identity()
        .ok_or_else(|| "RuntimeResource owner is missing its release identity".to_string())?;
    if owner.state() == RuntimeOwnerState::Intent {
        let inspection = inspect_sandbox(endpoint, sandbox_id).await?;
        if !validate_intent_inspection(sandbox_id, lease_id, generation, &inspection)? {
            // The durable INTENT was revoked before PrepareSandbox reached the
            // provider.  InspectSandbox is the non-allocating proof that there
            // is no resource to release, so the cleanup queue can be acked.
            return Ok(());
        }
    }
    let sandbox = PreparedSandbox {
        sandbox_id: sandbox_id.to_string(),
        lease_id: lease_id.to_string(),
        generation,
        ..Default::default()
    };
    let mut client = RuntimeResourceClient::connect(endpoint).await?;
    let response: ReleaseSandboxResponse = client
        .unary(
            ReleaseSandboxRequest {
                sandbox_id: sandbox.sandbox_id.clone(),
                lease_id: sandbox.lease_id.clone(),
                generation: sandbox.generation,
                idempotency_key: release_key(&sandbox),
            },
            "/cubelet.services.runtime.v1.RuntimeResource/ReleaseSandbox",
        )
        .await?;
    if response.released {
        Ok(())
    } else {
        Err("Cubelet did not confirm external RuntimeResource release".to_string())
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
    reaper_queue::persist_reaper_job_at(&root, &record).map(|_| ())
}

pub(crate) async fn scan_persisted_reapers_once() -> Result<(), String> {
    let root = reaper_root()?;
    let entries = match fs::read_dir(&root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("scan RuntimeResource cleanup queue: {error}")),
    };
    let mut errors = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        let job = entry.path();
        if !entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false) {
            continue;
        }
        let path = job.join(RUNTIME_CLEANUP_RECORD);
        let Some(record) = load_cleanup_record_at(&path)? else {
            continue;
        };
        let lease = RuntimeLease {
            endpoint: record.endpoint,
            sandbox: PreparedSandbox {
                sandbox_id: record.sandbox_id,
                lease_id: record.lease_id,
                generation: record.generation,
                ..Default::default()
            },
        };
        match lease.release_at(&path).await {
            Ok(()) => {
                if let Err(error) = reaper_queue::remove_reaper_job_directory(&job) {
                    errors.push(error);
                }
            }
            Err(error) => errors.push(format!("retry {}: {error}", job.display())),
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
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
    if config.metadata.is_none() {
        return Err("CRI PodSandboxConfig metadata message is missing".to_string());
    }
    Ok(config)
}

fn hash_fingerprint_part(hasher: &mut Sha256, value: &[u8]) {
    hasher.update((value.len() as u64).to_be_bytes());
    hasher.update(value);
}

fn hash_fingerprint_field(hasher: &mut Sha256, label: &[u8], value: &[u8]) {
    hash_fingerprint_part(hasher, label);
    hash_fingerprint_part(hasher, value);
}

fn hash_fingerprint_string_list(hasher: &mut Sha256, label: &[u8], values: &[String]) {
    hash_fingerprint_part(hasher, label);
    hash_fingerprint_part(hasher, &(values.len() as u64).to_be_bytes());
    for value in values {
        hash_fingerprint_part(hasher, b"item");
        hash_fingerprint_part(hasher, value.as_bytes());
    }
}

fn hash_fingerprint_string_map(
    hasher: &mut Sha256,
    label: &[u8],
    values: &HashMap<String, String>,
) {
    hash_fingerprint_part(hasher, label);
    hash_fingerprint_part(hasher, &(values.len() as u64).to_be_bytes());
    let mut entries: Vec<_> = values.iter().collect();
    entries.sort_by(|left, right| left.0.cmp(right.0));
    for (key, value) in entries {
        hash_fingerprint_part(hasher, b"entry");
        hash_fingerprint_part(hasher, key.as_bytes());
        hash_fingerprint_part(hasher, value.as_bytes());
    }
}

fn hash_linux_resources(
    hasher: &mut Sha256,
    label: &[u8],
    resources: Option<&CriLinuxContainerResources>,
) {
    hash_fingerprint_part(hasher, label);
    let Some(resources) = resources else {
        hash_fingerprint_part(hasher, b"absent");
        return;
    };
    hash_fingerprint_part(hasher, b"present");
    for (field, value) in [
        (b"cpu-period".as_slice(), resources.cpu_period),
        (b"cpu-quota".as_slice(), resources.cpu_quota),
        (b"cpu-shares".as_slice(), resources.cpu_shares),
        (
            b"memory-limit-in-bytes".as_slice(),
            resources.memory_limit_in_bytes,
        ),
        (b"oom-score-adj".as_slice(), resources.oom_score_adj),
        (
            b"memory-swap-limit-in-bytes".as_slice(),
            resources.memory_swap_limit_in_bytes,
        ),
    ] {
        hash_fingerprint_field(hasher, field, &value.to_be_bytes());
    }
    hash_fingerprint_field(hasher, b"cpuset-cpus", resources.cpuset_cpus.as_bytes());
    hash_fingerprint_field(hasher, b"cpuset-mems", resources.cpuset_mems.as_bytes());
    let mut hugepages: Vec<_> = resources.hugepage_limits.iter().collect();
    hugepages.sort_by(|left, right| {
        left.page_size
            .cmp(&right.page_size)
            .then(left.limit.cmp(&right.limit))
    });
    hash_fingerprint_part(hasher, b"hugepage-limits");
    hash_fingerprint_part(hasher, &(hugepages.len() as u64).to_be_bytes());
    for limit in hugepages {
        hash_fingerprint_part(hasher, b"hugepage-limit");
        hash_fingerprint_field(hasher, b"page-size", limit.page_size.as_bytes());
        hash_fingerprint_field(hasher, b"limit", &limit.limit.to_be_bytes());
    }
    hash_fingerprint_string_map(hasher, b"unified", &resources.unified);
}

pub(crate) fn cri_semantic_fingerprint(config: &CriPodSandboxConfig) -> String {
    let mut hasher = Sha256::new();
    hash_fingerprint_part(&mut hasher, b"cri-pod-sandbox-semantic-v2");
    hash_fingerprint_field(&mut hasher, b"hostname", config.hostname.as_bytes());
    hash_fingerprint_part(&mut hasher, b"metadata");
    if let Some(metadata) = &config.metadata {
        hash_fingerprint_part(&mut hasher, b"present");
        hash_fingerprint_field(&mut hasher, b"name", metadata.name.as_bytes());
        hash_fingerprint_field(&mut hasher, b"uid", metadata.uid.as_bytes());
        hash_fingerprint_field(&mut hasher, b"namespace", metadata.namespace.as_bytes());
        hash_fingerprint_field(&mut hasher, b"attempt", &metadata.attempt.to_be_bytes());
    } else {
        hash_fingerprint_part(&mut hasher, b"absent");
    }
    hash_fingerprint_part(&mut hasher, b"dns-config");
    if let Some(dns) = &config.dns_config {
        hash_fingerprint_part(&mut hasher, b"present");
        hash_fingerprint_string_list(&mut hasher, b"servers", &dns.servers);
        hash_fingerprint_string_list(&mut hasher, b"searches", &dns.searches);
        hash_fingerprint_string_list(&mut hasher, b"options", &dns.options);
    } else {
        hash_fingerprint_part(&mut hasher, b"absent");
    }
    hash_fingerprint_string_map(&mut hasher, b"annotations", &config.annotations);
    hash_fingerprint_part(&mut hasher, b"linux");
    if let Some(linux) = config.linux.as_ref() {
        hash_fingerprint_part(&mut hasher, b"present");
        hash_fingerprint_field(
            &mut hasher,
            b"cgroup-parent",
            linux.cgroup_parent.as_bytes(),
        );
        hash_fingerprint_string_map(&mut hasher, b"sysctls", &linux.sysctls);
        hash_linux_resources(&mut hasher, b"resources", linux.resources.as_ref());
        hash_linux_resources(&mut hasher, b"overhead", linux.overhead.as_ref());
    } else {
        hash_fingerprint_part(&mut hasher, b"absent");
    }
    hash_fingerprint_part(&mut hasher, b"namespace-options");
    if let Some(options) = namespace_options(config) {
        hash_fingerprint_part(&mut hasher, b"present");
        for (field, value) in [
            (b"network".as_slice(), options.network),
            (b"pid".as_slice(), options.pid),
            (b"ipc".as_slice(), options.ipc),
        ] {
            hash_fingerprint_field(&mut hasher, field, &value.to_be_bytes());
        }
        hash_fingerprint_field(&mut hasher, b"target-id", options.target_id.as_bytes());
    } else {
        hash_fingerprint_part(&mut hasher, b"absent");
    }
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
pub(crate) fn cri_collection_collision_regression_fingerprints() -> (String, String) {
    let metadata = Some(CriPodSandboxMetadata {
        name: "collision-pod".to_string(),
        uid: "collision-uid".to_string(),
        namespace: "default".to_string(),
        attempt: 0,
    });
    let left = CriPodSandboxConfig {
        metadata: metadata.clone(),
        annotations: HashMap::from([("linux-present".to_string(), "user.slice".to_string())]),
        linux: Some(CriLinuxPodSandboxConfig {
            cgroup_parent: "system.slice".to_string(),
            ..Default::default()
        }),
        ..Default::default()
    };
    let right = CriPodSandboxConfig {
        metadata,
        linux: Some(CriLinuxPodSandboxConfig {
            cgroup_parent: "user.slice".to_string(),
            sysctls: HashMap::from([("linux-present".to_string(), "system.slice".to_string())]),
            ..Default::default()
        }),
        ..Default::default()
    };
    (
        cri_semantic_fingerprint(&left),
        cri_semantic_fingerprint(&right),
    )
}

pub(crate) fn cgroup_parent(config: &CriPodSandboxConfig) -> &str {
    config
        .linux
        .as_ref()
        .map(|linux| linux.cgroup_parent.as_str())
        .unwrap_or_default()
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
    plan: &RuntimePreparePlan,
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
    let resources = plan.resources.clone();
    let generation = u64::from(metadata.attempt) + 1;
    let dns = cri_dns_entries(config.dns_config.as_ref())?;
    let idempotency_key = prepare_key(sandbox_id, generation);
    let expected_lease_id = lease_id_for_prepare(sandbox_id, generation, &idempotency_key);
    let lifecycle = lifecycle_from_env()?;
    let runtime_operation = lifecycle
        .as_ref()
        .map(|lifecycle| {
            lifecycle.begin_runtime_intent(&RuntimeResourceOwner::intent(
                endpoint.clone(),
                sandbox_id.to_string(),
                expected_lease_id.clone(),
                generation,
                idempotency_key.clone(),
            ))
        })
        .transpose()?;
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
    if let Some(lifecycle) = lifecycle.as_ref() {
        lifecycle.wait_test_failpoint("pre-runtime-prepare").await;
    }
    if let Some(operation) = runtime_operation.as_ref() {
        // The RuntimeResource INTENT and owner epoch were committed together.
        // Recheck after every fallible preparation step and immediately before
        // the allocating RPC. If cleanup revoked us earlier, no side effect is
        // allowed; if it revokes us later, the durable handoff already carries
        // this exact INTENT rather than EMPTY.
        operation.verify()?;
    }
    let response: PrepareSandboxResponse = match client
        .unary(
            request,
            "/cubelet.services.runtime.v1.RuntimeResource/PrepareSandbox",
        )
        .await
    {
        Ok(response) => response,
        Err(error) => {
            return Err(release_after_prepare_error(
                &cleanup_lease,
                runtime_operation.as_ref(),
                error,
            )
            .await)
        }
    };
    let mut sandbox = match response.sandbox {
        Some(sandbox) => sandbox,
        None => {
            return Err(release_after_prepare_error(
                &cleanup_lease,
                runtime_operation.as_ref(),
                "Cubelet returned no prepared sandbox".to_string(),
            )
            .await)
        }
    };
    let shared_root = match validate_prepared(sandbox_id, generation, &expected_lease_id, &sandbox)
    {
        Ok(shared_root) => shared_root,
        Err(error) => {
            return Err(release_after_prepare_error(
                &cleanup_lease,
                runtime_operation.as_ref(),
                error,
            )
            .await)
        }
    };
    // From this point on both the virtiofs annotation and Task rootfs bridge
    // use the canonical path that was validated as a strict /data/cubelet
    // descendant. Do not retain a server-supplied symlink spelling.
    sandbox.assets.as_mut().unwrap().shared_root = shared_root.display().to_string();
    if let Err(error) = ensure_managed_volume_export_root(&shared_root) {
        return Err(
            release_after_prepare_error(&cleanup_lease, runtime_operation.as_ref(), error).await,
        );
    }
    if let Err(error) = inject_annotations(spec, &resources, &sandbox) {
        return Err(
            release_after_prepare_error(&cleanup_lease, runtime_operation.as_ref(), error).await,
        );
    }
    if let Some(operation) = runtime_operation {
        operation.mark_allocated()?;
    }
    Ok(RuntimeLease { endpoint, sandbox })
}

async fn release_after_prepare_error(
    lease: &RuntimeLease,
    operation: Option<&crate::service::host_cgroup::LifecycleOperation>,
    error: String,
) -> String {
    let cleanup_path = match runtime_cleanup_record_path() {
        Ok(path) => path,
        Err(release_error) => return format!("{error}; release RuntimeResource: {release_error}"),
    };
    match lease.release_at(&cleanup_path).await {
        Ok(()) => match operation
            .map(|operation| operation.mark_released())
            .transpose()
        {
            Ok(_) => error,
            Err(release_error) => {
                format!("{error}; persist RuntimeResource release: {release_error}")
            }
        },
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

pub(crate) fn managed_volume_export_root(shared_root: &Path) -> Result<PathBuf, String> {
    let shared_root = canonical_runtime_shared_root(shared_root)?;
    let volume_root = shared_root.join(MANAGED_VOLUME_EXPORT_DIR);
    let metadata = fs::symlink_metadata(&volume_root).map_err(|error| {
        format!(
            "stat fixed managed volume export root {}: {error}",
            volume_root.display()
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!(
            "fixed managed volume export root is not a real directory: {}",
            volume_root.display()
        ));
    }
    let canonical = volume_root.canonicalize().map_err(|error| {
        format!(
            "canonicalize fixed managed volume export root {}: {error}",
            volume_root.display()
        )
    })?;
    if canonical.parent() != Some(shared_root.as_path()) {
        return Err(format!(
            "fixed managed volume export root escaped RuntimeResource root: {}",
            canonical.display()
        ));
    }
    Ok(canonical)
}

fn ensure_managed_volume_export_root(shared_root: &Path) -> Result<PathBuf, String> {
    let volume_root = shared_root.join(MANAGED_VOLUME_EXPORT_DIR);
    match fs::create_dir(&volume_root) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => {
            return Err(format!(
                "create fixed managed volume export root {}: {error}",
                volume_root.display()
            ))
        }
    }
    managed_volume_export_root(shared_root)
}

fn inject_annotations(
    spec: &mut Spec,
    resources: &ResourceRequest,
    sandbox: &PreparedSandbox,
) -> Result<(), String> {
    let assets = sandbox.assets.as_ref().unwrap();
    let network = sandbox.network.as_ref().unwrap();
    let mut annotations = spec.annotations().as_ref().cloned().unwrap_or_default();
    if annotations.contains_key(ANNO_VIRTIOFS) {
        return Err(format!(
            "RuntimeResource sandbox cannot be combined with an existing {ANNO_VIRTIOFS} annotation"
        ));
    }
    let volume_root = managed_volume_export_root(Path::new(&assets.shared_root))?;
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
    annotations.insert(
        ANNO_VIRTIOFS.to_string(),
        serde_json::json!([{
            "id": MANAGED_VOLUME_VIRTIOFS_ID,
            "backendfs_config": {
                "shared_dir": VIRTIOFS_SHARED_DIR,
                "allowed_dirs": [volume_root],
                "announce_submounts": false,
                "cache": 3,
                "read_only": false,
            }
        }])
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

fn load_runtimeclass_overhead_config() -> Result<RuntimeClassOverheadConfig, String> {
    let path = std::env::var_os(RUNTIMECLASS_OVERHEAD_CONFIG_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_RUNTIMECLASS_OVERHEAD_CONFIG));
    if !path.is_absolute() {
        return Err(format!(
            "{RUNTIMECLASS_OVERHEAD_CONFIG_ENV} must be an absolute path"
        ));
    }
    let data = fs::read(&path).map_err(|error| {
        format!(
            "read RuntimeClass overhead config {}: {error}",
            path.display()
        )
    })?;
    let config: RuntimeClassOverheadConfig = serde_json::from_slice(&data).map_err(|error| {
        format!(
            "decode RuntimeClass overhead config {}: {error}",
            path.display()
        )
    })?;
    validate_runtimeclass_overhead_config(&config)?;
    Ok(config)
}

fn validate_runtimeclass_overhead_config(
    config: &RuntimeClassOverheadConfig,
) -> Result<(), String> {
    if config.schema_version != 1 {
        return Err(format!(
            "unsupported RuntimeClass overhead config schema {}",
            config.schema_version
        ));
    }
    if config.minimum_cpu_millicores == 0
        || config.minimum_memory_bytes == 0
        || config.host_pids_max == 0
    {
        return Err(
            "RuntimeClass overhead minimum CPU, memory, and Host PIDs must be non-zero".to_string(),
        );
    }
    if config.host_pids_max > LINUX_PIDS_MAX_LIMIT {
        return Err(format!(
            "RuntimeClass Host PIDs {} exceeds Linux numeric pids.max limit {LINUX_PIDS_MAX_LIMIT}",
            config.host_pids_max
        ));
    }
    Ok(())
}

/// Validate the exact CRI RuntimeClass overhead and derive a checked static
/// Host leaf ceiling. Request annotations override the copy carried inside
/// PodSandboxConfig in the same way as merge_cri_annotations.
pub(crate) fn runtime_prepare_plan(
    config: &CriPodSandboxConfig,
    request_annotations: &HashMap<String, String>,
) -> Result<RuntimePreparePlan, String> {
    let node = load_runtimeclass_overhead_config()?;
    runtime_prepare_plan_with_config(config, request_annotations, &node)
}

#[cfg(test)]
fn host_resource_ceiling_with_config(
    config: &CriPodSandboxConfig,
    request_annotations: &HashMap<String, String>,
    node: &RuntimeClassOverheadConfig,
) -> Result<HostResourceCeiling, String> {
    Ok(runtime_prepare_plan_with_config(config, request_annotations, node)?.host_ceiling)
}

fn runtime_prepare_plan_with_config(
    config: &CriPodSandboxConfig,
    request_annotations: &HashMap<String, String>,
    node: &RuntimeClassOverheadConfig,
) -> Result<RuntimePreparePlan, String> {
    validate_runtimeclass_overhead_config(node)?;
    let linux = config
        .linux
        .as_ref()
        .ok_or_else(|| "CRI LinuxPodSandboxConfig is required".to_string())?;
    let overhead = linux
        .overhead
        .as_ref()
        .ok_or_else(|| "RuntimeClass overhead is required for RuntimeClass cube".to_string())?;

    if overhead.cpu_period <= 0
        || overhead.cpu_quota <= 0
        || overhead.cpu_shares < 0
        || overhead.memory_limit_in_bytes <= 0
    {
        return Err(
            "RuntimeClass overhead requires positive CPU period/quota and memory with non-negative CPU shares"
                .to_string(),
        );
    }
    if overhead.oom_score_adj != 0
        || !overhead.cpuset_cpus.is_empty()
        || !overhead.cpuset_mems.is_empty()
        || !overhead.hugepage_limits.is_empty()
        || overhead.memory_swap_limit_in_bytes != 0
    {
        return Err(
            "RuntimeClass overhead supports only CPU, memory, and memory.oom.group=1".to_string(),
        );
    }
    if overhead.unified.len() > 1
        || overhead
            .unified
            .iter()
            .any(|(key, value)| key != "memory.oom.group" || value != "1")
    {
        return Err("RuntimeClass overhead unified supports only memory.oom.group=1".to_string());
    }

    let period = u128::try_from(overhead.cpu_period)
        .map_err(|_| "RuntimeClass overhead CPU period is negative".to_string())?;
    let quota = u128::try_from(overhead.cpu_quota)
        .map_err(|_| "RuntimeClass overhead CPU quota is negative".to_string())?;
    let normalized = quota
        .checked_mul(100_000)
        .and_then(|value| value.checked_add(period - 1))
        .map(|value| value / period)
        .ok_or_else(|| "RuntimeClass overhead CPU normalization overflow".to_string())?;
    let rate_numerator = quota
        .checked_mul(1_000)
        .ok_or_else(|| "RuntimeClass overhead CPU rate overflow".to_string())?;
    let minimum_rate_numerator = u128::from(node.minimum_cpu_millicores)
        .checked_mul(period)
        .ok_or_else(|| "RuntimeClass overhead node minimum CPU rate overflow".to_string())?;
    if rate_numerator < minimum_rate_numerator {
        let millicores = rate_numerator / period;
        return Err(format!(
            "RuntimeClass CPU overhead {millicores}m is below node minimum {}m",
            node.minimum_cpu_millicores
        ));
    }
    let overhead_memory = u64::try_from(overhead.memory_limit_in_bytes)
        .map_err(|_| "RuntimeClass overhead memory is negative".to_string())?;
    if overhead_memory < node.minimum_memory_bytes {
        return Err(format!(
            "RuntimeClass memory overhead {overhead_memory} is below node minimum {}",
            node.minimum_memory_bytes
        ));
    }

    let mut annotations = config.annotations.clone();
    annotations.extend(request_annotations.clone());
    let vm = resources_from_config(&annotations, config)?;
    let cpu_quota = u128::from(vm.vcpu_count)
        .checked_mul(100_000)
        .and_then(|value| value.checked_add(normalized))
        .ok_or_else(|| "Host CPU ceiling overflow".to_string())?;
    if cpu_quota > i64::MAX as u128 {
        return Err("Host CPU ceiling exceeds cgroup controller range".to_string());
    }
    let memory_max = vm
        .memory_bytes
        .checked_add(overhead_memory)
        .ok_or_else(|| "Host memory ceiling overflow".to_string())?;
    if memory_max > i64::MAX as u64 {
        return Err("Host memory ceiling exceeds cgroup controller range".to_string());
    }

    Ok(RuntimePreparePlan {
        resources: vm,
        host_ceiling: HostResourceCeiling {
            cpu_max: format!("{cpu_quota} 100000"),
            memory_max: memory_max.to_string(),
            pids_max: node.host_pids_max.to_string(),
            memory_oom_group: "1".to_string(),
        },
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

    #[cfg(target_family = "unix")]
    #[test]
    fn managed_volume_share_is_writable_cacheless_and_inode_stable() {
        use std::os::unix::fs::MetadataExt;

        let root = PathBuf::from(format!(
            "/data/cubelet/runtime-volume-root-test-{}",
            uuid::Uuid::new_v4()
        ));
        let shared = root.join("shared");
        std::fs::create_dir_all(&shared).unwrap();
        let volume_root = ensure_managed_volume_export_root(&shared).unwrap();
        let inode = std::fs::metadata(&volume_root).unwrap().ino();
        assert_eq!(
            std::fs::metadata(ensure_managed_volume_export_root(&shared).unwrap())
                .unwrap()
                .ino(),
            inode
        );

        let sandbox = PreparedSandbox {
            assets: Some(RuntimeAssets {
                shared_root: shared.display().to_string(),
                ..Default::default()
            }),
            network: Some(sample_network()),
            ..Default::default()
        };
        let mut spec = Spec::default();
        inject_annotations(
            &mut spec,
            &ResourceRequest {
                vcpu_count: 1,
                memory_bytes: 256 * 1024 * 1024,
            },
            &sandbox,
        )
        .unwrap();
        let annotations = spec.annotations().as_ref().unwrap();
        let rootfs: serde_json::Value =
            serde_json::from_str(annotations.get(ANNO_VMM_FS).unwrap()).unwrap();
        assert_eq!(
            rootfs["backendfs_config"]["allowed_dirs"][0],
            shared.display().to_string()
        );
        assert_eq!(rootfs["backendfs_config"]["cache"], 2);
        assert_eq!(rootfs["backendfs_config"]["read_only"], true);
        assert_eq!(rootfs["backendfs_config"]["announce_submounts"], false);

        let volume: serde_json::Value =
            serde_json::from_str(annotations.get(ANNO_VIRTIOFS).unwrap()).unwrap();
        assert_eq!(volume[0]["id"], MANAGED_VOLUME_VIRTIOFS_ID);
        assert_eq!(
            volume[0]["backendfs_config"]["allowed_dirs"][0],
            volume_root.display().to_string()
        );
        assert_eq!(volume[0]["backendfs_config"]["cache"], 3);
        assert_eq!(volume[0]["backendfs_config"]["read_only"], false);
        assert_eq!(volume[0]["backendfs_config"]["announce_submounts"], false);

        std::fs::remove_dir_all(&root).unwrap();
    }

    #[cfg(target_family = "unix")]
    #[test]
    fn managed_volume_root_rejects_symlink_replacement() {
        let root = PathBuf::from(format!(
            "/data/cubelet/runtime-volume-symlink-test-{}",
            uuid::Uuid::new_v4()
        ));
        let shared = root.join("shared");
        let outside = root.join("outside");
        std::fs::create_dir_all(&shared).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        symlink(&outside, shared.join(MANAGED_VOLUME_EXPORT_DIR)).unwrap();

        assert!(ensure_managed_volume_export_root(&shared)
            .unwrap_err()
            .contains("not a real directory"));

        std::fs::remove_dir_all(&root).unwrap();
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
    fn intent_cleanup_accepts_absent_and_exact_released_tombstone() {
        let absent = InspectSandboxResponse::default();
        assert!(!validate_intent_inspection("sandbox-a", "lease-a", 3, &absent).unwrap());

        let released = InspectSandboxResponse {
            found: true,
            state: SandboxResourceState::Released as i32,
            sandbox: None,
            last_error: String::new(),
        };
        assert!(validate_intent_inspection("sandbox-a", "lease-a", 3, &released).unwrap());
    }

    #[test]
    fn intent_cleanup_requires_exact_active_lease_and_fails_closed_on_error() {
        let expected = PreparedSandbox {
            sandbox_id: "sandbox-a".to_string(),
            lease_id: "lease-a".to_string(),
            generation: 3,
            ..Default::default()
        };
        let ready = InspectSandboxResponse {
            found: true,
            state: SandboxResourceState::Ready as i32,
            sandbox: Some(expected.clone()),
            last_error: String::new(),
        };
        assert!(validate_intent_inspection("sandbox-a", "lease-a", 3, &ready).unwrap());

        let mut mismatched = ready;
        mismatched.sandbox.as_mut().unwrap().lease_id = "other".to_string();
        assert!(validate_intent_inspection("sandbox-a", "lease-a", 3, &mismatched).is_err());
        let provider_error = InspectSandboxResponse {
            found: true,
            state: SandboxResourceState::Error as i32,
            sandbox: Some(expected),
            last_error: "provider inspection failed".to_string(),
        };
        assert!(validate_intent_inspection("sandbox-a", "lease-a", 3, &provider_error).is_err());
    }

    #[test]
    fn succeeded_readback_requires_ready_and_all_exact_provider_handles() {
        let expected = PreparedSandbox {
            sandbox_id: "sandbox-a".to_string(),
            lease_id: "lease-a".to_string(),
            generation: 3,
            assets: Some(RuntimeAssets {
                kernel_path: "/kernel".to_string(),
                agent_path: "/agent".to_string(),
                guest_image_path: "/rootfs".to_string(),
                shared_root: "/data/cubelet/shared/a".to_string(),
            }),
            network: Some(sample_network()),
        };
        let exact = InspectSandboxResponse {
            found: true,
            state: SandboxResourceState::Ready as i32,
            sandbox: Some(expected.clone()),
            last_error: String::new(),
        };
        validate_exact_inspection(&expected, &exact).unwrap();

        let mut drifted = exact.clone();
        drifted
            .sandbox
            .as_mut()
            .unwrap()
            .network
            .as_mut()
            .unwrap()
            .network_handle = "replacement".to_string();
        assert!(validate_exact_inspection(&expected, &drifted).is_err());
        let mut releasing = exact;
        releasing.state = SandboxResourceState::Releasing as i32;
        assert!(validate_exact_inspection(&expected, &releasing).is_err());
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
                cgroup_parent: "kubepods-burstable-podabc.slice".to_string(),
                sysctls: HashMap::new(),
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
                    ..Default::default()
                }),
                overhead: Some(CriLinuxContainerResources {
                    cpu_period: 100_000,
                    cpu_quota: 25_000,
                    memory_limit_in_bytes: 256 * 1024 * 1024,
                    unified: HashMap::from([("memory.oom.group".to_string(), "1".to_string())]),
                    ..Default::default()
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
        assert_eq!(
            decoded.linux.as_ref().unwrap().cgroup_parent,
            "kubepods-burstable-podabc.slice"
        );
        assert_eq!(
            decoded
                .linux
                .as_ref()
                .unwrap()
                .overhead
                .as_ref()
                .unwrap()
                .memory_limit_in_bytes,
            256 * 1024 * 1024
        );
    }

    #[test]
    fn kubernetes_v1_36_golden_wire_preserves_parent_and_overhead_tags() {
        // runtime.v1.PodSandboxConfig captured with the Kubernetes v1.36 CRI
        // field layout. Keeping this independent byte vector prevents the
        // local prost declarations from agreeing with themselves on a wrong
        // tag number.
        const GOLDEN: &[u8] = &[
            0x0a, 0x25, 0x0a, 0x0a, 0x67, 0x6f, 0x6c, 0x64, 0x65, 0x6e, 0x2d, 0x70, 0x6f, 0x64,
            0x12, 0x0a, 0x67, 0x6f, 0x6c, 0x64, 0x65, 0x6e, 0x2d, 0x75, 0x69, 0x64, 0x1a, 0x09,
            0x67, 0x6f, 0x6c, 0x64, 0x65, 0x6e, 0x2d, 0x6e, 0x73, 0x20, 0x07, 0x12, 0x0b, 0x67,
            0x6f, 0x6c, 0x64, 0x65, 0x6e, 0x2d, 0x68, 0x6f, 0x73, 0x74, 0x42, 0x4e, 0x0a, 0x22,
            0x6b, 0x75, 0x62, 0x65, 0x70, 0x6f, 0x64, 0x73, 0x2d, 0x62, 0x75, 0x72, 0x73, 0x74,
            0x61, 0x62, 0x6c, 0x65, 0x2d, 0x70, 0x6f, 0x64, 0x67, 0x6f, 0x6c, 0x64, 0x65, 0x6e,
            0x2e, 0x73, 0x6c, 0x69, 0x63, 0x65, 0x22, 0x28, 0x08, 0xa0, 0x8d, 0x06, 0x10, 0xa8,
            0xc3, 0x01, 0x18, 0x80, 0x02, 0x20, 0x80, 0x80, 0x80, 0x80, 0x01, 0x4a, 0x15, 0x0a,
            0x10, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x2e, 0x6f, 0x6f, 0x6d, 0x2e, 0x67, 0x72,
            0x6f, 0x75, 0x70, 0x12, 0x01, 0x31,
        ];
        let decoded = decode_cri_config(CRI_V1_POD_SANDBOX_CONFIG, GOLDEN).unwrap();
        let linux = decoded.linux.unwrap();
        assert_eq!(linux.cgroup_parent, "kubepods-burstable-podgolden.slice");
        let overhead = linux.overhead.unwrap();
        assert_eq!(overhead.cpu_period, 100_000);
        assert_eq!(overhead.cpu_quota, 25_000);
        assert_eq!(overhead.cpu_shares, 256);
        assert_eq!(overhead.memory_limit_in_bytes, 256 * 1024 * 1024);
        assert_eq!(overhead.unified["memory.oom.group"], "1");
    }

    #[test]
    fn cri_fingerprint_covers_parent_and_complete_overhead() {
        let base = sample_cri();
        let base_fingerprint = cri_semantic_fingerprint(&base);
        let mut changed_parent = base.clone();
        changed_parent
            .linux
            .as_mut()
            .unwrap()
            .cgroup_parent
            .push('x');
        assert_ne!(base_fingerprint, cri_semantic_fingerprint(&changed_parent));

        let mut changed_overhead = base.clone();
        changed_overhead
            .linux
            .as_mut()
            .unwrap()
            .overhead
            .as_mut()
            .unwrap()
            .memory_swap_limit_in_bytes = 1;
        assert_ne!(
            base_fingerprint,
            cri_semantic_fingerprint(&changed_overhead)
        );

        let mut reordered = base.clone();
        let overhead = reordered.linux.as_mut().unwrap().overhead.as_mut().unwrap();
        overhead
            .unified
            .insert("cpu.weight".to_string(), "100".to_string());
        let first = cri_semantic_fingerprint(&reordered);
        let mut same = reordered.clone();
        let entries = same
            .linux
            .as_mut()
            .unwrap()
            .overhead
            .as_mut()
            .unwrap()
            .unified
            .drain()
            .collect::<Vec<_>>();
        for (key, value) in entries.into_iter().rev() {
            same.linux
                .as_mut()
                .unwrap()
                .overhead
                .as_mut()
                .unwrap()
                .unified
                .insert(key, value);
        }
        assert_eq!(first, cri_semantic_fingerprint(&same));
    }

    #[test]
    fn cri_fingerprint_frames_collection_domains_against_v12_collision() {
        // With the legacy untagged encoding these two requests produced the
        // same sequence after DNS: an annotation entry could be reinterpreted
        // as the Linux presence marker/parent and a sysctl entry.
        let (left, right) = cri_collection_collision_regression_fingerprints();
        assert_ne!(left, right);
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

    fn poc_overhead_config() -> RuntimeClassOverheadConfig {
        RuntimeClassOverheadConfig {
            schema_version: 1,
            minimum_cpu_millicores: 250,
            minimum_memory_bytes: 256 * 1024 * 1024,
            host_pids_max: 512,
        }
    }

    fn default_overhead() -> CriLinuxContainerResources {
        CriLinuxContainerResources {
            cpu_period: 100_000,
            cpu_quota: 25_000,
            cpu_shares: 256,
            memory_limit_in_bytes: 256 * 1024 * 1024,
            unified: HashMap::from([("memory.oom.group".to_string(), "1".to_string())]),
            ..Default::default()
        }
    }

    fn ceiling_config(
        aggregate: CriLinuxContainerResources,
        overhead: CriLinuxContainerResources,
    ) -> CriPodSandboxConfig {
        let mut config = sample_cri();
        let linux = config.linux.as_mut().unwrap();
        linux.resources = Some(aggregate);
        linux.overhead = Some(overhead);
        config
    }

    #[test]
    fn runtimeclass_ceiling_matches_v1_v3_v5_v9_v10() {
        let node = poc_overhead_config();
        let v1 = ceiling_config(CriLinuxContainerResources::default(), default_overhead());
        assert_eq!(
            host_resource_ceiling_with_config(&v1, &HashMap::new(), &node).unwrap(),
            HostResourceCeiling {
                cpu_max: "125000 100000".to_string(),
                memory_max: "536870912".to_string(),
                pids_max: "512".to_string(),
                memory_oom_group: "1".to_string(),
            }
        );

        let v2 = ceiling_config(
            CriLinuxContainerResources {
                cpu_period: 100_000,
                cpu_shares: 204,
                ..Default::default()
            },
            default_overhead(),
        );
        assert_eq!(
            host_resource_ceiling_with_config(&v2, &HashMap::new(), &node).unwrap(),
            host_resource_ceiling_with_config(&v1, &HashMap::new(), &node).unwrap()
        );

        let v3 = ceiling_config(
            CriLinuxContainerResources {
                cpu_period: 100_000,
                cpu_quota: 60_000,
                cpu_shares: 614,
                memory_limit_in_bytes: 320 * 1024 * 1024,
                ..Default::default()
            },
            default_overhead(),
        );
        let v3_ceiling = host_resource_ceiling_with_config(&v3, &HashMap::new(), &node).unwrap();
        assert_eq!(v3_ceiling.cpu_max, "125000 100000");
        assert_eq!(v3_ceiling.memory_max, "603979776");

        let v4 = ceiling_config(
            CriLinuxContainerResources {
                cpu_period: 100_000,
                cpu_quota: 70_000,
                cpu_shares: 716,
                memory_limit_in_bytes: 384 * 1024 * 1024,
                ..Default::default()
            },
            default_overhead(),
        );
        let v4 = host_resource_ceiling_with_config(&v4, &HashMap::new(), &node).unwrap();
        assert_eq!(v4.cpu_max, "125000 100000");
        assert_eq!(v4.memory_max, "671088640");

        let v5_annotations = HashMap::from([(
            ANNO_VM_RES.to_string(),
            r#"{"cpu":2,"memory":1024}"#.to_string(),
        )]);
        let v5 = host_resource_ceiling_with_config(&v3, &v5_annotations, &node).unwrap();
        assert_eq!(v5.cpu_max, "225000 100000");
        assert_eq!(v5.memory_max, "1342177280");

        // V7 carries no finite Pod PID input into this Host-only budget. V8
        // keeps the same pre-reserved leaf across the workload resize.
        assert_eq!(
            host_resource_ceiling_with_config(&v1, &HashMap::new(), &node)
                .unwrap()
                .pids_max,
            "512"
        );
        let v8_before = host_resource_ceiling_with_config(&v3, &v5_annotations, &node).unwrap();
        let mut v8_after_config = v3.clone();
        let resources = v8_after_config
            .linux
            .as_mut()
            .unwrap()
            .resources
            .as_mut()
            .unwrap();
        resources.cpu_quota = 45_000;
        resources.cpu_shares = 460;
        resources.memory_limit_in_bytes = 240 * 1024 * 1024;
        let v8_after =
            host_resource_ceiling_with_config(&v8_after_config, &v5_annotations, &node).unwrap();
        assert_eq!(v8_before, v8_after);

        let mut v9_overhead = default_overhead();
        v9_overhead.cpu_period = 200_000;
        v9_overhead.cpu_quota = 50_001;
        let v9 = ceiling_config(CriLinuxContainerResources::default(), v9_overhead);
        assert_eq!(
            host_resource_ceiling_with_config(&v9, &HashMap::new(), &node)
                .unwrap()
                .cpu_max,
            "125001 100000"
        );

        let mut v10_overhead = default_overhead();
        v10_overhead.cpu_quota = 50_000;
        v10_overhead.cpu_shares = 512;
        v10_overhead.memory_limit_in_bytes = 512 * 1024 * 1024;
        let v10 = ceiling_config(CriLinuxContainerResources::default(), v10_overhead);
        let v10 = host_resource_ceiling_with_config(&v10, &HashMap::new(), &node).unwrap();
        assert_eq!(v10.cpu_max, "150000 100000");
        assert_eq!(v10.memory_max, "805306368");
    }

    #[test]
    fn runtimeclass_ceiling_rejects_v6_and_v11_before_controller_io() {
        let node = poc_overhead_config();
        let mut missing = ceiling_config(CriLinuxContainerResources::default(), default_overhead());
        missing.linux.as_mut().unwrap().overhead = None;
        assert!(host_resource_ceiling_with_config(&missing, &HashMap::new(), &node).is_err());

        let mut invalid = default_overhead();
        for mutate in 0..5 {
            let mut candidate = invalid.clone();
            match mutate {
                0 => candidate.cpu_quota = 24_900,
                1 => candidate.memory_limit_in_bytes = 255 * 1024 * 1024,
                2 => candidate.memory_limit_in_bytes = 0,
                3 => candidate.cpu_period = 0,
                4 => candidate.cpu_quota = -1,
                _ => unreachable!(),
            }
            let config = ceiling_config(CriLinuxContainerResources::default(), candidate);
            assert!(host_resource_ceiling_with_config(&config, &HashMap::new(), &node).is_err());
        }

        invalid.cpu_period = 1;
        invalid.cpu_quota = i64::MAX;
        let overflow = ceiling_config(CriLinuxContainerResources::default(), invalid);
        assert!(
            host_resource_ceiling_with_config(&overflow, &HashMap::new(), &node)
                .unwrap_err()
                .contains("controller range")
        );
    }

    #[test]
    fn runtimeclass_cpu_minimum_compares_exact_rate_across_periods() {
        let node = poc_overhead_config();
        for (period, exact_quota, below_quota) in [
            (100_000, 25_000, 24_999),
            (200_000, 50_000, 49_999),
            (1_000_000, 250_000, 249_999),
        ] {
            let mut exact = default_overhead();
            exact.cpu_period = period;
            exact.cpu_quota = exact_quota;
            let exact = ceiling_config(CriLinuxContainerResources::default(), exact);
            assert_eq!(
                host_resource_ceiling_with_config(&exact, &HashMap::new(), &node)
                    .unwrap()
                    .cpu_max,
                "125000 100000"
            );

            let mut below = default_overhead();
            below.cpu_period = period;
            below.cpu_quota = below_quota;
            let below = ceiling_config(CriLinuxContainerResources::default(), below);
            assert!(
                host_resource_ceiling_with_config(&below, &HashMap::new(), &node)
                    .unwrap_err()
                    .contains("below node minimum 250m")
            );
        }
    }

    #[test]
    fn runtimeclass_zero_cpu_shares_remain_fingerprint_only() {
        let node = poc_overhead_config();
        let mut overhead = default_overhead();
        overhead.cpu_shares = 0;
        let config = ceiling_config(CriLinuxContainerResources::default(), overhead);
        assert_eq!(
            host_resource_ceiling_with_config(&config, &HashMap::new(), &node)
                .unwrap()
                .cpu_max,
            "125000 100000"
        );
    }

    #[test]
    fn runtimeclass_ceiling_rejects_unsupported_overhead_fields_and_bad_node_config() {
        let node = poc_overhead_config();
        let mut overhead = default_overhead();
        overhead.cpuset_cpus = "0".to_string();
        let config = ceiling_config(CriLinuxContainerResources::default(), overhead);
        assert!(host_resource_ceiling_with_config(&config, &HashMap::new(), &node).is_err());

        let mut overhead = default_overhead();
        overhead
            .unified
            .insert("memory.swap.max".to_string(), "0".to_string());
        let config = ceiling_config(CriLinuxContainerResources::default(), overhead);
        assert!(host_resource_ceiling_with_config(&config, &HashMap::new(), &node).is_err());

        let bad = RuntimeClassOverheadConfig {
            schema_version: 2,
            ..node
        };
        assert!(host_resource_ceiling_with_config(
            &ceiling_config(CriLinuxContainerResources::default(), default_overhead()),
            &HashMap::new(),
            &bad,
        )
        .is_err());
        assert!(serde_json::from_str::<RuntimeClassOverheadConfig>(
            r#"{"schema_version":1,"minimum_cpu_millicores":250,"minimum_memory_bytes":268435456,"host_pids_max":512,"unknown":true}"#
        )
        .is_err());
    }

    #[test]
    fn runtimeclass_node_policy_rejects_pids_above_linux_limit_before_controller_io() {
        let config = ceiling_config(CriLinuxContainerResources::default(), default_overhead());
        let mut node = poc_overhead_config();
        node.host_pids_max = LINUX_PIDS_MAX_LIMIT;
        assert_eq!(
            host_resource_ceiling_with_config(&config, &HashMap::new(), &node)
                .unwrap()
                .pids_max,
            LINUX_PIDS_MAX_LIMIT.to_string()
        );

        for invalid in [LINUX_PIDS_MAX_LIMIT + 1, u64::MAX] {
            node.host_pids_max = invalid;
            assert!(
                host_resource_ceiling_with_config(&config, &HashMap::new(), &node)
                    .unwrap_err()
                    .contains("exceeds Linux numeric pids.max limit")
            );
        }
    }
}
