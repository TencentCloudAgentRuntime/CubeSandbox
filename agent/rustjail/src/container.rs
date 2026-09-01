// Copyright (c) 2019, 2020 Ant Group
//
// SPDX-License-Identifier: Apache-2.0
//

use std::clone::Clone;
use std::collections::{BTreeSet, HashMap};
use std::ffi::CString;
use std::fmt::{self, Display};
use std::fs;
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use cgroups::freezer::FreezerState;
use cube::rootfs::{
    ANNO_PROPAGATION_CONTAINER_UMNTS, ANNO_PROPAGATION_EXEC_MNTS, ENV_CONTAINER_PID,
};
use libc::pid_t;
use nix::errno::Errno;
use nix::fcntl::{self, OFlag};
use nix::fcntl::{FcntlArg, FdFlag};
use nix::mount::MntFlags;
use nix::sched::{self, CloneFlags};
use nix::sys::signal::{self, Signal};
use nix::sys::stat::{self, Mode};
use nix::unistd::{self, fork, ForkResult, Gid, Pid, Uid, User};
use oci::State as OCIState;
use oci::{ContainerState, LinuxDevice, LinuxIdMapping};
use oci::{Hook, Linux, LinuxNamespace, LinuxResources, Spec};
use protobuf::MessageField;
use protocols::agent::StatsContainerResponse;
use rlimit::{setrlimit, Resource, Rlim};
use slog::{debug, info, o, Logger};
use tokio::io::AsyncBufReadExt;
use tokio::sync::Mutex;

use crate::capabilities;
#[cfg(not(test))]
use crate::cgroups::fs::Manager as FsManager;
#[cfg(test)]
use crate::cgroups::mock::Manager as FsManager;
use crate::cgroups::Manager;
#[cfg(feature = "standard-oci-runtime")]
use crate::console;
use crate::log_child;
use crate::pipestream::PipeStream;
use crate::process::Process;
#[cfg(feature = "seccomp")]
use crate::seccomp;
use crate::specconv::CreateOpts;
use crate::sync::{
    read_sync, read_sync_with_timeout, write_count, write_sync, SYNC_DATA, SYNC_FAILED,
    SYNC_SUCCESS,
};
use crate::sync_with_async::{read_async, write_async};
use crate::{mount, validator};
pub const EXEC_FIFO_FILENAME: &str = "exec.fifo";
pub const RESOURCE_V2_JOURNAL_FILENAME: &str = "resources-v2.undo.json";

const INIT: &str = "INIT";
const NO_PIVOT: &str = "NO_PIVOT";
const CRFD_FD: &str = "CRFD_FD";
const CWFD_FD: &str = "CWFD_FD";
const CLOG_FD: &str = "CLOG_FD";
const FIFO_FD: &str = "FIFO_FD";
const PARENT_READY_SYNC_TIMEOUT_SECS: u64 = 10;
const HOME_ENV_KEY: &str = "HOME";
const PIDNS_FD: &str = "PIDNS_FD";
const CONSOLE_SOCKET_FD: &str = "CONSOLE_SOCKET_FD";
const EARLY_PROCESS_ATTACH_PATHS: &str = "EARLY_PROCESS_ATTACH_PATHS";

#[derive(Debug)]
pub struct ContainerStatus {
    pre_status: ContainerState,
    cur_status: ContainerState,
}

impl ContainerStatus {
    pub fn new() -> Self {
        ContainerStatus {
            pre_status: ContainerState::Created,
            cur_status: ContainerState::Created,
        }
    }

    fn status(&self) -> ContainerState {
        self.cur_status
    }

    fn transition(&mut self, to: ContainerState) {
        self.pre_status = self.status();
        self.cur_status = to;
    }
}

impl Default for ContainerStatus {
    fn default() -> Self {
        Self::new()
    }
}

pub type Config = CreateOpts;
type NamespaceType = String;

lazy_static! {
    // This locker ensures the child exit signal will be received by the right receiver.
    pub static ref WAIT_PID_LOCKER: Arc<Mutex<bool>> = Arc::new(Mutex::new(false));

    pub static ref NAMESPACES: HashMap<&'static str, CloneFlags> = {
        let mut m = HashMap::new();
        m.insert("user", CloneFlags::CLONE_NEWUSER);
        m.insert("ipc", CloneFlags::CLONE_NEWIPC);
        m.insert("pid", CloneFlags::CLONE_NEWPID);
        m.insert("network", CloneFlags::CLONE_NEWNET);
        m.insert("mount", CloneFlags::CLONE_NEWNS);
        m.insert("uts", CloneFlags::CLONE_NEWUTS);
        m.insert("cgroup", CloneFlags::CLONE_NEWCGROUP);
        m
    };

// type to name hashmap, better to be in NAMESPACES
    pub static ref TYPETONAME: HashMap<&'static str, &'static str> = {
        let mut m = HashMap::new();
        m.insert("ipc", "ipc");
        m.insert("user", "user");
        m.insert("pid", "pid");
        m.insert("network", "net");
        m.insert("mount", "mnt");
        m.insert("cgroup", "cgroup");
        m.insert("uts", "uts");
        m
    };

    pub static ref DEFAULT_DEVICES: Vec<LinuxDevice> = {
        vec![
            LinuxDevice {
                path: "/dev/null".to_string(),
                r#type: "c".to_string(),
                major: 1,
                minor: 3,
                file_mode: Some(0o666),
                uid: Some(0xffffffff),
                gid: Some(0xffffffff),
            },
            LinuxDevice {
                path: "/dev/zero".to_string(),
                r#type: "c".to_string(),
                major: 1,
                minor: 5,
                file_mode: Some(0o666),
                uid: Some(0xffffffff),
                gid: Some(0xffffffff),
            },
            LinuxDevice {
                path: "/dev/full".to_string(),
                r#type: "c".to_string(),
                major: 1,
                minor: 7,
                file_mode: Some(0o666),
                uid: Some(0xffffffff),
                gid: Some(0xffffffff),
            },
            LinuxDevice {
                path: "/dev/tty".to_string(),
                r#type: "c".to_string(),
                major: 5,
                minor: 0,
                file_mode: Some(0o666),
                uid: Some(0xffffffff),
                gid: Some(0xffffffff),
            },
            LinuxDevice {
                path: "/dev/urandom".to_string(),
                r#type: "c".to_string(),
                major: 1,
                minor: 9,
                file_mode: Some(0o666),
                uid: Some(0xffffffff),
                gid: Some(0xffffffff),
            },
            LinuxDevice {
                path: "/dev/random".to_string(),
                r#type: "c".to_string(),
                major: 1,
                minor: 8,
                file_mode: Some(0o666),
                uid: Some(0xffffffff),
                gid: Some(0xffffffff),
            },
        ]
    };
}

struct ProcessLaunchGuard {
    pid: Pid,
    armed: bool,
}

struct LaunchLogGuard {
    handle: Option<tokio::task::JoinHandle<()>>,
}

impl LaunchLogGuard {
    fn new(handle: tokio::task::JoinHandle<()>) -> Self {
        Self {
            handle: Some(handle),
        }
    }

    fn take(&mut self) -> Option<tokio::task::JoinHandle<()>> {
        self.handle.take()
    }
}

impl Drop for LaunchLogGuard {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            handle.abort();
        }
    }
}

fn own_fd(fd: RawFd) -> OwnedFd {
    // SAFETY: callers pass a newly opened descriptor and transfer its sole
    // ownership to the returned guard immediately.
    unsafe { OwnedFd::from_raw_fd(fd) }
}

fn owned_pipe() -> Result<(OwnedFd, OwnedFd)> {
    let (read_fd, write_fd) = unistd::pipe().context("failed to create pipe")?;
    Ok((own_fd(read_fd), own_fd(write_fd)))
}

impl ProcessLaunchGuard {
    fn new(pid: pid_t) -> Self {
        Self {
            pid: Pid::from_raw(pid),
            armed: true,
        }
    }

    fn reap(&mut self) -> Result<()> {
        loop {
            match nix::sys::wait::waitpid(self.pid, None) {
                Ok(_) | Err(Errno::ECHILD) => {
                    self.armed = false;
                    return Ok(());
                }
                Err(Errno::EINTR) => continue,
                Err(error) => return Err(anyhow!(error)),
            }
        }
    }
}

impl Drop for ProcessLaunchGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let _ = signal::kill(self.pid, Some(Signal::SIGKILL));
        let _ = self.reap();
    }
}

#[derive(Serialize, Deserialize, Debug)]
pub struct BaseState {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    id: String,
    #[serde(default)]
    init_process_pid: i32,
    #[serde(default)]
    init_process_start: u64,
}

#[async_trait]
pub trait BaseContainer {
    fn id(&self) -> String;
    fn status(&self) -> ContainerState;
    fn state(&self) -> Result<State>;
    fn oci_state(&self) -> Result<OCIState>;
    fn config(&self) -> Result<&Config>;
    fn processes(&self) -> Result<Vec<i32>>;
    fn get_process(&mut self, eid: &str) -> Result<&mut Process>;
    fn stats(&self) -> Result<StatsContainerResponse>;
    fn set(&mut self, config: LinuxResources) -> Result<()>;
    async fn start(&mut self, p: Process) -> Result<()>;
    async fn run(&mut self, p: Process) -> Result<()>;
    async fn destroy(&mut self) -> Result<()>;
    async fn exec(&mut self) -> Result<()>;
}

// LinuxContainer protected by Mutex
// Arc<Mutex<Innercontainer>> or just Mutex<InnerContainer>?
// Or use Mutex<xx> as a member of struct, like C?
// a lot of String in the struct might be &str
#[derive(Debug)]
pub struct LinuxContainer {
    pub id: String,
    pub root: String,
    pub config: Config,
    pub cgroup_manager: Option<FsManager>,
    pub init_process_pid: pid_t,
    pending_process_pid: Option<pid_t>,
    pub init_process_start_time: u64,
    pub uid_map_path: String,
    pub gid_map_path: String,
    pub processes: HashMap<pid_t, Process>,
    pub status: ContainerStatus,
    pub created: SystemTime,
    pub logger: Logger,
    pub resource_degraded: Option<ResourceDegraded>,
    #[cfg(test)]
    pre_spawn_hook: Option<fn(&[RawFd]) -> Result<()>>,
    #[cfg(feature = "standard-oci-runtime")]
    pub console_socket: PathBuf,
}

pub struct LinuxContainerCreateOutcome {
    pub container: LinuxContainer,
    pub initialization_error: Option<anyhow::Error>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResourceDegraded {
    pub cause: String,
    pub rollback_error: Option<String>,
    pub journal_path: PathBuf,
    pub current_values: std::collections::BTreeMap<PathBuf, String>,
    pub latest_recovery_error: Option<String>,
}

#[derive(Debug)]
pub struct ResourcePreconditionError {
    pub container_id: String,
    pub operation: String,
    pub degraded: ResourceDegraded,
}

impl fmt::Display for ResourcePreconditionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "container {} cannot {} while resources are degraded: {}; journal: {}",
            self.container_id,
            self.operation,
            self.degraded.cause,
            self.degraded.journal_path.display()
        )?;
        if let Some(error) = self.degraded.rollback_error.as_deref() {
            write!(formatter, "; rollback error: {error}")?;
        }
        if !self.degraded.current_values.is_empty() {
            write!(
                formatter,
                "; current values: {:?}",
                self.degraded.current_values
            )?;
        }
        if let Some(error) = self.degraded.latest_recovery_error.as_deref() {
            write!(formatter, "; latest recovery error: {error}")?;
        }
        Ok(())
    }
}

impl std::error::Error for ResourcePreconditionError {}

#[derive(Serialize, Deserialize, Debug)]
pub struct State {
    base: BaseState,
    #[serde(default)]
    rootless: bool,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    cgroup_paths: HashMap<String, String>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    namespace_paths: HashMap<NamespaceType, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    external_descriptors: Vec<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    intel_rdt_path: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct SyncPc {
    #[serde(default)]
    pid: pid_t,
}

pub trait Container: BaseContainer {
    fn pause(&mut self) -> Result<()>;
    fn resume(&mut self) -> Result<()>;
}

impl Container for LinuxContainer {
    fn pause(&mut self) -> Result<()> {
        let status = self.status();
        if status != ContainerState::Running && status != ContainerState::Created {
            return Err(anyhow!(
                "failed to pause container: current status is: {:?}",
                status
            ));
        }

        if self.cgroup_manager.is_some() {
            self.cgroup_manager
                .as_ref()
                .unwrap()
                .freeze(FreezerState::Frozen)?;

            self.status.transition(ContainerState::Paused);
            return Ok(());
        }
        Err(anyhow!("failed to get container's cgroup manager"))
    }

