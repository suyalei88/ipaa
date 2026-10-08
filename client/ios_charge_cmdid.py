#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ios_charge_cmdid.py —— 从官方主二进制里解出「充电四个 cmdid」。

为什么需要它：
    抓包里 `POST /carownerservice/v3/api/appremotectl` 的 cmdid 只有
    110/120/130/170/230/400（已实现的 6 个车控），
    **充电四个 cmdid 一个样本都没有** —— 抓包期间没人点过充电。
    所以只能从官方主二进制的 cmdid 分派函数里反汇编出来。

为什么不能走「直接扫 __objc_selrefs」这条捷径：
    `__objc_selrefs` 在 `__DATA` 段，磁盘上的 8 字节**全是 0** ——
    它们是 chained-fixups 未 rebase 状态。必须解析
    `LC_DYLD_CHAINED_FIXUPS` 才能还原出「这个槽位指向哪个 selector 字符串」。
    本脚本自带一份纯 stdlib 的解码实现（不依赖 lief），
    以免哪天环境里装不上 lief 就复现不了。

链路：
    1. selector 字符串 vmaddr          ← 在 __objc_methname / __cstring 里找
    2. selector 槽位                    ← chained fixups 里 target == 该 vmaddr 的槽
    3. selector 的 stub 地址            ← __objc_stubs 里 `adrp x1,p` + `ldr x1,[x1,#o]`
                                          且 p+o 命中上面的槽位
    4. `bl <stub>` 调用点               ← __text 里 (insn & 0xFC000000) == 0x94000000
    5. 从调用点往前找最近的 `cmp wN, #imm` ← 那个 imm 就是 cmdid

用法：
    python client/ios_charge_cmdid.py evidence/leapmotor_main

2026-10-09 实跑结果（应完全一致）：

    requestForChargingSetContent:                 cmdid=[190]                stub=0x10A4D4E20  callsite=0x106C5F09C
    requestForBeginOrEndChargingWithContent:      cmdid=[193]                stub=0x10A4D4D80  callsite=0x106C5F250
    requestForChargingHealthControl:              cmdid=[480]                stub=0x10A4D4E00  callsite=0x106C5EF38
    requestForAppointmentContrlCmdID:content:     cmdid=[161,171,361,392]    stub=0x10A4D4D40  callsite=0x106C5EF54

⚠️ 预约充电那条是**四个 cmdid 共用一个分支体**（161 / 171 / 361 / 392）——
   所以「cmdid 161 = 预约充电」成立，但反过来「预约充电只有 161」不成立。
   本 App 只用 161（`rightList` 里也有它，且排位靠前）。
