// Copyright (c) 2020 Intel Corporation
//
// SPDX-License-Identifier: Apache-2.0
//

use protobuf::MessageField;

use crate::cgroups::{Manager as CgroupManager, ManagerCreateOutcome, RESOURCE_METRICS_VERSION_V1};
use crate::protocols::agent::{BlkioStats, CgroupStats, CpuStats, MemoryStats, PidsStats};
use anyhow::{anyhow, Result};
use cgroups::freezer::FreezerState;
use libc::{self, pid_t};
use oci::LinuxResources;
use std::path::{Path, PathBuf};

use crate::cgroups::fs::resources_v2::{TransactionError, TransactionFailureKind};
use std::collections::HashMap;
use std::string::String;

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Manager {
    pub paths: HashMap<String, String>,
    pub mounts: HashMap<String, String>,
    pub cpath: String,
    pub fail_destroy_once: bool,
}

impl CgroupManager for Manager {
    fn apply(&self, _: pid_t) -> Result<()> {
        Ok(())
    }

    fn set(&self, _: &LinuxResources, _: bool) -> Result<()> {
        Ok(())
    }

    fn get_stats(&self) -> Result<CgroupStats> {
        Ok(CgroupStats {
            cpu_stats: MessageField::some(CpuStats::default()),
            memory_stats: MessageField::some(MemoryStats::new()),
            pids_stats: MessageField::some(PidsStats::new()),
            blkio_stats: MessageField::some(BlkioStats::new()),
            hugetlb_stats: HashMap::new(),
            ..Default::default()
        })
    }

    fn resource_metrics_version(&self) -> u32 {
        RESOURCE_METRICS_VERSION_V1
    }

    fn freeze(&self, _: FreezerState) -> Result<()> {
        Ok(())
    }

    fn destroy(&mut self) -> Result<()> {
        if self.fail_destroy_once {
            self.fail_destroy_once = false;
            return Err(anyhow!("injected cgroup destroy failure"));
        }
        Ok(())
    }

    fn get_pids(&self) -> Result<Vec<pid_t>> {
        Ok(Vec::new())
    }
}

impl Manager {
    pub fn set_resources_v2(
        &self,
        _: &LinuxResources,
        _: bool,
        journal_path: &Path,
    ) -> std::result::Result<(), TransactionError> {
        Err(TransactionError {
            kind: TransactionFailureKind::Unchanged,
            cause: "mock cgroup manager does not apply resources-v2".to_string(),
            rollback_error: None,
            journal_path: journal_path.to_path_buf(),
            current_values: Default::default(),
        })
    }

    pub fn set_resources_v2_create(
        &self,
        _: &LinuxResources,
        journal_path: &Path,
    ) -> std::result::Result<(), TransactionError> {
        Err(TransactionError {
            kind: TransactionFailureKind::Unchanged,
            cause: "mock cgroup manager does not apply resources-v2".to_string(),
            rollback_error: None,
            journal_path: journal_path.to_path_buf(),
            current_values: Default::default(),
        })
    }

    pub fn replay_resources_v2(
        &self,
        journal_path: &Path,
    ) -> std::result::Result<(), TransactionError> {
        crate::cgroups::fs::resources_v2::replay(journal_path)
    }

    pub fn early_process_attach_paths(&self) -> Result<Vec<PathBuf>> {
        crate::cgroups::fs::early_process_attach_paths_for_layout(true, &self.cpath, &[])
    }

    pub fn new(cpath: &str) -> Result<Self> {
        Ok(Self {
            paths: HashMap::new(),
            mounts: HashMap::new(),
            cpath: cpath.to_string(),
            fail_destroy_once: false,
        })
    }

    pub fn new_owned(cpath: &str) -> Result<ManagerCreateOutcome<Self>> {
        Ok(ManagerCreateOutcome {
            manager: Self::new(cpath)?,
            initialization_error: None,
        })
    }

    pub fn update_cpuset_path(&self, _: &str, _: &str) -> Result<()> {
        Ok(())
    }

    pub fn get_cg_path(&self, _: &str) -> Option<String> {
        Some("".to_string())
    }
}
