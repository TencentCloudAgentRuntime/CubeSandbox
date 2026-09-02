// Copyright (c) 2020 Ant Group
//
// SPDX-License-Identifier: Apache-2.0
//

use anyhow::{anyhow, Context, Result};
use eventfd::{eventfd, EfdFlags};
use nix::sys::eventfd;
use std::fs::{self, File};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::Path;

use crate::pipestream::PipeStream;
use futures::StreamExt as _;
use inotify::{Inotify, WatchMask};
use tokio::io::AsyncReadExt;
use tokio::sync::mpsc::{channel, Receiver};
use tokio::task::JoinHandle;

// Convenience macro to obtain the scope logger
macro_rules! sl {
    () => {
        slog_scope::logger().new(o!("subsystem" => "cgroups_notifier"))
    };
}

pub struct OomNotifier {
    receiver: Receiver<String>,
    task: Option<JoinHandle<()>>,
}

impl OomNotifier {
    fn new(receiver: Receiver<String>, task: JoinHandle<()>) -> Self {
        Self {
            receiver,
            task: Some(task),
        }
    }

    pub async fn recv(&mut self) -> Option<String> {
        self.receiver.recv().await
    }

    pub async fn cancel(mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
            let _ = task.await;
        }
    }
}

impl Drop for OomNotifier {
    fn drop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

pub async fn notify_oom(cid: &str, cg_dir: String) -> Result<OomNotifier> {
    if cgroups::hierarchies::is_cgroup2_unified_mode() {
        return notify_on_oom_v2(cid, cg_dir).await;
    }
    notify_on_oom(cid, cg_dir).await
}

// get_value_from_cgroup parse cgroup file with `Flat keyed`
// and get the value of `key`.
// Flat keyed file format:
//   KEY0 VAL0\n
//   KEY1 VAL1\n
fn get_value_from_cgroup(path: &Path, key: &str) -> Result<i64> {
    let content = fs::read_to_string(path)?;
    info!(
        sl!(),
        "get_value_from_cgroup file: {:?}, content: {}", &path, &content
    );

    for line in content.lines() {
        let arr: Vec<&str> = line.split(' ').collect();
        if arr.len() == 2 && arr[0] == key {
            let r = arr[1].parse::<i64>()?;
            return Ok(r);
        }
    }
    Ok(0)
}

#[derive(Debug, PartialEq, Eq)]
enum V2EventDecision {
    Continue,
    Oom,
    Exited,
}

fn decide_v2_event(
    oom_kill: i64,
    baseline_oom_kill: i64,
    populated: Option<i64>,
) -> V2EventDecision {
    // memory.events and cgroup.events are independent inotify watches.  The
    // populated=0 event can be delivered before the memory.events event for
    // the same kill, so always give the counter readback precedence.
    if oom_kill > baseline_oom_kill {
        V2EventDecision::Oom
    } else if populated == Some(0) {
        V2EventDecision::Exited
    } else {
        V2EventDecision::Continue
    }
}

// notify_on_oom returns channel on which you can expect event about OOM,
// if process died without OOM this channel will be closed.
pub async fn notify_on_oom_v2(containere_id: &str, cg_dir: String) -> Result<OomNotifier> {
    register_memory_event_v2(containere_id, cg_dir, "memory.events", "cgroup.events").await
}

async fn register_memory_event_v2(
    containere_id: &str,
    cg_dir: String,
    memory_event_name: &str,
    cgroup_event_name: &str,
) -> Result<OomNotifier> {
    let event_control_path = Path::new(&cg_dir).join(memory_event_name);
    let cgroup_event_control_path = Path::new(&cg_dir).join(cgroup_event_name);
    info!(
        sl!(),
        "register_memory_event_v2 event_control_path: {:?}", &event_control_path
    );
    info!(
        sl!(),
        "register_memory_event_v2 cgroup_event_control_path: {:?}", &cgroup_event_control_path
    );

    let baseline_oom_kill = get_value_from_cgroup(&event_control_path, "oom_kill")?;
    let mut inotify = Inotify::init().context("Failed to initialize inotify")?;

    // watching oom kill
    let ev_wd = inotify.add_watch(&event_control_path, WatchMask::MODIFY)?;
    // Because no `unix.IN_DELETE|unix.IN_DELETE_SELF` event for cgroup file system, so watching all process exited
    let cg_wd = inotify.add_watch(&cgroup_event_control_path, WatchMask::MODIFY)?;

    info!(sl!(), "ev_wd: {:?}", ev_wd);
    info!(sl!(), "cg_wd: {:?}", cg_wd);

    let (sender, receiver) = channel(100);
    let containere_id = containere_id.to_string();
    let armed_oom_kill = get_value_from_cgroup(&event_control_path, "oom_kill")?;

    let task = tokio::spawn(async move {
        if armed_oom_kill > baseline_oom_kill {
            let _ = sender.send(containere_id.clone()).await.map_err(|e| {
                error!(sl!(), "send containere_id failed, error: {:?}", e);
            });
            return;
        }
        let mut buffer = [0; 32];
        let mut stream = inotify
            .event_stream(&mut buffer)
            .expect("create inotify event stream failed");

        while let Some(event_or_error) = stream.next().await {
            let event = event_or_error.unwrap();
            info!(
                sl!(),
                "container[{}] get event for container: {:?}", &containere_id, &event
            );
            // info!("is1: {}", event.wd == wd1);
            info!(sl!(), "event.wd: {:?}", event.wd);

            let oom_kill = get_value_from_cgroup(&event_control_path, "oom_kill");
            let populated = if event.wd == cg_wd {
                Some(get_value_from_cgroup(&cgroup_event_control_path, "populated").unwrap_or(-1))
            } else {
                None
            };
            match decide_v2_event(
                oom_kill.unwrap_or(baseline_oom_kill),
                baseline_oom_kill,
                populated,
            ) {
                V2EventDecision::Oom => {
                    let _ = sender.send(containere_id.clone()).await.map_err(|e| {
                        error!(sl!(), "send containere_id failed, error: {:?}", e);
                    });
                    return;
                }
                V2EventDecision::Exited => return,
                V2EventDecision::Continue => {}
            }

            // When a cgroup is destroyed, an event is sent to eventfd.
            // So if the control path is gone, return instead of notifying.
            if !Path::new(&event_control_path).exists() {
                return;
            }
        }
    });

    Ok(OomNotifier::new(receiver, task))
}

#[cfg(test)]
mod tests {
    use super::{
        decide_v2_event, get_value_from_cgroup, register_memory_event_v2, V2EventDecision,
    };
    use std::fs;
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::Barrier;

