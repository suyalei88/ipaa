#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_refresh_contract.py —— 守住「登录态自动续期」这条链路的契约。

为什么需要它：
    续期是**唯一一条没有任何抓包样本**的链路（三份 HAR 里都没有 /token/v1/refresh），
    全部结论来自官方主二进制逆向。这种「靠逆向撑起来」的代码最怕两件事：
      ① 后人觉得 `/base/base-user` 前缀多余，把它「清理」成 `/token/v1/refresh` → 续期静默失效；
      ② 有人给 LMSession 加一个**非 Optional** 字段 → Keychain 里的老会话解不出来 →
         升级即掉登录，正好和这次要修的问题相反（Swift 合成的 init(from:) 不认属性默认值）。

    这两条都不会被编译器抓住，所以在这里钉死。

    python client/test_refresh_contract.py
"""
from __future__ import annotations

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
APP = os.path.join(ROOT, "ios", "LeapmotorLite", "LeapmotorLite")

sys.path.insert(0, HERE)
from leapmotor_client import derive_sign_key  # noqa: E402

FAILS: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not ok else ""))
    if not ok:
        FAILS.append(name)


def read(rel: str) -> str:
    with open(os.path.join(APP, rel), "r", encoding="utf-8") as f:
        return f.read()


# ============================================================
# 1. 端点契约
# ============================================================
def test_endpoint() -> None:
    print("\n[1] 续期端点")
    src = read("API/LMEndpoints.swift")
    m = re.search(r'static\s+let\s+refreshToken\s*=\s*"([^"]+)"', src)
    check("LMEndpoints.Path.refreshToken 存在", m is not None)
    if not m:
        return
    path = m.group(1)
    # ★ 前缀是逆向出来的：主二进制路径表里裸路径是 /token/v1/refresh，
    #   服务名前缀 /base/base-user 是运行时拼的（@0xAA33D8E 与 @0xAA33E05 相邻）。
    check("续期路径带 /base/base-user 前缀",
          path == "/base/base-user/token/v1/refresh", f"实际 {path!r}")
    check("续期路径以 /token/v1/refresh 结尾", path.endswith("/token/v1/refresh"), path)


# ============================================================
# 2. LMSession 的 Codable 向后兼容
# ============================================================
def test_session_codable() -> None:
    print("\n[2] LMSession 字段必须 Optional（Keychain 向后兼容）")
    src = read("API/LMClient.swift")
    m = re.search(r"struct\s+LMSession\s*:\s*Codable[^{]*\{(.*?)\n\}", src, re.S)
    check("找得到 struct LMSession", m is not None)
    if not m:
        return
    body = m.group(1)

    for field in ("tokenExpireTime", "refreshTokenExpireTime", "tokenIssuedAt"):
        fm = re.search(rf"var\s+{field}\s*:\s*([^\n=]+)", body)
        check(f"{field} 已声明", fm is not None)
        if fm:
            t = fm.group(1).strip()
            check(f"{field} 是 Optional（{t}）", t.endswith("?"), t)

    # 反向检查：除了已知安全的字段，不应再出现新的非 Optional 存储属性
    known_ok = {
        "accessToken", "signKeyHex", "encryptKeyHex",
        "refreshToken", "userId", "accountId", "nickname", "opPassword",
    }
    for fm in re.finditer(r"var\s+(\w+)\s*:\s*([A-Za-z_][\w<>\[\]: ,\.]*)\s*(?:=\s*[^\n]+)?$",
                          body, re.M):
        name, typ = fm.group(1), fm.group(2).strip()
        if name in known_ok:
            continue
        # 计算属性（有 { ）不算存储属性
        tail = body[fm.end():fm.end() + 4]
        if tail.lstrip().startswith("{"):
            continue
        check(f"新增存储属性 {name} 必须是 Optional", typ.endswith("?"), typ)


# ============================================================
# 3. 续期请求体与触发点
# ============================================================
def test_request_shape() -> None:
    print("\n[3] 续期请求体 / 签名 / 触发点")
    src = read("API/LMClient.swift")

    check("performRefresh 用 refreshToken 作为 body 键",
          re.search(r'body:\s*\[\s*"refreshToken"\s*:', src) is not None)

    # ★★ 2026-10-08 实测定论：续期**不能**用登录那条无密钥 SHA256 ——
    #    服务端会回 {"code":302002002,"message":"签名信息校验失败"}；
    #    换成 HMAC(旧 signKey) 才回 code:0。所以这里必须钉住「走 HMAC 签名路径」，
    #    防止后人「顺手统一成 preLoginRequest」把续期改回坏的。
    check("续期走 signedPost（HMAC 签名 + token 头）",
          re.search(r"signedPost\(path:\s*LMEndpoints\.Path\.refreshToken", src) is not None)
    check("续期不再用 preLoginRequest（无密钥 SHA256 已实测失败）",
          re.search(r"preLoginRequest\(path:\s*LMEndpoints\.Path\.refreshToken", src) is None)
    check("signedPost 用 buildHeaders（内含 signKey HMAC）",
          re.search(r"private func signedPost[\s\S]{0,600}?buildHeaders\(", src) is not None)
    check("signedPost 挂在 login 之外（不触发续期钩子，避免递归）",
          "throwsOnBusinessError: false" in src)

    check("有并发去重（refreshTask）", "private var refreshTask" in src)
    check("request(...) 会主动续期",
          re.search(r"await\s+refreshSessionIfNeeded\(\)", src) is not None)
    check("request(...) 有被动重放",
          re.search(r"looksLikeTokenExpired", src) is not None
          and src.count("sendWithFreshHeaders") >= 3)
    check("401/403 被当作 token 失效", "code == 401 || code == 403" in src)


# ============================================================
# 3b. 3D 车模：离线包必须在 bundle 里，且工程把它按 folder 引用
#     —— 官方查看器用 `new Worker("./FBX.worker.js")` 在 worker 里解析 FBX，
#        且模型路径是写死的 './D19_2026/D19_2026_full_car.fbx'，
#        所以 bundle 内的目录结构必须原样保留，不能被打平。
# ============================================================
def test_car3d_assets() -> None:
    print("\n[3b] 3D 车模离线包")

    assets = os.path.join(APP, "Car3D")
    need = [
        "index.html",
        "index.js",
        "FBX.worker.js",
        "D19_2026/D19_2026_full_car.fbx",
        "D19_2026/D19_2026_starter_car.fbx",
        "D19_2026/D19_2026_CarPaintConfig.csv",
    ]
    for rel in need:
        p = os.path.join(assets, *rel.split("/"))
        ok = os.path.isfile(p)
        size = os.path.getsize(p) if ok else 0
        check(f"资源存在 {rel}", ok and size > 0, f"{size} B")

    # index.js 必须是「零 import/export」的 IIFE 包 —— 我们据此判断它可以
    # 不依赖 ESM 加载（也是本地 HTTP 方案之外的退路依据）
    idx = os.path.join(assets, "index.js")
    if os.path.isfile(idx):
        with open(idx, "r", encoding="utf-8", errors="replace") as f:
            js = f.read()
        check("index.js 无 ESM import/export",
              len(re.findall(r"(?m)^\s*(?:import|export)[\s{*]", js)) == 0)
        check("index.js 导出 newInit 入口", "window.newInit=newInit" in js)
        check("index.js 有 OrbitControls 阻尼/旋转参数（全方位旋转）",
              "enableDamping" in js and "rotateSpeed" in js)

    # 工程必须用 folder 引用（不是逐文件），否则 .js/.fbx 不会被打进 bundle
    pbx = os.path.join(ROOT, "ios", "LeapmotorLite", "LeapmotorLite.xcodeproj", "project.pbxproj")
    if os.path.isfile(pbx):
        with open(pbx, encoding="utf-8") as f:
            p = f.read()
        check("pbxproj 里有 Car3D folder 引用",
              "lastKnownFileType = folder; path = Car3D;" in p)
        check("Car3D 进了 Resources build phase", "Car3D in Resources" in p)

    # 入口：爱车页必须同时挂上「内嵌车模」和「全屏看车」
    # ★ 2026-10-09：爱车页已从 SwiftUI 迁成 UIKit（LMLoveCarViewController）。
    love = read("UIKit/LMLoveCarViewController.swift")
    check("爱车页内嵌了 3D 车模（LMCar3DWebView 直接出现在本页）",
          "LMCar3DWebView(" in love)
    check("爱车页保留了全屏看车入口",
          "LMCar3DViewController(client: client)" in love)

    # ATS 必须放开本地回环（Car3DServer 走 http://127.0.0.1）
    plist = read("Support/Info.plist")
    check("Info.plist 放开 NSAllowsLocalNetworking", "NSAllowsLocalNetworking" in plist)

    srv = read("Support/Car3DServer.swift")
    check("本地服务只绑回环", "requiredInterfaceType = .loopback" in srv)
    check("本地服务有目录穿越防护", '".."' in srv or "'..'" in srv)


# ============================================================
# 4. 响应解析必须同时吃「嵌套」和「扁平」两种形状
#     —— 官方登录 SDK 就是这么写的（主二进制 0x106E82B34 起，
#        每个字段都成对出现：data.signParam.r2 / signR2 …）
# ============================================================
DEMO_TOKEN = (
    "eyJub25jZSI6ImEyNzEwYjZkNDgwNDQ2ZTlhMjExOGI2YjIzZmQ3MDU3IiwiYWxnIjoiSFMyNTYiLCJ0eXAiOiJKV1QifQ"
    ".eyJ1c2VyX25hbWUiOiJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2LDEsZGV2aWNlSWQ6aW9zX2VlNDViOWQ4MzBi"
    "YjEyNmQ0MzFlOTk4OTQzYTc3OTdhLHBhc3N3b3JkOiIsInNjb3BlIjpbInJlYWQiXSwiZXhwIjoxNzkxMzU3ODExLCJhdXRo"
    "b3JpdGllcyI6WyJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2Il0sImp0aSI6IjJlZDE3MjcyLTBmOTktNDcwNy04MTE3"
    "LTU3OGYxMTAyYWI1NiIsInNpZ25fdGltZSI6MTc5MTM1MDYxMSwiY2xpZW50X2lkIjoiSHpUbWNzQmcifQ"
    ".y9ncviOjBWW1YSTbjf0RRJVB4_cWJIOAufJ-ZU7Ci1I"
)
SIGN_R2 = "6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo="
SIGN_R3 = "XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884="


def resolve_r2r3(payload: dict) -> tuple[str, str]:
    """复刻 Swift 里 adoptLoginResponse 的 r2/r3 解析：点路径优先，扁平键兜底。"""
    sp = payload.get("signParam") or {}
    r2 = sp.get("r2") or payload.get("signR2")
    r3 = sp.get("r3") or payload.get("signR3")
    return r2, r3


def test_response_shapes() -> None:
    print("\n[4] 续期响应两种形状都要能解析")
    nested = {"accessToken": DEMO_TOKEN, "refreshToken": "rt", "tokenExpireTime": 7199,
              "signParam": {"r2": SIGN_R2, "r3": SIGN_R3}}
    flat = {"accessToken": DEMO_TOKEN, "refreshToken": "rt", "tokenExpireTime": 7199,
            "signR2": SIGN_R2, "signR3": SIGN_R3}

    n = resolve_r2r3(nested)
    f = resolve_r2r3(flat)
    check("嵌套形状解出 r2/r3", all(n), str(n))
    check("扁平形状解出 r2/r3", all(f), str(f))
    check("两种形状 r2/r3 一致", n == f)

    if all(n):
        kn = derive_sign_key(DEMO_TOKEN, *n).hex().upper()
        kf = derive_sign_key(DEMO_TOKEN, *f).hex().upper()
        check("两种形状派生出同一个 signKey", kn == kf, f"{kn} vs {kf}")
        check("signKey 与已知样本一致",
              kn == "7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566", kn)


# ============================================================
# 3c. 「爱车」页完整复刻
#     —— 官方爱车页（已绑车态）的模块顺序是固定的，而且每一块都有实测数据源。
#        这一节钉住「模块没被删掉」「快捷操作分页没被压平」
#        「没拿假数据冒充官方那一块（驻车照片）」。
# ============================================================
def test_lovecar_page() -> None:
    print("\n[3c] 爱车页完整复刻")
    # ★ 2026-10-09：已从 SwiftUI（Views/LoveCarView.swift）迁成 UIKit。
    love = read("UIKit/LMLoveCarViewController.swift")

    # ① 官方爱车页的模块（顺序即官方截图顺序）
    #    ★ UIKit 版里模块从「`private var xxx` 计算属性」变成
    #      「`private let xxx` 控件属性 + `buildXxx()` 方法」，
    #      断言按真实形态写（盯被测对象，不盯旧写法）。
    modules = [
        ("顶部车辆栏", "private func buildTopBar()"),
        ("续航主数字 + SOC 进度条 + 车门锁态", "private let rangeHero"),
        ("充电中心入口", "private let chargeCenterChip"),
        ("3D 车模（内嵌）", "private func buildCar3D()"),
        ("快捷操作分页", "private func buildPager()"),
        ("预约充电横幅", "private let appointmentBanner"),
        ("车内温度 / 空调", "private let climateCard"),
        ("地图卡", "private let mapCard"),
        ("蓝牙钥匙卡", "private let bleCard"),
    ]
    for label, token in modules:
        check(f"模块在：{label}", token in love)

    # ② 快捷操作第 1 页必须与官方截图逐字一致
    m = re.search(r"let\s+pages:\s*\[\[String\]\]\s*=\s*\[\s*\n?\s*\[([^\]]*)\]", love)
    check("找得到快捷操作分页定义", m is not None)
    if m:
        page1 = [s.strip().strip('"') for s in m.group(1).split(",") if s.strip()]
        check("快捷操作第 1 页 = 解锁/上锁/后备箱/车窗（与官方截图一致）",
              page1 == ["lock", "unlock", "trunk_open", "window"], str(page1))

    # ③ 车窗必须走三档（关闭 / 微开 / 半开），不是单一开关
    check("车窗用 WindowOpening 全量枚举（三档）",
          "LMEndpoints.WindowOpening.allCases" in love)
    check("车窗走 cmdid 230 的 controlRaw",
          "LMEndpoints.windowCmdid" in love and "windowState(" in love)

    # ④ 3D 内嵌卡必须把真实宽度喂给官方查看器（否则车会被裁切）
    #    ★ UIKit 没有 GeometryReader，等价物是「容器实际宽度 / 兜底宽度」。
    check("内嵌车模按容器实际宽度喂 Car3DConfig.appJSON(width:height:)",
          re.search(r"Car3DConfig\.appJSON\(width:[\s\S]{0,60}?height:\s*car3DHeight\)", love)
          is not None)

    # ⑤ ★★ 2026-10-09 **反转了这条断言**。
    #    原来写的是「**不能**把『驻车照片』做成 UI 元素」——
    #    理由是当时那个接口在 IPA 字符串表里扫不到、四份 HAR 里也没有样本，
    #    所以宁可留空，不拿假图糊上去。
    #
    #    现在接口**已确认**，证据是硬的：
    #      GET /carownerservice/v3/api/chassis/query?vin=<VIN>
    #      → data.fileUrl（OSS 直链）+ data.uploadTime
    #      （evidence/har_appgw.har #42 请求 + #38 图片本体）
    #    图片也已存盘：evidence/car3d/chassis.jpg（地下停车场俯视哨兵照）。
    #
    #    功能落在**定位页**（LMLocationViewController），不在爱车页 ——
    #    官方把这块放在地图页内部，我们放在「车辆定位」页更顺手，
    #    也避免同一张图两处维护。所以下面两条断言一正一反。
    loc = read("UIKit/LMLocationViewController.swift")
    check("爱车页不放驻车照片（统一放定位页，避免两处维护）",
          "驻车照片" not in love)
    check("定位页确实做了驻车照片（接口已确认，不再是「明确不做」）",
          "驻车照片" in loc)

    # ⑥ lint R9：读了锁定态就必须挂时钟，否则倒计时冻住
    #    ★ SwiftUI 版的等价物 `.lmClock(until:)` 是修饰符；
    #      UIKit 版是 target/selector 版 Timer（block 版收 @Sendable 闭包，
    #      不继承 @MainActor 隔离，会编译报错）+ `.common` 模式。
    check("挂了 target/selector 版 Timer 驱动锁定倒计时",
          re.search(r"Timer\(timeInterval:[\s\S]{0,200}?selector:\s*#selector\(lockTick\)", love)
          is not None and "forMode: .common" in love)

    # ⑦ Tab 必须换成爱车页，旧的车况页不能留
    tabs = read("UIKit/LMMainTabBarController.swift")
    check("首 Tab 是 LMLoveCarViewController",
          "LMLoveCarViewController(client: client)" in tabs)
    check("Tab 标签叫「爱车」", '"爱车"' in tabs)
    check("旧 DashboardView 已移除", not os.path.exists(os.path.join(APP, "Views", "DashboardView.swift")))
    check("代码里没有 DashboardView 残留",
          "DashboardView" not in tabs and "DashboardView" not in love)

    # ⑧ ★ Car3DConfig.serverJSON 必须标 @MainActor
    #     LMClient 是 @MainActor 隔离的，而 static func 没有任何隔离推断来源。
    #     漏了这个标注，CI 编译期会直接报：
    #       main actor-isolated property 'car3DKey' can not be referenced
    #       from a non-isolated context
    #    2026-10-08 真烧过一轮 CI。lint 的 R14 也会拦，这里是双保险。
    #    ★ 2026-10-09：`Car3DConfig` 随迁移搬到了 `UIKit/LMCar3DWebView.swift`。
    c3d = read("UIKit/LMCar3DWebView.swift")
    check("Car3DConfig.serverJSON 标了 @MainActor（否则 CI 报 actor 隔离错误）",
          re.search(r"@MainActor\s*\n\s*static func serverJSON\(", c3d) is not None)


def test_location_source() -> None:
    """⑨ 定位数据源：**本机 GPS + 车机坐标**，不再用 IP 归属地。

    历史（两次方向相反的修复，别把结论搞混）：
      · 2026-10-08 用户报「官方显示淮南、本 App 显示合肥」。
        当时的修复是**把主位置改成 IP 归属地**
        （`GET apptec.leapmotor.cn/ipAnalysis/getAddressByIp`），
        依据是车机 signalMap 的 `2190/2191` 在 60 个抓包样本里一个数字都没变过。
      · ★ 2026-10-09 用户**要求撤掉这一套**：
        「把当前位置取消掉 改回之前的」
        +「把车辆定位内部加入本机 GPS 位置和车辆位置同时加入」。
        理由：IP 归属地是「服务端认为手机连的网在哪」—— 只精确到城市，
        WiFi 专线 / 代理 / 开热点都会把它指到别的城市；而且它出现在
        「车辆定位」页最上面，很容易被当成「车在哪」。

    现在的规则（本函数钉死）：
      · 定位页**同时**有「我的位置（本机 GPS）」和「车辆位置（车机坐标）」；
      · UI 层**不许**再读 `client.ipAddress`；
      · `probeIpAddress()` 保留（诊断页的排查工具，有独立抓包样本），
        但轮询版 `refreshIPAddress()` 已删除，不再每次刷新都发这个请求；
      · ★ 新增：驻车照片（`chassis/query` → `fileUrl`）。

    ⚠️ 断言写法纪律：只匹配**真实代码形态**，不要写
       `"ipSourceNote" not in love` 这种 —— 注释里必然会提到这个名字
       （解释「为什么撤掉」时就要写），会变成假阳性。同一类坑踩过四次了。
    """
    print("\n[9] 定位数据源（本机 GPS + 车机坐标，撤掉 IP 归属地）")

    client = read("API/LMClient.swift")
    models = read("API/LMModels.swift")
    love = read("UIKit/LMLoveCarViewController.swift")
    loc = read("UIKit/LMLocationViewController.swift")
    ep = read("API/LMEndpoints.swift")

    # ── 端点 / 模型：都保留（诊断页要用，也是历史证据）─────────────────
    check("端点表里仍保留 IP 归属地路径（诊断用）",
          "/ipAnalysis/getAddressByIp" in ep)
    check("IP 归属地仍走 tecHost（apptec.leapmotor.cn）",
          "tecHost" in ep and "apptec.leapmotor.cn" in ep)
    check("LMIPAddress 仍保留 regionText（诊断页会显示）",
          re.search(r"var regionText: String", models) is not None)

    # ── ★ 关键：IP 归属地不再进轮询 ────────────────────────────────
    check("refreshAll 里不再 await refreshIPAddress",
          "await refreshIPAddress()" not in client)
    check("轮询版 refreshIPAddress 已删除（否则是 unused private，编译器会警告）",
          re.search(r"func refreshIPAddress", client) is None)
    check("诊断用的 probeIpAddress 保留",
          re.search(r"func probeIpAddress\(", client) is not None)

    # ── ★ 关键：UI 层不许再读 ipAddress（匹配代码形态，不是注释）──────
    check("爱车页不再读 client.ipAddress（代码里）",
          re.search(r"if let ip = client\.ipAddress", love) is None)
    check("定位页不再读 client.ipAddress（代码里）",
          re.search(r"if let ip = client\.ipAddress", loc) is None)
    check("爱车页不再声明 ipSourceNote 控件",
          re.search(r"private let ipSourceNote", love) is None)
    check("定位页不再声明 ipCard / ipHeader 控件",
          re.search(r"private let ip(Card|Header|ContentStack)\b", loc) is None)
    check("定位页不再有 buildIPCard / renderIP / probeIPTapped",
          re.search(r"func (buildIPCard|renderIP|probeIPTapped)\b", loc) is None)

    # ── ★ 新规则：定位页同时有「本机 GPS」和「车辆位置」──────────────
    check("定位页有「我的位置（本机 GPS）」标题",
          "我的位置（本机 GPS）" in loc)
    check("定位页声明了本机位置卡片控件",
          re.search(r"private let mePosCard\b", loc) is not None)
    check("定位页有 renderMePosition",
          re.search(r"func renderMePosition\(", loc) is not None)
    check("本机位置真的读 me.coordinate（LMLocationProvider）",
          re.search(r"func renderMePosition\(\)[\s\S]{0,900}?me\.coordinate", loc) is not None)
    check("本机位置与「距我多远」同源（都用 LMLocationProvider 实例 me）",
          re.search(r"private let me = LMLocationProvider\(\)", loc) is not None)
    check("定位页仍然有车辆位置（地址卡 caption）", "车辆位置" in loc)
    check("定位页 render() 同时调用两个位置渲染",
          re.search(r"renderMePosition\(\)", loc) is not None
          and re.search(r"renderAddress\(\)", loc) is not None)

    # ── ★ 爱车页地图卡改回车机坐标 ────────────────────────────────
    check("爱车页地图卡改回车机坐标（renderMap 里读 client.coordinate）",
          re.search(r"func renderMap\(\)[\s\S]{0,700}?client\.coordinate", love) is not None)
    check("打开地图改回按车机坐标（openInMaps 里读 client.coordinate）",
          re.search(r"func openInMaps\(\)[\s\S]{0,700}?client\.coordinate", love) is not None)
    check("定位页说明了车机坐标可能长期不变", "一个数字都没动" in loc)

    # ── 车端未分享位置的提示（复刻官方原话）─────────────────────────
    tip = "车端已关闭位置数据分享，无法获取车辆实时位置"
    check("爱车页复刻了官方「车端已关闭位置数据分享」提示", tip in love)
    check("定位页复刻了同一句提示", tip in loc)
    check("该判断用可观测事实（坐标长期不变）而非猜 privacyGPS 语义",
          re.search(r"var carLocationShareOff[\s\S]{0,700}?coordinateUnchangedFor",
                    client) is not None)

    # ── ★★ 驻车照片（2026-10-09 新增）────────────────────────────
    #
    # 用户要求「找出驻车照片和驻车位置」。
    # 证据：`evidence/har_appgw.har` #42 / #38 ——
    #   GET /carownerservice/v3/api/chassis/query?vin=<VIN>
    #   → data.fileUrl（OSS 直链）+ data.uploadTime
    #   → 下载得到地下停车场俯视哨兵照（856×1296，已存 evidence/car3d/chassis.jpg）
    # 旁证：官方主二进制 LMVMapParkingSnapService / queryParkSnapComleteBlock: /
    #       LMVMapParkingSnapView / LMVParkPhotoBrowserView / LMVParkBusinessModel。
    check("chassis 端点路径在端点表里",
          "/carownerservice/v3/api/chassis/query" in ep)
    check("LMClient 暴露 parkingSnap 状态",
          re.search(r"var parkingSnap: LMParkingSnap\?", client) is not None)
    check("LMClient 有 refreshParkingSnap()",
          re.search(r"func refreshParkingSnap\(", client) is not None)
    check("LMClient 有 downloadParkingSnapImage()",
          re.search(r"func downloadParkingSnapImage\(", client) is not None)
    check("LMParkingSnap 读 fileUrl",
          re.search(r"struct LMParkingSnap[\s\S]{0,1200}?fileUrl", models) is not None)
    check("LMParkingSnap 把 uploadTime 毫秒时间戳转成 Date",
          re.search(r"struct LMParkingSnap[\s\S]{0,1400}?timeIntervalSince1970", models) is not None)
    check("定位页有驻车照片卡片",
          re.search(r"private let snapCard\b", loc) is not None)
    check("定位页有 buildSnapCard / renderSnap",
          re.search(r"func buildSnapCard\(", loc) is not None
          and re.search(r"func renderSnap\(", loc) is not None)
    check("驻车照片卡里同时给出驻车位置（车机坐标）",
          re.search(r"func renderSnap\(\)[\s\S]{0,1200}?carCoordinate", loc) is not None)
    check("图片高度约束在没图时被关掉（否则 stack 会留 260pt 空白）",
          re.search(r"snapHeightConstraint\?\.isActive", loc) is not None)

    # ---- ★★ 2026-10-09 第二轮：用户报「驻车照片获取报下载失败」----
    #
    # 根因：车端返回的 `fileUrl` **是明文 http://**（实测 `har_appgw.har` #42）：
    #   http://lp-carnet.oss-cn-hangzhou.aliyuncs.com/ChassisPicture/prod/<VIN>?Expires=…&Signature=…
    # 而本 App `NSAllowsArbitraryLoads = false` → ATS 直接掐掉请求。
    # 两处一起修，缺一条都还会失败，所以两条都钉死。
    plist = read("Support/Info.plist")
    check("ATS 给 aliyuncs.com 开了窄口径明文例外（驻车照片走 OSS http 直链）",
          re.search(r"NSExceptionDomains[\s\S]{0,600}?aliyuncs\.com", plist) is not None
          and re.search(r"NSExceptionAllowsInsecureHTTPLoads", plist) is not None)
    check("没有图省事打开 NSAllowsArbitraryLoads（那等于全关 ATS）",
          re.search(r"<key>NSAllowsArbitraryLoads</key>\s*<false/>", plist) is not None)
    check("下载时优先把 http 换成 https 再试（OSS 支持 https，且 scheme 不参与签名）",
          re.search(r"switchingScheme\([\s\S]{0,300}?\"https\"", client) is not None)
    check("https 失败会回退原地址（不因为换 scheme 就彻底失败）",
          re.search(r"candidates\.append\(url\)", client) is not None)
    check("下载用 URLRequest 并设了超时（不再是裸 data(from:)）",
          re.search(r"var req = URLRequest\(url: candidate\)[\s\S]{0,200}?timeoutInterval", client) is not None)
    check("下载会检查 HTTP 状态码（非 2xx 算失败）",
          re.search(r"200\.\.<300\)\.contains\(http\.statusCode\)", client) is not None)
    check("URL 解析有百分号编码兜底（OSS 偶尔回未编码串）",
          re.search(r"func parseSnapURL\(", client) is not None
          and re.search(r"addingPercentEncoding\(withAllowedCharacters", client) is not None)
    check("下载失败信息带上了试过几个地址 + 真实原因（方便定位）",
          re.search(r"parkingSnapError = \"图片下载失败（\\\(candidates\.count\)", client) is not None)


def test_charging_center() -> None:
    """⑩ 充电中心可写：四个 cmdid 全部来自官方主二进制反汇编。

    背景（2026-10-09 用户报）：`ChargeView` 之前是纯只读展示页，
    用户要求「能直接在 App 设置预约充电 / 健康充电 / 立即充电 / 结束充电」。

    这四个 cmdid **一个都没有抓包样本**（抓包里 POST `appremotectl` 只有
    110/120/130/170/230/400 这 6 个已知值），所以结论全部来自反汇编：
    从 `__objc_methname` 取 selector → `__objc_selrefs`（chained fixups，
    磁盘上是 0，必须解析 `LC_DYLD_CHAINED_FIXUPS` 才还原）→ `__objc_stubs`
    → 在 `__text` 里找 `bl <stub>` → 反汇编那个大 switch。

    下面把这些数字钉死。**它们改一个就全盘失效**，而失效方式是「指令发出去了、
    车端按另一个语义执行」—— 比编译错误危险得多，所以必须由测试守住。
    """
    print("\n[10] 充电中心可写（cmdid 反汇编实证）")

    ep = read("API/LMEndpoints.swift")
    client = read("API/LMClient.swift")
    # ★ 2026-10-09：充电中心已从 SwiftUI（Views/ChargeView.swift）迁成 UIKit。
    view = read("UIKit/LMChargeViewController.swift")

    # ---- cmdid 取值 ----
    m = re.search(r"enum\s+ChargeCmdid\s*\{(.*?)\n\s*\}", ep, re.S)
    check("LMEndpoints 里有 enum ChargeCmdid", m is not None)
    if m:
        body = m.group(1)
        for name, val in (("socLimit", 190), ("startOrStop", 193),
                          ("health", 480), ("appointment", 161)):
            mm = re.search(rf"static\s+let\s+{name}\s*=\s*(\d+)", body)
            check(f"ChargeCmdid.{name} = {val}",
                  mm is not None and int(mm.group(1)) == val,
                  f"实际 {mm.group(1) if mm else '缺失'}")

    # ---- 端点 ----
    check("端点表里有预约充电设置路径 appremotectl/appointment（不带 get）",
          re.search(r'appointmentSet\s*=\s*"/carownerservice/v3/api/appremotectl/appointment"', ep)
          is not None)
    check("端点表里有健康充电控制路径 healthyCharging/control",
          re.search(r'healthyChargingControl\s*=\s*"/carownerservice/v3/api/healthyCharging/control"', ep)
          is not None)
    check("健康充电只读查询路径仍在（开关初值靠它）",
          re.search(r'healthyChargingPush\s*=\s*"/carownerservice/v3/api/healthyCharging/queryPushState"', ep)
          is not None)

    # ---- ★ 2026-10-09 核实：上面两条写路径**当前未被引用** ----
    # 它们只是逆向记录 + 备用通道，真正的下发走 appremotectl + cmdid。
    #
    # 为什么必须把这件事钉死：**无人引用的常量，Swift 会把整个字符串
    # 字面量优化掉**，于是「最终二进制里搜不到这个路径」是**正常现象**。
    # 不知道这一点的人会误判成「漏编译」，然后去乱改一通。
    #
    # 上一轮就真犯过这个错：把搜不到的原因解释成「Swift 小字符串优化」。
    # 但那两条路径分别是 46 / 47 字节，远超小字符串 15 字节的阈值 ——
    # 真实原因是**死代码消除**。所以这里同时断言「标注」和「实际通道」。
    for cname, cn in (("appointmentSet", "预约充电"),
                      ("healthyChargingControl", "健康充电")):
        m = re.search(rf"static let {cname}\s*=", ep)
        check(f"{cname} 仍在端点表里（逆向记录）", m is not None)
        if m:
            head = ep[max(0, m.start() - 900):m.start()]
            check(f"{cname} 明确标注了「当前未启用」（{cn}实际走 cmdid 通道）",
                  "当前未启用" in head)
    check("预约充电实际走 controlRaw(cmdid 161)",
          re.search(r"saveAppointmentCharge[\s\S]{0,1200}?ChargeCmdid\.appointment", client) is not None)
    check("健康充电实际走 controlRaw(cmdid 480)",
          re.search(r"setHealthyCharging[\s\S]{0,600}?ChargeCmdid\.health\b", client) is not None)

    # ---- 客户端方法 ----
    for fn in ("setChargingActive", "setChargeLimit", "setHealthyCharging",
               "saveAppointmentCharge", "refreshHealthyCharging"):
        check(f"LMClient 有 {fn}()", re.search(rf"func\s+{fn}\(", client) is not None)

    check("充电上限被夹在 chargeSocRange 内（不信任调用方传值）",
          re.search(r"chargeSocRange\.lowerBound", client) is not None
          and re.search(r"chargeSocRange\.upperBound", client) is not None)

    # ---- 每个方法必须挂到正确的 cmdid 上 ----
    for fn, cid in (("setChargingActive", "startOrStop"), ("setChargeLimit", "socLimit"),
                    ("setHealthyCharging", "health"), ("saveAppointmentCharge", "appointment")):
        check(f"{fn} 走 ChargeCmdid.{cid}",
              re.search(rf"func\s+{fn}\([\s\S]{{0,1400}}?ChargeCmdid\.{cid}", client) is not None)

    # ---- state 字段：分级证据，字段名不能乱换 ----
    check("立即充电用 Begin_Charge（主二进制字符串表）",
          re.search(r'"Begin_Charge"', client) is not None)
    check("健康充电用 isPush（查询接口实测字段）",
          re.search(r'"isPush"\s*:\s*on', client) is not None)
    check("充电上限用 percent（服务端 config[\"3\"] 实测名）",
          re.search(r'"percent"\s*:\s*p', client) is not None)
    for f in ("beginTime", "endTime", "isEnable", "cycles", "circulation"):
        check(f"预约充电回传服务端原名 {f}", f'"{f}"' in client)

    # ---- 健康充电状态必须是 Optional（区分「未知」与「已关闭」）----
    check("healthyChargingPush 是 Bool?（未读取 ≠ 已关闭）",
          re.search(r"var\s+healthyChargingPush\s*:\s*Bool\?", client) is not None)
    check("refreshAll 里会查一次健康充电状态",
          re.search(r"refreshAll\(\)[\s\S]*?refreshHealthyCharging\(\)", client) is not None)

    # ---- 界面：四张卡 + 四个动作 ----
    # ★ UIKit 版的卡是 `private let xxxCard = LMCardView(...)` 控件属性。
    for card in ("controlCard", "healthCard", "socCard", "apCard"):
        check(f"充电页有 {card}",
              re.search(rf"private\s+let\s+{card}\s*=", view) is not None)
    for act in ("runCharging", "runHealth", "runSocLimit", "runAppointment"):
        check(f"充电页有动作 {act}()", re.search(rf"func\s+{act}\(", view) is not None)

    # body 顺序：控制 → 健康 → 上限 → 预约
    idx = [view.find(x) for x in ("controlCard", "healthCard", "socCard", "apCard")]
    check("四张卡的 body 顺序为 控制→健康→上限→预约",
          all(i >= 0 for i in idx) and idx == sorted(idx), str(idx))

    check("按钮在忙 / 控制锁定期内禁用（controlLockRemaining）",
          "controlLockRemaining() > 0" in view)
    # ★ SwiftUI 版用 `.alert`；UIKit 版走基类的 `showAlert`（内部是
    #   `UIAlertController`），同样保证「下发结果不静默」。
    check("下发结果用 alert 回报（不静默）",
          re.search(r"showAlert\(", view) is not None
          and "UIAlertController" in read("UIKit/LMBaseViewController.swift"))

    # ---- 预约回填：只在服务端有值时才覆盖 ----
    check("syncAppointmentFromServer 存在", re.search(r"func\s+syncAppointmentFromServer\(", view) is not None)
    check("回填时跳过占位值 --:--（不把「未设置」写成 00:00）",
          re.search(r'syncAppointmentFromServer[\s\S]{0,900}?"--:--"', view) is not None)
    check("预约开关初值来自服务端 isEnabled",
          re.search(r"syncAppointmentFromServer[\s\S]{0,900}?apEnabled\s*=\s*s\.isEnabled", view) is not None)

    # ---- 可复现脚本必须在（否则这些 cmdid 就只剩「注释里的传说」）----
    repro = os.path.join(ROOT, "client", "ios_charge_cmdid.py")
    check("client/ios_charge_cmdid.py 存在（cmdid 可重算）", os.path.exists(repro))
    if os.path.exists(repro):
        with open(repro, "r", encoding="utf-8") as f:
            r = f.read()
        for cid in (190, 193, 480, 161):
            check(f"复现脚本里断言了 cmdid {cid}", f", {cid}, " in r)
        check("复现脚本解释了「预约充电是多对一」",
              "多对一" in r or "161 / 171 / 361 / 392" in r)

    # ---- ★ 2026-10-09 加：deviceId 必须稳定，否则设备维度的状态读不对 ----
    #
    # 用户报「官方健康充电是开启状态，本 App 显示已关闭」。
    # 根因线索：`queryPushState` 是拿 `carvin + deviceId` 查「**这台设备**的状态」，
    # 而原来的 `deviceId` 是**每次启动现生成一个 UUID** ——
    # 服务端每次都把本机当成一台陌生设备，带设备维度的状态一律回默认值 false。
    # 抓包交叉验证：官方自己调同一个接口，用的也是**固定不变**的
    # `ios_ee45b9d830bb126d431e998943a7797a`。
    check("deviceId 走持久化的稳定值（不再每次启动随机）",
          re.search(r"var deviceId: String\s*=\s*LMConfig\.stableDeviceId", client) is not None)
    check("stableDeviceId 落盘复用（UserDefaults）",
          re.search(r"static let stableDeviceId[\s\S]{0,1300}?UserDefaults", client) is not None)
    check("stableDeviceId 首次取官方抓包那个 deviceId（服务端认过）",
          re.search(r"static let stableDeviceId[\s\S]{0,1300}?capturedDeviceId", client) is not None)
    check("健康充电卡写明了状态来源（不再只给一个「已关闭」）",
          re.search(r"healthSourceLabel\.text[\s\S]{0,500}?queryPushState", view) is not None)
    check("读取开关状态的按钮不再被隐藏（用户随时能重读）",
          re.search(r"healthReadRow\.isHidden = false", view) is not None)
    check("健康充电开关状态用颜色区分开/关",
          re.search(r"healthStateLabel\.textColor = on \? \.lmGood", view) is not None)

    # ---- ★★ 2026-10-09 第二轮：用户报「健康充电读取开关状态没反应」----
    #
    # 根因（两条叠加）：
    #   ① `refreshHealthyCharging()` 把异常**整个吞掉**（`catch { return nil }`），
    #      界面上一个字都看不到；而且 `@Published` 没被赋值 → `objectWillChange`
    #      不触发 → `render()` 根本不会跑；
    #   ② 就算成功，`isPush` 值没变时界面也不会动 —— 点下去等于没有反馈。
    # 修法：把「加载中 / 出错原因 / 读取时间」都记下来并在卡里写出来，
    #      并且 `healthReadTapped()` 前后各显式 `render()` 一次。
    check("LMClient 暴露 healthyChargingLoading",
          re.search(r"var healthyChargingLoading = false", client) is not None)
    check("LMClient 暴露 healthyChargingError（不再静默吞异常）",
          re.search(r"var healthyChargingError: String\?", client) is not None)
    check("LMClient 暴露 healthyChargingReadAt（区分刚读的和很久以前的）",
          re.search(r"var healthyChargingReadAt: Date\?", client) is not None)
    check("refreshHealthyCharging 的 catch 会写 healthyChargingError",
          re.search(r"catch \{[\s\S]{0,300}?healthyChargingError = \"读取失败", client) is not None)
    check("refreshHealthyCharging 会校验 code != 0",
          re.search(r"if let code = env\.code, code != 0", client) is not None)
    check("refreshHealthyCharging 会校验 isPush 字段存在",
          re.search(r"guard let value = env\.data\?\.isPush", client) is not None)
    check("refreshHealthyCharging 有 loading 开/关（defer 兜底）",
          re.search(r"healthyChargingLoading = true[\s\S]{0,200}?defer \{ healthyChargingLoading = false \}",
                    client) is not None)
    check("充电页有读取结果反馈行",
          re.search(r"private let healthFeedbackLabel", view) is not None)
    check("反馈行会写出「读取中…」",
          re.search(r"healthFeedbackLabel\.text = \"正在向车端查询", view) is not None)
    check("反馈行会写出服务端原始值 + 读取时间",
          re.search(r"isPush = \\\(raw\)[\s\S]{0,200}?healthTimeText", view) is not None)
    check("读取按钮提成了属性（才能动态改标题/可用态）",
          re.search(r"private let healthReadButton = UIButton\(\)", view) is not None)
    check("读取中按钮标题变「读取中…」（用 configuration 改，不是 titleLabel）",
          re.search(r"healthReadButton\.configuration\?\.title = loading \? \"读取中…\"", view) is not None)
    check("healthReadTapped 前后各 render 一次（点了必有反馈）",
          re.search(r"func healthReadTapped\(\)[\s\S]{0,600}?self\.render\(\)[\s\S]{0,300}?await self\.client\.refreshHealthyCharging\(\)[\s\S]{0,120}?self\.render\(\)",
                    view) is not None)
    check("卡里如实写明 isPush 未必等于官方那个功能开关",
          re.search(r"healthSourceLabel\.text[\s\S]{0,600}?以官方 App 为准", view) is not None)


def test_car3d_layout() -> None:
    """⑪ 3D 车模：放大 + 提到顶部 + 去掉卡片感。

    背景（2026-10-09 用户报）：「把 3D 车模给放大调到上面跟背景一起」。
    官方爱车页的车模是**页面背景的一部分**（直接浮在页面上），
    而我们之前套了 `LMCard` 式的圆角底色，看起来像一张卡。

    注意「去掉底色」是安全的：`LMCar3DWebView` 的 WKWebView 已设
    `isOpaque = false` + `backgroundColor = .clear`，所以没有白块。

    ★ 2026-10-09：本页已迁成 UIKit，断言按 UIKit 的真实形态写 ——
      「顺序」看 `buildUI()` 里 `addArrangedSubview` 的调用次序，
      「去卡片感」看 `buildCar3D()` 里有没有铺底色 / 裁圆角。
    """
    print("\n[11] 3D 车模布局（放大 + 上移 + 去卡片感）")

    love = read("UIKit/LMLoveCarViewController.swift")
    c3d = read("UIKit/LMCar3DWebView.swift")

    check("car3DHeight = 330（原 230）",
          re.search(r"let\s+car3DHeight\s*:\s*CGFloat\s*=\s*330", love) is not None)

    # 顺序：topBar → car3DContainer → rangeHero
    i_top = love.find("addArrangedSubview(topBar)")
    i_car = love.find("addArrangedSubview(car3DContainer)")
    i_rng = love.find("addArrangedSubview(rangeHero)")
    check("car3DContainer 紧跟在 topBar 之后（提到页面顶部）",
          i_top >= 0 and i_car >= 0 and i_top < i_car, f"topBar@{i_top} car3D@{i_car}")
    check("car3DContainer 在 rangeHero 之前",
          i_car >= 0 and i_rng >= 0 and i_car < i_rng, f"car3D@{i_car} range@{i_rng}")

    # 去卡片感：buildCar3D 里不能再有 secondarySystemBackground / 圆角裁切
    seg = love[love.find("private func buildCar3D()"):]
    nxt = re.search(r"\n    (?:private|override|@objc) ", seg[10:])
    seg = seg[: (10 + nxt.start()) if nxt else 3000]
    check("buildCar3D 不再铺 secondarySystemBackground 底色",
          "secondarySystemBackground" not in seg)
    check("buildCar3D 不再对容器做圆角裁切",
          "masksToBounds" not in seg and "clipShape" not in seg)

    # 安全性前提：WebView 必须透明，否则去底色会露白块
    check("LMCar3DWebView 设了 isOpaque = false（去底色才安全）",
          "isOpaque = false" in c3d)
    check("LMCar3DWebView 设了 backgroundColor = .clear",
          "backgroundColor = .clear" in c3d)

    # 全屏入口与手势提示保留
    check("全屏看车入口保留", "全屏看车" in love)
    check("拖动/缩放手势提示保留", "hand.draw" in love)


# ============================================================
# 11. UIKit 骨架（2026-10-09 从 SwiftUI 迁到 UIKit · Phase 0）
# ============================================================
def test_uikit_skeleton() -> None:
    """⑪ UIKit 骨架：入口换成 AppDelegate，页面暂时用 UIHostingController 托住。

    背景：用户要求「换个 UI，不使用 SwiftUI」。做法不是一次性重写 7,514 行
    视图代码，而是先把**壳**换成 UIKit，未迁移的页面用 `UIHostingController`
    托住 —— 这样每一步 App 都能编译、能出包、能装机验证。

    ★ 2026-10-09（Phase 3~6 全部迁完）：SwiftUI 页面已清零，
      `LMHostingController` 与 `Views/` 目录都已删除。本组断言随之更新为
      「5 个 Tab 全是原生 UIKit 页」的形态。

    这组断言钉住三件事：
      ① 入口只有一处 `@main`，且是 AppDelegate（两处 `@main` 直接编译失败）
      ② 骨架各件语义正确（订阅 / 注入 / 换根 / 5 个原生 Tab）
      ③ 关键文件**真的进了 pbxproj 的 Sources** ——
         否则会出现「CI 绿了但功能静默缺失」这种最难查的问题
    """
    print("\n[11] UIKit 骨架（AppDelegate + HostingController 过渡）")

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    app_dir = APP

    # ---- ① 入口唯一性 ----
    mains: list[str] = []
    for dirpath, dirs, fns in os.walk(app_dir):
        dirs.sort()
        for fn in sorted(fns):
            if not fn.endswith(".swift"):
                continue
            p = os.path.join(dirpath, fn)
            with open(p, "r", encoding="utf-8") as f:
                src = f.read()
            # 只看行首的真正声明，不看注释里提到的 @main
            if re.search(r"(?m)^@main\b", src):
                mains.append(os.path.relpath(p, app_dir).replace(os.sep, "/"))
    check("全项目只有一处 @main", len(mains) == 1, f"实际 {mains}")
    check("入口是 UIKit 的 LMAppDelegate.swift",
          mains == ["UIKit/LMAppDelegate.swift"], f"实际 {mains}")

    # ---- ② 骨架各件的语义 ----
    delegate = read("UIKit/LMAppDelegate.swift")
    check("AppDelegate 建 window 并挂 LMRootViewController",
          "UIWindow(" in delegate and "LMRootViewController(client: client)" in delegate)
    check("AppDelegate 里创建全局唯一的 LMClient",
          re.search(r"let\s+client\s*=\s*LMClient\(\)", delegate) is not None)
    # ★ 这条要查 Info.plist，不能查 AppDelegate 源码 ——
    #   源码注释里为了解释「为什么不用 SceneDelegate」**必然**会提到
    #   `UIApplicationSceneManifest` 这个词，查源码等于自己踩自己。
    plist = read("Support/Info.plist")
    check("Info.plist 里没有 Scene 清单（所以 AppDelegate+window 就够，不需要 SceneDelegate）",
          "UIApplicationSceneManifest" not in plist)

    base = read("UIKit/LMBaseViewController.swift")
    check("基类订阅 objectWillChange 驱动刷新", "client.objectWillChange" in base)
    check("基类把刷新推到下一轮主 actor（objectWillChange 早于赋值）",
          "Task { @MainActor in" in base)
    check("基类提供下拉刷新桥接", "UIRefreshControl" in base)
    check("基类暴露 buildUI / render 两个钩子",
          "func buildUI()" in base and "func render()" in base)
    check("基类持的是外部传入的 client（不自己 new）",
          "init(client: LMClient)" in base)

    host = read("UIKit/LMBaseViewController.swift")
    check("基类订阅 objectWillChange 驱动刷新", "client.objectWillChange" in host)
    check("基类把刷新推到下一轮主 actor（objectWillChange 早于赋值）",
          "Task { @MainActor in" in host)
    check("基类提供下拉刷新桥接", "UIRefreshControl" in host)
    check("基类暴露 buildUI / render 两个钩子",
          "func buildUI()" in host and "func render()" in host)
    check("基类持的是外部传入的 client（不自己 new）",
          "init(client: LMClient)" in host)

    # ★ 2026-10-09（Phase 3~6 全部迁完）：过渡期的 `LMHostingController`
    #   （把 SwiftUI 页包成 VC 的桥）已随最后一个 SwiftUI 页面一起删除。
    #   它只在「还有页面没迁」时才有意义 —— 留着反而是死代码。
    check("过渡期的 LMHostingController.swift 已删除",
          not os.path.exists(os.path.join(app_dir, "UIKit", "LMHostingController.swift")))

    tabs = read("UIKit/LMMainTabBarController.swift")
    for name in ("爱车", "定位", "充电", "车控", "设置"):
        check(f"Tab 里有「{name}」", f'"{name}"' in tabs)
    # ★ 2026-10-09（Phase 3~6）：5 个 Tab **全部**已是原生 UIKit 页，
    #   由 `LMNavigationController` 承载 —— 一个 SwiftUI 托管页都不剩。
    check("5 个 Tab 全是原生 UIKit 页（不再有 SwiftUI 托管页）",
          tabs.count("LMHostingController(") == 0
          and tabs.count("NavigationStack {") == 0)
    check("Tab 统一由 makeTab(...) 包 LMNavigationController",
          "makeTab(" in tabs
          and "LMNavigationController(rootViewController: root)" in tabs)
    for vc in ("LMLoveCarViewController", "LMLocationViewController",
               "LMChargeViewController", "LMControlPanelViewController",
               "LMSettingsViewController"):
        check(f"Tab 根页是 {vc}", f"{vc}(client: client)" in tabs)

    rootvc = read("UIKit/LMRootViewController.swift")
    check("根容器按 session?.isValid 切换",
          "client.session?.isValid == true" in rootvc)
    check("根容器在登录态未变时不重建（否则用户输入会被清空）",
          "wantMain != showingMain" in rootvc)

    theme = read("UIKit/LMUIKitTheme.swift")
    for c in ("lmAccent", "lmGood", "lmWarn", "lmBad"):
        check(f"UIColor.{c} 已定义", f"static let {c}" in theme)

    # ---- ③ 新文件真的进了编译 ----
    pbx_path = os.path.join(os.path.dirname(app_dir),
                            "LeapmotorLite.xcodeproj", "project.pbxproj")
    check("project.pbxproj 存在", os.path.exists(pbx_path))
    if os.path.exists(pbx_path):
        with open(pbx_path, "r", encoding="utf-8") as f:
            pbx = f.read()
        for fn in ("LMAppDelegate.swift", "LMBaseViewController.swift",
                   "LMMainTabBarController.swift",
                   "LMRootViewController.swift", "LMUIKitTheme.swift",
                   "LMLoginViewController.swift",
                   # ★ 2026-10-09（Phase 3~6）新迁的 5 个 Tab 根页 + 子页
                   "LMLoveCarViewController.swift", "LMLocationViewController.swift",
                   "LMChargeViewController.swift", "LMControlPanelViewController.swift",
                   "LMSettingsViewController.swift", "LMCar3DWebView.swift",
                   "LMCar3DViewController.swift", "LMVehicleProfileViewController.swift",
                   "LMBLEKeyViewController.swift", "LMBLEDebugViewController.swift",
                   "LMDiagnosticsViewController.swift", "LMSignalExplorerViewController.swift",
                   "LMSelfTestViewController.swift"):
            check(f"{fn} 已进 Sources（否则 CI 绿但功能静默缺失）",
                  f"{fn} in Sources" in pbx)
        check("旧入口 LeapmotorLiteApp.swift 已从工程移除",
              "LeapmotorLiteApp.swift" not in pbx)
        # ★ 2026-10-09：过渡期的宿主桥与 12 个 SwiftUI 页面必须一起消失，
        #   否则会出现「文件还在工程里、但没有任何代码引用」的死代码。
        check("过渡期宿主 LMHostingController.swift 已从工程移除",
              "/* LMHostingController.swift */" not in pbx)
        check("旧 SwiftUI 页面已从工程移除",
              "/* LoveCarView.swift */" not in pbx
              and "/* Car3DView.swift */" not in pbx
              and "/* ChargeView.swift */" not in pbx)
    check("旧入口文件已删除",
          not os.path.exists(os.path.join(app_dir, "LeapmotorLiteApp.swift")))

    gen = os.path.join(root, "ios", "tools", "gen_xcodeproj.py")
    if os.path.exists(gen):
        with open(gen, "r", encoding="utf-8") as f:
            gsrc = f.read()
        check("gen_xcodeproj.py 的 DIR_ORDER 含 UIKit", '"UIKit"' in gsrc)
        # ★ 2026-10-09：`Views/` 整个目录已删，DIR_ORDER 里不能再留着它。
        check("gen_xcodeproj.py 的 DIR_ORDER 已移除 Views",
              '"Views"' not in gsrc)


# ============================================================
# 12. Phase 1：登录页迁成 UIKit
# ============================================================
def test_uikit_login() -> None:
    """⑫ 登录页（Phase 1）已从 SwiftUI 迁成 UIKit。

    这是第一页「真迁移」，所以要把迁移的**验收标准**钉死 ——
    后面每一页都照这个模板来：

      ① 旧 SwiftUI 文件删掉，且没有任何地方还引用它
      ② 新 VC 继承 `LMBaseViewController`（否则拿不到 client 与自动刷新）
      ③ **行为不能丢**：验证码倒计时、数字过滤、导入登录态三条链路都在
      ④ 根容器换成原生 VC，不再由 `UIHostingController` 托管
      ⑤ 新文件真的进了 pbxproj 的 Sources
      ⑥ 踩过的 UIKit 坑不能回归：`UILabel.isSelectable`（真烧过一轮 CI）、
         按钮标题必须走 `configuration?.title`
    """
    print("\n[12] Phase 1：登录页迁成 UIKit")

    # ---- ① 旧文件删干净 ----
    check("Views/LoginView.swift 已删除",
          not os.path.exists(os.path.join(APP, "Views", "LoginView.swift")))
    old_refs = []
    for dirpath, dirs, fns in os.walk(APP):
        dirs.sort()
        for fn in sorted(fns):
            if not fn.endswith(".swift"):
                continue
            with open(os.path.join(dirpath, fn), "r", encoding="utf-8") as f:
                if re.search(r"(?m)^\s*(?:struct|final class)\s+LoginView\b", f.read()):
                    old_refs.append(fn)
    check("源码里没有 LoginView 类型残留", old_refs == [], f"实际 {old_refs}")

    # ---- ② 新 VC 的骨架 ----
    vc = read("UIKit/LMLoginViewController.swift")
    check("LMLoginViewController 继承 LMBaseViewController",
          re.search(r"final class LMLoginViewController\s*:\s*LMBaseViewController", vc)
          is not None)
    check("实现了 buildUI / render 两个钩子",
          "override func buildUI()" in vc and "override func render()" in vc)
    check("render 幂等（只调 refreshControls，不重建视图）",
          re.search(r"override func render\(\)[\s\S]{0,400}?refreshControls\(\)", vc)
          is not None)

    # ---- ③ 三条行为链路不能丢 ----
    # 3.1 倒计时
    check("倒计时用 target/selector 版 Timer（block 版是 @Sendable 闭包，"
          "不继承 @MainActor 隔离）",
          re.search(r"Timer\(timeInterval:[\s\S]{0,120}?selector:\s*#selector\(", vc)
          is not None)
    check("倒计时加进 RunLoop 的 .common 模式（否则一拖动就停走）",
          "forMode: .common" in vc)
    check("离开页面会停表（避免 Timer 一直持有 self）",
          re.search(r"viewDidDisappear[\s\S]{0,300}?countdownTimer\?\.invalidate\(\)", vc)
          is not None)
    # 3.2 输入过滤
    check("手机号只留数字", vc.count(r"filter(\.isNumber)") >= 2)
    check("验证码截断到 6 位", re.search(r"prefix\(6\)", vc) is not None)
    # 3.3 导入登录态
    check("导入框接了 UITextViewDelegate",
          re.search(r"extension LMLoginViewController:\s*UITextViewDelegate", vc)
          is not None)
    check("导入框变化会刷新按钮可用性",
          re.search(r"textViewDidChange[\s\S]{0,300}?refreshControls\(\)", vc) is not None)
    # 3.4 验证码框的 oneTimeCode 是**正确**用法（R8 拦的是操作密码框）
    check("验证码框用 .oneTimeCode（收短信验证码的正确用法）",
          "textContentType = .oneTimeCode" in vc)

    # ---- ④ 四条 LMClient 链路都还在 ----
    for m in ("sendSMSCode", "loginWithSMSCode", "adoptLoginResponse", "refreshAll"):
        check(f"仍调用 client.{m}", f"client.{m}" in vc)

    # ---- ⑤ 根容器换成原生 VC ----
    rootvc = read("UIKit/LMRootViewController.swift")
    check("根容器直接建 LMLoginViewController（不再是 HostingController）",
          "LMLoginViewController(client: client)" in rootvc)
    check("根容器不再引用 SwiftUI 的 LoginView()",
          re.search(r"\{\s*LoginView\(\)\s*\}", rootvc) is None)
    check("登录页用 LMNavigationController 承载导航栏",
          re.search(r"LMNavigationController\(\s*\n?\s*rootViewController:\s*LMLoginViewController",
                    rootvc) is not None)

    # ---- ⑥ 进编译 ----
    pbx_path = os.path.join(os.path.dirname(APP),
                            "LeapmotorLite.xcodeproj", "project.pbxproj")
    if os.path.exists(pbx_path):
        with open(pbx_path, "r", encoding="utf-8") as f:
            pbx = f.read()
        # 用 /* 文件名 */ 精确匹配，避免 "LMLoginViewController.swift"
        # 里的 "LoginView" 子串造成假阳性
        check("LMLoginViewController.swift 已进 Sources",
              "/* LMLoginViewController.swift */" in pbx)
        check("旧的 LoginView.swift 已从工程移除",
              "/* LoginView.swift */" not in pbx)

    # ---- ⑦ 消息卡「可复制」的正确 UIKit 实现（★ 真烧过一轮 CI） ----
    #
    # 2026-10-09：这里原来写的是 `messageLabel.isSelectable = true`
    # （把 UITextView 的成员安到了 UILabel 上），CI 直接报
    #   LMLoginViewController.swift:256:22: error:
    #     value of type 'UILabel' has no member 'isSelectable'
    # 正确做法是自己挂长按手势 + 写剪贴板（UILabel 没有内建选择能力）。
    # lint 已加 R15 兜这类错，这里再钉一遍**语义**，
    # 防止以后有人图省事「简化」回 isSelectable。
    check("没有在 UILabel 上写 isSelectable（UILabel 根本没这个成员）",
          re.search(r"messageLabel\.isSelectable", vc) is None)
    check("消息卡用长按手势实现复制",
          re.search(r"UILongPressGestureRecognizer\(\s*[\s\S]{0,140}?"
                    r"#selector\(messageLongPressed", vc) is not None)
    check("长按复制真的写进剪贴板",
          re.search(r"messageLongPressed[\s\S]{0,500}?UIPasteboard\.general\.string\s*=",
                    vc) is not None)

    # ---- ⑧ 按钮标题/字体走 configuration（用 Configuration 建的按钮） ----
    #
    # `UIButton.Configuration` 一旦挂上，配置里的 title 才是权威来源；
    # 字体也由配置决定 —— 直接写 `titleLabel?.font` 会被配置覆盖（静默失效）。
    # 所以：动态标题走 configuration?.title，且全文件不出现 titleLabel?.font。
    check("动态按钮标题走 configuration?.title",
          "sendCodeButton.configuration?.title" in vc)
    check("没有用会被配置覆盖的 titleLabel?.font",
          re.search(r"\.titleLabel\?\.font\s*=", vc) is None)


def test_uikit_settings() -> None:
    """⑬ 设置页（Phase 2）已从 SwiftUI 迁成 UIKit。

    这是第一个「带表单 + 带子页跳转」的页面，比登录页多两类风险：

      A. **操作密码的输入语义不能变** —— 这是「车控报密码错误」的主战场：
         密码框不能挂 `.oneTimeCode`、只滤数字但不截断、切明文后必须重赋 text。
      B. **子页跳转不能断** —— 设置页要 push 7 个子页。Phase 3~6 之后这 7 个
         也全是原生 UIKit 页了，一律直接 `pushViewController`；过渡期的
         `ownsNavigationBar` / `LMHostingController` 已随之删除。

    ⚠️ 写断言时注意：**盯被测对象，不要盯字符串是否出现在文件里**。
       本文件的注释里为了解释「为什么不能用 .oneTimeCode / prefix(8)」
       必然会写出这两个词，用 `"oneTimeCode" not in vc` 这种写法会自己踩自己。
       所以下面一律用正则匹配**真实调用**（`textContentType = .oneTimeCode`、
       `.prefix(8)`），不匹配裸词。
    """
    print("\n[13] Phase 2：设置页迁成 UIKit")

    # ---- ① 旧文件删干净 ----
    check("Views/SettingsView.swift 已删除",
          not os.path.exists(os.path.join(APP, "Views", "SettingsView.swift")))
    old_refs = []
    for dirpath, dirs, fns in os.walk(APP):
        dirs.sort()
        for fn in sorted(fns):
            if not fn.endswith(".swift"):
                continue
            with open(os.path.join(dirpath, fn), "r", encoding="utf-8") as f:
                if re.search(r"(?m)^\s*(?:struct|final class)\s+SettingsView\b", f.read()):
                    old_refs.append(fn)
    check("源码里没有 SettingsView 类型残留", old_refs == [], f"实际 {old_refs}")

    # ---- ② 新 VC 的骨架 ----
    vc = read("UIKit/LMSettingsViewController.swift")
    check("LMSettingsViewController 继承 LMBaseViewController",
          re.search(r"final class LMSettingsViewController\s*:\s*LMBaseViewController", vc)
          is not None)
    check("实现了 buildUI / render 两个钩子",
          "override func buildUI()" in vc and "override func render()" in vc)
    check("render 幂等（条件行用 isHidden 折叠，不重建视图）",
          vc.count(".isHidden = ") >= 6)
    check("行数会变的两块内容用指纹去重（不是每次 render 都重建）",
          "rebuildIfNeeded" in vc and "ObjectIdentifier" in vc)

    # ---- ③ 操作密码：输入语义不能变（「车控报密码错误」的主战场）----
    check("操作密码框用 .password",
          "textContentType = .password" in vc)
    check("没有把 .oneTimeCode 挂到操作密码框上（会静默替换用户输入）",
          re.search(r"textContentType\s*=\s*\.oneTimeCode", vc) is None)
    check("只滤数字但不截断（不能再静默吃掉输入）",
          "\\.isNumber" in vc and re.search(r"\.prefix\(8\)", vc) is None)
    check("有「已输入 N 位」提示（任何一环出问题用户都能自己看出来）",
          '"已输入"' in vc and '"0 位"' in vc)
    check("超范围只警告不硬拦",
          "官方操作密码一般是 4~6 位" in vc)
    check("可临时明文查看（切 isSecureTextEntry 后重赋 text，否则一打字就清空）",
          "isSecureTextEntry = !revealPassword" in vc
          and re.search(r"isSecureTextEntry = !revealPassword[\s\S]{0,400}?text = saved", vc)
          is not None)
    check("现场算 oppwd 并回解（用户肉眼能判断发出去的明文对不对）",
          "encryptOppwd" in vc and "decryptOppwd" in vc and "oppwdKeyIV" in vc)
    check("保存操作密码走 client.adopt(session:)（写 Keychain）",
          "client.adopt(session:" in vc)

    # ---- ④ 其余行为链路 ----
    for name, needle in (
        ("立即续期 accessToken", "refreshSessionIfNeeded(force: true)"),
        ("刷新车辆列表", "client.loadVehicles()"),
        ("切换选中车辆并刷新", "client.select(vehicle:"),
        ("退出登录", "client.signOut()"),
        ("未读消息角标", "noticeCount"),
        ("本 App 构建信息", "LMBuildInfo.displayText"),
        ("JWT exp 解析（提示 token 何时过期）", "timeIntervalSince1970: exp"),
        ("续期日志", "tokenRefreshLog"),
    ):
        check(f"仍保留：{name}", needle in vc)

    # ---- ⑤ 7 个子页跳转入口都在（★ 现在全是原生 UIKit 页，直接 push）----
    for page in ("LMVehicleProfileViewController", "LMLocationViewController",
                 "LMChargeViewController", "LMBLEKeyViewController",
                 "LMSignalExplorerViewController", "LMDiagnosticsViewController",
                 "LMSelfTestViewController"):
        check(f"设置页仍能跳到 {page}",
              f"pushViewController({page}(client: client)" in vc)

    # ---- ⑥ 导航架构：直接 push 原生 VC，过渡期的宿主桥已删除 ----
    #
    # ⚠️ 这里**不能**写 `"pushSwiftUIPage" not in vc` / `"import SwiftUI" not in vc`：
    #    本文件的头注释为了说明「过渡期方法已删」必然会写出这两个词，
    #    裸串断言会自己踩自己（这个坑在本项目已经踩过三次）。
    #    必须匹配**真实声明形态**。
    check("设置页不再有过渡方法 pushSwiftUIPage",
          re.search(r"func\s+pushSwiftUIPage", vc) is None)
    check("设置页不再 import SwiftUI",
          re.search(r"(?m)^import SwiftUI", vc) is None)
    check("push 子页前先取到 navigationController",
          re.search(r"let\s+nav\s*=\s*navigationController", vc) is not None
          and "nav.pushViewController(" in vc)

    # ---- ⑦ 爱车页那个齿轮入口 ----
    lovecar = read("UIKit/LMLoveCarViewController.swift")
    check("爱车页齿轮改成切「设置」Tab",
          "lmSelectSettingsTab" in lovecar)
    tabs = read("UIKit/LMMainTabBarController.swift")
    check("Tab 容器实现了切到设置 Tab",
          "func selectSettingsTab()" in tabs and "lmSelectSettingsTab" in tabs)

    # ---- ⑧ 进编译 ----
    pbx_path = os.path.join(os.path.dirname(APP),
                            "LeapmotorLite.xcodeproj", "project.pbxproj")
    if os.path.exists(pbx_path):
        with open(pbx_path, "r", encoding="utf-8") as f:
            pbx = f.read()
        check("LMSettingsViewController.swift 已进 Sources",
              "/* LMSettingsViewController.swift */" in pbx)
        check("旧的 SettingsView.swift 已从工程移除",
              "/* SettingsView.swift */" not in pbx)


# ============================================================
# 14. Phase 3~6：剩余 11 页全部迁成 UIKit（SwiftUI 清零）
# ============================================================
def test_uikit_full_migration() -> None:
    """⑭ Phase 3~6：11 个页面全部迁成 UIKit，SwiftUI 清零。

    这是「换掉 SwiftUI」这条线的收尾验收。前面 ⑫⑬ 是逐页验收，
    这一节只钉**整体不变量** —— 它们能拦住「迁了一半、留了半截」的形态：

      ① `Views/` 目录与 `LMHostingController` 必须整个消失
      ② 全项目不能再有 `import SwiftUI`（UIKit 页不该引 SwiftUI）
      ③ 不能再有过渡方法 `pushSwiftUIPage` 的**定义**（只剩注释不算）
      ④ 13 个新 VC 全部继承 `LMBaseViewController` 且实现 buildUI/render
      ⑤ 跨页跳转全部指向新的 VC 类
      ⑥ `Car3DConfig` 只有一处定义（新旧文件曾重名，不删旧的必冲突）
      ⑦ 全部进了 pbxproj 的 Sources，且磁盘源文件数与工程一致

    ⚠️ 写断言的老规矩：盯**真实声明形态**，不盯裸词 ——
       本文件注释里必然出现 `pushSwiftUIPage` / `import SwiftUI` 这些词，
       裸串断言会自己踩自己（本项目已踩过三次）。
    """
    print("\n[14] Phase 3~6：全部页面迁成 UIKit（SwiftUI 清零）")

    app_dir = APP

    def _swift_files():
        for dirpath, dirs, fns in os.walk(app_dir):
            dirs.sort()
            for fn in sorted(fns):
                if fn.endswith(".swift"):
                    p = os.path.join(dirpath, fn)
                    with open(p, "r", encoding="utf-8") as f:
                        yield os.path.relpath(p, app_dir).replace(os.sep, "/"), f.read()

    # ---- ① 过渡期产物必须整体消失 ----
    check("Views/ 目录已删除",
          not os.path.isdir(os.path.join(app_dir, "Views")))
    check("LMHostingController.swift 已删除",
          not os.path.exists(os.path.join(app_dir, "UIKit", "LMHostingController.swift")))

    # ---- ② 全项目不再 import SwiftUI ----
    swiftui_imports, old_types = [], []
    for rel, src in _swift_files():
        if re.search(r"(?m)^import SwiftUI", src):
            swiftui_imports.append(rel)
        # 旧的 SwiftUI 页面都是 `struct XxxView: View`
        if re.search(r"(?m)^\s*(?:struct|final class)\s+\w+View\s*:\s*View\b", src):
            old_types.append(rel)
    check("全项目不再 import SwiftUI", swiftui_imports == [], f"实际 {swiftui_imports}")
    check("源码里没有 SwiftUI 页面类型残留（struct XxxView: View）",
          old_types == [], f"实际 {old_types}")

    # ---- ③ 过渡方法只剩注释，没有定义 ----
    pushers = [rel for rel, src in _swift_files()
               if re.search(r"func\s+pushSwiftUIPage", src)]
    check("没有 pushSwiftUIPage 的方法定义（过渡期结束）", pushers == [], f"实际 {pushers}")

    # ---- ④ 13 个新 VC 的骨架 ----
    new_vcs = [
        # Phase 3 诊断类
        "LMSelfTestViewController", "LMSignalExplorerViewController",
        "LMBLEKeyViewController", "LMBLEProtocolStatusViewController",
        "LMBLEKeySelfCheckViewController", "LMBLEDebugViewController",
        "LMDiagnosticsViewController",
        # Phase 4
        "LMVehicleProfileViewController", "LMControlPanelViewController",
        # Phase 5
        "LMLocationViewController", "LMChargeViewController",
        # Phase 6
        "LMCar3DViewController", "LMLoveCarViewController",
    ]
    for vc in new_vcs:
        src = read(f"UIKit/{vc}.swift")
        check(f"{vc} 继承 LMBaseViewController",
              re.search(rf"final class {vc}\s*:\s*LMBaseViewController", src) is not None)
        check(f"{vc} 实现了 buildUI / render",
              "override func buildUI()" in src and "override func render()" in src)

    # ---- ⑤ 跨页跳转全部指向新 VC ----
    settings = read("UIKit/LMSettingsViewController.swift")
    for target in ("LMVehicleProfileViewController", "LMLocationViewController",
                   "LMChargeViewController", "LMBLEKeyViewController",
                   "LMSignalExplorerViewController", "LMDiagnosticsViewController",
                   "LMSelfTestViewController"):
        check(f"设置页 → {target}",
              f"pushViewController({target}(client: client)" in settings)

    blekey = read("UIKit/LMBLEKeyViewController.swift")
    check("蓝牙钥匙页 → LMDiagnosticsViewController",
          "LMDiagnosticsViewController(client: client)" in blekey)
    check("蓝牙钥匙页 → LMBLEDebugViewController（复用同一个 ble）",
          "LMBLEDebugViewController(client: client, ble: ble)" in blekey)
    diag = read("UIKit/LMDiagnosticsViewController.swift")
    check("车控体检页 → LMSignalExplorerViewController",
          "LMSignalExplorerViewController(client: client)" in diag)
    lovecar = read("UIKit/LMLoveCarViewController.swift")
    check("爱车页 → LMCar3DViewController（全屏看车）",
          "LMCar3DViewController(client: client)" in lovecar)

    # ---- ⑥ Car3DConfig 只能有一处定义（新旧文件曾重名）----
    defs = [rel for rel, src in _swift_files()
            if re.search(r"(?m)^(?:enum|struct|final class)\s+Car3DConfig\b", src)]
    check("Car3DConfig 只有一处定义",
          defs == ["UIKit/LMCar3DWebView.swift"], f"实际 {defs}")

    # ---- ⑦ 进编译 + 源文件数一致 ----
    pbx_path = os.path.join(os.path.dirname(app_dir),
                            "LeapmotorLite.xcodeproj", "project.pbxproj")
    if os.path.exists(pbx_path):
        with open(pbx_path, "r", encoding="utf-8") as f:
            pbx = f.read()
        for vc in new_vcs:
            check(f"{vc}.swift 已进 Sources", f"/* {vc}.swift */" in pbx)
        disk = sum(1 for _, _, fs in os.walk(app_dir)
                   for f in fs if f.endswith(".swift"))
        in_pbx = pbx.count("in Sources */ = {isa = PBXBuildFile")
        check("磁盘源文件数 == pbxproj 编译源文件数",
              disk == in_pbx, f"磁盘 {disk} vs 工程 {in_pbx}")


def test_dark_theme() -> None:
    """⑮ 视觉重设计「碳黑霓虹」：设计 token + 深色锁定 + 关键页面落地。

    背景（2026-10-09）：用户要求「开始做视觉重设计」，选定「碳黑霓虹」——
    近黑底 + 实心深灰卡 + 发丝描边 + 等宽大数字 + 单一薄荷霓虹点缀。

    这组断言钉住四件事：
      ① 调色板 / 圆角 / 字体三组 token 的**具体值** —— 这是整套设计的根，
         改错了这里先红，不会等到装机才发现「怎么又变回系统蓝了」
      ② 深色外观是**锁定**的：这套设计没有浅色版本，放开会白底白字
      ③ 主色是薄荷 `#00E39A`，不再是系统蓝
      ④ 爱车页那几个标志性改动真的落地了（等宽大数字 / 圆角方形快捷钮 /
         SOC 渐变辉光 / 车底辉光）

    ★ 断言纪律（本项目已经踩过四次假阳性）：一律匹配**真实声明形态**，
      不匹配「某字符串有没有出现在某文件里」。下面注释里出现的 token 名
      不该让断言变绿。
    """
    print("\n[15] 视觉重设计「碳黑霓虹」")

    theme = read("UIKit/LMUIKitTheme.swift")
    app = read("UIKit/LMAppDelegate.swift")
    base = read("UIKit/LMBaseViewController.swift")
    love = read("UIKit/LMLoveCarViewController.swift")
    tabs = read("UIKit/LMMainTabBarController.swift")

    # ---- ① 调色板：值必须逐位对得上 ----
    for name, hexv in (("lmCanvas", "0x0A0A0C"),
                       ("lmCard", "0x131316"),
                       ("lmCardLine", "0x26262C"),
                       ("lmAccent", "0x00E39A"),
                       ("lmAccent2", "0x00B8FF")):
        check(f"调色板 {name} = {hexv}",
              re.search(rf"static let {name}\s*=\s*UIColor\(hex: {hexv}\)",
                        theme) is not None)

    check("主色不再是系统蓝（0.11 / 0.45 / 0.94 已删除）",
          "0.11, green: 0.45, blue: 0.94" not in theme)

    # ---- ② 圆角整体收方一档 ----
    for name, val in (("card", 14), ("tile", 12), ("hero", 16)):
        check(f"LMRadius.{name} = {val}",
              re.search(rf"static let {name}: CGFloat = {val}\b", theme) is not None)

    # ---- ③ 等宽数字字体 ----
    check("有等宽数字字体 LMFont.mono（大数字跳动时不抖）",
          re.search(r"static func mono\(", theme) is not None
          and "monospacedSystemFont" in theme)
    check("等宽数字真的用在了磁贴主值上",
          re.search(r"valueLabel\.font = LMFont\.mono\(", theme) is not None)

    # ---- ④ 深色外观锁定 ----
    check("窗口锁定深色外观（这套设计没有浅色版本）",
          re.search(r"overrideUserInterfaceStyle\s*=\s*\.dark", app) is not None)

    # ---- ⑤ 页面底 + 顶部辉光 ----
    check("页面底色用 lmCanvas（不再是 systemGroupedBackground）",
          "view.backgroundColor = .lmCanvas" in base)
    check("基类铺了顶部辉光底 LMGlowBackdropView",
          "LMGlowBackdropView()" in base)
    check("辉光底被压到最底层（否则会盖住内容）",
          "sendSubviewToBack" in base)
    check("辉光底不吃手势（isUserInteractionEnabled = false）",
          re.search(r"final class LMGlowBackdropView[\s\S]{0,400}?"
                    r"isUserInteractionEnabled = false", theme) is not None)

    # ---- ⑥ 卡片发丝描边（近黑底上靠描边分层）----
    check("卡片带发丝描边",
          "layer.borderColor = UIColor.lmCardLine.cgColor" in theme)
    check("导航栏刷成 lmCanvas 并去掉投影线",
          "ap.backgroundColor = .lmCanvas" in theme and "ap.shadowColor = .clear" in theme)
    check("Tab 栏刷成 lmCanvas 并去掉投影线",
          "tabAp.backgroundColor = .lmCanvas" in tabs
          and "tabAp.shadowColor = .clear" in tabs)
    check("Tab 未选中项压到 lmText3（让选中项自己跳出来）",
          "tabBar.unselectedItemTintColor = .lmText3" in tabs)

    # ---- ⑦ 爱车页的标志性改动 ----
    check("续航大数字用等宽字体",
          re.search(r"rangeNumberLabel\.font = LMFont\.mono\(", love) is not None)
    check("续航 Hero 不再是蓝渐变（改成实心卡 + 薄荷洗色）",
          "rangeHero.backgroundColor = .lmCard" in love
          and "lmAccent2.withAlphaComponent(0.04)" not in love)
    check("快捷操作按钮是圆角方形（cornerRadius 17，不再是圆）",
          "iconCircle.layer.cornerRadius = 17" in love)
    check("SOC 进度条改成渐变 + 辉光",
          "fillGradient" in love and "shadowPath" in love)
    check("SOC 辉光与裁剪拆成两层（同一层会被 masksToBounds 裁掉）",
          re.search(r"private final class LMSOCBarView[\s\S]{0,900}?fillGradient\.masksToBounds = true",
                    love) is not None)
    check("3D 车模底部有辉光",
          "LMCar3DPedestalView" in love)
    check("toast 用近黑文字（薄荷底上白字只有约 1.5:1）",
          "toastLabel.textColor = .lmCanvas" in love)

    # ---- ⑧ 两条新 lint 规则真的注册了 ----
    lint_src = open(os.path.join(ROOT, "ios", "tools", "lint_swift.py"),
                    encoding="utf-8").read()
    check("lint 有 R18（薄荷底白字）", '"R18"' in lint_src)
    check("lint 有 R19（系统语义背景色）", '"R19"' in lint_src)
    # ★ 2026-10-09：R20 是「可选链吞掉 flatMap/compactMap」——
    #   v1.1.5 真烧过一轮 CI（`parkingSnap?.fileUrl.flatMap(URL.init(string:))`）。
    #   本地没 swiftc，只能靠这条静态规则拦，必须保证规则真的注册了。
    check("lint 有 R20（可选链后 flatMap/compactMap）", '"R20"' in lint_src)
    check("R20 真的挂了检查正则（不只是文档）",
          "OPTIONAL_CHAIN_FLATTEN_RE.finditer" in lint_src)


def main() -> int:
    print("=" * 64)
    print("续期契约测试（test_refresh_contract）")
    print("=" * 64)
    if not os.path.isdir(APP):
        print(f"找不到 App 源码目录：{APP}")
        return 2
    test_endpoint()
    test_session_codable()
    test_request_shape()
    test_car3d_assets()
    test_lovecar_page()
    test_location_source()
    test_response_shapes()
    test_charging_center()
    test_car3d_layout()
    test_uikit_skeleton()
    test_uikit_login()
    test_uikit_settings()
    test_uikit_full_migration()
    test_dark_theme()
    print("\n" + "=" * 64)
    if FAILS:
        print(f"失败 {len(FAILS)} 项：")
        for f in FAILS:
            print(f"  · {f}")
        return 1
    print("全部通过 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
