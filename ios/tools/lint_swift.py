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

  R11 CoreBluetooth 的 delegate 回调里直接写 @Published
      CBCentralManager 的回调**不在主线程**（除非显式传 queue: nil）。
      在回调里写 @Published 会撞 SwiftUI 的
      「Publishing changes from background threads is not allowed」——
      轻则界面不刷新，重则崩溃，而且**编译期完全看不出来**。
      修法二选一：建 manager 时传 `queue: nil`（= 主队列），
      或在每个回调里手动跳主线程。
      触发条件刻意收得很窄：必须同时有 CoreBluetooth delegate 协议
      + @Published + 没有任何主线程保证，才报 —— 避免误伤。

  R12 局部变量名与同文件的方法名同名
      真烧过一轮 CI：`LMClient.swift` 的 `probeBLEKey` 里写了
          let request = [...]          // 想拼一段「请求描述」
      而同一个类里有
          func request(method:path:host:params:body:form:skipAuth:) async throws -> Any
      于是后面 `try await request(method: "GET", ...)` 全被解析成「调用一个 String」，
      报 `error: cannot call value of non-function type 'String'` ——
      错误信息**完全不提遮蔽**，只说不是函数，翻半天。
      Swift 对这类撞名没有任何编译警告，只能靠规则兜。

  R13 Text(...) 里的长 `+` 拼接链
      `Text("a" + "b" + "c" + "d" + …)` 会让 Swift 类型检查器超时：
        error: the compiler is unable to type-check this expression in
        reasonable time; try breaking up the expression into distinct
        sub-expressions
      ★ 2026-10-08 真烧过一轮 CI（ControlPanelView.swift:595）。
      原因不是「字符串太长」，而是 **Text 同时有 LocalizedStringKey 和
      String 两个 init**，而 `+` 又有几十个重载 —— 每个字面量都要参与
      重载推断，候选数随 `+` 的个数指数增长，7 段就足够炸。
      修法：长文案抽成 `-> String` 的计算属性，再 `Text(那个属性)`。
      这个错误本地文本检查 / SwiftLint 都看不出来，只有真编译才暴露，
      而拿到 CI 日志本身就要绕一圈（GitHub 把日志放在 Azure Blob 上），
      所以宁可早拦。

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
    "R10": "用了系统框架的符号却没 import 那个框架（MapKit / CoreLocation / UIKit / CoreBluetooth）",
    "R11": "CoreBluetooth delegate 回调里写 @Published 但没保证主线程（编译期无感，运行时崩/不刷新）",
    "R12": "局部变量名与同文件的方法名同名 → 遮蔽方法调用（报「cannot call value of non-function type」）",
    "R13": "Text(...) 里超过 3 个 `+` 拼接 → Swift 类型检查器超时（抽成 String 计算属性）",
}

# R13 用：Text(...) 参数里允许的最大 `+` 个数。
#   实测 7 段（6 个 `+`）必炸；4~5 段能过但已贴边，所以阈值取 3（= 4 段）。
TEXT_PLUS_LIMIT = 3

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
    "CoreBluetooth": [
        r"\bCBCentralManager\b", r"\bCBPeripheral\b", r"\bCBPeripheralManager\b",
        r"\bCBService\b", r"\bCBCharacteristic\b", r"\bCBUUID\b",
        r"\bCBManagerState\b", r"\bCBCharacteristicProperties\b",
        r"\bCBAdvertisementData[A-Za-z]*\b", r"\bCBCentralManagerOption[A-Za-z]*\b",
        r"\bCBCharacteristicWriteType\b", r"\bCBMutableCharacteristic\b",
    ],
}

# R11 用：CoreBluetooth 的 delegate 协议名
#   CBCentralManager 的回调走它自己的 queue，默认**不是**主队列。
#   （CBPeripheralManager 同理。）
CB_DELEGATE_PROTOCOLS = [
    r"\bCBCentralManagerDelegate\b",
    r"\bCBPeripheralDelegate\b",
    r"\bCBPeripheralManagerDelegate\b",
]

