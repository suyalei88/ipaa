#!/usr/bin/env python3
"""Resolve `__stubs` / `__objc_stubs` trampolines to symbol names / selectors.

- `__stubs`      : adrp x16,page ; ldr x16,[x16,#off] ; br x16
                   -> GOT slot in __DATA_CONST.__got -> chained-fixup bind
                      ordinal -> LC_DYLD_CHAINED_FIXUPS imports table.
- `__objc_stubs` : adrp x1,page  ; ldr x1,[x1,#off]   ; adrp x16,.. ; ldr x16,..; br x16
                   -> x1 slot in __objc_selrefs -> selector cstring.
"""
from __future__ import annotations

import struct

from macho_util import Image, PTR_MASK
from capstone import CS_OP_MEM

DYLD_CHAINED_IMPORT = 1


class Symbols:
    def __init__(self, img: Image):
        self.im = img
        self.blob = self._find_blob()
        self.imports: list[str] = []
        self._parse_imports()
        self.stubs: dict[int, str] = {}
        self.objc_stubs: dict[int, str] = {}
        self._parse_stubs()
        self._parse_objc_stubs()

    # ---- fixups blob ------------------------------------------------
    def _find_blob(self) -> int:
        # __LINKEDIT has no sections in this binary -> read raw file bytes.
        va, vend, foff, nm = [s for s in self.im.seg_file if s[3] == "__LINKEDIT"][0]
        size = vend - va
        self.im._fh.seek(foff)
        sc = self.im._fh.read(size)
        for o in range(0, len(sc) - 28):
            ver, starts, imps, syms, cnt, ifmt, sfmt = struct.unpack_from("<7I", sc, o)
            if ver != 0 or ifmt != DYLD_CHAINED_IMPORT:
                continue
            if not (0 < starts < len(sc) and 0 < imps < len(sc) and 0 < syms < len(sc)):
                continue
            if cnt <= 0 or cnt > 200000:
                continue
            segc = struct.unpack_from("<I", sc, o + starts)[0]
            if not (1 <= segc <= 16):
                continue
            return va + o  # vmaddr of blob
        raise RuntimeError("chained fixups blob not found")

    def _blob_content(self):
        return self.im.read(self.blob, 0x100000) or b""

    def _parse_imports(self) -> None:
        # read header at self.blob (raw: __LINKEDIT has no lief sections)
        hdr = self.im.raw(self.blob, 28)
        ver, starts, imps_off, syms_off, cnt, ifmt, sfmt = struct.unpack("<7I", hdr)
        self.imports_off = imps_off
        self.symbols_off = syms_off
        self.imports_count = cnt
        tbl = self.im.raw(self.blob + imps_off, cnt * 4)
        strs = self.im.raw(self.blob + syms_off, 0x40000)
        for i in range(cnt):
            (raw,) = struct.unpack_from("<I", tbl, i * 4)
            name_off = raw >> 9
            e = strs.find(b"\x00", name_off)
            nm = strs[name_off:e].decode("utf-8", "replace") if e != -1 else None
            self.imports.append(nm or f"<import#{i}>")

    def _got_target(self, stub_addr: int) -> str | None:
        ins = list(self.im.disasm(stub_addr, 3))
        if len(ins) < 3:
            return None
        page = None
        off = None
        for i in ins:
            if i.mnemonic == "adrp":
                page = i.operands[1].imm
            elif i.mnemonic == "ldr":
                m = i.operands[1]
                if m.type == CS_OP_MEM:
                    off = m.mem.disp
        if page is None or off is None:
            return None
        slot = page + off
        raw = self.im.u64(slot)
        if raw is None:
            return None
        if not (raw >> 63):
            return None
        ordinal = raw & 0xFFFFFF
        if 0 <= ordinal < len(self.imports):
            return self.imports[ordinal]
        return None

    def _parse_stubs(self) -> None:
        va, c = self.im.sections[("__TEXT", "__stubs")]
        n = len(c) // 12
        for i in range(n):
            a = va + i * 12
            nm = self._got_target(a)
            if nm:
                self.stubs[a] = nm

    def _sel_at(self, slot_addr: int):
        v = self.im.deref(slot_addr)
        if v is None:
            return None
        return self.im.cstr(v)

    def _parse_objc_stubs(self) -> None:
        va, c = self.im.sections[("__TEXT", "__objc_stubs")]
        n = len(c) // 16
        for i in range(n):
            a = va + i * 16
            ins = list(self.im.disasm(a, 5))
            page = off = None
            for x in ins:
                if x.mnemonic == "adrp" and x.op_str.startswith("x1"):
                    page = x.operands[1].imm
                elif x.mnemonic == "ldr" and x.op_str.startswith("x1"):
                    page = None
            # simpler: re-read first two instructions
            i0 = list(self.im.disasm(a, 2))
            if len(i0) < 2:
                continue
            if i0[0].mnemonic == "adrp" and i0[1].mnemonic == "ldr":
                p = i0[0].operands[1].imm
                m = i0[1].operands[1]
                if m.type == CS_OP_MEM:
                    slot = p + m.mem.disp
                    sel = self._sel_at(slot)
                    if sel:
                        self.objc_stubs[a] = sel

    def call_name(self, addr: int) -> str | None:
        if addr in self.stubs:
            return self.stubs[addr]
        if addr in self.objc_stubs:
            return f"objc_msgSend({self.objc_stubs[addr]})"
        return None


if __name__ == "__main__":
    import sys
    im = Image(sys.argv[1])
    sy = Symbols(im)
    print(f"blob=0x{sy.blob:x} imports={len(sy.imports)} stubs={len(sy.stubs)} objc_stubs={len(sy.objc_stubs)}")
    for i in range(5):
        print("  import", i, sy.imports[i])
