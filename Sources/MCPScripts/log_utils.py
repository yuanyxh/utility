"""所有 Python 子进程共享的日志模块。
使用方式：
    from log_utils import setup_logging, write_error_log
    logger = setup_logging("server")       # → ~/.cache/utility/server.log
    logger = setup_logging("token_proxy", json_format=True)  # → JSON Lines
"""

import json
import logging
import logging.handlers
import os
from datetime import datetime, timezone

_CACHE_BASE = os.path.expanduser("~/.cache/utility")


def setup_logging(name: str, level=logging.INFO, json_format=False):
    os.makedirs(_CACHE_BASE, exist_ok=True)

    root = logging.getLogger(name)
    root.setLevel(level)
    if root.handlers:
        return root

    log_path = os.path.join(_CACHE_BASE, f"{name}.log")
    fh = logging.handlers.TimedRotatingFileHandler(
        filename=log_path,
        when="midnight",
        interval=1,
        backupCount=30,
        encoding="utf-8",
    )

    if json_format:
        fh.setFormatter(logging.Formatter("%(message)s"))
    else:
        fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))

    root.addHandler(fh)

    # 静默第三方库，避免噪音
    for lib in ("httpx", "httpcore", "uvicorn.access", "uvicorn.error"):
        logging.getLogger(lib).setLevel(logging.WARNING)

    return root


def write_error_log(log_path: str, entry: dict):
    entry["timestamp"] = datetime.now(timezone.utc).isoformat()
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