    fn resume(&mut self) -> Result<()> {
        let status = self.status();
        if status != ContainerState::Paused {
            return Err(anyhow!("container status is: {:?}, not paused", status));
        }

        if self.cgroup_manager.is_some() {
            self.cgroup_manager
                .as_ref()
                .unwrap()
                .freeze(FreezerState::Thawed)?;

            self.status.transition(ContainerState::Running);
            return Ok(());
        }
        Err(anyhow!("failed to get container's cgroup manager"))
    }
}

pub fn init_child() {
    let cwfd = std::env::var(CWFD_FD).unwrap().parse::<i32>().unwrap();
    let cfd_log = std::env::var(CLOG_FD).unwrap().parse::<i32>().unwrap();

    match do_init_child(cwfd) {
        Ok(_) => {}
        Err(e) => {
            log_child!(cfd_log, "temporary parent process exit:child exit: {:?}", e);
            let _ = write_sync(cwfd, SYNC_FAILED, format!("{:?}", e).as_str());
        }
    }
}

fn attach_fork_child_before_report<Attach, Cleanup>(
    targets: &[PathBuf],
    pid: pid_t,
    mut attach: Attach,
    cleanup: Cleanup,
) -> Result<()>
where
    Attach: FnMut(&Path, pid_t) -> Result<()>,
    Cleanup: FnOnce(pid_t) -> Result<()>,
{
    let attach_result = (|| {
        if targets.is_empty() {
            return Err(anyhow!("no cgroup targets for early process attach"));
        }
        for target in targets {
            attach(target, pid)?;
        }
        Ok(())
    })();
    if let Err(attach_error) = attach_result {
        return match cleanup(pid) {
            Ok(()) => Err(anyhow!(attach_error).context("attach fork child to cgroup")),
            Err(cleanup_error) => Err(anyhow!(
                "attach fork child to cgroup: {attach_error:#}; cleanup child: {cleanup_error:#}"
            )),
        };
    }
    Ok(())
}

fn kill_and_reap_fork_child(pid: pid_t) -> Result<()> {
    match signal::kill(Pid::from_raw(pid), Some(Signal::SIGKILL)) {
        Ok(()) | Err(Errno::ESRCH) => {}
        Err(error) => return Err(anyhow!(error).context("kill unattached fork child")),
    }
    loop {
        match nix::sys::wait::waitpid(Pid::from_raw(pid), None) {
            Ok(_) | Err(Errno::ECHILD) => return Ok(()),
            Err(Errno::EINTR) => continue,
            Err(error) => return Err(anyhow!(error).context("reap unattached fork child")),
        }
    }
}

fn do_init_child(cwfd: RawFd) -> Result<()> {
    lazy_static::initialize(&NAMESPACES);
    lazy_static::initialize(&DEFAULT_DEVICES);

    let init = std::env::var(INIT)?.eq(format!("{}", true).as_str());

    let no_pivot = std::env::var(NO_PIVOT)?.eq(format!("{}", true).as_str());
    let crfd = std::env::var(CRFD_FD)?.parse::<i32>().unwrap();
    let cfd_log = std::env::var(CLOG_FD)?.parse::<i32>().unwrap();
    let early_process_attach_paths: Vec<PathBuf> =
        serde_json::from_str(&std::env::var(EARLY_PROCESS_ATTACH_PATHS)?)
            .context("decode early process cgroup attach paths")?;
    let mut start = Instant::now();
    // get the pidns fd from parent, if parent had passed the pidns fd,
    // then get it and join in this pidns; otherwise, create a new pidns
    // by unshare from the parent pidns.
    match std::env::var(PIDNS_FD) {
        Ok(fd) => {
            let pidns_fd = fd.parse::<i32>().context("get parent pidns fd")?;
            sched::setns(pidns_fd, CloneFlags::CLONE_NEWPID).context("failed to join pidns")?;
            let _ = unistd::close(pidns_fd);
        }
        Err(_e) => sched::unshare(CloneFlags::CLONE_NEWPID)?,
    }

    match unsafe { fork() } {
        Ok(ForkResult::Parent { child, .. }) => {
            attach_fork_child_before_report(
                &early_process_attach_paths,
                pid_t::from(child),
                |target, pid| {
                    fs::write(target, pid.to_string()).with_context(|| {
                        format!("attach fork child {pid} to cgroup {}", target.display())
                    })
                },
                kill_and_reap_fork_child,
            )?;
            write_sync(cwfd, SYNC_DATA, format!("{}", pid_t::from(child)).as_str())?;
            // parent return
            return Ok(());
        }
        Ok(ForkResult::Child) => (),
        Err(e) => {
            return Err(anyhow!(format!(
                "failed to fork temporary process: {:?}",
                e
            )));
        }
    }
    let buf = read_sync(crfd)?;
    let spec_str = std::str::from_utf8(&buf)?;
    let spec: oci::Spec = serde_json::from_str(spec_str)?;

    write_sync(cwfd, SYNC_SUCCESS, "")?;

    let buf = read_sync(crfd)?;
    let process_str = std::str::from_utf8(&buf)?;
    let oci_process: oci::Process = serde_json::from_str(process_str)?;
    write_sync(cwfd, SYNC_SUCCESS, "")?;

    let buf = read_sync(crfd)?;
    let cm_str = std::str::from_utf8(&buf)?;

    let cm: FsManager = serde_json::from_str(cm_str)?;

    #[cfg(feature = "standard-oci-runtime")]
    let csocket_fd = console::setup_console_socket(&std::env::var(CONSOLE_SOCKET_FD)?)?;

    let p = if spec.process.is_some() {
        spec.process.as_ref().unwrap()
    } else {
        return Err(anyhow!("didn't find process in Spec"));
    };

    if spec.linux.is_none() {
        return Err(anyhow!("no linux config"));
    }
    let linux = spec.linux.as_ref().unwrap();

    // get namespace vector to join/new
    let nses = get_namespaces(linux);

    let mut userns = false;
    let mut to_new = CloneFlags::empty();
    let mut to_join = Vec::new();

    for ns in &nses {
        let s = NAMESPACES.get(&ns.r#type.as_str());
        if s.is_none() {
            return Err(anyhow!("invalid ns type"));
        }
        let s = s.unwrap();

        if ns.path.is_empty() {
            // skip the pidns since it has been done in parent process.
            if *s != CloneFlags::CLONE_NEWPID {
                to_new.set(*s, true);
            }
        } else {
            let fd =
                fcntl::open(ns.path.as_str(), OFlag::O_CLOEXEC, Mode::empty()).map_err(|e| {
                    log_child!(
                        cfd_log,
                        "cannot open type: {} path: {}",
                        ns.r#type.clone(),
                        ns.path.clone()
                    );
                    log_child!(cfd_log, "error is : {:?}", e);
                    e
                })?;

            if *s != CloneFlags::CLONE_NEWPID {
                to_join.push((*s, fd));
            }
        }
    }

    if to_new.contains(CloneFlags::CLONE_NEWUSER) {
        userns = true;
    }

    if p.oom_score_adj.is_some() {
        fs::write(
            "/proc/self/oom_score_adj",
            p.oom_score_adj.unwrap().to_string().as_bytes(),
        )?;
    }

    // set rlimit
    for rl in p.rlimits.iter() {
        setrlimit(
            Resource::from_str(&rl.r#type)?,
            Rlim::from_raw(rl.soft),
            Rlim::from_raw(rl.hard),
        )?;
    }

    //
    // Make the process non-dumpable, to avoid various race conditions that
    // could cause processes in namespaces we're joining to access host
    // resources (or potentially execute code).
    //
    // However, if the number of namespaces we are joining is 0, we are not
    // going to be switching to a different security context. Thus setting
    // ourselves to be non-dumpable only breaks things (like rootless
    // containers), which is the recommendation from the kernel folks.
    //
    // Ref: https://github.com/opencontainers/runc/commit/50a19c6ff828c58e5dab13830bd3dacde268afe5
    //
    if !nses.is_empty() {
        capctl::prctl::set_dumpable(false)
            .map_err(|e| anyhow!(e).context("set process non-dumpable failed"))?;
    }

    if userns {
        sched::unshare(CloneFlags::CLONE_NEWUSER)?;
    }

    // notify parent unshare user ns completed.
    write_sync(cwfd, SYNC_SUCCESS, "")?;
    // wait parent to setup user id mapping.
    read_sync(crfd)?;

    if userns {
        setid(Uid::from_raw(0), Gid::from_raw(0))?;
    }

    let mut mount_fd = -1;
    let mut bind_device = false;
    for (s, fd) in to_join {
        if s == CloneFlags::CLONE_NEWNS {
            mount_fd = fd;
            continue;
        }

        sched::setns(fd, s).or_else(|e| {
            if s == CloneFlags::CLONE_NEWUSER {
                if e != Errno::EINVAL {
                    let _ = write_sync(cwfd, SYNC_FAILED, format!("{:?}", e).as_str());
                    return Err(e);
                }

                Ok(())
            } else {
                let _ = write_sync(cwfd, SYNC_FAILED, format!("{:?}", e).as_str());
                Err(e)
            }
        })?;

        unistd::close(fd)?;

        if s == CloneFlags::CLONE_NEWUSER {
            setid(Uid::from_raw(0), Gid::from_raw(0))?;
            bind_device = true;
        }
    }

    sched::unshare(to_new & !CloneFlags::CLONE_NEWUSER)?;

    if userns {
        bind_device = true;
    }

    if to_new.contains(CloneFlags::CLONE_NEWUTS) {
        unistd::sethostname(&spec.hostname)?;
    }

    let rootfs = spec.root.as_ref().unwrap().path.as_str();
    let root = fs::canonicalize(rootfs)?;
    let rootfs = root.to_str().unwrap();

    if to_new.contains(CloneFlags::CLONE_NEWNS) {
        // setup rootfs
        mount::init_rootfs(
            cfd_log,
            &spec,
            &cm.paths,
            &cm.mounts,
            &cm.cpath,
            bind_device,
        )
        .map_err(|e| anyhow!("init_rootfs failed.{:}", e))?;
    }

    if init {
        // notify parent to run prestart hooks
        write_sync(cwfd, SYNC_SUCCESS, "")?;
        // wait parent run prestart hooks
        read_sync(crfd)?;
    }
    let duration_prestart = start.elapsed().as_millis();
    start = Instant::now();
    if mount_fd != -1 {
        sched::setns(mount_fd, CloneFlags::CLONE_NEWNS)?;
        unistd::close(mount_fd)?;
    }

    if to_new.contains(CloneFlags::CLONE_NEWNS) {
        // unistd::chroot(rootfs)?;
        if no_pivot {
            mount::ms_move_root(rootfs).map_err(|e| anyhow!("ms_move_root faild.{:}", e))?;
        } else {
            // pivot root
            mount::pivot_rootfs(rootfs).map_err(|e| anyhow!("pivot_rootfs faild.{:}", e))?;
        }

        // setup sysctl
        set_sysctls(&linux.sysctl)?;
        unistd::chdir("/")?;
    }
    let duration_newns = start.elapsed().as_millis();
    if to_new.contains(CloneFlags::CLONE_NEWNS) {
        mount::finish_rootfs(cfd_log, &spec, &oci_process)
            .map_err(|e| anyhow!("finish_rootfs faild.{:}", e))?;
    }

    if !oci_process.cwd.is_empty() {
        unistd::chdir(oci_process.cwd.as_str())?;
    }

    let guser = &oci_process.user;

    let uid = Uid::from_raw(guser.uid);
    let gid = Gid::from_raw(guser.gid);

    // only change stdio devices owner when user
    // isn't root.
    if !uid.is_root() {
        set_stdio_permissions(uid)?;
    }

    setid(uid, gid)?;

    if !guser.additional_gids.is_empty() {
        let gids: Vec<Gid> = guser
            .additional_gids
            .iter()
            .map(|gid| Gid::from_raw(*gid))
            .collect();

        unistd::setgroups(&gids).map_err(|e| {
            let _ = write_sync(
                cwfd,
                SYNC_FAILED,
                format!("setgroups failed: {:?}", e).as_str(),
            );

            e
        })?;
    }
    // NoNewPrivileges
    if oci_process.no_new_privileges {
        capctl::prctl::set_no_new_privs().map_err(|_| anyhow!("cannot set no new privileges"))?;
    }
    // Without NoNewPrivileges, we need to set seccomp
    // before dropping capabilities because the calling thread
    // must have the CAP_SYS_ADMIN.
    start = Instant::now();
    #[cfg(feature = "seccomp")]
    if !oci_process.no_new_privileges {
        if let Some(ref scmp) = linux.seccomp {
            seccomp::init_seccomp(scmp)?;
        }
    }
    let duration_sec = start.elapsed().as_millis();
    start = Instant::now();

    // Drop capabilities
    if oci_process.capabilities.is_some() {
        let c = oci_process.capabilities.as_ref().unwrap();
        capabilities::drop_privileges(cfd_log, c)?;
    }

    let args = oci_process.args.to_vec();
    let env = oci_process.env.to_vec();

    let duration_cap = start.elapsed().as_millis();
    start = Instant::now();
    let mut fifofd = -1;
    if init {
        fifofd = std::env::var(FIFO_FD)?.parse::<i32>().unwrap();
    }

    // cleanup the env inherited from parent
    for (key, _) in env::vars() {
        env::remove_var(key);
    }

    // setup the envs
    for e in env.iter() {
        match valid_env(e) {
            Some((key, value)) => env::set_var(key, value),
            None => log_child!(cfd_log, "invalid env key-value: {:?}", e),
        }
    }

    if env::var_os(HOME_ENV_KEY).is_none() {
        // try to set "HOME" env by uid
        if let Ok(Some(user)) = User::from_uid(Uid::from_raw(guser.uid)) {
            if let Ok(user_home_dir) = user.dir.into_os_string().into_string() {
                env::set_var(HOME_ENV_KEY, user_home_dir);
            }
        }
        // set default home dir as "/" if "HOME" env is still empty
        if env::var_os(HOME_ENV_KEY).is_none() {
            env::set_var(HOME_ENV_KEY, String::from("/"));
        }
    }
    let duration_env = start.elapsed().as_millis();
    start = Instant::now();
    let exec_file = Path::new(&args[0]);
    if !exec_file.exists() {
        //use [] wrap the content that return to the cubelet for error identification.
        find_file(exec_file).ok_or_else(|| {
            anyhow!(
                "[exec file: No such file or directory]the file {} was not found",
                &args[0]
            )
        })?;
    }

    // notify parent that the child's ready to start
    write_sync(cwfd, SYNC_SUCCESS, "")?;
    // Wait until the parent has installed process bookkeeping and stdio
    // forwarding. Fast execs can otherwise exit before passfd output tasks are
    // ready to drain stdout/stderr.
    read_sync_with_timeout(crfd, Duration::from_secs(PARENT_READY_SYNC_TIMEOUT_SECS))?;
    let duration_stat = start.elapsed().as_millis();
    log_child!(
        cfd_log,
        "prestart:{}ms, newns:{}ms, sec:{}ms, cap:{}ms, env:{}ms, sec_stat_cmd:{}ms",
        duration_prestart,
        duration_newns,
        duration_sec,
        duration_cap,
        duration_env,
        duration_stat
    );
    let _ = unistd::close(cfd_log);
    let _ = unistd::close(crfd);
    let _ = unistd::close(cwfd);

    if oci_process.terminal {
        cfg_if::cfg_if! {
            if #[cfg(feature = "standard-oci-runtime")] {
                if let Some(csocket_fd) = csocket_fd {
                    console::setup_master_console(csocket_fd)?;
                } else {
                    return Err(anyhow!("failed to get console master socket fd"));
                }
            }
            else {
                unistd::setsid().context("create a new session")?;
                unsafe { libc::ioctl(0, libc::TIOCSCTTY) };
            }
        }
    }

    if init {
        let fd = fcntl::open(
            format!("/proc/self/fd/{}", fifofd).as_str(),
            OFlag::O_RDONLY | OFlag::O_CLOEXEC,
            Mode::from_bits_truncate(0),
        )?;
        unistd::close(fifofd)?;
        let buf: &mut [u8] = &mut [0];
        unistd::read(fd, buf)?;
    }

    // With NoNewPrivileges, we should set seccomp as close to
    // do_exec as possible in order to reduce the amount of
    // system calls in the seccomp profiles.
    #[cfg(feature = "seccomp")]
    if oci_process.no_new_privileges {
        if let Some(ref scmp) = linux.seccomp {
            seccomp::init_seccomp(scmp)?;
        }
    }

    do_exec(&args);
}

// set_stdio_permissions fixes the permissions of PID 1's STDIO
// within the container to the specified user.
// The ownership needs to match because it is created outside of
// the container and needs to be localized.
fn set_stdio_permissions(uid: Uid) -> Result<()> {
    let meta = fs::metadata("/dev/null")?;
    let fds = [
        std::io::stdin().as_raw_fd(),
        std::io::stdout().as_raw_fd(),
        std::io::stderr().as_raw_fd(),
    ];

    for fd in &fds {
        let stat = stat::fstat(*fd)?;
        // Skip chown of /dev/null if it was used as one of the STDIO fds.
        if stat.st_rdev == meta.rdev() {
            continue;
        }

        // We only change the uid owner (as it is possible for the mount to
        // prefer a different gid, and there's no reason for us to change it).
        // The reason why we don't just leave the default uid=X mount setup is
        // that users expect to be able to actually use their console. Without
        // this code, you couldn't effectively run as a non-root user inside a
        // container and also have a console set up.
        unistd::fchown(*fd, Some(uid), None).with_context(|| "set stdio permissions failed")?;
    }

    Ok(())
}

#[async_trait]
impl BaseContainer for LinuxContainer {
    fn id(&self) -> String {
        self.id.clone()
    }

    fn status(&self) -> ContainerState {
        self.status.status()
    }

    fn state(&self) -> Result<State> {
        Err(anyhow!("not supported"))
    }

    fn oci_state(&self) -> Result<OCIState> {
        let oci = match self.config.spec.as_ref() {
            Some(s) => s,
            None => return Err(anyhow!("Unable to get OCI state: spec not found")),
        };

        let status = self.status();
        let pid = if status != ContainerState::Stopped {
            self.init_process_pid
        } else {
            0
        };

        let root = match oci.root.as_ref() {
            Some(s) => s.path.as_str(),
            None => return Err(anyhow!("Unable to get root path: oci.root is none")),
        };

        let path = fs::canonicalize(root)?;
        let bundle = match path.parent() {
            Some(s) => s.to_str().unwrap().to_string(),
            None => return Err(anyhow!("could not get root parent: root path {:?}", path)),
        };

        Ok(OCIState {
            version: oci.version.clone(),
            id: self.id(),
            status,
            pid,
            bundle,
            annotations: oci.annotations.clone(),
        })
    }

    fn config(&self) -> Result<&Config> {
        Ok(&self.config)
    }

    fn processes(&self) -> Result<Vec<i32>> {
        Ok(self.processes.keys().cloned().collect())
    }

    fn get_process(&mut self, eid: &str) -> Result<&mut Process> {
        for (_, v) in self.processes.iter_mut() {
            if eid == v.exec_id.as_str() {
                return Ok(v);
            }
        }

        Err(anyhow!("invalid eid {}", eid))
    }

    fn stats(&self) -> Result<StatsContainerResponse> {
        let mut r = StatsContainerResponse::default();

        if let Some(manager) = self.cgroup_manager.as_ref() {
            r.cgroup_stats = MessageField::some(manager.get_stats()?);
            r.resource_metrics_version = manager.resource_metrics_version();
        }

        // what about network interface stats?

        Ok(r)
    }

    fn set(&mut self, r: LinuxResources) -> Result<()> {
        if self.cgroup_manager.is_some() {
            self.cgroup_manager.as_ref().unwrap().set(&r, true)?;
        }
        let linux = self.config.spec.as_mut().unwrap().linux.as_mut().unwrap();

        // 合并逻辑：对于 cpu/memory/pids/block_io/hugepage_limits/network，仅当传入为 Some 时更新；否则保留原值。
        // devices 字段直接使用传入值覆盖。
        let mut incoming = r;
        if let Some(mut existing) = linux.resources.take() {
            if incoming.cpu.is_none() {
                incoming.cpu = existing.cpu.take();
            }
            if incoming.memory.is_none() {
                incoming.memory = existing.memory.take();
            }
            if incoming.pids.is_none() {
                incoming.pids = existing.pids.take();
            }
            if incoming.block_io.is_none() {
                incoming.block_io = existing.block_io.take();
            }
            if incoming.hugepage_limits.is_empty() {
                incoming.hugepage_limits = existing.hugepage_limits;
            }
            if incoming.network.is_none() {
                incoming.network = existing.network.take();
            }
        }
        linux.resources = Some(incoming);
        Ok(())
    }

    async fn start(&mut self, mut p: Process) -> Result<()> {
        let logger = self.logger.new(o!("eid" => p.exec_id.clone()));
        //let tty = p.tty;
        let fifo_file = format!("{}/{}", &self.root, EXEC_FIFO_FILENAME);
        let fifofd = if p.init {
            if stat::stat(fifo_file.as_str()).is_ok() {
                return Err(anyhow!("exec fifo exists"));
            }
            unistd::mkfifo(fifo_file.as_str(), Mode::from_bits(0o644).unwrap())?;

            Some(own_fd(fcntl::open(
                fifo_file.as_str(),
                OFlag::O_PATH,
                Mode::from_bits(0).unwrap(),
            )?))
        } else {
            None
        };

        if self.config.spec.is_none() {
            return Err(anyhow!("no spec"));
        }

        let spec = self.config.spec.as_ref().unwrap().clone();
        if spec.linux.is_none() {
            return Err(anyhow!("no linux config"));
        }
        let linux = spec.linux.as_ref().unwrap();

        if p.oci.capabilities.is_none() {
            // No capabilities, inherit from container process
            let process = spec
                .process
                .as_ref()
                .ok_or_else(|| anyhow!("no process config"))?;
            p.oci.capabilities = Some(
                process
                    .capabilities
                    .clone()
                    .ok_or_else(|| anyhow!("missing process capabilities"))?,
            );
        }

        let (pfd_log, cfd_log) = owned_pipe()?;

        let _ = fcntl::fcntl(pfd_log.as_raw_fd(), FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))
            .map_err(|e| warn!(logger, "fcntl pfd log FD_CLOEXEC {:?}", e));

        let child_logger = logger.new(o!("action" => "child process log"));
        let mut log_handler =
            LaunchLogGuard::new(setup_child_logger(pfd_log.into_raw_fd(), child_logger));

        let (prfd, cwfd) = owned_pipe()?;
        let (crfd, pwfd) = owned_pipe()?;

        let _ = fcntl::fcntl(prfd.as_raw_fd(), FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))
            .map_err(|e| warn!(logger, "fcntl prfd FD_CLOEXEC {:?}", e));

        let _ = fcntl::fcntl(pwfd.as_raw_fd(), FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))
            .map_err(|e| warn!(logger, "fcntl pwfd FD_COLEXEC {:?}", e));

