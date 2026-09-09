// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Best-effort node-local metric events. Metrics must never delay a sandbox
//! operation, so this module owns a bounded queue and deliberately drops when
//! the cubelet-cri collector is unavailable or overloaded.

use crate::log::StatRet;
use serde::Serialize;
use std::env;
use std::os::unix::net::UnixDatagram;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, SyncSender, TrySendError};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

const METRICS_SOCKET_ENV: &str = "CUBE_CRI_METRICS_SOCKET";
const QUEUE_CAPACITY: usize = 256;

static SENDER: OnceLock<Option<SyncSender<Event>>> = OnceLock::new();
static DROPPED: AtomicU64 = AtomicU64::new(0);

#[derive(Serialize)]
struct Event {
    version: u8,
    #[serde(rename = "event_type")]
    event_type: &'static str,
    component: &'static str,
    operation: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error_class: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    duration_seconds: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    dropped: Option<u64>,
}

pub fn observe_stat(callee: &str, action: &str, result: &StatRet, duration: Duration) {
    let Some((component, operation)) = stat_operation(callee, action) else {
        return;
    };
    observe(
        component,
        operation,
        matches!(result, StatRet::Ok),
        duration,
    );
}

pub fn observe_vmm_stage(operation: &'static str, succeeded: bool, duration: Duration) {
    observe("vmm", operation, succeeded, duration);
}

pub fn observe_shim_stage(operation: &'static str, succeeded: bool, duration: Duration) {
    observe("shim", operation, succeeded, duration);
}

/// Records the actual VM start path for a successfully created CRI sandbox.
/// This is intentionally separate from CreatePodSandbox: a template restore
/// and a cold boot have different capacity and latency characteristics.
pub fn observe_sandbox_start_path(template_derived: bool, duration: Duration) {
    observe_shim_stage(
        if template_derived {
            "TemplateDerivedSandbox"
        } else {
            "ColdStartSandbox"
        },
        true,
        duration,
    );
}

/// Times one bounded internal operation without adding latency to the path.
pub struct OperationTimer {
    component: &'static str,
    operation: &'static str,
    started: Instant,
    succeeded: bool,
}

impl OperationTimer {
    pub fn new(component: &'static str, operation: &'static str) -> Self {
        observe_start(component, operation);
        Self {
            component,
            operation,
            started: Instant::now(),
            succeeded: false,
        }
    }

    pub fn succeed(&mut self) {
        self.succeeded = true;
    }
}

impl Drop for OperationTimer {
    fn drop(&mut self) {
        observe_finish(
            self.component,
            self.operation,
            self.succeeded,
            self.started.elapsed(),
        );
    }
}

fn observe(component: &'static str, operation: &'static str, succeeded: bool, duration: Duration) {
    send(Event {
        version: 1,
        event_type: "observe",
        component,
        operation,
        result: Some(if succeeded { "ok" } else { "error" }),
        error_class: (!succeeded).then_some("internal"),
        duration_seconds: Some(duration.as_secs_f64()),
        dropped: Some(DROPPED.swap(0, Ordering::Relaxed)).filter(|count| *count > 0),
    });
}

fn observe_start(component: &'static str, operation: &'static str) {
    send(Event {
        version: 1,
        event_type: "start",
        component,
        operation,
        result: None,
        error_class: None,
        duration_seconds: None,
        dropped: Some(DROPPED.swap(0, Ordering::Relaxed)).filter(|count| *count > 0),
    });
}

fn observe_finish(
    component: &'static str,
    operation: &'static str,
    succeeded: bool,
    duration: Duration,
) {
    send(Event {
        version: 1,
        event_type: "finish",
        component,
        operation,
        result: Some(if succeeded { "ok" } else { "error" }),
        error_class: (!succeeded).then_some("internal"),
        duration_seconds: Some(duration.as_secs_f64()),
        dropped: Some(DROPPED.swap(0, Ordering::Relaxed)).filter(|count| *count > 0),
    });
}

fn send(event: Event) {
    let Some(sender) = sender() else {
        return;
    };
    match sender.try_send(event) {
        Ok(()) => {}
        Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
            DROPPED.fetch_add(1, Ordering::Relaxed);
        }
    }
}

fn sender() -> Option<&'static SyncSender<Event>> {
    SENDER
        .get_or_init(|| {
            let path = env::var(METRICS_SOCKET_ENV).ok()?;
            if path.is_empty() {
                return None;
            }
            let (sender, receiver) = sync_channel(QUEUE_CAPACITY);
            thread::Builder::new()
                .name("cube-metrics".to_string())
                .spawn(move || {
                    let socket = match UnixDatagram::unbound() {
                        Ok(socket) => socket,
                        Err(_) => return,
                    };
                    let _ = socket.set_nonblocking(true);
                    while let Ok(event) = receiver.recv() {
                        let payload = match serde_json::to_vec(&event) {
                            Ok(payload) => payload,
                            Err(_) => {
                                DROPPED.fetch_add(1, Ordering::Relaxed);
                                continue;
                            }
                        };
                        if socket.send_to(&payload, &path).is_err() {
                            DROPPED.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                })
                .ok()?;
            Some(sender)
        })
        .as_ref()
}

fn stat_operation(callee: &str, action: &str) -> Option<(&'static str, &'static str)> {
    match (callee, action) {
        ("Shim", "CreatePodContainer") => Some(("shim", "CreatePodContainer")),
        ("Agent", "CreateSandbox") => Some(("agent", "CreateSandbox")),
        ("Agent", "CreateContainer") => Some(("agent", "CreateContainer")),
        ("Ch", "LaunchVmm") => Some(("vmm", "LaunchVmm")),
        ("Ch", "CreateVm") => Some(("vmm", "CreateVm")),
        ("Ch", "BootVm") => Some(("vmm", "BootVm")),
        ("Ch", "RestoreVm") => Some(("vmm", "RestoreVm")),
        _ => None,
    }
}
