#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Gen_Articles artifact text follows the active language pack."""

from __future__ import annotations

from gen_articles import runtime


def t(key: str, **values) -> str:
    return runtime.pack().text(key, **values)
