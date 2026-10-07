#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""最后一轮：扩展头集合 + r2/r3 组合 key。"""
import base64
import hashlib
import hmac
import urllib.parse

SIGN = "cb711ef16bc1ff5d50177bce1d17c303e464e4fef05a1b92911f7ab5440888f6"
PATH = "/app/app-control-service/v3/api/appremotectl"
BODY = dict(urllib.parse.parse_qsl(
    'carvin=LFZ63AA15TH035113&cmdid=400&oppwd=uHTigfMDS5zIuZX4Gq4NVQ%3D%3D&state=%7B%22operation%22%3A%22on%22%7D'))

CORE = {"acceptLanguage": "zh-CN", "deviceType": "iOS", "source": "leapmotor",
        "version": "1.22.68", "channel": "1",
        "deviceId": "ios_ee45b9d830bb126d431e998943a7797a",
        "timestamp": "1791350711516", "nonce": "470844264"}
EXTRA = {"userId": "672955179229782016", "carvin": "LFZ63AA15TH035113",
         "cartype": "D19", "xRegion": "CN", "xSubversion": "3.22.2-3",
         "xApiSignatureVersion": "2.0"}

R2 = "6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo="
R3 = "XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884="
b2, b3 = base64.b64decode(R2), base64.b64decode(R3)


def hdrs_sets():
    yield "core", CORE
    yield "core+userid", {**CORE, "userId": EXTRA["userId"]}
    yield "core+carvin+cartype", {**CORE, "carvin": EXTRA["carvin"], "cartype": EXTRA["cartype"]}
    yield "core+all", {**CORE, **EXTRA}


def keys():
    yield "r2_b64", b2
    yield "r3_b64", b3
    yield "r2^r3", bytes(a ^ b for a, b in zip(b2, b3))
    yield "r2+r3", b2 + b3
    yield "r3+r2", b3 + b2
    yield "r2_b64_utf8", R2.encode()
    yield "r3_b64_utf8", R3.encode()
    yield "md5(r2^r3)", hashlib.md5(bytes(a ^ b for a, b in zip(b2, b3))).digest()
    yield "sha256(r2^r3)", hashlib.sha256(bytes(a ^ b for a, b in zip(b2, b3))).digest()
    yield "md5(r2_b64)", hashlib.md5(b2).digest()
    yield "md5(r3_b64)", hashlib.md5(b3).digest()


def msgs(body, hdrs):
    items = sorted(list(body.items()) + list(hdrs.items()), key=lambda kv: kv[0])
    yield "sorted_vals", "".join(str(v) for _, v in items)
    yield "sorted_kv&", "&".join(f"{k}={v}" for k, v in items)
    yield "sorted_kv&+path", "&".join(f"{k}={v}" for k, v in items) + PATH
    yield "sorted_vals+path", "".join(str(v) for _, v in items) + PATH
    # body 与 header 分开拼
    yield "bodyvals+hdrvals", "".join(str(v) for _, v in sorted(body.items())) + "".join(str(v) for _, v in sorted(hdrs.items()))


hits = 0
for hn, hdrs in hdrs_sets():
    for mn, msg in msgs(BODY, hdrs):
        mb = msg.encode()
        for kn, key in keys():
            for an, fn in {
                "hmac_sha256": lambda k, m: hmac.new(k, m, hashlib.sha256).hexdigest(),
                "hmac_sha1": lambda k, m: hmac.new(k, m, hashlib.sha1).hexdigest(),
                "sha256(k+m)": lambda k, m: hashlib.sha256(k + m).hexdigest(),
                "sha256(m+k)": lambda k, m: hashlib.sha256(m + k).hexdigest(),
            }.items():
                if fn(key, mb) == SIGN:
                    print(f"✅ MATCH hdr={hn} msg={mn} key={kn} alg={an}")
                    print("   msg:", msg)
                    hits += 1
print("命中:", hits)
