#!/usr/bin/env python3
"""向节点默认 containerd 配置增量注入 Cube runtime。"""
import argparse
import copy
import json
import pathlib
import re
import subprocess
import tomllib

CRI17 = "io.containerd.grpc.v1.cri"
CRI2 = "io.containerd.cri.v1.runtime"
SHIM_MANAGER = "io.containerd.shim.v1.manager"


def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def option(args, names, default):
    value = default
    for i, arg in enumerate(args):
        if arg in names:
            value = args[i + 1]
        for name in names:
            if arg.startswith(name + "="):
                value = arg.split("=", 1)[1]
    return value


def relocate_imports(imports, source):
    paths = [source.parent / path for path in imports]
    # 1.7 config dump adds its own source file to imports. Reimporting that
    # file would overwrite the new Cube handler (or recurse on reinstallation).
    return [str(path) for path in paths if path.resolve() != source.resolve()]


def with_config(args, path):
    result = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("--config", "-c"):
            i += 2
            continue
        if not arg.startswith(("--config=", "-c=")):
            result.append(arg)
        i += 1
    return ["--config", str(path), *result]


def family(version):
    match = re.search(r"\bv?(\d+)\.(\d+)\.\d+", version)
    if match and match[1] == "1" and match[2] == "7":
        return "1.7"
    if match and match[1] == "2":
        return "2"
    raise ValueError(f"不支持的节点 containerd 版本: {version}")


def runtime_table(data, major):
    plugins = data.get("plugins", {})
    if major == "1.7":
        if CRI17 not in plugins:
            raise ValueError("containerd 1.7 配置缺少 CRI 插件")
        return CRI17, "sandbox_mode"
    if CRI2 in plugins:
        return CRI2, "sandboxer"
    # containerd 2.x can still be started with a version=2, legacy CRI
    # configuration. Keep that input format intact; `config dump` migrates it
    # to io.containerd.cri.v1.runtime at load time.
    if CRI17 in plugins:
        return CRI17, "sandbox_mode"
    raise ValueError("containerd 2.x 配置缺少 CRI 插件")


def default_tracing():
    return {"endpoint": "", "protocol": "http/protobuf", "service_name": "cube-cri-containerd", "sampling_ratio": "1.0"}


def tracing_env(tracing):
    if not tracing["endpoint"]:
        return []
    return [
        f"OTEL_EXPORTER_OTLP_ENDPOINT={tracing['endpoint']}",
        f"OTEL_EXPORTER_OTLP_PROTOCOL={tracing['protocol']}",
        f"OTEL_SERVICE_NAME={tracing['service_name']}",
        "OTEL_TRACES_SAMPLER=traceidratio",
        f"OTEL_TRACES_SAMPLER_ARG={tracing['sampling_ratio']}",
    ]


def shim_env(kernel_cmdline_append, guest_boot_trace, include_privileged=True, tracing=None):
    tracing = tracing or default_tracing()
    env = []
    if include_privileged:
        env.append("CUBE_ALLOW_PRIVILEGED=true")
    if guest_boot_trace:
        env.append("CUBE_GUEST_BOOT_TRACE=1")
    if tracing["endpoint"]:
        env.extend([
            f"CUBE_CRI_TRACING_OTLP_ENDPOINT={tracing['endpoint']}",
            f"CUBE_CRI_TRACING_OTLP_PROTOCOL={tracing['protocol']}",
            f"CUBE_CRI_TRACING_SERVICE_NAME={tracing['service_name']}-shim",
            f"CUBE_CRI_TRACING_SAMPLING_RATIO={tracing['sampling_ratio']}",
        ])
    if kernel_cmdline_append:
        env.append("CUBE_GUEST_KERNEL_CMDLINE_APPEND=" + json.dumps(kernel_cmdline_append, ensure_ascii=False))
    return env


def proxy_backend_address(address):
    path = pathlib.Path(address)
    return str(path.with_name(path.stem + "-real" + path.suffix))


