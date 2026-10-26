"""Standalone entry for the Python services (`minod`).

P1 ships the self-check only. Starting the services from here needs the env
derivation that still lives in the Swift host; that move is planned for P3.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import threading
from pathlib import Path

from utility.cli import env_builder
from utility.core import config_loader, daemon, ports

MIN_PYTHON = (3, 12)

#: service -> (config key for an explicit port, default start port)
SERVICE_PORTS = {
    daemon.SERVICE_MCP: ("mcp.port", 9001),
    daemon.SERVICE_PROXY: ("modelProxy.port", 8613),
}


def _report(passed: bool, message: str) -> bool:
    print(f"  {'ok  ' if passed else 'FAIL'}  {message}")
    return passed


def _config_parses(path) -> tuple[bool, str]:
    try:
        import yaml
    except ImportError:
        return False, "PyYAML is not installed"
    try:
        yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        return False, f"config parse error: {exc}"
    return True, f"config parses: {path}"


def check() -> int:
    """Report whether a standalone run has everything it needs."""
    ok = True
    root = os.environ.get("UTILITY_DATA_DIR", "").strip()
    ok = (
        _report(bool(root), f"config root: {root or 'UTILITY_DATA_DIR not set'}") and ok
    )

    path = config_loader.config_file()
    exists = path is not None and path.is_file()
    ok = _report(exists, f"config file: {path or 'unresolved'}") and ok
    if exists:
        parsed, message = _config_parses(path)
        ok = _report(parsed, message) and ok

    version = ".".join(str(part) for part in sys.version_info[:3])
    ok = (
        _report(sys.version_info[:2] >= MIN_PYTHON, f"python {version} (need >= 3.12)")
        and ok
    )
    ok = _report(daemon.state_dir() is not None, "runtime state dir resolvable") and ok

    for service in SERVICE_PORTS:
        port = _resolve_port(service)
        online = not ports.is_available(port) and daemon.health_ok(
            f"http://127.0.0.1:{port}/health", timeout=0.5
        )
        ok = (
            _report(
                ports.is_available(port) or online,
                f"{service} port {port} free or healthy",
            )
            and ok
        )

    print(f"[minod] check {'passed' if ok else 'failed'}")
    return 0 if ok else 1


SERVICE_SCRIPTS = {
    daemon.SERVICE_MCP: "server.py",
    daemon.SERVICE_PROXY: "token_proxy.py",
}
HEALTH_TIMEOUT = 90.0


def _health_url(port: int) -> str:
    return f"http://127.0.0.1:{port}/health"


def _alive(pid: object) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _resolve_port(service: str) -> int:
    """Explicit config → recorded healthy service → first free port."""
    key, base = SERVICE_PORTS[service]
    configured = config_loader.value(key, 0)
    if isinstance(configured, int) and configured > 0:
        return configured
    state = daemon.read_state(service)
    if state:
        port, pid = state.get("port"), state.get("pid")
        if isinstance(port, int) and _alive(pid):
            if daemon.health_ok(_health_url(port), timeout=0.5):
                return port
    return ports.find_available(base)


def _environment(service: str, port: int) -> dict[str, str]:
    env = dict(os.environ)
    if service == daemon.SERVICE_MCP:
        env.update(env_builder.mcp_environment(port))
    else:
        env.update(env_builder.proxy_environment(port))
    env.setdefault("PYTHONUNBUFFERED", "1")
    env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    return env


def _shutdown(children: dict[str, subprocess.Popen]) -> None:
    for proc in children.values():
        if proc.poll() is None:
            proc.terminate()
    for proc in children.values():
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    for service in children:
        daemon.clear_state(service)


def serve(services: list[str], scripts_dir: Path) -> int:
    """Start the requested services, record their ports, stop them together."""
    stop = threading.Event()
    daemon.install_stop_handlers(stop)
    children: dict[str, subprocess.Popen] = {}
    try:
        for service in services:
            script = scripts_dir / SERVICE_SCRIPTS[service]
            if not script.is_file():
                print(f"[minod] missing script: {script}")
                return 1
            port = _resolve_port(service)
            if not ports.is_available(port):
                print(f"[minod] {service}: port {port} is already in use")
                return 1
            proc = subprocess.Popen(
                [sys.executable, str(script)], env=_environment(service, port)
            )
            children[service] = proc
            daemon.write_state(service, port, pid=proc.pid)
            print(f"[minod] {service} starting on {port} (pid {proc.pid})")

        for service, proc in children.items():
            state = daemon.read_state(service) or {}
            port = int(state.get("port", 0))
            if daemon.wait_until(
                lambda p=port: daemon.health_ok(_health_url(p)), HEALTH_TIMEOUT
            ):
                print(f"[minod] {service} healthy")
            else:
                print(f"[minod] {service} failed health check")
                return 1

        while not stop.is_set():
            if any(proc.poll() is not None for proc in children.values()):
                print("[minod] a service exited, shutting down")
                break
            stop.wait(0.5)
        return 0
    finally:
        _shutdown(children)


def main(argv: list[str] | None = None, scripts_dir: Path | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="minod", description="Utility Python services"
    )
    parser.add_argument(
        "--check", action="store_true", help="verify the standalone environment"
    )
    parser.add_argument(
        "--serve", action="store_true", help="start the enabled services"
    )
    parser.add_argument("--service", choices=("mcp", "proxy", "all"), default="all")
    args = parser.parse_args(argv)

    if args.check:
        return check()
    if not args.serve:
        parser.print_help()
        return 2

    requested = list(SERVICE_SCRIPTS) if args.service == "all" else [args.service]
    enabled = {
        daemon.SERVICE_MCP: env_builder.mcp_enabled(),
        daemon.SERVICE_PROXY: env_builder.proxy_enabled(),
    }
    selected = [service for service in requested if enabled[service]]
    if not selected:
        print(
            "[minod] nothing to serve: mcp.enabled and modelProxy.enabled are both off"
        )
        return 1
    root = scripts_dir or Path(__file__).resolve().parents[2]
    return serve(selected, root)
