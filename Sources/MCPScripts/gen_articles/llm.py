#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Thin adapter over the project's single LLM exit (`llm_client`).

Gen_Articles only adds typed errors and a retry policy for empty/truncated
responses; transport, auth, timeout and thinking injection stay shared.
"""

from __future__ import annotations

import time

from llm_client import (
    API_ANTHROPIC,
    LLMClientError,
    LLMTarget,
    chat as _chat,
    default_target,
)


class LLMError(RuntimeError):
    def __init__(self, message: str, *, kind: str = "error",
                 finish_reason: str | None = None):
        super().__init__(message)
        self.kind = kind
        self.finish_reason = finish_reason


class LLMClient:
    def __init__(self, target: LLMTarget | None = None,
                 timeout: float | None = None):
        self.target = target
        self.timeout = timeout

    @property
    def model(self) -> str:
        return (self.target or default_target()).model

    def chat(
        self,
        prompt: str,
        *,
        system: str | None = None,
        temperature: float = 0.7,
        max_tokens: int = 8192,
        retry: int = 1,
        disable_thinking: bool = False,
    ) -> str:
        target = self.target or default_target()
        extra = (
            {"thinking": {"type": "disabled"}}
            if disable_thinking and target.api_format != API_ANTHROPIC
            else None
        )
        for attempt in range(retry + 1):
            try:
                text = _chat(
                    prompt,
                    system=system,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    timeout=self.timeout,
                    disable_thinking=disable_thinking,
                    extra_body=extra,
                    target=self.target,
                    label="gen_articles",
                    retry_503=retry,
                    raise_on_error=True,
                )
            except LLMClientError as exc:
                if exc.kind == "network" and attempt < retry:
                    time.sleep(1.5)
                    continue
                raise LLMError(
                    str(exc), kind=exc.kind,
                    finish_reason=exc.finish_reason,
                ) from exc
            if text is None:
                raise LLMError("LLM returned no content", kind="empty")
            return text
        raise LLMError("unreachable")


def chat_with_retry(client: LLMClient, user: str, system: str,
                    temperature: float, max_tokens: int,
                    disable_thinking: bool) -> str:
    """Retry only empty/truncated responses, doubling the token budget."""
    tokens = max_tokens
    while True:
        try:
            return client.chat(
                user, system=system, temperature=temperature,
                max_tokens=tokens, disable_thinking=disable_thinking,
            )
        except LLMError as exc:
            if exc.kind not in ("empty", "truncated") or tokens >= 32768:
                raise
            tokens = min(32768, tokens * 2)
