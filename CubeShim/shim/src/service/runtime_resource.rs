// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Client for Cubelet's node-resources-only RuntimeResource v1 service.

use hyper_util::rt::TokioIo;
use nix::cmsg_space;
use nix::sys::socket::{recvmsg, ControlMessageOwned, MsgFlags};
use oci_spec::runtime::Spec;
use prost::Message;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{IoSliceMut, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::path::Path;
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
const CRI_V1_POD_SANDBOX_CONFIG: &str = "runtime.v1.PodSandboxConfig";

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
    #[prost(message, optional, tag = "5")]
    resources: Option<CriLinuxContainerResources>,
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

#[derive(Clone, Debug)]
pub(crate) struct RuntimeLease {
    endpoint: String,
    pub(crate) sandbox: PreparedSandbox,
}

impl RuntimeLease {
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
        Ok(())
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

pub(crate) fn merge_cri_annotations(
    spec: &mut Spec,
    config: &CriPodSandboxConfig,
    request_annotations: &HashMap<String, String>,
) -> Result<(), String> {
    let metadata = pod_metadata(config)?;
    let mut annotations = spec.annotations().as_ref().cloned().unwrap_or_default();
    annotations.extend(config.annotations.clone());
    annotations.extend(request_annotations.clone());
    annotations.insert(ANNO_SANDBOX_UID.to_string(), metadata.uid.clone());
    annotations.insert(
        ANNO_SANDBOX_NAMESPACE.to_string(),
        metadata.namespace.clone(),
    );
    annotations.insert(ANNO_SANDBOX_NAME.to_string(), metadata.name.clone());
    spec.set_annotations(Some(annotations));
    Ok(())
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
    let request = PrepareSandboxRequest {
        sandbox_id: sandbox_id.to_string(),
        idempotency_key: prepare_key(sandbox_id, generation),
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
            dns: config
                .dns_config
                .as_ref()
                .map(|dns| dns.servers.clone())
                .unwrap_or_default(),
        }),
    };
    let response: PrepareSandboxResponse = client
        .unary(
            request,
            "/cubelet.services.runtime.v1.RuntimeResource/PrepareSandbox",
        )
        .await?;
    let sandbox = response
        .sandbox
        .ok_or_else(|| "Cubelet returned no prepared sandbox".to_string())?;
    validate_prepared(sandbox_id, generation, &sandbox)?;
    inject_annotations(spec, &resources, &sandbox)?;
    Ok(RuntimeLease { endpoint, sandbox })
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
    sandbox: &PreparedSandbox,
) -> Result<(), String> {
    if sandbox.sandbox_id != sandbox_id
        || sandbox.generation != generation
        || sandbox.lease_id.is_empty()
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
    if !Path::new(&assets.shared_root).starts_with(VIRTIOFS_SHARED_DIR) {
        return Err(format!(
            "RuntimeResource shared root {} is outside {}",
            assets.shared_root, VIRTIOFS_SHARED_DIR
        ));
    }
    Ok(())
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
    let (received, descriptors) = {
        let message = recvmsg::<()>(
            stream.as_raw_fd(),
            &mut iov,
            Some(&mut control),
            MsgFlags::empty(),
        )
        .map_err(|error| format!("receive FD handoff response: {error}"))?;
        let received = message.bytes;
        let mut descriptors = Vec::new();
        for control_message in message
            .cmsgs()
            .map_err(|error| format!("decode FD handoff control message: {error}"))?
        {
            if let ControlMessageOwned::ScmRights(rights) = control_message {
                descriptors.extend(rights);
            }
        }
        (received, descriptors)
    };
    drop(iov);
    if received != header.len() {
        close_raw_fds(&descriptors);
        return Err(format!("short FD handoff response header: {received}"));
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
    fn retry_keys_are_stable_and_operation_scoped() {
        let sandbox = PreparedSandbox {
            sandbox_id: "sandbox-a".to_string(),
            lease_id: "lease-a".to_string(),
            generation: 1,
            ..Default::default()
        };
        assert_eq!(prepare_key("sandbox-a", 1), prepare_key("sandbox-a", 1));
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
            linux: Some(CriLinuxPodSandboxConfig {
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
        assert_eq!(annotations["pod.example/key"], "value");
        assert_eq!(annotations["request.example/key"], "request");
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
