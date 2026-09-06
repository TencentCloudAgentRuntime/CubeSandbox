// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

use crate::common::CResult;
use crate::hypervisor::config::{HypConfig, VmConfig};
use crate::infof;
use crate::log::stat_defer::StatDefer;
use crate::log::{stat_defer, Log};
use cube_hypervisor::config::RestoreConfig;
use cube_hypervisor::vm_config::{DeviceConfig, FsConfig};
use cube_hypervisor::{
    self, config, vmm_config, ApiRequest, ApiResponsePayload, SnapshotConfig, SnapshotType,
    VmRemoveDeviceData,
};
use std::sync::mpsc::{channel, Receiver};
use std::time::Duration;
use std::{fmt, sync::Arc};
use tokio::sync::Mutex;

pub use cube_hypervisor::NotifyEvent;

use super::config::PciDeviceInfo;
use super::worker::{
    extract_vm_fds, worker_backend_enabled, LaunchConfig, WorkerClient, WorkerCommand,
    WorkerPlacement, WorkerReply,
};

const CALLE_ACTION_ADD_DEV_PRE: &str = "AddDevice";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum VmmBackendRoute {
    Worker,
    Embedded,
}

fn select_vmm_backend(worker_enabled: bool, has_managed_placement: bool) -> VmmBackendRoute {
    if worker_enabled && has_managed_placement {
        VmmBackendRoute::Worker
    } else {
        VmmBackendRoute::Embedded
    }
}

// VmmInstance::new installs seccomp and blocks signals on its calling thread.
// A reusable Tokio worker (including spawn_blocking workers) must never inherit
// those irreversible changes: later CRI operations spawn host helpers there.
fn vmm_bootstrap<T: Send + 'static>(
    init: impl FnOnce() -> CResult<T> + Send + 'static,
) -> CResult<T> {
    std::thread::Builder::new()
        .name("cube-vmm-init".into())
        .spawn(init)
        .map_err(|error| format!("spawn VMM initializer: {error}"))?
        .join()
        .map_err(|_| "VMM initializer panicked".to_string())?
}

pub(crate) fn runtime_seccomp_syscalls() -> Vec<i64> {
    vec![
        #[cfg(target_arch = "x86_64")]
        libc::SYS_mkdir,
        #[cfg(target_arch = "aarch64")]
        libc::SYS_mkdirat,
        libc::SYS_getsockopt,
        libc::SYS_setsockopt,
        libc::SYS_faccessat2,
    ]
}

#[derive(Debug, PartialEq, Eq, Clone)]
enum HypStatus {
    Init,
    Launched,
    Running,
}
impl fmt::Display for HypStatus {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match *self {
            HypStatus::Init => write!(f, "init"),
            HypStatus::Launched => write!(f, "launched"),
            HypStatus::Running => write!(f, "running"),
        }
    }
}

#[derive(Clone)]
pub struct CubeHypervisor {
    status: HypStatus,
    config: HypConfig,
    ch: Option<Arc<Mutex<cube_hypervisor::VmmInstance>>>,
    worker: Option<WorkerClient>,
    ev_receiver: Option<Arc<Mutex<Receiver<NotifyEvent>>>>,
    log: Log,
}

impl CubeHypervisor {
    pub fn new(config: HypConfig, log: Log) -> Self {
        CubeHypervisor {
            status: HypStatus::Init,
            ch: None,
            worker: None,
            config: config.clone(),
            ev_receiver: None,
            log,
        }
    }

