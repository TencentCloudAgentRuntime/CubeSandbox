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

/// Stable Pod-local translation from kubelet's host CPU/NUMA identifiers to
/// the dense identifiers exposed by a Cube guest. Host identifiers are not
/// meaningful inside the VM, but equality and separation between container
/// assignments must survive the boundary (notably for CPU Manager).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct PodCpusetMapper {
    cpus: BTreeMap<u32, u32>,
    mems: BTreeMap<u32, u32>,
}

fn parse_cpuset_ids(value: &str, maximum_items: usize, field: &str) -> CResult<Vec<u32>> {
    let mut ranges = Vec::new();
    for component in value.split(',') {
        if component.is_empty() {
            return Err(format!("empty {field} component in {value:?}"));
        }
        let mut bounds = component.split('-');
        let first = bounds
            .next()
            .expect("split always returns one component")
            .parse::<u32>()
            .map_err(|error| format!("invalid {field} component {component:?}: {error}"))?;
        let last = match bounds.next() {
            Some(last) => last
                .parse::<u32>()
                .map_err(|error| format!("invalid {field} component {component:?}: {error}"))?,
            None => first,
        };
        if bounds.next().is_some() || first > last {
            return Err(format!("invalid {field} range {component:?}"));
        }
        ranges.push((first, last));
    }
    ranges.sort_unstable();

    let mut merged: Vec<(u32, u32)> = Vec::with_capacity(ranges.len());
    for (start, end) in ranges {
        if let Some(previous) = merged.last_mut() {
            if start <= previous.1.saturating_add(1) {
                previous.1 = previous.1.max(end);
                continue;
            }
        }
        merged.push((start, end));
    }

    let count = merged.iter().try_fold(0_u64, |count, (start, end)| {
        count.checked_add(u64::from(*end) - u64::from(*start) + 1)
    });
    let count = count.ok_or_else(|| format!("{field} cardinality overflows"))?;
    if count > maximum_items as u64 {
        return Err(format!(
            "{field} requests {count} identifiers but Cube exposes {maximum_items}"
        ));
    }

    let mut ids = Vec::with_capacity(count as usize);
    for (start, end) in merged {
        ids.extend(start..=end);
    }
    Ok(ids)
}

fn format_cpuset_ids(mut ids: Vec<u32>) -> String {
    ids.sort_unstable();
    ids.dedup();
    let mut ranges = Vec::new();
    let mut index = 0;
    while index < ids.len() {
        let start = ids[index];
        let mut end = start;
        index += 1;
        while index < ids.len() && ids[index] == end.saturating_add(1) {
            end = ids[index];
            index += 1;
        }
        if start == end {
            ranges.push(start.to_string());
        } else {
            ranges.push(format!("{start}-{end}"));
        }
    }
    ranges.join(",")
}

fn remap_cpuset(
    mapping: &mut BTreeMap<u32, u32>,
    value: &str,
    guest_count: u32,
    field: &str,
) -> CResult<String> {
    if value.is_empty() {
        return Ok(String::new());
    }
    if guest_count == 0 {
        return Err(format!(
            "cannot translate non-empty {field} {value:?}: Cube exposes no identifiers"
        ));
    }
    // A CPU Manager shared-pool assignment commonly contains most CPUs on the
    // host and is therefore larger than the VM. Its correct VM-local meaning
    // is "all guest identifiers" and it must not consume exclusive mappings.
    // Keep a hard expansion bound for malformed or adversarial OCI input.
    let source = parse_cpuset_ids(value, 65_536, field)?;
    if source.len() > guest_count as usize {
        return Ok(format_cpuset_ids((0..guest_count).collect()));
    }
    let mut candidate = mapping.clone();
    let mut used = candidate
        .values()
        .copied()
        .collect::<std::collections::BTreeSet<_>>();
    let mut translated = Vec::with_capacity(source.len());
    for source_id in source {
        let guest_id = match candidate.get(&source_id).copied() {
            Some(guest_id) if guest_id < guest_count => guest_id,
            Some(guest_id) => {
                return Err(format!(
                    "existing {field} mapping {source_id}->{guest_id} is outside Cube identifier count {guest_count}"
                ))
            }
            None => {
                let guest_id = (0..guest_count)
                    .find(|guest_id| !used.contains(guest_id))
                    .ok_or_else(|| {
                        format!(
                            "cannot translate {field} {value:?}: all {guest_count} Cube identifiers are already mapped"
                        )
                    })?;
                candidate.insert(source_id, guest_id);
                used.insert(guest_id);
                guest_id
            }
        };
        translated.push(guest_id);
    }
    *mapping = candidate;
    Ok(format_cpuset_ids(translated))
}

