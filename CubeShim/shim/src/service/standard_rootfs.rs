// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

//! Adapter from containerd's standard `CreateTaskRequest.rootfs` to the
//! current Cube guest rootfs contract.
//!
//! Sandbox-managed tasks always export beneath the RuntimeResource shared
//! root that was fixed before VM start. Legacy tasks retain the explicit S0
//! annotation and private share root so the original probes keep working.

use std::collections::HashMap;
use std::ffi::CString;
use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use containerd_shim::protos::types::mount::Mount;
use oci_spec::runtime::Spec;
use serde_json::json;

use crate::common::{
    ANNO_ROOTFS_WLAYER_PATH, GUEST_VIRTIOFS_MNT_PATH, GUEST_VIRTIOFS_MNT_PATH_DEPRECATED,
};
use crate::container::rootfs::{OverlayInfo, RootfsInfo, ANNOTATION_K_ROOTFS_INFO};
use crate::sandbox::config::ANNO_VMM_FS;
use crate::service::runtime_resource::{
    canonical_runtime_shared_root, managed_volume_export_root, MANAGED_VOLUME_EXPORT_DIR,
    MANAGED_VOLUME_VIRTIOFS_ID,
};

pub const ENABLE_ANNOTATION: &str = "io.containerd.cube.s0.standard-rootfs";
pub const SHARE_BASE: &str = "/data/cubelet/s0.2-share";
const VIRTIOFS_SHARED_DIR: &str = "/data/cubelet";
const GUEST_SANDBOX_RESOLV_CONF: &str = "/etc/resolv.conf";
const MANAGED_ROOTFS_WRITABLE_DIR: &str = "rootfs-writable";
static EXPORT_ATTEMPT: AtomicU64 = AtomicU64::new(1);

#[derive(Debug)]
pub struct PreparedRootfs {
    target: PathBuf,
    share_root: PathBuf,
    mounts: Vec<PathBuf>,
    cleanup_dirs: Vec<PathBuf>,
    remove_share_root: bool,
}

impl PreparedRootfs {
    pub fn target(&self) -> &Path {
        &self.target
    }

    pub fn cleanup(mut self) -> Result<(), String> {
        if let Err(normal_error) = self.unmount_all(false) {
            // A Guest unmount can complete just before its virtiofs/FUSE
            // references are released on the Host.  The export is no longer
            // usable by the failed container, so detach the remaining mounts
            // from this namespace instead of leaking the containerd snapshot.
            // Only remove directories after every remaining mount detached.
            self.unmount_all(true).map_err(|detach_error| {
                format!(
                    "normal unmount failed: {normal_error}; lazy-detach fallback failed: {detach_error}"
                )
            })?;
        }
        self.remove_dirs();
        Ok(())
    }

    fn unmount_all(&mut self, detach: bool) -> Result<(), String> {
        while let Some(path) = self.mounts.pop() {
            let target = match path_cstring(&path) {
                Ok(target) => target,
                Err(error) => {
                    self.mounts.push(path);
                    return Err(error);
                }
            };
            let flags = if detach { libc::MNT_DETACH } else { 0 };
            let ret = unsafe { libc::umount2(target.as_ptr(), flags) };
            if ret != 0 {
                let err = io::Error::last_os_error();
                if err.raw_os_error() != Some(libc::EINVAL)
                    && err.raw_os_error() != Some(libc::ENOENT)
                {
                    self.mounts.push(path.clone());
                    return Err(format!("unmount {} failed: {err}", path.display()));
                }
            }
        }
        Ok(())
    }

    fn remove_dirs(&self) {
        let rootfs_dir = self.target.parent();
        for path in self.cleanup_dirs.iter().rev() {
            let _ = fs::remove_dir_all(path);
        }
        if self.remove_share_root {
            if let Some(rootfs_dir) = rootfs_dir {
                remove_empty_dir(rootfs_dir);
            }
            remove_empty_dir(&self.share_root);
        }
    }
}

fn remove_empty_dir(path: &Path) {
    let Ok(path) = path_cstring(path) else {
        return;
    };
    let _ = unsafe { libc::unlinkat(libc::AT_FDCWD, path.as_ptr(), libc::AT_REMOVEDIR) };
}

impl Drop for PreparedRootfs {
    fn drop(&mut self) {
        // Never remove an export while any bind mount may still be attached.
        // For directory bind mounts, remove_dir_all would otherwise traverse
        // into the host volume and could delete data from the bind source.
        if self.unmount_all(true).is_ok() {
            self.remove_dirs();
        }
    }
}

