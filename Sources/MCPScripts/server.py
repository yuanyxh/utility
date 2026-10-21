#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Entry shim; the implementation lives in `utility.services.mcp.server`."""

import asyncio

from utility.services.mcp.server import main

if __name__ == "__main__":
    asyncio.run(main())