    #[test]
    fn populated_zero_prefers_oom_counter_increase() {
        assert_eq!(decide_v2_event(1, 0, Some(0)), V2EventDecision::Oom);
        assert_eq!(decide_v2_event(0, 0, Some(0)), V2EventDecision::Exited);
        assert_eq!(decide_v2_event(0, 0, Some(1)), V2EventDecision::Continue);
    }

    #[test]
    fn cgroup_counter_readback_is_exact() {
        let directory = tempfile::tempdir().unwrap();
        let events = directory.path().join("memory.events");
        fs::write(&events, "low 0\nhigh 0\nmax 3\noom 2\noom_kill 1\n").unwrap();
        assert_eq!(get_value_from_cgroup(&events, "oom_kill").unwrap(), 1);
    }

    #[tokio::test]
    async fn watcher_is_armed_before_immediate_oom_and_notifies_exactly_once() {
        let directory = tempfile::tempdir().unwrap();
        let memory_events = directory.path().join("memory.events");
        let cgroup_events = directory.path().join("cgroup.events");
        fs::write(&memory_events, "oom 0\noom_kill 0\n").unwrap();
        fs::write(&cgroup_events, "populated 1\n").unwrap();

        // This barrier models the exec FIFO: the workload cannot create its
        // immediate OOM until registration has returned with both watches
        // armed and the baseline captured.
        let release = Arc::new(Barrier::new(2));
        let trigger = Arc::clone(&release);
        let memory_events_for_trigger = memory_events.clone();
        let cgroup_events_for_trigger = cgroup_events.clone();
        let workload = tokio::spawn(async move {
            trigger.wait().await;
            fs::write(memory_events_for_trigger, "oom 1\noom_kill 1\n").unwrap();
            fs::write(cgroup_events_for_trigger, "populated 0\n").unwrap();
        });

        let mut notifier = register_memory_event_v2(
            "immediate-oom",
            directory.path().display().to_string(),
            "memory.events",
            "cgroup.events",
        )
        .await
        .unwrap();
        release.wait().await;
        workload.await.unwrap();

        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), notifier.recv())
                .await
                .unwrap(),
            Some("immediate-oom".to_string())
        );
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), notifier.recv())
                .await
                .unwrap(),
            None,
            "one cgroup OOM must produce exactly one notification"
        );
    }

    #[tokio::test]
    async fn watcher_can_be_cancelled_when_start_fails() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("memory.events"), "oom_kill 0\n").unwrap();
        fs::write(directory.path().join("cgroup.events"), "populated 1\n").unwrap();
        let notifier = register_memory_event_v2(
            "failed-start",
            directory.path().display().to_string(),
            "memory.events",
            "cgroup.events",
        )
        .await
        .unwrap();
        tokio::time::timeout(Duration::from_secs(1), notifier.cancel())
            .await
            .unwrap();
    }
}