def proxy_addresses(address):
    path = pathlib.Path(address)
    stem = path.stem
    while stem.endswith("-real"):
        stem = stem[:-len("-real")]
    frontend = path.with_name(stem + path.suffix)
    backend = path.with_name(stem + "-real" + path.suffix)
    return str(frontend), str(backend)


def configure(text, major, kernel_cmdline_append=None, guest_boot_trace=False, tracing=None, grpc_address=None):
    kernel_cmdline_append = list(kernel_cmdline_append or [])
    tracing = tracing or default_tracing()
    if tracing["endpoint"] and "agent.trace=1" not in kernel_cmdline_append:
        kernel_cmdline_append.append("agent.trace=1")
    data = tomllib.loads(text)
    plugin, sandbox_key = runtime_table(data, major)
    runtimes = data["plugins"][plugin]["containerd"]["runtimes"]
    existing = runtimes.get("cube", {})
    if existing and existing.get("runtime_type") != "io.containerd.cube.rs":
        raise ValueError("节点已有其他运行时使用 cube handler，请先处理名称冲突")
    if any(p in data.get("disabled_plugins", []) for p in ("cri", plugin)):
        raise ValueError("节点禁用了 CRI 插件")
    expected = copy.deepcopy(data)
    if grpc_address:
        expected.setdefault("grpc", {})["address"] = grpc_address
    handler = {
        "runtime_type": "io.containerd.cube.rs",
        "runtime_path": "/opt/cube-cri/current/bin/containerd-shim-cube-rs",
        sandbox_key: "shim",
        "privileged_without_host_devices": True,
        "privileged_without_host_devices_all_devices_allowed": True,
    }
    expected["plugins"][plugin]["containerd"]["runtimes"]["cube"] = handler
    if major == "2":
        manager = expected["plugins"].setdefault(SHIM_MANAGER, {})
        cube_env_prefixes = (
            "CUBE_ALLOW_PRIVILEGED=",
            "CUBE_GUEST_BOOT_TRACE=",
            "CUBE_GUEST_KERNEL_CMDLINE_APPEND=",
            "CUBE_CRI_TRACING_OTLP_ENDPOINT=",
            "CUBE_CRI_TRACING_OTLP_PROTOCOL=",
            "CUBE_CRI_TRACING_SERVICE_NAME=",
            "CUBE_CRI_TRACING_SAMPLING_RATIO=",
        )
        manager["env"] = [
            value for value in manager.get("env", []) if not value.startswith(cube_env_prefixes)
        ] + shim_env(kernel_cmdline_append, guest_boot_trace, tracing=tracing)
    # Parse headers instead of relying on the quote style used by a particular
    # containerd/TOML library version. This keeps all unrelated node settings
    # byte-for-byte intact.
    lines = []
    skip = False
    in_grpc = False
    grpc_seen = False
    in_manager = False
    manager_seen = False
    for line in text.splitlines():
        if line.lstrip().startswith("["):
            section = tomllib.loads(line)
            in_grpc = "grpc" in section and len(section) == 1
            if grpc_address and in_grpc:
                grpc_seen = True
                lines.extend([line, "  address = " + json.dumps(grpc_address)])
                continue
            skip = "cube" in section.get("plugins", {}).get(plugin, {}).get("containerd", {}).get("runtimes", {})
            in_manager = major == "2" and SHIM_MANAGER in section.get("plugins", {})
            if in_manager:
                manager_seen = True
                lines.extend([line, "  env = " + json.dumps(manager["env"])])
                continue
        if grpc_address and in_grpc and re.match(r"\s*address\s*=", line):
            continue
        if in_manager and re.match(r"\s*env\s*=", line):
            continue
        if not skip:
            lines.append(line)
    while lines and not lines[-1].strip():
        lines.pop()
    if grpc_address and not grpc_seen:
        lines.extend(["\n[grpc]", "  address = " + json.dumps(grpc_address)])
    if major == "2" and not manager_seen:
        lines.extend([f'\n[plugins."{SHIM_MANAGER}"]', "  env = " + json.dumps(manager["env"])])
    lines.append(f'\n[plugins."{plugin}".containerd.runtimes.cube]')
    lines.extend(f"  {key} = {json.dumps(value)}" for key, value in handler.items())
    result = "\n".join(lines) + "\n"
    if tomllib.loads(result) != expected:
        raise ValueError("生成配置意外修改了 Cube handler 或 shim 环境变量以外的内容")
    return result


