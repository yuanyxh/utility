"""统一 SQLite 连接工具。

收敛 token_proxy / proxy_usage / server_search / server 散落的
`sqlite3.connect(...)` 样板为 `with conn(db_path) as c:`，
自动提交 + 异常回滚 + 自动关闭，避免连接泄漏与重复样板。
"""

from __future__ import annotations

import sqlite3
from collections.abc import Generator
from contextlib import contextmanager


@contextmanager
def conn(
    db_path: str, *, timeout: float = 5.0
) -> Generator[sqlite3.Connection, None, None]:
    """SQLite 连接上下文管理器。

    正常退出自动 commit，异常自动 rollback，无论如何关闭连接。

    用法::

        with conn(DB_PATH) as c:
            c.execute("INSERT INTO t (a) VALUES (?)", (1,))
    """
    connection = sqlite3.connect(db_path, timeout=timeout)
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