// notify_on_oom returns channel on which you can expect event about OOM,
// if process died without OOM this channel will be closed.
async fn notify_on_oom(cid: &str, dir: String) -> Result<OomNotifier> {
    if dir.is_empty() {
        return Err(anyhow!("memory controller missing"));
    }

    register_memory_event(cid, dir, "memory.oom_control", "").await
}

async fn register_memory_event(
    cid: &str,
    cg_dir: String,
    event_name: &str,
    arg: &str,
) -> Result<OomNotifier> {
    let path = Path::new(&cg_dir).join(event_name);
    let event_file = File::open(path.clone())?;

    let eventfd = eventfd(0, EfdFlags::EFD_CLOEXEC)?;

    let event_control_path = Path::new(&cg_dir).join("cgroup.event_control");

    let data = if arg.is_empty() {
        format!("{} {}", eventfd, event_file.as_raw_fd())
    } else {
        format!("{} {} {}", eventfd, event_file.as_raw_fd(), arg)
    };

    fs::write(&event_control_path, data)?;

    let mut eventfd_stream = unsafe { PipeStream::from_raw_fd(eventfd) };

    let (sender, receiver) = tokio::sync::mpsc::channel(100);
    let containere_id = cid.to_string();

    let task = tokio::spawn(async move {
        loop {
            let sender = sender.clone();
            let mut buf = [0u8; 8];
            match eventfd_stream.read(&mut buf).await {
                Err(err) => {
                    warn!(sl!(), "failed to read from eventfd: {:?}", err);
                    return;
                }
                Ok(_) => match fs::read_to_string(path.clone()) {
                    Ok(content) => {
                        debug!(
                            sl!(),
                            "cgroup event for container: {}, path: {:?}, content: {:?}",
                            &containere_id,
                            &path,
                            content
                        );
                    }
                    Err(_) => {}
                },
            }

            // When a cgroup is destroyed, an event is sent to eventfd.
            // So if the control path is gone, return instead of notifying.
            if !Path::new(&event_control_path).exists() {
                return;
            }

            let _ = sender.send(containere_id.clone()).await.map_err(|e| {
                error!(sl!(), "send containere_id failed, error: {:?}", e);
            });
        }
    });

    Ok(OomNotifier::new(receiver, task))
}
