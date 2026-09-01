// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Transactional cgroup v2 resource application.

use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail, Context, Result};
use oci::{LinuxHugepageLimit, LinuxResources};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransactionFailureKind {
    Unchanged,
    RolledBack,
    Degraded,
    Recovered,
}

#[derive(Debug)]
pub struct TransactionError {
    pub kind: TransactionFailureKind,
    pub cause: String,
    pub rollback_error: Option<String>,
    pub journal_path: PathBuf,
    pub current_values: BTreeMap<PathBuf, String>,
}

impl fmt::Display for TransactionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "resource transaction failed: {}", self.cause)?;
        match self.kind {
            TransactionFailureKind::Unchanged => write!(formatter, "; no controller changed"),
            TransactionFailureKind::RolledBack => write!(formatter, "; rollback complete"),
            TransactionFailureKind::Degraded => {
                write!(
                    formatter,
                    "; rollback incomplete: {} (journal: {})",
                    self.rollback_error.as_deref().unwrap_or("unknown error"),
                    self.journal_path.display()
                )?;
                if !self.current_values.is_empty() {
                    write!(formatter, "; current values: {:?}", self.current_values)?;
                }
                Ok(())
            }
            TransactionFailureKind::Recovered => write!(
                formatter,
                "; previous rollback replayed; retry the requested update"
            ),
        }
    }
}

