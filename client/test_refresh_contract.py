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
    app = read("LeapmotorLiteApp.swift")
    check("首 Tab 是 LoveCarView", "LoveCarView()" in app)
    check("Tab 标签叫「爱车」", 'Label("爱车"' in app)
    check("旧 DashboardView 已移除", not os.path.exists(os.path.join(APP, "Views", "DashboardView.swift")))
    check("代码里没有 DashboardView 残留",
          "DashboardView" not in app and "DashboardView" not in love)

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
    **111 个抓包样本里一个数字都没变**（31.801201 / 117.342718，指向合肥）
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
