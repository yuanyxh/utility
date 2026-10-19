"""Behavioural tests for the token-proxy forwarding pipeline.

These run fully offline: a fake aiohttp upstream stands in for the provider, and
`token_proxy.PROVIDERS` is pointed at its port. They pin the invariants that
were repeatedly broken in production (injection position, note stripping,
protocol conversion, retry) so the upcoming `handle_proxy` split has a
regression gate.
"""

from __future__ import annotations

import asyncio
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="utility-proxy-test-")
os.environ["UTILITY_DATA_DIR"] = _TMP

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Sources" / "MCPScripts"))

from aiohttp import web  # noqa: E402
from aiohttp.test_utils import TestClient, TestServer  # noqa: E402

import proxy_protocol  # noqa: E402
import proxy_response_note  # noqa: E402
import proxy_usage  # noqa: E402
import token_proxy  # noqa: E402


class _FakeUpstream:
    """Records every request and replays queued responses."""

    def __init__(self) -> None:
        self.requests: list[dict] = []
        self._responses: list[tuple[int, bytes, str]] = []

    def enqueue_json(self, payload: dict, status: int = 200) -> None:
        self._responses.append((status, json.dumps(payload).encode(), "application/json"))

    def enqueue_sse(self, text: str, status: int = 200) -> None:
        self._responses.append((status, text.encode(), "text/event-stream"))

    def enqueue_empty(self, status: int) -> None:
        self._responses.append((status, b"", "application/json"))

    async def handle(self, request: web.Request) -> web.Response:
        raw = await request.read()
        self.requests.append(
            {
                "path": request.path,
                "headers": dict(request.headers),
                "body": json.loads(raw) if raw else None,
            }
        )
        if not self._responses:
            return web.Response(status=500, text="no queued response")
        status, body, content_type = self._responses.pop(0)
        return web.Response(status=status, body=body, content_type=content_type)


class ProxyTestBase(unittest.IsolatedAsyncioTestCase):
    provider_format = "openai"

    async def asyncSetUp(self) -> None:
        self.upstream = _FakeUpstream()
        upstream_app = web.Application()
        upstream_app.router.add_route("*", "/{path:.*}", self.upstream.handle)
        self.upstream_server = TestServer(upstream_app)
        await self.upstream_server.start_server()

        token_proxy.PROVIDERS = [
            {
                "name": "fake",
                "url": f"http://127.0.0.1:{self.upstream_server.port}",
                "apiFormat": self.provider_format,
                "apiKey": "",
                "models": ["test-model"],
            }
        ]
        token_proxy.UPSTREAM_URL = ""
        token_proxy.SKILL_DEDUP_ENABLED = False
        token_proxy.RESPONSE_NOTE_ENABLED = False
        token_proxy._logged_first_body = True

        self.proxy = TestClient(TestServer(token_proxy.create_app()))
        await self.proxy.start_server()
        proxy_usage.init_db()
        proxy_usage.init_tool_output_db()

    async def asyncTearDown(self) -> None:
        await self.proxy.close()
        await self.upstream_server.close()

    async def _wait_for_usage(self, expected: int, timeout: float = 2.0) -> int:
        deadline = asyncio.get_running_loop().time() + timeout
        count = 0
        while asyncio.get_running_loop().time() < deadline:
            with sqlite3.connect(proxy_usage.DB_PATH) as conn:
                count = conn.execute("SELECT COUNT(*) FROM api_usage").fetchone()[0]
            if count >= expected:
                return count
            await asyncio.sleep(0.05)
        return count


class PassthroughTests(ProxyTestBase):
    provider_format = "openai"

    async def test_json_passthrough_and_usage_recorded(self) -> None:
        self.upstream.enqueue_json(
            {
                "id": "chatcmpl-1",
                "model": "test-model",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "hi"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5},
            }
        )
        resp = await self.proxy.post(
            "/v1/chat/completions",
            json={"model": "test-model", "messages": [{"role": "user", "content": "hello"}]},
        )
        self.assertEqual(resp.status, 200)
        self.assertEqual((await resp.json())["id"], "chatcmpl-1")
        self.assertEqual(self.upstream.requests[0]["path"], "/v1/chat/completions")
        self.assertGreaterEqual(await self._wait_for_usage(1), 1)


