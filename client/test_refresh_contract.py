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
    love = read("Views/LoveCarView.swift")
    check("爱车页内嵌了 3D 车模（Car3DWebView 直接出现在本页）",
          "Car3DWebView(" in love)
    check("爱车页保留了全屏看车入口", "Car3DView()" in love)

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
    love = read("Views/LoveCarView.swift")

    # ① 官方爱车页的模块（顺序即官方截图顺序）
    modules = [
        ("顶部车辆栏", "private func topBar("),
        ("续航主数字 + SOC 进度条 + 车门锁态", "private var rangeHero"),
        ("充电中心入口", "private var chargeCenterChip"),
        ("3D 车模（内嵌）", "private var car3DCard"),
        ("快捷操作分页", "private var quickActionsPager"),
        ("预约充电横幅", "private var appointmentBanner"),
        ("车内温度 / 空调", "private var climateCard"),
        ("地图卡", "private var mapCard"),
        ("蓝牙钥匙卡", "private var bleCard"),
    ]
    for label, token in modules:
        check(f"模块在：{label}", token in love)

    # ② 快捷操作第 1 页必须与官方截图逐字一致
    m = re.search(r"quickPages:\s*\[\[String\]\]\s*=\s*\[\s*\[([^\]]*)\]", love)
    check("找得到 quickPages 定义", m is not None)
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
    check("内嵌车模用 GeometryReader 量宽度",
          re.search(r"GeometryReader\s*\{\s*geo\s+in[\s\S]{0,120}?car3DBody\(width:", love) is not None)
    check("内嵌车模喂 Car3DConfig.appJSON(width:height:)",
          "Car3DConfig.appJSON(width: width, height: height)" in love)

    # ⑤ 反向断言：**不能**把「驻车照片」做成 UI 元素 ——
    #    那个接口在 IPA 字符串表里扫不到、抓包里也没有样本，
    #    本 App 明确不做，不拿假图糊上去。有人「顺手补上」时这里会红。
    #    （只允许它出现在解释「为什么不做」的注释里。）
    check("没有把「驻车照片」做成 UI 元素（接口未确认，明确不做）",
          re.search(r'(?:Text|Label)\(\s*"驻车照片"', love) is None)

    # ⑥ lint R9：读了锁定态就必须挂时钟，否则倒计时冻住
    check("挂了 .lmClock 驱动锁定倒计时", ".lmClock(until:" in love)

    # ⑦ Tab 必须换成爱车页，旧的车况页不能留
    #    ★ 2026-10-09：入口从 SwiftUI 的 `LeapmotorLiteApp.swift`
    #      换成 UIKit 的 `UIKit/LMAppDelegate.swift`，
    #      Tab 定义搬到了 `UIKit/LMMainTabBarController.swift`。
    #      被托管的 SwiftUI 页仍然叫 `LoveCarView()`，只是外面多了
    #      一层 `NavigationStack`（这些页面内部有 NavigationLink）。
    tabs = read("UIKit/LMMainTabBarController.swift")
    check("首 Tab 是 LoveCarView", "LoveCarView()" in tabs)
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
    c3d = read("Views/Car3DView.swift")
    check("Car3DConfig.serverJSON 标了 @MainActor（否则 CI 报 actor 隔离错误）",
          re.search(r"@MainActor\s*\n\s*static func serverJSON\(", c3d) is not None)