"""
from __future__ import annotations

import struct
import sys

import capstone

# 目标 selector → 期望 cmdid / 期望 stub 地址
# 期望值写在这里是为了「验证」而不是「发现」：脚本自己从二进制里读，
# 与期望不符就报红 —— 防止哪天官方换版本而代码里的常量悄悄失配。
TARGETS: list[tuple[str, int, int]] = [
    ("requestForChargingSetContent:", 190, 0x10A4D4E20),
    ("requestForBeginOrEndChargingWithContent:", 193, 0x10A4D4D80),
    ("requestForChargingHealthControl:", 480, 0x10A4D4E00),
    ("requestForAppointmentContrlCmdID:content:", 161, 0x10A4D4D40),
]

BL_MASK = 0xFC000000
BL_OP = 0x94000000


# ----------------------------------------------------------------------
# Mach-O
# ----------------------------------------------------------------------
class MachO:
    def __init__(self, path: str):
        self.f = open(path, "rb")
        head = self.f.read(0x400000)
        magic = struct.unpack_from("<I", head, 0)[0]
        if magic != 0xFEEDFACF:
            raise SystemExit(f"不是 64 位 Mach-O：magic=0x{magic:08X}")
        (_magic, _cpu, _sub, _ft, ncmds, _sz, _fl) = struct.unpack_from("<IiiIIII", head, 0)
        self.segs: list[dict] = []
        self.secs: list[dict] = []
        self.chained = None
        off = 32
        for _ in range(ncmds):
            cmd, sz = struct.unpack_from("<II", head, off)
            base = cmd & 0x7FFFFFFF
            if base == 0x19:  # LC_SEGMENT_64
                segname = head[off + 8:off + 24].split(b"\x00")[0].decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", head, off + 24)
                nsects = struct.unpack_from("<I", head, off + 64)[0]
                self.segs.append(dict(name=segname, vmaddr=vmaddr, vmsize=vmsize,
                                      fileoff=fileoff, filesize=filesize))
                so = off + 72
                for _s in range(nsects):
                    sname = head[so:so + 16].split(b"\x00")[0].decode()
                    sseg = head[so + 16:so + 32].split(b"\x00")[0].decode()
                    addr, size = struct.unpack_from("<QQ", head, so + 32)
                    sfileoff = struct.unpack_from("<I", head, so + 48)[0]
                    self.secs.append(dict(seg=sseg, name=sname, addr=addr,
                                          size=size, offset=sfileoff))
                    so += 80
            elif base == 0x34:  # LC_DYLD_CHAINED_FIXUPS（0x80000034）
                doff, dsize = struct.unpack_from("<II", head, off + 8)
                self.chained = (doff, dsize)
            off += sz
        # ★ 不能用 segs[0].vmaddr —— 第一个段是 __PAGEZERO（vmaddr=0）。
        #   chained fixups 的 PTR_64_OFFSET 是相对 __TEXT 的。
        self.image_base = next(s["vmaddr"] for s in self.segs if s["name"] == "__TEXT")

    # --- vm <-> fileoff ---
    def vm2off(self, vm: int):
        for s in self.segs:
            # ★ 跳过 __PAGEZERO：它 vmsize 极大但 filesize=0，会把低地址全吞掉
            if s["filesize"] == 0:
                continue
            if s["vmaddr"] <= vm < s["vmaddr"] + s["vmsize"]:
                return s["fileoff"] + (vm - s["vmaddr"])
        return None

    def off2vm(self, off: int):
        for s in self.segs:
            if s["filesize"] == 0:
                continue
            if s["fileoff"] <= off < s["fileoff"] + s["filesize"]:
                return s["vmaddr"] + (off - s["fileoff"])
        return None

    def sec(self, name: str):
        for s in self.secs:
            if s["name"] == name:
                return s
        return None

    def bytes_at_vm(self, vm: int, n: int) -> bytes:
        o = self.vm2off(vm)
        if o is None:
            return b""
        self.f.seek(o)
        return self.f.read(n)

    def u64_at_off(self, off: int) -> int:
        self.f.seek(off)
        b = self.f.read(8)
        return struct.unpack("<Q", b)[0] if len(b) == 8 else 0

    # --- chained fixups ---
    def decode_chained(self) -> dict[int, int]:
        """返回 {槽位文件偏移: 目标 vmaddr}（只含 rebase 指针，不含 bind）。"""
        if not self.chained:
            raise SystemExit("没有 LC_DYLD_CHAINED_FIXUPS")
        doff, dsize = self.chained
        self.f.seek(doff)
        blob = self.f.read(dsize)
        (ver, starts_off, _imps_off, _syms_off, _imps_cnt,
         _ifmt, _sfmt) = struct.unpack_from("<IIIIIII", blob, 0)
        if ver != 0:
            raise SystemExit(f"fixups_version={ver} 不认识")
        seg_count = struct.unpack_from("<I", blob, starts_off)[0]
        # struct dyld_chained_starts_in_image {
        #     uint32_t seg_count;
        #     uint32_t seg_info_offset[seg_count];   // 相对 starts_off 的偏移，0 = 该段无 fixups
        # };
        # ★ 段结构体不是连续排列的！必须按 seg_info_offset[i] 跳过去。
        #   本二进制实测 seg_info = [0, 0, 0x20, 0x1B0, 0, 0]，
        #   即只有 __DATA_CONST(idx2) 和 __DATA(idx3) 有 fixups。
        seg_info = struct.unpack_from("<%dI" % seg_count, blob, starts_off + 4)

        out: dict[int, int] = {}
        for si, so in enumerate(seg_info):
            if so == 0:
                continue
            q = starts_off + so
            # struct dyld_chained_starts_in_segment:
            #   uint32 size; uint16 page_size; uint16 pointer_format;
            #   uint64 segment_offset; uint32 max_valid_pointer;
            #   uint16 page_count; uint16 page_start[];
            # 合计 22 字节 —— 别写成 "<IIQIIH"（那是 26 字节，
            # 会把 page_size 和 pointer_format 挤成一个整数，解出天文数字）。
            (_size, page_size, ptr_fmt, seg_off, _maxptr,
             page_count) = struct.unpack_from("<IHHQIH", blob, q)
            if page_count == 0:
                continue
            if ptr_fmt not in (1, 2, 4, 6):
                raise SystemExit(f"段 {si} 的 pointer_format={ptr_fmt} 未处理")
            page_starts = struct.unpack_from("<%dH" % page_count, blob, q + 22)
            for pi, ps in enumerate(page_starts):
                if ps == 0xFFFF:
                    continue
                # ★ seg_off 在本二进制里就是**文件偏移**（实测 __DATA: 0xB574000，
                #   与 __DATA 段的 fileoff 一致），所以 chain 直接当文件偏移用。
                chain = seg_off + pi * page_size + ps
                while True:
                    raw = self.u64_at_off(chain)
                    if ptr_fmt in (2, 3):       # DYLD_CHAINED_PTR_64 / _64_KERNEL_CACHE
                        is_bind = (raw >> 63) & 1
                        nxt = (raw >> 51) & 0xFFF
                        tgt_vm = raw & 0xFFFFFFFFF
                    elif ptr_fmt == 4:          # DYLD_CHAINED_PTR_64_OFFSET
                        is_bind = (raw >> 63) & 1
                        nxt = (raw >> 51) & 0xFFF
                        tgt_vm = (raw & 0xFFFFFFFFF) + self.image_base
                    else:                       # DYLD_CHAINED_PTR_ARM64E / _OFFSET
                        is_bind = (raw >> 62) & 1
                        nxt = (raw >> 51) & 0x7FF
                        tgt_vm = raw & 0xFFFFFFFFF
                    if not is_bind:
                        out[chain] = tgt_vm
                    if nxt == 0:
                        break
                    chain += nxt * 4
        return out


# ----------------------------------------------------------------------
# 分析
# ----------------------------------------------------------------------
def selref_slots(mo: MachO, fixmap: dict[int, int], sel_vm: int) -> list[int]:
    """找出所有「rebase 后指向 sel_vm」的槽位 vmaddr。"""
    return [mo.off2vm(off) for off, tgt in fixmap.items()
            if tgt == sel_vm and mo.off2vm(off) is not None]


def stub_of(mo: MachO, md, fixmap: dict[int, int], slots: set[int]) -> int | None:
    """在 __objc_stubs 里找 `adrp x1,p` + `ldr x1,[x1,#o]`，且 p+o ∈ slots。"""
    sec = mo.sec("__objc_stubs")
    if not sec:
        return None
    vm, size = sec["addr"], sec["size"]
    for a in range(vm, vm + size, 16):
        code = mo.bytes_at_vm(a, 8)
        if len(code) < 8:
            break
        ins = list(md.disasm(code, a))
        if len(ins) < 2:
            continue
        i0, i1 = ins[0], ins[1]
        if i0.mnemonic != "adrp" or i1.mnemonic != "ldr":
            continue
        if not i0.op_str.startswith("x1") or not i1.op_str.startswith("x1"):
            continue
        page = i0.operands[1].imm
        m = i1.operands[1]
        if m.type != capstone.arm64.ARM64_OP_MEM:
            continue
        slot = page + m.mem.disp
        if slot in slots:
            return a
    return None


def callsites_of(mo: MachO, stub: int) -> list[int]:
    sec = mo.sec("__text")
    vm, size = sec["addr"], sec["size"]
    out = []
    for i in range(size // 4):
        w = struct.unpack_from("<I", mo.bytes_at_vm(vm + i * 4, 4), 0)[0]
        if (w & BL_MASK) != BL_OP:
            continue
        imm26 = w & 0x03FFFFFF
        if imm26 & (1 << 25):
            imm26 -= 1 << 26
        if vm + i * 4 + imm26 * 4 == stub:
            out.append(vm + i * 4)
    return out


BRANCH_MNEMONICS = ("b", "b.eq", "b.ne", "b.gt", "b.le", "b.ge", "b.lt",
                    "b.hi", "b.ls", "b.hs", "b.lo", "b.mi", "b.pl", "b.vs", "b.vc")


def body_start_before(mo: MachO, md, callsite: int) -> int | None:
    """调用点所在「分派分支体」的起始地址。

    分派表长这样（实测 0x106C5EE00 起）：
        cmp   x23, #0xc1
        b.eq  #0x106c5f248      ← 跳到分支体
        ...
        0x106C5F248: mov x0, x21
                     mov x2, x19
                     bl  #0x10a4d4d80
                     b   #0x106c5ef60

    所以分支体起点 = 调用点往前最近的一条分支指令的**下一条**。
    """
    for k in range(1, 400):
        a = callsite - 4 * k
        code = mo.bytes_at_vm(a, 4)
        if len(code) < 4:
            return None
        ins = list(md.disasm(code, a))
        if ins and ins[0].mnemonic in BRANCH_MNEMONICS:
            return a + 4
    return None


def cmdids_for_body(mo: MachO, md, body_start: int, span: int = 1400):
    """找出所有「这个分支体对应的 cmdid」→ 返回 [(imm, cmp_addr, cmp_op_str)]。

    编译器用了**两种**分发方式，必须都认：

      ① 跳转式：`cmp xN, #imm` + `b.eq <body>`
      ② 落空式：`cmp xN, #imm` + `b.ne <统一退出>`，相等则**顺序落到** body
         （实测 190 与 480 都是这种 —— 它们是各自比较链的最后一项）

    ★ 一个分支体可能被多个 cmdid 共用。实测预约充电就是
      **161 / 171 / 361 / 392** 四个值都落到 0x106C5EF48 ——
      所以必须收集「集合」，不能只取最近的那一个。
    """
    hits = []
    for k in range(1, span):
        a = body_start - 4 * k
        code = mo.bytes_at_vm(a, 4)
        if len(code) < 4:
            break
        ins = list(md.disasm(code, a))
        if not ins:
            continue
        i = ins[0]
        if i.mnemonic != "cmp":
            continue
        imm = None
        for op in i.operands:
            if op.type == capstone.arm64.ARM64_OP_IMM:
                imm = op.imm
        if imm is None:
            continue

        nxt = list(md.disasm(mo.bytes_at_vm(a + 4, 4), a + 4))
        if not nxt:
            continue
        n = nxt[0]
        tgt = n.operands[0].imm if n.operands else None

        if n.mnemonic == "b.eq" and tgt == body_start:
            hits.append((imm, a, i.op_str, "b.eq"))          # ① 跳转式
        elif n.mnemonic == "b.ne" and a + 8 == body_start:
            hits.append((imm, a, i.op_str, "b.ne→落空"))     # ② 落空式
    return sorted(hits)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    print(f"目标二进制：{path}")
    mo = MachO(path)
    print(f"image_base = 0x{mo.image_base:X}  段数={len(mo.segs)}  section 数={len(mo.secs)}")

    print("解析 chained fixups …")
    fixmap = mo.decode_chained()
    print(f"  rebase 指针 {len(fixmap)} 个")

    # selector 字符串 → vmaddr
    methname = mo.sec("__objc_methname")
    cstring = mo.sec("__cstring")
    print(f"  __objc_methname vm=0x{methname['addr']:X} size=0x{methname['size']:X}")

    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    md.detail = True

    print("\n" + "=" * 74)
    fails = 0
    for sel, expect_cmd, expect_stub in TARGETS:
        print(f"\nselector: {sel}")
        needle = sel.encode()
        sel_vm = None
        for sec in (methname, cstring):
            sec_off = sec["offset"]
            mo.f.seek(sec_off)
            data = mo.f.read(sec["size"])
            idx = data.find(needle + b"\x00")
            if idx >= 0:
                sel_vm = sec["addr"] + idx
                print(f"  字符串 @0x{sel_vm:X}（{sec['name']}）")
                break
        if sel_vm is None:
            print("  ❌ 字符串表里找不到这个 selector")
            fails += 1
            continue

        slots = set(selref_slots(mo, fixmap, sel_vm))
        if not slots:
            print("  ❌ chained fixups 里没有指向它的槽位")
            fails += 1
            continue
        print(f"  selref 槽位 {len(slots)} 个，例 0x{sorted(slots)[0]:X}")

        stub = stub_of(mo, md, fixmap, slots)
        if stub is None:
            print("  ❌ __objc_stubs 里找不到对应 stub")
            fails += 1
            continue
        ok_stub = stub == expect_stub
        print(f"  stub = 0x{stub:X}  {'✅' if ok_stub else '❌ 期望 0x%X' % expect_stub}")
        if not ok_stub:
            fails += 1

        sites = callsites_of(mo, stub)
        if not sites:
            print("  ❌ __text 里没有 bl <stub> 调用点")
            fails += 1
            continue
        for site in sites:
            body = body_start_before(mo, md, site)
            if body is None:
                print(f"  callsite=0x{site:X}  （往前找不到分支体起点）")
                continue
            cmds = cmdids_for_body(mo, md, body)
            vals = [c[0] for c in cmds]
            ok = expect_cmd in vals
            print(f"  callsite=0x{site:X}  分支体起点=0x{body:X}  "
                  f"{'✅' if ok else '❌'} cmdid={vals}  期望包含 {expect_cmd}")
            for imm, caddr, cop, bmn in cmds:
                print(f"      cmp @0x{caddr:X}   cmp {cop}"
                      f"   {bmn} → 0x{body:X}")
            if not ok:
                fails += 1

    print("\n" + "=" * 74)
    if fails:
        print(f"❌ {fails} 处与期望不符 —— 二进制可能换了版本，需重新分析")
        return 1
    print("✅ 四个 cmdid + 四个 stub 地址全部与代码里的常量一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
