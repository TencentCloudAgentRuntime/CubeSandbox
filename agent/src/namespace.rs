// Copyright (c) 2019 Ant Financial
//
// SPDX-License-Identifier: Apache-2.0
//

use anyhow::{anyhow, Context, Result};
use nix::mount::MsFlags;
use nix::sched::{clone, unshare, CloneFlags};
use nix::unistd::{getpid, gettid};
use std::fmt;
use std::fs;
use std::fs::File;
use std::os::unix::io::RawFd;
use std::path::{Path, PathBuf};
use tracing::instrument;

use crate::mount::{baremount, FLAGS};
use slog::Logger;

const PERSISTENT_NS_DIR: &str = "/var/run/sandbox-ns";
const PIDNS_HOLDER_PATH: &[u8] = b"/run/support/cube-pidns-holder\0";
const PIDNS_HOLDER_READY_FD: RawFd = 3;
const PIDNS_HOLDER_READY: u8 = 0;
const PIDNS_HOLDER_EXEC_FAILED: u8 = 1;
const PIDNS_HOLDER_READY_TIMEOUT_MS: libc::c_int = 5_000;
pub const NSTYPEIPC: &str = "ipc";
pub const NSTYPEUTS: &str = "uts";
pub const NSTYPEPID: &str = "pid";

#[instrument]
pub fn get_current_thread_ns_path(ns_type: &str) -> String {
    format!("/proc/{}/task/{}/ns/{}", getpid(), gettid(), ns_type)
}

#[derive(Debug)]
pub struct Namespace {
    logger: Logger,
    pub path: String,
    persistent_ns_dir: String,
    ns_type: NamespaceType,
    //only used for uts namespace
    pub hostname: Option<String>,
}

impl Namespace {
    #[instrument]
    pub fn new(logger: &Logger) -> Self {
        Namespace {
            logger: logger.clone(),
            path: String::from(""),
            persistent_ns_dir: String::from(PERSISTENT_NS_DIR),
            ns_type: NamespaceType::Ipc,
            hostname: None,
        }
    }

    #[instrument]
    pub fn get_ipc(mut self) -> Self {
        self.ns_type = NamespaceType::Ipc;
        self
    }

    #[instrument]
    pub fn get_uts(mut self, hostname: &str) -> Self {
        self.ns_type = NamespaceType::Uts;
        if !hostname.is_empty() {
            self.hostname = Some(String::from(hostname));
        }
        self
    }

    #[instrument]
    pub fn get_pid(mut self) -> Self {
        self.ns_type = NamespaceType::Pid;
        self
    }

    #[allow(dead_code)]
    pub fn set_root_dir(mut self, dir: &str) -> Self {
        self.persistent_ns_dir = dir.to_string();
        self
    }

    // setup creates persistent namespace without switching to it.
    // Note, pid namespaces cannot be persisted.
    #[instrument]
    pub async fn setup(mut self) -> Result<Self> {
        fs::create_dir_all(&self.persistent_ns_dir)?;

        let ns_path = PathBuf::from(&self.persistent_ns_dir);
        let ns_type = self.ns_type;
        if ns_type == NamespaceType::Pid {
            return Err(anyhow!("Cannot persist namespace of PID type"));
        }
        let logger = self.logger.clone();

        let new_ns_path = ns_path.join(&ns_type.get());

        File::create(new_ns_path.as_path())?;

        self.path = new_ns_path.clone().into_os_string().into_string().unwrap();
        let hostname = self.hostname.clone();

        let new_thread = std::thread::spawn(move || {
            if let Err(err) = || -> Result<()> {
                let origin_ns_path = get_current_thread_ns_path(ns_type.get());

                let source = Path::new(&origin_ns_path);
                let destination = new_ns_path.as_path();

                File::open(&source)?;

                // Create a new netns on the current thread.
                let cf = ns_type.get_flags();

                unshare(cf)?;

                if ns_type == NamespaceType::Uts && hostname.is_some() {
                    nix::unistd::sethostname(hostname.unwrap())?;
                }
                // Bind mount the new namespace from the current thread onto the mount point to persist it.

                let mut flags = MsFlags::empty();

                if let Some(x) = FLAGS.get("rbind") {
                    let (clear, f) = *x;
                    if clear {
                        flags &= !f;
                    } else {
                        flags |= f;
                    }
                };

                baremount(source, destination, "none", flags, "", &logger).map_err(|e| {
                    anyhow!(
                        "Failed to mount {:?} to {:?} with err:{:?}",
                        source,
                        destination,
                        e
                    )
                })?;

                Ok(())
            }() {
                return Err(err);
            }

            Ok(())
        });

        new_thread
            .join()
            .map_err(|e| anyhow!("Failed to join thread {:?}!", e))??;

        Ok(self)
    }