        let mut pipe_r = PipeStream::from_fd(prfd.into_raw_fd());
        let mut pipe_w = PipeStream::from_fd(pwfd.into_raw_fd());

        let mut child_stdin = std::process::Stdio::null();
        let mut child_stdout = std::process::Stdio::null();
        let mut child_stderr = std::process::Stdio::null();

        if let Some(stdin) = p.stdin {
            child_stdin = unsafe { std::process::Stdio::from_raw_fd(unistd::dup(stdin)?) };
        }

        if let Some(stdout) = p.stdout {
            child_stdout = unsafe { std::process::Stdio::from_raw_fd(unistd::dup(stdout)?) };
        }

        if let Some(stderr) = p.stderr {
            child_stderr = unsafe { std::process::Stdio::from_raw_fd(unistd::dup(stderr)?) };
        }

        let pidns = get_pid_namespace(&self.logger, linux)?.map(own_fd);

        let exec_path = std::env::current_exe()?;
        let mut child = std::process::Command::new(exec_path);

        #[allow(unused_mut)]
        let mut console_name = PathBuf::from("");
        #[cfg(feature = "standard-oci-runtime")]
        if !self.console_socket.as_os_str().is_empty() {
            console_name = self.console_socket.clone();
        }

        let mut child = child
            .arg("init")
            .stdin(child_stdin)
            .stdout(child_stdout)
            .stderr(child_stderr)
            .env(INIT, format!("{}", p.init))
            .env(NO_PIVOT, format!("{}", self.config.no_pivot_root))
            .env(CRFD_FD, format!("{}", crfd.as_raw_fd()))
            .env(CWFD_FD, format!("{}", cwfd.as_raw_fd()))
            .env(CLOG_FD, format!("{}", cfd_log.as_raw_fd()))
            .env(CONSOLE_SOCKET_FD, console_name);

