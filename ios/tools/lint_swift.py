#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lint_swift.py —— 拦截「静态审查看不出来、只能靠真机编译/运行才发现」的 Swift 陷阱

这些规则全部来自实际踩坑（Xcode 15.4 / iPhoneOS 17.5 SDK），每条都真实烧过一轮 CI：

  R1  URLComponents / queryItems 拼 URL
      '+' 属于 CharacterSet.urlQueryAllowed，不会被转义成 %2B。
      base64 密文里的 '+' 会被服务端按 form 规则解成空格 → 密文损坏
      → 「业务错误 1019：参数不能为空」。
      必须用 LMClient.makeURL() / urlEncode()（只放行 unreserved 字符）。

  R2  [CFString: Any] 字典 + `as String` 键
      error: cannot convert value of type 'String' to expected dictionary key type 'CFString'

  R3  foregroundStyle(.自定义色)
      foregroundStyle 收泛型 ShapeStyle，前导点简写推不出自定义 Color 成员
      （SwiftUI 只给标准色声明了 `extension ShapeStyle where Self == Color`）
      error: type 'ShapeStyle' has no member 'lmAccent'

  R4  三元两分支分别是 Color 和 HierarchicalShapeStyle
      如 `.red : .secondary` —— 两分支类型不同，直接编译失败

  R5  withUnsafeMutableBytes 闭包内访问外层变量的属性（含 .count）
      error: overlapping accesses to 'x', but modification requires exclusive access

用法:
    python3 ios/tools/lint_swift.py            # 扫 ios/ 下所有 .swift
    python3 ios/tools/lint_swift.py --verbose
