#!/usr/bin/env python3
"""Annotated arm64 disassembler for the decrypted Leapmotor iOS binary.

Resolves:
  * `bl <stub>`            -> imported symbol name or objc_msgSend(<selector>)
  * `adrp/add` string refs -> the cstring
  * `adrp/ldr` global refs -> cstring / ObjC class / selector slot

Usage:
    python client/ios_dis.py <macho> --at 0x1069c009c [--n 200]
    python client/ios_dis.py <macho> --func 0x1069c009c
"""
from __future__ import annotations

import argparse
import sys

from capstone import CS_OP_IMM, CS_OP_MEM

from macho_util import Image, fmt
from ios_sym import Symbols


class Dis:
    def __init__(self, path: str):
        self.im = Image(path)
        self.sy = Symbols(self.im)

    def annotate(self, ins) -> str:
        extra = []
        # bl / b to stub
        if ins.mnemonic in ("bl", "b", "blr") and ins.operands:
            t = ins.operands[0]
            if t.type == CS_OP_IMM:
                nm = self.sy.call_name(t.imm)
                if nm:
                    extra.append(f"-> {nm}")
                else:
                    extra.append(f"-> 0x{t.imm:x}  {self.im.which(t.imm)}")
        # memory / imm refs
        for op in ins.operands:
            if op.type == CS_OP_IMM and ins.mnemonic in ("adrp",):
                continue
            if op.type == CS_OP_MEM and op.mem.base and op.mem.disp == 0:
                pass
        return ("  ; " + " ".join(extra)) if extra else ""

    def dump(self, addr: int, n: int = 120, max_ins: int = 600):
        code = self.im.read(addr, 4 * n)
        if not code:
            print(f"[!] cannot read 0x{addr:x}")
            return
        adrp = {}
        for ins in self.im.md.disasm(code, addr):
            note = []
            if ins.mnemonic == "adrp" and len(ins.operands) == 2:
                adrp[ins.operands[0].reg] = ins.operands[1].imm
            elif ins.mnemonic == "add" and len(ins.operands) >= 3:
                # add Rd, Rn, #imm  ->  the immediate is operands[2], not [1]
                dst = ins.operands[0]
                base = ins.operands[1]
                imm = ins.operands[2]
                if (imm.type == CS_OP_IMM and imm.imm is not None
                        and getattr(base, "reg", None) in adrp):
                    tgt = adrp[base.reg] + imm.imm
                    note.append(f"@{tgt:x} {self.describe(tgt)}")
            elif ins.mnemonic == "ldr" and len(ins.operands) >= 2:
                dst = ins.operands[0]
                src = ins.operands[1]
                if src.type == CS_OP_IMM and src.imm is not None and getattr(dst, "reg", None) in adrp:
                    tgt = adrp[dst.reg] + src.imm
                    note.append(f"@{tgt:x} {self.describe(tgt)}")
                elif src.type == CS_OP_MEM and src.mem.base in adrp:
                    tgt = adrp[src.mem.base] + (src.mem.disp or 0)
                    note.append(f"-> [{tgt:x}] {self.describe(tgt, indirect=True)}")
            if ins.mnemonic in ("bl", "b", "blr") and ins.operands and ins.operands[0].type == CS_OP_IMM:
                t = ins.operands[0].imm
                nm = self.sy.call_name(t)
                note.append(f"-> {nm}" if nm else f"-> 0x{t:x}")
            suffix = ("  ; " + " | ".join(note)) if note else ""
            print(f"0x{ins.address:x}:  {ins.mnemonic:<8} {ins.op_str}{suffix}")
            if ins.mnemonic == "ret":
                break

    def describe(self, vm: int, indirect: bool = False) -> str:
        # ObjC/Swift literals are __CFConstantString objects, not raw cstrings.
        cf = self.cf_string(vm)
        if cf:
            return f'"{cf}"'
        s = self.im.cstr(vm)
        if s and 1 <= len(s) <= 120 and all(32 <= ord(ch) < 127 for ch in s):
            return f'"{s}"'
        v = self.im.deref(vm) if not indirect else None
        if v:
            s2 = self.im.cstr(v)
            if s2 and all(32 <= ord(ch) < 127 for ch in s2) and len(s2) < 120:
                return f'ptr -> "{s2}"'
            cls = self.objc_class_at(v)
            if cls:
                return f"class {cls}"
        cls = self.objc_class_at(vm)
        if cls:
            return f"class {cls}"
        return self.im.which(vm)

    def cf_string(self, vm: int):
        """Resolve a __CFConstantString object { isa, flags, charPtr, len }."""
        ptr = self.im.deref(vm + 16)
        ln = self.im.deref(vm + 24)
        if not ptr or ln is None or not (0 < ln < 300):
            return None
        d = self.im.read(ptr, ln)
        if not d:
            return None
        for enc in ("utf-8", "utf-16-le"):
            try:
                t = d.decode(enc)
                if t and all(32 <= ord(ch) < 0x3000 for ch in t):
                    return t
            except Exception:
                pass
        return None

    def objc_class_at(self, vm: int):
        # class_t: data at +32 -> ro -> name at +24
        d = self.im.deref(vm + 32)
        if not d:
            return None
        return self.im.cstr(self.im.deref(d + 24))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("macho")
    ap.add_argument("--at", type=lambda x: int(x, 0))
    ap.add_argument("--n", type=int, default=150)
    ap.add_argument("--sel", help="disassemble ObjC method by selector (class:sel)")
    args = ap.parse_args()

    d = Dis(args.macho)
    if args.at:
        d.dump(args.at, args.n)
        return 0
    ap.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
