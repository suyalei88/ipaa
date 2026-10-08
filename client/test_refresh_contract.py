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

    for field in ("tokenExpireTime", "tokenIssuedAt"):
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
    print("\n[3] 续期请求体 / 触发点")
    src = read("API/LMClient.swift")

    check("performRefresh 用 refreshToken 作为 body 键",
          re.search(r'body:\s*\[\s*"refreshToken"\s*:', src) is not None)
    check("续期走 preLoginRequest（无密钥 SHA256 签名）",
          re.search(r"preLoginRequest\(path:\s*LMEndpoints\.Path\.refreshToken", src) is not None)
    check("有并发去重（refreshTask）", "private var refreshTask" in src)
    check("request(...) 会主动续期",
          re.search(r"await\s+refreshSessionIfNeeded\(\)", src) is not None)
    check("request(...) 有被动重放",
          re.search(r"looksLikeTokenExpired", src) is not None
          and src.count("sendWithFreshHeaders") >= 3)
    check("401/403 被当作 token 失效", "code == 401 || code == 403" in src)


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