        if p.init {
            child = child.env(FIFO_FD, format!("{}", fifofd.as_ref().unwrap().as_raw_fd()));
        }

        if let Some(pidns) = pidns.as_ref() {
            child = child.env(PIDNS_FD, format!("{}", pidns.as_raw_fd()));
        }

        let process_attach_paths = self
            .cgroup_manager
            .as_ref()
            .ok_or_else(|| anyhow!("cgroup manager does not exist"))?;
        let process_attach_paths = process_attach_paths.early_process_attach_paths()?;
        child.env(
            EARLY_PROCESS_ATTACH_PATHS,
            serde_json::to_string(&process_attach_paths)
                .context("encode early process cgroup attach paths")?,
        );

        #[cfg(test)]
        if let Some(hook) = self.pre_spawn_hook {
            let mut launch_fds = vec![crfd.as_raw_fd(), cwfd.as_raw_fd(), cfd_log.as_raw_fd()];
            if let Some(fifofd) = fifofd.as_ref() {
                launch_fds.push(fifofd.as_raw_fd());
            }
            hook(&launch_fds)?;
        }

        // Keep the global reaper out from spawn through the successful
        // handshake/reap. ProcessLaunchGuard is declared after this lock, so
        // cancellation kills and reaps the helper before releasing the lock.
        let _wait_locker = WAIT_PID_LOCKER.lock().await;
        let helper = child.spawn()?;
        let helper_pid = helper.id() as pid_t;
        drop(helper);
        let mut launch_guard = ProcessLaunchGuard::new(helper_pid);

        // The child inherited these descriptors at spawn. The parent copies
        // are now released together without fallible, short-circuiting closes.
        drop(crfd);
        drop(cwfd);
        drop(cfd_log);
        drop(fifofd);

        // Drop the agent's copy of child-side stdio fds so EOF on the parent
        // side reflects the real container process lifetime.
        p.close_inherited_write_ends();

        // get container process's pid
        let pid_buf = read_async(&mut pipe_r).await?;
        let pid_str = std::str::from_utf8(&pid_buf).context("get pid string")?;
        let pid = match pid_str.parse::<i32>() {
            Ok(i) => i,
            Err(e) => {
                return Err(anyhow!(format!(
                    "failed to get container process's pid: {:?}",
                    e
                )));
            }
        };

        p.pid = pid;
        self.pending_process_pid = Some(p.pid);

        if p.init {
            self.init_process_pid = p.pid;
        }

        launch_guard.reap()?;
        drop(_wait_locker);

        let st = self.oci_state()?;

        join_namespaces(
            &logger,
            &spec,
            &p,
            self.cgroup_manager.as_ref().unwrap(),
            &st,
            &mut pipe_w,
            &mut pipe_r,
            self.config.resources_v2.is_some(),
        )
        .await
        .map_err(|e| {
            error!(logger, "create container process error {:?}", e);
            // kill the child process.
            let _ = signal::kill(Pid::from_raw(p.pid), Some(Signal::SIGKILL))
                .map_err(|e| warn!(logger, "signal::kill joining namespaces {:?}", e));

            e
        })?;

        if p.init {
            let spec = self.config.spec.as_mut().unwrap();
            update_namespaces(&self.logger, spec, p.pid)?;
        }
        p.setup_passfd_io().await;
        self.processes.insert(p.pid, p);
        self.pending_process_pid = None;
        write_async(&mut pipe_w, SYNC_SUCCESS, "").await?;

        if let Some(log_handler) = log_handler.take() {
            let _ = log_handler
                .await
                .map_err(|e| warn!(logger, "joining log handler {:?}", e));
        }
        debug!(logger, "create process completed");
        Ok(())
    }

    async fn run(&mut self, p: Process) -> Result<()> {
        let init = p.init;
        self.start(p).await?;

        if init {
            self.exec().await?;
            self.status.transition(ContainerState::Running);
        }

        Ok(())
    }

    async fn destroy(&mut self) -> Result<()> {
        let mut errors = self.kill_owned_processes();
        if self.status() != ContainerState::Stopped {
            match self.oci_state() {
                Ok(state) => {
                    if let Some(hooks) = self
                        .config
                        .spec
                        .as_ref()
                        .and_then(|spec| spec.hooks.as_ref())
                    {
                        for hook in &hooks.poststop {
                            if let Err(error) = execute_hook(&self.logger, hook, &state).await {
                                errors.push(format!("poststop hook: {error:#}"));
                            }
                        }
                    }
                }
                Err(error) => errors.push(format!("load OCI state for poststop hooks: {error:#}")),
            }
            self.status.transition(ContainerState::Stopped);
        }

        errors.extend(self.cleanup_owned_resources());
        if errors.is_empty() {
            Ok(())
        } else {
            Err(anyhow!(errors.join("; ")))
        }
    }

    async fn exec(&mut self) -> Result<()> {
        let fifo = format!("{}/{}", &self.root, EXEC_FIFO_FILENAME);
        let fd = fcntl::open(fifo.as_str(), OFlag::O_WRONLY, Mode::from_bits_truncate(0))?;
        let data: &[u8] = &[0];
        unistd::write(fd, data)?;
        self.init_process_start_time = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        self.status.transition(ContainerState::Running);

        let spec = self
            .config
            .spec
            .as_ref()
            .ok_or_else(|| anyhow!("OCI spec was not found"))?;
        let st = self.oci_state()?;

        // run poststart hook
        if spec.hooks.is_some() {
            let hooks = spec
                .hooks
                .as_ref()
                .ok_or_else(|| anyhow!("OCI hooks were not found"))?;
            for h in hooks.poststart.iter() {
                execute_hook(&self.logger, h, &st).await?;
            }
        }

        unistd::close(fd)?;

        Ok(())
    }
}

use std::env;

fn find_file<P>(exe_name: P) -> Option<PathBuf>
where
    P: AsRef<Path>,
{
    env::var_os("PATH").and_then(|paths| {
        env::split_paths(&paths)
            .filter_map(|dir| {
                let full_path = dir.join(&exe_name);
                if full_path.is_file() {
                    Some(full_path)
                } else {
                    None
                }
            })
            .next()
    })
}

fn do_exec(args: &[String]) -> ! {
    let path = &args[0];
    let p = CString::new(path.to_string()).unwrap();
    let sa: Vec<CString> = args
        .iter()
        .map(|s| CString::new(s.to_string()).unwrap_or_default())
        .collect();

    let _ = unistd::execvp(p.as_c_str(), &sa).map_err(|e| match e {
        nix::Error::UnknownErrno => std::process::exit(-2),
        _ => std::process::exit(e as i32),
    });

    unreachable!()
}

fn update_namespaces(_logger: &Logger, spec: &mut Spec, init_pid: RawFd) -> Result<()> {
    let linux = spec
        .linux
        .as_mut()
        .ok_or_else(|| anyhow!("Spec didn't contain linux field"))?;

    let namespaces = linux.namespaces.as_mut_slice();
    for namespace in namespaces.iter_mut() {
        if TYPETONAME.contains_key(namespace.r#type.as_str()) {
            let ns_path = format!(
                "/proc/{}/ns/{}",
                init_pid,
                TYPETONAME.get(namespace.r#type.as_str()).unwrap()
            );

            if namespace.path.is_empty() {
                namespace.path = ns_path;
            }
        }
    }

    Ok(())
}

fn get_pid_namespace(logger: &Logger, linux: &Linux) -> Result<Option<RawFd>> {
    for ns in &linux.namespaces {
        if ns.r#type == "pid" {
            if ns.path.is_empty() {
                return Ok(None);
            }

            let fd =
                fcntl::open(ns.path.as_str(), OFlag::O_RDONLY, Mode::empty()).map_err(|e| {
                    error!(
                        logger,
                        "cannot open type: {} path: {}",
                        ns.r#type.clone(),
                        ns.path.clone()
                    );
                    error!(logger, "error is : {:?}", e);

                    e
                })?;

            return Ok(Some(fd));
        }
    }

    Err(anyhow!("cannot find the pid ns"))
}

fn is_userns_enabled(linux: &Linux) -> bool {
    linux
        .namespaces
        .iter()
        .any(|ns| ns.r#type == "user" && ns.path.is_empty())
}

fn get_namespaces(linux: &Linux) -> Vec<LinuxNamespace> {
    linux
        .namespaces
        .iter()
        .map(|ns| LinuxNamespace {
            r#type: ns.r#type.clone(),
            path: ns.path.clone(),
        })
        .collect()
}

pub fn setup_child_logger(fd: RawFd, child_logger: Logger) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let log_file_stream = PipeStream::from_fd(fd);
        let buf_reader_stream = tokio::io::BufReader::new(log_file_stream);
        let mut lines = buf_reader_stream.lines();

        loop {
            match lines.next_line().await {
                Err(e) => {
                    info!(child_logger, "read child process log error: {:?}", e);
                    break;
                }
                Ok(Some(line)) => {
                    info!(child_logger, "{}", line);
                }
                Ok(None) => {
                    break;
                }
            }
        }
    })
}

async fn join_namespaces(
    logger: &Logger,
    spec: &Spec,
    p: &Process,
    cm: &FsManager,
    st: &OCIState,
    pipe_w: &mut PipeStream,
    pipe_r: &mut PipeStream,
    resources_v2: bool,
) -> Result<()> {
    let logger = logger.new(o!("action" => "join-namespaces"));
    let linux = spec.linux.as_ref().unwrap();
    let res = linux.resources.as_ref();
    let userns = is_userns_enabled(linux);

    let spec_str = serde_json::to_string(spec)?;
    write_async(pipe_w, SYNC_DATA, spec_str.as_str()).await?;

    read_async(pipe_r).await?;

    debug!(logger, "send oci process from parent to child");
    let process_str = serde_json::to_string(&p.oci)?;
    write_async(pipe_w, SYNC_DATA, process_str.as_str()).await?;

    read_async(pipe_r).await?;

    let cm_str = serde_json::to_string(cm)?;
    write_async(pipe_w, SYNC_DATA, cm_str.as_str()).await?;

    // wait child setup user namespace
    debug!(logger, "wait child setup user namespace");
    read_async(pipe_r).await?;

    if userns {
        debug!(logger, "setup uid/gid mappings");
        // setup uid/gid mappings
        write_mappings(
            &logger,
            &format!("/proc/{}/uid_map", p.pid),
            &linux.uid_mappings,
        )?;
        write_mappings(
            &logger,
            &format!("/proc/{}/gid_map", p.pid),
            &linux.gid_mappings,
        )?;
    }

    // apply cgroups
    if p.init && res.is_some() && !resources_v2 {
        debug!(logger, "apply cgroups!");
        cm.set(res.unwrap(), false)?;
    }

    if res.is_some() {
        cm.apply(p.pid)?;
    }

    debug!(logger, "notify child to continue");
    // notify child to continue
    write_async(pipe_w, SYNC_SUCCESS, "").await?;

    if p.init {
        debug!(logger, "notify child parent ready to run prestart hook!");
        read_async(pipe_r).await?;

        debug!(logger, "get ready to run prestart hook!");
        debug!(logger, "hooks: {:?}", spec.hooks);

        // run prestart hook
        if spec.hooks.is_some() {
            let hooks = spec.hooks.as_ref().unwrap();
            for h in hooks.prestart.iter() {
                execute_hook(&logger, h, st).await.map_err(|e| {
                    error!(logger, "prestart hook {h:?} failed: {:?}", e);
                    e
                })?;
            }
            debug!(logger, "all prestart hooks completed successfully");
        }

        // notify child run prestart hooks completed
        write_async(pipe_w, SYNC_SUCCESS, "").await?;
    }

    read_async(pipe_r).await?;
    Ok(())
}

fn write_mappings(logger: &Logger, path: &str, maps: &[LinuxIdMapping]) -> Result<()> {
    let data = maps
        .iter()
        .filter(|m| m.size != 0)
        .map(|m| format!("{} {} {}\n", m.container_id, m.host_id, m.size))
        .collect::<Vec<_>>()
        .join("");

    if !data.is_empty() {
        let fd = fcntl::open(path, OFlag::O_WRONLY, Mode::empty())?;
        defer!(unistd::close(fd).unwrap());
        unistd::write(fd, data.as_bytes()).map_err(|e| {
            info!(logger, "cannot write mapping");
            e
        })?;
    }
    Ok(())
}

