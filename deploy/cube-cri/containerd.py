#!/usr/bin/env python3
"""从运行中的节点服务生成 Cube 配置，不安装或切换 containerd。"""
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


def configure(text, major):
    data = tomllib.loads(text)
    plugin = CRI17 if major == "1.7" else CRI2
    runtimes = data["plugins"][plugin]["containerd"]["runtimes"]
    existing = runtimes.get("cube", {})
    if existing and existing.get("runtime_type") != "io.containerd.cube.rs":
        raise ValueError("节点已有其他运行时使用 cube handler，请先处理名称冲突")
    if any(p in data.get("disabled_plugins", []) for p in ("cri", plugin)):
        raise ValueError("节点禁用了 CRI 插件")
    expected = copy.deepcopy(data)
    handler = {
        "runtime_type": "io.containerd.cube.rs",
        "runtime_path": "/opt/cube-cri/current/bin/containerd-shim-cube-rs",
        "sandbox_mode" if major == "1.7" else "sandboxer": "shim",
        "privileged_without_host_devices": True,
        "privileged_without_host_devices_all_devices_allowed": True,
    }
    expected["plugins"][plugin]["containerd"]["runtimes"]["cube"] = handler
    if major == "2":
        manager = expected["plugins"].setdefault(SHIM_MANAGER, {})
        manager["env"] = [value for value in manager.get("env", [])
                          if not value.startswith("CUBE_ALLOW_PRIVILEGED=")] + ["CUBE_ALLOW_PRIVILEGED=true"]
    # config migrate may retain the old required-plugin ID even after migration.
    required = []
    for name in data.get("required_plugins", []):
        required.extend(["io.containerd.cri.v1.images", CRI2] if major == "2" and name == CRI17 else [name])
    if "required_plugins" in data:
        expected["required_plugins"] = list(dict.fromkeys(required))
        text = re.sub(r"^required_plugins\s*=.*$", "required_plugins = " + json.dumps(expected["required_plugins"]), text, flags=re.M)
    # Work on normalized containerd output. Parse headers instead of relying on
    # the quote style used by a particular containerd/TOML library version.
    lines = []
    skip = False
    in_manager = False
    manager_seen = False
    for line in text.splitlines():
        if line.lstrip().startswith("["):
            section = tomllib.loads(line)
            skip = "cube" in section.get("plugins", {}).get(plugin, {}).get("containerd", {}).get("runtimes", {})
            in_manager = major == "2" and SHIM_MANAGER in section.get("plugins", {})
            if in_manager:
                manager_seen = True
                lines.extend([line, "  env = " + json.dumps(manager["env"])])
                continue
        if in_manager and re.match(r"\s*env\s*=", line):
            continue
        if not skip:
            lines.append(line)
    while lines and not lines[-1].strip():
        lines.pop()
    if major == "2" and not manager_seen:
        lines.extend([f'\n[plugins."{SHIM_MANAGER}"]', "  env = " + json.dumps(manager["env"])])
    lines.append(f'\n[plugins."{plugin}".containerd.runtimes.cube]')
    lines.extend(f"  {key} = {json.dumps(value)}" for key, value in handler.items())
    result = "\n".join(lines) + "\n"
    if tomllib.loads(result) != expected:
        raise ValueError("生成配置意外修改了 Cube handler 或 shim 环境变量以外的内容")
    return result


def unit_arg(arg):
    if any(c in arg for c in "\n\r\0"):
        raise ValueError("containerd 启动参数含控制字符")
    return '"' + arg.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$") + '"'


def prepare(pid, output, config_path):
    proc = pathlib.Path(f"/proc/{pid}")
    binary = str((proc / "exe").resolve(strict=True))
    if not pathlib.Path(binary).is_file():
        raise ValueError("运行中的 containerd 二进制已被替换，请先恢复节点服务")
    args = (proc / "cmdline").read_bytes().decode().rstrip("\0").split("\0")[1:]
    cwd = str((proc / "cwd").resolve(strict=True))
    source = pathlib.Path(option(args, ("--config", "-c"), "/etc/containerd/config.toml"))
    if not source.is_absolute():
        source = pathlib.Path(cwd) / source
    source = source.resolve(strict=True)
    version = command(binary, "--version")
    major = family(version)
    normalized = command(binary, *args, "config", "dump" if major == "1.7" else "migrate", cwd=cwd)
    # Moving a config must not change how its relative import paths resolve.
    parsed = tomllib.loads(normalized)
    imports = parsed.get("imports", [])
    absolute_imports = relocate_imports(imports, source)
    if imports != absolute_imports:
        normalized = re.sub(r"^imports\s*=.*$", "imports = " + json.dumps(absolute_imports), normalized, flags=re.M)
    rendered = configure(normalized, major)
    output.mkdir(parents=True, exist_ok=True)
    (output / "containerd.toml").write_text(rendered)
    resolved = command(binary, *with_config(args, output / "containerd.toml"), "config", "dump", cwd=cwd)
    plugin = CRI17 if major == "1.7" else CRI2
    expected_handler = tomllib.loads(rendered)["plugins"][plugin]["containerd"]["runtimes"]["cube"]
    effective_handler = tomllib.loads(resolved)["plugins"][plugin]["containerd"]["runtimes"]["cube"]
    if any(effective_handler.get(k) != v for k, v in expected_handler.items()):
        raise ValueError("节点 imports 或启动参数覆盖了 Cube handler")
    if major == "2" and tomllib.loads(resolved)["plugins"][SHIM_MANAGER]["env"] != tomllib.loads(rendered)["plugins"][SHIM_MANAGER]["env"]:
        raise ValueError("节点 imports 覆盖了 shim 环境变量")
    (output / "containerd.resolved.toml").write_text(resolved + "\n")
    final_args = [binary, *with_config(args, config_path)]
    unit = """[Unit]
Requires=cube-cri-runtime-resource.service cubesandbox-shim-watchdog.service
After=cube-cri-runtime-resource.service cubesandbox-shim-watchdog.service
[Service]
ExecStart=
ExecStart=""" + " ".join(map(unit_arg, final_args)) + """
Environment=CUBE_RUNTIME_RESOURCE_ENDPOINT=/run/cube-cri/runtime-resource.sock
Environment=CUBE_RUNTIME_RESOURCE_REAPER_DIR=/data/cubelet/runtime-resource-reaper
Environment=CUBE_CRI_METRICS_SOCKET=/run/cube-cri/metrics.sock
Environment=CUBE_VMM_WORKER_PATH=/opt/cube-cri/current/bin/cube-vmm-worker
"""
    unit += "Environment=ENABLE_CRI_SANDBOXES=1\nEnvironment=CUBE_ALLOW_PRIVILEGED=true\n" if major == "1.7" else "UnsetEnvironment=ENABLE_CRI_SANDBOXES\n"
    (output / "containerd.service.conf").write_text(unit)
    metadata = {"binary": binary, "version": version, "family": major, "source_config": str(source), "exec_argv": final_args,
                "address": option(args, ("--address", "-a"), parsed.get("grpc", {}).get("address", "/run/containerd/containerd.sock"))}
    (output / "containerd.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(f"复用节点 containerd: {version}; binary={binary}; config={source}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--pid", type=int, help="测试隔离实例；默认使用 containerd.service MainPID")
    parser.add_argument("--config-path", type=pathlib.Path)
    options = parser.parse_args()
    pid = options.pid or int(command("systemctl", "show", "containerd", "--property=MainPID", "--value"))
    if pid <= 0:
        parser.error("节点 containerd.service 未运行")
    prepare(pid, options.output, options.config_path or options.output / "containerd.toml")