def test_location_source() -> None:
    """⑨ 定位数据源：车辆位置必须走 IP 归属地（与官方 App 同源）。

    背景（2026-10-08 用户报）：官方 App 显示车在淮南，本 App 显示合肥。
    根因：之前拿车机 signalMap 的 `2190/2191` 当位置，而那组坐标在
    **60 个抓包样本里一个数字都没变**（31.801201 / 117.342718，指向合肥）
    —— 是静态值，不是实时位置。官方「车辆位置」实际来自 IP 归属地：
        GET https://apptec.leapmotor.cn/ipAnalysis/getAddressByIp
        → {"country":"中国","province":"安徽","city":"淮南"}
    下面几条断言把这个修复钉死，防止以后有人「优化」回用车机坐标。
    """
    print("\n[9] 定位数据源（IP 归属地，与官方同源）")

    client = read("API/LMClient.swift")
    models = read("API/LMModels.swift")
    love = read("Views/LoveCarView.swift")
    loc = read("Views/LocationView.swift")
    ep = read("API/LMEndpoints.swift")

    # 端点
    check("端点表里有 IP 归属地路径", "/ipAnalysis/getAddressByIp" in ep)
    check("IP 归属地走 tecHost（apptec.leapmotor.cn）",
          "tecHost" in ep and "apptec.leapmotor.cn" in ep)

    # 模型
    check("LMIPAddress 有 regionText（省+市，给主位置用）",
          re.search(r"var regionText: String", models) is not None)

    # 客户端
    check("LMClient 暴露结构化 ipAddress",
          re.search(r"var ipAddress: LMIPAddress\?", client) is not None)
    check("refreshAll 里会拉 IP 归属地", "refreshIPAddress()" in client)
    check("refreshIPAddress 走 ipAddress 路径",
          re.search(r"private func refreshIPAddress[\s\S]{0,900}?LMEndpoints\.Path\.ipAddress",
                    client) is not None)

    # 爱车页地图卡：主位置 = IP 归属地
    check("爱车页地图卡读 client.ipAddress", "client.ipAddress" in love)
    check("爱车页地图卡显示 regionText", "ip.regionText" in love)
    check("打开地图优先用 IP 归属地城市名",
          re.search(r"func openInMaps\(\)[\s\S]{0,700}?ip\.regionText", love) is not None)

    # 定位页
    check("定位页有 IP 归属地卡片", "ipLocationCard" in loc)
    check("定位页卡片读 client.ipAddress", "client.ipAddress" in loc)
    check("定位页说明了车机坐标可能长期不变", "一个数字都没动" in loc)

    # 车端未分享位置的提示（复刻官方原话）
    tip = "车端已关闭位置数据分享，无法获取车辆实时位置"
    check("爱车页复刻了官方「车端已关闭位置数据分享」提示", tip in love)
    check("定位页复刻了同一句提示", tip in loc)
    check("该判断用可观测事实（坐标长期不变）而非猜 privacyGPS 语义",
          re.search(r"var carLocationShareOff[\s\S]{0,700}?coordinateUnchangedFor", client) is not None)


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
    view = read("Views/ChargeView.swift")

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
    for card in ("controlCard", "healthCard", "socLimitCard", "appointmentEditor"):
        check(f"ChargeView 有 {card}", re.search(rf"private\s+var\s+{card}\s*:", view) is not None)
    for act in ("runCharging", "runHealth", "runSocLimit", "runAppointment"):
        check(f"ChargeView 有动作 {act}()", re.search(rf"func\s+{act}\(", view) is not None)

    # body 顺序：控制 → 健康 → 上限 → 预约
    idx = [view.find(x) for x in ("controlCard", "healthCard", "socLimitCard", "appointmentEditor")]
    check("四张卡的 body 顺序为 控制→健康→上限→预约",
          all(i >= 0 for i in idx) and idx == sorted(idx), str(idx))

    check("按钮在忙 / 控制锁定期内禁用（controlLockRemaining）",
          "controlLockRemaining() > 0" in view)
    check("下发结果用 alert 回报（不静默）",
          re.search(r"\.alert\(", view) is not None and "toast" in view)

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


