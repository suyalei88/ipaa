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

  R6  括号不平衡
      大段重写 View 之后最容易漏一个 } 或 )，编译器报的却是别处的
      `expected '}' in ...`，翻半天。

  R7  同名 static 成员重复声明（跨文件扫 extension）
      invalid redeclaration of 'lmAccent'（把 Color 扩展从 App 挪到 Theme 时忘了删）

  R8  SecureField 上挂 .textContentType(.oneTimeCode)
      iOS 会把刚收到的短信验证码自动填进操作密码框 → 用户看着是自己输的，
      实际提交的是 OTP → 服务端一直回「业务错误 70：操作密码累计出错 3 次以上」。

  R9  视图读了依赖当前时间的锁定状态却没挂 .lmClock(until:now:)
      SwiftUI 不会因为 Date() 变了就重绘 → 倒计时冻在第一帧，
      而且锁定期到期后按钮永远不会重新启用，用户被永久卡死。

  R10 用了系统框架的符号却没 import 那个框架
      Theme.swift 里用 Color(.secondarySystemGroupedBackground) 忘了 import UIKit，
      报的却是一堆指向别处的类型推断错误。加了 MapKit / CoreLocation 之后
      （Map / Marker / CLLocationCoordinate2D / CLGeocoder）这个坑概率大增。

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
    "R6": "括号不平衡（大改之后最容易漏，报 expected '}' / expected ')'）",
    "R7": "同名 static 成员重复声明（invalid redeclaration）",
    "R8": "SecureField 挂 .oneTimeCode（短信验证码会被自动填进去）",
    "R9": "读了依赖当前时间的锁定状态却没挂 .lmClock（倒计时冻住 / 按钮永远禁用）",
    "R10": "用了系统框架的符号却没 import 那个框架（MapKit / CoreLocation / UIKit）",
}

