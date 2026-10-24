#!/usr/bin/env python3
"""Entry shim; the implementation lives in `scripts/router_contract/`.

Groups: consts (paths/constants) -> parsers -> proxy_checks / env_checks /
content_checks -> inputs -> main.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from router_contract.main import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
