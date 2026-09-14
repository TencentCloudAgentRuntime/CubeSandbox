// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use std::collections::HashMap;

use containerd_shim::protos::ttrpc::r#async::TtrpcContext;
use tonic::metadata::{Ascii, AsciiMetadataValue, MetadataKey, MetadataMap};
use tonic::Request;
use ttrpc::context::Context;

const TRACE_HEADERS: [&str; 3] = ["traceparent", "tracestate", "baggage"];

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct TraceContext {
    values: HashMap<String, String>,
}

impl TraceContext {
    pub(crate) fn from_ttrpc(ctx: &TtrpcContext) -> Option<Self> {
        let mut values = HashMap::new();
        for key in TRACE_HEADERS {
            let Some(header_values) = ctx.metadata.get(key) else {
                continue;
            };
            let Some(value) = header_values
                .iter()
                .map(|value| value.trim())
                .find(|value| !value.is_empty())
            else {
                continue;
            };
            values.insert(key.to_string(), value.to_string());
        }
        if values.is_empty() {
            None
        } else {
            Some(Self { values })
        }
    }

    pub(crate) fn inject_tonic<T>(&self, request: &mut Request<T>) -> Result<(), String> {
        inject_tonic_metadata(request.metadata_mut(), &self.values)
    }

    pub(crate) fn apply_ttrpc(&self, mut ctx: Context) -> Context {
        for (key, value) in &self.values {
            ctx.set(key.clone(), vec![value.clone()]);
        }
        ctx
    }
}

fn inject_tonic_metadata(
    metadata: &mut MetadataMap,
    values: &HashMap<String, String>,
) -> Result<(), String> {
    for (key, value) in values {
        let name: MetadataKey<Ascii> = key
            .parse()
            .map_err(|error| format!("invalid trace metadata key {key}: {error}"))?;
        let value = AsciiMetadataValue::try_from(value.as_str())
            .map_err(|error| format!("invalid trace metadata value for {key}: {error}"))?;
        metadata.insert(name, value);
    }
    Ok(())
}