# R10 用：框架 → 该框架里「一眼能认出来」的符号正则
#
# 只放**独属于**该框架的符号。像 `Color` 这种跨 SwiftUI/UIKit 的不要放，
# 否则会满屏误报。
FRAMEWORK_TYPES = {
    "MapKit": [
        r"\bMKCoordinateRegion\b", r"\bMKCoordinateSpan\b", r"\bMKMapView\b",
        r"\bMapCameraPosition\b", r"\bMapInteractionModes\b",
        r"(?<![\w.])Map\s*\(", r"(?<![\w.])Marker\s*\(",
        r"\.mapStyle\s*\(",
    ],
    "CoreLocation": [
        r"\bCLLocationCoordinate2D\b", r"\bCLLocationManager\b",
        r"\bCLGeocoder\b", r"\bCLPlacemark\b", r"\bCLLocation\b",
        r"\bCLAuthorizationStatus\b", r"\bCLGeocodeCompletionHandler\b",
    ],
    "UIKit": [
        r"\bUIPasteboard\b", r"\bUIApplication\b", r"\bUIImage\b",
        r"\bUIDevice\b", r"\bUIScreen\b", r"\bUIColor\b",
    ],
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

    # R6 —— 括号平衡（先按字符扫，字符串/注释已被清空）
    for open_ch, close_ch in (("{", "}"), ("(", ")"), ("[", "]")):
        depth = 0
        for idx, ch in enumerate(code):
            if ch == open_ch:
                depth += 1
            elif ch == close_ch:
                depth -= 1
                if depth < 0:
                    add(idx, "R6", f"多了一个 '{close_ch}'")
                    depth = 0
        if depth:
            add(len(code) - 1, "R6", f"'{open_ch}' 比 '{close_ch}' 多 {depth} 个")

    # R8 —— SecureField 挂 .oneTimeCode
    # iOS 会把刚收到的短信验证码自动填进标了 oneTimeCode 的输入框。
    # 操作密码框一旦被这么污染，用户输入的数字被悄悄替换掉，
    # 服务端就一直回「操作密码错误 / 累计出错 3 次以上」（业务码 70）。
    for m in re.finditer(r"\.textContentType\(\s*\.oneTimeCode\s*\)", code):
        head = code[max(0, m.start() - 400):m.start()]
        last_text = head.rfind("TextField(")
        last_secure = head.rfind("SecureField(")
        if last_secure > last_text:
            add(m.start(), "R8",
                "SecureField 上挂了 .oneTimeCode → 会被短信验证码自动填充；"
                "操作密码请用 .password 或不设")

    # R9 —— 读了「跟当前时间有关」的锁定状态，却没挂 .lmClock
    # SwiftUI 不会因为 Date() 变了就重绘。只读 client.isControlLocked(at:) 的视图
    # 会把倒计时冻在第一帧的数字上，而且锁定期到期后按钮永远不会重新启用
    # （没有任何 @Published 变化触发重绘）—— 用户被永久卡死，比不显示倒计时更糟。
    # 视图必须挂 .lmClock(until:now:) 推一个每秒更新的 now。
    #
    # 定义处（LMClient.swift 里那两行 `func ...`）要放行，否则会误报自己。
    defines_api = "func isControlLocked" in code or "func controlLockRemaining" in code
    if not defines_api and ("isControlLocked(" in code or "controlLockRemaining(" in code):
        if ".lmClock(" not in code:
            idx = code.find("isControlLocked(")
            if idx < 0:
                idx = code.find("controlLockRemaining(")
            add(idx, "R9",
                "读了 isControlLocked/controlLockRemaining（依赖当前时间）但本文件没有"
                ".lmClock(until:now:) → 倒计时会冻住，锁定期到期后按钮不会重新启用")

    # R10 —— 用了某个系统框架的类型，却没 import 那个框架
    #
    # 真烧过一轮：Theme.swift 里用了 Color(.secondarySystemGroupedBackground)
    # 这类 UIKit 桥接 API，忘了 `import UIKit`，报的却是
    #   "cannot find 'UIViewController' in scope" / 类型推断失败 之类
    # 一堆指向别处的错误，翻半天才发现少一行 import。
    #
    # 加了 MapKit / CoreLocation 之后这个坑的概率大幅上升（Map / Marker /
    # CLLocationCoordinate2D / CLGeocoder 全在别的模块里），所以固化成规则。
    for framework, needles in FRAMEWORK_TYPES.items():
        if re.search(rf"^\s*import\s+{framework}\s*$", code, re.M):
            continue
        for needle in needles:
            m = re.search(needle, code)
            if m:
                add(m.start(), "R10",
                    f"用了 {framework} 的符号（{m.group(0)}）但本文件没有 `import {framework}`")
                break
    return hits


def collect_members(files: list[str]) -> list[tuple[str, int, str, str]]:
    """跨文件收集 `extension X { ... static let/var NAME ... }`，找重复声明。

    真实踩过的坑：把 `extension Color { static let lmAccent ... }` 从
    LeapmotorLiteApp.swift 挪到 Theme.swift 时忘了删旧的 →
    "invalid redeclaration of 'lmAccent'"，一轮 CI 白跑。
    """
    decl = re.compile(
        r"extension\s+([A-Za-z_][\w.]*)\s*\{(.*?)\n\}", re.S)
    member = re.compile(r"\bstatic\s+(?:let|var)\s+([A-Za-z_]\w*)")
    seen: dict[tuple[str, str], tuple[str, int]] = {}
    dups: list[tuple[str, int, str, str]] = []
    for f in files:
        src = open(f, encoding="utf-8").read()
        code = blank_comments_and_strings(src)
        for m in decl.finditer(code):
            type_name, body = m.group(1), m.group(2)
            for mm in member.finditer(body):
                name = mm.group(1)
                key = (type_name, name)
                pos = m.start(2) + mm.start()
                ln = lineno(src, pos)
                if key in seen:
                    prev_f, prev_ln = seen[key]
                    dups.append((f, ln, f"{type_name}.{name}",
                                 f"已在 {os.path.basename(prev_f)}:{prev_ln} 声明过"))
                else:
                    seen[key] = (f, ln)
    return dups


def main() -> int:
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "LeapmotorLite")
    root = os.path.normpath(root)
    verbose = "--verbose" in sys.argv

    files = []
    for dirpath, dirs, fns in os.walk(root):
        # ★ os.walk 的遍历顺序跟文件系统有关，不排序的话 Windows / Linux 上
        #   报告顺序不一样，CI 日志和本地对不上，容易看错行。
        dirs.sort()
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
        # 统一成 '/'，Windows 上 os.path.relpath 会给反斜杠
        rel = os.path.relpath(f, os.path.dirname(root)).replace(os.sep, "/")
        if hits:
            total += len(hits)
            print(f"\n{rel}")
            for ln, rule, msg, line in hits:
                print(f"  {rule}  L{ln}: {msg}")
                if line:
                    print(f"          {line}")
        elif verbose:
            print(f"  OK  {rel}")

    dups = collect_members(files)
    if dups:
        total += len(dups)
        print("\n重复的 static 成员（跨文件）")
        for f, ln, name, extra in dups:
            print(f"  R7  {os.path.basename(f)}:L{ln}  {name} —— {extra}")

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
