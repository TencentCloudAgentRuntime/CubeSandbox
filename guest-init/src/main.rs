// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Guest PID 1: mount cube-agent.ext4 from /dev/pmem1 and exec cube-agent.
//!
//! Topology (fixed):
//!   /dev/pmem0 = Guest OS image (this binary as /sbin/init)
//!   /dev/pmem1 = cube-agent.ext4 → mounted at /run/support (ext4,ro,dax)
//!
//! Open-source guest-init intentionally does **not** perform SysCtrl
//! snapshot handshake (write SYS_START / poll SYS_RESTORE). Product
//! templates use APP snapshot on a running VM; cold boot never needs it.
//! Agent still signals VsockServerReady via SysCtrl after exec.

use anyhow::{anyhow, Result};
use nix::mount::{mount, MsFlags};
use nix::unistd;
use std::ffi::CString;
use std::fs;
#[cfg(target_arch = "aarch64")]
use std::os::fd::AsRawFd;
use std::path::Path;
use std::process;
use std::time::Instant;

mod init_env;

use crate::init_env::init;

const PMEM_DEV: &str = "/dev/pmem1";
const PMEM_MP: &str = "/run/support/";
const CUBE_AGENT: &str = "/run/support/cube-agent";

fn main() {
    let start = Instant::now();
    println!("init start at:{}", start.elapsed().as_millis());

    if process::id() != 1 {
        panic!("cube init must be started as pid 1");
    }
    if let Err(e) = notify_guest_init_started() {
        panic!("{}", e);
    }

    if let Err(e) = init(start) {
        panic!("{}", e);
    }

    if let Err(e) = mount_pmem() {
        panic!("{}", e);
    }
    if let Err(e) = notify_guest_init_ready() {
        panic!("{}", e);
    }
    println!("mount pmem finish at:{}", start.elapsed().as_millis());
    start_agent();
}

fn notify_guest_init_ready() -> Result<()> {
    notify_sys_ctrl(1 << 4, "guest init ready")
}

fn notify_guest_init_started() -> Result<()> {
    notify_sys_ctrl(1 << 6, "guest init started")
}

fn notify_sys_ctrl(data: u8, phase: &str) -> Result<()> {
    #[cfg(target_arch = "x86_64")]
    {
        const SYS_CTRL_PORT: u16 = 0x680;
        if unsafe { libc::ioperm(SYS_CTRL_PORT as u64, 1, 1) } != 0 {
            return Err(anyhow!(
                "ioperm {phase} port 0x{SYS_CTRL_PORT:x} failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        let mut port = x86_64::instructions::port::Port::new(SYS_CTRL_PORT);
        unsafe { port.write(data) };
    }
    #[cfg(target_arch = "aarch64")]
    {
        const SYS_CTRL_MMIO_ADDR: libc::off_t = 0x0903_0000;
        const SYS_CTRL_MMIO_SIZE: usize = 0x1000;
        let dev_mem = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/mem")
            .with_context(|| format!("open /dev/mem for {phase}"))?;
        let map = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                SYS_CTRL_MMIO_SIZE,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                dev_mem.as_raw_fd(),
                SYS_CTRL_MMIO_ADDR,
            )
        };
        if map == libc::MAP_FAILED {
            return Err(anyhow!(
                "mmap guest init ready addr 0x{SYS_CTRL_MMIO_ADDR:x} failed: {}",
                std::io::Error::last_os_error()
            ));
        }
        unsafe {
            std::ptr::write_volatile(map as *mut u8, data);
            libc::munmap(map, SYS_CTRL_MMIO_SIZE);
        }
    }
    Ok(())
}

fn mount_pmem() -> Result<()> {
    let source = Path::new(PMEM_DEV);
    let target = Path::new(PMEM_MP);
    let m_type = Some("ext4");
    let flags = MsFlags::MS_RDONLY;

    fs::create_dir_all(target).map_err(|e| anyhow!("mkdir {} failed:{}", PMEM_MP, e))?;

    mount(Some(source), target, m_type, flags, Some("dax"))
        .map_err(|e| anyhow!("mount pmem failed:{}", e))?;

    Ok(())
}

fn start_agent() -> ! {
    let args: Vec<CString> = Vec::new();
    let cmd = CString::new(CUBE_AGENT).expect("new cmd failed");
    let err = unistd::execvp(cmd.as_c_str(), &args).unwrap_err();
    panic!("exec agent failed:{}", err);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_exec_path_constant() {
        assert_eq!(CUBE_AGENT, "/run/support/cube-agent");
        assert_eq!(PMEM_DEV, "/dev/pmem1");
        assert_eq!(PMEM_MP, "/run/support/");
    }
}