# R11 用：任何一条出现，就说明作者已经处理了线程问题，放行
CB_MAIN_THREAD_PROOF = [
    r"queue\s*:\s*nil",          # CBCentralManager(delegate:queue:options:) 传 nil = 主队列
    r"DispatchQueue\.main",      # 手动跳主线程
    r"@MainActor",               # 类型/方法整体标主 actor
    r"MainActor\.assumeIsolated",# 显式断言
    r"@objc\s+dynamic",          # 少见，但保留
]

# R12 用：这些名字跟同名方法撞了是正常的（协议 / SwiftUI 惯用名），直接放行。
# 不加这个的话每个 `var body: some View` 都会跟 ViewModifier 的
# `func body(content: Content)` 撞上，满屏噪音。
R12_IDIOMATIC = {
    "body", "description", "debugDescription", "hash", "encode", "decode",
    "isEqual", "copy", "init", "main", "callAsFunction",
}


def blank_comments_and_strings(src: str) -> str:
    """把注释和字符串内容替换成空格，保留原始行/列位置。

    ★ 必须认全 Swift 的四种字面量，否则会**静默失步** ——
      失步比误报危险得多：后面的真代码被当成字符串一起吞掉，
      所有规则同时失效，而输出还是「0 命中 通过」。
      真踩过：`#"{"mac":"","version":"2.0"}"#` 这种原始字符串，
      老实现按普通字符串处理，`{` 被吃掉而 `}` 留下来，
      括号平衡（R6）当场就是错的。

    支持：
      · 普通字符串      "..."            （含 \\ 转义，换行即终止）
      · 多行字符串      \"\"\"...\"\"\"       （可跨行，\\ 可转义）
      · 原始字符串      #"..."#  ##"..."##  （# 个数必须配对）
      · 行注释          //
      · 块注释          /* ... */          （Swift 允许嵌套）
    """
    out = list(src)
    i, n = 0, len(src)

    def blank(a: int, b: int) -> None:
        """把 [a, b) 清成空格，但保留换行（行号不能乱）。"""
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c = src[i]

        # ---- 行注释 ----
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
            continue

        # ---- 块注释（Swift 支持嵌套）----
        if src.startswith("/*", i):
            depth, j = 0, i
            while j < n:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                    continue
                if src.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                    continue
                j += 1
            blank(i, j)
            i = min(j, n)
            continue

        # ---- 原始字符串 #"..."# ----
        if c == "#":
            h, j = 0, i
            while j < n and src[j] == "#":
                h += 1
                j += 1
            if j < n and src[j] == '"':
                k = j + 1
                while k < n:
                    if src[k] == '"':
                        m, cnt = k + 1, 0
                        while m < n and src[m] == "#" and cnt < h:
                            cnt += 1
                            m += 1
                        if cnt == h:
                            k = m
                            break
                    k += 1
                blank(i, k)
                i = min(k, n)
                continue

        # ---- 多行字符串 """...""" ----
        if src.startswith('"""', i):
            j = i + 3
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src.startswith('"""', j):
                    j += 3
                    break
                j += 1
            blank(i, j)
            i = min(j, n)
            continue

        # ---- 普通字符串 ----
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    j += 1
                    break
                if src[j] == "\n":
                    break
                j += 1
            blank(i, j)
            i = max(min(j, n), i + 1)
            continue

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

    # R11 —— CoreBluetooth delegate 回调里写 @Published 但没保证主线程
    # CBCentralManager 的 delegate 回调**不在主线程**（除非建的时候传 queue: nil）。
    # 在回调里写 @Published 会撞
    #     "Publishing changes from background threads is not allowed"
    # —— 编译期完全看不出来，轻则界面不刷新，重则崩。
    #
    # 触发条件刻意收得很窄，三条同时满足才报：
    #   ① 文件里出现了 CoreBluetooth 的 delegate 协议
    #   ② 文件里有 @Published
    #   ③ 文件里没有任何主线程保证（queue: nil / DispatchQueue.main / @MainActor …）
    # 这样不会误伤「只扫不发布」或者「已经跳了主线程」的写法。
    if any(re.search(p, code) for p in CB_DELEGATE_PROTOCOLS) and "@Published" in code:
        if not any(re.search(p, code) for p in CB_MAIN_THREAD_PROOF):
            idx = code.find("@Published")
            add(idx, "R11",
                "CoreBluetooth 的 delegate 回调不在主线程，但本文件有 @Published 且没有任何"
                "主线程保证 → 建 manager 时传 `queue: nil`，或在回调里 DispatchQueue.main.async")

    # R12 —— 局部变量遮蔽同文件的方法名
    #
    # 真烧过一轮 CI：LMClient.swift 的 probeBLEKey 里写了
    #     let request = [ ... ]          // 想拼一段「请求描述」
    # 而同一个类里有
    #     func request(method:path:host:params:body:form:skipAuth:) async throws -> Any
    # 于是后面 `try await request(method: "GET", ...)` 全被解析成「调用一个 String」，
    # 报
    #     error: cannot call value of non-function type 'String'
    # 错误信息**完全不提遮蔽**，只说不是函数 —— 不熟悉的话要翻半天。
    #
    # 判定：同文件里出现的 `func 名字(` 与 `let/var 名字` 撞名就报。
    # 这类撞名在 Swift 里没有任何编译警告，属于纯靠人眼容易漏的。
    #
    # ★ 两个约束，都是被误报逼出来的：
    #   ① 只算「函数体内的局部变量」—— 用花括号深度卡（深度 ≥ 2）。
    #      类型层的属性声明深度是 1，典型如 `var body: some View`；
    #      它跟 ViewModifier 里的 `func body(content: Content)` 撞名是
    #      SwiftUI 的常规写法（Theme.swift 就是这样），报出来纯噪音。
    #   ② 名字白名单直接排除 body / hash / encode / decode 这类协议惯用名。
    # 加完这两条之后，剩下的命中基本都是真问题。
    func_names = set(re.findall(r"\bfunc\s+([A-Za-z_]\w*)\s*[<(]", code)) - R12_IDIOMATIC
    if func_names:
        depth = 0
        for m in re.finditer(r"[{}]|\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::|=)", code):
            tok = m.group(0)
            if tok == "{":
                depth += 1
                continue
            if tok == "}":
                depth -= 1
                continue
            name = m.group(1)
            if depth >= 2 and name in func_names:
                add(m.start(), "R12",
                    f"局部变量 `{name}` 与同文件的方法名撞了 → 会遮蔽方法调用，"
                    f"报的却是「cannot call value of non-function type」。改个名")

    # R13 —— Text(...) 里的长 `+` 拼接链
    #
    # ★ 2026-10-08 真烧过一轮 CI：
    #     ControlPanelView.swift:595:9: error: the compiler is unable to
    #     type-check this expression in reasonable time; try breaking up the
    #     expression into distinct sub-expressions
    #
    #   原因**不是**「字符串太长」，而是：
    #     · `Text` 同时有 `LocalizedStringKey` 和 `String` 两个 init
    #     · `+` 在 Swift 里有几十个重载（String / Int / Double / Array …）
    #   于是 `Text("a" + "b" + … + "g")` 里每个字面量都要参与重载推断，
    #   候选数随 `+` 的个数**指数增长**，7 段拼接就足够让类型检查器超时。
    #
    #   修法（已在本仓库落地）：把长文案抽成 `-> String` 的计算属性，再
    #   `Text(那个属性)`。类型被注解钉死成 String 之后，推断是线性的。
    #
    #   阈值取 3（= 4 段）而不是 6：实测 4~5 段能编过但已经很贴边，
    #   而且这个错误**本地静态检查、SwiftLint 都看不出来**，只有真编译才暴露，
    #   排查成本极高（要先拿到 CI 日志）。宁可早一点拦住。
    #
    #   注意：`code` 里的字符串已被清成空格，所以这里数到的 `+` 一定是
    #   真正的拼接运算符，不是字符串内容。
    for m in re.finditer(r"\bText\s*\(", code):
        start = m.end() - 1          # 指向 '('
        depth, j, plus = 0, start, 0
        while j < len(code):
            ch = code[j]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
                if depth == 0:
                    break
            elif ch == "+" and depth == 1:
                plus += 1
            j += 1
        if plus >= TEXT_PLUS_LIMIT:
            add(m.start(), "R13",
                f"Text(...) 里有 {plus} 个 `+`（{plus + 1} 段拼接）→ "
                f"Swift 类型检查器可能超时；抽成 `-> String` 的计算属性再 Text(它)")

    # R10 —— 用了某个系统框架的类型，却没 import 那个框架
    #
    # 真烧过一轮：Theme.swift 里用了 Color(.secondarySystemGroupedBackground)
    # 这类 UIKit 桥接 API，忘了 `import UIKit`，报的却是
    #   "cannot find 'UIViewController' in scope" / 类型推断失败 之类
    # 一堆指向别处的错误，翻半天才发现少一行 import。
    #
    # 加了 MapKit / CoreLocation / CoreBluetooth 之后这个坑的概率大幅上升
    # （Map / Marker / CLLocationCoordinate2D / CLGeocoder / CBPeripheral
    #   全在别的模块里），所以固化成规则。
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
    """收集各**类型体**内的 `static let/var NAME`，找同名重复声明。

    真实踩过的两个坑：
    ① 把 `extension Color { static let lmAccent ... }` 从 LeapmotorLiteApp.swift
       挪到 Theme.swift 时忘了删旧的 → "invalid redeclaration of 'lmAccent'"。
    ② ★ 2026-10-08：给 `LMEndpoints.Path` 加 `static let chassis` 时，
       在「杂项」分组和带注释的正式位置**各加了一遍** →
       "invalid redeclaration of 'chassis'" + "ambiguous use of 'chassis'"，
       本地文本闸门全绿、CI 编译才炸，白跑一轮。

    旧版只认 `extension X { ... }`，所以 ② 那种写在 `enum` 里的漏了。
    新版改成**按括号深度跟踪类型栈**，enum / struct / class / actor / extension
    一律覆盖。
    """
    typedecl = re.compile(r"\b(extension|enum|struct|class|actor)\s+([A-Za-z_][\w.]*)")
    member = re.compile(r"\bstatic\s+(?:let|var)\s+([A-Za-z_]\w*)")
    brace = re.compile(r"[{}]")
    # 类型声明与它那个 `{` 之间隔太远就不认（避免把没配对的声明粘到后面的闭包上）
    MAX_GAP = 300

    seen: dict[tuple[str, str], tuple[str, int]] = {}
    dups: list[tuple[str, int, str, str]] = []

    for f in files:
        src = open(f, encoding="utf-8").read()
        code = blank_comments_and_strings(src)

        events: list[tuple[int, str, str]] = []
        for m in brace.finditer(code):
            events.append((m.start(), "brace", m.group(0)))
        for m in typedecl.finditer(code):
            events.append((m.start(), "type", m.group(2)))
        for m in member.finditer(code):
            events.append((m.start(), "member", m.group(1)))
        events.sort(key=lambda x: x[0])

        depth = 0
        # [(depth, 类型名)]，类型名可能是 None（普通代码块）
        stack: list[tuple[int, str | None]] = []
        pending: tuple[str, int] | None = None   # (类型名, 声明结束位置)

        for pos, kind, val in events:
            if kind == "type":
                pending = (val, pos + len(val))
            elif kind == "brace" and val == "{":
                name = None
                if pending and pos - pending[1] <= MAX_GAP:
                    name = pending[0]
                pending = None
                depth += 1
                stack.append((depth, name))
            elif kind == "brace" and val == "}":
                while stack and stack[-1][0] >= depth:
                    stack.pop()
                depth = max(0, depth - 1)
            else:  # member
                enclosing = next((n for _, n in reversed(stack) if n), None)
                if enclosing is None:
                    continue
                key = (enclosing, val)
                ln = lineno(src, pos)
                if key in seen:
                    prev_f, prev_ln = seen[key]
                    dups.append((f, ln, f"{enclosing}.{val}",
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
