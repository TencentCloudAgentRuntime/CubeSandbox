// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

#![cfg(target_os = "linux")]

use containerd_shim_cube_rs::hypervisor::worker::{
    configure_worker_child_before_exec, WorkerProcessProbe,
};
use cube_hypervisor::NotifyEvent;
use nix::sys::signal::{kill, Signal};
use nix::sys::socket::{socketpair, AddressFamily, SockFlag, SockType};
use nix::unistd::Pid;
use std::fs::File;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const WORKER_PATH_ENV: &str = "CUBE_VMM_WORKER_PATH";
const CONTROL_FD_ENV: &str = "CUBE_VMM_WORKER_CONTROL_FD";
const EVENT_FD_ENV: &str = "CUBE_VMM_WORKER_EVENT_FD";
const NONCE_ENV: &str = "CUBE_VMM_WORKER_NONCE";
const PARENT_PID_ENV: &str = "CUBE_VMM_WORKER_PARENT_PID";
const PARENT_HELPER_ENV: &str = "CUBE_VMM_WORKER_PARENT_TEST_HELPER";
const PARENT_HELPER_PID_FILE_ENV: &str = "CUBE_VMM_WORKER_PARENT_TEST_PID_FILE";
const WORKER_BIN: &str = env!("CARGO_BIN_EXE_cube-vmm-worker");

fn wait_until(timeout: Duration, mut predicate: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if predicate() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    predicate()
}

fn spawn_unlaunched_worker() -> (Child, OwnedFd, OwnedFd) {
    let (control_parent, control_child) = socketpair(
        AddressFamily::Unix,
        SockType::SeqPacket,
        None,
        SockFlag::SOCK_CLOEXEC,
    )
    .unwrap();
    let (event_parent, event_child) = socketpair(
        AddressFamily::Unix,
        SockType::SeqPacket,
        None,
        SockFlag::SOCK_CLOEXEC,
    )
    .unwrap();
    let parent_pid = std::process::id();
    let control_fd = control_child.as_raw_fd();
    let event_fd = event_child.as_raw_fd();
    let mut command = Command::new(WORKER_BIN);
    command
        .env(CONTROL_FD_ENV, control_fd.to_string())
        .env(EVENT_FD_ENV, event_fd.to_string())
        .env(NONCE_ENV, "process-test-timeout")
        .env(PARENT_PID_ENV, parent_pid.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command
            .pre_exec(move || configure_worker_child_before_exec(control_fd, event_fd, parent_pid));
    }
    let child = command.spawn().unwrap();
    drop(control_child);
    drop(event_child);
    (child, control_parent, event_parent)
}

fn process_is_dead(pid: u32) -> bool {
    let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return true;
    };
    let Some(end) = stat.rfind(')') else {
        return false;
    };
    matches!(stat.as_bytes().get(end + 2), Some(b'Z' | b'X'))
}

#[test]
fn real_worker_exec_contract() {
    assert!(Path::new(WORKER_BIN).is_file());
    std::env::set_var(WORKER_PATH_ENV, WORKER_BIN);

    // A parent-only descriptor makes the production /proc/<pid>/fd gate prove
    // close-on-exec handling, rather than merely proving that IPC works.
    let sentinel = File::open("/dev/zero").unwrap();
    let sentinel_target =
        std::fs::read_link(format!("/proc/self/fd/{}", sentinel.as_raw_fd())).unwrap();
    let client = WorkerProcessProbe::spawn("worker-process-roundtrip".to_string()).unwrap();
    let worker_fd_targets = std::fs::read_dir(format!("/proc/{}/fd", client.process_id()))
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|entry| std::fs::read_link(entry.path()).ok())
        .collect::<Vec<_>>();
    assert!(
        !worker_fd_targets
            .iter()
            .any(|target| target == &sentinel_target),
        "parent-only descriptor crossed worker exec"
    );
    client.shutdown().unwrap();

    let client = WorkerProcessProbe::spawn("worker-process-early-exit".to_string()).unwrap();
    kill(Pid::from_raw(client.process_id() as i32), Signal::SIGKILL).unwrap();
    assert!(matches!(
        client.recv_event_timeout(Duration::from_secs(2)).unwrap(),
        NotifyEvent::VmShutdown
    ));
    assert!(wait_until(Duration::from_secs(2), || {
        client.is_poisoned_and_reaped()
    }));
    client.shutdown().unwrap();

    let (mut child, _control, _event) = spawn_unlaunched_worker();
    let started = Instant::now();
    assert!(wait_until(Duration::from_secs(4), || child
        .try_wait()
        .unwrap()
        .is_some()));
    assert!(started.elapsed() < Duration::from_secs(4));

    let pid_file =
        std::env::temp_dir().join(format!("cube-vmm-parent-death-{}", uuid::Uuid::new_v4()));
    let mut supervisor = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "parent_death_helper_process",
            "--nocapture",
        ])
        .env(PARENT_HELPER_ENV, "1")
        .env(PARENT_HELPER_PID_FILE_ENV, &pid_file)
        .env(WORKER_PATH_ENV, WORKER_BIN)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert!(wait_until(Duration::from_secs(5), || pid_file.is_file()));
    let worker_pid = std::fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse::<u32>()
        .unwrap();
    assert!(!process_is_dead(worker_pid));
    kill(Pid::from_raw(supervisor.id() as i32), Signal::SIGKILL).unwrap();
    supervisor.wait().unwrap();
    assert!(
        wait_until(Duration::from_secs(3), || process_is_dead(worker_pid)),
        "worker {worker_pid} survived its CubeShim parent"
    );
    std::fs::remove_file(pid_file).unwrap();
    std::env::remove_var(WORKER_PATH_ENV);
}

#[test]
#[ignore = "subprocess helper for real_worker_exec_contract"]
fn parent_death_helper_process() {
    if std::env::var(PARENT_HELPER_ENV).as_deref() != Ok("1") {
        return;
    }
    let pid_file = std::env::var(PARENT_HELPER_PID_FILE_ENV).unwrap();
    let client = WorkerProcessProbe::spawn("worker-parent-death".to_string()).unwrap();
    let temporary = format!("{pid_file}.tmp-{}", std::process::id());
    std::fs::write(&temporary, format!("{}\n", client.process_id())).unwrap();
    std::fs::rename(temporary, pid_file).unwrap();
    loop {
        std::thread::park_timeout(Duration::from_secs(60));
    }
}
