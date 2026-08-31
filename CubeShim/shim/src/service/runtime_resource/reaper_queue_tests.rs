// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

use super::{
    load_cleanup_record_at, reaper_queue, PreparedSandbox, RuntimeCleanupRecord, RuntimeLease,
    RUNTIME_CLEANUP_RECORD,
};

#[test]
fn reaper_job_queue_is_durable_reopenable_and_parent_synced_on_removal() {
    let temporary = std::env::temp_dir().join(format!(
        "cube-runtime-reaper-queue-{}",
        uuid::Uuid::new_v4()
    ));
    let root = temporary.join("nested").join("queue");
    let record = RuntimeCleanupRecord {
        endpoint: "/run/cubelet/runtime.sock".to_string(),
        sandbox_id: "sandbox-job-only".to_string(),
        lease_id: "lease-job-only".to_string(),
        generation: 11,
    };

    let job = reaper_queue::persist_reaper_job_at(&root, &record).unwrap();
    let record_path = job.join(RUNTIME_CLEANUP_RECORD);
    assert_eq!(
        load_cleanup_record_at(&record_path).unwrap(),
        Some(record.clone())
    );
    assert_eq!(
        reaper_queue::persist_reaper_job_at(&root, &record).unwrap(),
        job
    );

    let reopened_job = std::fs::read_dir(&root)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(reopened_job, job);
    assert_eq!(
        load_cleanup_record_at(&reopened_job.join(RUNTIME_CLEANUP_RECORD)).unwrap(),
        Some(record.clone())
    );

    RuntimeLease {
        endpoint: record.endpoint.clone(),
        sandbox: PreparedSandbox {
            sandbox_id: record.sandbox_id.clone(),
            lease_id: record.lease_id.clone(),
            generation: record.generation,
            ..Default::default()
        },
    }
    .remove_cleanup_record_at(&record_path)
    .unwrap();
    reaper_queue::remove_reaper_job_directory(&job).unwrap();
    assert!(!job.exists());
    std::fs::File::open(&root).unwrap().sync_all().unwrap();
    std::fs::remove_dir_all(temporary).unwrap();
}
