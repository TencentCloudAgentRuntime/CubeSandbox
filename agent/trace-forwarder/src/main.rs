// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Receive the cube-agent's length-prefixed bincode spans and export OTLP/HTTP.

use anyhow::{Context, Result};
use opentelemetry::sdk::export::trace::{SpanData, SpanExporter};
use opentelemetry::{Key, KeyValue, Value};
use opentelemetry_otlp::{ExporterConfig, HttpConfig, Protocol, TraceExporter};
use std::convert::TryFrom;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::sync::mpsc;
use tokio_vsock::{VsockAddr, VsockListener, VsockStream};

const PORT: u32 = 10240;
const MAX_SPAN_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Debug)]
struct CheckedHttpClient(reqwest::Client);

#[async_trait::async_trait]
impl opentelemetry_http::HttpClient for CheckedHttpClient {
    async fn send(
        &self,
        request: http::Request<Vec<u8>>,
    ) -> Result<http::Response<bytes::Bytes>, opentelemetry_http::HttpError> {
        let response = opentelemetry_http::HttpClient::send(&self.0, request).await?;
        if !response.status().is_success() {
            return Err(std::io::Error::other(format!(
                "collector returned HTTP {}",
                response.status()
            ))
            .into());
        }
        Ok(response)
    }
}

async fn receive(mut stream: VsockStream, sender: mpsc::Sender<SpanData>) -> Result<()> {
    loop {
        let mut header = [0u8; 8];
        if stream.read_exact(&mut header).await.is_err() {
            return Ok(());
        }
        let size = u64::from_be_bytes(header);
        if size == 0 || size > MAX_SPAN_BYTES {
            anyhow::bail!("invalid guest span size: {size}");
        }
        let mut bytes = vec![0u8; size as usize];
        stream.read_exact(&mut bytes).await?;
        let mut span: SpanData = bincode::deserialize(&bytes)?;
        if let Err(reason) = normalize_span_timestamps(&mut span) {
            eprintln!("dropping guest span with invalid timestamp: {reason}");
            continue;
        }
        sender.send(span).await.context("export queue closed")?;
    }
}

fn span_elapsed_ns(span: &SpanData) -> Option<u64> {
    let value = |key| match span.attributes.get(&Key::new(key)) {
        Some(Value::I64(value)) if *value >= 0 => Some(*value as u64),
        _ => None,
    };
    value("busy_ns")?.checked_add(value("idle_ns")?)
}

fn unix_nanos(time: std::time::SystemTime) -> Option<u64> {
    u64::try_from(time.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos()).ok()
}

fn normalize_span_timestamps(span: &mut SpanData) -> std::result::Result<(), &'static str> {
    if span.end_time >= span.start_time {
        if unix_nanos(span.start_time).is_none() || unix_nanos(span.end_time).is_none() {
            return Err("timestamp is outside the OTLP unix-nanosecond range");
        }
        return Ok(());
    }

    let rollback = span
        .start_time
        .duration_since(span.end_time)
        .unwrap_or_default();
    let rollback_ns = i64::try_from(rollback.as_nanos()).unwrap_or(i64::MAX);
    let elapsed_ns = span_elapsed_ns(span).ok_or("missing or invalid monotonic elapsed time")?;
    let corrected_start = span
        .end_time
        .checked_sub(Duration::from_nanos(elapsed_ns))
        .ok_or("corrected start time is before the system clock epoch")?;
    if unix_nanos(corrected_start).is_none() || unix_nanos(span.end_time).is_none() {
        return Err("corrected timestamp is outside the OTLP unix-nanosecond range");
    }
    span.start_time = corrected_start;
    span.attributes
        .insert(KeyValue::new("clock.rollback.detected", true));
    span.attributes
        .insert(KeyValue::new("clock.rollback.duration_ns", rollback_ns));
    Ok(())
}

