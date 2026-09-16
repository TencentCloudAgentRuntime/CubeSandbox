// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Propagate the containerd ttrpc parent through the shim's RPC boundaries.

use containerd_shim::protos::ttrpc::r#async::TtrpcContext;
use opentelemetry::global;
use opentelemetry::propagation::{Extractor, Injector};
use opentelemetry::sdk::{propagation::TraceContextPropagator, trace::Sampler, Resource};
use opentelemetry::{KeyValue, Context};
use std::collections::HashMap;
use std::future::Future;
use tracing::Instrument;
use tracing_opentelemetry::OpenTelemetrySpanExt;
use tracing_subscriber::layer::SubscriberExt;

struct TtrpcCarrier<'a>(&'a HashMap<String, Vec<String>>);

impl Extractor for TtrpcCarrier<'_> {
    fn get(&self, key: &str) -> Option<&str> {
        self.0.get(key).and_then(|values| values.first().map(String::as_str))
    }

    fn keys(&self) -> Vec<&str> {
        self.0.keys().map(String::as_str).collect()
    }
}

struct MetadataInjector<'a>(&'a mut HashMap<String, Vec<String>>);

impl Injector for MetadataInjector<'_> {
    fn set(&mut self, key: &str, value: String) {
        self.0.insert(key.to_string(), vec![value]);
    }
}

pub(super) fn initialize() -> Result<(), String> {
    let endpoint = match std::env::var("CUBE_CRI_TRACING_OTLP_ENDPOINT") {
        Ok(endpoint) if !endpoint.is_empty() => endpoint,
        _ => return Ok(()),
    };
    let ratio = std::env::var("CUBE_CRI_TRACING_SAMPLING_RATIO")
        .unwrap_or_else(|_| "0.01".to_string())
        .parse::<f64>()
        .map_err(|error| format!("invalid shim tracing sampling ratio: {error}"))?;
    if !(0.0..=1.0).contains(&ratio) {
        return Err("shim tracing sampling ratio must be between 0 and 1".to_string());
    }
    let service = std::env::var("CUBE_CRI_TRACING_SERVICE_NAME")
        .unwrap_or_else(|_| "cube-cri-containerd-shim".to_string());
    // This OTLP crate expects the full HTTP path, while the node setting is
    // the standard collector base endpoint used by containerd.
    let endpoint = if endpoint.trim_end_matches('/').ends_with("/v1/traces") {
        endpoint.trim_end_matches('/').to_string()
    } else {
        format!("{}/v1/traces", endpoint.trim_end_matches('/'))
    };
    let tracer = opentelemetry_otlp::new_pipeline()
        .with_endpoint(endpoint)
        .with_trace_config(
            opentelemetry::sdk::trace::config()
                .with_sampler(Sampler::ParentBased(Box::new(Sampler::TraceIdRatioBased(ratio))))
                .with_resource(Resource::new(vec![KeyValue::new("service.name", service)])),
        )
        .with_http()
        .with_http_client(reqwest::Client::new())
        .install_batch(opentelemetry::runtime::Tokio)
        .map_err(|error| format!("initialize shim tracing: {error}"))?;
    global::set_text_map_propagator(TraceContextPropagator::new());
    tracing::subscriber::set_global_default(
        tracing_subscriber::Registry::default()
            .with(tracing_opentelemetry::OpenTelemetryLayer::new(tracer)),
    )
    .map_err(|error| format!("install shim tracing subscriber: {error}"))?;
    Ok(())
}

pub(super) async fn inbound<F, T, E>(ctx: &TtrpcContext, span: tracing::Span, future: F) -> Result<T, E>
where
    F: Future<Output = Result<T, E>>,
    E: std::fmt::Display,
{
    let parent = global::get_text_map_propagator(|propagator| {
        propagator.extract(&TtrpcCarrier(&ctx.metadata))
    });
    span.set_parent(parent);
    let status_span = span.clone();
    let result = future.instrument(span).await;
    if let Err(error) = &result {
        status_span.record("otel.status_code", &"ERROR");
        status_span.record("otel.status_message", &tracing::field::display(error));
    }
    result
}

fn inject(metadata: &mut HashMap<String, Vec<String>>, context: &Context) {
    global::get_text_map_propagator(|propagator| {
        propagator.inject_context(context, &mut MetadataInjector(metadata));
    });
}

pub(crate) fn agent_context(mut context: ttrpc::context::Context) -> ttrpc::context::Context {
    inject(&mut context.metadata, &tracing::Span::current().context());
    context
}

pub(super) fn tonic_request<T>(message: T) -> tonic::Request<T> {
    let mut request = tonic::Request::new(message);
    let mut metadata = HashMap::new();
    inject(&mut metadata, &tracing::Span::current().context());
    if let Some(value) = metadata.get("traceparent").and_then(|values| values.first()) {
        if let Ok(value) = value.parse() {
            request.metadata_mut().insert("traceparent", value);
        }
    }
    if let Some(value) = metadata.get("tracestate").and_then(|values| values.first()) {
        if let Ok(value) = value.parse() {
            request.metadata_mut().insert("tracestate", value);
        }
    }
    request
}

#[cfg(test)]
mod tests {
    use super::*;
    use opentelemetry::trace::{SpanId, TraceContextExt, TraceId, TRACE_FLAG_SAMPLED};

    #[test]
    fn ttrpc_traceparent_is_extracted_and_injected() {
        global::set_text_map_propagator(TraceContextPropagator::new());
        let mut metadata = HashMap::new();
        metadata.insert("traceparent".to_string(), vec!["00-0123456789abcdef0123456789abcdef-0123456789abcdef-01".to_string()]);
        let parent = global::get_text_map_propagator(|p| p.extract(&TtrpcCarrier(&metadata)));
        let mut outbound = HashMap::new();
        inject(&mut outbound, &parent);
        assert_eq!(outbound.get("traceparent"), metadata.get("traceparent"));
        let span = parent.span();
        let remote = span.span_context();
        assert_eq!(remote.trace_id(), TraceId::from_hex("0123456789abcdef0123456789abcdef"));
        assert_eq!(remote.span_id(), SpanId::from_hex("0123456789abcdef"));
        assert_eq!(remote.trace_flags(), TRACE_FLAG_SAMPLED);
    }
}
