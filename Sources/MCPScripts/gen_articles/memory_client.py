#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mino Brain MCP client and memory-row normalization."""

from __future__ import annotations

import json
import re
import urllib.request

from gen_articles import runtime

DEFAULT_ENDPOINT = "http://localhost:9001"


class MinoBrainClient:
    def __init__(self, endpoint: str = DEFAULT_ENDPOINT, timeout: int = 10):
        self.endpoint = endpoint.rstrip("/")
        self.timeout = timeout
        self._id = 0

    def call_tool(self, name: str, arguments: dict) -> dict:
        self._id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": self._id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }
        req = urllib.request.Request(
            self.endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        if "error" in data:
            raise RuntimeError(data["error"])
        content = data["result"]["content"]
        text = next((c["text"] for c in content if c.get("type") == "text"), "{}")
        return json.loads(text)


def _clean_memory(text: str) -> str:
    text = runtime.pack().pattern("memory_tags").sub("", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def recall_hot(endpoint: str, query: str, limit: int) -> list[dict]:
    client = MinoBrainClient(endpoint)
    result = client.call_tool(
        "recall",
        {
            "query": query,
            "limit": max(limit * 2, 10),
            "include_archived": False,
            "layers": ["hot"],
        },
    )
    items = from_memory(result.get("results", []))
    return [item for item in items if item.get("layer") in ("", "hot")]


def from_memory(rows: list[dict]) -> list[dict]:
    out = []
    for row in rows:
        meta = row.get("metadata") or {}
        out.append(
            {
                "kind": "memory",
                "id": row.get("id"),
                "content": _clean_memory(row.get("content", "")),
                "score": row.get("score", 0),
                "tags": meta.get("tags", []),
                "created_at": row.get("created_at", ""),
                "layer": row.get("layer", ""),
            }
        )
    return out
