// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Presence-preserving resource transport for Kubernetes-managed sandboxes.
//!
//! The raw parser deliberately runs before `serde_json::Value` and
//! `oci_spec` deserialization. Both of those representations can erase input
//! (most importantly duplicate map keys or unknown typed fields), which would
//! make a fail-closed transport impossible.

use std::collections::BTreeMap;
use std::fmt;

use serde::de::{self, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::{Number, Value};

use crate::common::CResult;
use protoc::oci;

pub(crate) const RESOURCE_V2_VERSION: u32 = 1;
pub(crate) const RESOURCE_V2_MEDIA_TYPE: &str =
    "application/vnd.cubesandbox.oci.linux-resources.v1+json";
pub(crate) const RESOURCE_V2_MAX_BYTES: usize = 256 * 1024;
pub(crate) const RESOURCE_V2_CAPABILITY: &str = "io.cubesandbox.agent.container.resources-v2";
pub(crate) const OCI_LINUX_RESOURCES_TYPE_URL: &str =
    "types.containerd.io/opencontainers/runtime-spec/1/LinuxResources";

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
    fn as_object(&self, path: &str) -> CResult<&BTreeMap<String, StrictValue>> {
        match self {
            Self::Object(value) => Ok(value),
            _ => Err(format!("{path} must be a JSON object")),
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
            let value = map.next_value::<StrictValue>()?;
            values.insert(key, value);
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

fn parse_strict(raw: &[u8], label: &str) -> CResult<StrictValue> {
    let mut deserializer = serde_json::Deserializer::from_slice(raw);
    let value = StrictValue::deserialize(&mut deserializer)
        .map_err(|error| format!("strict {label} JSON validation failed: {error}"))?;
    deserializer
        .end()
        .map_err(|error| format!("strict {label} JSON validation failed: {error}"))?;
    Ok(value)
}

fn reject_unknown(
    object: &BTreeMap<String, StrictValue>,
    path: &str,
    allowed: &[&str],
) -> CResult<()> {
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(format!("unknown OCI resource field {path}.{key}"));
        }
    }
    Ok(())
}

fn validate_object(value: &StrictValue, path: &str, allowed: &[&str]) -> CResult<()> {
    reject_unknown(value.as_object(path)?, path, allowed)
}

fn validate_object_array(value: &StrictValue, path: &str, allowed: &[&str]) -> CResult<()> {
    let StrictValue::Array(values) = value else {
        return Err(format!("{path} must be a JSON array"));
    };
    for (index, value) in values.iter().enumerate() {
        validate_object(value, &format!("{path}[{index}]"), allowed)?;
    }
    Ok(())
}

fn validate_block_io(value: &StrictValue, path: &str) -> CResult<()> {
    let object = value.as_object(path)?;
    reject_unknown(
        object,
        path,
        &[
            "weight",
            "leafWeight",
            "weightDevice",
            "throttleReadBpsDevice",
            "throttleWriteBpsDevice",
            "throttleReadIOPSDevice",
            "throttleWriteIOPSDevice",
        ],
    )?;
    if let Some(value) = object.get("weightDevice") {
        validate_object_array(
            value,
            &format!("{path}.weightDevice"),
            &["major", "minor", "weight", "leafWeight"],
        )?;
    }
    for field in [
        "throttleReadBpsDevice",
        "throttleWriteBpsDevice",
        "throttleReadIOPSDevice",
        "throttleWriteIOPSDevice",
    ] {
        if let Some(value) = object.get(field) {
            validate_object_array(
                value,
                &format!("{path}.{field}"),
                &["major", "minor", "rate"],
            )?;
        }
    }
    Ok(())
}

fn validate_network(value: &StrictValue, path: &str) -> CResult<()> {
    let object = value.as_object(path)?;
    reject_unknown(object, path, &["classID", "priorities"])?;
    if let Some(value) = object.get("priorities") {
        validate_object_array(value, &format!("{path}.priorities"), &["name", "priority"])?;
    }
    Ok(())
}

fn validate_rdma(value: &StrictValue, path: &str) -> CResult<()> {
    let object = value.as_object(path)?;
    for (device, limit) in object {
        validate_object(
            limit,
            &format!("{path}.{device}"),
            &["hcaHandles", "hcaObjects"],
        )?;
    }
    Ok(())
}

fn validate_resources(value: &StrictValue, path: &str) -> CResult<()> {
    let object = value.as_object(path)?;
    reject_unknown(
        object,
        path,
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

    if let Some(value) = object.get("devices") {
        validate_object_array(
            value,
            &format!("{path}.devices"),
            &["allow", "type", "major", "minor", "access"],
        )?;
    }
    if let Some(value) = object.get("memory") {
        validate_object(
            value,
            &format!("{path}.memory"),
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
    }
    if let Some(value) = object.get("cpu") {
        validate_object(
            value,
            &format!("{path}.cpu"),
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
    }
    if let Some(value) = object.get("pids") {
        validate_object(value, &format!("{path}.pids"), &["limit"])?;
    }
    if let Some(value) = object.get("blockIO") {
        validate_block_io(value, &format!("{path}.blockIO"))?;
    }
    if let Some(value) = object.get("hugepageLimits") {
        validate_object_array(
            value,
            &format!("{path}.hugepageLimits"),
            &["pageSize", "limit"],
        )?;
    }
    if let Some(value) = object.get("network") {
        validate_network(value, &format!("{path}.network"))?;
    }
    if let Some(value) = object.get("rdma") {
        validate_rdma(value, &format!("{path}.rdma"))?;
    }
    if let Some(value) = object.get("unified") {
        value.as_object(&format!("{path}.unified"))?;
    }
    Ok(())
}

fn canonical_payload(mut resources: StrictValue) -> CResult<Vec<u8>> {
    // Devices remain on the already-reviewed S3.3 protobuf path and may not
    // be smuggled through the V2 controller payload.
    if let StrictValue::Object(object) = &mut resources {
        object.remove("devices");
    }
    let payload = serde_json::to_vec(&resources.into_json())
        .map_err(|error| format!("encode canonical OCI resources failed: {error}"))?;
    if payload.len() > RESOURCE_V2_MAX_BYTES {
        return Err(format!(
            "canonical OCI resources payload is {} bytes; maximum is {}",
            payload.len(),
            RESOURCE_V2_MAX_BYTES
        ));
    }
    Ok(payload)
}

pub(crate) fn canonicalize_create_config(raw: &[u8]) -> CResult<Vec<u8>> {
    let config = parse_strict(raw, "create config.json")?;
    let root = config.as_object("config")?;
    let Some(linux) = root.get("linux") else {
        return canonical_payload(StrictValue::Object(BTreeMap::new()));
    };
    if matches!(linux, StrictValue::Null) {
        return canonical_payload(StrictValue::Object(BTreeMap::new()));
    }
    let linux = linux.as_object("config.linux")?;
    let Some(resources) = linux.get("resources") else {
        return canonical_payload(StrictValue::Object(BTreeMap::new()));
    };
    if matches!(resources, StrictValue::Null) {
        return canonical_payload(StrictValue::Object(BTreeMap::new()));
    }
    validate_resources(resources, "config.linux.resources")?;
    canonical_payload(resources.clone())
}

pub(crate) fn canonicalize_update(raw: &[u8]) -> CResult<Vec<u8>> {
    let resources = parse_strict(raw, "Task.Update resources")?;
    validate_resources(&resources, "resources")?;
    canonical_payload(resources)
}

pub(crate) fn envelope(payload: Vec<u8>) -> oci::LinuxResourcesV2 {
    let mut value = oci::LinuxResourcesV2::new();
    value.set_version(RESOURCE_V2_VERSION);
    value.set_mediaType(RESOURCE_V2_MEDIA_TYPE.to_string());
    value.set_value(payload);
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_preserves_presence_sorts_keys_and_removes_devices() {
        let raw = br#"{
            "ociVersion":"1.2.0",
            "linux":{"resources":{
                "unified":{"memory.swap.max":"0"},
                "memory":{"checkBeforeUpdate":false,"limit":0},
                "cpu":{"shares":0,"cpus":""},
                "devices":[{"allow":true,"access":"rwm"}]
            }}
        }"#;
        let payload = canonicalize_create_config(raw).unwrap();
        assert_eq!(
            std::str::from_utf8(&payload).unwrap(),
            r#"{"cpu":{"cpus":"","shares":0},"memory":{"checkBeforeUpdate":false,"limit":0},"unified":{"memory.swap.max":"0"}}"#
        );
    }

    #[test]
    fn managed_create_without_resources_still_sends_empty_v2_payload() {
        let payload = canonicalize_create_config(br#"{"ociVersion":"1.2.0","linux":{}}"#).unwrap();
        assert_eq!(payload, b"{}");
    }

    #[test]
    fn rejects_duplicate_at_any_create_depth() {
        for raw in [
            br#"{"ociVersion":"1.2.0","ociVersion":"1.1.0"}"#.as_slice(),
            br#"{"linux":{"resources":{"cpu":{"shares":2,"shares":4}}}}"#.as_slice(),
            br#"{"linux":{"resources":{"unified":{"memory.swap.max":"0","memory.swap.max":"max"}}}}"#.as_slice(),
        ] {
            let error = canonicalize_create_config(raw).unwrap_err();
            assert!(error.contains("duplicate JSON object key"), "{error}");
        }
    }

    #[test]
    fn rejects_nested_unknown_create_field() {
        let error = canonicalize_create_config(
            br#"{"linux":{"resources":{"memory":{"limit":1,"futureLimit":2}}}}"#,
        )
        .unwrap_err();
        assert!(error.contains("config.linux.resources.memory.futureLimit"));
    }

    #[test]
    fn update_rejects_structural_and_unified_duplicates() {
        for raw in [
            br#"{"cpu":{"period":1000},"cpu":{"quota":2000}}"#.as_slice(),
            br#"{"unified":{"memory.oom.group":"0","memory.oom.group":"1"}}"#.as_slice(),
        ] {
            let error = canonicalize_update(raw).unwrap_err();
            assert!(error.contains("duplicate JSON object key"), "{error}");
        }
    }

    #[test]
    fn update_rejects_nested_unknown_field() {
        let error = canonicalize_update(br#"{"cpu":{"period":1000,"future":1}}"#).unwrap_err();
        assert!(error.contains("resources.cpu.future"));
    }

    #[test]
    fn update_strips_devices_from_v2_controller_payload() {
        let payload = canonicalize_update(
            br#"{"memory":{"limit":1048576},"devices":[{"allow":true,"access":"rwm"}]}"#,
        )
        .unwrap();
        assert_eq!(payload, br#"{"memory":{"limit":1048576}}"#);
    }

    #[test]
    fn envelope_is_versioned_and_bounded() {
        let payload = canonicalize_update(br#"{"pids":{"limit":0}}"#).unwrap();
        let value = envelope(payload.clone());
        assert_eq!(value.get_version(), RESOURCE_V2_VERSION);
        assert_eq!(value.get_mediaType(), RESOURCE_V2_MEDIA_TYPE);
        assert_eq!(value.get_value(), payload.as_slice());
    }
}