def test_car3d_layout() -> None:
    """⑪ 3D 车模：放大 + 提到顶部 + 去掉卡片感。

    背景（2026-10-09 用户报）：「把 3D 车模给放大调到上面跟背景一起」。
    官方爱车页的车模是**页面背景的一部分**（直接浮在页面上），
    而我们之前套了 `LMCard` 式的圆角底色，看起来像一张卡。

    注意「去掉底色」是安全的：`Car3DWebView` 的 WKWebView 已设
    `isOpaque = false` + `backgroundColor = .clear`，所以没有白块。
    """
    print("\n[11] 3D 车模布局（放大 + 上移 + 去卡片感）")

    love = read("Views/LoveCarView.swift")
    c3d = read("Views/Car3DView.swift")

    check("car3DHeight = 330（原 230）",
          re.search(r"var\s+car3DHeight\s*:\s*CGFloat\s*\{\s*330\s*\}", love) is not None)

    # 顺序：topBar → car3DCard → rangeHero
    i_top = love.find("topBar(v)")
    i_car = love.find("car3DCard\n")
    i_rng = love.find("rangeHero\n")
    check("car3DCard 紧跟在 topBar 之后（提到页面顶部）",
          i_top >= 0 and i_car >= 0 and i_top < i_car, f"topBar@{i_top} car3D@{i_car}")
    check("car3DCard 在 rangeHero 之前",
          i_car >= 0 and i_rng >= 0 and i_car < i_rng, f"car3D@{i_car} range@{i_rng}")

    # 去卡片感：car3DBody 里不能再有 secondarySystemBackground / clipShape
    seg = love[love.find("private func car3DBody"):]
    seg = seg[: seg.find("private var car3DFailureView") if "private var car3DFailureView" in seg else 3000]
    check("car3DBody 不再铺 secondarySystemBackground 底色",
          "secondarySystemBackground" not in seg)
    check("car3DBody 不再 clipShape 圆角", "clipShape" not in seg)

    # 安全性前提：WebView 必须透明，否则去底色会露白块
    check("Car3DWebView 设了 isOpaque = false（去底色才安全）",
          "isOpaque = false" in c3d)
    check("Car3DWebView 设了 backgroundColor = .clear",
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

    这组断言钉住三件事：
      ① 入口只有一处 `@main`，且是 AppDelegate（两处 `@main` 直接编译失败）
      ② 骨架各件语义正确（订阅 / 注入 / 换根 / 5 个 Tab / 保留 NavigationStack）
      ③ 六个新文件**真的进了 pbxproj 的 Sources** ——
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

    host = read("UIKit/LMHostingController.swift")
    check("宿主注入 environmentObject(client)", ".environmentObject(client)" in host)
    check("宿主补回全局 tint（否则 SwiftUI 控件退回系统蓝）",
          ".tint(Color.lmAccent)" in host)

    tabs = read("UIKit/LMMainTabBarController.swift")
    for name in ("爱车", "定位", "充电", "车控", "设置"):
        check(f"Tab 里有「{name}」", f'"{name}"' in tabs)
    # ★ Phase 2：设置页已迁成 UIKit，它那一行不再是托管页 ——
    #   必须由 LMNavigationController 提供导航栏（否则它没法 push 那 7 个子页），
    #   所以「保留 NavigationStack」的只剩 4 个还没迁的 Tab。
    check("还没迁的 4 个托管页各自保留了 NavigationStack（否则内部跳转静默失效）",
          tabs.count("NavigationStack {") == 4)
    check("设置 Tab 已是原生 UIKit 页",
          "LMSettingsViewController(client: client)" in tabs)
    check("设置 Tab 由 LMNavigationController 承载（push 子页的前提）",
          "LMNavigationController(" in tabs)
    # ★ 不能用 `"SettingsView()" not in tabs` —— 本文件注释里为了解释
    #   「为什么不能再 NavigationLink { SettingsView() }」必然写出这个词，
    #   裸串断言会自己踩自己。这里匹配**真实的托管形态**。
    check("设置 Tab 不再是 SwiftUI 托管页",
          re.search(r"NavigationStack\s*\{\s*SettingsView\(\)", tabs) is None)

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
                   "LMHostingController.swift", "LMMainTabBarController.swift",
                   "LMRootViewController.swift", "LMUIKitTheme.swift",
                   "LMLoginViewController.swift"):
            check(f"{fn} 已进 Sources（否则 CI 绿但功能静默缺失）",
                  f"{fn} in Sources" in pbx)
        check("旧入口 LeapmotorLiteApp.swift 已从工程移除",
              "LeapmotorLiteApp.swift" not in pbx)
    check("旧入口文件已删除",
          not os.path.exists(os.path.join(app_dir, "LeapmotorLiteApp.swift")))

    gen = os.path.join(root, "ios", "tools", "gen_xcodeproj.py")
    if os.path.exists(gen):
        with open(gen, "r", encoding="utf-8") as f:
            gsrc = f.read()
        check("gen_xcodeproj.py 的 DIR_ORDER 含 UIKit", '"UIKit"' in gsrc)


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
      B. **子页跳转不能断** —— 设置页要 push 7 个还没迁移的 SwiftUI 页，
         其中 `BLEKeyView` / `DiagnosticsView` 内部还有 `NavigationLink`，
         所以必须走 `ownsNavigationBar: true`（自带 NavigationStack + 补返回键）。

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

    # ---- ⑤ 7 个子页跳转入口都在 ----
    for page in ("VehicleProfileView", "LocationView", "ChargeView", "BLEKeyView",
                 "SignalExplorerView", "DiagnosticsView", "SelfTestView"):
        check(f"设置页仍能跳到 {page}", f"{page}()" in vc)

    # ---- ⑥ 导航架构：push 出去的 SwiftUI 页必须自带 NavigationStack ----
    check("push 子页时打开 ownsNavigationBar"
          "（否则 BLEKeyView / DiagnosticsView 内部跳转静默失效）",
          "ownsNavigationBar: true" in vc)
    check("push 子页时补了返回键（NavigationStack 作为栈底本来没有）",
          "onBack:" in vc and "popViewController(animated: true)" in vc)
    host = read("UIKit/LMHostingController.swift")
    check("宿主在 ownsNavigationBar 模式下藏掉外层 UIKit 导航栏（否则双导航栏）",
          "setNavigationBarHidden(true" in host)
    check("宿主离开时恢复外层导航栏（否则返回后设置页也没栏了）",
          "setNavigationBarHidden(false" in host)

    # ---- ⑦ 爱车页那个齿轮入口 ----
    lovecar = read("Views/LoveCarView.swift")
    check("爱车页齿轮改成切「设置」Tab"
          "（UIKit 页没法塞进 SwiftUI 的 NavigationStack）",
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
