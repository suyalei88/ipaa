#!/usr/bin/env python3
"""iOS ObjC metadata explorer using lief.

Usage:
    python client/ios_objc.py <macho> --list-classes [--grep PAT]
    python client/ios_objc.py <macho> --class NAME
    python client/ios_objc.py <macho> --method SEL
    python client/ios_objc.py <macho> --grep-str TEXT
"""
from __future__ import annotations

import argparse
import re
import sys

import lief


def load(path: str):
    fat = lief.MachO.parse(path)
    # FatBinary or Binary
    try:
        bins = [fat.at(i) for i in range(fat.size)]
    except Exception:
        bins = [fat]
    return bins


def get_classes(bin_) -> list:
    for attr in ("objc_classes", "objcClasses"):
        if hasattr(bin_, attr):
            try:
                return list(getattr(bin_, attr))
            except Exception:
                pass
    return []


def cls_name(c) -> str:
    for attr in ("name", "mangled_name"):
        v = getattr(c, attr, None)
        if v:
            return str(v)
    return "?"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("macho")
    ap.add_argument("--list-classes", action="store_true")
    ap.add_argument("--grep")
    ap.add_argument("--class", dest="cls")
    ap.add_argument("--method")
    ap.add_argument("--grep-str")
    args = ap.parse_args()

    bins = load(args.macho)
    print(f"[*] {len(bins)} slice(s)", file=sys.stderr)
    b = bins[0]
    print(f"[*] binary: {b.header.cpu_type} {b.header.file_type}", file=sys.stderr)

    classes = get_classes(b)
    print(f"[*] objc classes: {len(classes)}", file=sys.stderr)

    if args.list_classes or args.grep:
        pat = re.compile(args.grep, re.I) if args.grep else None
        n = 0
        for c in classes:
            nm = cls_name(c)
            if pat is None or pat.search(nm):
                n += 1
                sup = getattr(c, "superclass", None)
                supn = ""
                if sup is not None:
                    supn = f" : {cls_name(sup)}"
                print(f"{nm}{supn}")
        print(f"[*] matched {n}", file=sys.stderr)
        return 0

    if args.cls:
        for c in classes:
            if cls_name(c) == args.cls:
                print(f"=== class {args.cls} ===")
                sup = getattr(c, "superclass", None)
                if sup is not None:
                    print(f"super: {cls_name(sup)}")
                for m in getattr(c, "methods", []):
                    nm = getattr(m, "name", "?")
                    ty = getattr(m, "mangled_type", getattr(m, "type", ""))
                    print(f"  -[{nm}]  {ty}")
                for p in getattr(c, "properties", []):
                    print(f"  prop: {getattr(p,'name','?')}")
                return 0
        print(f"class {args.cls} not found")
        return 1

    if args.method:
        for c in classes:
            for m in getattr(c, "methods", []):
                if getattr(m, "name", "") == args.method:
                    print(f"{cls_name(c)}  -[{args.method}]")
        return 0

    if args.grep_str:
        needle = args.grep_str.encode()
        secs = {}
        for s in b.sections:
            try:
                secs[f"{s.segment_name}/{s.name}"] = bytes(s.content)
            except Exception:
                pass
        for k, v in secs.items():
            off = v.find(needle)
            if off != -1:
                print(f"{k}: found at section offset 0x{off:x}")
                i = 0
                while True:
                    j = v.find(needle, i)
                    if j == -1:
                        break
                    ctx = v[max(0, j - 40): j + 80]
                    txt = "".join(chr(ch) if 32 <= ch < 127 else "." for ch in ctx)
                    print(f"   0x{j:x}: {txt}")
                    i = j + 1
        return 0

    ap.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
