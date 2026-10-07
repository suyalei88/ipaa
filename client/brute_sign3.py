#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用二进制里的硬编码 hex 常量当 key 暴力匹配签名。"""
import base64
import hashlib
import hmac
import re
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

BIN = "evidence/unpack_ios/Payload/leapmotorCarOwner.app/leapmotorCarOwner"
data = open(BIN, "rb").read()
HEXES = sorted(set(m.group().decode() for m in re.finditer(rb"\b[0-9a-f]{32}\b", data)))


def sm3_hex(b):
    return sm3.sm3_hash(func.bytes_to_list(b))


def hmac_sm3(key, msg):
    block = 64
    if len(key) > block:
        key = bytes.fromhex(sm3_hex(key))
    key = key.ljust(block, b"\x00")
    o = bytes(k ^ 0x5c for k in key)
    i = bytes(k ^ 0x36 for k in key)
    return sm3_hex(o + bytes.fromhex(sm3_hex(i + msg)))


def keys():
    for h in HEXES:
        yield f"hex:{h}", h.encode()
        yield f"hexbytes:{h}", bytes.fromhex(h)
    yield "r2_utf8", R2.encode()
    yield "r3_utf8", R3.encode()
    yield "r2_b64", base64.b64decode(R2)
    yield "r3_b64", base64.b64decode(R3)
    yield "md5(r2_utf8)", hashlib.md5(R2.encode()).hexdigest().encode()
    yield "md5(r2_b64)", hashlib.md5(base64.b64decode(R2)).hexdigest().encode()


def messages():
    items = sorted(list(BODY.items()) + list(HDRS.items()), key=lambda kv: kv[0])
    yield "vals", "".join(str(v) for _, v in items)
    yield "kv_eq_amp", "&".join(f"{k}={v}" for k, v in items)
    yield "vals+path", "".join(str(v) for _, v in items) + PATH
    yield "rawbody", RAW_BODY


hits = 0
for kname, key in keys():
    for mname, msg in messages():
        mb = msg.encode()
        cands = {
            "hmac_sha256": hmac.new(key, mb, hashlib.sha256).hexdigest(),
            "hmac_sm3": hmac_sm3(key, mb),
            "sm3(msg+key)": sm3_hex(mb + key),
            "sm3(key+msg)": sm3_hex(key + mb),
            "sha256(msg+key)": hashlib.sha256(mb + key).hexdigest(),
            "sha256(key+msg)": hashlib.sha256(key + mb).hexdigest(),
        }
        for an, out in cands.items():
            if out == SIGN:
                print(f"✅ MATCH key={kname} msg={mname} alg={an}")
                hits += 1
print("命中:", hits)
