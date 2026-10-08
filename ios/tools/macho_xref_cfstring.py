#!/usr/bin/env python3
"""
macho_xref_cfstring.py — 定位「使用某个 ObjC 字符串字面量(@"...")的代码」。

背景（踩过的坑，务必保留）：
  · 这个 App 的 Mach-O 用 DYLD_CHAINED_PTR_64（**非** _64_OFFSET）。
    __cfstring 里 ptr 字段的 raw 64 位值 = 低 36 位是 vmaddr，
    高位还塞着 next 链字段。所以判等必须 `(v & 0xFFFFFFFFF) == vmaddr`，
    不能拿 `vmaddr - imageBase` 去比 —— 那样一条都命中不了。
  · 三段 vm 与 fileoff 的关系恰好都是 vm = 0x100000000 + fileoff。
  · ObjC 字面量在代码里是 adrp+add 指向 __cfstring 的**条目地址**，
    不是指向 cstring 本身。所以要 xref 的是 cfstring 条目地址。

用法：
  macho_xref_cfstring.py <binary> <cfstring_vmaddr_hex> [--before 12] [--after 30] [--max 3]
"""
import struct
import sys

import capstone

IB = 0x100000000


def parse_sections(path):
    with open(path, "rb") as f:
        data = f.read()
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    secs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x19:
            seg = data[off + 8:off + 24].split(b"\x00")[0].decode()
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            so = off + 72
            for _s in range(nsects):
                sname = data[so:so + 16].split(b"\x00")[0].decode()
                svm, ssize = struct.unpack_from("<QQ", data, so + 32)
                soff = struct.unpack_from("<I", data, so + 48)[0]
                secs.append((seg, sname, svm, soff, ssize))
                so += 80
        off += cmdsize
    return data, secs


def resolve_cfstring(data, vm):
    """给 cfstring 条目 vmaddr，返回它指向的字符串（或 None）。"""
    fo = vm - IB
    if not (0 <= fo < len(data) - 32):
        return None
    _isa, _fl, ptr, ln = struct.unpack_from("<QQQQ", data, fo)
    if (ptr >> 63) & 1:
        return None
    tgt = ptr & 0xFFFFFFFFF
    f2 = tgt - IB
    if not (0 <= f2 < len(data)):
        return None
    if 0 < ln < 300:
        raw = data[f2:f2 + ln]
    else:
        raw = data[f2:f2 + 80].split(b"\x00")[0]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("utf-8", "replace")


def main():
    path = sys.argv[1]
    target = int(sys.argv[2], 16)
    before = 12
    after = 30
    maxhits = 3
    if "--before" in sys.argv:
        before = int(sys.argv[sys.argv.index("--before") + 1])
    if "--after" in sys.argv:
        after = int(sys.argv[sys.argv.index("--after") + 1])
    if "--max" in sys.argv:
        maxhits = int(sys.argv[sys.argv.index("--max") + 1])

    data, secs = parse_sections(path)
    text = next(s for s in secs if s[1] == "__text")
    _seg, _sec, tvm, toff, tsize = text
    code = data[toff:toff + tsize]

    page = target & ~0xFFF
    pageoff = target & 0xFFF

    # 找 adrp 命中该 page 的位置（纯位解码，快）
    cand = []
    for i in range(0, tsize - 4, 4):
        w = struct.unpack_from("<I", code, i)[0]
        if (w >> 31) & 1 and ((w >> 24) & 0x1F) == 0x10:
            immlo = (w >> 29) & 3
            immhi = (w >> 5) & 0x7FFFF
            imm = (immhi << 2) | immlo
            if imm & (1 << 20):
                imm -= (1 << 21)
            pc = tvm + i
            if ((pc & ~0xFFF) + (imm << 12)) == page:
                cand.append(i)

    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    print(f"cfstring @0x{target:X} -> {resolve_cfstring(data, target)!r}")
    print(f"adrp 命中 page 0x{page:X}: {len(cand)} 处，找 add #{pageoff:#x} 的")

    hits = 0
    for i in cand:
        insns = list(md.disasm(code[i:i + 24], tvm + i))
        if len(insns) < 2:
            continue
        reg = insns[0].op_str.split(",")[0].strip()
        for k in range(1, min(5, len(insns))):
            ins = insns[k]
            if ins.mnemonic == "add":
                ops = [x.strip() for x in ins.op_str.replace("#", "").split(",")]
                if len(ops) == 3 and ops[0] == reg and ops[1] == reg:
                    try:
                        if int(ops[2], 16) != pageoff:
                            break
                    except ValueError:
                        break
                    print(f"\n===== xref @0x{ins.address:X} =====")
                    lo = max(0, i - before * 4)
                    hi = min(len(code), i + after * 4)
                    window = list(md.disasm(code[lo:hi], tvm + lo))
                    # 把 adrp+add 解析成 cfstring 内容，方便阅读
                    pend = {}
                    for ins2 in window:
                        note = ""
                        if ins2.mnemonic == "adrp":
                            try:
                                pend[ins2.op_str.split(",")[0].strip()] = ins2.op_str.split("#")[-1]
                            except Exception:
                                pass
                        elif ins2.mnemonic == "add":
                            ops = [x.strip() for x in ins2.op_str.replace("#", "").split(",")]
                            if len(ops) == 3 and ops[0] == ops[1] and ops[1] in pend:
                                try:
                                    vm = int(pend[ops[1]], 16) + int(ops[2], 16)
                                except ValueError:
                                    vm = None
                                if vm:
                                    s = resolve_cfstring(data, vm)
                                    if s is not None:
                                        note = f"   ; @\"{s}\""
                        mark = ">>" if ins2.address == ins.address else "  "
                        print(f" {mark} 0x{ins2.address:X}: {ins2.mnemonic}\t{ins2.op_str}{note}")
                    hits += 1
                    break
            if ins.mnemonic.startswith(("ld", "st")):
                break
        if hits >= maxhits:
            break
    if hits == 0:
        print("（未找到引用）")


if __name__ == "__main__":
    main()
