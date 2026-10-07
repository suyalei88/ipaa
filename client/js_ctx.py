#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 JS bundle 里找关键词上下文（minified JS 一行到底，用窗口切片看）"""
import re
import sys

path = sys.argv[1]
pat = sys.argv[2]
win = int(sys.argv[3]) if len(sys.argv) > 3 else 400

data = open(path, "r", encoding="utf-8", errors="ignore").read()
rx = re.compile(pat)
seen = set()
n = 0
for m in rx.finditer(data):
    s = max(0, m.start() - win)
    e = min(len(data), m.end() + win)
    chunk = data[s:e]
    key = chunk[:80]
    if key in seen:
        continue
    seen.add(key)
    n += 1
    print(f"\n===== match {n} @ {m.start()} =====")
    print(chunk)
    if n >= 25:
        break
print(f"\n[total shown: {n}]")
