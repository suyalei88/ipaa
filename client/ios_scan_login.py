#!/usr/bin/env python3
"""Scan a vm range and print every annotated string / selector / class ref."""
import sys, re
from capstone import CS_OP_IMM, CS_OP_MEM
sys.path.insert(0, "client")
from ios_dis import Dis

def main():
    path, lo, hi = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
    filt = re.compile(sys.argv[4]) if len(sys.argv) > 4 else None
    d = Dis(path)
    code = d.im.read(lo, hi - lo)
    if not code:
        print("[!] cannot read range"); return
    adrp = {}
    for ins in d.im.md.disasm(code, lo):
        note = []
        if ins.mnemonic == "adrp" and len(ins.operands) == 2:
            adrp[ins.operands[0].reg] = ins.operands[1].imm
        elif ins.mnemonic == "add" and len(ins.operands) >= 3:
            dst, base, imm = ins.operands[0], ins.operands[1], ins.operands[2]
            if imm.type == CS_OP_IMM and imm.imm is not None and getattr(base, "reg", None) in adrp:
                note.append(f"@{adrp[base.reg]+imm.imm:x} {d.describe(adrp[base.reg]+imm.imm)}")
        elif ins.mnemonic == "ldr" and len(ins.operands) >= 2:
            dst, src = ins.operands[0], ins.operands[1]
            if src.type == CS_OP_IMM and src.imm is not None and getattr(dst, "reg", None) in adrp:
                note.append(f"@{adrp[dst.reg]+src.imm:x} {d.describe(adrp[dst.reg]+src.imm)}")
            elif src.type == CS_OP_MEM and src.mem.base in adrp:
                note.append(f"-> [{adrp[src.mem.base]+(src.mem.disp or 0):x}] {d.describe(adrp[src.mem.base]+(src.mem.disp or 0), indirect=True)}")
        if ins.mnemonic in ("bl", "b", "blr") and ins.operands and ins.operands[0].type == CS_OP_IMM:
            t = ins.operands[0].imm
            nm = d.sy.call_name(t)
            if nm:
                note.append(f"-> {nm}")
        line = f"0x{ins.address:x}:  {ins.mnemonic:<8} {ins.op_str}"
        suffix = ("  ; " + " | ".join(note)) if note else ""
        if filt:
            full = line + suffix
            if filt.search(full):
                print(full)
        elif suffix:
            print(line + suffix)

main()