"""
from __future__ import annotations

import os
import re
import sys

# ---------------------------------------------------------------- 已知的合法前导点成员
# SwiftUI 给 ShapeStyle 声明了 where Self == Color / HierarchicalShapeStyle 的扩展，
# 所以这些写法在泛型 ShapeStyle 上下文里是合法的。
STD_COLORS = {
    "clear", "black", "white", "gray", "red", "green", "blue", "orange",
    "yellow", "pink", "purple", "brown", "cyan", "indigo", "mint", "teal",
    "accentColor",
}
HIERARCHICAL = {"primary", "secondary", "tertiary", "quaternary"}
MATERIALS = {
    "ultraThinMaterial", "thinMaterial", "regularMaterial",
    "thickMaterial", "ultraThickMaterial", "bar",
}
SHAPE_STYLE_OK = STD_COLORS | HIERARCHICAL | MATERIALS | {
    "tint", "background", "foreground", "selection", "separator", "link",
    "placeholder", "fill", "windowBackground", "red", "blue",
}

RULES = {
    "R1": "URLComponents / queryItems 拼 URL（'+' 不会被转义 → 1019 参数不能为空）",
    "R2": "[CFString: Any] 字典配 `as String` 键（类型不匹配）",
    "R3": "foregroundStyle(.自定义色)（泛型 ShapeStyle 推不出成员）",
    "R4": "三元两分支类型不同（Color vs HierarchicalShapeStyle）",
    "R5": "withUnsafe* 闭包内访问外层变量属性（独占访问冲突）",
}


def blank_comments_and_strings(src: str) -> str:
    """把注释和字符串内容替换成空格，保留原始行/列位置。"""
    out = list(src)
    i, n = 0, len(src)
    in_str = in_block = False
    while i < n:
        c = src[i]
        if in_block:
            if src.startswith("*/", i):
                out[i] = out[i + 1] = " "
                in_block = False
                i += 2
                continue
            if c != "\n":
                out[i] = " "
            i += 1
            continue
        if in_str:
            if c == "\\" and i + 1 < n:
                out[i] = out[i + 1] = " "
                i += 2
                continue
            if c == '"':
                in_str = False
            elif c != "\n":
                out[i] = " "
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if src.startswith("/*", i):
            out[i] = out[i + 1] = " "
            in_block = True
            i += 2
            continue
        if c == '"':
            in_str = True
        i += 1
    return "".join(out)


def lineno(src: str, pos: int) -> int:
    return src.count("\n", 0, pos) + 1


def check(path: str, src: str):
    """返回 [(行号, 规则号, 说明, 该行原文)]"""
    code = blank_comments_and_strings(src)
    raw_lines = src.splitlines()
    hits = []

    def add(pos, rule, msg):
        ln = lineno(src, pos)
        line = raw_lines[ln - 1].strip() if 0 < ln <= len(raw_lines) else ""
        hits.append((ln, rule, msg, line))

    # R1 —— URLComponents / queryItems
    for m in re.finditer(r"\bURLComponents\b|\.queryItems\b", code):
        add(m.start(), "R1", "改用 LMClient.makeURL(host:path:params:) 或 urlEncode()")

    # R2 —— [CFString: Any]
    for m in re.finditer(r"\[\s*CFString\s*:\s*Any\s*\]", code):
        add(m.start(), "R2", "声明成 [String: Any]")

    # R3 —— foregroundStyle(.自定义)
    for m in re.finditer(r"foregroundStyle\(\s*\.([A-Za-z_][A-Za-z0-9_]*)", code):
        name = m.group(1)
        if name not in SHAPE_STYLE_OK:
            add(m.start(), "R3", f"`.{name}` 不是标准 ShapeStyle 成员 → 写 `Color.{name}`")

    # R4 —— 三元两分支类型不同
    for m in re.finditer(
        r"\?\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\.([A-Za-z_][A-Za-z0-9_]*)", code
    ):
        a, b = m.group(1), m.group(2)
        ca = "H" if a in HIERARCHICAL else ("C" if a in STD_COLORS else "?")
        cb = "H" if b in HIERARCHICAL else ("C" if b in STD_COLORS else "?")
        if {ca, cb} == {"C", "H"}:
            add(m.start(), "R4", f"`.{a}` 与 `.{b}` 类型不同 → 两边都写 Color.*")

    # R5 —— withUnsafeMutableBytes 闭包内访问外层变量
    for m in re.finditer(r"(\w+)\.withUnsafeMutableBytes\s*\{", code):
        var = m.group(1)
        # 取到匹配的闭包结尾（按大括号配对）
        depth, j = 1, m.end()
        while j < len(code) and depth:
            if code[j] == "{":
                depth += 1
            elif code[j] == "}":
                depth -= 1
            j += 1
        body = code[m.end():j]
        for bad in re.finditer(rf"\b{re.escape(var)}\.(\w+)", body):
            add(m.end() + bad.start(), "R5",
                f"闭包内访问 `{var}.{bad.group(1)}` → 提前用 let 取出来")
    return hits


def main() -> int:
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "LeapmotorLite")
    root = os.path.normpath(root)
    verbose = "--verbose" in sys.argv

    files = []
    for dirpath, _, fns in os.walk(root):
        for fn in sorted(fns):
            if fn.endswith(".swift"):
                files.append(os.path.join(dirpath, fn))

    if not files:
        print(f"[x] 没找到 .swift：{root}")
        return 2

    total = 0
    for f in files:
        src = open(f, encoding="utf-8").read()
        hits = check(f, src)
        rel = os.path.relpath(f, os.path.dirname(root))
        if hits:
            total += len(hits)
            print(f"\n{rel}")
            for ln, rule, msg, line in hits:
                print(f"  {rule}  L{ln}: {msg}")
                if line:
                    print(f"          {line}")
        elif verbose:
            print(f"  OK  {rel}")

    print()
    if total:
        print(f"[x] {total} 处命中已知陷阱：")
        for k, v in sorted(RULES.items()):
            print(f"      {k}  {v}")
        return 1

    print(f"lint_swift 通过（{len(files)} 个 .swift，0 命中）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
