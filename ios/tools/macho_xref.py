#!/usr/bin/env python3
"""
macho_xref.py — 在 Mach-O (arm64) 里按「字符串 → adrp/add 代码引用」找 xref。

为什么需要它：官方 App 的登录/续期逻辑静态链接进 204MB 主二进制，
而 objdump（mingw64）不认 Mach-O，本地也没有 IDA/r2。
但 ObjC 代码引用 cstring 用的是 `adrp + add`（不是 __objc_const 里的
chained fixup 指针），所以只要扫 __TEXT 里的 adrp/add 配对就能定位调用点，
完全绕开 chained fixups 解码。

用法：
  macho_xref.py <binary> <needle> [--window 40] [--max 8]
"""
import struct
import sys

import capstone


def parse_macho(path):
    """返回 (image_base, sections) —— sections = [(segname, sectname, vmaddr, fileoff, size)]"""
    with open(path, "rb") as f:
        data = f.read()

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic not in (0xFEEDFACF, 0xFEEDFACE):
        raise SystemExit(f"不是 Mach-O：magic=0x{magic:08X}")
    is64 = magic == 0xFEEDFACF
    header_size = 32 if is64 else 28
    ncmds = struct.unpack_from("<I", data, 16)[0]

    off = header_size
    sections = []
    image_base = None

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x19 and is64:  # LC_SEGMENT_64
            segname = data[off + 8:off + 24].split(b"\x00")[0].decode()
            vmaddr = struct.unpack_from("<Q", data, off + 24)[0]
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            if segname == "__TEXT" and image_base is None:
                image_base = vmaddr
            so = off + 72
            for _s in range(nsects):
                sname = data[so:so + 16].split(b"\x00")[0].decode()
                svm = struct.unpack_from("<Q", data, so + 32)[0]
                ssize = struct.unpack_from("<Q", data, so + 40)[0]
                soff = struct.unpack_from("<I", data, so + 48)[0]
                sections.append((segname, sname, svm, soff, ssize))
                so += 80
        off += cmdsize

    if image_base is None:
        raise SystemExit("找不到 __TEXT 段")
    return data, image_base, sections


def fileoff_to_vm(sections, image_base, fileoff):
    for seg, sec, svm, soff, ssize in sections:
        if soff <= fileoff < soff + ssize:
            return svm + (fileoff - soff)
    return None


def _chunked_disasm(md, code, base_vm, chunk):
    """分块反汇编。块边界按 4 字节对齐，逐块 disasm 后流式 yield，避免 OOM。"""
    off = 0
    n = len(code)
    while off < n:
        piece = code[off:off + chunk]
        # 末尾可能截断一条指令；丢掉不足 4 字节的尾巴，下一块接着来
        usable = len(piece) - (len(piece) % 4)
        if usable <= 0:
            break
        for ins in md.disasm(piece[:usable], base_vm + off):
            yield ins
        off += usable


def main():
    path = sys.argv[1]
    needle = sys.argv[2].encode()
    window = 40
    maxhits = 8
    if "--window" in sys.argv:
        window = int(sys.argv[sys.argv.index("--window") + 1])
    if "--max" in sys.argv:
        maxhits = int(sys.argv[sys.argv.index("--max") + 1])

    data, image_base, sections = parse_macho(path)
    print(f"image_base = 0x{image_base:X}")
    for seg, sec, svm, soff, ssize in sections:
        if sec in ("__text", "__cstring", "__objc_methname", "__const"):
            print(f"  {seg},{sec:18s} vm=0x{svm:X} off=0x{soff:X} size=0x{ssize:X}")

    # 1) 找 needle 的文件偏移
    hits = []
    start = 0
    while True:
        i = data.find(needle, start)
        if i < 0:
            break
        hits.append(i)
        start = i + 1
    print(f"\n'{needle.decode(errors='replace')}' 文件偏移命中 {len(hits)} 处")

    text = next((s for s in sections if s[1] == "__text"), None)
    if text is None:
        raise SystemExit("没有 __text")
    _seg, _sec, tvm, toff, tsize = text
    code = data[toff:toff + tsize]

    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    md.detail = True
    # ★ 必须开：arm64 的 __text 里内嵌着字面量池 / jump table，
    #   capstone 默认遇到非法字节就停，会让扫描在第一个字面量池处夭折。
    md.skipdata = True

    # 2) 流式扫 __text：找 adrp 命中目标 page、随后 add #pageoff 的配对。
    #    用滑动窗口保存最近若干条指令，避免把上亿条指令全塞进内存。
    from collections import deque

    targets = []
    for fi in hits[:maxhits]:
        vm = fileoff_to_vm(sections, image_base, fi)
        if vm is None:
            continue
        targets.append((fi, vm, vm & ~0xFFF, vm & 0xFFF))

    page_map = {}
    for fi, vm, page, pageoff in targets:
        page_map.setdefault(page, []).append((fi, vm, pageoff))

    results = {vm: [] for _fi, vm, _p, _po in targets}
    hist = deque(maxlen=window + 8)
    pending = []  # [(adrp_ins, reg_name, target_vm, pageoff)]

    # capstone 一次性吃 172MB __text 会 OOM，分块喂。
    CHUNK = 1 << 22
    gen = _chunked_disasm(md, code, tvm, CHUNK)
    for ins in gen:
        hist.append(ins)
        if ins.mnemonic == "adrp":
            try:
                tgt_page = ins.operands[1].imm
                reg = ins.reg_name(ins.operands[0].reg)
            except Exception:
                continue
            if tgt_page in page_map:
                for fi, vm, pageoff in page_map[tgt_page]:
                    pending.append((ins, reg, vm, pageoff))
        elif ins.mnemonic == "add" and len(ins.operands) == 3:
            try:
                dst = ins.reg_name(ins.operands[0].reg)
                src = ins.reg_name(ins.operands[1].reg)
                imm = ins.operands[2].imm
            except Exception:
                continue
            keep = []
            for (ain, areg, avm, apoff) in pending:
                if dst == areg and src == areg and imm == apoff:
                    if len(results[avm]) < 3:
                        # 收集 adrp 前后各若干条
                        try:
                            ai = list(hist).index(ain)
                        except ValueError:
                            ai = 0
                        seg = list(hist)[max(0, ai - 6):ai + 8]
                        results[avm].append((ain.address, seg))
                else:
                    # adrp 太老就丢弃（超出窗口）
                    if ins.address - ain.address < 0x400:
                        keep.append((ain, areg, avm, apoff))
            pending = keep

    for fi, vm, page, pageoff in targets:
        print(f"\n===== '{needle.decode(errors='replace')}' off=0x{fi:X} vm=0x{vm:X} page=0x{page:X} pageoff=0x{pageoff:X} =====")
        got = results.get(vm) or []
        if not got:
            print("  （未找到 adrp/add 引用）")
        for addr, seg in got:
            print(f"  --- xref @0x{addr:X} ---")
            for ik in seg:
                mark = "  "
                print(f"   {mark} 0x{ik.address:X}: {ik.mnemonic}\t{ik.op_str}")


if __name__ == "__main__":
    main()