fn setid(uid: Uid, gid: Gid) -> Result<()> {
    // set uid/gid
    capctl::prctl::set_keepcaps(true)
        .map_err(|e| anyhow!(e).context("set keep capabilities returned"))?;

    {
        unistd::setresgid(gid, gid, gid)?;
    }
    {
        unistd::setresuid(uid, uid, uid)?;
    }
    // if we change from zero, we lose effective caps
    if uid != Uid::from_raw(0) {
        capabilities::reset_effective()?;
    }

    capctl::prctl::set_keepcaps(false)
        .map_err(|e| anyhow!(e).context("set keep capabilities returned"))?;

    Ok(())
}

impl LinuxContainer {
    fn resources_v2_journal_path(&self) -> PathBuf {
        Path::new(&self.root).join(RESOURCE_V2_JOURNAL_FILENAME)
    }

    fn remember_resource_degraded(
        &mut self,
        error: &crate::cgroups::fs::resources_v2::TransactionError,
    ) {
        if error.kind == crate::cgroups::fs::resources_v2::TransactionFailureKind::Degraded {
            if let Some(degraded) = self.resource_degraded.as_mut() {
                degraded.latest_recovery_error = Some(error.to_string());
                if !error.current_values.is_empty() {
                    degraded.current_values = error.current_values.clone();
                }
                return;
            }
            self.resource_degraded = Some(ResourceDegraded {
                cause: error.cause.clone(),
                rollback_error: error.rollback_error.clone(),
                journal_path: error.journal_path.clone(),
                current_values: error.current_values.clone(),
                latest_recovery_error: None,
            });
        }
    }

    pub fn ensure_resources_healthy(&self, operation: &str) -> Result<()> {
        match self.resource_degraded.as_ref() {
            Some(degraded) => Err(anyhow!(ResourcePreconditionError {
                container_id: self.id.clone(),
                operation: operation.to_string(),
                degraded: degraded.clone(),
            })),
            None => Ok(()),
        }
    }

    pub fn abort_create(&mut self) -> Result<()> {
        let mut errors = self.kill_owned_processes();
        errors.extend(self.cleanup_owned_resources());
        if errors.is_empty() {
            Ok(())
        } else {
            Err(anyhow!(errors.join("; ")))
        }
    }

    fn kill_owned_processes(&mut self) -> Vec<String> {
        let (pids, mut errors) = self.owned_process_ids();
        let pending_pid = self.pending_process_pid;
        let mut released_pids = BTreeSet::new();
        for pid in pids {
            match signal::kill(Pid::from_raw(pid), Some(Signal::SIGKILL)) {
                Ok(()) | Err(Errno::ESRCH) => {
                    released_pids.insert(pid);
                    if pending_pid == Some(pid) {
                        self.pending_process_pid = None;
                    }
                }
                Err(error) => errors.push(format!("kill pid {pid}: {error}")),
            }
        }
        self.processes.retain(|pid, _| !released_pids.contains(pid));
        errors
    }

    fn owned_process_ids(&self) -> (BTreeSet<pid_t>, Vec<String>) {
        let mut errors = Vec::new();
        let mut pids = self.processes.keys().copied().collect::<BTreeSet<_>>();
        if let Some(pid) = self.pending_process_pid.filter(|pid| *pid > 0) {
            pids.insert(pid);
        }
        if let Some(manager) = self.cgroup_manager.as_ref() {
            match manager.get_pids() {
                Ok(cgroup_pids) => pids.extend(cgroup_pids),
                Err(error) => errors.push(format!("get cgroup pids: {error:#}")),
            }
        }
        (pids, errors)
    }

    fn cleanup_owned_resources(&mut self) -> Vec<String> {
        let mut errors = Vec::new();
        let rootfs = Path::new(&self.root).join("rootfs");
        let rootfs_detached = match mount::umount2(rootfs.as_path(), MntFlags::MNT_DETACH) {
            Ok(()) | Err(Errno::EINVAL) | Err(Errno::ENOENT) => true,
            Err(error) => {
                errors.push(format!("detach rootfs {}: {error}", rootfs.display()));
                false
            }
        };

        let cgroup_removed = match self.cgroup_manager.as_mut() {
            Some(manager) => match manager.destroy() {
                Ok(()) => {
                    self.cgroup_manager = None;
                    self.pending_process_pid = None;
                    self.processes.clear();
                    true
                }
                Err(error) => {
                    errors.push(format!("destroy cgroups: {error:#}"));
                    false
                }
            },
            None => true,
        };
        if rootfs_detached && cgroup_removed {
            match fs::remove_dir_all(&self.root) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => errors.push(format!("remove bundle {}: {error}", self.root)),
            }
        }

        errors
    }

    pub fn apply_resources_v2_create(
        &mut self,
    ) -> std::result::Result<(), crate::cgroups::fs::resources_v2::TransactionError> {
        let journal_path = self.resources_v2_journal_path();
        let resources = self
            .config
            .spec
            .as_ref()
            .and_then(|spec| spec.linux.as_ref())
            .and_then(|linux| linux.resources.as_ref())
            .cloned()
            .ok_or_else(|| crate::cgroups::fs::resources_v2::TransactionError {
                kind: crate::cgroups::fs::resources_v2::TransactionFailureKind::Unchanged,
                cause: "resources-v2 create has no Linux resources".to_string(),
                rollback_error: None,
                journal_path: journal_path.clone(),
                current_values: Default::default(),
            })?;
        let manager = self.cgroup_manager.as_ref().ok_or_else(|| {
            crate::cgroups::fs::resources_v2::TransactionError {
                kind: crate::cgroups::fs::resources_v2::TransactionFailureKind::Unchanged,
                cause: "resources-v2 create has no cgroup manager".to_string(),
                rollback_error: None,
                journal_path: journal_path.clone(),
                current_values: Default::default(),
            }
        })?;
        let result = manager.set_resources_v2_create(&resources, &journal_path);
        if let Err(error) = result.as_ref() {
            self.remember_resource_degraded(error);
        }
        result
    }

    pub fn set_resources_v2(
        &mut self,
        incoming: LinuxResources,
    ) -> std::result::Result<(), crate::cgroups::fs::resources_v2::TransactionError> {
        let journal_path = self.resources_v2_journal_path();
        self.recover_resources_v2()?;
        let mut effective = self
            .config
            .spec
            .as_ref()
            .and_then(|spec| spec.linux.as_ref())
            .and_then(|linux| linux.resources.as_ref())
            .cloned()
            .unwrap_or_default();
        crate::cgroups::fs::resources_v2::merge(&mut effective, &incoming).map_err(|error| {
            crate::cgroups::fs::resources_v2::TransactionError {
                kind: crate::cgroups::fs::resources_v2::TransactionFailureKind::Unchanged,
                cause: format!("merge resources-v2 update: {error:#}"),
                rollback_error: None,
                journal_path: journal_path.clone(),
                current_values: Default::default(),
            }
        })?;
        let canonical = crate::resources::canonical_resources(&effective).map_err(|error| {
            crate::cgroups::fs::resources_v2::TransactionError {
                kind: crate::cgroups::fs::resources_v2::TransactionFailureKind::Unchanged,
                cause: format!("persist resources-v2 update: {error:#}"),
                rollback_error: None,
                journal_path: journal_path.clone(),
                current_values: Default::default(),
            }
        })?;
        let manager = self.cgroup_manager.as_ref().ok_or_else(|| {
            crate::cgroups::fs::resources_v2::TransactionError {
                kind: crate::cgroups::fs::resources_v2::TransactionFailureKind::Unchanged,
                cause: "resources-v2 update has no cgroup manager".to_string(),
                rollback_error: None,
                journal_path: journal_path.clone(),
                current_values: Default::default(),
            }
        })?;
        let result = manager.set_resources_v2(&incoming, true, &journal_path);
        if let Err(error) = result.as_ref() {
            self.remember_resource_degraded(error);
        }
        result?;

        self.config
            .spec
            .as_mut()
            .unwrap()
            .linux
            .as_mut()
            .unwrap()
            .resources = Some(effective);
        self.config.resources_v2 = Some(crate::specconv::ResourceV2Config {
            version: crate::resources::RESOURCE_V2_VERSION,
            canonical,
        });
        Ok(())
    }

    pub fn recover_resources_v2(
        &mut self,
    ) -> std::result::Result<(), crate::cgroups::fs::resources_v2::TransactionError> {
        let degraded = match self.resource_degraded.as_ref() {
            Some(degraded) => degraded.clone(),
            None => return Ok(()),
        };
        let manager = match self.cgroup_manager.as_ref() {
            Some(manager) => manager,
            None => {
                let error = crate::cgroups::fs::resources_v2::TransactionError {
                    kind: crate::cgroups::fs::resources_v2::TransactionFailureKind::Degraded,
                    cause: "resources-v2 recovery has no cgroup manager".to_string(),
                    rollback_error: Some("cannot replay undo journal".to_string()),
                    journal_path: degraded.journal_path.clone(),
                    current_values: degraded.current_values.clone(),
                };
                self.remember_resource_degraded(&error);
                return Err(error);
            }
        };
        match manager.replay_resources_v2(&degraded.journal_path) {
            Ok(()) => {
                self.resource_degraded = None;
                Err(crate::cgroups::fs::resources_v2::TransactionError {
                    kind: crate::cgroups::fs::resources_v2::TransactionFailureKind::Recovered,
                    cause: "resources-v2 recovered the previous transaction".to_string(),
                    rollback_error: None,
                    journal_path: degraded.journal_path,
                    current_values: Default::default(),
                })
            }
            Err(error) => {
                self.remember_resource_degraded(&error);
                Err(error)
            }
        }
    }

    pub fn new<T: Into<String> + Display + Clone>(
        id: T,
        base: T,
        config: Config,
        logger: &Logger,
    ) -> Result<Self> {
        let outcome = Self::new_owned(id, base, config, logger)?;
        if let Some(initialization_error) = outcome.initialization_error {
            let mut container = outcome.container;
            return match container.abort_create() {
                Ok(()) => Err(initialization_error),
                Err(cleanup_error) => Err(anyhow!(
                    "{initialization_error:#}; cleanup partially initialized container: {cleanup_error:#}"
                )),
            };
        }
        Ok(outcome.container)
    }

    pub fn new_owned<T: Into<String> + Display + Clone>(
        id: T,
        base: T,
        config: Config,
        logger: &Logger,
    ) -> Result<LinuxContainerCreateOutcome> {
        Self::new_with_manager(id.into(), base.into(), config, logger, |cpath| {
            FsManager::new_owned(cpath)
        })
    }

    fn new_with_manager<CreateManager>(
        id: String,
        base: String,
        config: Config,
        logger: &Logger,
        create_manager: CreateManager,
    ) -> Result<LinuxContainerCreateOutcome>
    where
        CreateManager: FnOnce(&str) -> Result<crate::cgroups::ManagerCreateOutcome<FsManager>>,
    {
        let root = format!("{}/{}", base.as_str(), id.as_str());

        // validate oci spec
        validator::validate(&config)?;

        fs::create_dir_all(root.as_str()).map_err(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                return anyhow!(e).context(format!("container {} already exists", id.as_str()));
            }

            anyhow!(e).context(format!("fail to create container directory {}", root))
        })?;

        unistd::chown(
            root.as_str(),
            Some(unistd::getuid()),
            Some(unistd::getgid()),
        )
        .context(format!("cannot change owner of container {} root", id))?;

        if config.spec.is_none() {
            return Err(anyhow!(nix::Error::EINVAL));
        }

        let spec = config.spec.as_ref().unwrap();

        if spec.linux.is_none() {
            return Err(anyhow!(nix::Error::EINVAL));
        }

        let linux = spec.linux.as_ref().unwrap();

        let cpath = if linux.cgroups_path.is_empty() {
            format!("/{}", id.as_str())
        } else {
            linux.cgroups_path.clone()
        };

        let start = Instant::now();
        let cgroup_outcome = create_manager(cpath.as_str())?;
        let duration = start.elapsed().as_millis();
        info!(
            logger,
            "[cube-strace]finish new cgroup_manager {}, cost:{}ms",
            cpath.as_str(),
            duration
        );

        Ok(LinuxContainerCreateOutcome {
            container: LinuxContainer {
                id: id.clone(),
                root,
                cgroup_manager: Some(cgroup_outcome.manager),
                status: ContainerStatus::new(),
                uid_map_path: String::from(""),
                gid_map_path: "".to_string(),
                config,
                processes: HashMap::new(),
                created: SystemTime::now(),
                init_process_pid: -1,
                pending_process_pid: None,
                init_process_start_time: SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap()
                    .as_secs(),
                logger: logger
                    .new(o!("module" => "rustjail", "subsystem" => "container", "cid" => id)),
                resource_degraded: None,
                #[cfg(test)]
                pre_spawn_hook: None,
                #[cfg(feature = "standard-oci-runtime")]
                console_socket: Path::new("").to_path_buf(),
            },
            initialization_error: cgroup_outcome.initialization_error,
        })
    }

    #[cfg(feature = "standard-oci-runtime")]
    pub fn set_console_socket(&mut self, console_socket: &Path) -> Result<()> {
        self.console_socket = console_socket.to_path_buf();
        Ok(())
    }
}

