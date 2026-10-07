#!/usr/bin/env python3
"""CFString-aware cross reference finder for the decrypted Leapmotor iOS binary.

For an ObjC string literal, clang emits:
    __cstring  "<text>\\0"
    __const/__cfstring   __CFConstantString { isa, flags, charPtr, len }
    __text     adrp xN, cfobj@page ; add xN, xN, #off   (or ldr for globals)

Naive ADRP+ADD scanning of the raw cstring finds nothing because the code points
at the __CFConstantString object, not at the bytes.  This tool bridges that gap.

Usage:
    python client/ios_cfref.py <macho> --cstr "/app-user/applogin/check_login_with_phone"
    python client/ios_cfref.py <macho> --cstr "Des" --selref
"""
from __future__ import annotations

import argparse
import sys

import numpy as np

from macho_util import Image

TEXT_SEC = ("__TEXT", "__text")
CONST_HINT = ("__const", "__cfstring", "__objc_const")


class CfRef:
    def __init__(self, path: str):
        self.im = Image(path)
        va, c = self.im.sections[TEXT_SEC]
        self.text_va = va
        arr = np.frombuffer(c, dtype="<u4").astype(np.uint64)
        self.n = len(arr)
        self.arr = arr
        self._index()

    def _index(self):
        arr = self.arr
        n = self.n
        idx = np.nonzero((arr & 0x9F000000) == 0x90000000)[0]
        immlo = ((arr[idx] >> 29) & 3).astype(np.int64)
        immhi = ((arr[idx] >> 5) & 0x7FFFF).astype(np.int64)
        imm = (immhi << 2) | immlo
        imm = np.where(imm >= (1 << 20), imm - (1 << 21), imm)
        page = ((self.text_va + idx.astype(np.int64) * 4) & ~0xFFF) + (imm << 12)
        rd = (arr[idx] & 0x1F).astype(np.int64)
        self.is_adrp = np.zeros(n, dtype=bool)
        self.is_adrp[idx] = True
        self.adrp_page = np.zeros(n, dtype=np.int64)
        self.adrp_page[idx] = page
        self.adrp_rd = np.zeros(n, dtype=np.int64)
        self.adrp_rd[idx] = rd
        self.refs: dict[int, list[int]] = {}
        # ADD imm (unshifted) and LDR imm (<<3)
        for mask, val, shift in ((0xFF800000, 0x91000000, 0),
                                 (0xFFC00000, 0xF9400000, 3)):
            ii = np.nonzero((arr & mask) == val)[0]
            a = arr[ii].astype(np.int64)
            rn = (a >> 5) & 0x1F
            imm12 = (a >> 10) & 0xFFF
            disp = imm12 << shift
            for off in range(1, 7):
                j = ii - off
                m = j >= 0
                if not m.any():
                    continue
                jj = j[m]
                sel = self.is_adrp[jj] & (self.adrp_rd[jj] == rn[m])
                if not sel.any():
                    continue
                jj2 = jj[sel]
                tgt = self.adrp_page[jj2] + disp[m][sel]
                addrs = ii[m][sel]
                for aa, tt in zip(addrs.tolist(), tgt.tolist()):
                    self.refs.setdefault(tt, []).append(self.text_va + aa * 4)

    # ---- cstring helpers -------------------------------------------
    def cstr_addrs(self, s: str):
        out = []
        for (sg, nm), (va, c) in self.im.sections.items():
            if nm not in ("__cstring", "__objc_methname"):
                continue
            i = c.find(s.encode())
            while i != -1:
                if i == 0 or c[i - 1] == 0:
                    out.append(va + i)
                i = c.find(s.encode(), i + 1)
        return out

    def cf_objects(self, cstr_addr: int):
        """__CFConstantString objects whose charPtr == cstr_addr (obj = slot - 0x10)."""
        out = []
        for (sg, nm), (va, c) in self.im.sections.items():
            if not any(h in nm for h in CONST_HINT):
                continue
            for off in range(0, len(c) - 8, 8):
                if self.im.deref(va + off) == cstr_addr:
                    out.append(va + off - 0x10)
        return out

    def selref_slots(self, target: int):
        out = []
        for (sg, nm), (va, c) in self.im.sections.items():
            if "selref" not in nm:
                continue
            for off in range(0, len(c) - 8, 8):
                if self.im.deref(va + off) == target:
                    out.append(va + off)
        return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("macho")
    ap.add_argument("--cstr")
    ap.add_argument("--addr", action="append", type=lambda x: int(x, 0), default=[])
    ap.add_argument("--selref", action="store_true", help="also look in __objc_selrefs")
    ap.add_argument("--dis", type=int, default=0)
    args = ap.parse_args()

    x = CfRef(args.macho)
    targets = list(args.addr)
    if args.cstr:
        targets += x.cstr_addrs(args.cstr)

    for t in targets:
        print(f"\n=== 0x{t:x}  cstr={x.im.cstr(t)!r}")
        objs = x.cf_objects(t)
        print(f"    cf-objects: {[hex(o) for o in objs]}")
        sites = list(x.refs.get(t, []))
        for o in objs:
            sites += x.refs.get(o, [])
        if args.selref:
            slots = x.selref_slots(t)
            print(f"    selrefs: {[hex(s) for s in slots]}")
            for s in slots:
                sites += x.refs.get(s, [])
        sites = sorted(set(sites))
        print(f"    code refs ({len(sites)}):")
        for a in sites:
            print(f"       0x{a:x}")
            if args.dis:
                start = a - 4 * (args.dis // 2)
                for ins in x.im.disasm(start, args.dis, stop_at_ret=False):
                    mark = " <==" if ins.address == a else ""
                    from macho_util import fmt
                    print("           " + fmt(ins) + mark)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
