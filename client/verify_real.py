#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用真实抓包验证签名算法 —— 暴力匹配 signKey 解析方式与拼接方式。
输入: 车控请求 (headers + body + sign) + 登录响应 signParam
"""
import base64
import hashlib
import hmac
import itertools
import json
import urllib.parse

# ---- 抓到的车控请求 ----
SIGN = "cb711ef16bc1ff5d50177bce1d17c303e464e4fef05a1b92911f7ab5440888f6"
HDRS = {
    "acceptlanguage": "zh-CN",
    "devicetype": "iOS",
    "source": "leapmotor",
    "version": "1.22.68",
    "channel": "1",
    "deviceid": "ios_ee45b9d830bb126d431e998943a7797a",
    "timestamp": "1791350711516",
    "nonce": "470844264",
}
RAW_BODY = 'carvin=LFZ63AA15TH035113&cmdid=400&oppwd=uHTigfMDS5zIuZX4Gq4NVQ%3D%3D&state=%7B%22operation%22%3A%22on%22%7D'

# ---- 登录响应里的密钥 ----
R2 = "6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo="
R3 = "XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884="


def js_str(v):
    if v is True: return "true"
    if v is False: return "false"
    if v is None: return ""
    if isinstance(v, float) and v.is_integer(): return str(int(v))
    return str(v)


def build_value_str(body: dict, sh: dict):
    o = {}
    o.update(body)
    o.update(sh)
    items = [(k, v) for k, v in o.items() if v is not None and v != ""]
    items.sort(key=lambda kv: kv[0])
    return "".join(js_str(v) for _, v in items)


def body_variants():
    yield "form_decoded", {k: v for k, v in urllib.parse.parse_qsl(RAW_BODY)}
    yield "form_raw", dict(kv.split("=", 1) for kv in RAW_BODY.split("&") if "=" in kv)
    yield "json_parse", json.loads(RAW_BODY) if RAW_BODY.startswith("{") else {}
    yield "empty", {}


def key_variants():
    yield "r2_utf8", R2.encode()
    yield "r3_utf8", R3.encode()
    yield "r2_b64", base64.b64decode(R2)
    yield "r3_b64", base64.b64decode(R3)
    yield "r2r3_utf8", (R2 + R3).encode()
    yield "r2r3_b64cat", base64.b64decode(R2) + base64.b64decode(R3)
    yield "r2_nopad", R2.rstrip("=").encode()


# header 键名大小写变体
HDR_VARIANTS = {
    "rn_camel": {"acceptLanguage": HDRS["acceptlanguage"], "deviceType": HDRS["devicetype"],
                 "source": HDRS["source"], "version": HDRS["version"], "channel": HDRS["channel"],
                 "deviceId": HDRS["deviceid"], "timestamp": HDRS["timestamp"], "nonce": HDRS["nonce"]},
    "wire_lower": {k: v for k, v in HDRS.items()},
}

print("target sign =", SIGN)
print("=" * 70)
found = []
for bname, body in body_variants():
    for hname, sh in HDR_VARIANTS.items():
        vs = build_value_str(body, sh)
        for kname, key in key_variants():
            out = hmac.new(key, vs.encode(), hashlib.sha256).hexdigest()
            if out == SIGN:
                found.append((bname, hname, kname, vs))
                print(f"\n✅ MATCH!  body={bname}  headers={hname}  key={kname}")
                print(f"   valueStr = {vs}")
                print(f"   sign     = {out}")

if not found:
    print("\n❌ 直接组合未命中，打印所有 valueStr 供人工比对：")
    for bname, body in body_variants():
        for hname, sh in HDR_VARIANTS.items():
            print(f"\n-- body={bname} headers={hname} --")
            print("   ", build_value_str(body, sh))