pub fn enabled(spec: &Spec) -> bool {
    spec.annotations()
        .as_ref()
        .and_then(|annotations| annotations.get(ENABLE_ANNOTATION))
        .map(|value| value.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Mount a standard containerd rootfs and inject only the legacy annotations
/// needed by the current Guest Agent.  VM asset/resource annotations remain a
/// Sandbox-resource concern and are supplied by the S0 replay fixture.
pub fn prepare_legacy(
    sandbox_id: &str,
    task_id: &str,
    mounts: &[Mount],
    spec: &mut Spec,
) -> Result<Option<PreparedRootfs>, String> {
    if !enabled(spec) {
        return Ok(None);
    }
    let share_root = Path::new(SHARE_BASE).join(sandbox_id);
    let prepared = prepare_at(
        &share_root,
        sandbox_id,
        task_id,
        mounts,
        spec,
        true,
        true,
        None,
    )?;
    Ok(Some(prepared))
}

/// Prepare a task rootfs and its bind exports beneath the two fixed directory
/// inodes selected before the sandbox VM starts. No per-task virtiofs device
/// is hot-plugged on this path.
pub fn prepare_managed(
    shared_root: &Path,
    task_id: &str,
    mounts: &[Mount],
    spec: &mut Spec,
) -> Result<PreparedRootfs, String> {
    let shared_root = canonical_runtime_shared_root(shared_root)?;
    let volume_root = managed_volume_export_root(&shared_root)?;
    let guest_share_name = guest_share_name(&shared_root)?;
    let prepared = prepare_at(
        &shared_root,
        &guest_share_name,
        task_id,
        mounts,
        spec,
        false,
        false,
        Some(&volume_root),
    )?;
    inject_guest_sandbox_resolver(spec);
    Ok(prepared)
}

/// containerd's sandboxer path can omit the workload-level resolv.conf bind
/// mount because DNS belongs to the Pod sandbox. Each Cube workload still has
/// its own mount namespace and rootfs, so bind the resolver configured by the
/// Agent at sandbox creation unless containerd supplied an explicit mount.
fn inject_guest_sandbox_resolver(spec: &mut Spec) {
    if spec.mounts().as_ref().is_some_and(|mounts| {
        mounts
            .iter()
            .any(|mount| mount.destination() == Path::new(GUEST_SANDBOX_RESOLV_CONF))
    }) {
        return;
    }

    let mut resolver = oci_spec::runtime::Mount::default();
    resolver.set_destination(PathBuf::from(GUEST_SANDBOX_RESOLV_CONF));
    resolver.set_typ(Some("bind".to_string()));
    resolver.set_source(Some(PathBuf::from(GUEST_SANDBOX_RESOLV_CONF)));
    resolver.set_options(Some(vec!["bind".to_string(), "ro".to_string()]));
    spec.mounts_mut()
        .get_or_insert_with(Vec::new)
        .push(resolver);
}

fn prepare_at(
    share_root: &Path,
    guest_share_name: &str,
    task_id: &str,
    mounts: &[Mount],
    spec: &mut Spec,
    inject_virtiofs: bool,
    remove_share_root: bool,
    managed_volume_root: Option<&Path>,
) -> Result<PreparedRootfs, String> {
    validate_id("guest share", guest_share_name)?;
    validate_id("task", task_id)?;
    if mounts.len() != 1 {
        return Err(format!(
            "standard rootfs requires exactly one rootfs mount, got {}",
            mounts.len()
        ));
    }

    // A previous shim, a duplicate Create, or a concurrent Delete may still
    // own an export for this task ID. Every Create attempt gets a distinct
    // directory so neither a failed attempt nor old-task cleanup can unmount
    // or remove another generation.
    let export_id = next_export_generation(task_id, std::process::id());
    let target = share_root.join("rootfs").join(&export_id);
    fs::create_dir_all(&target)
        .map_err(|e| format!("create rootfs export {} failed: {e}", target.display()))?;

    let mut prepared = PreparedRootfs {
        target: target.clone(),
        share_root: share_root.to_path_buf(),
        mounts: Vec::new(),
        cleanup_dirs: vec![target.clone()],
        remove_share_root,
    };
    if let Some(volume_root) = managed_volume_root {
        prepared.cleanup_dirs.push(volume_root.join(&export_id));
    }
    let guest_lowerdirs = export_rootfs(
        guest_share_name,
        &export_id,
        &mounts[0],
        &target,
        &mut prepared.mounts,
    )?;
    export_host_bind_mounts(
        guest_share_name,
        &export_id,
        &target,
        managed_volume_root,
        spec,
        &mut prepared.mounts,
    )?;

    // The Guest's legacy default upperdir lives under /run, which is tmpfs.
    // Besides consuming VM memory, tmpfs pages cannot be written back under a
    // container memory limit. Kubernetes' standard file-cache pressure test
    // therefore OOMs instead of reclaiming. Managed sandboxes already have a
    // writable, cacheless virtio-fs export for Pod volumes; allocate a private
    // generation below that export and use it for a writable OCI rootfs.
    let writable_layer = managed_volume_root
        .filter(|_| should_prepare_managed_writable_layer(spec, true))
        .map(|volume_root| prepare_managed_writable_layer(volume_root, &export_id))
        .transpose()?;

    inject_annotations(
        spec,
        share_root,
        guest_lowerdirs,
        inject_virtiofs,
        writable_layer.as_deref(),
    )?;
    Ok(prepared)
}

fn rootfs_is_readonly(spec: &Spec) -> bool {
    match spec.root().as_ref() {
        Some(root) => root.readonly().unwrap_or(false),
        None => true,
    }
}

fn should_prepare_managed_writable_layer(spec: &Spec, managed: bool) -> bool {
    managed
        && !rootfs_is_readonly(spec)
        && !spec
            .annotations()
            .as_ref()
            .is_some_and(|annotations| annotations.contains_key(ANNO_ROOTFS_WLAYER_PATH))
}

fn prepare_managed_writable_layer(
    managed_volume_root: &Path,
    export_id: &str,
) -> Result<PathBuf, String> {
    let host = managed_volume_root
        .join(export_id)
        .join(MANAGED_ROOTFS_WRITABLE_DIR);
    fs::create_dir_all(&host).map_err(|error| {
        format!(
            "create managed writable rootfs {} failed: {error}",
            host.display()
        )
    })?;
    Ok(Path::new(GUEST_VIRTIOFS_MNT_PATH)
        .join(MANAGED_VOLUME_VIRTIOFS_ID)
        .join(MANAGED_VOLUME_EXPORT_DIR)
        .join(export_id)
        .join(MANAGED_ROOTFS_WRITABLE_DIR))
}

/// Export host bind mounts through the sandbox's existing virtio-fs share and
/// rewrite their OCI sources to paths that exist inside the Guest. Kubernetes
/// injects files such as /etc/hosts, /etc/hostname and /etc/resolv.conf as host
/// bind mounts, and uses the same mechanism for Pod volumes. Passing those
/// host paths to the Guest unchanged makes runc fail with ENOENT.
fn export_host_bind_mounts(
    guest_share_name: &str,
    export_id: &str,
    target: &Path,
    managed_volume_root: Option<&Path>,
    spec: &mut Spec,
    mounted: &mut Vec<PathBuf>,
) -> Result<(), String> {
    let Some(mounts) = spec.mounts_mut().as_mut() else {
        return Ok(());
    };

    for (index, mount) in mounts.iter_mut().enumerate() {
        if mount.typ().as_deref() != Some("bind") || mount.destination() == Path::new("/dev/shm") {
            continue;
        }
        let source = mount
            .source()
            .as_ref()
            .ok_or_else(|| {
                format!(
                    "host bind mount {} has no source",
                    mount.destination().display()
                )
            })?
            .clone();
        if source.starts_with(GUEST_VIRTIOFS_MNT_PATH_DEPRECATED) {
            continue;
        }
        if !source.is_absolute() {
            return Err(format!(
                "host bind mount source must be absolute for {}: {}",
                mount.destination().display(),
                source.display()
            ));
        }

        let metadata = fs::metadata(&source).map_err(|error| {
            format!(
                "stat host bind mount source {} for {} failed: {error}",
                source.display(),
                mount.destination().display()
            )
        })?;
        let export_target = host_bind_export_target(target, managed_volume_root, export_id, index);
        if metadata.is_dir() {
            fs::create_dir_all(&export_target).map_err(|error| {
                format!(
                    "create host directory export {} failed: {error}",
                    export_target.display()
                )
            })?;
        } else if metadata.is_file() {
            if let Some(parent) = export_target.parent() {
                fs::create_dir_all(parent).map_err(|error| {
                    format!(
                        "create host file export parent {} failed: {error}",
                        parent.display()
                    )
                })?;
            }
            fs::File::create(&export_target).map_err(|error| {
                format!(
                    "create host file export {} failed: {error}",
                    export_target.display()
                )
            })?;
        } else {
            return Err(format!(
                "host bind mount source is neither file nor directory: {}",
                source.display()
            ));
        }

        mirror_export_target_mode(&metadata, &export_target)?;
        bind_mount(&source, &export_target, metadata.is_dir())?;
        mounted.push(export_target);
        mount.set_source(Some(guest_bind_source(
            guest_share_name,
            export_id,
            index,
            managed_volume_root.is_some(),
        )));
    }
    Ok(())
}

fn mirror_export_target_mode(metadata: &fs::Metadata, export_target: &Path) -> Result<(), String> {
    let mode = metadata.mode() & 0o7777;
    fs::set_permissions(export_target, fs::Permissions::from_mode(mode)).map_err(|error| {
        format!(
            "set host bind export mode {:04o} on {} failed: {error}",
            mode,
            export_target.display()
        )
    })
}

fn host_bind_export_target(
    rootfs_target: &Path,
    managed_volume_root: Option<&Path>,
    export_id: &str,
    index: usize,
) -> PathBuf {
    managed_volume_root
        .map(|root| root.join(export_id).join(format!("{index:03}")))
        .unwrap_or_else(|| rootfs_target.join("volumes").join(format!("{index:03}")))
}

fn guest_bind_source(
    guest_share_name: &str,
    export_id: &str,
    index: usize,
    managed: bool,
) -> PathBuf {
    if managed {
        return Path::new(crate::common::GUEST_VIRTIOFS_MNT_PATH)
            .join(MANAGED_VOLUME_VIRTIOFS_ID)
            .join(MANAGED_VOLUME_EXPORT_DIR)
            .join(export_id)
            .join(format!("{index:03}"));
    }
    Path::new(GUEST_VIRTIOFS_MNT_PATH_DEPRECATED)
        .join(guest_share_name)
        .join("rootfs")
        .join(export_id)
        .join("volumes")
        .join(format!("{index:03}"))
}

fn guest_share_name(shared_root: &Path) -> Result<String, String> {
    shared_root
        .file_name()
        .and_then(|name| name.to_str())
        .map(str::to_string)
        .ok_or_else(|| {
            format!(
                "managed shared root has no UTF-8 export name: {}",
                shared_root.display()
            )
        })
}

fn next_export_generation(task_id: &str, pid: u32) -> String {
    let attempt = EXPORT_ATTEMPT.fetch_add(1, Ordering::Relaxed);
    export_generation(task_id, pid, attempt)
}

fn export_generation(task_id: &str, pid: u32, attempt: u64) -> String {
    format!("{task_id}-{pid}-{attempt}")
}

fn validate_id(kind: &str, id: &str) -> Result<(), String> {
    if id.is_empty() || id == "." || id == ".." || id.contains('/') || id.contains('\0') {
        return Err(format!("invalid {kind} id for S0 rootfs path: {id:?}"));
    }
    Ok(())
}

fn inject_annotations(
    spec: &mut Spec,
    share_root: &Path,
    guest_lowerdirs: Vec<String>,
    inject_virtiofs: bool,
    writable_layer: Option<&Path>,
) -> Result<(), String> {
    let mut annotations: HashMap<String, String> =
        spec.annotations().as_ref().cloned().unwrap_or_default();
    if annotations.contains_key(ANNO_VMM_FS) {
        return Err(format!(
            "standard rootfs cannot be combined with an existing {ANNO_VMM_FS} annotation"
        ));
    }
    if annotations.contains_key(ANNOTATION_K_ROOTFS_INFO) {
        return Err(format!(
            "standard rootfs cannot be combined with an existing {ANNOTATION_K_ROOTFS_INFO} annotation"
        ));
    }

    if inject_virtiofs {
        let fs_config = json!({
            "backendfs_config": {
                "shared_dir": VIRTIOFS_SHARED_DIR,
                "allowed_dirs": [share_root.to_string_lossy()],
                "announce_submounts": false,
                "cache": 2,
                "read_only": true
            }
        });
        annotations.insert(ANNO_VMM_FS.to_string(), fs_config.to_string());
    }

    let rootfs_info = RootfsInfo {
        pmem_file: None,
        overlay_info: Some(OverlayInfo {
            virtiofs_lower_dir: guest_lowerdirs,
        }),
        mounts: None,
        ero_image: None,
    };
    annotations.insert(
        ANNOTATION_K_ROOTFS_INFO.to_string(),
        serde_json::to_string(&rootfs_info)
            .map_err(|e| format!("serialize S0 rootfs annotation failed: {e}"))?,
    );
    if let Some(path) = writable_layer {
        annotations.insert(
            ANNO_ROOTFS_WLAYER_PATH.to_string(),
            path.to_string_lossy().into_owned(),
        );
    }
    spec.set_annotations(Some(annotations));
    Ok(())
}

fn export_rootfs(
    sandbox_id: &str,
    task_id: &str,
    mount: &Mount,
    target: &Path,
    mounted: &mut Vec<PathBuf>,
) -> Result<Vec<String>, String> {
    if mount.type_ == "overlay" {
        let sources = overlay_layer_sources(&mount.options)?;
        let layers = target.join("layers");
        fs::create_dir_all(&layers)
            .map_err(|e| format!("create layer export {} failed: {e}", layers.display()))?;

        let mut guest_lowerdirs = Vec::with_capacity(sources.len());
        for (index, source) in sources.iter().enumerate() {
            let layer_name = format!("{index:03}");
            let layer_target = layers.join(&layer_name);
            fs::create_dir_all(&layer_target).map_err(|e| {
                format!("create layer target {} failed: {e}", layer_target.display())
            })?;
            bind_mount(source, &layer_target, true)?;
            mounted.push(layer_target);
            guest_lowerdirs.push(format!("{sandbox_id}/rootfs/{task_id}/layers/{layer_name}"));
        }
        return Ok(guest_lowerdirs);
    }

    let merged = target.join("merged");
    fs::create_dir_all(&merged)
        .map_err(|e| format!("create rootfs target {} failed: {e}", merged.display()))?;
    mount_one(mount, &merged)?;
    mounted.push(merged);
    Ok(vec![format!("{sandbox_id}/rootfs/{task_id}/merged")])
}

/// Convert containerd's overlay active snapshot into Guest overlay lowerdirs.
/// The active upper comes first, followed by the image lowerdirs in the exact
/// order supplied by containerd. This avoids overlay-on-overlay while retaining
/// containerd as the sole OCI image/snapshot owner for the PoC.
fn overlay_layer_sources(options: &[String]) -> Result<Vec<PathBuf>, String> {
    let upper = options
        .iter()
        .find_map(|option| option.strip_prefix("upperdir="));
    let lower = options
        .iter()
        .find_map(|option| option.strip_prefix("lowerdir="))
        .ok_or_else(|| "S0 overlay rootfs has no lowerdir option".to_string())?;

    let mut sources = Vec::new();
    if let Some(upper) = upper {
        sources.push(validate_layer_source("upperdir", upper)?);
    }
    for lower in lower.split(':') {
        sources.push(validate_layer_source("lowerdir", lower)?);
    }
    if sources.is_empty() {
        return Err("S0 overlay rootfs has no exportable layers".to_string());
    }
    Ok(sources)
}

fn validate_layer_source(kind: &str, value: &str) -> Result<PathBuf, String> {
    let source = PathBuf::from(value);
    if value.is_empty() || !source.is_absolute() {
        return Err(format!(
            "S0 overlay {kind} must be an absolute path: {value:?}"
        ));
    }
    let metadata = fs::metadata(&source)
        .map_err(|e| format!("stat S0 overlay {kind} {} failed: {e}", source.display()))?;
    if !metadata.is_dir() {
        return Err(format!(
            "S0 overlay {kind} is not a directory: {}",
            source.display()
        ));
    }
    Ok(source)
}

fn bind_mount(source: &Path, target: &Path, recursive: bool) -> Result<(), String> {
    let source_c = path_cstring(source)?;
    let target_c = path_cstring(target)?;
    let flags = if recursive {
        libc::MS_BIND | libc::MS_REC
    } else {
        libc::MS_BIND
    };
    let ret = unsafe {
        libc::mount(
            source_c.as_ptr(),
            target_c.as_ptr(),
            std::ptr::null(),
            flags,
            std::ptr::null(),
        )
    };
    if ret != 0 {
        return Err(format!(
            "bind mount {} on {} failed: {}",
            source.display(),
            target.display(),
            io::Error::last_os_error()
        ));
    }
    Ok(())
}

fn mount_one(mount: &Mount, target: &Path) -> Result<(), String> {
    if mount.type_.is_empty() {
        return Err("S0 rootfs mount type is empty".to_string());
    }
    let target = path_cstring(target)?;
    let source_value = if mount.source.is_empty() {
        mount.type_.as_str()
    } else {
        mount.source.as_str()
    };
    let source = CString::new(source_value)
        .map_err(|_| "S0 rootfs mount source contains NUL".to_string())?;
    let fs_type = CString::new(mount.type_.as_str())
        .map_err(|_| "S0 rootfs mount type contains NUL".to_string())?;

    let (flags, data_options) = parse_mount_options(&mount.options);
    let data = CString::new(data_options.join(","))
        .map_err(|_| "S0 rootfs mount options contain NUL".to_string())?;
    let ret = unsafe {
        libc::mount(
            source.as_ptr(),
            target.as_ptr(),
            fs_type.as_ptr(),
            flags,
            data.as_ptr().cast(),
        )
    };
    if ret != 0 {
        return Err(format!(
            "mount standard rootfs on {} failed: {}",
            target.to_string_lossy(),
            io::Error::last_os_error()
        ));
    }
    Ok(())
}

fn parse_mount_options(options: &[String]) -> (libc::c_ulong, Vec<String>) {
    let mut flags = 0;
    let mut data = Vec::new();
    for option in options {
        match option.as_str() {
            "ro" => flags |= libc::MS_RDONLY,
            "rw" => flags &= !libc::MS_RDONLY,
            "nosuid" => flags |= libc::MS_NOSUID,
            "suid" => flags &= !libc::MS_NOSUID,
            "nodev" => flags |= libc::MS_NODEV,
            "dev" => flags &= !libc::MS_NODEV,
            "noexec" => flags |= libc::MS_NOEXEC,
            "exec" => flags &= !libc::MS_NOEXEC,
            "sync" => flags |= libc::MS_SYNCHRONOUS,
            "dirsync" => flags |= libc::MS_DIRSYNC,
            "remount" => flags |= libc::MS_REMOUNT,
            "bind" => flags |= libc::MS_BIND,
            "rbind" => flags |= libc::MS_BIND | libc::MS_REC,
            "rec" => flags |= libc::MS_REC,
            "silent" => flags |= libc::MS_SILENT,
            "mand" => flags |= libc::MS_MANDLOCK,
            "noatime" => flags |= libc::MS_NOATIME,
            "nodiratime" => flags |= libc::MS_NODIRATIME,
            "relatime" => flags |= libc::MS_RELATIME,
            "strictatime" => flags |= libc::MS_STRICTATIME,
            _ => data.push(option.clone()),
        }
    }
    (flags, data)
}

fn path_cstring(path: &Path) -> Result<CString, String> {
    CString::new(path.as_os_str().as_encoded_bytes())
        .map_err(|_| format!("path contains NUL: {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn enabled_spec() -> Spec {
        let mut spec = Spec::default();
        spec.set_annotations(Some(HashMap::from([(
            ENABLE_ANNOTATION.to_string(),
            "true".to_string(),
        )])));
        spec
    }

    #[test]
    fn feature_gate_is_explicit() {
        assert!(!enabled(&Spec::default()));
        assert!(enabled(&enabled_spec()));
    }

    #[test]
    fn rejects_path_components() {
        assert!(validate_id("task", "../escape").is_err());
        assert!(validate_id("task", "ok-task_1").is_ok());
    }

    #[test]
    fn export_generation_is_process_and_attempt_scoped() {
        assert_eq!(export_generation("task-a", 42, 7), "task-a-42-7");
        assert_ne!(
            next_export_generation("task-a", 42),
            next_export_generation("task-a", 42)
        );
    }

    #[test]
    fn translates_mount_flags_and_data() {
        let options = vec![
            "ro".to_string(),
            "nodev".to_string(),
            "lowerdir=/a:/b".to_string(),
            "upperdir=/c".to_string(),
        ];
        let (flags, data) = parse_mount_options(&options);
        assert_ne!(flags & libc::MS_RDONLY, 0);
        assert_ne!(flags & libc::MS_NODEV, 0);
        assert_eq!(data, vec!["lowerdir=/a:/b", "upperdir=/c"]);
    }

    #[test]
    fn preserves_overlay_active_layer_order() {
        let temp = std::env::temp_dir();
        let temp = temp.to_string_lossy();
        let options = vec![
            format!("lowerdir=/:{temp}"),
            format!("upperdir={temp}"),
            "workdir=/ignored".to_string(),
        ];

        let sources = overlay_layer_sources(&options).unwrap();

        assert_eq!(
            sources,
            vec![
                PathBuf::from(temp.as_ref()),
                PathBuf::from("/"),
                PathBuf::from(temp.as_ref())
            ]
        );
    }

    #[test]
    fn rejects_overlay_without_lowerdir() {
        let error = overlay_layer_sources(&["upperdir=/".to_string()]).unwrap_err();
        assert!(error.contains("no lowerdir"));
    }

    #[test]
    fn injects_fixed_share_and_guest_lowerdir() {
        let mut spec = enabled_spec();
        inject_annotations(
            &mut spec,
            Path::new("/data/cubelet/s0.2-share/sandbox-a"),
            vec![
                "sandbox-a/rootfs/task-a/layers/000".to_string(),
                "sandbox-a/rootfs/task-a/layers/001".to_string(),
            ],
            true,
            None,
        )
        .unwrap();
        let annotations = spec.annotations().as_ref().unwrap();
        let fs: serde_json::Value =
            serde_json::from_str(annotations.get(ANNO_VMM_FS).unwrap()).unwrap();
        assert_eq!(
            fs["backendfs_config"]["allowed_dirs"][0],
            "/data/cubelet/s0.2-share/sandbox-a"
        );
        assert_eq!(fs["backendfs_config"]["announce_submounts"], false);

        let rootfs: serde_json::Value =
            serde_json::from_str(annotations.get(ANNOTATION_K_ROOTFS_INFO).unwrap()).unwrap();
        assert_eq!(
            rootfs["overlay_info"]["virtiofs_lower_dir"][0],
            "sandbox-a/rootfs/task-a/layers/000"
        );
        assert_eq!(
            rootfs["overlay_info"]["virtiofs_lower_dir"][1],
            "sandbox-a/rootfs/task-a/layers/001"
        );
    }

    #[test]
    fn managed_rootfs_uses_runtime_share_export_name() {
        assert_eq!(
            guest_share_name(Path::new("/data/cubelet/s11/shared/sb-generation")).unwrap(),
            "sb-generation"
        );
    }

    #[test]
    fn managed_rootfs_injects_guest_sandbox_resolver_when_missing() {
        let mut spec = Spec::default();
        spec.set_mounts(Some(Vec::new()));
        inject_guest_sandbox_resolver(&mut spec);

        let mounts = spec.mounts().as_ref().unwrap();
        assert_eq!(mounts.len(), 1);
        assert_eq!(
            mounts[0].destination(),
            Path::new(GUEST_SANDBOX_RESOLV_CONF)
        );
        assert_eq!(
            mounts[0].source(),
            &Some(PathBuf::from(GUEST_SANDBOX_RESOLV_CONF))
        );
        assert_eq!(mounts[0].typ().as_deref(), Some("bind"));
        assert_eq!(
            mounts[0].options().as_ref().unwrap(),
            &["bind".to_string(), "ro".to_string()]
        );
    }

    #[test]
    fn managed_rootfs_preserves_explicit_resolver_mount() {
        let mut resolver = oci_spec::runtime::Mount::default();
        resolver.set_destination(PathBuf::from(GUEST_SANDBOX_RESOLV_CONF));
        resolver.set_typ(Some("bind".to_string()));
        resolver.set_source(Some(PathBuf::from("/explicit/resolv.conf")));
        resolver.set_options(Some(vec!["rbind".to_string(), "ro".to_string()]));
        let mut spec = Spec::default();
        spec.set_mounts(Some(vec![resolver]));

        inject_guest_sandbox_resolver(&mut spec);

        let mounts = spec.mounts().as_ref().unwrap();
        assert_eq!(mounts.len(), 1);
        assert_eq!(
            mounts[0].source(),
            &Some(PathBuf::from("/explicit/resolv.conf"))
        );
        assert_eq!(
            mounts[0].options().as_ref().unwrap(),
            &["rbind".to_string(), "ro".to_string()]
        );
    }

    #[test]
    fn managed_bind_mount_uses_existing_guest_share() {
        assert_eq!(
            guest_bind_source("sb-generation", "task-a-42-7", 3, true),
            PathBuf::from("/run/virtiofs/cubeVolumes/volumes/task-a-42-7/003")
        );
        assert_eq!(
            guest_bind_source("sb-generation", "task-a-42-7", 3, false),
            PathBuf::from(
                "/run/cube-containers/shared/containers/sb-generation/rootfs/task-a-42-7/volumes/003"
            )
        );
        assert_eq!(
            host_bind_export_target(
                Path::new("/shared/rootfs/task-a-42-7"),
                Some(Path::new("/shared/volumes")),
                "task-a-42-7",
                3,
            ),
            PathBuf::from("/shared/volumes/task-a-42-7/003")
        );
    }

    #[test]
    fn host_bind_export_target_mirrors_source_mode() {
        let root = std::env::temp_dir().join(format!(
            "cubesandbox-host-bind-mode-test-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir(&root).unwrap();
        let source_dir = root.join("source-dir");
        let target_dir = root.join("target-dir");
        fs::create_dir(&source_dir).unwrap();
        fs::create_dir(&target_dir).unwrap();
        fs::set_permissions(&source_dir, fs::Permissions::from_mode(0o1777)).unwrap();
        fs::set_permissions(&target_dir, fs::Permissions::from_mode(0o700)).unwrap();

        mirror_export_target_mode(&fs::metadata(&source_dir).unwrap(), &target_dir).unwrap();

        assert_eq!(fs::metadata(&target_dir).unwrap().mode() & 0o7777, 0o1777);

        let source_file = root.join("source-file");
        let target_file = root.join("target-file");
        fs::write(&source_file, b"source").unwrap();
        fs::write(&target_file, b"target").unwrap();
        fs::set_permissions(&source_file, fs::Permissions::from_mode(0o640)).unwrap();
        fs::set_permissions(&target_file, fs::Permissions::from_mode(0o600)).unwrap();

        mirror_export_target_mode(&fs::metadata(&source_file).unwrap(), &target_file).unwrap();

        assert_eq!(fs::metadata(&target_file).unwrap().mode() & 0o7777, 0o640);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn managed_writable_layer_uses_the_existing_volume_export() {
        let root = std::env::temp_dir().join(format!(
            "cubesandbox-managed-writable-rootfs-test-{}",
            uuid::Uuid::new_v4()
        ));
        let volume_root = root.join(MANAGED_VOLUME_EXPORT_DIR);
        fs::create_dir_all(&volume_root).unwrap();

        let guest = prepare_managed_writable_layer(&volume_root, "task-a-42-7").unwrap();

        assert_eq!(
            guest,
            PathBuf::from("/run/virtiofs/cubeVolumes/volumes/task-a-42-7/rootfs-writable")
        );
        assert!(volume_root
            .join("task-a-42-7")
            .join(MANAGED_ROOTFS_WRITABLE_DIR)
            .is_dir());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn writable_layer_annotation_is_injected_only_when_selected() {
        let writable = Path::new("/run/virtiofs/cubeVolumes/volumes/task-a-42-7/rootfs-writable");
        let mut spec = Spec::default();
        inject_annotations(
            &mut spec,
            Path::new("/data/cubelet/s11/shared/sb-generation"),
            vec!["sb-generation/rootfs/task-a-42/layers/000".to_string()],
            false,
            Some(writable),
        )
        .unwrap();
        assert_eq!(
            spec.annotations().as_ref().unwrap()[ANNO_ROOTFS_WLAYER_PATH],
            writable.to_string_lossy()
        );
    }

    #[test]
    fn managed_writable_layer_selection_preserves_fail_closed_and_explicit_semantics() {
        let spec = |root: Option<bool>, explicit_writable_layer: bool| {
            let root = match root {
                Some(readonly) => json!({"path": "rootfs", "readonly": readonly}),
                None => serde_json::Value::Null,
            };
            let annotations = explicit_writable_layer
                .then(|| json!({ANNO_ROOTFS_WLAYER_PATH: "/run/virtiofs/explicit-writable-layer"}));
            serde_json::from_value::<Spec>(json!({
                "root": root,
                "annotations": annotations,
            }))
            .unwrap()
        };

        for (name, spec, managed, expected) in [
            ("managed writable", spec(Some(false), false), true, true),
            ("managed readonly", spec(Some(true), false), true, false),
            ("explicit wlayer", spec(Some(false), true), true, false),
            ("legacy unmanaged", spec(Some(false), false), false, false),
            ("missing root", spec(None, false), true, false),
        ] {
            assert_eq!(
                should_prepare_managed_writable_layer(&spec, managed),
                expected,
                "{name}"
            );
        }

        let root_without_readonly: Spec = serde_json::from_value(json!({
            "root": {"path": "rootfs"}
        }))
        .unwrap();
        assert!(should_prepare_managed_writable_layer(
            &root_without_readonly,
            true
        ));
    }

    #[test]
    fn managed_bind_mount_skips_guest_shared_shm() {
        let mut mount = oci_spec::runtime::Mount::default();
        mount.set_typ(Some("bind".to_string()));
        mount.set_source(Some(PathBuf::from("/host/path/that/does/not/exist")));
        mount.set_destination(PathBuf::from("/dev/shm"));
        let mut spec = Spec::default();
        spec.set_mounts(Some(vec![mount]));

        export_host_bind_mounts(
            "sb-generation",
            "task-a-42-7",
            Path::new("/unused"),
            None,
            &mut spec,
            &mut Vec::new(),
        )
        .unwrap();

        assert_eq!(
            spec.mounts().as_ref().unwrap()[0].source(),
            &Some(PathBuf::from("/host/path/that/does/not/exist"))
        );
    }

    #[test]
    fn managed_rootfs_injects_only_guest_rootfs_contract() {
        let mut spec = Spec::default();
        inject_annotations(
            &mut spec,
            Path::new("/data/cubelet/s11/shared/sb-generation"),
            vec!["sb-generation/rootfs/task-a-42/layers/000".to_string()],
            false,
            None,
        )
        .unwrap();

        let annotations = spec.annotations().as_ref().unwrap();
        assert!(!annotations.contains_key(ANNO_VMM_FS));
        let rootfs: serde_json::Value =
            serde_json::from_str(annotations.get(ANNOTATION_K_ROOTFS_INFO).unwrap()).unwrap();
        assert_eq!(
            rootfs["overlay_info"]["virtiofs_lower_dir"][0],
            "sb-generation/rootfs/task-a-42/layers/000"
        );
    }

    #[test]
    fn managed_cleanup_preserves_runtime_shared_root() {
        let share_root = std::env::temp_dir().join(format!(
            "cubesandbox-managed-rootfs-test-{}",
            std::process::id()
        ));
        let target = share_root.join("rootfs/task-a-42");
        let _ = fs::remove_dir_all(&share_root);
        fs::create_dir_all(&target).unwrap();

        PreparedRootfs {
            target: target.clone(),
            share_root: share_root.clone(),
            mounts: Vec::new(),
            cleanup_dirs: vec![target],
            remove_share_root: false,
        }
        .cleanup()
        .unwrap();

        assert!(share_root.is_dir());
        assert!(share_root.join("rootfs").is_dir());
        fs::remove_dir(share_root.join("rootfs")).unwrap();
        fs::remove_dir(&share_root).unwrap();
    }

    #[cfg(target_family = "unix")]
    #[test]
    fn managed_cleanup_keeps_rootfs_parent_inode_stable_across_tasks() {
        use std::os::unix::fs::MetadataExt;

        let share_root = std::env::temp_dir().join(format!(
            "cubesandbox-managed-rootfs-generation-test-{}",
            uuid::Uuid::new_v4()
        ));
        let rootfs_dir = share_root.join("rootfs");
        let old_target = rootfs_dir.join("task-old");
        fs::create_dir_all(&old_target).unwrap();
        let rootfs_inode = fs::metadata(&rootfs_dir).unwrap().ino();

        PreparedRootfs {
            target: old_target.clone(),
            share_root: share_root.clone(),
            mounts: Vec::new(),
            cleanup_dirs: vec![old_target],
            remove_share_root: false,
        }
        .cleanup()
        .unwrap();

        let new_target = rootfs_dir.join("task-new");
        fs::create_dir_all(&new_target).unwrap();
        assert_eq!(fs::metadata(&rootfs_dir).unwrap().ino(), rootfs_inode);

        fs::remove_dir_all(&share_root).unwrap();
    }

    #[cfg(target_family = "unix")]
    #[test]
    fn managed_cleanup_removes_only_its_volume_generation() {
        use std::os::unix::fs::MetadataExt;

        let share_root = std::env::temp_dir().join(format!(
            "cubesandbox-managed-volume-generation-test-{}",
            uuid::Uuid::new_v4()
        ));
        let target = share_root.join("rootfs/task-old");
        let volume_root = share_root.join("volumes");
        let old_volume = volume_root.join("task-old");
        let new_volume = volume_root.join("task-new");
        for path in [&target, &old_volume, &new_volume] {
            fs::create_dir_all(path).unwrap();
        }
        let volume_root_inode = fs::metadata(&volume_root).unwrap().ino();

        PreparedRootfs {
            target: target.clone(),
            share_root: share_root.clone(),
            mounts: Vec::new(),
            cleanup_dirs: vec![target.clone(), old_volume.clone()],
            remove_share_root: false,
        }
        .cleanup()
        .unwrap();

        assert!(!target.exists());
        assert!(!old_volume.exists());
        assert!(new_volume.is_dir());
        assert_eq!(fs::metadata(&volume_root).unwrap().ino(), volume_root_inode);
        fs::remove_dir_all(&share_root).unwrap();
    }

    #[cfg(target_family = "unix")]
    #[test]
    fn drop_preserves_export_when_unmount_fails() {
        use std::ffi::OsString;
        use std::os::unix::ffi::OsStringExt;

        let share_root = std::env::temp_dir().join(format!(
            "cubesandbox-rootfs-unmount-failure-test-{}",
            uuid::Uuid::new_v4()
        ));
        let target = share_root.join("rootfs/task-a-42");
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("must-remain"), b"host-volume-sentinel").unwrap();

        drop(PreparedRootfs {
            target: target.clone(),
            share_root: share_root.clone(),
            // A NUL path makes path_cstring fail before any umount2 syscall,
            // providing a deterministic unmount failure without privileges.
            mounts: vec![PathBuf::from(OsString::from_vec(
                b"invalid\0mount".to_vec(),
            ))],
            cleanup_dirs: vec![target.clone()],
            remove_share_root: false,
        });

        assert_eq!(
            fs::read(target.join("must-remain")).unwrap(),
            b"host-volume-sentinel"
        );
        fs::remove_dir_all(&share_root).unwrap();
    }

    #[cfg(target_family = "unix")]
    #[test]
    fn cleanup_preserves_export_when_normal_and_detach_unmount_fail() {
        use std::ffi::OsString;
        use std::os::unix::ffi::OsStringExt;

        let share_root = std::env::temp_dir().join(format!(
            "cubesandbox-rootfs-cleanup-unmount-failure-test-{}",
            uuid::Uuid::new_v4()
        ));
        let target = share_root.join("rootfs/task-a-42");
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("must-remain"), b"host-volume-sentinel").unwrap();

        let error = PreparedRootfs {
            target: target.clone(),
            share_root: share_root.clone(),
            mounts: vec![PathBuf::from(OsString::from_vec(
                b"invalid\0mount".to_vec(),
            ))],
            cleanup_dirs: vec![target.clone()],
            remove_share_root: false,
        }
        .cleanup()
        .unwrap_err();

        assert!(error.contains("normal unmount failed"));
        assert!(error.contains("lazy-detach fallback failed"));
        assert_eq!(
            fs::read(target.join("must-remain")).unwrap(),
            b"host-volume-sentinel"
        );
        fs::remove_dir_all(&share_root).unwrap();
    }

    #[test]
    fn cleanup_of_old_attempt_preserves_recreated_task_export() {
        let share_root = std::env::temp_dir().join(format!(
            "cubesandbox-rootfs-recreate-test-{}",
            uuid::Uuid::new_v4()
        ));
        let old_target = share_root
            .join("rootfs")
            .join(export_generation("same-task", 42, 1));
        let new_target = share_root
            .join("rootfs")
            .join(export_generation("same-task", 42, 2));
        fs::create_dir_all(&old_target).unwrap();
        fs::create_dir_all(&new_target).unwrap();

        PreparedRootfs {
            target: old_target.clone(),
            share_root: share_root.clone(),
            mounts: Vec::new(),
            cleanup_dirs: vec![old_target.clone()],
            remove_share_root: false,
        }
        .cleanup()
        .unwrap();

        assert!(!old_target.exists());
        assert!(new_target.is_dir());
        fs::remove_dir_all(&share_root).unwrap();
    }

    #[test]
    fn legacy_cleanup_removes_its_private_shared_root() {
        let share_root = std::env::temp_dir().join(format!(
            "cubesandbox-legacy-rootfs-test-{}",
            std::process::id()
        ));
        let target = share_root.join("rootfs/task-a-42");
        let _ = fs::remove_dir_all(&share_root);
        fs::create_dir_all(&target).unwrap();

        PreparedRootfs {
            target: target.clone(),
            share_root: share_root.clone(),
            mounts: Vec::new(),
            cleanup_dirs: vec![target],
            remove_share_root: true,
        }
        .cleanup()
        .unwrap();

        assert!(!share_root.exists());
    }
}
