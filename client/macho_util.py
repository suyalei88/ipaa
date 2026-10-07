#!/usr/bin/env python3
"""Reusable Mach-O helpers: section map, vm<->off, pointer deref, disasm, xref.

The binary uses DYLD_CHAINED_PTR_64 fixups, so a pointer slot's low 36 bits are
an absolute vmaddr; bit63 marks a bind (external symbol).
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

import lief
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN, CS_OP_IMM, CS_OP_MEM

PTR_MASK = 0xFFFFFFFFF


class Image:
    def __init__(self, path: str):
        self.path = path
        fat = lief.MachO.parse(path)
        try:
            self.b = fat.at(0)
        except Exception:
            self.b = fat
        self.base = self.b.imagebase
        self.sections = {}
        for s in self.b.sections:
            try:
                content = bytes(s.content)
            except Exception:
                content = b""
            self.sections[(s.segment_name, s.name)] = (s.virtual_address, content)
        self.segs = [(s.virtual_address, s.virtual_address + s.virtual_size, s.name)
                     for s in self.b.segments]
        # raw file mapping (needed for __LINKEDIT, which has no sections)
        self.seg_file = [(s.virtual_address, s.virtual_address + s.file_size, s.file_offset, s.name)
                         for s in self.b.segments]
        self._fh = open(path, "rb")
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        self.md.detail = True

    def vm2off(self, vm: int):
        for va, vend, foff, nm in self.seg_file:
            if va <= vm < vend:
                return foff + (vm - va)
        return None

    def raw(self, vm: int, n: int):
        o = self.vm2off(vm)
        if o is None:
            return None
        self._fh.seek(o)
        return self._fh.read(n)

    # --- addressing -------------------------------------------------
    def vm_ok(self, vm: int) -> bool:
        return any(a <= vm < b for a, b, _ in self.segs)

    def sec_of(self, vm: int):
        for (sg, nm), (va, c) in self.sections.items():
            if va <= vm < va + len(c):
                return sg, nm, va, c
        return None

    def which(self, vm: int) -> str:
        r = self.sec_of(vm)
        if not r:
            return "??"
        sg, nm, va, _ = r
        return f"{sg}/{nm}+0x{vm - va:x}"

    def read(self, vm: int, n: int):
        r = self.sec_of(vm)
        if not r:
            return None
        sg, nm, va, c = r
        o = vm - va
        if o + n > len(c):
            return None
        return c[o:o + n]

    def u8(self, vm):
        d = self.read(vm, 1)
        return d[0] if d else None

    def u32(self, vm):
        d = self.read(vm, 4)
        return struct.unpack("<I", d)[0] if d else None

    def i32(self, vm):
        d = self.read(vm, 4)
        return struct.unpack("<i", d)[0] if d else None

    def u64(self, vm):
        d = self.read(vm, 8)
        return struct.unpack("<Q", d)[0] if d else None

    def deref(self, vm: int):
        raw = self.u64(vm)
        if raw is None or (raw >> 63):
            return None
        cand = raw & PTR_MASK
        if self.vm_ok(cand):
            return cand
        cand2 = self.base + (raw & PTR_MASK)
        if self.vm_ok(cand2):
            return cand2
        return raw if self.vm_ok(raw) else None

    def cstr(self, vm: int, limit: int = 512):
        if vm is None:
            return None
        r = self.sec_of(vm)
        if not r:
            return None
        sg, nm, va, c = r
        o = vm - va
        e = c.find(b"\x00", o)
        if e == -1:
            e = min(len(c), o + limit)
        return c[o:e].decode("utf-8", "replace")

    def objc_str(self, vm: int):
        """selector/string slot -> text (deref one level if it is a selref)."""
        s = self.cstr(vm)
        if s and s.isprintable() and s:
            return s
        return self.cstr(self.deref(vm))

    # --- disasm -----------------------------------------------------
    def disasm(self, vm: int, count: int = 60, stop_at_ret: bool = True):
        out = []
        for ins in self.md.disasm(self.read(vm, 4 * count) or b"", vm):
            out.append(ins)
            if stop_at_ret and ins.mnemonic in ("ret", "brk"):
                break
        return out

    def disasm_until_ret(self, vm: int, max_ins: int = 400):
        """Disassemble a function by linear sweep, stopping at the first `ret`
        that returns to the caller (heuristic: `ret` with no following code)."""
        out = []
        size = 4 * max_ins
        code = self.read(vm, size)
        if not code:
            return out
        for ins in self.md.disasm(code, vm):
            out.append(ins)
            if ins.mnemonic == "ret":
                # peek: if next instruction is another function prologue, stop
                break
        return out

    # --- xref -------------------------------------------------------
    def find_ptr_refs(self, target_vm: int, seg_names=("__DATA", "__DATA_CONST")):
        """Find pointer slots whose resolved value == target_vm."""
        hits = []
        for (sg, nm), (va, c) in self.sections.items():
            if sg not in seg_names:
                continue
            for o in range(0, len(c) - 8, 8):
                raw = struct.unpack_from("<Q", c, o)[0]
                if raw >> 63:
                    continue
                if (raw & PTR_MASK) == target_vm or (self.base + (raw & PTR_MASK)) == target_vm:
                    hits.append((sg, nm, va + o))
        return hits

    def find_adrp_add_refs(self, target_vm: int):
        """Scan __TEXT for ADRP+ADD / ADRP+LDR sequences resolving to target_vm."""
        hits = []
        va, c = self.sections[("__TEXT", "__text")]
        insns = list(self.md.disasm(c, va))
        adrp = {}
        for ins in insns:
            if ins.mnemonic == "adrp" and len(ins.operands) == 2:
                rd = ins.operands[0].reg
                page = ins.operands[1].imm
                adrp[rd] = page
            elif ins.mnemonic in ("add", "ldr") and len(ins.operands) >= 2:
                op1 = ins.operands[1]
                if op1.type == CS_OP_IMM and ins.operands[0].reg in adrp:
                    tgt = adrp[ins.operands[0].reg] + op1.imm
                    if tgt == target_vm:
                        hits.append((ins.address, str(ins)))
                elif op1.type == CS_OP_MEM:
                    base = op1.mem.base
                    if base in adrp and op1.mem.disp == 0:
                        tgt = adrp[base]
                        if tgt == target_vm:
                            hits.append((ins.address, str(ins)))
        return hits


def fmt(ins) -> str:
    return f"0x{ins.address:x}:  {ins.mnemonic:<8} {ins.op_str}"