use std::fs::OpenOptions;
use std::io::Write;

fn set_sysctls(sysctls: &HashMap<String, String>) -> Result<()> {
    for (key, value) in sysctls {
        let name = format!("/proc/sys/{}", key.replace('.', "/"));
        let mut file = match OpenOptions::new()
            .read(true)
            .write(true)
            .create(false)
            .open(name.as_str())
        {
            Ok(f) => f,
            Err(e) => {
                if e.kind() == std::io::ErrorKind::NotFound {
                    continue;
                }
                return Err(e.into());
            }
        };

        file.write_all(value.as_bytes())?;
    }

    Ok(())
}

use std::process::Stdio;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub async fn execute_hook(logger: &Logger, h: &Hook, st: &OCIState) -> Result<()> {
    let logger = logger.new(o!("action" => "execute-hook"));
    let logger2 = logger.clone();
    let binary = PathBuf::from(h.path.as_str());
    let path = binary.canonicalize()?;
    if !path.exists() {
        return Err(anyhow!(nix::Error::EINVAL));
    }

    // OCI runtime-spec: hook.args has the same semantics as POSIX execve argv:
    // it represents the full argv array, where args[0] is argv[0] (often the
    // binary name, but may differ from path). `Command::new()` already sets
    // argv[0] to the program path by default, so we must use arg0() to honor
    // args[0] when it is provided.
    let args = h.args.clone();

    // all invalid envs will be omitted, only valid envs will be passed to hook.
    let env: HashMap<&str, &str> = h.env.iter().filter_map(|e| valid_env(e)).collect();

    // Avoid the exit signal to be reaped by the global reaper.
    let _wait_locker = WAIT_PID_LOCKER.lock().await;
    let mut cmd = tokio::process::Command::new(path);

    // 临时兼容：由于cubelet之前错误的拼装了OCI prestart hook的args，导致args[0]是prestart而不是路径，这里临时兼容一下。
    // 后续需要删除这个兼容。
    if h.path.ends_with("/nvidia-container-runtime-hook")
        && args.len() == 1
        && args[0] == "prestart"
    {
        cmd.args(args.iter());
    } else if let Some((argv0, rest)) = args.split_first() {
        cmd.arg0(argv0).args(rest);
    }

    let mut child = cmd
        .envs(env.iter())
        .kill_on_drop(true)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    // default timeout 10s
    let mut timeout: u64 = 10;

    // if timeout is set if hook, then use the specified value
    if let Some(t) = h.timeout {
        if t > 0 {
            timeout = t as u64;
        }
    }

    let state = serde_json::to_string(st)?;
    let path = h.path.clone();

    let join_handle = tokio::spawn(async move {
        if let Some(mut stdin) = child.stdin.take() {
            match stdin.write_all(state.as_bytes()).await {
                Ok(_) => {}
                Err(e) => {
                    info!(logger, "write to child stdin failed: {:?}", e);
                }
            }
        }

        // read something from stdout and stderr for debug
        if let Some(stdout) = child.stdout.as_mut() {
            let mut out = String::new();
            match stdout.read_to_string(&mut out).await {
                Ok(_) => {}
                Err(e) => {
                    info!(logger, "read from child stdout failed: {:?}", e);
                }
            }
        }

        let mut err = String::new();
        if let Some(stderr) = child.stderr.as_mut() {
            match stderr.read_to_string(&mut err).await {
                Ok(_) => {}
                Err(e) => {
                    info!(logger, "read from child stderr failed: {:?}", e);
                }
            }
        }

        match child.wait().await {
            Ok(exit) => {
                let code = exit
                    .code()
                    .ok_or_else(|| anyhow!("hook exit status has no status code"))?;

                if code != 0 {
                    error!(
                        logger,
                        "hook {} exit status is {}, error message is {}", &path, code, err
                    );
                    return Err(anyhow!(nix::Error::UnknownErrno));
                }

                debug!(logger, "hook {} exit status is 0", &path);
                Ok(())
            }
            Err(e) => Err(anyhow!(
                "wait child error: {} {}",
                e,
                e.raw_os_error().unwrap()
            )),
        }
    });
    match tokio::time::timeout(Duration::new(timeout, 0), join_handle).await {
        Ok(r) => match r {
            Ok(hook_result) => hook_result,
            Err(join_err) => {
                error!(logger2, "hook join error: {:?}", join_err);
                Err(anyhow!(join_err))
            }
        },
        Err(e) => {
            error!(logger2, "timeout error: {:?}", e);
            Err(anyhow!(nix::Error::ETIMEDOUT))
        }
    }
}

// valid environment variables according to https://doc.rust-lang.org/std/env/fn.set_var.html#panics
fn valid_env(e: &str) -> Option<(&str, &str)> {
    // wherther key or value will contain NULL char.
    if e.as_bytes().contains(&b'\0') {
        return None;
    }

    let v: Vec<&str> = e.splitn(2, '=').collect();

    // key can't hold an `equal` sign, but value can
    if v.len() != 2 {
        return None;
    }

    let (key, value) = (v[0].trim(), v[1].trim());

    // key can't be empty
    if key.is_empty() {
        return None;
    }

    Some((key, value))
}