    /// Create a pause-like PID 1 process and return its namespace path.
    ///
    /// PID namespaces cannot be kept usable by a bind mount alone: once their
    /// init process exits, the kernel prevents creation of new processes in
    /// that namespace. A dedicated helper therefore remains alive for the
    /// lifetime of the single-sandbox Guest VM. The clone child closes Agent
    /// descriptors and execs the helper so it cannot expose Agent memory. The
    /// helper reports readiness only after installing its empty root and
    /// dropping credentials and capabilities.
    #[instrument]
    pub fn setup_pid(mut self) -> Result<(Self, libc::pid_t)> {
        self.ns_type = NamespaceType::Pid;
        let mut ready_pipe = [-1; 2];
        if unsafe { libc::pipe2(ready_pipe.as_mut_ptr(), libc::O_CLOEXEC) } < 0 {
            return Err(std::io::Error::last_os_error())
                .context("Failed to create shared PID namespace holder readiness pipe");
        }

        let ready_read = ready_pipe[0];
        let ready_write = ready_pipe[1];
        let mut stack = vec![0_u8; 64 * 1024];
        let holder_result = clone(
            Box::new(move || -> isize { exec_pidns_holder(ready_read, ready_write) }),
            &mut stack,
            CloneFlags::CLONE_NEWPID | CloneFlags::CLONE_NEWNS,
            Some(libc::SIGCHLD),
        );
        unsafe {
            libc::close(ready_write);
        }
        let holder = match holder_result {
            Ok(holder) => holder,
            Err(err) => {
                unsafe {
                    libc::close(ready_read);
                }
                return Err(err).context("Failed to clone shared PID namespace holder");
            }
        };

        let status = wait_pidns_holder_ready(ready_read, holder.as_raw())?;
        if status != PIDNS_HOLDER_READY {
            terminate_pidns_holder(holder.as_raw());
            return Err(anyhow!(
                "Shared PID namespace holder initialization failed at step {}",
                status
            ));
        }

        self.path = format!("/proc/{}/ns/pid", holder.as_raw());
        if let Err(err) = File::open(&self.path).with_context(|| {
            format!(
                "Failed to open shared PID namespace holder path {}",
                self.path
            )
        }) {
            terminate_pidns_holder(holder.as_raw());
            return Err(err);
        }
        Ok((self, holder.as_raw()))
    }
}

fn write_pidns_holder_status(fd: RawFd, status: u8) {
    unsafe {
        libc::write(fd, &status as *const u8 as *const libc::c_void, 1);
    }
}

fn exec_pidns_holder(ready_read: RawFd, ready_write: RawFd) -> isize {
    unsafe {
        libc::close(ready_read);

        if ready_write != PIDNS_HOLDER_READY_FD {
            if libc::dup2(ready_write, PIDNS_HOLDER_READY_FD) < 0 {
                write_pidns_holder_status(ready_write, PIDNS_HOLDER_EXEC_FAILED);
                return 127;
            }
            libc::close(ready_write);
        }

        let null_fd = libc::open(b"/dev/null\0".as_ptr() as *const libc::c_char, libc::O_RDWR);
        if null_fd < 0 {
            write_pidns_holder_status(PIDNS_HOLDER_READY_FD, PIDNS_HOLDER_EXEC_FAILED);
            return 127;
        }
        for fd in 0..=2 {
            if libc::dup2(null_fd, fd) < 0 {
                write_pidns_holder_status(PIDNS_HOLDER_READY_FD, PIDNS_HOLDER_EXEC_FAILED);
                return 127;
            }
        }
        if null_fd > PIDNS_HOLDER_READY_FD {
            libc::close(null_fd);
        }

        // fd 3 is the readiness channel. No Agent control, log, vsock or
        // event-loop descriptor may survive the exec boundary.
        if libc::syscall(
            libc::SYS_close_range,
            (PIDNS_HOLDER_READY_FD + 1) as libc::c_uint,
            libc::c_uint::MAX,
            0 as libc::c_uint,
        ) < 0
        {
            write_pidns_holder_status(PIDNS_HOLDER_READY_FD, PIDNS_HOLDER_EXEC_FAILED);
            return 127;
        }

        let argv = [
            PIDNS_HOLDER_PATH.as_ptr() as *const libc::c_char,
            std::ptr::null(),
        ];
        libc::execv(
            PIDNS_HOLDER_PATH.as_ptr() as *const libc::c_char,
            argv.as_ptr(),
        );
        write_pidns_holder_status(PIDNS_HOLDER_READY_FD, PIDNS_HOLDER_EXEC_FAILED);
        127
    }
}

