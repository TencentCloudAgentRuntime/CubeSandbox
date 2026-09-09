// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! Builds an agent-ready, business-free base snapshot for Cube CRI.
//!
//! The node RuntimeResource invokes this executable after a template miss. It
//! intentionally uses CubeShim's existing Snapshot producer rather than a
//! workload Pod, so Pod identity, CNI state, volumes and containers never
//! enter the published source template.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use containerd_shim_cube_rs::snapshot::{cmd::SnapshotArgs, Snapshot};

#[derive(Parser, Debug)]
struct Args {
    #[arg(long)]
    template_key: String,
    #[arg(long)]
    output: PathBuf,
    #[arg(long)]
    cpu: u32,
    #[arg(long)]
    memory_mib: u64,
    #[arg(long)]
    kernel: String,
    #[arg(long = "os-image")]
    os_image: String,
    #[arg(long)]
    agent: String,
}

#[derive(serde::Serialize)]
struct ReadyManifest<'a> {
    snapshot_base: &'a str,
    template_key: &'a str,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let args = Args::parse();
    if args.template_key.trim().is_empty() || args.cpu == 0 || args.memory_mib == 0 {
        return Err(anyhow!("template key, cpu and memory-mib must be non-zero"));
    }
    for (name, path) in [
        ("kernel", args.kernel.as_str()),
        ("guest image", args.os_image.as_str()),
        ("agent", args.agent.as_str()),
    ] {
        if !Path::new(path).is_file() {
            return Err(anyhow!("template {name} is not a regular file: {path}"));
        }
    }
    let output = args.output.canonicalize_parent()?;
    // `ready.json` is the sole publication point. Build directly below the
    // final key: this avoids relying on directory rename semantics while a
    // VMM still holds snapshot files open. An incomplete prior attempt has no
    // ready marker and is safe to replace on the next miss.
    if output.exists() {
        fs::remove_dir_all(&output)
            .with_context(|| format!("remove incomplete template {}", output.display()))?;
    }
    fs::create_dir_all(&output).with_context(|| format!("create {}", output.display()))?;
    let profile = format!("{}C{}M", args.cpu, args.memory_mib);
    let snapshot = Snapshot::try_from(SnapshotArgs {
        path: output.join(&profile).display().to_string(),
        disk: "[]".to_string(),
        pmem: "[]".to_string(),
        resource: serde_json::json!({
            "cpu": args.cpu,
            "memory": args.memory_mib,
            "preserve_memory": args.memory_mib,
            "snap_memory": args.memory_mib,
        })
        .to_string(),
        kernel: args.kernel,
        os_image: Some(args.os_image),
        agent: Some(args.agent),
        // Pod NICs are hotplugged after restore so the guest driver performs
        // a fresh feature negotiation against the Pod CNI TAP.
        notap: true,
        runtime_template_network: false,
        force: false,
        app_snapshot: false,
        vm_id: None,
        snapshot_type: "full".to_string(),
        memory_vol: None,
        container_id: None,
    })
    .map_err(|error| anyhow!(error))?;
    let mut snapshot = snapshot;
    if let Err(error) = snapshot.handle().await {
        let _ = fs::remove_dir_all(&output);
        return Err(anyhow!(error));
    }
    let manifest = ReadyManifest {
        snapshot_base: output
            .to_str()
            .ok_or_else(|| anyhow!("non-UTF8 output path"))?,
        template_key: &args.template_key,
    };
    // Some node-local runtime filesystems report success for rename yet leave
    // the source name in place. The manifest is tiny and the consumer also
    // verifies metadata/snapshot, so publish it directly after all artifacts
    // have been durably created.
    let ready = output.join("ready.json");
    fs::write(&ready, serde_json::to_vec(&manifest)?)
        .with_context(|| format!("write {}", ready.display()))?;
    Ok(())
}

trait CanonicalizeParent {
    fn canonicalize_parent(self) -> Result<PathBuf>;
}

impl CanonicalizeParent for PathBuf {
    fn canonicalize_parent(self) -> Result<PathBuf> {
        if !self.is_absolute() {
            return Err(anyhow!(
                "template output must be absolute: {}",
                self.display()
            ));
        }
        let parent = self
            .parent()
            .ok_or_else(|| anyhow!("template output has no parent"))?;
        let parent = parent
            .canonicalize()
            .with_context(|| format!("canonicalize template parent {}", parent.display()))?;
        Ok(parent.join(
            self.file_name()
                .ok_or_else(|| anyhow!("template output has no name"))?,
        ))
    }
}
