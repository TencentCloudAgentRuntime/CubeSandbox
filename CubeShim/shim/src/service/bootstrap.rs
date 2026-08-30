// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! containerd 2.3 bootstrap-v1 wire messages.
//!
//! `containerd-shim` 0.11 still exposes the legacy string-returning start
//! interface. containerd 2.3 writes and expects binary protobuf messages, so
//! CubeShim owns this small adapter until the Rust shim crate exposes the new
//! manager API. Unknown extension fields are deliberately ignored by prost.

use prost::Message;
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::path::Path;

pub const MAX_BOOTSTRAP_BYTES: u64 = 10 << 20;
pub const SHIM_API_VERSION: i32 = 3;

#[derive(Clone, PartialEq, Message)]
pub struct BootstrapParams {
    #[prost(string, tag = "1")]
    pub instance_id: String,
    #[prost(string, tag = "2")]
    pub namespace: String,
    #[prost(int32, tag = "3")]
    pub log_level: i32,
    #[prost(string, tag = "4")]
    pub containerd_version: String,
    #[prost(string, tag = "5")]
    pub containerd_ttrpc_address: String,
    #[prost(string, tag = "6")]
    pub containerd_grpc_address: String,
    #[prost(string, tag = "7")]
    pub containerd_binary: String,
    // Field 8 is repeated Extension. It is not interpreted by S1.1.
    #[prost(string, optional, tag = "9")]
    pub socket_dir: Option<String>,
}

impl BootstrapParams {
    pub fn read_from(mut reader: impl Read) -> io::Result<Self> {
        let mut data = Vec::new();
        reader
            .by_ref()
            .take(MAX_BOOTSTRAP_BYTES + 1)
            .read_to_end(&mut data)?;
        if data.len() as u64 > MAX_BOOTSTRAP_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "bootstrap input exceeds 10 MiB",
            ));
        }
        let params = Self::decode(data.as_slice()).map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("decode bootstrap params: {error}"),
            )
        })?;
        params.validate()?;
        Ok(params)
    }

    fn validate(&self) -> io::Result<()> {
        for (name, value) in [
            ("instance_id", self.instance_id.as_str()),
            ("namespace", self.namespace.as_str()),
            (
                "containerd_ttrpc_address",
                self.containerd_ttrpc_address.as_str(),
            ),
            (
                "containerd_grpc_address",
                self.containerd_grpc_address.as_str(),
            ),
        ] {
            if value.trim().is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("bootstrap {name} is empty"),
                ));
            }
        }
        if let Some(socket_dir) = self.socket_dir.as_deref() {
            if socket_dir.is_empty() || !Path::new(socket_dir).is_absolute() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "bootstrap socket_dir must be an absolute path",
                ));
            }
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Message)]
pub struct BootstrapResult {
    #[prost(int32, tag = "1")]
    pub version: i32,
    #[prost(string, tag = "2")]
    pub address: String,
    #[prost(string, tag = "3")]
    pub protocol: String,
    #[prost(int32, repeated, tag = "4")]
    pub capabilities: Vec<i32>,
    #[prost(map = "string, string", tag = "5")]
    pub metadata: HashMap<String, String>,
}

impl BootstrapResult {
    pub fn ttrpc(address: String) -> Self {
        Self {
            version: SHIM_API_VERSION,
            address,
            protocol: "ttrpc".to_string(),
            capabilities: Vec::new(),
            metadata: HashMap::new(),
        }
    }

    pub fn write_to(&self, mut writer: impl Write) -> io::Result<()> {
        let mut data = Vec::with_capacity(self.encoded_len());
        self.encode(&mut data).map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("encode bootstrap result: {error}"),
            )
        })?;
        writer.write_all(&data)?;
        writer.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn params() -> BootstrapParams {
        BootstrapParams {
            instance_id: "sandbox-1".to_string(),
            namespace: "k8s.io".to_string(),
            log_level: -4,
            containerd_version: "2.3.4".to_string(),
            containerd_ttrpc_address: "unix:///run/containerd/containerd.sock.ttrpc".to_string(),
            containerd_grpc_address: "unix:///run/containerd/containerd.sock".to_string(),
            containerd_binary: "/usr/bin/containerd".to_string(),
            socket_dir: Some("/run/containerd/s".to_string()),
        }
    }

    #[test]
    fn decodes_containerd_wire_fields() {
        let expected = params();
        let data = expected.encode_to_vec();
        let decoded = BootstrapParams::read_from(Cursor::new(data)).unwrap();
        assert_eq!(decoded, expected);
    }

    #[test]
    fn rejects_missing_identity() {
        let mut input = params();
        input.instance_id.clear();
        let error = BootstrapParams::read_from(Cursor::new(input.encode_to_vec())).unwrap_err();
        assert!(error.to_string().contains("instance_id is empty"));
    }

    #[test]
    fn rejects_relative_socket_dir() {
        let mut input = params();
        input.socket_dir = Some("run/containerd/s".to_string());
        let error = BootstrapParams::read_from(Cursor::new(input.encode_to_vec())).unwrap_err();
        assert!(error.to_string().contains("absolute path"));
    }

    #[test]
    fn rejects_oversized_input() {
        let input = vec![0_u8; (MAX_BOOTSTRAP_BYTES + 1) as usize];
        let error = BootstrapParams::read_from(Cursor::new(input)).unwrap_err();
        assert!(error.to_string().contains("exceeds 10 MiB"));
    }

    #[test]
    fn writes_v3_ttrpc_result() {
        let result = BootstrapResult::ttrpc("unix:///run/containerd/s/hash".to_string());
        let mut wire = Vec::new();
        result.write_to(&mut wire).unwrap();
        let decoded = BootstrapResult::decode(wire.as_slice()).unwrap();
        assert_eq!(decoded.version, 3);
        assert_eq!(decoded.protocol, "ttrpc");
        assert_eq!(decoded.address, "unix:///run/containerd/s/hash");
    }
}
