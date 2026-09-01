// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

//! cgroup v2 device filter backed by `BPF_PROG_TYPE_CGROUP_DEVICE`.

use std::collections::BTreeMap;
use std::ffi::CString;
use std::mem;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use oci::LinuxDeviceCgroup;

const BPF_PROG_LOAD: libc::c_long = 5;
const BPF_PROG_ATTACH: libc::c_long = 8;
const BPF_PROG_DETACH: libc::c_long = 9;
const BPF_PROG_TYPE_CGROUP_DEVICE: u32 = 15;
const BPF_CGROUP_DEVICE: u32 = 6;
const BPF_F_ALLOW_MULTI: u32 = 1 << 1;

const BPF_DEVCG_ACC_MKNOD: i32 = 1 << 0;
const BPF_DEVCG_ACC_READ: i32 = 1 << 1;
const BPF_DEVCG_ACC_WRITE: i32 = 1 << 2;
const BPF_DEVCG_ACC_ALL: i32 = BPF_DEVCG_ACC_MKNOD | BPF_DEVCG_ACC_READ | BPF_DEVCG_ACC_WRITE;
const BPF_DEVCG_DEV_BLOCK: i32 = 1 << 0;
const BPF_DEVCG_DEV_CHAR: i32 = 1 << 1;
const MAX_DEVICE_RULES: usize = 4096;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct DeviceMeta {
    kind: u8,
    major: i64,
    minor: i64,
}

#[derive(Default)]
struct Emulator {
    default_allow: bool,
    rules: BTreeMap<DeviceMeta, u8>,
}

fn permissions(value: &str) -> Result<u8> {
    let mut result = 0;
    for value in value.bytes() {
        result |= match value {
            b'r' => 1,
            b'w' => 2,
            b'm' => 4,
            _ => bail!("invalid device permission {:?}", value as char),
        };
    }
    if result == 0 {
        bail!("device access must not be empty");
    }
    Ok(result)
}

