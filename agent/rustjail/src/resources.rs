// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Strict, presence-preserving resource transport for cgroup v2.

use std::collections::BTreeMap;
use std::fmt;

use anyhow::{anyhow, bail, Context, Result};
use oci::LinuxResources;
use protocols::oci as grpc;
use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::{Number, Value};

pub const RESOURCE_V2_VERSION: u32 = 1;
pub const RESOURCE_V2_MEDIA_TYPE: &str = "application/vnd.cubesandbox.oci.linux-resources.v1+json";
pub const RESOURCE_V2_MAX_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, PartialEq)]
enum StrictValue {
    Null,
    Bool(bool),
    Number(Number),
    String(String),
    Array(Vec<StrictValue>),
    Object(BTreeMap<String, StrictValue>),
}

impl StrictValue {
    fn as_object(&self, path: &str) -> Result<&BTreeMap<String, StrictValue>> {
        match self {
            Self::Object(value) => Ok(value),
            _ => bail!("{path} must be a JSON object"),
        }
    }

    fn into_json(self) -> Value {
        match self {
            Self::Null => Value::Null,
            Self::Bool(value) => Value::Bool(value),
            Self::Number(value) => Value::Number(value),
            Self::String(value) => Value::String(value),
            Self::Array(values) => {
                Value::Array(values.into_iter().map(StrictValue::into_json).collect())
            }
            Self::Object(values) => Value::Object(
                values
                    .into_iter()
                    .map(|(key, value)| (key, value.into_json()))
                    .collect(),
            ),
        }
    }
}

struct StrictValueVisitor;

impl<'de> Visitor<'de> for StrictValueVisitor {
    type Value = StrictValue;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON value without duplicate object keys")
    }

    fn visit_bool<E>(self, value: bool) -> Result<Self::Value, E> {
        Ok(StrictValue::Bool(value))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E> {
        Ok(StrictValue::Number(Number::from(value)))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E> {
        Ok(StrictValue::Number(Number::from(value)))
    }

    fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Number::from_f64(value)
            .map(StrictValue::Number)
            .ok_or_else(|| E::custom("non-finite JSON number"))
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Ok(StrictValue::String(value.to_string()))
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
        Ok(StrictValue::String(value))
    }

    fn visit_none<E>(self) -> Result<Self::Value, E> {
        Ok(StrictValue::Null)
    }

    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(StrictValue::Null)
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        let mut values = Vec::new();
        while let Some(value) = sequence.next_element::<StrictValue>()? {
            values.push(value);
        }
        Ok(StrictValue::Array(values))
    }

    fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut values = BTreeMap::new();
        while let Some(key) = map.next_key::<String>()? {
            if values.contains_key(&key) {
                return Err(de::Error::custom(format!(
                    "duplicate JSON object key {key:?}"
                )));
            }
            values.insert(key, map.next_value::<StrictValue>()?);
        }
        Ok(StrictValue::Object(values))
    }
}

impl<'de> Deserialize<'de> for StrictValue {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_any(StrictValueVisitor)
    }
}

fn parse_strict(raw: &[u8]) -> Result<StrictValue> {
    let mut deserializer = serde_json::Deserializer::from_slice(raw);
    let value = StrictValue::deserialize(&mut deserializer)
        .context("strict resources-v2 JSON validation")?;
    deserializer
        .end()
        .context("strict resources-v2 JSON trailing data validation")?;
    Ok(value)
}

fn reject_unknown(
    object: &BTreeMap<String, StrictValue>,
    path: &str,
    allowed: &[&str],
) -> Result<()> {
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            bail!("unknown OCI resource field {path}.{key}");
        }
    }
    Ok(())
}

fn validate_object(value: &StrictValue, path: &str, allowed: &[&str]) -> Result<()> {
    reject_unknown(value.as_object(path)?, path, allowed)
}

fn validate_object_array(value: &StrictValue, path: &str, allowed: &[&str]) -> Result<()> {
    let StrictValue::Array(values) = value else {
        bail!("{path} must be a JSON array");
    };
    for (index, value) in values.iter().enumerate() {
        validate_object(value, &format!("{path}[{index}]"), allowed)?;
    }
    Ok(())
}

