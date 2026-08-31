// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

use crate::common::utils::{ADDRESS_FILE, SHIM_PID_FILE};
use crate::service::{runtime_resource, tools};
use crate::{common::utils, service::task_srv::TaskService};
use async_trait::async_trait;
use containerd_shim::{
    asynchronous::{publisher::RemotePublisher, spawn, ExitSignal, Shim},
    protos::api,
    Config, Error, Flags, StartOpts,
};

use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::time::{Duration, Instant};
use std::{fs, io::Read, sync::Arc};

#[derive(Clone)]
pub struct Service {
    id: String,
    ns: String,
    exit: Arc<ExitSignal>,
    debug: bool,
}

#[async_trait]
impl Shim for Service {
    type T = TaskService;

    async fn new(_runtime: &str, flags: &Flags, _config: &mut Config) -> Self {
        Service {
            id: flags.id.clone(),
            ns: flags.namespace.clone(),
            exit: Arc::new(ExitSignal::default()),
            debug: flags.debug,
        }
    }

    async fn start_shim(&mut self, opts: StartOpts) -> Result<String, Error> {
        // containerd 2.3 writes BootstrapParams to the start action's stdin, but
        // containerd-shim 0.9.0's start path never consumes that request. Drain
        // it before using the library's legacy address-response path; flags and
        // environment still carry the inputs needed to spawn the server. Remove
        // this adapter when CubeShim moves to a bootstrap-aware shim library.
        consume_start_input(std::io::stdin().lock()).map_err(|err| Error::IoError {
            context: "read containerd bootstrap input".to_string(),
            err,
        })?;
        let grouping = opts.id.clone();
        let address: String = spawn(opts, &grouping, Vec::new()).await?;
        fs::write(ADDRESS_FILE, address.as_bytes()).map_err(|e| Error::IoError {
            context: "write address file failed".to_string(),
            err: e,
        })?;

        /*
        fs::write(SHIM_PID_FILE, format!("{}", "0")).map_err(|e| Error::IoError {
            context: "write pid file failed".to_string(),
            err: e,
        })?;
        */
        Ok(address)
    }

    async fn delete_shim(&mut self) -> Result<api::DeleteResponse, Error> {
        // The cleanup record is handed to an external reaper only after the
        // exact old shim process is dead. Its in-process VMM and virtiofs
        // threads may otherwise still own mounts below RuntimeResource.
        terminate_recorded_then_handoff(
            || read_optional_shim_pid(SHIM_PID_FILE),
            |shim_pid| terminate_shim_process(shim_pid, Duration::from_secs(30)),
            runtime_resource::handoff_persisted_to_reaper,
        )
        .map_err(Error::Other)?;

        if let Ok(sk_file) = tools::read_address(ADDRESS_FILE) {
            let _ = fs::remove_file(sk_file.as_str());
        }

        utils::Utils::clean_sandbox_resource(&self.id).map_err(Error::Other)?;

        Ok(api::DeleteResponse::new())
    }

    async fn wait(&mut self) {
        self.exit.wait().await;
    }

    async fn create_task_service(&self, publisher: RemotePublisher) -> Self::T {
        TaskService::new(
            self.id.clone(),
            self.ns.clone(),
            self.debug,
            self.exit.clone(),
            publisher,
        )
        .await
    }
}

fn terminate_then_handoff<T, H>(terminate: T, handoff: H) -> Result<(), String>
where
    T: FnOnce() -> Result<(), String>,
    H: FnOnce() -> Result<(), String>,
{
    terminate()?;
    handoff()
}

fn read_optional_shim_pid(file: &str) -> Result<Option<i32>, String> {
    match tools::read_number_from_file(file) {
        Ok(pid) => Ok(Some(pid)),
        Err(Error::IoError { err, .. }) if err.kind() == std::io::ErrorKind::NotFound => {
            // record_pid runs before VM creation, so a genuinely absent file
            // means that no VMM/virtiofs threads were started by this shim.
            Ok(None)
        }
        Err(error) => Err(format!("read recorded shim pid from {file}: {error}")),
    }
}

fn terminate_recorded_then_handoff<R, T, H>(
    read_pid: R,
    terminate: T,
    handoff: H,
) -> Result<(), String>
where
    R: FnOnce() -> Result<Option<i32>, String>,
    T: FnOnce(i32) -> Result<(), String>,
    H: FnOnce() -> Result<(), String>,
{
    match read_pid()? {
        Some(pid) => terminate_then_handoff(|| terminate(pid), handoff),
        None => handoff(),
    }
}