impl Emulator {
    fn apply(&mut self, rule: &LinuxDeviceCgroup) -> Result<()> {
        let access = permissions(&rule.access)?;
        let kind = match rule.r#type.as_str() {
            "a" => {
                if access != 7 {
                    bail!("wildcard device rule must use rwm access");
                }
                self.default_allow = rule.allow;
                self.rules.clear();
                return Ok(());
            }
            "b" => b'b',
            "c" => b'c',
            value => bail!("invalid cgroup device type {value:?}"),
        };
        let major = rule.major.unwrap_or(-1);
        let minor = rule.minor.unwrap_or(-1);
        for (field, value) in [("major", major), ("minor", minor)] {
            if value < -1 || value > u32::MAX as i64 {
                bail!("device {field} must be -1 or a uint32, got {value}");
            }
        }
        let meta = DeviceMeta { kind, major, minor };
        if rule.allow {
            if self.default_allow {
                self.remove(meta, access)?;
            } else {
                self.add(meta, access);
            }
        } else if self.default_allow {
            self.add(meta, access);
        } else {
            self.remove(meta, access)?;
        }
        Ok(())
    }

    fn add(&mut self, meta: DeviceMeta, access: u8) {
        self.rules
            .entry(meta)
            .and_modify(|value| *value |= access)
            .or_insert(access);
    }

    fn remove(&mut self, meta: DeviceMeta, access: u8) -> Result<()> {
        for partial in [
            DeviceMeta {
                kind: meta.kind,
                major: -1,
                minor: meta.minor,
            },
            DeviceMeta {
                kind: meta.kind,
                major: meta.major,
                minor: -1,
            },
            DeviceMeta {
                kind: meta.kind,
                major: -1,
                minor: -1,
            },
        ] {
            if partial != meta
                && self
                    .rules
                    .get(&partial)
                    .map_or(false, |value| value & access != 0)
            {
                bail!(
                    "cannot punch device exception {:?} through wildcard rule {:?}",
                    meta,
                    partial
                );
            }
        }
        if let Some(value) = self.rules.get_mut(&meta) {
            *value &= !access;
            if *value == 0 {
                self.rules.remove(&meta);
            }
        }
        Ok(())
    }

    #[cfg(test)]
    fn allows(&self, kind: u8, major: u32, minor: u32, access: u8) -> bool {
        for (meta, permissions) in &self.rules {
            if meta.kind == kind
                && (meta.major == -1 || meta.major == major as i64)
                && (meta.minor == -1 || meta.minor == minor as i64)
                && permissions & access == access
            {
                return !self.default_allow;
            }
        }
        self.default_allow
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct BpfInsn {
    code: u8,
    dst_src: u8,
    off: i16,
    imm: i32,
}

impl BpfInsn {
    fn new(code: u8, dst: u8, src: u8, off: i16, imm: i32) -> Self {
        Self {
            code,
            dst_src: (src << 4) | dst,
            off,
            imm,
        }
    }
}

fn instructions(emulator: &Emulator) -> Result<Vec<BpfInsn>> {
    // R2=type, R3=access, R4=major, R5=minor from bpf_cgroup_dev_ctx.
    let mut result = vec![
        BpfInsn::new(0x61, 2, 1, 0, 0),
        BpfInsn::new(0x54, 2, 0, 0, 0xffff),
        BpfInsn::new(0x61, 3, 1, 0, 0),
        BpfInsn::new(0x74, 3, 0, 0, 16),
        BpfInsn::new(0x61, 4, 1, 0, 4),
        BpfInsn::new(0x61, 5, 1, 0, 8),
    ];
    for (meta, permissions) in &emulator.rules {
        let device_kind = match meta.kind {
            b'b' => BPF_DEVCG_DEV_BLOCK,
            b'c' => BPF_DEVCG_DEV_CHAR,
            _ => bail!("invalid emulated device type {:?}", meta.kind as char),
        };
        let mut block = vec![BpfInsn::new(0x55, 2, 0, 0, device_kind)];
        let access = (if permissions & 1 != 0 {
            BPF_DEVCG_ACC_READ
        } else {
            0
        }) | (if permissions & 2 != 0 {
            BPF_DEVCG_ACC_WRITE
        } else {
            0
        }) | (if permissions & 4 != 0 {
            BPF_DEVCG_ACC_MKNOD
        } else {
            0
        });
        if access != BPF_DEVCG_ACC_ALL {
            block.extend([
                BpfInsn::new(0xbc, 1, 3, 0, 0),
                BpfInsn::new(0x54, 1, 0, 0, access),
                BpfInsn::new(0x5d, 1, 3, 0, 0),
            ]);
        }
        if meta.major >= 0 {
            block.push(BpfInsn::new(0x55, 4, 0, 0, meta.major as i32));
        }
        if meta.minor >= 0 {
            block.push(BpfInsn::new(0x55, 5, 0, 0, meta.minor as i32));
        }
        let allow = !emulator.default_allow;
        block.push(BpfInsn::new(0xb4, 0, 0, 0, i32::from(allow)));
        block.push(BpfInsn::new(0x95, 0, 0, 0, 0));
        let block_len = block.len();
        for (index, instruction) in block.iter_mut().enumerate() {
            if matches!(instruction.code, 0x55 | 0x5d) {
                instruction.off =
                    i16::try_from(block_len - index - 1).context("device BPF jump exceeds i16")?;
            }
        }
        result.extend(block);
    }
    result.extend([
        BpfInsn::new(0xb4, 0, 0, 0, i32::from(emulator.default_allow)),
        BpfInsn::new(0x95, 0, 0, 0, 0),
    ]);
    Ok(result)
}

#[repr(C)]
struct ProgLoadAttr {
    prog_type: u32,
    insn_cnt: u32,
    insns: u64,
    license: u64,
    log_level: u32,
    log_size: u32,
    log_buf: u64,
}

#[repr(C)]
struct ProgAttachAttr {
    target_fd: u32,
    attach_bpf_fd: u32,
    attach_type: u32,
    attach_flags: u32,
    replace_bpf_fd: u32,
}

fn bpf(command: libc::c_long, attribute: *const libc::c_void, size: usize) -> Result<libc::c_long> {
    for attempt in 0..=30 {
        let result = unsafe { libc::syscall(libc::SYS_bpf, command, attribute, size) };
        if result >= 0 {
            return Ok(result);
        }
        let error = std::io::Error::last_os_error();
        let retryable = matches!(
            error.raw_os_error(),
            Some(code) if code == libc::EAGAIN || code == libc::EINTR
        );
        if command == BPF_PROG_LOAD && retryable && attempt < 30 {
            continue;
        }
        return Err(error).with_context(|| format!("bpf command {command}"));
    }
    unreachable!()
}

fn load_program(program: &[BpfInsn]) -> Result<libc::c_int> {
    let license = CString::new("Apache").unwrap();
    let mut verifier_log = vec![0_u8; 64 * 1024];
    let attribute = ProgLoadAttr {
        prog_type: BPF_PROG_TYPE_CGROUP_DEVICE,
        insn_cnt: u32::try_from(program.len()).context("device BPF program is too large")?,
        insns: program.as_ptr() as u64,
        license: license.as_ptr() as u64,
        log_level: 1,
        log_size: verifier_log.len() as u32,
        log_buf: verifier_log.as_mut_ptr() as u64,
    };
    match bpf(
        BPF_PROG_LOAD,
        &attribute as *const _ as *const libc::c_void,
        mem::size_of::<ProgLoadAttr>(),
    ) {
        Ok(fd) => Ok(fd as libc::c_int),
        Err(error) => {
            let end = verifier_log
                .iter()
                .position(|value| *value == 0)
                .unwrap_or(verifier_log.len());
            let log = String::from_utf8_lossy(&verifier_log[..end]);
            Err(error).context(format!("load cgroup device BPF program: {log}"))
        }
    }
}

fn attach_program(cgroup_fd: libc::c_int, program_fd: libc::c_int) -> Result<()> {
    let attribute = ProgAttachAttr {
        target_fd: cgroup_fd as u32,
        attach_bpf_fd: program_fd as u32,
        attach_type: BPF_CGROUP_DEVICE,
        attach_flags: BPF_F_ALLOW_MULTI,
        replace_bpf_fd: 0,
    };
    bpf(
        BPF_PROG_ATTACH,
        &attribute as *const _ as *const libc::c_void,
        mem::size_of::<ProgAttachAttr>(),
    )?;
    Ok(())
}

fn detach_program(cgroup_fd: libc::c_int, program_fd: libc::c_int) -> Result<()> {
    let attribute = ProgAttachAttr {
        target_fd: cgroup_fd as u32,
        attach_bpf_fd: program_fd as u32,
        attach_type: BPF_CGROUP_DEVICE,
        attach_flags: 0,
        replace_bpf_fd: 0,
    };
    bpf(
        BPF_PROG_DETACH,
        &attribute as *const _ as *const libc::c_void,
        mem::size_of::<ProgAttachAttr>(),
    )?;
    Ok(())
}

pub struct AttachedDeviceFilter {
    cgroup_fd: libc::c_int,
    program_fd: libc::c_int,
    attached: bool,
}

impl AttachedDeviceFilter {
    pub fn commit(mut self) {
        self.attached = false;
    }

    pub fn rollback(mut self) -> Result<()> {
        detach_program(self.cgroup_fd, self.program_fd)?;
        self.attached = false;
        Ok(())
    }
}

impl Drop for AttachedDeviceFilter {
    fn drop(&mut self) {
        if self.attached {
            let _ = detach_program(self.cgroup_fd, self.program_fd);
        }
        unsafe {
            libc::close(self.program_fd);
            libc::close(self.cgroup_fd);
        }
    }
}

pub fn attach(root: &Path, rules: &[LinuxDeviceCgroup]) -> Result<AttachedDeviceFilter> {
    if rules.len() > MAX_DEVICE_RULES {
        bail!(
            "device rule count {} exceeds maximum {}",
            rules.len(),
            MAX_DEVICE_RULES
        );
    }
    let mut emulator = Emulator::default();
    for rule in rules {
        emulator.apply(rule)?;
    }
    let program = instructions(&emulator)?;
    let path = CString::new(root.as_os_str().as_bytes())
        .map_err(|_| anyhow!("cgroup path contains a NUL byte: {}", root.display()))?;
    let cgroup_fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_DIRECTORY | libc::O_RDONLY | libc::O_CLOEXEC,
        )
    };
    if cgroup_fd < 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("open resource cgroup {}", root.display()));
    }
    let program_fd = match load_program(&program) {
        Ok(fd) => fd,
        Err(error) => {
            unsafe { libc::close(cgroup_fd) };
            return Err(error);
        }
    };
    if let Err(error) = attach_program(cgroup_fd, program_fd) {
        unsafe {
            libc::close(program_fd);
            libc::close(cgroup_fd);
        }
        return Err(error).context("attach cgroup device BPF program");
    }
    Ok(AttachedDeviceFilter {
        cgroup_fd,
        program_fd,
        attached: true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(program: &[BpfInsn], kind: i32, major: u32, minor: u32, access: i32) -> bool {
        let context = [((access << 16) | kind) as u32, major, minor];
        let mut registers = [0_u64; 6];
        let mut pc = 0_usize;
        while pc < program.len() {
            let instruction = program[pc];
            let dst = (instruction.dst_src & 0xf) as usize;
            let src = (instruction.dst_src >> 4) as usize;
            match instruction.code {
                0x61 => registers[dst] = context[(instruction.imm / 4) as usize] as u64,
                0x54 => registers[dst] = (registers[dst] as u32 & instruction.imm as u32) as u64,
                0x74 => registers[dst] = (registers[dst] as u32 >> instruction.imm) as u64,
                0xbc => registers[dst] = registers[src] as u32 as u64,
                0x55 => {
                    if registers[dst] as u32 != instruction.imm as u32 {
                        pc += instruction.off as usize;
                    }
                }
                0x5d => {
                    if registers[dst] as u32 != registers[src] as u32 {
                        pc += instruction.off as usize;
                    }
                }
                0xb4 => registers[dst] = instruction.imm as u32 as u64,
                0x95 => return registers[0] != 0,
                code => panic!("unsupported test BPF opcode {code:#x}"),
            }
            pc += 1;
        }
        panic!("device BPF program did not return")
    }

    fn rule(
        allow: bool,
        kind: &str,
        major: Option<i64>,
        minor: Option<i64>,
        access: &str,
    ) -> LinuxDeviceCgroup {
        LinuxDeviceCgroup {
            allow,
            r#type: kind.to_string(),
            major,
            minor,
            access: access.to_string(),
        }
    }

    #[test]
    fn whitelist_and_privileged_allow_all_match_cgroup_v1_emulation() {
        let mut whitelist = Emulator::default();
        whitelist
            .apply(&rule(true, "c", Some(1), Some(3), "rwm"))
            .unwrap();
        assert!(whitelist.allows(b'c', 1, 3, 1));
        assert!(!whitelist.allows(b'c', 1, 5, 1));

        let mut privileged = Emulator::default();
        privileged
            .apply(&rule(true, "a", None, None, "rwm"))
            .unwrap();
        privileged
            .apply(&rule(true, "c", Some(1), Some(3), "rwm"))
            .unwrap();
        assert!(privileged.allows(b'c', 250, 250, 7));
        assert!(privileged.allows(b'b', 8, 0, 3));
    }

    #[test]
    fn wildcard_hole_and_invalid_rules_fail_closed() {
        let mut emulator = Emulator::default();
        emulator.apply(&rule(true, "c", None, None, "rwm")).unwrap();
        assert!(emulator
            .apply(&rule(false, "c", Some(1), Some(3), "r"))
            .is_err());
        assert!(emulator
            .apply(&rule(true, "x", Some(1), Some(3), "r"))
            .is_err());
        assert!(emulator
            .apply(&rule(true, "c", Some(1), Some(3), "rx"))
            .is_err());
    }

    #[test]
    fn generated_program_has_valid_local_jumps_and_terminal_default() {
        let mut emulator = Emulator::default();
        emulator
            .apply(&rule(true, "c", Some(1), None, "rw"))
            .unwrap();
        let program = instructions(&emulator).unwrap();
        assert!(program.len() > 8);
        for instruction in &program {
            if matches!(instruction.code, 0x55 | 0x5d) {
                assert!(instruction.off > 0);
            }
        }
        assert_eq!(program[program.len() - 2].imm, 0);
        assert_eq!(program.last().unwrap().code, 0x95);
        assert!(run(&program, BPF_DEVCG_DEV_CHAR, 1, 9, BPF_DEVCG_ACC_READ));
        assert!(!run(
            &program,
            BPF_DEVCG_DEV_CHAR,
            1,
            9,
            BPF_DEVCG_ACC_MKNOD
        ));
        assert!(!run(
            &program,
            BPF_DEVCG_DEV_BLOCK,
            1,
            9,
            BPF_DEVCG_ACC_READ
        ));
    }
}
