#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Entry shim; the implementation lives in `utility.cli.minod`."""

import sys

from utility.cli.minod import main

if __name__ == "__main__":
    sys.exit(main())
