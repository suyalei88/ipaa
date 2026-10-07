#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""大范围暴力匹配签名：多种 key 派生 × 多种消息拼接。"""
import base64
import hashlib
import hmac
import json
import urllib.parse

SIGN = "cb711ef16bc1ff5d50177bce1d17c303e464e4fef05a1b92911f7ab5440888f6"
PATH = "/app/app-control-service/v3/api/appremotectl"
HDRS = {"acceptLanguage": "zh-CN", "deviceType": "iOS", "source": "leapmotor",
        "version": "1.22.68", "channel": "1",
        "deviceId": "ios_ee45b9d830bb126d431e998943a7797a",
        "timestamp": "1791350711516", "nonce": "470844264"}
RAW_BODY = 'carvin=LFZ63AA15TH035113&cmdid=400&oppwd=uHTigfMDS5zIuZX4Gq4NVQ%3D%3D&state=%7B%22operation%22%3A%22on%22%7D'
BODY = dict(urllib.parse.parse_qsl(RAW_BODY))

R2 = "6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo="
R3 = "XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884="
E2 = "cYPovbbtY3Bxv+9m0+0+2v7CRs/s1FWbotOguVLySys="
E3 = "xnYhizldbR6gC4IUdU3o9aN5+Wv9RW95VoxyjSa6BR8="


def b64(s):
    return base64.b64decode(s)


def keys():
    yield "r2_utf8", R2.encode()
    yield "r3_utf8", R3.encode()
    yield "r2_b64", b64(R2)
    yield "r3_b64", b64(R3)
    yield "r2r3_b64", b64(R2) + b64(R3)
    yield "e2_b64", b64(E2)
    yield "e3_b64", b64(E3)
    yield "e2_utf8", E2.encode()
    # md5/sha 派生
    for name, raw in [("r2_utf8", R2.encode()), ("r3_utf8", R3.encode()),
                      ("r2_b64", b64(R2)), ("r3_b64", b64(R3))]:
        yield f"md5hex({name})", hashlib.md5(raw).hexdigest().encode()
        yield f"md5raw({name})", hashlib.md5(raw).digest()
        yield f"sha256hex({name})", hashlib.sha256(raw).hexdigest().encode()
        yield f"sha256raw({name})", hashlib.sha256(raw).digest()
    # hex of decoded
    yield "hex(r2_b64)", b64(R2).hex().encode()
    yield "hex(r3_b64)", b64(R3).hex().encode()
    # halves
    yield "r2_b64[:16]", b64(R2)[:16]
    yield "r2_b64[16:]", b64(R2)[16:]
    yield "r3_b64[:16]", b64(R3)[:16]
    yield "r3_b64[16:]", b64(R3)[16:]


def messages():
    items = sorted(list(BODY.items()) + list(HDRS.items()), key=lambda kv: kv[0])
    vals = "".join(str(v) for _, v in items)
    kveq = "&".join(f"{k}={v}" for k, v in items)
    kvnoeq = "".join(f"{k}{v}" for k, v in items)
    yield "vals", vals
    yield "kv_eq_amp", kveq
    yield "kv_noeq", kvnoeq
    yield "vals+path", vals + PATH
    yield "path+vals", PATH + vals
    yield "kv_eq_amp+path", kveq + PATH
    yield "rawbody", RAW_BODY
    yield "vals+rawbody", vals + RAW_BODY
    yield "rawbody+vals", RAW_BODY + vals
    yield "vals_sortedbody_first", "".join(str(v) for _, v in sorted(BODY.items())) + "".join(str(v) for _, v in sorted(HDRS.items()))


hits = 0
for kname, key in keys():
    for mname, msg in messages():
        for alg in (hashlib.sha256, hashlib.sha1, hashlib.md5):
            try:
                out = hmac.new(key, msg.encode(), alg).hexdigest()
            except Exception:
                continue
            if out == SIGN:
                print(f"✅ MATCH  key={kname}  msg={mname}  alg={alg().name}")
                print(f"   message = {msg}")
                hits += 1
print(f"\n命中 {hits} 个")
if not hits:
    print("仍未命中 → key 可能由原生运行时派生（如 SM2 解密 r2/r3，或 r2 XOR 设备信息）")
