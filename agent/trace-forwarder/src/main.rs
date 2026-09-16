// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Receive the cube-agent's length-prefixed bincode spans and export OTLP/HTTP.

use anyhow::{Context, Result};
use opentelemetry::sdk::export::trace::{SpanData, SpanExporter};
use opentelemetry_otlp::{ExporterConfig, HttpConfig, Protocol, TraceExporter};
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
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("collector returned HTTP {}", response.status()),
            )
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
        let span: SpanData = bincode::deserialize(&bytes)?;
        sender.send(span).await.context("export queue closed")?;
    }
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
    anyhow::ensure!(protocol == "http/protobuf", "unsupported guest trace protocol: {protocol}");
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
