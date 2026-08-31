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
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use containerd_shim::protos::types::mount::Mount;
use oci_spec::runtime::Spec;
use serde_json::json;

use crate::container::rootfs::{OverlayInfo, RootfsInfo, ANNOTATION_K_ROOTFS_INFO};
use crate::sandbox::config::ANNO_VMM_FS;
use crate::service::runtime_resource::canonical_runtime_shared_root;

pub const ENABLE_ANNOTATION: &str = "io.containerd.cube.s0.standard-rootfs";
pub const SHARE_BASE: &str = "/data/cubelet/s0.2-share";
const VIRTIOFS_SHARED_DIR: &str = "/data/cubelet";
static EXPORT_ATTEMPT: AtomicU64 = AtomicU64::new(1);

#[derive(Debug)]
pub struct PreparedRootfs {
    target: PathBuf,
    share_root: PathBuf,
    mounts: Vec<PathBuf>,
    remove_share_root: bool,
}

impl PreparedRootfs {
    pub fn target(&self) -> &Path {
        &self.target
    }

    pub fn cleanup(mut self) -> Result<(), String> {
        self.unmount_all(false)?;
        self.remove_dirs();
        Ok(())
    }

    fn unmount_all(&mut self, detach: bool) -> Result<(), String> {
        while let Some(path) = self.mounts.pop() {
            let target = path_cstring(&path)?;
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
        let _ = fs::remove_dir_all(&self.target);
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
        let _ = self.unmount_all(true);
        self.remove_dirs();
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
    let prepared = prepare_at(&share_root, sandbox_id, task_id, mounts, spec, true, true)?;
    Ok(Some(prepared))
}

/// Prepare a task rootfs inside the immutable shared root selected by
/// RuntimeResource before the sandbox VM was started. No per-task virtiofs
/// configuration is accepted or injected on this path.
pub fn prepare_managed(
    shared_root: &Path,
    task_id: &str,
    mounts: &[Mount],
    spec: &mut Spec,
) -> Result<PreparedRootfs, String> {
    let shared_root = canonical_runtime_shared_root(shared_root)?;
    let guest_share_name = guest_share_name(&shared_root)?;
    prepare_at(
        &shared_root,
        &guest_share_name,
        task_id,
        mounts,
        spec,
        false,
        false,
    )
}

fn prepare_at(
    share_root: &Path,
    guest_share_name: &str,
    task_id: &str,
    mounts: &[Mount],
    spec: &mut Spec,
    inject_virtiofs: bool,
    remove_share_root: bool,
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
        remove_share_root,
    };
    let guest_lowerdirs = export_rootfs(
        guest_share_name,
        &export_id,
        &mounts[0],
        &target,
        &mut prepared.mounts,
    )?;

    inject_annotations(spec, share_root, guest_lowerdirs, inject_virtiofs)?;
    Ok(prepared)
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
            bind_mount(source, &layer_target)?;
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

fn bind_mount(source: &Path, target: &Path) -> Result<(), String> {
    let source_c = path_cstring(source)?;
    let target_c = path_cstring(target)?;
    let ret = unsafe {
        libc::mount(
            source_c.as_ptr(),
            target_c.as_ptr(),
            std::ptr::null(),
            libc::MS_BIND | libc::MS_REC,
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
    fn managed_rootfs_injects_only_guest_rootfs_contract() {
        let mut spec = Spec::default();
        inject_annotations(
            &mut spec,
            Path::new("/data/cubelet/s11/shared/sb-generation"),
            vec!["sb-generation/rootfs/task-a-42/layers/000".to_string()],
            false,
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
            target,
            share_root: share_root.clone(),
            mounts: Vec::new(),
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
            target: old_target,
            share_root: share_root.clone(),
            mounts: Vec::new(),
            remove_share_root: false,
        }
        .cleanup()
        .unwrap();

        let new_target = rootfs_dir.join("task-new");
        fs::create_dir_all(&new_target).unwrap();
        assert_eq!(fs::metadata(&rootfs_dir).unwrap().ino(), rootfs_inode);

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
            target,
            share_root: share_root.clone(),
            mounts: Vec::new(),
            remove_share_root: true,
        }
        .cleanup()
        .unwrap();

        assert!(!share_root.exists());
    }
}