    fn status_err(&self, s: String) -> String {
        format!("{}, status: {}", s, self.status)
    }
    fn new_stat(&self, callee_act: String) -> StatDefer {
        stat_defer::StatDefer::new(
            self.config.sandbox_id.clone(),
            stat_defer::CALLEE_CH.to_string(),
            stat_defer::ACT_CREATE.to_string(),
            callee_act,
            self.log.clone(),
        )
    }
    pub async fn launch_vmm(&mut self, placement: Option<&dyn WorkerPlacement>) -> CResult<()> {
        if self.ch.is_some() || self.worker.is_some() {
            return Err(self.status_err("oops: VMM backend is already initialized".to_string()));
        }
        let mut stat = self.new_stat(stat_defer::CALLEE_ACT_LAUNCH_VMM.to_string());
        let worker_enabled = worker_backend_enabled()?;
        if select_vmm_backend(worker_enabled, placement.is_some()) == VmmBackendRoute::Worker {
            let (worker, receiver) = WorkerClient::spawn(
                LaunchConfig::new(
                    self.config.sandbox_id.clone(),
                    self.config.log_level,
                    self.config.ch_http_api.clone(),
                ),
                placement,
            )?;
            self.worker = Some(worker);
            self.ev_receiver = Some(Arc::new(Mutex::new(receiver)));
            self.status = HypStatus::Launched;
            stat.set_ok();
            return Ok(());
        }
        if worker_enabled {
            infof!(
                self.log,
                "legacy Task path has no durable worker placement; using embedded VMM backend"
            );
        }
        cube_hypervisor::set_runtime_seccomp_rules(
            runtime_seccomp_syscalls()
                .into_iter()
                .map(|syscall| (syscall, vec![]))
                .collect(),
        );
        let mut vmm_config = self.config.to_vmm_config();
        let (sender, receiver) = channel::<NotifyEvent>();
        let notifier = vmm_config::EventNotifyConfig { notifier: sender };
        vmm_config.event_notifier = Some(notifier);
        self.ev_receiver = Some(Arc::new(Mutex::new(receiver)));

        let ch = vmm_bootstrap(move || {
            cube_hypervisor::VmmInstance::new(vmm_config).map_err(|error| error.to_string())
        })
        .map_err(|error| self.status_err(format!("New vmm instance failed:{error}")))?;
        self.ch = Some(Arc::new(Mutex::new(ch)));
        self.status = HypStatus::Launched;
        stat.set_ok();
        Ok(())
    }

