#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 dex/so 里提取可打印字符串（替代 strings 命令），并按关键词过滤。"""
import re
import sys

PRINTABLE = re.compile(rb"[\x20-\x7e]{6,}")


def strings(path, minlen=6):
    data = open(path, "rb").read()
    for m in re.finditer(rb"[\x20-\x7e]{%d,}" % minlen, data):
        yield m.group().decode("ascii", errors="ignore")


def main():
    path = sys.argv[1]
    pat = sys.argv[2] if len(sys.argv) > 2 else None
    rx = re.compile(pat, re.I) if pat else None
    seen = set()
    for s in strings(path):
        if s in seen:
            continue
        seen.add(s)
        if rx is None or rx.search(s):
            print(s)


if __name__ == "__main__":
    main()
