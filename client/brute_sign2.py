#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""含国密 SM3 的签名暴力匹配。"""
import base64
import hashlib
import hmac
import urllib.parse
from gmssl import sm3, func

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


def sm3_hex(b):
    return sm3.sm3_hash(func.bytes_to_list(b))


def hmac_sm3_hex(key: bytes, msg: bytes) -> str:
    """HMAC-SM3 (RFC2104, block 64)"""
    block = 64
    if len(key) > block:
        key = bytes.fromhex(sm3_hex(key))
    key = key.ljust(block, b"\x00")
    o_pad = bytes(k ^ 0x5c for k in key)
    i_pad = bytes(k ^ 0x36 for k in key)
    inner = bytes.fromhex(sm3_hex(i_pad + msg))
    return sm3_hex(o_pad + inner)


def b64(s):
    return base64.b64decode(s)


def keys():
    yield "r2_utf8", R2.encode()
    yield "r3_utf8", R3.encode()
    yield "r2_b64", b64(R2)
    yield "r3_b64", b64(R3)
    yield "r2r3_b64", b64(R2) + b64(R3)
    yield "r2_b64_hex", b64(R2).hex().encode()
    yield "r3_b64_hex", b64(R3).hex().encode()


def messages():
    items = sorted(list(BODY.items()) + list(HDRS.items()), key=lambda kv: kv[0])
    vals = "".join(str(v) for _, v in items)
    kveq = "&".join(f"{k}={v}" for k, v in items)
    yield "vals", vals
    yield "kv_eq_amp", kveq
    yield "vals+path", vals + PATH
    yield "path+vals", PATH + vals
    yield "rawbody", RAW_BODY


print("target:", SIGN)
hits = 0
for kname, key in keys():
    for mname, msg in messages():
        mb = msg.encode()
        cands = {
            "hmac_sm3": hmac_sm3_hex(key, mb),
            "sm3(msg+key)": sm3_hex(mb + key),
            "sm3(key+msg)": sm3_hex(key + mb),
            "hmac_sha256": hmac.new(key, mb, hashlib.sha256).hexdigest(),
            "sha256(msg+key)": hashlib.sha256(mb + key).hexdigest(),
            "sha256(key+msg)": hashlib.sha256(key + mb).hexdigest(),
        }
        for an, out in cands.items():
            if out == SIGN:
                print(f"✅ MATCH key={kname} msg={mname} alg={an}")
                print(f"   message = {msg}")
                hits += 1
print("命中:", hits)