impl Error for TransactionError {}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct UndoEntry {
    path: PathBuf,
    old_value: String,
    compare: CompareKind,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct UndoJournal {
    version: u32,
    entries: Vec<UndoEntry>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
enum CompareKind {
    Exact,
    Words,
    CpuSet,
}

#[derive(Clone, Debug)]
struct Target {
    path: PathBuf,
    value: String,
    compare: CompareKind,
}

trait ResourceIo {
    fn read(&self, path: &Path) -> Result<String>;
    fn write(&self, path: &Path, value: &str) -> Result<()>;
    fn write_journal(&self, path: &Path, journal: &UndoJournal) -> Result<()>;
    fn read_journal(&self, path: &Path) -> Result<UndoJournal>;
    fn remove_journal(&self, path: &Path) -> Result<()>;
}

struct RealResourceIo;

impl ResourceIo for RealResourceIo {
    fn read(&self, path: &Path) -> Result<String> {
        Ok(fs::read_to_string(path)
            .with_context(|| format!("read cgroup file {}", path.display()))?
            .trim()
            .to_string())
    }

    fn write(&self, path: &Path, value: &str) -> Result<()> {
        let bytes = if value.is_empty() {
            b"\n".as_slice()
        } else {
            value.as_bytes()
        };
        fs::write(path, bytes)
            .with_context(|| format!("write {:?} to cgroup file {}", value, path.display()))
    }

    fn write_journal(&self, path: &Path, journal: &UndoJournal) -> Result<()> {
        let parent = path
            .parent()
            .ok_or_else(|| anyhow!("undo journal path has no parent: {}", path.display()))?;
        fs::create_dir_all(parent)
            .with_context(|| format!("create undo journal directory {}", parent.display()))?;
        let temporary = path.with_extension("tmp");
        let bytes = serde_json::to_vec(journal).context("encode resource undo journal")?;
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temporary)
            .with_context(|| format!("create undo journal {}", temporary.display()))?;
        file.write_all(&bytes)
            .with_context(|| format!("write undo journal {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("sync undo journal {}", temporary.display()))?;
        fs::rename(&temporary, path).with_context(|| {
            format!(
                "publish undo journal {} as {}",
                temporary.display(),
                path.display()
            )
        })?;
        Ok(())
    }

    fn read_journal(&self, path: &Path) -> Result<UndoJournal> {
        let value = fs::read(path)
            .with_context(|| format!("read resource undo journal {}", path.display()))?;
        serde_json::from_slice(&value)
            .with_context(|| format!("decode resource undo journal {}", path.display()))
    }

    fn remove_journal(&self, path: &Path) -> Result<()> {
        match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error)
                .with_context(|| format!("remove resource undo journal {}", path.display())),
        }
    }
}

fn failure(
    kind: TransactionFailureKind,
    cause: impl fmt::Display,
    journal: &Path,
) -> TransactionError {
    TransactionError {
        kind,
        cause: cause.to_string(),
        rollback_error: None,
        journal_path: journal.to_path_buf(),
        current_values: BTreeMap::new(),
    }
}

fn capture_current_values<I: ResourceIo>(
    io: &I,
    entries: &[UndoEntry],
) -> BTreeMap<PathBuf, String> {
    entries
        .iter()
        .map(|entry| {
            let value = io
                .read(&entry.path)
                .unwrap_or_else(|error| format!("<read-error: {error:#}>"));
            (entry.path.clone(), value)
        })
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CpuSet(Vec<(u32, u32)>);

impl CpuSet {
    fn is_subset_of(&self, parent: &Self) -> bool {
        let mut parent_index = 0;
        for &(start, end) in &self.0 {
            while parent_index < parent.0.len() && parent.0[parent_index].1 < start {
                parent_index += 1;
            }
            if parent_index == parent.0.len()
                || parent.0[parent_index].0 > start
                || parent.0[parent_index].1 < end
            {
                return false;
            }
        }
        true
    }
}

fn parse_cpuset(value: &str) -> Result<CpuSet> {
    let mut ranges = Vec::new();
    if value.is_empty() {
        return Ok(CpuSet(ranges));
    }
    for component in value.split(',') {
        if component.is_empty() {
            bail!("empty cpuset component in {value:?}");
        }
        let mut bounds = component.split('-');
        let first = bounds
            .next()
            .unwrap()
            .parse::<u32>()
            .with_context(|| format!("invalid cpuset component {component:?}"))?;
        let last = match bounds.next() {
            Some(value) => value
                .parse::<u32>()
                .with_context(|| format!("invalid cpuset component {component:?}"))?,
            None => first,
        };
        if bounds.next().is_some() || first > last {
            bail!("invalid cpuset range {component:?}");
        }
        ranges.push((first, last));
    }
    ranges.sort_unstable();
    let mut merged: Vec<(u32, u32)> = Vec::with_capacity(ranges.len());
    for (start, end) in ranges {
        if let Some(previous) = merged.last_mut() {
            if start <= previous.1.saturating_add(1) {
                previous.1 = previous.1.max(end);
                continue;
            }
        }
        merged.push((start, end));
    }
    Ok(CpuSet(merged))
}

fn values_match(kind: CompareKind, expected: &str, actual: &str) -> Result<bool> {
    match kind {
        CompareKind::Exact => Ok(expected.trim() == actual.trim()),
        CompareKind::Words => Ok(expected.split_whitespace().eq(actual.split_whitespace())),
        CompareKind::CpuSet => Ok(parse_cpuset(expected)? == parse_cpuset(actual)?),
    }
}

fn add_target(
    targets: &mut Vec<Target>,
    path: PathBuf,
    value: String,
    compare: CompareKind,
) -> Result<()> {
    if let Some(existing) = targets.iter().find(|target| target.path == path) {
        if values_match(compare, &existing.value, &value)? {
            return Ok(());
        }
        bail!(
            "conflicting resource targets for {}: {:?} and {:?}",
            path.display(),
            existing.value,
            value
        );
    }
    targets.push(Target {
        path,
        value,
        compare,
    });
    Ok(())
}

pub fn cpu_shares_to_weight(shares: u64) -> u64 {
    if shares == 0 {
        return 0;
    }
    if shares <= 2 {
        return 1;
    }
    if shares >= 262_144 {
        return 10_000;
    }
    let logarithm = (shares as f64).log2();
    let exponent = (logarithm * logarithm + 125.0 * logarithm) / 612.0 - 7.0 / 34.0;
    10_f64.powf(exponent).ceil() as u64
}

/// Validate resource values whose create-time semantics cannot be delegated to
/// cgroup migration alone. Linux intentionally allows administrative process
/// migration to make `pids.current` exceed `pids.max`, so writing
/// `pids.max=0` and then moving an already-forked init process into the cgroup
/// would otherwise start a container that requested a zero-process limit.
pub fn validate_init_process_create(resources: &LinuxResources) -> Result<()> {
    if resources
        .pids
        .as_ref()
        .is_some_and(|pids| pids.limit == 0)
    {
        bail!(
            "resources-v2 create rejects pids.limit=0: cgroup v2 permits administrative process migration above pids.max, so starting an init process would violate the requested zero-process limit"
        );
    }
    Ok(())
}

fn parse_cpu_max(value: &str) -> Result<(String, u64)> {
    let fields = value.split_whitespace().collect::<Vec<_>>();
    if fields.len() != 2 {
        bail!("invalid current cpu.max value {value:?}");
    }
    if fields[0] != "max" {
        fields[0]
            .parse::<u64>()
            .with_context(|| format!("invalid current cpu.max quota {value:?}"))?;
    }
    let period = fields[1]
        .parse::<u64>()
        .with_context(|| format!("invalid current cpu.max period {value:?}"))?;
    Ok((fields[0].to_string(), period))
}

fn limit_value(value: i64, field: &str) -> Result<String> {
    match value {
        -1 => Ok("max".to_string()),
        value if value >= 0 => Ok(value.to_string()),
        _ => bail!("{field} must be -1 or non-negative, got {value}"),
    }
}

fn normalize_hugepage_size(value: &str) -> Result<String> {
    let digit_count = value.bytes().take_while(u8::is_ascii_digit).count();
    if digit_count == 0 || digit_count == value.len() {
        bail!("invalid hugepage pageSize {value:?}");
    }
    let amount = value[..digit_count]
        .parse::<u64>()
        .with_context(|| format!("invalid hugepage pageSize {value:?}"))?;
    if amount == 0 {
        bail!("hugepage pageSize must be greater than zero");
    }
    let multiplier = match &value[digit_count..] {
        "KB" => 1_u64,
        "MB" => 1_024,
        "GB" => 1_024 * 1_024,
        unit => bail!("unsupported hugepage unit {unit:?}; expected KB, MB, or GB"),
    };
    let kib = amount
        .checked_mul(multiplier)
        .ok_or_else(|| anyhow!("hugepage pageSize overflow: {value:?}"))?;
    if kib % (1_024 * 1_024) == 0 {
        Ok(format!("{}GB", kib / (1_024 * 1_024)))
    } else if kib % 1_024 == 0 {
        Ok(format!("{}MB", kib / 1_024))
    } else {
        Ok(format!("{kib}KB"))
    }
}

fn normalized_hugepages(values: &[LinuxHugepageLimit]) -> Result<BTreeMap<String, u64>> {
    let mut result = BTreeMap::new();
    for value in values {
        let size = normalize_hugepage_size(&value.page_size)?;
        if let Some(previous) = result.insert(size.clone(), value.limit) {
            if previous != value.limit {
                bail!(
                    "conflicting hugepage limits for normalized page size {size}: {previous} and {}",
                    value.limit
                );
            }
        }
    }
    Ok(result)
}

fn validate_cpuset<I: ResourceIo>(io: &I, root: &Path, field: &str, value: &str) -> Result<()> {
    let requested = parse_cpuset(value)?;
    let parent = root
        .parent()
        .ok_or_else(|| anyhow!("resource cgroup {} has no parent", root.display()))?;
    let effective = io.read(&parent.join(format!("cpuset.{field}.effective")))?;
    let effective = parse_cpuset(&effective)?;
    if !requested.is_subset_of(&effective) {
        bail!(
            "cpuset.{field} value {value:?} is outside parent effective set {:?}",
            effective
        );
    }
    Ok(())
}

fn plan<I: ResourceIo>(
    io: &I,
    root: &Path,
    resources: &LinuxResources,
    update: bool,
) -> Result<Vec<Target>> {
    if resources.block_io.is_some() {
        bail!("resources.blockIO is not supported by resources-v2 version 1");
    }
    if resources.network.is_some() {
        bail!("resources.network is not supported by resources-v2 version 1");
    }
    if !resources.rdma.is_empty() {
        bail!("resources.rdma is not supported by resources-v2 version 1");
    }

    let mut cpuset_mems = Vec::new();
    let mut cpuset_cpus = Vec::new();
    let mut cpu = Vec::new();
    let mut memory = Vec::new();
    let mut pids = Vec::new();
    let mut hugepages = Vec::new();
    let mut unified = Vec::new();

    if let Some(value) = resources.cpu.as_ref() {
        if value.burst.is_some()
            || value.realtime_runtime.is_some()
            || value.realtime_period.is_some()
            || value.idle.is_some()
        {
            bail!(
                "cpu burst, realtime, and idle fields are not supported by resources-v2 version 1"
            );
        }
        if let Some(shares) = value.shares {
            if shares != 0 {
                add_target(
                    &mut cpu,
                    root.join("cpu.weight"),
                    cpu_shares_to_weight(shares).to_string(),
                    CompareKind::Exact,
                )?;
            }
        }
        if let Some(mems) = value.mems.as_deref() {
            if !mems.is_empty() {
                validate_cpuset(io, root, "mems", mems)?;
                add_target(
                    &mut cpuset_mems,
                    root.join("cpuset.mems"),
                    mems.to_string(),
                    CompareKind::CpuSet,
                )?;
            }
        }
        if let Some(cpus) = value.cpus.as_deref() {
            if !cpus.is_empty() {
                validate_cpuset(io, root, "cpus", cpus)?;
                add_target(
                    &mut cpuset_cpus,
                    root.join("cpuset.cpus"),
                    cpus.to_string(),
                    CompareKind::CpuSet,
                )?;
            }
        }
        if value.quota.is_some() || value.period.is_some() {
            let (current_quota, current_period) = parse_cpu_max(&io.read(&root.join("cpu.max"))?)?;
            let quota = match value.quota {
                None => current_quota,
                Some(-1) => "max".to_string(),
                Some(quota) if quota >= 1_000 => quota.to_string(),
                Some(quota) => bail!("cpu.quota must be -1 or at least 1000, got {quota}"),
            };
            let period = match value.period {
                None => current_period,
                Some(period) if (1_000..=1_000_000).contains(&period) => period,
                Some(period) => bail!("cpu.period must be in 1000..=1000000, got {period}"),
            };
            add_target(
                &mut cpu,
                root.join("cpu.max"),
                format!("{quota} {period}"),
                CompareKind::Words,
            )?;
        }
    }

    let requested_memory_limit = resources.memory.as_ref().and_then(|value| value.limit);
    if let Some(value) = resources.memory.as_ref() {
        if value.kernel.is_some()
            || value.kernel_tcp.is_some()
            || value.swappiness.is_some()
            || value.disable_oom_killer.is_some()
            || value.use_hierarchy.is_some()
        {
            bail!("unsupported cgroup v2 memory field in resources-v2 request");
        }
        if let Some(limit) = value.limit {
            add_target(
                &mut memory,
                root.join("memory.max"),
                limit_value(limit, "memory.limit")?,
                CompareKind::Exact,
            )?;
        }
        if let Some(reservation) = value.reservation {
            add_target(
                &mut memory,
                root.join("memory.low"),
                limit_value(reservation, "memory.reservation")?,
                CompareKind::Exact,
            )?;
        }
        if update && value.check_before_update == Some(true) {
            if let Some(limit) = value.limit {
                if limit >= 0 {
                    let current = io
                        .read(&root.join("memory.current"))?
                        .parse::<u64>()
                        .context("parse memory.current")?;
                    if current > limit as u64 {
                        bail!(
                            "memory.current {current} exceeds requested memory.limit {limit} with checkBeforeUpdate"
                        );
                    }
                }
            }
        }
        if let Some(swap) = value.swap {
            let target = if swap == -1 {
                "max".to_string()
            } else if swap < -1 {
                bail!("memory.swap must be -1 or non-negative, got {swap}");
            } else {
                let memory_limit = match requested_memory_limit {
                    Some(-1) => None,
                    Some(limit) if limit >= 0 => Some(limit as u64),
                    Some(limit) => bail!("memory.limit must be -1 or non-negative, got {limit}"),
                    None => {
                        let current = io.read(&root.join("memory.max"))?;
                        if current == "max" {
                            None
                        } else {
                            Some(current.parse::<u64>().context("parse current memory.max")?)
                        }
                    }
                };
                let memory_limit = memory_limit.ok_or_else(|| {
                    anyhow!("finite memory.swap requires a finite effective memory.limit")
                })?;
                let total = swap as u64;
                if total < memory_limit {
                    bail!(
                        "memory.swap total {total} is less than effective memory limit {memory_limit}"
                    );
                }
                (total - memory_limit).to_string()
            };
            add_target(
                &mut memory,
                root.join("memory.swap.max"),
                target,
                CompareKind::Exact,
            )?;
        }
    }

    if let Some(value) = resources.pids.as_ref() {
        add_target(
            &mut pids,
            root.join("pids.max"),
            limit_value(value.limit, "pids.limit")?,
            CompareKind::Exact,
        )?;
    }

    for (size, limit) in normalized_hugepages(&resources.hugepage_limits)? {
        add_target(
            &mut hugepages,
            root.join(format!("hugetlb.{size}.max")),
            limit.to_string(),
            CompareKind::Exact,
        )?;
    }

    for (key, value) in &resources.unified {
        match key.as_str() {
            "memory.swap.max" => {
                let normalized = if value == "max" {
                    value.clone()
                } else {
                    value
                        .parse::<u64>()
                        .with_context(|| format!("invalid unified {key} value {value:?}"))?
                        .to_string()
                };
                add_target(&mut memory, root.join(key), normalized, CompareKind::Exact)?;
            }
            "memory.oom.group" => {
                if value != "0" && value != "1" {
                    bail!("unified memory.oom.group must be 0 or 1, got {value:?}");
                }
                add_target(
                    &mut unified,
                    root.join(key),
                    value.clone(),
                    CompareKind::Exact,
                )?;
            }
            _ => bail!("unsupported unified cgroup key {key:?}"),
        }
    }

    let mut targets = Vec::new();
    targets.extend(cpuset_mems);
    targets.extend(cpuset_cpus);
    targets.extend(cpu);
    targets.extend(memory);
    targets.extend(pids);
    targets.extend(hugepages);
    targets.extend(unified);
    Ok(targets)
}

fn rollback<I: ResourceIo>(io: &I, entries: &[UndoEntry]) -> Result<()> {
    let mut errors = Vec::new();
    for entry in entries.iter().rev() {
        if let Err(error) = io.write(&entry.path, &entry.old_value) {
            errors.push(format!("restore {}: {error:#}", entry.path.display()));
        }
    }
    for entry in entries {
        match io.read(&entry.path) {
            Ok(value) => match values_match(entry.compare, &entry.old_value, &value) {
                Ok(true) => {}
                Ok(false) => errors.push(format!(
                    "rollback readback mismatch for {}: expected {:?}, got {:?}",
                    entry.path.display(),
                    entry.old_value,
                    value
                )),
                Err(error) => errors.push(format!(
                    "rollback readback validation for {}: {error:#}",
                    entry.path.display()
                )),
            },
            Err(error) => errors.push(format!(
                "rollback readback {}: {error:#}",
                entry.path.display()
            )),
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        bail!(errors.join("; "))
    }
}

fn apply_with_io<I: ResourceIo>(
    io: &I,
    root: &Path,
    journal_path: &Path,
    resources: &LinuxResources,
    update: bool,
) -> std::result::Result<(), TransactionError> {
    let targets = plan(io, root, resources, update).map_err(|error| {
        failure(
            TransactionFailureKind::Unchanged,
            format!("{error:#}"),
            journal_path,
        )
    })?;
    if targets.is_empty() {
        return Ok(());
    }

    let mut entries = Vec::with_capacity(targets.len());
    for target in &targets {
        let old_value = io.read(&target.path).map_err(|error| {
            failure(
                TransactionFailureKind::Unchanged,
                format!("preflight {}: {error:#}", target.path.display()),
                journal_path,
            )
        })?;
        entries.push(UndoEntry {
            path: target.path.clone(),
            old_value,
            compare: target.compare,
        });
    }
    let journal = UndoJournal {
        version: 1,
        entries: entries.clone(),
    };
    io.write_journal(journal_path, &journal).map_err(|error| {
        failure(
            TransactionFailureKind::Unchanged,
            format!("persist undo journal: {error:#}"),
            journal_path,
        )
    })?;

    let mut touched = 0;
    let result: Result<()> = (|| {
        for target in &targets {
            touched += 1;
            io.write(&target.path, &target.value)?;
        }
        for target in &targets {
            let actual = io.read(&target.path)?;
            if !values_match(target.compare, &target.value, &actual)? {
                bail!(
                    "resource readback mismatch for {}: expected {:?}, got {:?}",
                    target.path.display(),
                    target.value,
                    actual
                );
            }
        }
        Ok(())
    })();

    match result {
        Ok(()) => {
            if let Err(error) = io.remove_journal(journal_path) {
                let mut transaction_error = failure(
                    TransactionFailureKind::Degraded,
                    format!("commit succeeded but journal cleanup failed: {error:#}"),
                    journal_path,
                );
                transaction_error.current_values = capture_current_values(io, &entries);
                return Err(transaction_error);
            }
            Ok(())
        }
        Err(error) => {
            let cause = format!("{error:#}");
            match rollback(io, &entries[..touched]) {
                Ok(()) => {
                    if let Err(remove_error) = io.remove_journal(journal_path) {
                        let mut transaction_error =
                            failure(TransactionFailureKind::Degraded, cause, journal_path);
                        transaction_error.rollback_error = Some(format!(
                            "rollback succeeded but journal cleanup failed: {remove_error:#}"
                        ));
                        transaction_error.current_values =
                            capture_current_values(io, &entries[..touched]);
                        return Err(transaction_error);
                    }
                    Err(failure(
                        TransactionFailureKind::RolledBack,
                        cause,
                        journal_path,
                    ))
                }
                Err(rollback_error) => {
                    let mut transaction_error =
                        failure(TransactionFailureKind::Degraded, cause, journal_path);
                    transaction_error.rollback_error = Some(format!("{rollback_error:#}"));
                    transaction_error.current_values =
                        capture_current_values(io, &entries[..touched]);
                    Err(transaction_error)
                }
            }
        }
    }
}

pub fn preflight(
    root: &Path,
    journal_path: &Path,
    resources: &LinuxResources,
    update: bool,
) -> std::result::Result<(), TransactionError> {
    let io = RealResourceIo;
    let targets = plan(&io, root, resources, update).map_err(|error| {
        failure(
            TransactionFailureKind::Unchanged,
            format!("{error:#}"),
            journal_path,
        )
    })?;
    for target in targets {
        io.read(&target.path).map_err(|error| {
            failure(
                TransactionFailureKind::Unchanged,
                format!("preflight {}: {error:#}", target.path.display()),
                journal_path,
            )
        })?;
    }
    Ok(())
}

pub fn apply(
    root: &Path,
    journal_path: &Path,
    resources: &LinuxResources,
    update: bool,
) -> std::result::Result<(), TransactionError> {
    apply_with_io(&RealResourceIo, root, journal_path, resources, update)
}

pub fn replay(journal_path: &Path) -> std::result::Result<(), TransactionError> {
    let io = RealResourceIo;
    replay_with_io(&io, journal_path)
}

fn replay_with_io<I: ResourceIo>(
    io: &I,
    journal_path: &Path,
) -> std::result::Result<(), TransactionError> {
    let journal = io.read_journal(journal_path).map_err(|error| {
        failure(
            TransactionFailureKind::Degraded,
            format!("load undo journal: {error:#}"),
            journal_path,
        )
    })?;
    if journal.version != 1 {
        return Err(failure(
            TransactionFailureKind::Degraded,
            format!("unsupported undo journal version {}", journal.version),
            journal_path,
        ));
    }
    rollback(io, &journal.entries).map_err(|error| {
        let mut transaction_error = failure(
            TransactionFailureKind::Degraded,
            "replay undo journal",
            journal_path,
        );
        transaction_error.rollback_error = Some(format!("{error:#}"));
        transaction_error.current_values = capture_current_values(io, &journal.entries);
        transaction_error
    })?;
    io.remove_journal(journal_path).map_err(|error| {
        let mut transaction_error = failure(
            TransactionFailureKind::Degraded,
            format!("remove replayed undo journal: {error:#}"),
            journal_path,
        );
        transaction_error.current_values = capture_current_values(io, &journal.entries);
        transaction_error
    })
}

pub fn merge(current: &mut LinuxResources, incoming: &LinuxResources) -> Result<()> {
    if let Some(incoming_cpu) = incoming.cpu.as_ref() {
        let current_cpu = current.cpu.get_or_insert_with(Default::default);
        if incoming_cpu.shares.is_some() && incoming_cpu.shares != Some(0) {
            current_cpu.shares = incoming_cpu.shares;
        }
        if incoming_cpu.quota.is_some() {
            current_cpu.quota = incoming_cpu.quota;
        }
        if incoming_cpu.period.is_some() {
            current_cpu.period = incoming_cpu.period;
        }
        if incoming_cpu
            .cpus
            .as_deref()
            .map_or(false, |value| !value.is_empty())
        {
            current_cpu.cpus = incoming_cpu.cpus.clone();
        }
        if incoming_cpu
            .mems
            .as_deref()
            .map_or(false, |value| !value.is_empty())
        {
            current_cpu.mems = incoming_cpu.mems.clone();
        }
    }
    if let Some(incoming_memory) = incoming.memory.as_ref() {
        let current_memory = current.memory.get_or_insert_with(Default::default);
        if incoming_memory.limit.is_some() {
            current_memory.limit = incoming_memory.limit;
        }
        if incoming_memory.reservation.is_some() {
            current_memory.reservation = incoming_memory.reservation;
        }
        if incoming_memory.swap.is_some() {
            current_memory.swap = incoming_memory.swap;
        }
        if incoming_memory.check_before_update.is_some() {
            current_memory.check_before_update = incoming_memory.check_before_update;
        }
    }
    if incoming.pids.is_some() {
        current.pids = incoming.pids.clone();
    }
    let mut hugepages = normalized_hugepages(&current.hugepage_limits)?;
    hugepages.extend(normalized_hugepages(&incoming.hugepage_limits)?);
    current.hugepage_limits = hugepages
        .into_iter()
        .map(|(page_size, limit)| LinuxHugepageLimit { page_size, limit })
        .collect();
    for (key, value) in &incoming.unified {
        current.unified.insert(key.clone(), value.clone());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use oci::{LinuxCpu, LinuxMemory, LinuxPids};
    use std::cell::{Cell, RefCell};
    use std::collections::BTreeSet;

    #[derive(Default)]
    struct FakeIo {
        files: RefCell<BTreeMap<PathBuf, String>>,
        writes: RefCell<Vec<PathBuf>>,
        fail_writes: RefCell<BTreeSet<usize>>,
        corrupt_readback: RefCell<Option<PathBuf>>,
        journal: RefCell<Option<UndoJournal>>,
    }

    impl FakeIo {
        fn with_files(values: &[(&str, &str)]) -> Self {
            let io = Self::default();
            for (path, value) in values {
                io.files
                    .borrow_mut()
                    .insert(PathBuf::from(path), value.to_string());
            }
            io
        }
    }

    impl ResourceIo for FakeIo {
        fn read(&self, path: &Path) -> Result<String> {
            let value = self
                .files
                .borrow()
                .get(path)
                .cloned()
                .ok_or_else(|| anyhow!("missing {}", path.display()))?;
            if self.corrupt_readback.borrow().as_deref() == Some(path)
                && !self.writes.borrow().is_empty()
            {
                return Ok("corrupt".to_string());
            }
            Ok(value)
        }

        fn write(&self, path: &Path, value: &str) -> Result<()> {
            let index = self.writes.borrow().len() + 1;
            self.writes.borrow_mut().push(path.to_path_buf());
            if self.fail_writes.borrow().contains(&index) {
                bail!("injected write {index}");
            }
            self.files
                .borrow_mut()
                .insert(path.to_path_buf(), value.to_string());
            Ok(())
        }

        fn write_journal(&self, _path: &Path, journal: &UndoJournal) -> Result<()> {
            *self.journal.borrow_mut() = Some(journal.clone());
            Ok(())
        }

        fn read_journal(&self, _path: &Path) -> Result<UndoJournal> {
            self.journal
                .borrow()
                .clone()
                .ok_or_else(|| anyhow!("no journal"))
        }

        fn remove_journal(&self, _path: &Path) -> Result<()> {
            *self.journal.borrow_mut() = None;
            Ok(())
        }
    }

    struct FaultingRealIo {
        writes: Cell<usize>,
        fail_writes: RefCell<BTreeSet<usize>>,
        corrupt_readback: RefCell<Option<PathBuf>>,
    }

    impl FaultingRealIo {
        fn new() -> Self {
            Self {
                writes: Cell::new(0),
                fail_writes: RefCell::new(BTreeSet::new()),
                corrupt_readback: RefCell::new(None),
            }
        }

        fn reset_faults(&self) {
            self.writes.set(0);
            self.fail_writes.borrow_mut().clear();
            *self.corrupt_readback.borrow_mut() = None;
        }
    }

    impl ResourceIo for FaultingRealIo {
        fn read(&self, path: &Path) -> Result<String> {
            let value = RealResourceIo.read(path)?;
            if self.corrupt_readback.borrow().as_deref() == Some(path) && self.writes.get() > 0 {
                return Ok("injected-corrupt-readback".to_string());
            }
            Ok(value)
        }

        fn write(&self, path: &Path, value: &str) -> Result<()> {
            let index = self.writes.get() + 1;
            self.writes.set(index);
            if self.fail_writes.borrow().contains(&index) {
                bail!("injected real cgroup write {index}");
            }
            RealResourceIo.write(path, value)
        }

        fn write_journal(&self, path: &Path, journal: &UndoJournal) -> Result<()> {
            RealResourceIo.write_journal(path, journal)
        }

        fn read_journal(&self, path: &Path) -> Result<UndoJournal> {
            RealResourceIo.read_journal(path)
        }

        fn remove_journal(&self, path: &Path) -> Result<()> {
            RealResourceIo.remove_journal(path)
        }
    }

    fn base_io() -> FakeIo {
        FakeIo::with_files(&[
            ("/cg/cpuset.mems.effective", "0"),
            ("/cg/cpuset.cpus.effective", "0-3"),
            ("/cg/x/cpu.weight", "100"),
            ("/cg/x/cpu.max", "max 100000"),
            ("/cg/x/memory.max", "1073741824"),
            ("/cg/x/memory.low", "0"),
            ("/cg/x/memory.swap.max", "1073741824"),
            ("/cg/x/memory.current", "1024"),
            ("/cg/x/memory.oom.group", "0"),
            ("/cg/x/pids.max", "max"),
            ("/cg/x/cpuset.mems", ""),
            ("/cg/x/cpuset.cpus", ""),
            ("/cg/x/hugetlb.2MB.max", "max"),
        ])
    }

    #[test]
    fn shares_match_containerd_vectors() {
        let values = [
            (0, 0),
            (1, 1),
            (2, 1),
            (51, 11),
            (102, 17),
            (204, 29),
            (512, 59),
            (1024, 100),
            (262_144, 10_000),
            (262_145, 10_000),
        ];
        for (shares, weight) in values {
            assert_eq!(cpu_shares_to_weight(shares), weight, "shares={shares}");
        }
    }

    #[test]
    fn init_create_rejects_zero_pids_despite_cgroup_migration_exception() {
        let mut resources = LinuxResources::default();
        validate_init_process_create(&resources).unwrap();

        resources.pids = Some(LinuxPids { limit: -1 });
        validate_init_process_create(&resources).unwrap();
        resources.pids = Some(LinuxPids { limit: 1 });
        validate_init_process_create(&resources).unwrap();

        resources.pids = Some(LinuxPids { limit: 0 });
        let error = validate_init_process_create(&resources).unwrap_err();
        assert!(error.to_string().contains("pids.limit=0"));
        assert!(error.to_string().contains("administrative process migration"));
    }

    #[test]
    fn plans_and_commits_all_supported_resource_groups_in_order() {
        let io = base_io();
        let mut resources = LinuxResources::default();
        resources.cpu = Some(LinuxCpu {
            shares: Some(1024),
            quota: Some(20_000),
            period: Some(50_000),
            cpus: Some("0-1".to_string()),
            mems: Some("0".to_string()),
            ..Default::default()
        });
        resources.memory = Some(LinuxMemory {
            limit: Some(536_870_912),
            reservation: Some(0),
            swap: Some(805_306_368),
            check_before_update: Some(true),
            ..Default::default()
        });
        resources.pids = Some(LinuxPids { limit: 32 });
        resources.hugepage_limits.push(LinuxHugepageLimit {
            page_size: "2048KB".to_string(),
            limit: 0,
        });
        resources
            .unified
            .insert("memory.oom.group".to_string(), "1".to_string());

        apply_with_io(
            &io,
            Path::new("/cg/x"),
            Path::new("/journal"),
            &resources,
            true,
        )
        .unwrap();
        let names = io
            .writes
            .borrow()
            .iter()
            .map(|path| path.file_name().unwrap().to_string_lossy().to_string())
            .collect::<Vec<_>>();
        assert_eq!(
            names,
            [
                "cpuset.mems",
                "cpuset.cpus",
                "cpu.weight",
                "cpu.max",
                "memory.max",
                "memory.low",
                "memory.swap.max",
                "pids.max",
                "hugetlb.2MB.max",
                "memory.oom.group",
            ]
        );
        assert!(io.journal.borrow().is_none());
    }

    #[test]
    fn validation_failure_has_zero_writes() {
        let io = base_io();
        let resources = LinuxResources {
            cpu: Some(LinuxCpu {
                quota: Some(999),
                ..Default::default()
            }),
            ..Default::default()
        };
        let error = apply_with_io(
            &io,
            Path::new("/cg/x"),
            Path::new("/journal"),
            &resources,
            true,
        )
        .unwrap_err();
        assert_eq!(error.kind, TransactionFailureKind::Unchanged);
        assert!(io.writes.borrow().is_empty());
        assert!(io.journal.borrow().is_none());
    }

    #[test]
    fn mid_write_failure_rolls_back_in_reverse_order() {
        let io = base_io();
        io.fail_writes.borrow_mut().insert(2);
        let resources = LinuxResources {
            cpu: Some(LinuxCpu {
                shares: Some(1024),
                quota: Some(20_000),
                ..Default::default()
            }),
            ..Default::default()
        };
        let error = apply_with_io(
            &io,
            Path::new("/cg/x"),
            Path::new("/journal"),
            &resources,
            true,
        )
        .unwrap_err();
        assert_eq!(error.kind, TransactionFailureKind::RolledBack);
        assert_eq!(io.files.borrow()[Path::new("/cg/x/cpu.weight")], "100");
        assert_eq!(io.files.borrow()[Path::new("/cg/x/cpu.max")], "max 100000");
        let writes = io.writes.borrow();
        assert_eq!(writes[writes.len() - 1], Path::new("/cg/x/cpu.weight"));
        assert!(io.journal.borrow().is_none());
    }

    #[test]
    fn typed_and_unified_swap_must_agree() {
        let io = base_io();
        let mut resources = LinuxResources {
            memory: Some(LinuxMemory {
                limit: Some(100),
                swap: Some(150),
                ..Default::default()
            }),
            ..Default::default()
        };
        resources
            .unified
            .insert("memory.swap.max".to_string(), "51".to_string());
        let error = plan(&io, Path::new("/cg/x"), &resources, true).unwrap_err();
        assert!(error.to_string().contains("conflicting"));
    }

    #[test]
    fn cpu_and_memory_sentinels_are_fail_closed_before_writes() {
        for resources in [
            LinuxResources {
                cpu: Some(LinuxCpu {
                    quota: Some(0),
                    ..Default::default()
                }),
                ..Default::default()
            },
            LinuxResources {
                cpu: Some(LinuxCpu {
                    period: Some(1_000_001),
                    ..Default::default()
                }),
                ..Default::default()
            },
            LinuxResources {
                memory: Some(LinuxMemory {
                    limit: Some(-2),
                    ..Default::default()
                }),
                ..Default::default()
            },
            LinuxResources {
                pids: Some(LinuxPids { limit: -2 }),
                ..Default::default()
            },
        ] {
            let io = base_io();
            let error = apply_with_io(
                &io,
                Path::new("/cg/x"),
                Path::new("/journal"),
                &resources,
                true,
            )
            .unwrap_err();
            assert_eq!(error.kind, TransactionFailureKind::Unchanged);
            assert!(io.writes.borrow().is_empty());
        }
    }

    #[test]
    fn quota_and_period_preserve_the_unspecified_cpu_max_half() {
        let io = base_io();
        let quota = LinuxResources {
            cpu: Some(LinuxCpu {
                quota: Some(20_000),
                ..Default::default()
            }),
            ..Default::default()
        };
        apply_with_io(&io, Path::new("/cg/x"), Path::new("/journal"), &quota, true).unwrap();
        assert_eq!(
            io.files.borrow()[Path::new("/cg/x/cpu.max")],
            "20000 100000"
        );

        let period = LinuxResources {
            cpu: Some(LinuxCpu {
                period: Some(50_000),
                ..Default::default()
            }),
            ..Default::default()
        };
        apply_with_io(
            &io,
            Path::new("/cg/x"),
            Path::new("/journal"),
            &period,
            true,
        )
        .unwrap();
        assert_eq!(io.files.borrow()[Path::new("/cg/x/cpu.max")], "20000 50000");
    }

    #[test]
    fn swap_uses_effective_limit_and_accepts_zero_delta() {
        let io = base_io();
        let resources = LinuxResources {
            memory: Some(LinuxMemory {
                swap: Some(1_073_741_824),
                ..Default::default()
            }),
            ..Default::default()
        };
        apply_with_io(
            &io,
            Path::new("/cg/x"),
            Path::new("/journal"),
            &resources,
            true,
        )
        .unwrap();
        assert_eq!(io.files.borrow()[Path::new("/cg/x/memory.swap.max")], "0");

        io.files
            .borrow_mut()
            .insert(PathBuf::from("/cg/x/memory.max"), "max".to_string());
        let finite = LinuxResources {
            memory: Some(LinuxMemory {
                swap: Some(100),
                ..Default::default()
            }),
            ..Default::default()
        };
        let error = plan(&io, Path::new("/cg/x"), &finite, true).unwrap_err();
        assert!(error.to_string().contains("finite effective"));
    }

    #[test]
    fn cpuset_parent_and_hugepage_conflicts_fail_before_writes() {
        let io = base_io();
        let outside = LinuxResources {
            cpu: Some(LinuxCpu {
                cpus: Some("4".to_string()),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(plan(&io, Path::new("/cg/x"), &outside, true)
            .unwrap_err()
            .to_string()
            .contains("outside parent"));

        let conflict = LinuxResources {
            hugepage_limits: vec![
                LinuxHugepageLimit {
                    page_size: "2048KB".to_string(),
                    limit: 1,
                },
                LinuxHugepageLimit {
                    page_size: "2MB".to_string(),
                    limit: 2,
                },
            ],
            ..Default::default()
        };
        assert!(plan(&io, Path::new("/cg/x"), &conflict, true)
            .unwrap_err()
            .to_string()
            .contains("conflicting hugepage"));
        assert!(io.writes.borrow().is_empty());
    }

    #[test]
    fn huge_cpuset_range_is_rejected_without_expansion() {
        let io = base_io();
        let resources = LinuxResources {
            cpu: Some(LinuxCpu {
                cpus: Some("0-4294967295".to_string()),
                ..Default::default()
            }),
            ..Default::default()
        };
        let error = plan(&io, Path::new("/cg/x"), &resources, true).unwrap_err();
        assert!(error.to_string().contains("outside parent"));
        assert!(io.writes.borrow().is_empty());
    }

    #[test]
    fn check_before_update_rejects_above_target_but_false_does_not_precheck() {
        let io = base_io();
        let checked = LinuxResources {
            memory: Some(LinuxMemory {
                limit: Some(100),
                check_before_update: Some(true),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(plan(&io, Path::new("/cg/x"), &checked, true)
            .unwrap_err()
            .to_string()
            .contains("exceeds"));

        let unchecked = LinuxResources {
            memory: Some(LinuxMemory {
                limit: Some(100),
                check_before_update: Some(false),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(plan(&io, Path::new("/cg/x"), &unchecked, true).is_ok());
        assert!(plan(&io, Path::new("/cg/x"), &checked, false).is_ok());
    }

    #[test]
    fn readback_failure_can_degrade_then_replay_the_persisted_undo() {
        let io = base_io();
        *io.corrupt_readback.borrow_mut() = Some(PathBuf::from("/cg/x/cpu.weight"));
        let resources = LinuxResources {
            cpu: Some(LinuxCpu {
                shares: Some(1024),
                ..Default::default()
            }),
            ..Default::default()
        };
        let error = apply_with_io(
            &io,
            Path::new("/cg/x"),
            Path::new("/journal"),
            &resources,
            true,
        )
        .unwrap_err();
        assert_eq!(error.kind, TransactionFailureKind::Degraded);
        assert_eq!(
            error.current_values[Path::new("/cg/x/cpu.weight")],
            "corrupt"
        );
        assert!(io.journal.borrow().is_some());

        *io.corrupt_readback.borrow_mut() = None;
        replay_with_io(&io, Path::new("/journal")).unwrap();
        assert_eq!(io.files.borrow()[Path::new("/cg/x/cpu.weight")], "100");
        assert!(io.journal.borrow().is_none());
    }

    #[test]
    fn real_cgroup_io_rolls_back_and_replays_injected_failures() {
        let Some(root) = std::env::var_os("CUBE_TEST_REAL_CGROUP_ROOT").map(PathBuf::from) else {
            eprintln!(
                "INFO: skipping real cgroup transaction test without CUBE_TEST_REAL_CGROUP_ROOT"
            );
            return;
        };
        assert_eq!(root.parent(), Some(Path::new("/sys/fs/cgroup")));
        assert!(root
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("cubesandbox-s34b-realio-")));
        assert!(root.is_dir());

        let cpu_path = root.join("cpu.weight");
        let oom_path = root.join("memory.oom.group");
        let original_cpu = RealResourceIo.read(&cpu_path).unwrap();
        let original_oom = RealResourceIo.read(&oom_path).unwrap();
        let shares = if original_cpu == "100" { 512 } else { 1024 };
        let target_cpu = cpu_shares_to_weight(shares).to_string();
        let target_oom = if original_oom == "0" { "1" } else { "0" };
        assert_ne!(target_cpu, original_cpu);
        assert_ne!(target_oom, original_oom);

        let resources = LinuxResources {
            cpu: Some(LinuxCpu {
                shares: Some(shares),
                ..Default::default()
            }),
            unified: std::collections::HashMap::from([(
                "memory.oom.group".to_string(),
                target_oom.to_string(),
            )]),
            ..Default::default()
        };
        let journal_directory = tempfile::tempdir().unwrap();
        let journal = journal_directory.path().join("resources-v2.undo.json");
        let io = FaultingRealIo::new();

        io.fail_writes.borrow_mut().insert(2);
        let rolled_back = apply_with_io(&io, &root, &journal, &resources, true).unwrap_err();
        assert_eq!(rolled_back.kind, TransactionFailureKind::RolledBack);
        assert_eq!(RealResourceIo.read(&cpu_path).unwrap(), original_cpu);
        assert_eq!(RealResourceIo.read(&oom_path).unwrap(), original_oom);
        assert!(!journal.exists());

        io.reset_faults();
        io.fail_writes.borrow_mut().insert(3);
        *io.corrupt_readback.borrow_mut() = Some(cpu_path.clone());
        let degraded = apply_with_io(&io, &root, &journal, &resources, true).unwrap_err();
        assert_eq!(degraded.kind, TransactionFailureKind::Degraded);
        assert!(degraded
            .rollback_error
            .as_deref()
            .is_some_and(|error| error.contains("injected real cgroup write 3")));
        assert!(journal.exists());
        assert_eq!(RealResourceIo.read(&cpu_path).unwrap(), original_cpu);
        assert_eq!(RealResourceIo.read(&oom_path).unwrap(), target_oom);

        io.reset_faults();
        replay_with_io(&io, &journal).unwrap();
        assert_eq!(RealResourceIo.read(&cpu_path).unwrap(), original_cpu);
        assert_eq!(RealResourceIo.read(&oom_path).unwrap(), original_oom);
        assert!(!journal.exists());
    }

    #[test]
    fn cpuset_empty_rollback_and_replay_restore_inherited_state() {
        let io = base_io();
        *io.corrupt_readback.borrow_mut() = Some(PathBuf::from("/cg/x/cpu.weight"));
        let resources = LinuxResources {
            cpu: Some(LinuxCpu {
                shares: Some(1024),
                cpus: Some("0".to_string()),
                mems: Some("0".to_string()),
                ..Default::default()
            }),
            ..Default::default()
        };
        let error = apply_with_io(
            &io,
            Path::new("/cg/x"),
            Path::new("/journal"),
            &resources,
            true,
        )
        .unwrap_err();
        assert_eq!(error.kind, TransactionFailureKind::Degraded);
        *io.corrupt_readback.borrow_mut() = None;
        replay_with_io(&io, Path::new("/journal")).unwrap();
        assert_eq!(io.files.borrow()[Path::new("/cg/x/cpuset.cpus")], "");
        assert_eq!(io.files.borrow()[Path::new("/cg/x/cpuset.mems")], "");
    }

    #[test]
    fn real_io_encodes_empty_cgroup_value_as_newline() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("cpuset.cpus");
        fs::write(&path, "old").unwrap();
        RealResourceIo.write(&path, "").unwrap();
        assert_eq!(fs::read(path).unwrap(), b"\n");
    }

    #[test]
    fn partial_merge_keeps_absent_and_unset_fields() {
        let mut current = LinuxResources {
            cpu: Some(LinuxCpu {
                shares: Some(1024),
                quota: Some(20_000),
                cpus: Some("0".to_string()),
                ..Default::default()
            }),
            memory: Some(LinuxMemory {
                limit: Some(100),
                check_before_update: Some(true),
                ..Default::default()
            }),
            ..Default::default()
        };
        let incoming = LinuxResources {
            cpu: Some(LinuxCpu {
                shares: Some(0),
                period: Some(50_000),
                cpus: Some(String::new()),
                ..Default::default()
            }),
            memory: Some(LinuxMemory {
                limit: Some(0),
                check_before_update: Some(false),
                ..Default::default()
            }),
            ..Default::default()
        };
        merge(&mut current, &incoming).unwrap();
        let cpu = current.cpu.unwrap();
        assert_eq!(cpu.shares, Some(1024));
        assert_eq!(cpu.quota, Some(20_000));
        assert_eq!(cpu.period, Some(50_000));
        assert_eq!(cpu.cpus.as_deref(), Some("0"));
        let memory = current.memory.unwrap();
        assert_eq!(memory.limit, Some(0));
        assert_eq!(memory.check_before_update, Some(false));
    }
}
