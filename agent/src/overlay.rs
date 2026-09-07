// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{Context, Result};
use nix::mount::MsFlags;
use std::ffi::CString;
use std::fs::OpenOptions;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};
use std::path::Path;

// Linux UAPI <linux/mount.h>; libc does not expose these for musl targets.
const FSOPEN_CLOEXEC: libc::c_uint = 1;
const FSCONFIG_SET_STRING: libc::c_uint = 1;
const FSCONFIG_CMD_CREATE: libc::c_uint = 6;
const FSMOUNT_CLOEXEC: libc::c_uint = 1;
const MOVE_MOUNT_F_EMPTY_PATH: libc::c_uint = 4;

fn checked(ret: libc::c_long) -> io::Result<libc::c_long> {
    if ret < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(ret)
    }
}

// fsconfig resolves each directory immediately. O_PATH aliases also avoid the
// per-string limit in older fsconfig implementations without changing cwd.
fn set_directory(context: &OwnedFd, key: &str, path: &Path) -> Result<()> {
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_DIRECTORY)
        .open(path)
        .with_context(|| format!("open overlay {key} {}", path.display()))?;
    let key_c = CString::new(key)?;
    let value = CString::new(format!("/proc/self/fd/{}", directory.as_raw_fd()))?;
    checked(unsafe {
        libc::syscall(
            libc::SYS_fsconfig,
            context.as_raw_fd(),
            FSCONFIG_SET_STRING,
            key_c.as_ptr(),
            value.as_ptr(),
            0,
        )
    })
    .with_context(|| {
        format!(
            "fsconfig overlay {key} {} (requires lowerdir+ support)",
            path.display()
        )
    })?;
    Ok(())
}

pub fn mount_rootfs(target: &Path, work: &Path, upper: &Path, lower: &str) -> Result<()> {
    let options = format!(
        "workdir={},upperdir={},lowerdir={}",
        work.display(),
        upper.display(),
        lower
    );
    let page_size = nix::unistd::sysconf(nix::unistd::SysconfVar::PAGE_SIZE)?
        .context("cannot determine mount option size limit")? as usize;
    // mount(2) copies at most one page, including the terminating NUL.
    if options.len() < page_size {
        return crate::mount::baremount(
            Path::new("overlay2"),
            target,
            "overlay",
            MsFlags::empty(),
            &options,
            &slog_scope::logger(),
        );
    }

    info!(slog_scope::logger(), "mount overlay with per-layer fsconfig";
        "target" => target.display().to_string(),
        "layers" => lower.split(':').count(), "option_bytes" => options.len());
    let fs_type = CString::new("overlay")?;
    let fd = checked(unsafe { libc::syscall(libc::SYS_fsopen, fs_type.as_ptr(), FSOPEN_CLOEXEC) })
        .context("fsopen overlay")?;
    // These descriptors own the filesystem context and detached mount, so any
    // error releases both and does not leave a mount or writable-layer lock.
    let context = unsafe { OwnedFd::from_raw_fd(fd as i32) };
    set_directory(&context, "workdir", work)?;
    set_directory(&context, "upperdir", upper)?;
    for path in lower.split(':') {
        set_directory(&context, "lowerdir+", Path::new(path))?;
    }
    checked(unsafe {
        libc::syscall(
            libc::SYS_fsconfig,
            context.as_raw_fd(),
            FSCONFIG_CMD_CREATE,
            std::ptr::null::<libc::c_char>(),
            std::ptr::null::<libc::c_char>(),
            0,
        )
    })
    .context("create overlay superblock")?;
    let fd = checked(unsafe {
        libc::syscall(libc::SYS_fsmount, context.as_raw_fd(), FSMOUNT_CLOEXEC, 0)
    })
    .context("fsmount overlay")?;
    let mount = unsafe { OwnedFd::from_raw_fd(fd as i32) };
    let target_c = CString::new(target.as_os_str().as_bytes())?;
    checked(unsafe {
        libc::syscall(
            libc::SYS_move_mount,
            mount.as_raw_fd(),
            b"\0".as_ptr(),
            libc::AT_FDCWD,
            target_c.as_ptr(),
            MOVE_MOUNT_F_EMPTY_PATH,
        )
    })
    .with_context(|| format!("attach overlay to {}", target.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn rootfs_layers_and_cleanup() {
        crate::skip_if_no_cap!(capctl::caps::Cap::SYS_ADMIN);
        check_rootfs_layers_and_cleanup().unwrap();
    }

    fn check_rootfs_layers_and_cleanup() -> Result<()> {
        let tmp = tempfile::tempdir()?;
        nix::mount::mount(
            Some("tmpfs"),
            tmp.path(),
            Some("tmpfs"),
            MsFlags::empty(),
            None::<&str>,
        )?;
        let _tmp_mount = scopeguard::guard((), |_| {
            let _ = nix::mount::umount2(tmp.path(), nix::mount::MntFlags::MNT_DETACH);
        });
        for (name, count, long) in [("short", 2, false), ("long", 40, true)] {
            let base = tmp.path().join(name);
            let layers = if long {
                base.join("a".repeat(180)).join("b".repeat(180))
            } else {
                base.clone()
            };
            let mut lower = Vec::new();
            for i in 0..count {
                let path = layers.join(format!("{i:03}"));
                fs::create_dir_all(&path)?;
                fs::write(path.join("order"), i.to_string())?;
                fs::write(path.join(format!("layer-{i}")), i.to_string())?;
                lower.push(path.to_str().unwrap().to_owned());
            }
            let target = base.join("merged");
            let work = base.join("work");
            let upper = base.join("upper");
            for path in [&target, &work, &upper] {
                fs::create_dir_all(path)?;
            }
            let lower = lower.join(":");
            // Exercise failure after superblock creation, then reuse the same
            // writable layer to catch leaked detached mounts/context handles.
            assert!(mount_rootfs(&base.join("missing"), &work, &upper, &lower).is_err());
            mount_rootfs(&target, &work, &upper, &lower)?;
            let mounted = scopeguard::guard((), |_| {
                let _ = nix::mount::umount2(&target, nix::mount::MntFlags::MNT_DETACH);
            });
            assert_eq!(fs::read_to_string(target.join("order"))?, "0");
            for i in 0..count {
                assert!(target.join(format!("layer-{i}")).is_file());
            }
            fs::write(target.join("order"), "copied up")?;
            assert_eq!(fs::read_to_string(upper.join("order"))?, "copied up");
            assert_eq!(fs::read_to_string(layers.join("000/order"))?, "0");
            fs::remove_file(target.join("layer-0"))?;
            drop(mounted);
            mount_rootfs(&target, &work, &upper, &lower)?;
            let _remounted = scopeguard::guard((), |_| {
                let _ = nix::mount::umount2(&target, nix::mount::MntFlags::MNT_DETACH);
            });
            assert_eq!(fs::read_to_string(target.join("order"))?, "copied up");
            assert!(!target.join("layer-0").exists());
        }
        Ok(())
    }
}