def validation_text(text, source):
    """Make relative imports keep the source file's meaning during validation."""
    parsed = tomllib.loads(text)
    imports = parsed.get("imports", [])
    absolute_imports = relocate_imports(imports, source)
    if imports == absolute_imports:
        return text
    return re.sub(r"^imports\s*=.*$", "imports = " + json.dumps(absolute_imports), text, flags=re.M)


def unit_arg(arg):
    if any(c in arg for c in "\n\r\0"):
        raise ValueError("containerd 启动参数含控制字符")
    return '"' + arg.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$") + '"'


def load_kernel_cmdline_append(path):
    if path is None:
        return []
    params = json.loads(path.read_text())
    if not isinstance(params, list) or not all(isinstance(param, str) for param in params):
        raise ValueError("guest kernel cmdline append must be a JSON string array")
    return [param.strip() for param in params if param.strip()]


def tracing_config(endpoint, protocol, service_name, sampling_ratio):
    if not endpoint:
        return default_tracing()
    if protocol not in ("http/protobuf", "grpc"):
        raise ValueError("unsupported tracing protocol")
    try:
        ratio = float(sampling_ratio)
    except ValueError as error:
        raise ValueError("tracing sampling ratio must be numeric") from error
    if ratio < 0 or ratio > 1:
        raise ValueError("tracing sampling ratio must be in [0,1]")
    return {"endpoint": endpoint, "protocol": protocol, "service_name": service_name, "sampling_ratio": sampling_ratio}


