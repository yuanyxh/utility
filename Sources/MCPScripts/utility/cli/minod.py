"""Standalone entry for the Python services (`minod`).

P1 ships the self-check only. Starting the services from here needs the env
derivation that still lives in the Swift host; that move is planned for P3.
"""

from __future__ import annotations

import argparse
import os
import sys

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


def _resolve_port(key: str, base: int) -> int:
    configured = config_loader.value(key, 0)
    if isinstance(configured, int) and configured > 0:
        return configured
    return base


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

    for service, (key, base) in SERVICE_PORTS.items():
        port = _resolve_port(key, base)
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="minod", description="Utility Python services"
    )
    parser.add_argument(
        "--check", action="store_true", help="verify the standalone environment"
    )
    args = parser.parse_args(argv)
    if args.check:
        return check()
    parser.print_help()
    return 2
