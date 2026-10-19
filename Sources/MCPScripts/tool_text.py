"""MCP tool parameter descriptions — thin alias over the shared catalog.

Keys stay `param.<semantic>` at the call site and resolve to `mcp.param.<semantic>` in the
catalog. `server.py` keeps calling `param_text(...)`, so the schema cannot silently grow a
bare description literal.
"""

from __future__ import annotations

from l10n import MissingText, t

#: Backwards-compatible name for importers that catch the old exception.
MissingParamText = MissingText


def param_text(key: str) -> str:
    return t(f"mcp.{key}")
