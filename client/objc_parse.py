#!/usr/bin/env python3
"""Self-contained Mach-O ObjC metadata parser (no ObjC support in free lief).

Relies on two facts:
  1. Sections are readable via lief (`section.content`).
  2. On iOS arm64/arm64e, `__DATA`/`__DATA_CONST` pointer slots are encoded with
     DYLD chained fixups whose low 36 bits already equal `vmaddr - image_base`.
     Masking with 0xFFFFFFFFF therefore recovers the target vmaddr directly,
     without needing to walk the fixup chain.

Usage:
    python client/objc_parse.py <macho> --grep sign
    python client/objc_parse.py <macho> --class AIRequestInfoPlugin
    python client/objc_parse.py <macho> --method 'signStringWithParams:signatureParams:serverKey:'
    python client/objc_parse.py <macho> --dump-classes out.json
"""
from __future__ import annotations

import argparse
import json
import struct
import sys

import lief

PTR_MASK = 0xFFFFFFFFF  # 36 bits, low bits of chained-fixup target


class MachOObjC:
    def __init__(self, path: str):
        fat = lief.MachO.parse(path)
        try:
            self.b = fat.at(0)
        except Exception:
            self.b = fat
        self.base = self.b.imagebase
        self._segs = []
        for s in self.b.segments:
            self._segs.append((s.virtual_address, s.virtual_address + s.virtual_size, s.name))
        self._secs = {}
        for s in self.b.sections:
            try:
                content = bytes(s.content)
            except Exception:
                content = b""
            self._secs[(s.segment_name, s.name)] = (s.virtual_address, content)
        self.classes: list[dict] = []
        self._parse()

    # ---- low level -------------------------------------------------
    def vm_ok(self, vm: int) -> bool:
        for a, b, _ in self._segs:
            if a <= vm < b:
                return True
        return False

    def sec(self, seg: str, name: str):
        return self._secs.get((seg, name))

    def read(self, vm: int, n: int) -> bytes | None:
        for (seg, name), (va, content) in self._secs.items():
            if va <= vm and vm + n <= va + len(content):
                off = vm - va
                return content[off: off + n]
        return None

    def u32(self, vm: int):
        d = self.read(vm, 4)
        return struct.unpack("<I", d)[0] if d else None

    def i32(self, vm: int):
        d = self.read(vm, 4)
        return struct.unpack("<i", d)[0] if d else None

    def u64(self, vm: int):
        d = self.read(vm, 8)
        return struct.unpack("<Q", d)[0] if d else None

    def deref(self, vm: int):
        """Resolve a pointer slot.

        Format observed in this binary: DYLD_CHAINED_PTR_64 (pointer_format 1),
        i.e. the low 36 bits hold an ABSOLUTE vmaddr and bit63 marks a bind
        (external symbol) fixup.  We also fall back to the 64_OFFSET variant
        (low bits = vmaddr - imagebase) just in case.
        """
        raw = self.u64(vm)
        if raw is None:
            return None
        if raw & (1 << 63):  # bind -> external symbol, not resolvable here
            return None
        cand = raw & PTR_MASK            # 64 / ARM64E absolute target
        if self.vm_ok(cand):
            return cand
        cand2 = self.base + (raw & PTR_MASK)   # 64_OFFSET variant
        if self.vm_ok(cand2):
            return cand2
        if self.vm_ok(raw):
            return raw
        return None

    def cstr(self, vm: int, limit: int = 512) -> str | None:
        if vm is None:
            return None
        for (seg, name), (va, content) in self._secs.items():
            if va <= vm < va + len(content):
                off = vm - va
                end = content.find(b"\x00", off)
                if end == -1:
                    end = min(len(content), off + limit)
                try:
                    return content[off:end].decode("utf-8", "replace")
                except Exception:
                    return None
        return None

    # ---- objc ------------------------------------------------------
    def _parse(self):
        cl = self.sec("__DATA_CONST", "__objc_classlist") or self.sec("__DATA", "__objc_classlist")
        if not cl:
            print("[!] no __objc_classlist", file=sys.stderr)
            return
        va, content = cl
        n = len(content) // 8
        for i in range(n):
            slot = va + i * 8
            cls_vm = self.deref(slot)
            if not cls_vm or not self.vm_ok(cls_vm):
                continue
            info = self._parse_class(cls_vm)
            if info:
                self.classes.append(info)

    def _parse_class(self, cls_vm: int) -> dict | None:
        # class_t: isa, superclass, cache, vtable, data
        super_vm = self.deref(cls_vm + 8)
        data_vm = self.deref(cls_vm + 32)
        if not data_vm:
            return None
        # class_ro_t: flags, instanceStart, instanceSize, reserved, ivarLayout,
        #             name, baseMethods, baseProtocols, ivars, weakIvarLayout, baseProperties
        name = self.cstr(self.deref(data_vm + 24))
        if not name:
            return None
        sup_name = None
        if super_vm:
            sd = self.deref(super_vm + 32)
            if sd:
                sup_name = self.cstr(self.deref(sd + 24))
        meths = self._parse_methods(self.deref(data_vm + 32))
        return {
            "name": name,
            "super": sup_name,
            "vm": cls_vm,
            "ro": data_vm,
            "methods": meths,
        }

    def _parse_methods(self, ml_vm: int | None) -> list[dict]:
        if not ml_vm:
            return []
        ef = self.u32(ml_vm)
        cnt = self.u32(ml_vm + 4)
        if ef is None or cnt is None or cnt > 20000:
            return []
        entsize = ef & 0x0000FFFC
        relative = bool(ef & 0x80000000)
        if entsize == 0:
            entsize = 12 if relative else 24
        out = []
        p = ml_vm + 8
        for _ in range(cnt):
            if relative:
                noff = self.i32(p)
                toff = self.i32(p + 4)
                ioff = self.i32(p + 8)
                if noff is None:
                    break
                # `name` in __objc_methlist points at a *selref* slot; the real
                # selector cstring must be read through one more dereference.
                naddr = p + noff
                nm = self.cstr(self.deref(naddr))
                if not (nm and nm.isprintable()):
                    nm = self.cstr(naddr)
                ty = self.cstr(p + 4 + toff) if toff is not None else None
                imp = None
                if ioff is not None:
                    imp = p + 8 + (ioff & ~1)
                out.append({"name": nm, "types": ty, "imp": imp, "rel": True})
            else:
                nm = self.cstr(self.deref(p))
                ty = self.cstr(self.deref(p + 8))
                imp = self.deref(p + 16)
                out.append({"name": nm, "types": ty, "imp": imp, "rel": False})
            p += entsize
        return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("macho")
    ap.add_argument("--grep")
    ap.add_argument("--class", dest="cls")
    ap.add_argument("--method")
    ap.add_argument("--dump-classes")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    m = MachOObjC(args.macho)
    print(f"[*] classes: {len(m.classes)}  imagebase=0x{m.base:x}", file=sys.stderr)

    if args.dump_classes:
        with open(args.dump_classes, "w", encoding="utf-8") as f:
            json.dump(m.classes, f, ensure_ascii=False, indent=1)
        print(f"[*] wrote {args.dump_classes}", file=sys.stderr)

    if args.grep:
        import re
        pat = re.compile(args.grep, re.I)
        hits = [c for c in m.classes if pat.search(c["name"])]
        for c in hits:
            print(f"{c['name']} : {c['super']}  ({len(c['methods'])} methods) @0x{c['vm']:x}")
        print(f"[*] {len(hits)} classes matched", file=sys.stderr)
        return 0

    if args.cls:
        for c in m.classes:
            if c["name"] == args.cls:
                print(f"=== {c['name']} : {c['super']}  class_t@0x{c['vm']:x} ro@0x{c['ro']:x} ===")
                for me in c["methods"]:
                    imp = f"0x{me['imp']:x}" if me["imp"] else "-"
                    print(f"  {imp}  -[{me['name']}]  {me['types']}")
                return 0
        print("not found")
        return 1

    if args.method:
        for c in m.classes:
            for me in c["methods"]:
                if me["name"] == args.method:
                    imp = f"0x{me['imp']:x}" if me["imp"] else "-"
                    print(f"{c['name']}  {imp}  {me['types']}")
        return 0

    ap.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