pub async fn start_exec_process(
    pid: pid_t,
    exec_mnts: Option<&String>,
    propa_umnts: Option<&String>,
) -> Result<(), String> {
    println!("exec a child process");
    let exec_path = std::env::current_exe().map_err(|e| format!("get exe path failed:{}", e))?;
    let mut cmd = std::process::Command::new(exec_path);
    cmd.arg("exec")
        .env(ENV_CONTAINER_PID, format!("{}", pid))
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    if let Some(mnt) = exec_mnts {
        cmd.env(ANNO_PROPAGATION_EXEC_MNTS, format!("{}", mnt));
    }

    if let Some(mnt) = propa_umnts {
        cmd.env(ANNO_PROPAGATION_CONTAINER_UMNTS, format!("{}", mnt));
    }
    let _lock = WAIT_PID_LOCKER.lock().await;

    let child = cmd
        .spawn()
        .map_err(|e| format!("spawn child process failed:{}", e))?;
    let output = child
        .wait_with_output()
        .map_err(|e| format!("wait child failed:{}", e))?;
    match output.status.code() {
        Some(code) => {
            if code != 0 {
                // Surface the child's real failure reason (e.g.
                // "the source dir X not exists") instead of a bare
                // exit code. exit_proc_failed writes to stderr.
                let detail = String::from_utf8_lossy(&output.stderr);
                let detail = if detail.trim().is_empty() {
                    String::from_utf8_lossy(&output.stdout)
                } else {
                    detail
                };
                let detail = detail.trim();
                if detail.is_empty() {
                    return Err(format!("exec process exit code:{}", code));
                }
                return Err(detail.to_string());
            }
        }
        None => {
            return Err("exec process terminated by signal".to_string());
        }
    }

    // On success, log child stdout for observability (was previously
    // inherited to the agent's stdout before piping was added).
    let stdout = String::from_utf8_lossy(&output.stdout);
    if !stdout.trim().is_empty() {
        debug!(
            slog_scope::logger(),
            "exec mount child output: {}",
            stdout.trim()
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::io::AsRawFd;

    use nix::unistd::Uid;
    use tempfile::tempdir;
    use tokio::process::Command;

    use super::*;
    use crate::process::Process;
    use crate::skip_if_not_root;

    macro_rules! sl {
        () => {
            slog_scope::logger()
        };
    }

    static PRE_SPAWN_FDS: std::sync::Mutex<Vec<(RawFd, PathBuf)>> =
        std::sync::Mutex::new(Vec::new());

    fn reject_before_spawn(fds: &[RawFd]) -> Result<()> {
        *PRE_SPAWN_FDS.lock().unwrap() = fds
            .iter()
            .map(|fd| {
                (
                    *fd,
                    fs::read_link(format!("/proc/self/fd/{fd}"))
                        .expect("launch fd must exist before injected failure"),
                )
            })
            .collect();
        Err(anyhow!("injected pre-spawn failure"))
    }

    fn assert_pipe_writer_closed(observer: RawFd) {
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let mut byte = [0u8; 1];
            match unistd::read(observer, &mut byte) {
                Ok(0) => return,
                Err(Errno::EAGAIN) | Err(Errno::EINTR) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                result => panic!("process-owned pipe writer remained open: {result:?}"),
            }
        }
    }

    async fn which(cmd: &str) -> String {
        let output: std::process::Output = Command::new("which")
            .arg(cmd)
            .output()
            .await
            .expect("which command failed to run");

        match String::from_utf8(output.stdout) {
            Ok(v) => v.trim_end_matches('\n').to_string(),
            Err(e) => panic!("Invalid UTF-8 sequence: {}", e),
        }
    }

    #[tokio::test]
    async fn test_execute_hook() {
        let temp_file = "/tmp/test_execute_hook";

        let touch = which("touch").await;

        defer!(fs::remove_file(temp_file).unwrap(););
        let invalid_str = vec![97, b'\0', 98];
        let invalid_string = std::str::from_utf8(&invalid_str).unwrap();
        let invalid_env = format!("{}=value", invalid_string);

        execute_hook(
            &slog_scope::logger(),
            &Hook {
                path: touch,
                args: vec!["touch".to_string(), temp_file.to_string()],
                env: vec![invalid_env],
                timeout: Some(10),
            },
            &OCIState {
                version: "1.2.3".to_string(),
                id: "321".to_string(),
                status: ContainerState::Running,
                pid: 2,
                bundle: "".to_string(),
                annotations: Default::default(),
            },
        )
        .await
        .unwrap();

        assert_eq!(Path::new(&temp_file).exists(), true);
    }

    #[tokio::test]
    async fn test_execute_hook_with_error() {
        let false_bin = which("false").await;

        let res = execute_hook(
            &slog_scope::logger(),
            &Hook {
                path: false_bin,
                args: vec!["false".to_string()],
                env: vec![],
                timeout: None,
            },
            &OCIState {
                version: "1.2.3".to_string(),
                id: "321".to_string(),
                status: ContainerState::Running,
                pid: 2,
                bundle: "".to_string(),
                annotations: Default::default(),
            },
        )
        .await;

        let expected_err = nix::Error::UnknownErrno;
        assert_eq!(
            res.unwrap_err().downcast::<nix::Error>().unwrap(),
            expected_err
        );
    }

    #[tokio::test]
    async fn test_execute_hook_with_timeout() {
        let sleep = which("sleep").await;

        let res = execute_hook(
            &slog_scope::logger(),
            &Hook {
                path: sleep,
                args: vec!["sleep".to_string(), "2".to_string()],
                env: vec![],
                timeout: Some(1),
            },
            &OCIState {
                version: "1.2.3".to_string(),
                id: "321".to_string(),
                status: ContainerState::Running,
                pid: 2,
                bundle: "".to_string(),
                annotations: Default::default(),
            },
        )
        .await;

        let expected_err = nix::Error::ETIMEDOUT;
        assert_eq!(
            res.unwrap_err().downcast::<nix::Error>().unwrap(),
            expected_err
        );
    }

    #[test]
    fn test_status_transtition() {
        let mut status = ContainerStatus::new();
        let status_table: [ContainerState; 4] = [
            ContainerState::Created,
            ContainerState::Running,
            ContainerState::Paused,
            ContainerState::Stopped,
        ];

        for s in status_table.iter() {
            let pre_status = status.status();
            status.transition(*s);

            assert_eq!(pre_status, status.pre_status);
        }
    }

    #[test]
    fn test_set_stdio_permissions() {
        skip_if_not_root!();

        let meta = fs::metadata("/dev/stdin").unwrap();
        let old_uid = meta.uid();

        let uid = 1000;
        set_stdio_permissions(Uid::from_raw(uid)).unwrap();

        let meta = fs::metadata("/dev/stdin").unwrap();
        assert_eq!(meta.uid(), uid);

        let meta = fs::metadata("/dev/stdout").unwrap();
        assert_eq!(meta.uid(), uid);

        let meta = fs::metadata("/dev/stderr").unwrap();
        assert_eq!(meta.uid(), uid);

        // restore the uid
        set_stdio_permissions(Uid::from_raw(old_uid)).unwrap();
    }

    #[test]
    fn test_namespaces() {
        lazy_static::initialize(&NAMESPACES);
        assert_eq!(NAMESPACES.len(), 7);

        let ns = NAMESPACES.get("user");
        assert!(ns.is_some());

        let ns = NAMESPACES.get("ipc");
        assert!(ns.is_some());

        let ns = NAMESPACES.get("pid");
        assert!(ns.is_some());

        let ns = NAMESPACES.get("network");
        assert!(ns.is_some());

        let ns = NAMESPACES.get("mount");
        assert!(ns.is_some());

        let ns = NAMESPACES.get("uts");
        assert!(ns.is_some());

        let ns = NAMESPACES.get("cgroup");
        assert!(ns.is_some());
    }

    #[test]
    fn test_typetoname() {
        lazy_static::initialize(&TYPETONAME);
        assert_eq!(TYPETONAME.len(), 7);

        let ns = TYPETONAME.get("user");
        assert!(ns.is_some());

        let ns = TYPETONAME.get("ipc");
        assert!(ns.is_some());

        let ns = TYPETONAME.get("pid");
        assert!(ns.is_some());

        let ns = TYPETONAME.get("network");
        assert!(ns.is_some());

        let ns = TYPETONAME.get("mount");
        assert!(ns.is_some());

        let ns = TYPETONAME.get("uts");
        assert!(ns.is_some());

        let ns = TYPETONAME.get("cgroup");
        assert!(ns.is_some());
    }

    fn create_dummy_opts() -> CreateOpts {
        let mut root = oci::Root::default();
        root.path = "/tmp".to_string();

        let linux = Linux::default();
        let mut spec = Spec::default();
        spec.root = Some(root).into();
        spec.linux = Some(linux).into();

        CreateOpts {
            cgroup_name: "".to_string(),
            use_systemd_cgroup: false,
            no_pivot_root: false,
            no_new_keyring: false,
            spec: Some(spec),
            rootless_euid: false,
            rootless_cgroup: false,
            resources_v2: None,
        }
    }

    fn new_linux_container() -> (Result<LinuxContainer>, tempfile::TempDir) {
        // Create a temporal directory
        let dir = tempdir()
            .map_err(|e| anyhow!(e).context("tempdir failed"))
            .unwrap();

        // Create a new container
        (
            LinuxContainer::new(
                "some_id",
                &dir.path().join("rootfs").to_str().unwrap(),
                create_dummy_opts(),
                &slog_scope::logger(),
            ),
            dir,
        )
    }

    fn new_linux_container_and_then<U, F: FnOnce(LinuxContainer) -> Result<U, anyhow::Error>>(
        op: F,
    ) -> Result<U, anyhow::Error> {
        let (container, _dir) = new_linux_container();
        container.and_then(op)
    }

    #[test]
    fn test_linuxcontainer_pause_bad_status() {
        let ret = new_linux_container_and_then(|mut c: LinuxContainer| {
            // Change state to pause, c.pause() should fail
            c.status.transition(ContainerState::Paused);
            c.pause().map_err(|e| anyhow!(e))
        });

        assert!(ret.is_err(), "Expecting error, Got {:?}", ret);
        assert!(format!("{:?}", ret).contains("failed to pause container"))
    }

    #[test]
    fn test_linuxcontainer_pause_cgroupmgr_is_none() {
        let ret = new_linux_container_and_then(|mut c: LinuxContainer| {
            c.cgroup_manager = None;
            c.pause().map_err(|e| anyhow!(e))
        });

        assert!(ret.is_err(), "Expecting error, Got {:?}", ret);
    }

    #[test]
    fn test_linuxcontainer_pause() {
        let ret = new_linux_container_and_then(|mut c: LinuxContainer| {
            c.cgroup_manager = FsManager::new("").ok();
            c.pause().map_err(|e| anyhow!(e))
        });

        assert!(ret.is_ok(), "Expecting Ok, Got {:?}", ret);
    }

    #[test]
    fn test_linuxcontainer_resume_bad_status() {
        let ret = new_linux_container_and_then(|mut c: LinuxContainer| {
            // Change state to created, c.resume() should fail
            c.status.transition(ContainerState::Created);
            c.resume().map_err(|e| anyhow!(e))
        });

        assert!(ret.is_err(), "Expecting error, Got {:?}", ret);
        assert!(format!("{:?}", ret).contains("not paused"))
    }

    #[test]
    fn test_linuxcontainer_resume_cgroupmgr_is_none() {
        let ret = new_linux_container_and_then(|mut c: LinuxContainer| {
            c.status.transition(ContainerState::Paused);
            c.cgroup_manager = None;
            c.resume().map_err(|e| anyhow!(e))
        });

        assert!(ret.is_err(), "Expecting error, Got {:?}", ret);
    }

    #[test]
    fn test_linuxcontainer_resume() {
        let ret = new_linux_container_and_then(|mut c: LinuxContainer| {
            c.cgroup_manager = FsManager::new("").ok();
            // Change status to paused, this way we can resume it
            c.status.transition(ContainerState::Paused);
            c.resume().map_err(|e| anyhow!(e))
        });

        assert!(ret.is_ok(), "Expecting Ok, Got {:?}", ret);
    }

    #[test]
    fn test_linuxcontainer_state() {
        let ret = new_linux_container_and_then(|c: LinuxContainer| c.state());
        assert!(ret.is_err(), "Expecting Err, Got {:?}", ret);
        assert!(
            format!("{:?}", ret).contains("not supported"),
            "Got: {:?}",
            ret
        )
    }

    #[test]
    fn test_linuxcontainer_oci_state_no_root_parent() {
        let ret = new_linux_container_and_then(|mut c: LinuxContainer| {
            c.config.spec.as_mut().unwrap().root.as_mut().unwrap().path = "/".to_string();
            c.oci_state()
        });
        assert!(ret.is_err(), "Expecting Err, Got {:?}", ret);
        assert!(
            format!("{:?}", ret).contains("could not get root parent"),
            "Got: {:?}",
            ret
        )
    }

    #[test]
    fn test_linuxcontainer_oci_state() {
        let ret = new_linux_container_and_then(|c: LinuxContainer| c.oci_state());
        assert!(ret.is_ok(), "Expecting Ok, Got {:?}", ret);
    }

    #[test]
    fn test_linuxcontainer_config() {
        let ret = new_linux_container_and_then(|c: LinuxContainer| Ok(c));
        assert!(ret.is_ok(), "Expecting ok, Got {:?}", ret);
        assert!(
            ret.as_ref().unwrap().config().is_ok(),
            "Expecting ok, Got {:?}",
            ret
        );
    }

    #[test]
    fn test_linuxcontainer_processes() {
        let ret = new_linux_container_and_then(|c: LinuxContainer| c.processes());
        assert!(ret.is_ok(), "Expecting Ok, Got {:?}", ret);
    }

    #[test]
    fn test_linuxcontainer_get_process_not_found() {
        let _ = new_linux_container_and_then(|mut c: LinuxContainer| {
            let p = c.get_process("123");
            assert!(p.is_err(), "Expecting Err, Got {:?}", p);
            Ok(())
        });
    }

    #[test]
    fn test_linuxcontainer_get_process() {
        let _ = new_linux_container_and_then(|mut c: LinuxContainer| {
            c.processes.insert(
                1,
                Process::new(&sl!(), &oci::Process::default(), "123", true, 1).unwrap(),
            );
            let p = c.get_process("123");
            assert!(p.is_ok(), "Expecting Ok, Got {:?}", p);
            Ok(())
        });
    }

    #[test]
    fn test_linuxcontainer_stats() {
        let ret = new_linux_container_and_then(|c: LinuxContainer| c.stats());
        assert!(ret.is_ok(), "Expecting Ok, Got {:?}", ret);
        assert_eq!(ret.unwrap().resource_metrics_version(), 1);
    }

    #[test]
    fn test_linuxcontainer_without_cgroup_manager_does_not_claim_resource_metrics() {
        let ret = new_linux_container_and_then(|mut c: LinuxContainer| {
            c.cgroup_manager = None;
            c.stats()
        });
        assert!(ret.is_ok(), "Expecting Ok, Got {:?}", ret);
        assert_eq!(ret.unwrap().resource_metrics_version(), 0);
    }

    #[test]
    fn test_linuxcontainer_set() {
        let ret = new_linux_container_and_then(|mut c: LinuxContainer| {
            c.set(oci::LinuxResources::default())
        });
        assert!(ret.is_ok(), "Expecting Ok, Got {:?}", ret);
    }

    #[test]
    fn resource_degraded_blocks_new_work() {
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        container.resource_degraded = Some(ResourceDegraded {
            cause: "injected rollback failure".to_string(),
            rollback_error: Some("restore cpu.max".to_string()),
            journal_path: PathBuf::from("/tmp/resources-v2.undo.json"),
            current_values: Default::default(),
            latest_recovery_error: None,
        });

        let error = container.ensure_resources_healthy("exec").unwrap_err();
        let error = error.downcast_ref::<ResourcePreconditionError>().unwrap();
        assert_eq!(error.container_id, "some_id");
        assert_eq!(error.operation, "exec");
        assert_eq!(error.degraded.cause, "injected rollback failure");
    }

    #[test]
    fn degraded_update_replays_only_and_requires_retry() {
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        let journal_path = container.resources_v2_journal_path();
        fs::write(&journal_path, br#"{"version":1,"entries":[]}"#).unwrap();
        container.resource_degraded = Some(ResourceDegraded {
            cause: "injected rollback failure".to_string(),
            rollback_error: Some("restore cpu.max".to_string()),
            journal_path: journal_path.clone(),
            current_values: Default::default(),
            latest_recovery_error: None,
        });

        let error = container
            .set_resources_v2(LinuxResources::default())
            .unwrap_err();
        assert_eq!(
            error.kind,
            crate::cgroups::fs::resources_v2::TransactionFailureKind::Recovered
        );
        assert!(container.resource_degraded.is_none());
        assert!(!journal_path.exists());
    }

    #[test]
    fn failed_degraded_replay_remains_fail_stopped() {
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        let journal_path = container.resources_v2_journal_path();
        fs::write(&journal_path, b"not-json").unwrap();
        container.resource_degraded = Some(ResourceDegraded {
            cause: "injected rollback failure".to_string(),
            rollback_error: None,
            journal_path: journal_path.clone(),
            current_values: Default::default(),
            latest_recovery_error: None,
        });

        let error = container
            .set_resources_v2(LinuxResources::default())
            .unwrap_err();
        assert_eq!(
            error.kind,
            crate::cgroups::fs::resources_v2::TransactionFailureKind::Degraded
        );
        let degraded = container.resource_degraded.as_ref().unwrap();
        assert_eq!(degraded.journal_path, journal_path);
        assert_eq!(degraded.cause, "injected rollback failure");
        assert!(degraded
            .latest_recovery_error
            .as_deref()
            .unwrap()
            .contains("load undo journal"));
    }

    #[test]
    fn missing_cgroup_recovery_preserves_original_diagnosis() {
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        container.cgroup_manager = None;
        container.resource_degraded = Some(ResourceDegraded {
            cause: "original transaction failed".to_string(),
            rollback_error: Some("restore cpu.max".to_string()),
            journal_path: container.resources_v2_journal_path(),
            current_values: Default::default(),
            latest_recovery_error: None,
        });

        let error = container.recover_resources_v2().unwrap_err();
        assert_eq!(
            error.kind,
            crate::cgroups::fs::resources_v2::TransactionFailureKind::Degraded
        );
        let degraded = container.resource_degraded.as_ref().unwrap();
        assert_eq!(degraded.cause, "original transaction failed");
        assert_eq!(degraded.rollback_error.as_deref(), Some("restore cpu.max"));
        assert!(degraded
            .latest_recovery_error
            .as_deref()
            .unwrap()
            .contains("no cgroup manager"));
    }

    #[test]
    fn abort_create_is_idempotent() {
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        assert!(container.abort_create().is_ok());
        assert!(container.cgroup_manager.is_none());
        assert!(container.abort_create().is_ok());
    }

    #[test]
    fn owned_process_candidates_cover_transient_process_not_stale_init() {
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        container.init_process_pid = 424_242;

        let (pids, errors) = container.owned_process_ids();
        assert!(errors.is_empty());
        assert!(pids.is_empty(), "stale long-term init PID may be reused");

        container.pending_process_pid = Some(222_222);
        let (pids, errors) = container.owned_process_ids();
        assert!(errors.is_empty());
        assert_eq!(pids, BTreeSet::from([222_222]));

        container.pending_process_pid = None;
        let (pids, errors) = container.owned_process_ids();
        assert!(errors.is_empty());
        assert!(pids.is_empty());
    }

    #[test]
    fn fork_child_attach_preserves_exact_pids_limit_and_cleans_rejection() {
        let target = crate::cgroups::fs::process_cgroup_procs_path("/pod/container").unwrap();
        assert_eq!(
            target,
            PathBuf::from("/sys/fs/cgroup/pod/container/runtime/cgroup.procs")
        );
        let pids_one_occupancy = std::cell::Cell::new(0usize);
        let cleaned = std::cell::Cell::new(false);
        attach_fork_child_before_report(
            std::slice::from_ref(&target),
            101,
            |actual_target, _| {
                assert_eq!(actual_target, target);
                if pids_one_occupancy.get() >= 1 {
                    return Err(anyhow!("pids.max rejected child"));
                }
                pids_one_occupancy.set(pids_one_occupancy.get() + 1);
                Ok(())
            },
            |_| {
                cleaned.set(true);
                Ok(())
            },
        )
        .unwrap();
        assert!(!cleaned.get());
        assert_eq!(pids_one_occupancy.get(), 1);

        let cleaned = std::cell::Cell::new(false);
        let error = attach_fork_child_before_report(
            std::slice::from_ref(&target),
            202,
            |_, _| Err(anyhow!("pids.max=0 rejected child")),
            |_| {
                cleaned.set(true);
                Ok(())
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("attach fork child to cgroup"));
        assert!(cleaned.get());
    }

    #[test]
    fn fork_child_attach_writes_every_v1_controller_before_report() {
        let targets = vec![
            PathBuf::from("/sys/fs/cgroup/cpu/pod/container/tasks"),
            PathBuf::from("/sys/fs/cgroup/memory/pod/container/tasks"),
        ];
        let attached = std::cell::RefCell::new(Vec::new());
        attach_fork_child_before_report(
            &targets,
            303,
            |target, pid| {
                attached.borrow_mut().push((target.to_path_buf(), pid));
                Ok(())
            },
            |_| panic!("successful cgroup v1 attach must not clean the child"),
        )
        .unwrap();
        assert_eq!(
            attached.into_inner(),
            vec![(targets[0].clone(), 303), (targets[1].clone(), 303)]
        );
    }

    #[test]
    fn successful_process_launch_guard_reaps_helper_immediately() {
        let child = std::process::Command::new("/bin/true").spawn().unwrap();
        let pid = child.id() as pid_t;
        drop(child);
        let mut guard = ProcessLaunchGuard::new(pid);
        guard.reap().unwrap();
        assert!(!guard.armed);
        assert_eq!(
            nix::sys::wait::waitpid(
                Pid::from_raw(pid),
                Some(nix::sys::wait::WaitPidFlag::WNOHANG)
            ),
            Err(Errno::ECHILD)
        );
    }

    #[test]
    fn cancelled_process_launch_guard_kills_and_reaps_helper() {
        let child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = child.id() as pid_t;
        drop(child);
        drop(ProcessLaunchGuard::new(pid));
        assert_eq!(
            nix::sys::wait::waitpid(
                Pid::from_raw(pid),
                Some(nix::sys::wait::WaitPidFlag::WNOHANG)
            ),
            Err(Errno::ECHILD)
        );
    }

    #[tokio::test]
    async fn pre_spawn_failure_closes_launch_fds_and_aborts_log_handler() {
        struct DropSignal(Option<tokio::sync::oneshot::Sender<()>>);
        impl Drop for DropSignal {
            fn drop(&mut self) {
                if let Some(sender) = self.0.take() {
                    let _ = sender.send(());
                }
            }
        }

        let (dropped_tx, dropped_rx) = tokio::sync::oneshot::channel();
        let signal = DropSignal(Some(dropped_tx));
        let handler = tokio::spawn(async move {
            let _signal = signal;
            std::future::pending::<()>().await;
        });
        drop(LaunchLogGuard::new(handler));
        tokio::time::timeout(Duration::from_secs(1), dropped_rx)
            .await
            .unwrap()
            .unwrap();

        PRE_SPAWN_FDS.lock().unwrap().clear();
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        container.pre_spawn_hook = Some(reject_before_spawn);
        container
            .config
            .spec
            .as_mut()
            .unwrap()
            .linux
            .as_mut()
            .unwrap()
            .namespaces
            .push(LinuxNamespace {
                r#type: oci::PIDNAMESPACE.to_string(),
                path: String::new(),
            });
        let mut process =
            Process::new(&sl!(), &oci::Process::default(), "pre-spawn", false, 1).unwrap();
        process.oci.capabilities = Some(Default::default());

        let error = container.start(process).await.unwrap_err();
        assert!(
            error.to_string().contains("injected pre-spawn failure"),
            "unexpected start error: {error:#}"
        );
        let fds = PRE_SPAWN_FDS.lock().unwrap().clone();
        assert_eq!(fds.len(), 3, "sync read/write and child-log fds");
        for (fd, identity) in fds {
            assert_ne!(
                fs::read_link(format!("/proc/self/fd/{fd}")).ok(),
                Some(identity),
                "pre-spawn failure retained its original launch fd"
            );
        }
    }

    #[test]
    fn abort_create_retries_cgroup_cleanup_before_removing_bundle() {
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        let bundle = PathBuf::from(&container.root);
        fs::create_dir_all(bundle.join("rootfs")).unwrap();
        container.cgroup_manager.as_mut().unwrap().fail_destroy_once = true;

        let first = container.abort_create().unwrap_err();
        assert!(first
            .to_string()
            .contains("injected cgroup destroy failure"));
        assert!(container.cgroup_manager.is_some());
        assert!(
            bundle.exists(),
            "bundle must remain while cgroup cleanup is pending"
        );

        container.abort_create().unwrap();
        assert!(container.cgroup_manager.is_none());
        assert!(!bundle.exists());
    }

    #[test]
    fn partial_cgroup_initialization_retains_owner_across_delete_failure() {
        let dir = tempdir().unwrap();
        let creation = LinuxContainer::new_with_manager(
            "partial-cgroup".to_string(),
            dir.path().to_str().unwrap().to_string(),
            create_dummy_opts(),
            &slog_scope::logger(),
            |cpath| {
                let mut manager = FsManager::new(cpath)?;
                manager.fail_destroy_once = true;
                Ok(crate::cgroups::ManagerCreateOutcome {
                    manager,
                    initialization_error: Some(anyhow!(
                        "injected process leaf initialization failure"
                    )),
                })
            },
        )
        .unwrap();
        assert!(creation
            .initialization_error
            .as_ref()
            .unwrap()
            .to_string()
            .contains("process leaf"));
        let mut container = creation.container;
        let bundle = PathBuf::from(&container.root);

        let first = container.abort_create().unwrap_err();
        assert!(first
            .to_string()
            .contains("injected cgroup destroy failure"));
        assert!(container.cgroup_manager.is_some());
        assert!(bundle.exists());

        container.abort_create().unwrap();
        assert!(container.cgroup_manager.is_none());
        assert!(!bundle.exists());
    }

    #[test]
    fn abort_create_drops_removed_process_and_closes_its_fds() {
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        let first = unistd::pipe2(OFlag::O_CLOEXEC | OFlag::O_NONBLOCK).unwrap();
        let second = unistd::pipe2(OFlag::O_CLOEXEC | OFlag::O_NONBLOCK).unwrap();
        let mut process =
            Process::new(&sl!(), &oci::Process::default(), "pending-io", true, 1).unwrap();
        process.parent_stdout = Some(first.1);
        process.stdout = Some(second.1);
        container.processes.insert(i32::MAX, process);

        container.abort_create().unwrap();

        assert!(container.processes.is_empty());
        assert_pipe_writer_closed(first.0);
        assert_pipe_writer_closed(second.0);
        let _ = unistd::close(first.0);
        let _ = unistd::close(second.0);
    }

    #[tokio::test]
    async fn destroy_failure_does_not_retain_released_process_ids_for_retry() {
        let (container, _dir) = new_linux_container();
        let mut container = container.unwrap();
        let stale_candidate = i32::MAX;
        container.processes.insert(
            stale_candidate,
            Process::new(&sl!(), &oci::Process::default(), "stale-candidate", true, 1).unwrap(),
        );
        container.config.spec.as_mut().unwrap().hooks = Some(oci::Hooks {
            poststop: vec![Hook {
                path: "/bin/false".to_string(),
                args: vec!["false".to_string()],
                env: Vec::new(),
                timeout: None,
            }],
            ..Default::default()
        });

        let first = container.destroy().await.unwrap_err();
        assert!(first.to_string().contains("poststop hook"));
        assert!(container.cgroup_manager.is_none());
        assert!(container.processes.is_empty());
        let (pids, errors) = container.owned_process_ids();
        assert!(errors.is_empty());
        assert!(pids.is_empty(), "retry must not signal a reused PID");

        container.destroy().await.unwrap();
        assert!(container.processes.is_empty());
    }

    #[tokio::test]
    async fn test_linuxcontainer_start() {
        let (c, _dir) = new_linux_container();
        let ret = c
            .unwrap()
            .start(Process::new(&sl!(), &oci::Process::default(), "123", true, 1).unwrap())
            .await;
        assert!(ret.is_err(), "Expecting Err, Got {:?}", ret);
    }

    #[tokio::test]
    async fn test_linuxcontainer_run() {
        let (c, _dir) = new_linux_container();
        let ret = c
            .unwrap()
            .run(Process::new(&sl!(), &oci::Process::default(), "123", true, 1).unwrap())
            .await;
        assert!(ret.is_err(), "Expecting Err, Got {:?}", ret);
    }

    #[tokio::test]
    async fn test_linuxcontainer_destroy() {
        let (c, _dir) = new_linux_container();

        let ret = c.unwrap().destroy().await;
        assert!(ret.is_ok(), "Expecting Ok, Got {:?}", ret);
    }

    #[tokio::test]
    async fn test_linuxcontainer_exec() {
        let (c, _dir) = new_linux_container();
        let ret = c.unwrap().exec().await;
        assert!(ret.is_err(), "Expecting Err, Got {:?}", ret);
    }

    #[test]
    fn test_linuxcontainer_do_init_child() {
        let ret = do_init_child(std::io::stdin().as_raw_fd());
        assert!(ret.is_err(), "Expecting Err, Got {:?}", ret);
    }

    #[test]
    fn test_valid_env() {
        let env = valid_env("a=b=c");
        assert_eq!(Some(("a", "b=c")), env);

        let env = valid_env("a=b");
        assert_eq!(Some(("a", "b")), env);
        let env = valid_env("a =b");
        assert_eq!(Some(("a", "b")), env);

        let env = valid_env(" a =b");
        assert_eq!(Some(("a", "b")), env);

        let env = valid_env("a= b");
        assert_eq!(Some(("a", "b")), env);

        let env = valid_env("a=b ");
        assert_eq!(Some(("a", "b")), env);
        let env = valid_env("a=b c ");
        assert_eq!(Some(("a", "b c")), env);

        let env = valid_env("=b");
        assert_eq!(None, env);

        let env = valid_env("a=");
        assert_eq!(Some(("a", "")), env);

        let env = valid_env("a==");
        assert_eq!(Some(("a", "=")), env);

        let env = valid_env("a");
        assert_eq!(None, env);

        let invalid_str = vec![97, b'\0', 98];
        let invalid_string = std::str::from_utf8(&invalid_str).unwrap();

        let invalid_env = format!("{}=value", invalid_string);
        let env = valid_env(&invalid_env);
        assert_eq!(None, env);

        let invalid_env = format!("key={}", invalid_string);
        let env = valid_env(&invalid_env);
        assert_eq!(None, env);
    }
}
