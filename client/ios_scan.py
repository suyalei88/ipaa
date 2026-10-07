#!/usr/bin/env python3
"""Fast arm64 `bl` cross-reference scanner for the Leapmotor iOS binary.

* Caches the stub / objc_stub / import tables to evidence/ios_misc/symmap.json
  so repeated runs don't re-disassemble 42k trampolines.
* Scans __text for `bl` instructions with a vectorised numpy pass (millions of
  instructions in well under a second).

Usage:
    python client/ios_scan.py <macho> --sel 'setHKDFDeriveKey:'
    python client/ios_scan.py <macho> --sym '_CC_SHA256'
    python client/ios_scan.py <macho> --addr 0x106e832dc
    python client/ios_scan.py <macho> --build          # just refresh the cache
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

from macho_util import Image
from ios_sym import Symbols

CACHE = "evidence/ios_misc/symmap.json"


def build_symmap(path: str, force: bool = False) -> dict:
    if os.path.exists(CACHE) and not force:
        d = json.load(open(CACHE))
        if d.get("_src_size") == os.path.getsize(path):
            return d
    im = Image(path)
    sy = Symbols(im)
    d = {
        "_src_size": os.path.getsize(path),
        "stubs": {hex(k): v for k, v in sy.stubs.items()},
        "objc_stubs": {hex(k): v for k, v in sy.objc_stubs.items()},
        "imports": sy.imports,
        "blob": hex(sy.blob),
    }
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    json.dump(d, open(CACHE, "w"))
    return d


class Scanner:
    def __init__(self, path: str):
        self.im = Image(path)
        d = build_symmap(path)
        self.stubs = {int(k, 16): v for k, v in d["stubs"].items()}
        self.objc_stubs = {int(k, 16): v for k, v in d["objc_stubs"].items()}
        self.imports = d["imports"]
        self._scan()

    def _scan(self):
        va, c = self.im.sections[("__TEXT", "__text")]
        self.text_va = va
        arr = np.frombuffer(c, dtype="<u4")
        mask = (arr & np.uint32(0xFC000000)) == np.uint32(0x94000000)
        idx = np.nonzero(mask)[0]
        imm = (arr[idx] & np.uint32(0x03FFFFFF)).astype(np.int64)
        imm = np.where(imm >= (1 << 25), imm - (1 << 26), imm)
        self.bl_addr = (va + idx.astype(np.int64) * 4).astype(np.int64)
        self.bl_target = (self.bl_addr + imm * 4).astype(np.int64)

    def callers_of(self, target: int):
        sel = (self.bl_target == target)
        return self.bl_addr[sel].tolist()

    def name_of(self, addr: int):
        return self.stubs.get(addr) or (f"objc_msgSend({self.objc_stubs[addr]})"
                                        if addr in self.objc_stubs else None)

    def resolve_selector_stubs(self, sel: str):
        return [a for a, s in self.objc_stubs.items() if s == sel]

    def resolve_symbol_stubs(self, sym: str):
        return [a for a, s in self.stubs.items() if s == sym]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("macho")
    ap.add_argument("--sel")
    ap.add_argument("--sym")
    ap.add_argument("--addr", type=lambda x: int(x, 0))
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    if args.build:
        d = build_symmap(args.macho, force=args.force)
        print(f"cached: stubs={len(d['stubs'])} objc_stubs={len(d['objc_stubs'])} imports={len(d['imports'])}")
        return 0

    sc = Scanner(args.macho)
    targets = []
    if args.sel:
        targets = sc.resolve_selector_stubs(args.sel)
        print(f"[{args.sel}] {len(targets)} trampoline(s): {[hex(t) for t in targets]}")
    elif args.sym:
        targets = sc.resolve_symbol_stubs(args.sym)
        print(f"[{args.sym}] {len(targets)} stub(s): {[hex(t) for t in targets]}")
    elif args.addr:
        targets = [args.addr]

    for t in targets:
        callers = sc.callers_of(t)
        for c in callers:
            print(f"  caller 0x{c:x}   -> {sc.name_of(t) or hex(t)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