impl PodCpusetMapper {
    /// Rewrite only non-empty CPU Manager assignments in an already validated
    /// resources-v2 payload. Commit CPU and NUMA state only after the complete
    /// payload has been translated successfully.
    pub(crate) fn remap_payload(
        &mut self,
        payload: &[u8],
        guest_cpu_count: u32,
        guest_numa_count: u32,
    ) -> CResult<Vec<u8>> {
        let mut resources = parse_strict(payload, "resources-v2 cpuset")?;
        validate_resources(&resources, "resources")?;
        let mut candidate = self.clone();
        if let StrictValue::Object(resources) = &mut resources {
            if let Some(StrictValue::Object(cpu)) = resources.get_mut("cpu") {
                for (field, mapping, guest_count) in [
                    ("cpus", &mut candidate.cpus, guest_cpu_count),
                    ("mems", &mut candidate.mems, guest_numa_count),
                ] {
                    let Some(value) = cpu.get_mut(field) else {
                        continue;
                    };
                    let StrictValue::String(source) = value else {
                        return Err(format!("resources.cpu.{field} must be a string"));
                    };
                    if !source.is_empty() {
                        *source = remap_cpuset(mapping, source, guest_count, field)?;
                    }
                }
            }
        }
        let payload = canonical_payload(resources)?;
        *self = candidate;
        Ok(payload)
    }
}

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
    let mut resources = parse_strict(raw, "Task.Update resources")?;
    validate_resources(&resources, "resources")?;
    // CRI UpdateContainerResources cannot express the OCI
    // checkBeforeUpdate field. For a Kubernetes-managed sandbox, make an
    // absent value safe by default whenever a finite memory limit is being
    // changed: reject below-current downsizes before touching any controller
    // instead of allowing a synchronous kernel reclaim to outlive the Agent
    // RPC deadline. An explicit true/false from a lower-level Task client is
    // still preserved verbatim.
    if let StrictValue::Object(resources) = &mut resources {
        if let Some(StrictValue::Object(memory)) = resources.get_mut("memory") {
            if memory.contains_key("limit") && !memory.contains_key("checkBeforeUpdate") {
                memory.insert("checkBeforeUpdate".to_string(), StrictValue::Bool(true));
            }
        }
    }
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
        assert_eq!(
            payload,
            br#"{"memory":{"checkBeforeUpdate":true,"limit":1048576}}"#
        );
    }

    #[test]
    fn managed_memory_update_defaults_to_precheck_but_preserves_explicit_policy() {
        let defaulted = canonicalize_update(br#"{"memory":{"limit":67108864}}"#).unwrap();
        assert_eq!(
            defaulted,
            br#"{"memory":{"checkBeforeUpdate":true,"limit":67108864}}"#
        );

        let explicit_false =
            canonicalize_update(br#"{"memory":{"checkBeforeUpdate":false,"limit":67108864}}"#)
                .unwrap();
        assert_eq!(
            explicit_false,
            br#"{"memory":{"checkBeforeUpdate":false,"limit":67108864}}"#
        );

        let reservation_only =
            canonicalize_update(br#"{"memory":{"reservation":33554432}}"#).unwrap();
        assert_eq!(reservation_only, br#"{"memory":{"reservation":33554432}}"#);
    }

    #[test]
    fn pod_cpuset_remap_preserves_cpu_manager_identity_and_separation() {
        let mut mapper = PodCpusetMapper::default();
        let init = mapper
            .remap_payload(br#"{"cpu":{"cpus":"1","mems":"0"}}"#, 2, 1)
            .unwrap();
        let sidecar = mapper
            .remap_payload(br#"{"cpu":{"cpus":"1","mems":"0"}}"#, 2, 1)
            .unwrap();
        let regular = mapper
            .remap_payload(br#"{"cpu":{"cpus":"2","mems":"0"}}"#, 2, 1)
            .unwrap();

        assert_eq!(init, br#"{"cpu":{"cpus":"0","mems":"0"}}"#);
        assert_eq!(sidecar, init);
        assert_eq!(regular, br#"{"cpu":{"cpus":"1","mems":"0"}}"#);
    }

    #[test]
    fn pod_cpuset_remap_normalizes_ranges_and_is_atomic_on_exhaustion() {
        let mut mapper = PodCpusetMapper::default();
        let first = mapper
            .remap_payload(br#"{"cpu":{"cpus":"4,6-7","mems":"3"}}"#, 3, 1)
            .unwrap();
        assert_eq!(first, br#"{"cpu":{"cpus":"0-2","mems":"0"}}"#);
        let subset = mapper
            .remap_payload(br#"{"cpu":{"cpus":"7,4","mems":"3"}}"#, 3, 1)
            .unwrap();
        assert_eq!(subset, br#"{"cpu":{"cpus":"0,2","mems":"0"}}"#);

        let before = mapper.clone();
        let error = mapper
            .remap_payload(br#"{"cpu":{"cpus":"8"}}"#, 3, 1)
            .unwrap_err();
        assert!(error.contains("already mapped"), "{error}");
        assert_eq!(mapper, before);
    }

    #[test]
    fn pod_cpuset_remap_preserves_absent_and_explicit_empty_fields() {
        let mut mapper = PodCpusetMapper::default();
        assert_eq!(mapper.remap_payload(br#"{}"#, 2, 1).unwrap(), br#"{}"#);
        assert_eq!(
            mapper
                .remap_payload(br#"{"cpu":{"cpus":"","mems":""}}"#, 2, 1)
                .unwrap(),
            br#"{"cpu":{"cpus":"","mems":""}}"#
        );
        assert_eq!(mapper, PodCpusetMapper::default());
    }

    #[test]
    fn pod_cpuset_remap_maps_host_shared_pool_to_all_guest_cpus() {
        let mut mapper = PodCpusetMapper::default();
        let shared = mapper
            .remap_payload(br#"{"cpu":{"cpus":"0,3-15"}}"#, 2, 1)
            .unwrap();
        assert_eq!(shared, br#"{"cpu":{"cpus":"0-1"}}"#);
        assert_eq!(mapper, PodCpusetMapper::default());

        let exclusive = mapper
            .remap_payload(br#"{"cpu":{"cpus":"9"}}"#, 2, 1)
            .unwrap();
        assert_eq!(exclusive, br#"{"cpu":{"cpus":"0"}}"#);
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
