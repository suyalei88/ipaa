#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ios_all_cmdids.py —— 扫出官方主二进制里**全部** cmdid → selector 映射。

为什么需要它：
    `ios_charge_cmdid.py` 只验证「充电四个」已知 cmdid。
    但官方车控能做的事远不止我们已实现的 6 个（110/120/130/170/230/400）——
    官方本地化表里还有前备箱 / 天窗 / 遮阳帘 / 侧滑门 / 座椅加热通风 /
    方向盘加热 / 后视镜加热 / 电池预热 / 一键备车 / 上车迎宾 / 哨兵模式 /
    解锁充电枪 / 泊车辅助 / 直进直出 / 森野氧舱 ……
    这些**各自对应哪个 cmdid** 只能从分派器里解。

方法（与 ios_charge_cmdid.py 同一套 Mach-O/chained-fixups 解析）：
    1. 一次扫完 __text 里所有 `bl <stub>`，建 {stub: [callsite,...]}
       （反过来做会退化成 O(stub × text)，跑不动）
    2. 把 __objc_stubs 里每个 stub 解成它引用的 selector 字符串
    3. 对每个调用点，往前找分支体起点 → 再往前找 cmp #imm
    4. 汇总成 cmdid → [selector] 与 selector → [cmdid]

用法：
    python client/ios_all_cmdids.py evidence/leapmotor_main
"""
from __future__ import annotations

import struct
import sys
from collections import defaultdict

import capstone

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from ios_charge_cmdid import (  # noqa: E402
    MachO, BL_MASK, BL_OP, BRANCH_MNEMONICS,
    body_start_before, cmdids_for_body,
)


def build_stub_map(mo: MachO, md, fixmap: dict[int, int]) -> dict[int, str]:
    """{stub vmaddr: selector 名}。"""
    # 槽位 vmaddr → 目标 vmaddr（selector 字符串）
    slot_to_str: dict[int, int] = {}
    for off, tgt in fixmap.items():
        sv = mo.off2vm(off)
        if sv is not None:
            slot_to_str[sv] = tgt

    sec = mo.sec("__objc_stubs")
    if not sec:
        raise SystemExit("没有 __objc_stubs")
    vm, size = sec["addr"], sec["size"]
    out: dict[int, str] = {}
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
        m = i1.operands[1]
        if m.type != capstone.arm64.ARM64_OP_MEM:
            continue
        slot = i0.operands[1].imm + m.mem.disp
        tgt = slot_to_str.get(slot)
        if tgt is None:
            continue
        # 读字符串
        raw = mo.bytes_at_vm(tgt, 200)
        z = raw.find(b"\x00")
        if z < 0:
            continue
        try:
            name = raw[:z].decode("utf-8")
        except UnicodeDecodeError:
            continue
        out[a] = name
    return out


def all_bl_callsites(mo: MachO) -> dict[int, list[int]]:
    """一次扫完 __text，返回 {stub: [callsite,...]}。"""
    sec = mo.sec("__text")
    vm, size = sec["addr"], sec["size"]
    data = mo.bytes_at_vm(vm, size)
    out: dict[int, list[int]] = defaultdict(list)
    n = len(data) // 4
    for i in range(n):
        w = struct.unpack_from("<I", data, i * 4)[0]
        if (w & BL_MASK) != BL_OP:
            continue
        imm26 = w & 0x03FFFFFF
        if imm26 & (1 << 25):
            imm26 -= 1 << 26
        tgt = vm + i * 4 + imm26 * 4
        out[tgt].append(vm + i * 4)
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    mo = MachO(path)
    print(f"image_base=0x{mo.image_base:X}  段={len(mo.segs)}  section={len(mo.secs)}")
    print("解析 chained fixups …")
    fixmap = mo.decode_chained()
    print(f"  rebase 指针 {len(fixmap)} 个")

    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    md.detail = True

    print("扫 __objc_stubs …")
    stubs = build_stub_map(mo, md, fixmap)
    print(f"  stub 数 {len(stubs)}")

    print("扫 __text 里的 bl（一次过）…")
    calls = all_bl_callsites(mo)
    print(f"  bl 目标数 {len(calls)}")

    print("解 cmdid …")
    # ★ 分派器区域：从 evidence/charging/FINDINGS_CHARGING.md 实测
    #   `0x106C5EE00` 起。限定在这个窗口内回溯，避免对全 __text 的每个
    #   调用点都做 O(1800) 反向扫描（那会退化成几十分钟）。
    LO, HI = 0x106C5E000, 0x106C61000
    cmdid_to_sel: dict[int, set[str]] = defaultdict(set)
    sel_to_cmdid: dict[str, set[int]] = defaultdict(set)
    n_ok = 0
    for stub, sites in calls.items():
        sel = stubs.get(stub)
        if sel is None:
            continue
        for site in sites:
            if not (LO <= site < HI):
                continue
            body = body_start_before(mo, md, site)
            if body is None:
                continue
            cmds = cmdids_for_body(mo, md, body)
            if not cmds:
                continue
            n_ok += 1
            for imm, _a, _op, _bm in cmds:
                cmdid_to_sel[imm].add(sel)
                sel_to_cmdid[sel].add(imm)

    print(f"  解出 {n_ok} 个 (callsite, cmdid) 组合")
    print()
    print("=" * 78)
    print(f"★★ cmdid → selector（共 {len(cmdid_to_sel)} 个 cmdid）")
    print("=" * 78)
    for c in sorted(cmdid_to_sel):
        print(f"  {c:5d} 0x{c:04X}  " + "  ".join(sorted(cmdid_to_sel[c])))

    print()
    print("=" * 78)
    print(f"★★ 车控/远程类 selector → cmdid")
    print("=" * 78)
    KEY = ("request", "Request", "Control", "control", "Cmd", "cmd")
    for sel in sorted(sel_to_cmdid):
        if any(k in sel for k in KEY):
            print(f"  {sel:58s} {sorted(sel_to_cmdid[sel])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
