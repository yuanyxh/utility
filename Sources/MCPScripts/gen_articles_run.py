#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Gen_Articles 内置入口；由 TaskScheduler 手动任务调用。"""

from gen_articles.production import main

if __name__ == "__main__":
    raise SystemExit(main())
