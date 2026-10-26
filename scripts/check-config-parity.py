#!/usr/bin/env python3
"""Entry shim; the implementation lives in `scripts/config_parity/`."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from config_parity.main import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
