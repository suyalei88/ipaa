#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pack_source.py —— 把「打包 IPA 需要的那部分」压成一个 zip

排除掉 270MB 的 APK / 175MB 的 IPA / 抓包 HAR / 登录态，
产出一个可以直接拷到 Mac 或推到 GitHub 的干净压缩包。

    python ios/tools/pack_source.py
    → dist/leapmotor-lite-ios-src.zip
"""
from __future__ import annotations

import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT_DIR = os.path.join(ROOT, "dist")
OUT = os.path.join(OUT_DIR, "leapmotor-lite-ios-src.zip")

# 不打包的目录（相对 ROOT 的前缀）
EXCLUDE_DIRS = (
    ".git", "dist", "node_modules", "__pycache__",
    "ios/LeapmotorLite/build",
    "evidence/unpack", "evidence/unpack_ios",
)

# 不打包的文件（后缀）
EXCLUDE_EXT = (".apk", ".ipa", ".har", ".pyc", ".zip", ".dSYM")

# 不打包的具体文件
EXCLUDE_FILES = ("evidence/session.json",)


def included(rel: str) -> bool:
    rel = rel.replace("\\", "/")
    for d in EXCLUDE_DIRS:
        if rel == d or rel.startswith(d + "/"):
            return False
    if rel in EXCLUDE_FILES or os.path.basename(rel) in EXCLUDE_FILES:
        return False
    if rel.endswith(EXCLUDE_EXT):
        return False
    return True


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    n = 0
    total = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for dirpath, dirnames, filenames in os.walk(ROOT):
            dirnames[:] = [
                d for d in dirnames
                if included(os.path.relpath(os.path.join(dirpath, d), ROOT))
            ]
            for f in sorted(filenames):
                full = os.path.join(dirpath, f)
                rel = os.path.relpath(full, ROOT)
                if not included(rel):
                    continue
                arc = os.path.join("leapmotor-thirdparty", rel.replace("\\", "/"))
                z.write(full, arc)
                n += 1
                total += os.path.getsize(full)

    size = os.path.getsize(OUT)
    print(f"{n} 个文件，原始 {total/1048576:.1f} MB → 压缩 {size/1048576:.1f} MB")
    print("→", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
