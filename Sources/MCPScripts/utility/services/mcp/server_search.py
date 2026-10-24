"""Project dependency-graph query + note semantic search (facade).

Implementation lives in search_constants / search_symbols / search_vectors /
search_notes_io / search_notes_cache / search_notes_query / project_tools /
project_dependencies. This module only re-exports the public surface.
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
import threading

import numpy as np

from utility.core.db import conn as dbconn
from utility.core.log_utils import setup_logging
from utility.core.synonyms import load_synonyms
from utility.core.tool_defaults import arg_default
from utility.services.mcp.server_embed import _get_shared_embedder, embed_query

from utility.services.mcp.search_constants import (
    DEFAULT_PROJECT_DEPENDENCIES_DIRECTION,
    DEFAULT_PROJECT_DEPENDENCIES_LIMIT,
    DEFAULT_PROJECT_SEARCH_LIMIT,
    DEFAULT_PROJECT_STRUCTURE_LIMIT,
)
from utility.services.mcp.project_dependencies import tool_project_dependencies
from utility.services.mcp.project_tools import (
    tool_project_exports,
    tool_project_search,
    tool_project_structure,
)
from utility.services.mcp.search_constants import _symbol_embeddings
from utility.services.mcp.search_notes_cache import _ensure_note_cache
from utility.services.mcp.search_notes_query import _query_project_notes
from utility.services.mcp.search_vectors import (
    _ensure_symbol_embeddings,
    _get_shared_embedder,
    _search_vectors,
)