fn validate_schema(value: &StrictValue) -> Result<()> {
    let object = value.as_object("resources")?;
    reject_unknown(
        object,
        "resources",
        &[
            "devices",
            "memory",
            "cpu",
            "pids",
            "blockIO",
            "hugepageLimits",
            "network",
            "rdma",
            "unified",
        ],
    )?;

    if object.contains_key("devices") {
        bail!("resources-v2 payload must not contain resources.devices");
    }
    for unsupported in ["blockIO", "network", "rdma"] {
        if object.contains_key(unsupported) {
            bail!("resources.{unsupported} is not supported by resources-v2 version 1");
        }
    }

    if let Some(memory) = object.get("memory") {
        let memory = memory.as_object("resources.memory")?;
        reject_unknown(
            memory,
            "resources.memory",
            &[
                "limit",
                "reservation",
                "swap",
                "kernel",
                "kernelTCP",
                "swappiness",
                "disableOOMKiller",
                "useHierarchy",
                "checkBeforeUpdate",
            ],
        )?;
        for unsupported in [
            "kernel",
            "kernelTCP",
            "swappiness",
            "disableOOMKiller",
            "useHierarchy",
        ] {
            if memory.contains_key(unsupported) {
                bail!("resources.memory.{unsupported} is not supported on cgroup v2");
            }
        }
    }
    if let Some(cpu) = object.get("cpu") {
        let cpu = cpu.as_object("resources.cpu")?;
        reject_unknown(
            cpu,
            "resources.cpu",
            &[
                "shares",
                "quota",
                "burst",
                "period",
                "realtimeRuntime",
                "realtimePeriod",
                "cpus",
                "mems",
                "idle",
            ],
        )?;
        for unsupported in ["burst", "realtimeRuntime", "realtimePeriod", "idle"] {
            if cpu.contains_key(unsupported) {
                bail!("resources.cpu.{unsupported} is not supported by version 1");
            }
        }
    }
    if let Some(pids) = object.get("pids") {
        let pids = pids.as_object("resources.pids")?;
        reject_unknown(pids, "resources.pids", &["limit"])?;
        if !pids.contains_key("limit") {
            bail!("resources.pids.limit is required");
        }
    }
    if let Some(hugepages) = object.get("hugepageLimits") {
        validate_object_array(
            hugepages,
            "resources.hugepageLimits",
            &["pageSize", "limit"],
        )?;
        if let StrictValue::Array(values) = hugepages {
            for (index, value) in values.iter().enumerate() {
                let value = value.as_object(&format!("resources.hugepageLimits[{index}]"))?;
                for field in ["pageSize", "limit"] {
                    if !value.contains_key(field) {
                        bail!("resources.hugepageLimits[{index}].{field} is required");
                    }
                }
            }
        }
    }
    if let Some(unified) = object.get("unified") {
        let unified = unified.as_object("resources.unified")?;
        for (key, value) in unified {
            if !matches!(key.as_str(), "memory.swap.max" | "memory.oom.group") {
                bail!("resources.unified key {key:?} is not supported by version 1");
            }
            if !matches!(value, StrictValue::String(_)) {
                bail!("resources.unified[{key:?}] must be a string");
            }
        }
    }
    Ok(())
}

fn legacy_devices(resources: &grpc::LinuxResources) -> Vec<oci::LinuxDeviceCgroup> {
    resources
        .Devices
        .iter()
        .map(|device| oci::LinuxDeviceCgroup {
            allow: device.Allow,
            r#type: device.Type.clone(),
            major: (device.Major != -1).then_some(device.Major),
            minor: (device.Minor != -1).then_some(device.Minor),
            access: device.Access.clone(),
        })
        .collect()
}

#[derive(Clone, Debug, PartialEq)]
pub struct DecodedResourcesV2 {
    pub resources: LinuxResources,
    pub canonical: Vec<u8>,
}

/// Decode the negotiated V2 envelope. `Ok(None)` is the legacy wire path.
/// V2 controller fields never fall back to proto3 scalar defaults.
pub fn decode_resources_v2(
    resources: &grpc::LinuxResources,
    allow_legacy_devices: bool,
) -> Result<Option<DecodedResourcesV2>> {
    let Some(envelope) = resources.ResourceV2.as_ref() else {
        return Ok(None);
    };
    if envelope.Version != RESOURCE_V2_VERSION {
        bail!(
            "unsupported resources-v2 version {}; expected {}",
            envelope.Version,
            RESOURCE_V2_VERSION
        );
    }
    if envelope.MediaType != RESOURCE_V2_MEDIA_TYPE {
        bail!(
            "unsupported resources-v2 media type {:?}; expected {:?}",
            envelope.MediaType,
            RESOURCE_V2_MEDIA_TYPE
        );
    }
    if envelope.Value.len() > RESOURCE_V2_MAX_BYTES {
        bail!(
            "resources-v2 payload is {} bytes; maximum is {}",
            envelope.Value.len(),
            RESOURCE_V2_MAX_BYTES
        );
    }
    if !allow_legacy_devices && !resources.Devices.is_empty() {
        bail!("resources.devices updates are not supported");
    }

    let strict = parse_strict(&envelope.Value)?;
    validate_schema(&strict)?;
    let json = strict.into_json();
    let canonical = serde_json::to_vec(&json).context("canonicalize resources-v2 payload")?;
    if canonical != envelope.Value {
        bail!("resources-v2 payload is not canonical JSON");
    }
    let mut decoded: LinuxResources =
        serde_json::from_value(json).context("decode resources-v2 OCI schema")?;
    decoded.devices = if allow_legacy_devices {
        legacy_devices(resources)
    } else {
        Vec::new()
    };
    Ok(Some(DecodedResourcesV2 {
        resources: decoded,
        canonical,
    }))
}

pub fn resources_from_grpc(
    resources: &grpc::LinuxResources,
    allow_legacy_devices: bool,
) -> Result<(LinuxResources, Option<Vec<u8>>)> {
    if let Some(decoded) = decode_resources_v2(resources, allow_legacy_devices)? {
        return Ok((decoded.resources, Some(decoded.canonical)));
    }
    Ok((crate::resources_grpc_to_oci(resources), None))
}