fn terminate_shim_process(pid: i32, timeout: Duration) -> Result<(), String> {
    if pid <= 0 {
        return Err(format!("invalid shim pid {pid}"));
    }
    // SAFETY: pidfd_open returns a new owned file descriptor on success.
    let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) as i32 };
    if raw < 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            return Ok(());
        }
        return Err(format!("pidfd_open shim {pid}: {error}"));
    }
    // SAFETY: `raw` was returned as a new descriptor by pidfd_open above.
    let pidfd = unsafe { OwnedFd::from_raw_fd(raw) };
    // SAFETY: pidfd_send_signal targets the identity referenced by pidfd and
    // the null siginfo pointer is valid when flags are zero.
    let sent = unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            pidfd.as_raw_fd(),
            libc::SIGKILL,
            std::ptr::null::<libc::siginfo_t>(),
            0,
        )
    };
    if sent < 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::ESRCH) {
            return Err(format!("pidfd_send_signal shim {pid}: {error}"));
        }
    }

    let deadline = Instant::now() + timeout;
    loop {
        let mut descriptor = libc::pollfd {
            fd: pidfd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: descriptor points to one initialized pollfd for this call.
        let polled = unsafe { libc::poll(&mut descriptor, 1, 100) };
        if polled > 0 && descriptor.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            return Ok(());
        }
        if polled < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(format!("poll pidfd for shim {pid}: {error}"));
            }
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "timed out after {}ms waiting for shim {pid} to exit",
                timeout.as_millis()
            ));
        }
    }
}

fn consume_start_input(mut input: impl Read) -> std::io::Result<usize> {
    let mut data = Vec::new();
    input.read_to_end(&mut data)
}

#[cfg(test)]
mod tests {
    use super::{
        consume_start_input, read_optional_shim_pid, terminate_recorded_then_handoff,
        terminate_shim_process, terminate_then_handoff,
    };
    use std::io::Cursor;
    use std::process::Command;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    #[test]
    fn consume_start_input_drains_bootstrap_payload() {
        let payload = b"containerd-2.3-bootstrap";
        let mut input = Cursor::new(payload);

        let consumed = consume_start_input(&mut input).unwrap();

        assert_eq!(consumed, payload.len());
        assert_eq!(input.position(), payload.len() as u64);
    }

    #[test]
    fn reaper_handoff_occurs_only_after_shim_death_confirmation() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let termination_events = events.clone();
        let handoff_events = events.clone();

        terminate_then_handoff(
            move || {
                termination_events.lock().unwrap().push("shim-dead");
                Ok(())
            },
            move || {
                handoff_events.lock().unwrap().push("reaper-handoff");
                Ok(())
            },
        )
        .unwrap();

        assert_eq!(*events.lock().unwrap(), vec!["shim-dead", "reaper-handoff"]);
    }

    #[test]
    fn failed_shim_death_confirmation_never_hands_off_reaper() {
        let handed_off = Arc::new(Mutex::new(false));
        let handoff_state = handed_off.clone();

        let error = terminate_then_handoff(
            || Err("shim still alive".to_string()),
            move || {
                *handoff_state.lock().unwrap() = true;
                Ok(())
            },
        )
        .unwrap_err();

        assert_eq!(error, "shim still alive");
        assert!(!*handed_off.lock().unwrap());
    }

    #[test]
    fn pid_read_failure_blocks_reaper_handoff() {
        let handed_off = Arc::new(Mutex::new(false));
        let handoff_state = handed_off.clone();

        let error = terminate_recorded_then_handoff(
            || Err("malformed shim pid".to_string()),
            |_| Ok(()),
            move || {
                *handoff_state.lock().unwrap() = true;
                Ok(())
            },
        )
        .unwrap_err();

        assert_eq!(error, "malformed shim pid");
        assert!(!*handed_off.lock().unwrap());
    }

    #[test]
    fn malformed_pid_file_is_not_treated_as_absent() {
        let path = std::env::temp_dir().join(format!(
            "cubesandbox-malformed-shim-pid-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::write(&path, "not-a-pid").unwrap();

        let error = read_optional_shim_pid(path.to_str().unwrap()).unwrap_err();

        assert!(error.contains("read recorded shim pid"));
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn missing_pid_file_allows_handoff_without_termination() {
        let path = std::env::temp_dir().join(format!(
            "cubesandbox-missing-shim-pid-{}",
            uuid::Uuid::new_v4()
        ));
        let terminated = Arc::new(Mutex::new(false));
        let terminate_state = terminated.clone();
        let handed_off = Arc::new(Mutex::new(false));
        let handoff_state = handed_off.clone();

        terminate_recorded_then_handoff(
            || read_optional_shim_pid(path.to_str().unwrap()),
            move |_| {
                *terminate_state.lock().unwrap() = true;
                Ok(())
            },
            move || {
                *handoff_state.lock().unwrap() = true;
                Ok(())
            },
        )
        .unwrap();

        assert!(!*terminated.lock().unwrap());
        assert!(*handed_off.lock().unwrap());
    }

    #[test]
    fn pidfd_termination_waits_for_exact_child_exit() {
        let mut child = Command::new("sleep").arg("30").spawn().unwrap();
        let pid = i32::try_from(child.id()).unwrap();

        terminate_shim_process(pid, Duration::from_secs(5)).unwrap();
        let status = child.wait().unwrap();

        assert!(!status.success());
    }
}