fn wait_pidns_holder_ready(ready_read: RawFd, holder: libc::pid_t) -> Result<u8> {
    let mut pollfd = libc::pollfd {
        fd: ready_read,
        events: libc::POLLIN | libc::POLLHUP,
        revents: 0,
    };
    let poll_result = unsafe { libc::poll(&mut pollfd, 1, PIDNS_HOLDER_READY_TIMEOUT_MS) };
    if poll_result <= 0 {
        unsafe {
            libc::close(ready_read);
        }
        terminate_pidns_holder(holder);
        if poll_result == 0 {
            return Err(anyhow!("Timed out waiting for shared PID namespace holder"));
        }
        return Err(std::io::Error::last_os_error())
            .context("Failed waiting for shared PID namespace holder");
    }

    let mut status = PIDNS_HOLDER_EXEC_FAILED;
    let read_result = unsafe {
        let result = libc::read(ready_read, &mut status as *mut u8 as *mut libc::c_void, 1);
        libc::close(ready_read);
        result
    };
    if read_result != 1 {
        terminate_pidns_holder(holder);
        return Err(anyhow!(
            "Shared PID namespace holder exited before reporting readiness"
        ));
    }
    Ok(status)
}

fn terminate_pidns_holder(holder: libc::pid_t) {
    unsafe {
        libc::kill(holder, libc::SIGKILL);
        libc::waitpid(holder, std::ptr::null_mut(), 0);
    }
}

/// Represents the Namespace type.
#[derive(Clone, Copy, PartialEq)]
enum NamespaceType {
    Ipc,
    Uts,
    Pid,
}

impl NamespaceType {
    /// Get the string representation of the namespace type.
    pub fn get(&self) -> &str {
        match *self {
            Self::Ipc => "ipc",
            Self::Uts => "uts",
            Self::Pid => "pid",
        }
    }

    /// Get the associate flags with the namespace type.
    pub fn get_flags(&self) -> CloneFlags {
        match *self {
            Self::Ipc => CloneFlags::CLONE_NEWIPC,
            Self::Uts => CloneFlags::CLONE_NEWUTS,
            Self::Pid => CloneFlags::CLONE_NEWPID,
        }
    }
}

impl fmt::Debug for NamespaceType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.get())
    }
}

#[cfg(test)]
mod tests {
    use super::{Namespace, NamespaceType};
    use crate::{mount::remove_mounts, skip_if_no_cap, skip_if_not_root};
    use capctl::caps::Cap;
    use nix::sched::CloneFlags;
    use tempfile::Builder;

    #[tokio::test]
    async fn test_setup_persistent_ns() {
        skip_if_not_root!();
        // Creating and bind-mounting persistent namespaces needs CAP_SYS_ADMIN.
        skip_if_no_cap!(Cap::SYS_ADMIN);
        // Create dummy logger and temp folder.
        let logger = slog::Logger::root(slog::Discard, o!());
        let tmpdir = Builder::new().prefix("ipc").tempdir().unwrap();

        let ns_ipc = Namespace::new(&logger)
            .get_ipc()
            .set_root_dir(tmpdir.path().to_str().unwrap())
            .setup()
            .await;

        assert!(ns_ipc.is_ok());
        assert!(remove_mounts(&[ns_ipc.unwrap().path]).is_ok());

        let logger = slog::Logger::root(slog::Discard, o!());
        let tmpdir = Builder::new().prefix("uts").tempdir().unwrap();

        let ns_uts = Namespace::new(&logger)
            .get_uts("test_hostname")
            .set_root_dir(tmpdir.path().to_str().unwrap())
            .setup()
            .await;

        assert!(ns_uts.is_ok());
        assert!(remove_mounts(&[ns_uts.unwrap().path]).is_ok());

        // Check it cannot persist pid namespaces.
        let logger = slog::Logger::root(slog::Discard, o!());
        let tmpdir = Builder::new().prefix("pid").tempdir().unwrap();

        let ns_pid = Namespace::new(&logger)
            .get_pid()
            .set_root_dir(tmpdir.path().to_str().unwrap())
            .setup()
            .await;

        assert!(ns_pid.is_err());
    }

