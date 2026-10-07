#!/usr/bin/env python3
"""Locate an ObjC method by selector, regardless of where its list lives.

The class walk only reaches `class_ro_t.baseMethods` (instance methods of
non-meta classes).  Class methods live in the metaclass ro, and categories in
`__objc_catlist`.  Rather than modelling all of that, we use the fact that a
relative method list stores `name` as `selref_addr - field_addr`, so we can
reverse-scan `__objc_methlist` for the exact int32 and find the record.

Usage:
    python client/ios_sel.py <macho> --sel 'xorThreeData:data2:data3:'
    python client/ios_sel.py <macho> --list-selrefs 20
"""
from __future__ import annotations

import argparse
import struct
import sys

from macho_util import Image


class SelFinder:
    def __init__(self, path: str):
        self.im = Image(path)
        self._selrefs: dict[str, list[int]] | None = None

    # --- selref table ------------------------------------------------
    def selrefs(self) -> dict[str, list[int]]:
        if self._selrefs is not None:
            return self._selrefs
        d: dict[str, list[int]] = {}
        for sec in (("__DATA", "__objc_selrefs"), ("__DATA_CONST", "__objc_selrefs")):
            if sec not in self.im.sections:
                continue
            va, c = self.im.sections[sec]
            for i in range(len(c) // 8):
                slot = va + i * 8
                s = self.im.cstr(self.im.deref(slot))
                if s:
                    d.setdefault(s, []).append(slot)
        self._selrefs = d
        return d

    # --- reverse method lookup ---------------------------------------
    def find_method(self, sel: str):
        srs = self.selrefs().get(sel, [])
        out = []
        for sr in srs:
            for sec in (("__TEXT", "__objc_methlist"), ("__DATA", "__objc_const")):
                if sec not in self.im.sections:
                    continue
                va, c = self.im.sections[sec]
                if sec[1] == "__objc_methlist":
                    for off in range(0, len(c) - 4, 4):
                        f = va + off
                        v = struct.unpack_from("<i", c, off)[0]
                        if f + v == sr:
                            out.append(self._read_record(f))
                else:
                    for off in range(0, len(c) - 8, 8):
                        if struct.unpack_from("<Q", c, off)[0] == sr:
                            out.append(self._read_record_abs(va + off))
        return out

    def _read_record(self, f: int):
        no = self.im.i32(f)
        to = self.im.i32(f + 4)
        io = self.im.i32(f + 8)
        nm = self.im.cstr(self.im.deref(f + no))
        ty = self.im.cstr(f + 4 + to)
        imp = f + 8 + (io & ~1)
        return {"record": f, "sel": nm, "types": ty, "imp": imp}

    def _read_record_abs(self, f: int):
        nm = self.im.cstr(self.im.deref(f))
        ty = self.im.cstr(self.im.deref(f + 8))
        imp = self.im.deref(f + 16)
        return {"record": f, "sel": nm, "types": ty, "imp": imp}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("macho")
    ap.add_argument("--sel")
    ap.add_argument("--list-selrefs", type=int, default=0)
    args = ap.parse_args()

    f = SelFinder(args.macho)
    if args.list_selrefs:
        sr = f.selrefs()
        print(f"total selrefs: {len(sr)}")
        for i, (k, v) in enumerate(list(sr.items())[: args.list_selrefs]):
            print(f"  {k}  @ {[hex(x) for x in v]}")
        return 0
    if args.sel:
        res = f.find_method(args.sel)
        print(f"[{args.sel}] {len(res)} record(s)")
        for r in res:
            print(f"  record=0x{r['record']:x}  types={r['types']}  imp=0x{r['imp']:x}")
        return 0
    ap.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
