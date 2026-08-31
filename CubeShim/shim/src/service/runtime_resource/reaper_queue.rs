// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use super::{
    reaper_job_id, PreparedSandbox, RuntimeCleanupRecord, RuntimeLease, RUNTIME_CLEANUP_RECORD,
};
use std::io::ErrorKind;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

fn sync_directory(path: &Path) -> Result<(), String> {
    std::fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| {
            format!(
                "sync RuntimeResource reaper directory {}: {error}",
                path.display()
            )
        })
}

fn ensure_directory_durable(path: &Path) -> Result<(), String> {
    match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_dir() => return sync_directory(path),
        Ok(_) => {
            return Err(format!(
                "RuntimeResource reaper path is not a directory: {}",
                path.display()
            ));
        }
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "stat RuntimeResource reaper directory {}: {error}",
                path.display()
            ));
        }
    }

    let parent = path.parent().ok_or_else(|| {
        format!(
            "RuntimeResource reaper directory has no parent: {}",
            path.display()
        )
    })?;
    ensure_directory_durable(parent)?;
    match std::fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            if !std::fs::metadata(path)
                .map_err(|stat_error| {
                    format!(
                        "stat raced RuntimeResource reaper directory {}: {stat_error}",
                        path.display()
                    )
                })?
                .is_dir()
            {
                return Err(format!(
                    "RuntimeResource reaper path is not a directory: {}",
                    path.display()
                ));
            }
        }
        Err(error) => {
            return Err(format!(
                "create RuntimeResource reaper directory {}: {error}",
                path.display()
            ));
        }
    }
    sync_directory(parent)?;
    sync_directory(path)
}

pub(super) fn persist_reaper_job_at(
    root: &Path,
    record: &RuntimeCleanupRecord,
) -> Result<PathBuf, String> {
    ensure_directory_durable(root)?;
    let job = root.join(reaper_job_id(record)?);
    ensure_directory_durable(&job)?;
    RuntimeLease {
        endpoint: record.endpoint.clone(),
        sandbox: PreparedSandbox {
            sandbox_id: record.sandbox_id.clone(),
            lease_id: record.lease_id.clone(),
            generation: record.generation,
            ..Default::default()
        },
    }
    .persist_cleanup_record_at(&job.join(RUNTIME_CLEANUP_RECORD))?;

    // Persist both the record rename in the job and the job entry in the root.
    // Repeating both fsyncs also closes the already-existed/idempotent path.
    sync_directory(&job)?;
    sync_directory(root)?;
    Ok(job)
}

pub(super) fn remove_reaper_job_directory(job: &Path) -> Result<(), String> {
    let root = job.parent().ok_or_else(|| {
        format!(
            "RuntimeResource reaper job has no parent: {}",
            job.display()
        )
    })?;
    match std::fs::remove_dir(job) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "remove RuntimeResource reaper job {}: {error}",
                job.display()
            ));
        }
    }
    sync_directory(root)
}
