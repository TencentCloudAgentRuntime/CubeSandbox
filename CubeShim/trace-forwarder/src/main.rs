use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use byteorder::{ByteOrder, NetworkEndian};
use clap::{Parser, ValueEnum};
use opentelemetry::sdk::export::trace::{SpanData, SpanExporter};
use opentelemetry_otlp::{ExporterConfig, HttpConfig, Protocol, TonicConfig, TraceExporter};
use tokio::io::AsyncReadExt;
use tokio::sync::Mutex;
use tokio_vsock::{VsockAddr, VsockListener, VsockStream, VMADDR_CID_ANY};

const DEFAULT_VSOCK_PORT: u32 = 10240;
const HEADER_SIZE_BYTES: usize = std::mem::size_of::<u64>();
const DEFAULT_ENDPOINT: &str = "http://127.0.0.1:4318";
const DEFAULT_PROTOCOL: TraceProtocol = TraceProtocol::HttpProtobuf;

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
enum TraceProtocol {
    #[value(name = "http/protobuf")]
    HttpProtobuf,
    #[value(name = "grpc")]
    Grpc,
}

#[derive(Debug, Parser)]
#[command(about = "Forward cube-agent vsock spans to an OTLP backend")]
struct Args {
    #[arg(long, env = "CUBE_CRI_TRACING_OTLP_ENDPOINT", default_value = DEFAULT_ENDPOINT)]
    otlp_endpoint: String,

    #[arg(long, env = "CUBE_CRI_TRACING_OTLP_PROTOCOL", value_enum, default_value_t = DEFAULT_PROTOCOL)]
    otlp_protocol: TraceProtocol,

    #[arg(long, env = "CUBE_CRI_TRACE_FORWARDER_VSOCK_PORT", default_value_t = DEFAULT_VSOCK_PORT)]
    vsock_port: u32,

    #[arg(
        long,
        env = "CUBE_CRI_TRACE_FORWARDER_EXPORT_TIMEOUT_SECS",
        default_value_t = 10
    )]
    export_timeout_secs: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    if args.otlp_endpoint.trim().is_empty() {
        bail!("OTLP endpoint is empty");
    }

    let endpoint = normalize_endpoint(&args.otlp_endpoint, args.otlp_protocol)?;
    let exporter = new_exporter(
        endpoint,
        args.otlp_protocol,
        Duration::from_secs(args.export_timeout_secs),
    )?;
    let exporter = Arc::new(Mutex::new(exporter));
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, args.vsock_port))
        .with_context(|| format!("bind vsock port {}", args.vsock_port))?;

    eprintln!(
        "cube-trace-forwarder listening on vsock port {} and exporting via {:?}",
        args.vsock_port, args.otlp_protocol
    );

    loop {
        let (stream, peer) = listener.accept().await.context("accept vsock connection")?;
        let exporter = exporter.clone();
        tokio::spawn(async move {
            if let Err(err) = handle_connection(stream, exporter).await {
                eprintln!(
                    "cube-trace-forwarder connection {:?} closed: {:#}",
                    peer, err
                );
            }
        });
    }
}

fn new_exporter(
    endpoint: String,
    protocol: TraceProtocol,
    timeout: Duration,
) -> Result<TraceExporter> {
    let config = ExporterConfig {
        endpoint,
        protocol: match protocol {
            TraceProtocol::HttpProtobuf => Protocol::HttpBinary,
            TraceProtocol::Grpc => Protocol::Grpc,
        },
        timeout,
    };

    match protocol {
        TraceProtocol::HttpProtobuf => TraceExporter::new_http(config, HttpConfig::default())
            .context("create OTLP HTTP/protobuf exporter"),
        TraceProtocol::Grpc => TraceExporter::new_tonic(config, TonicConfig::default())
            .context("create OTLP gRPC exporter"),
    }
}

async fn handle_connection(
    mut stream: VsockStream,
    exporter: Arc<Mutex<TraceExporter>>,
) -> Result<()> {
    loop {
        let span = match read_span(&mut stream).await {
            Ok(span) => span,
            Err(err) if is_clean_eof(&err) => return Ok(()),
            Err(err) => return Err(err),
        };

        let mut exporter = exporter.lock().await;
        exporter
            .export(vec![span])
            .await
            .context("export span to OTLP backend")?;
    }
}

async fn read_span(stream: &mut VsockStream) -> Result<SpanData> {
    let mut header = [0u8; HEADER_SIZE_BYTES];
    stream
        .read_exact(&mut header)
        .await
        .context("read span payload length")?;
    let payload_len = NetworkEndian::read_u64(&header);
    if payload_len == 0 {
        bail!("span payload length is zero");
    }
    if payload_len > 16 * 1024 * 1024 {
        bail!("span payload too large: {} bytes", payload_len);
    }

    let mut payload = vec![0; payload_len as usize];
    stream
        .read_exact(&mut payload)
        .await
        .context("read span payload")?;
    bincode::deserialize(&payload).context("decode bincode SpanData")
}

fn normalize_endpoint(endpoint: &str, protocol: TraceProtocol) -> Result<String> {
    let endpoint = endpoint.trim().trim_end_matches('/').to_string();
    if endpoint.is_empty() {
        bail!("OTLP endpoint is empty");
    }
    if protocol == TraceProtocol::HttpProtobuf {
        if endpoint.ends_with("/v1/traces") {
            Ok(endpoint)
        } else {
            Ok(format!("{}/v1/traces", endpoint))
        }
    } else {
        Ok(endpoint)
    }
}

fn is_clean_eof(err: &anyhow::Error) -> bool {
    err.chain()
        .filter_map(|cause| cause.downcast_ref::<std::io::Error>())
        .any(|io| io.kind() == std::io::ErrorKind::UnexpectedEof)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_http_trace_path() {
        assert_eq!(
            normalize_endpoint("http://127.0.0.1:4318", TraceProtocol::HttpProtobuf).unwrap(),
            "http://127.0.0.1:4318/v1/traces"
        );
    }

    #[test]
    fn keeps_explicit_http_trace_path() {
        assert_eq!(
            normalize_endpoint(
                "http://collector:4318/v1/traces",
                TraceProtocol::HttpProtobuf
            )
            .unwrap(),
            "http://collector:4318/v1/traces"
        );
    }

    #[test]
    fn keeps_grpc_endpoint() {
        assert_eq!(
            normalize_endpoint("http://127.0.0.1:4317", TraceProtocol::Grpc).unwrap(),
            "http://127.0.0.1:4317"
        );
    }
}