def prepare(pid, output, config_path, kernel_cmdline_append, guest_boot_trace, tracing=None):
    tracing = tracing or default_tracing()
    proc = pathlib.Path(f"/proc/{pid}")
    binary = str((proc / "exe").resolve(strict=True))
    if not pathlib.Path(binary).is_file():
        raise ValueError("运行中的 containerd 二进制已被替换，请先恢复节点服务")
    args = (proc / "cmdline").read_bytes().decode().rstrip("\0").split("\0")[1:]
    cwd = str((proc / "cwd").resolve(strict=True))
    source = config_path
    if not source.is_absolute():
        source = pathlib.Path(cwd) / source
    source = source.resolve(strict=True)
    version = command(binary, "--version")
    major = family(version)
    source_text = source.read_text()
    source_data = tomllib.loads(source_text)
    frontend_address = option(args, ("--address", "-a"), source_data.get("grpc", {}).get("address", "/run/containerd/containerd.sock"))
    backend_address = frontend_address
    if tracing["endpoint"]:
        if option(args, ("--address", "-a"), None):
            raise ValueError("开启 tracing proxy 时不支持 containerd ExecStart 使用 --address/-a 覆盖 socket")
        frontend_address, backend_address = proxy_addresses(frontend_address)
    rendered = configure(source_text, major, kernel_cmdline_append, guest_boot_trace, tracing, backend_address if tracing["endpoint"] else None)
    output.mkdir(parents=True, exist_ok=True)
    (output / "containerd.toml").write_text(rendered)
    validation = output / "containerd.validation.toml"
    validation.write_text(validation_text(rendered, source))
    resolved = command(binary, *with_config(args, validation), "config", "dump", cwd=cwd)
    effective = tomllib.loads(resolved)
    plugin = CRI17 if major == "1.7" else CRI2
    effective_handler = effective["plugins"][plugin]["containerd"]["runtimes"]["cube"]
    expected_handler = tomllib.loads(rendered)["plugins"][runtime_table(tomllib.loads(rendered), major)[0]]["containerd"]["runtimes"]["cube"]
    expected_sandbox_key = "sandbox_mode" if major == "1.7" else "sandboxer"
    if any(effective_handler.get(k) != v for k, v in expected_handler.items() if k != "sandbox_mode") or effective_handler.get(expected_sandbox_key) != "shim":
        raise ValueError("节点 imports 或启动参数覆盖了 Cube handler")
    if major == "2" and effective["plugins"][SHIM_MANAGER]["env"] != tomllib.loads(rendered)["plugins"][SHIM_MANAGER]["env"]:
        raise ValueError("节点 imports 覆盖了 shim 环境变量")
    validation.unlink()
    (output / "containerd.resolved.toml").write_text(resolved + "\n")
    requires = "cube-cri-runtime-resource.service cubesandbox-shim-watchdog.service"
    after = "cube-cri-runtime-resource.service cubesandbox-shim-watchdog.service"
    if tracing["endpoint"]:
        requires += " cube-cri-trace-proxy.service"
        after += " cube-cri-trace-proxy.service"
    unit = f"""[Unit]
# Managed by Cube CRI. Keep containerd's original ExecStart and config path.
Requires={requires}
After={after}
[Service]
Environment=CUBE_RUNTIME_RESOURCE_ENDPOINT=/run/cube-cri/runtime-resource.sock
Environment=CUBE_RUNTIME_RESOURCE_REAPER_DIR=/data/cubelet/runtime-resource-reaper
Environment=CUBE_CRI_METRICS_SOCKET=/run/cube-cri/metrics.sock
Environment=CUBE_VMM_WORKER_PATH=/opt/cube-cri/current/bin/cube-vmm-worker
"""
    for env in tracing_env(tracing):
        unit += "Environment=" + unit_arg(env) + "\n"
    for env in shim_env(kernel_cmdline_append, guest_boot_trace, include_privileged=False, tracing=tracing):
        unit += "Environment=" + unit_arg(env) + "\n"
    unit += "Environment=ENABLE_CRI_SANDBOXES=1\nEnvironment=CUBE_ALLOW_PRIVILEGED=true\n" if major == "1.7" else "UnsetEnvironment=ENABLE_CRI_SANDBOXES\n"
    (output / "containerd.service.conf").write_text(unit)
    metadata = {"binary": binary, "version": version, "family": major, "source_config": str(source),
                "address": frontend_address, "backend_address": backend_address}
    (output / "containerd.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(f"复用节点 containerd: {version}; binary={binary}; config={source}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--pid", type=int, help="测试隔离实例；默认使用 containerd.service MainPID")
    parser.add_argument("--config-path", type=pathlib.Path)
    parser.add_argument("--guest-kernel-cmdline-append-file", type=pathlib.Path)
    parser.add_argument("--guest-boot-trace", action="store_true", help="捕获每个 Guest 的 serial/console 日志")
    parser.add_argument("--otel-endpoint", default="")
    parser.add_argument("--otel-protocol", default="http/protobuf")
    parser.add_argument("--otel-service-name", default="cube-cri-containerd")
    parser.add_argument("--otel-sampling-ratio", default="1.0")
    parser.add_argument("--enable-agent-tracing", action="store_true")
    options = parser.parse_args()
    pid = options.pid or int(command("systemctl", "show", "containerd", "--property=MainPID", "--value"))
    if pid <= 0:
        parser.error("节点 containerd.service 未运行")
    prepare(
        pid,
        options.output,
        options.config_path or options.output / "containerd.toml",
        load_kernel_cmdline_append(options.guest_kernel_cmdline_append_file) + (["agent.trace=1"] if options.enable_agent_tracing else []),
        options.guest_boot_trace,
        tracing_config(options.otel_endpoint, options.otel_protocol, options.otel_service_name, options.otel_sampling_ratio),
    )