async fn flush(exporter: &mut TraceExporter, batch: &mut Vec<SpanData>) {
    if !batch.is_empty() {
        match tokio::time::timeout(
            Duration::from_secs(10),
            exporter.export(std::mem::take(batch)),
        )
        .await
        {
            Ok(Ok(())) => {}
            Ok(Err(error)) => eprintln!("cube-agent OTLP export failed: {error}"),
            Err(_) => eprintln!("cube-agent OTLP export timed out after 10s"),
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let protocol = std::env::var("CUBE_CRI_TRACING_OTLP_PROTOCOL")
        .unwrap_or_else(|_| "http/protobuf".to_string());
    anyhow::ensure!(
        protocol == "http/protobuf",
        "unsupported guest trace protocol: {protocol}"
    );
    let endpoint = std::env::var("CUBE_CRI_TRACING_OTLP_ENDPOINT")
        .unwrap_or_else(|_| "http://127.0.0.1:4318".to_string());
    let endpoint = format!(
        "{}/v1/traces",
        endpoint
            .trim_end_matches("/v1/traces")
            .trim_end_matches('/')
    );
    let config = ExporterConfig {
        endpoint: endpoint.clone(),
        protocol: Protocol::HttpBinary,
        timeout: Duration::from_secs(10),
    };
    let mut exporter = TraceExporter::new_http(
        config,
        HttpConfig {
            client: Some(Box::new(CheckedHttpClient(reqwest::Client::new()))),
            headers: None,
        },
    )?;
    let listener = VsockListener::bind(VsockAddr::new(libc::VMADDR_CID_ANY, PORT))?;
    eprintln!("cube-agent trace forwarder listening on vsock {PORT}, exporting to {endpoint}");
    let (sender, mut receiver) = mpsc::channel::<SpanData>(4096);
    tokio::spawn(async move {
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    let sender = sender.clone();
                    tokio::spawn(async move {
                        if let Err(error) = receive(stream, sender).await {
                            eprintln!("cube-agent trace stream failed: {error}");
                        }
                    });
                }
                Err(error) => eprintln!("cube-agent trace accept failed: {error}"),
            }
        }
    });
    let mut ticker = tokio::time::interval(Duration::from_millis(200));
    let mut batch = Vec::with_capacity(64);
    loop {
        tokio::select! {
            received = receiver.recv() => match received {
                Some(span) => {
                    batch.push(span);
                    if batch.len() >= 64 { flush(&mut exporter, &mut batch).await; }
                }
                None => break,
            },
            _ = ticker.tick() => flush(&mut exporter, &mut batch).await,
        }
    }
    flush(&mut exporter, &mut batch).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use opentelemetry::sdk;
    use opentelemetry::trace::{SpanContext, SpanId, SpanKind, StatusCode, TraceId, TraceState};
    use std::borrow::Cow;
    use std::time::UNIX_EPOCH;

    fn span_data(start: Duration, end: Duration) -> SpanData {
        let mut attributes = sdk::trace::EvictedHashMap::new(8, 0);
        attributes.insert(KeyValue::new("busy_ns", 2_500_000_i64));
        attributes.insert(KeyValue::new("idle_ns", 500_000_i64));
        SpanData {
            span_context: SpanContext::new(
                TraceId::from_u128(1),
                SpanId::from_u64(1),
                1,
                false,
                TraceState::default(),
            ),
            parent_span_id: SpanId::invalid(),
            span_kind: SpanKind::Internal,
            name: Cow::Borrowed("set_guest_date_time"),
            start_time: UNIX_EPOCH + start,
            end_time: UNIX_EPOCH + end,
            attributes,
            events: sdk::trace::EvictedQueue::new(8),
            links: sdk::trace::EvictedQueue::new(8),
            status_code: StatusCode::Ok,
            status_message: Cow::Borrowed(""),
            resource: None,
            instrumentation_lib: sdk::InstrumentationLibrary::new("test", None),
        }
    }

    #[test]
    fn repairs_clock_rollback_with_monotonic_elapsed_time() {
        let mut span = span_data(Duration::from_millis(10), Duration::from_millis(7));

        normalize_span_timestamps(&mut span).unwrap();

        assert_eq!(span.start_time, UNIX_EPOCH + Duration::from_millis(4));
        assert_eq!(span.end_time, UNIX_EPOCH + Duration::from_millis(7));
        assert_eq!(
            span.attributes.get(&Key::new("clock.rollback.detected")),
            Some(&Value::Bool(true))
        );
        assert_eq!(
            span.attributes.get(&Key::new("clock.rollback.duration_ns")),
            Some(&Value::I64(3_000_000))
        );
    }

    #[test]
    fn preserves_valid_timestamps() {
        let mut span = span_data(Duration::from_millis(7), Duration::from_millis(10));

        normalize_span_timestamps(&mut span).unwrap();

        assert_eq!(span.end_time, UNIX_EPOCH + Duration::from_millis(10));
        assert!(span
            .attributes
            .get(&Key::new("clock.rollback.detected"))
            .is_none());
    }

    #[test]
    fn rejects_rollback_without_monotonic_elapsed_time() {
        let mut span = span_data(Duration::from_millis(10), Duration::from_millis(7));
        span.attributes = sdk::trace::EvictedHashMap::new(8, 0);

        assert_eq!(
            normalize_span_timestamps(&mut span),
            Err("missing or invalid monotonic elapsed time")
        );
    }

    #[test]
    fn rejects_elapsed_time_that_moves_start_before_epoch() {
        let mut span = span_data(Duration::from_secs(10), Duration::from_secs(7));
        span.attributes.insert(KeyValue::new("busy_ns", i64::MAX));
        span.attributes.insert(KeyValue::new("idle_ns", i64::MAX));

        assert_eq!(
            normalize_span_timestamps(&mut span),
            Err("corrected timestamp is outside the OTLP unix-nanosecond range")
        );
    }

    #[test]
    fn rejects_timestamp_outside_otlp_range() {
        let beyond_otlp = UNIX_EPOCH + Duration::from_nanos(u64::MAX) + Duration::from_nanos(1);
        let mut span = span_data(Duration::from_millis(7), Duration::from_millis(10));
        span.start_time = beyond_otlp;
        span.end_time = beyond_otlp;

        assert_eq!(
            normalize_span_timestamps(&mut span),
            Err("timestamp is outside the OTLP unix-nanosecond range")
        );
    }
}