    #[test]
    fn test_namespace_type() {
        let ipc = NamespaceType::Ipc;
        assert_eq!("ipc", ipc.get());
        assert_eq!(CloneFlags::CLONE_NEWIPC, ipc.get_flags());

        let uts = NamespaceType::Uts;
        assert_eq!("uts", uts.get());
        assert_eq!(CloneFlags::CLONE_NEWUTS, uts.get_flags());

        let pid = NamespaceType::Pid;
        assert_eq!("pid", pid.get());
        assert_eq!(CloneFlags::CLONE_NEWPID, pid.get_flags());
    }

    #[test]
    fn test_new() {
        // Create dummy logger and temp folder.
        let logger = slog::Logger::root(slog::Discard, o!());

        let ns_ipc = Namespace::new(&logger);
        assert_eq!(NamespaceType::Ipc, ns_ipc.ns_type);
    }

    #[test]
    fn test_get_ipc() {
        // Create dummy logger and temp folder.
        let logger = slog::Logger::root(slog::Discard, o!());

        let ns_ipc = Namespace::new(&logger).get_ipc();
        assert_eq!(NamespaceType::Ipc, ns_ipc.ns_type);
    }

    #[test]
    fn test_get_uts_with_hostname() {
        let hostname = String::from("a.test.com");
        // Create dummy logger and temp folder.
        let logger = slog::Logger::root(slog::Discard, o!());

        let ns_uts = Namespace::new(&logger).get_uts(hostname.as_str());
        assert_eq!(NamespaceType::Uts, ns_uts.ns_type);
        assert!(ns_uts.hostname.is_some());
    }

    #[test]
    fn test_get_uts() {
        let hostname = String::from("");
        // Create dummy logger and temp folder.
        let logger = slog::Logger::root(slog::Discard, o!());

        let ns_uts = Namespace::new(&logger).get_uts(hostname.as_str());
        assert_eq!(NamespaceType::Uts, ns_uts.ns_type);
        assert!(ns_uts.hostname.is_none());
    }

    #[test]
    fn test_get_pid() {
        // Create dummy logger and temp folder.
        let logger = slog::Logger::root(slog::Discard, o!());

        let ns_pid = Namespace::new(&logger).get_pid();
        assert_eq!(NamespaceType::Pid, ns_pid.ns_type);
    }

    #[test]
    fn test_set_root_dir() {
        // Create dummy logger and temp folder.
        let logger = slog::Logger::root(slog::Discard, o!());
        let tmpdir = Builder::new().prefix("pid").tempdir().unwrap();

        let ns_root = Namespace::new(&logger).set_root_dir(tmpdir.path().to_str().unwrap());
        assert_eq!(NamespaceType::Ipc, ns_root.ns_type);
        assert_eq!(ns_root.persistent_ns_dir, tmpdir.path().to_str().unwrap());
    }

    #[test]
    fn test_namespace_type_get() {
        #[derive(Debug)]
        struct TestData<'a> {
            ns_type: NamespaceType,
            str: &'a str,
        }

        let tests = &[
            TestData {
                ns_type: NamespaceType::Ipc,
                str: "ipc",
            },
            TestData {
                ns_type: NamespaceType::Uts,
                str: "uts",
            },
            TestData {
                ns_type: NamespaceType::Pid,
                str: "pid",
            },
        ];

        // Run the tests
        for (i, d) in tests.iter().enumerate() {
            // Create a string containing details of the test
            let msg = format!("test[{}]: {:?}", i, d);
            assert_eq!(d.str, d.ns_type.get(), "{}", msg)
        }
    }

    #[test]
    fn test_namespace_type_get_flags() {
        #[derive(Debug)]
        struct TestData {
            ns_type: NamespaceType,
            ns_flag: CloneFlags,
        }

        let tests = &[
            TestData {
                ns_type: NamespaceType::Ipc,
                ns_flag: CloneFlags::CLONE_NEWIPC,
            },
            TestData {
                ns_type: NamespaceType::Uts,
                ns_flag: CloneFlags::CLONE_NEWUTS,
            },
            TestData {
                ns_type: NamespaceType::Pid,
                ns_flag: CloneFlags::CLONE_NEWPID,
            },
        ];

        // Run the tests
        for (i, d) in tests.iter().enumerate() {
            // Create a string containing details of the test
            let msg = format!("test[{}]: {:?}", i, d);
            assert_eq!(d.ns_flag, d.ns_type.get_flags(), "{}", msg)
        }
    }
}