    pub async fn ping_vmm(&self, _timeout_ms: u64) -> CResult<()> {
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::Ping, &[])?;
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let _ = ch
            .send_request(ApiRequest::VmmPing)
            .map_err(|e| format!("Ping Vmm failed:{}", e))?
            .map_err(|e| format!("Ping Vmm failed:{}", e))?;
        Ok(())
    }

    pub async fn create_vm(&self, config: &VmConfig) -> CResult<()> {
        let mut stat = self.new_stat(stat_defer::CALLEE_ACT_CREATE_VM.to_string());
        if let Some(worker) = &self.worker {
            let mut config = config.to_vm_config();
            let descriptors = extract_vm_fds(&mut config);
            worker.request(WorkerCommand::CreateVm(config), &descriptors)?;
            stat.set_ok();
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let vm_config = config.to_vm_config();
        let b_vm_config = Box::new(vm_config);
        let _ = ch
            .send_request(ApiRequest::VmCreate(b_vm_config))
            .map_err(|e| self.status_err(format!("Create vm failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Create vm failed:{}", e)))?;
        stat.set_ok();
        Ok(())
    }

    pub async fn boot_vm(&mut self) -> CResult<()> {
        let mut stat = self.new_stat(stat_defer::CALLEE_ACT_BOOT_VM.to_string());
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::BootVm, &[])?;
            self.status = HypStatus::Running;
            stat.set_ok();
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let _ = ch
            .send_request(ApiRequest::VmBoot)
            .map_err(|e| self.status_err(format!("Boot vm failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Boot vm failed:{}", e)))?;
        self.status = HypStatus::Running;
        stat.set_ok();
        Ok(())
    }

    pub async fn snapshot_vm(&self, path: &str, snapshot_type: SnapshotType) -> CResult<()> {
        if let Some(worker) = &self.worker {
            worker.request(
                WorkerCommand::SnapshotVm {
                    path: path.to_string(),
                    snapshot_type,
                },
                &[],
            )?;
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let snap_config = Arc::new(SnapshotConfig {
            destination_url: path.to_string(),
            snapshot_type,
            ..Default::default()
        });
        let _ = ch
            .send_request(ApiRequest::VmSnapshot(snap_config))
            .map_err(|e| self.status_err(format!("Snapshot vm failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Snapshot vm failed:{}", e)))?;

        Ok(())
    }

    pub async fn pause_vm(&self) -> CResult<()> {
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::PauseVm, &[])?;
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let _ = ch
            .send_request(ApiRequest::VmPause)
            .map_err(|e| self.status_err(format!("Pause vm failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Pause vm failed:{}", e)))?;

        Ok(())
    }

    pub async fn resume_vm(&self) -> CResult<()> {
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::ResumeVm, &[])?;
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let _ = ch
            .send_request(ApiRequest::VmResume)
            .map_err(|e| self.status_err(format!("Resume vm failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Resume vm failed:{}", e)))?;

        Ok(())
    }

    pub async fn restore_vm(&self, config: config::RestoreConfig) -> CResult<()> {
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::RestoreVm(config), &[])?;
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let mut stat = self.new_stat(stat_defer::CALLEE_ACT_RESTORE_VM.to_string());
        let restore_config = Arc::new(config);
        let _ = ch
            .send_request(ApiRequest::VmRestore(restore_config))
            .map_err(|e| self.status_err(format!("Restore vm failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Restore vm failed:{}", e)))?;
        stat.set_ok();
        Ok(())
    }

    pub async fn set_fs(&self, config: FsConfig) -> CResult<()> {
        infof!(self.log, "update fs allow dir start");
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::SetFs(config), &[])?;
            infof!(self.log, "update fs allow dir finish");
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let fs_config = Arc::new(config);
        let _ = ch
            .send_request(ApiRequest::VmSetFs(fs_config))
            .map_err(|e| self.status_err(format!("Setfs vm failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Setfs vm failed:{}", e)))?;
        infof!(self.log, "update fs allow dir finish");
        Ok(())
    }

    pub async fn add_dev(&self, config: DeviceConfig) -> CResult<String> {
        let id = config.id.clone().unwrap_or("".to_string());
        let id_pre = if let Some(id_pre) = id.split_once("-") {
            id_pre.0.to_string()
        } else {
            "".to_string()
        };
        let act = format!("{}-{}", CALLE_ACTION_ADD_DEV_PRE, id_pre);
        let mut stat = self.new_stat(act);
        if let Some(worker) = &self.worker {
            let reply = worker.request(WorkerCommand::AddDevice(config), &[])?;
            let bdf = match reply {
                WorkerReply::ActionPayload(Some(payload)) => {
                    serde_json::from_slice::<PciDeviceInfo>(&payload)
                        .map_err(|error| format!("decode worker add-device response: {error}"))?
                        .bdf
                        .to_string()
                }
                WorkerReply::ActionPayload(None) | WorkerReply::Empty => String::new(),
            };
            stat.set_ok();
            return Ok(bdf);
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let dev_config = Arc::new(config);
        let rsp = ch
            .send_request(ApiRequest::VmAddDevice(dev_config))
            .map_err(|e| self.status_err(format!("Add device failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Add device failed:{}", e)))?;

        match rsp {
            ApiResponsePayload::VmAction(Some(payload)) => {
                let ret = serde_json::from_slice::<PciDeviceInfo>(&payload).unwrap();
                return Ok(ret.bdf.to_string());
            }
            _ => {}
        }
        stat.set_ok();
        Ok("".to_string())
    }

    pub async fn remove_dev(&self, config: VmRemoveDeviceData) -> CResult<()> {
        infof!(self.log, "remove dev:{} start", config.id.clone());
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::RemoveDevice(config), &[])?;
            infof!(self.log, "remove dev finish");
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let dev_config = Arc::new(config);
        let _ = ch
            .send_request(ApiRequest::VmRemoveDevice(dev_config))
            .map_err(|e| self.status_err(format!("Rm device failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Rm device failed:{}", e)))?;
        infof!(self.log, "remove dev finish");
        Ok(())
    }

    pub async fn stop_vm(&self) -> CResult<()> {
        Ok(())
    }

    /// Delete the current VM (cube-hypervisor `VmDelete`).
    /// The VMM shuts down the VM if still running, then destroys the VM object.
    /// After this call the hypervisor process is still alive and can host a new VM
    /// (e.g. restored from a snapshot via `resume_vm_cube_with_config`).
    pub async fn delete_vm(&self) -> CResult<()> {
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::DeleteVm, &[])?;
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let _ = ch
            .send_request(ApiRequest::VmDelete)
            .map_err(|e| self.status_err(format!("Delete vm failed:{}", e)))?
            .map_err(|e| self.status_err(format!("Delete vm failed:{}", e)))?;
        Ok(())
    }

    /// Stop the VMM process even when the guest agent never became reachable.
    ///
    /// Sandbox startup can fail after the VMM thread is launched but before
    /// `SandBox::client` is installed. The normal guest-driven shutdown path
    /// cannot cover that interval, so rollback must address the VMM directly.
    pub async fn shutdown_vmm(&mut self) -> CResult<()> {
        if let Some(worker) = self.worker.take() {
            let result = worker.shutdown();
            self.status = HypStatus::Init;
            self.ev_receiver = None;
            return result;
        }
        let Some(instance) = self.ch.take() else {
            self.status = HypStatus::Init;
            self.ev_receiver = None;
            return Ok(());
        };

        let mut instance = instance.lock().await;
        let request_result = instance
            .send_request(ApiRequest::VmmShutdown)
            .map_err(|error| format!("shutdown vmm request failed:{error}"))
            .and_then(|response| {
                response.map_err(|error| format!("shutdown vmm response failed:{error}"))
            });
        let join_result = instance
            .join()
            .map_err(|error| format!("join vmm after shutdown failed:{error}"));
        self.status = HypStatus::Init;
        self.ev_receiver = None;

        request_result.and(join_result).map(|_| ())
    }

    pub async fn wait_notify(&self, timeout: Duration) -> CResult<NotifyEvent> {
        if let Some(recv) = &self.ev_receiver {
            let rx = recv.lock().await;
            return tokio::task::block_in_place(move || match rx.recv_timeout(timeout) {
                Ok(ev) => Ok(ev),
                Err(_e) => Err(format!(
                    "Receive event timeout after {}ms",
                    timeout.as_millis()
                )),
            });
        }
        Err("Receiver is uninitialized".to_string())
    }

    pub fn try_wait_notify(&self) -> CResult<NotifyEvent> {
        if let Some(recv) = &self.ev_receiver {
            let rx = {
                if let Ok(rx) = recv.try_lock() {
                    rx
                } else {
                    return Err("Receiver is busying".to_string());
                }
            };
            return match rx.try_recv() {
                Ok(ev) => Ok(ev),
                Err(e) => Err(format!("Receive event failed:{}", e)),
            };
        }
        Err("Receiver is uninitialized".to_string())
    }

    pub async fn join(&mut self) -> CResult<()> {
        if let Some(worker) = &self.worker {
            return worker.join();
        }
        let mut ch = self.ch.as_mut().unwrap().lock().await;
        ch.join().map_err(|e| format!("join ch failed:{}", e))
    }

    pub async fn pause_vm_cube(&self, path: &str) -> CResult<()> {
        self.pause_vm_cube_with_config(path, None).await
    }

    /// Pause the VM and write a snapshot. When `memory_vol_url` is set, memory
    /// ranges are stored on that CubeCow (or other) volume while config/state
    /// still land under `destination_url` — the same layout CommitSandbox /
    /// cube-runtime snapshot uses.
    pub async fn pause_vm_cube_with_config(
        &self,
        destination_url: &str,
        memory_vol_url: Option<String>,
    ) -> CResult<()> {
        let snap_config = Arc::new(SnapshotConfig {
            destination_url: destination_url.to_string(),
            memory_vol_url,
            ..Default::default()
        });
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::PauseToSnapshot((*snap_config).clone()), &[])?;
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let _ = ch
            .send_request(ApiRequest::VmPauseToSnapshot(snap_config))
            .map_err(|e| self.status_err(format!("pause vm to snapshot failed:{}", e)))?
            .map_err(|e| self.status_err(format!("pause vm to snapshot failed:{}", e)))?;

        Ok(())
    }

    pub async fn resume_vm_cube(&self, path: &str) -> CResult<()> {
        let restore_config = Arc::new(RestoreConfig {
            source_url: path.into(),
            ..Default::default()
        });
        if let Some(worker) = &self.worker {
            worker.request(
                WorkerCommand::ResumeFromSnapshot((*restore_config).clone()),
                &[],
            )?;
            return Ok(());
        }
        let ch = self.ch.as_ref().unwrap().lock().await;
        let _ = ch
            .send_request(ApiRequest::VmResumeFromSnapshot(restore_config))
            .map_err(|e| self.status_err(format!("resume vm from snapshot failed:{}", e)))?
            .map_err(|e| self.status_err(format!("resume vm from snapshot failed:{}", e)))?;

        Ok(())
    }

    pub async fn resume_vm_cube_with_config(&self, config: RestoreConfig) -> CResult<()> {
        if let Some(worker) = &self.worker {
            worker.request(WorkerCommand::ResumeFromSnapshot(config), &[])?;
            return Ok(());
        }
        let restore_config = Arc::new(config);
        let ch = self.ch.as_ref().unwrap().lock().await;
        let _ = ch
            .send_request(ApiRequest::VmResumeFromSnapshot(restore_config))
            .map_err(|e| self.status_err(format!("resume vm from snapshot failed:{}", e)))?
            .map_err(|e| self.status_err(format!("resume vm from snapshot failed:{}", e)))?;

        Ok(())
    }
}