pub fn replace_spec_resources_from_grpc(
    spec: &mut oci::Spec,
    grpc_spec: &grpc::Spec,
) -> Result<Option<Vec<u8>>> {
    let Some(grpc_linux) = grpc_spec.Linux.as_ref() else {
        return Ok(None);
    };
    let Some(grpc_resources) = grpc_linux.Resources.as_ref() else {
        return Ok(None);
    };
    if grpc_resources.ResourceV2.is_none() {
        return Ok(None);
    }
    let (resources, canonical) = resources_from_grpc(grpc_resources, true)?;
    let linux = spec
        .linux
        .as_mut()
        .ok_or_else(|| anyhow!("resources-v2 request has no decoded Linux config"))?;
    linux.resources = Some(resources);
    Ok(canonical)
}

pub fn canonical_resources(resources: &LinuxResources) -> Result<Vec<u8>> {
    let mut resources = resources.clone();
    resources.devices.clear();
    let value = serde_json::to_value(resources).context("encode effective resources-v2 state")?;
    serde_json::to_vec(&value).context("canonicalize effective resources-v2 state")
}

#[cfg(test)]
mod tests {
    use super::*;
    use protobuf::MessageField;

    fn request(value: &[u8]) -> grpc::LinuxResources {
        grpc::LinuxResources {
            ResourceV2: MessageField::some(grpc::LinuxResourcesV2 {
                Version: RESOURCE_V2_VERSION,
                MediaType: RESOURCE_V2_MEDIA_TYPE.to_string(),
                Value: value.to_vec(),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn preserves_absent_zero_false_empty_and_unified() {
        let decoded = decode_resources_v2(
            &request(
                br#"{"cpu":{"cpus":"","shares":0},"memory":{"checkBeforeUpdate":false,"limit":0},"unified":{"memory.swap.max":"0"}}"#,
            ),
            true,
        )
        .unwrap()
        .unwrap();
        let cpu = decoded.resources.cpu.unwrap();
        assert_eq!(cpu.shares, Some(0));
        assert_eq!(cpu.cpus.as_deref(), Some(""));
        assert_eq!(cpu.period, None);
        let memory = decoded.resources.memory.unwrap();
        assert_eq!(memory.limit, Some(0));
        assert_eq!(memory.check_before_update, Some(false));
        assert_eq!(decoded.resources.unified["memory.swap.max"], "0");
    }

    #[test]
    fn rejects_duplicate_unknown_and_noncanonical_payloads() {
        for (raw, message) in [
            (
                br#"{"cpu":{"shares":1,"shares":2}}"#.as_slice(),
                "duplicate",
            ),
            (br#"{"cpu":{"future":1}}"#.as_slice(), "unknown"),
            (br#"{ "cpu": {} }"#.as_slice(), "not canonical"),
        ] {
            let error = decode_resources_v2(&request(raw), true).unwrap_err();
            assert!(format!("{error:#}").contains(message), "{error:#}");
        }
    }

    #[test]
    fn rejects_v2_devices_and_update_legacy_devices() {
        let error = decode_resources_v2(&request(br#"{"devices":[]}"#), true).unwrap_err();
        assert!(error.to_string().contains("must not contain"));

        let mut update = request(br#"{}"#);
        update.Devices.push(grpc::LinuxDeviceCgroup::default());
        let error = decode_resources_v2(&update, false).unwrap_err();
        assert!(error.to_string().contains("devices updates"));
    }

    #[test]
    fn v2_merges_only_sanitized_legacy_create_devices() {
        let mut create = request(br#"{}"#);
        create.Devices.push(grpc::LinuxDeviceCgroup {
            Allow: true,
            Type: "a".to_string(),
            Major: -1,
            Minor: -1,
            Access: "rwm".to_string(),
            ..Default::default()
        });
        let decoded = decode_resources_v2(&create, true).unwrap().unwrap();
        assert_eq!(decoded.resources.devices.len(), 1);
        assert_eq!(decoded.resources.devices[0].major, None);
        assert_eq!(decoded.resources.devices[0].minor, None);
    }

    #[test]
    fn malformed_envelope_never_falls_back() {
        let mut wrong_version = request(br#"{}"#);
        wrong_version.ResourceV2.as_mut().unwrap().Version = 2;
        assert!(decode_resources_v2(&wrong_version, true).is_err());

        let mut wrong_media = request(br#"{}"#);
        wrong_media.ResourceV2.as_mut().unwrap().MediaType = "text/plain".to_string();
        assert!(decode_resources_v2(&wrong_media, true).is_err());
    }

    #[test]
    fn required_nested_fields_and_nested_duplicates_are_rejected() {
        for raw in [
            br#"{"pids":{}}"#.as_slice(),
            br#"{"hugepageLimits":[{"pageSize":"2MB"}]}"#.as_slice(),
            br#"{"unified":{"memory.oom.group":"0","memory.oom.group":"1"}}"#.as_slice(),
        ] {
            assert!(decode_resources_v2(&request(raw), true).is_err());
        }
    }
}
