// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Minimal PID 1 for a Kubernetes Pod shared process namespace.

use capctl::caps::{ambient, bounding, CapState};
use std::ptr;

const READY_FD: libc::c_int = 3;
const READY: u8 = 0;
const FAILED_PRIVATE_MOUNTS: u8 = 2;
const FAILED_EMPTY_ROOT: u8 = 3;
const FAILED_CHROOT: u8 = 4;
const FAILED_PROCESS_STATE: u8 = 5;
const FAILED_CAPABILITIES: u8 = 6;
const FAILED_CREDENTIALS: u8 = 7;
const FAILED_READY_WRITE: u8 = 8;
const NOBODY: libc::uid_t = 65_534;

fn report(status: u8) -> bool {
    unsafe { libc::write(READY_FD, &status as *const u8 as *const libc::c_void, 1) == 1 }
}

fn fail(status: u8) -> ! {
    report(status);
    unsafe { libc::_exit(125) }
}

fn reset_signals() {
    unsafe {
        for signal in 1..=64 {
            if signal != libc::SIGKILL && signal != libc::SIGSTOP {
                libc::signal(signal, libc::SIG_DFL);
            }
        }
        let mut signals: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut signals);
        if libc::sigprocmask(libc::SIG_SETMASK, &signals, ptr::null_mut()) < 0 {
            fail(FAILED_PROCESS_STATE);
        }
    }
}

fn install_empty_root() {
    unsafe {
        if libc::mount(
            ptr::null(),
            b"/\0".as_ptr() as *const libc::c_char,
            ptr::null(),
            (libc::MS_PRIVATE | libc::MS_REC) as libc::c_ulong,
            ptr::null(),
        ) < 0
        {
            fail(FAILED_PRIVATE_MOUNTS);
        }
        if libc::mount(
            b"cube-pidns-holder\0".as_ptr() as *const libc::c_char,
            b"/tmp\0".as_ptr() as *const libc::c_char,
            b"tmpfs\0".as_ptr() as *const libc::c_char,
            (libc::MS_NODEV | libc::MS_NOSUID | libc::MS_NOEXEC) as libc::c_ulong,
            b"size=64k,mode=0555\0".as_ptr() as *const libc::c_void,
        ) < 0
        {
            fail(FAILED_EMPTY_ROOT);
        }
        if libc::chdir(b"/tmp\0".as_ptr() as *const libc::c_char) < 0
            || libc::chroot(b".\0".as_ptr() as *const libc::c_char) < 0
            || libc::chdir(b"/\0".as_ptr() as *const libc::c_char) < 0
        {
            fail(FAILED_CHROOT);
        }
    }
}

fn drop_privileges() {
    if capctl::prctl::set_no_new_privs().is_err()
        || capctl::prctl::set_dumpable(false).is_err()
        || ambient::clear().is_err()
        || bounding::clear().is_err()
    {
        fail(FAILED_CAPABILITIES);
    }

    unsafe {
        if libc::setgroups(0, ptr::null()) < 0
            || libc::setresgid(NOBODY, NOBODY, NOBODY) < 0
            || libc::setresuid(NOBODY, NOBODY, NOBODY) < 0
        {
            fail(FAILED_CREDENTIALS);
        }
    }
    if CapState::empty().set_current().is_err() || capctl::prctl::set_dumpable(false).is_err() {
        fail(FAILED_CAPABILITIES);
    }
}

fn main() {
    if unsafe { libc::getpid() } != 1 {
        fail(FAILED_PROCESS_STATE);
    }

    reset_signals();
    unsafe {
        if libc::prctl(
            libc::PR_SET_NAME,
            b"cube-pid-init\0".as_ptr() as libc::c_ulong,
        ) < 0
            || libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) < 0
        {
            fail(FAILED_PROCESS_STATE);
        }
    }
    install_empty_root();
    drop_privileges();

    if !report(READY) {
        fail(FAILED_READY_WRITE);
    }
    unsafe {
        libc::close(READY_FD);
    }

    loop {
        unsafe {
            while libc::waitpid(-1, ptr::null_mut(), libc::WNOHANG) > 0 {}
            let interval = libc::timespec {
                tv_sec: 0,
                tv_nsec: 100_000_000,
            };
            libc::nanosleep(&interval, ptr::null_mut());
        }
    }
}