#[cfg(test)]
mod backend_tests {
    use super::{select_vmm_backend, VmmBackendRoute};

    #[test]
    fn backend_route_requires_worker_switch_and_managed_placement() {
        assert_eq!(select_vmm_backend(true, true), VmmBackendRoute::Worker);
        assert_eq!(select_vmm_backend(true, false), VmmBackendRoute::Embedded);
        assert_eq!(select_vmm_backend(false, true), VmmBackendRoute::Embedded);
        assert_eq!(select_vmm_backend(false, false), VmmBackendRoute::Embedded);
    }
}

#[cfg(test)]
mod tests {
    use super::vmm_bootstrap;

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn vmm_filter_does_not_leak_into_reused_tokio_worker() {
        tokio::spawn(async {
            let parent = unsafe { libc::getppid() };
            vmm_bootstrap(move || {
                // Deny getppid only, so the test can observe filter inheritance
                // without requiring KVM or terminating the test process.
                let mut filter = [
                    libc::sock_filter {
                        code: 0x20,
                        jt: 0,
                        jf: 0,
                        k: 0,
                    },
                    libc::sock_filter {
                        code: 0x15,
                        jt: 0,
                        jf: 1,
                        k: libc::SYS_getppid as u32,
                    },
                    libc::sock_filter {
                        code: 0x06,
                        jt: 0,
                        jf: 0,
                        k: 0x0005_0000 | libc::EPERM as u32,
                    },
                    libc::sock_filter {
                        code: 0x06,
                        jt: 0,
                        jf: 0,
                        k: 0x7fff_0000,
                    },
                ];
                let program = libc::sock_fprog {
                    len: filter.len() as u16,
                    filter: filter.as_mut_ptr(),
                };
                // SAFETY: the program references the live filter array above;
                // no_new_privs and seccomp affect only this disposable thread.
                unsafe {
                    assert_eq!(libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0), 0);
                    assert_eq!(libc::prctl(libc::PR_SET_SECCOMP, 2, &program), 0);
                    assert_eq!(libc::syscall(libc::SYS_getppid), -1);
                }
                Ok(())
            })
            .unwrap();
            assert_eq!(unsafe { libc::getppid() }, parent);
            parent
        })
        .await
        .unwrap();
        assert!(
            tokio::spawn(async { unsafe { libc::getppid() } })
                .await
                .unwrap()
                > 0
        );
    }
}
