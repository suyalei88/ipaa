#!/usr/bin/env python3
"""Fast numpy ADRP+ADD / ADRP+LDR cross-reference scanner for arm64 Mach-O.

Unlike macho_util.Image.find_adrp_add_refs (which linearly disassembles the whole
__text with capstone and is unusably slow on a 200 MB binary), this pairs the
ADRP page register with a following ADD/LDR purely by bit-pattern matching,
fully vectorised with numpy.

Usage:
    python client/ios_xref.py <macho> --cstr identifierType
    python client/ios_xref.py <macho> --addr 0x10aa33204 --dis 6
"""
from __future__ import annotations

import argparse

import numpy as np

from macho_util import Image, fmt

ADRP_MASK, ADRP_VAL = 0x9F000000, 0x90000000
ADD64_MASK, ADD64_VAL = 0xFF800000, 0x91000000
LDR64_MASK, LDR64_VAL = 0xFFC00000, 0xF9400000
MAX_BACK = 6            # how far back an ADRP may sit from its ADD/LDR


def find_cstr(im: Image, s: str, secs=("__cstring", "__objc_methname")):
    tgt = s.encode()
    for (sg, nm), (va, c) in im.sections.items():
        if nm not in secs:
            continue
        i = c.find(tgt)
        while i != -1:
            if i == 0 or c[i - 1] == 0:
                yield va + i
            i = c.find(tgt, i + 1)


class Xref:
    def __init__(self, path: str):
        self.im = Image(path)
        va, c = self.im.sections[("__TEXT", "__text")]
        self.text_va = va
        self.arr = np.frombuffer(c, dtype="<u4")
        self.n = len(self.arr)
        a = self.arr.astype(np.uint32)
        self.adrp_idx = np.nonzero((a & np.uint32(ADRP_MASK)) == np.uint32(ADRP_VAL))[0]
        self.add_idx = np.nonzero((a & np.uint32(ADD64_MASK)) == np.uint32(ADD64_VAL))[0]
        self.ldr_idx = np.nonzero((a & np.uint32(LDR64_MASK)) == np.uint32(LDR64_VAL))[0]
        self._build_adrp_tables()

    @staticmethod
    def _adrp_page(insn: np.ndarray, pc: np.ndarray) -> np.ndarray:
        immlo = (insn >> 29) & 3
        immhi = (insn >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        imm = np.where(imm >= (1 << 20), imm - (1 << 21), imm)
        return (pc & ~0xFFF) + (imm << 12)

    def _build_adrp_tables(self):
        ins = self.arr[self.adrp_idx].astype(np.int64)
        pc = self.text_va + self.adrp_idx.astype(np.int64) * 4
        page = self._adrp_page(ins, pc)
        self.is_adrp = np.zeros(self.n, dtype=bool)
        self.is_adrp[self.adrp_idx] = True
        self.adrp_page = np.zeros(self.n, dtype=np.int64)
        self.adrp_page[self.adrp_idx] = page
        self.adrp_rd = np.zeros(self.n, dtype=np.int64)
        self.adrp_rd[self.adrp_idx] = ins & 0x1F

    def refs_to(self, targets):
        """Return {target: [(insn_addr, 'add'|'ldr'), ...]}"""
        want = set(int(t) for t in targets)
        res = {t: [] for t in want}
        for idx, kind in ((self.add_idx, "add"), (self.ldr_idx, "ldr")):
            a = self.arr[idx].astype(np.int64)
            rn = (a >> 5) & 0x1F
            sh = (a >> 22) & 1
            imm12 = (a >> 10) & 0xFFF
            disp = np.where(sh == 1, imm12 << 12, imm12)
            for off in range(1, MAX_BACK + 1):
                j = idx - off
                m = j >= 0
                if not m.any():
                    continue
                jj = j[m]
                sel = self.is_adrp[jj] & (self.adrp_rd[jj] == rn[m])
                if not sel.any():
                    continue
                jj2 = jj[sel]
                tgt = self.adrp_page[jj2] + disp[m][sel]
                addrs = idx[m][sel]
                # keep only targets we care about
                keep = np.isin(tgt, np.fromiter(want, dtype=np.int64, count=len(want)))
                if not keep.any():
                    continue
                for aa, tt in zip(addrs[keep].tolist(), tgt[keep].tolist()):
                    res[tt].append((self.text_va + aa * 4, kind))
        for t in res:
            res[t].sort()
        return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("macho")
    ap.add_argument("--cstr")
    ap.add_argument("--addr", action="append", type=lambda x: int(x, 0), default=[])
    ap.add_argument("--dis", type=int, default=0)
    ap.add_argument("--secs", default="__cstring,__objc_methname")
    args = ap.parse_args()

    targets = list(args.addr)
    if args.cstr:
        im = Image(args.macho)
        got = list(find_cstr(im, args.cstr, tuple(args.secs.split(","))))
        print(f"[cstr {args.cstr!r}] -> {[hex(t) for t in got]}")
        targets += got
    if not targets:
        print("nothing to look up")
        return 1

    xr = Xref(args.macho)
    res = xr.refs_to(targets)
    for t in targets:
        hits = res.get(t, [])
        print(f"\n=== xrefs to {hex(t)}: {len(hits)}")
        for addr, kind in hits:
            print(f"   0x{addr:x}  ({kind})")
            if args.dis:
                start = addr - 4 * (args.dis // 2)
                for ins in xr.im.disasm(start, args.dis, stop_at_ret=False):
                    mark = " <==" if ins.address == addr else ""
                    print("        " + fmt(ins) + mark)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