class ConversionTests(ProxyTestBase):
    provider_format = "openai"

    async def test_anthropic_entry_is_converted_for_openai_upstream(self) -> None:
        self.upstream.enqueue_json(
            {
                "id": "chatcmpl-2",
                "model": "test-model",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "hi"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 4, "completion_tokens": 1, "total_tokens": 5},
            }
        )
        resp = await self.proxy.post(
            "/v1/messages",
            json={
                "model": "test-model",
                "max_tokens": 16,
                "system": "SYS",
                "messages": [{"role": "user", "content": "hello"}],
            },
        )
        self.assertEqual(resp.status, 200)
        upstream_body = self.upstream.requests[0]["body"]
        self.assertEqual(upstream_body["model"], "test-model")
        self.assertNotIn("system", upstream_body)
        self.assertTrue(upstream_body["messages"])
        self.assertNotIn("choices", await resp.json())


class NoteTests(ProxyTestBase):
    provider_format = "anthropic"

    SSE = (
        'event: message_start\ndata: {"type":"message_start","message":{"model":"upstream-model","usage":{"input_tokens":5}}}\n\n'
        'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
        'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}\n\n'
        'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'
        'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n'
        'event: message_stop\ndata: {"type":"message_stop"}\n\n'
    )

    async def test_stream_note_is_appended(self) -> None:
        token_proxy.RESPONSE_NOTE_ENABLED = True
        self.upstream.enqueue_sse(self.SSE)
        resp = await self.proxy.post(
            "/v1/messages",
            json={"model": "test-model", "max_tokens": 16, "messages": [{"role": "user", "content": "hi"}]},
        )
        text = await resp.text()
        self.assertIn("upstream-model", text)
        self.assertIn(proxy_response_note.SEG_JOIN, text)

    async def test_assistant_note_echo_is_stripped_before_upstream(self) -> None:
        token_proxy.RESPONSE_NOTE_ENABLED = True
        note = "upstream-model" + proxy_response_note.SEG_JOIN + next(
            iter(proxy_response_note.NOTE_EMPTY_EXACT)
        )
        self.upstream.enqueue_json(
            {
                "id": "msg_1",
                "type": "message",
                "role": "assistant",
                "model": "test-model",
                "content": [{"type": "text", "text": "ok"}],
                "usage": {"input_tokens": 2, "output_tokens": 1},
            }
        )
        resp = await self.proxy.post(
            "/v1/messages",
            json={
                "model": "test-model",
                "max_tokens": 16,
                "messages": [
                    {"role": "user", "content": "hi"},
                    {"role": "assistant", "content": f"earlier answer\n\n{note}"},
                    {"role": "user", "content": "next"},
                ],
            },
        )
        self.assertEqual(resp.status, 200)
        assistant = self.upstream.requests[0]["body"]["messages"][1]
        self.assertNotIn(proxy_response_note.SEG_JOIN, assistant["content"])


class RetryTests(ProxyTestBase):
    provider_format = "openai"

    async def test_503_is_retried(self) -> None:
        token_proxy.llm_client.DEFAULT_RETRY_503_MAX = 1
        token_proxy.llm_client.DEFAULT_RETRY_503_DELAY = 0
        self.upstream.enqueue_empty(503)
        self.upstream.enqueue_json(
            {
                "id": "ok-after-retry",
                "model": "test-model",
                "choices": [],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
        )
        resp = await self.proxy.post(
            "/v1/chat/completions",
            json={"model": "test-model", "messages": [{"role": "user", "content": "hi"}]},
        )
        self.assertEqual(resp.status, 200)
        self.assertEqual((await resp.json())["id"], "ok-after-retry")
        self.assertEqual(len(self.upstream.requests), 2)


class InjectionPositionTests(unittest.TestCase):
    def test_rule_goes_after_the_last_tool_result(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as fh:
            fh.write("RULE-BODY")
            prompt_path = fh.name

        original_path = proxy_protocol.SYSTEM_PROMPTS_FILE
        try:
            proxy_protocol.SYSTEM_PROMPTS_FILE = prompt_path
            proxy_protocol._sys_prompt_content = None
            proxy_protocol._sys_prompt_mtime = 0
            body = {
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {"type": "tool_result", "tool_use_id": "t1", "content": "result"},
                            {"type": "text", "text": "user follow-up"},
                        ],
                    }
                ]
            }
            _, injected = proxy_protocol._inject_system_prompt(body)
        finally:
            proxy_protocol.SYSTEM_PROMPTS_FILE = original_path
            proxy_protocol._sys_prompt_content = None
            proxy_protocol._sys_prompt_mtime = 0

        self.assertEqual(injected, 1)
        blocks = body["messages"][0]["content"]
        self.assertEqual([block["type"] for block in blocks], ["tool_result", "text", "text"])
        self.assertIn("RULE-BODY", blocks[1]["text"])
        self.assertEqual(blocks[2]["text"], "user follow-up")


if __name__ == "__main__":
    unittest.main()
