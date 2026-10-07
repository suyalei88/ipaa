#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""双靶点暴力匹配：登录请求 + 车控请求。找出 key 与消息格式。"""
import base64
import hashlib
import hmac
import itertools
import json
import re
import urllib.parse
from gmssl import sm3, func

BIN = "evidence/unpack_ios/Payload/leapmotorCarOwner.app/leapmotorCarOwner"
data = open(BIN, "rb").read()
HEXES = sorted(set(m.group().decode() for m in re.finditer(rb"\b[0-9a-f]{32}\b", data)))

# ---------- 靶点 A: 登录 ----------
A = {
    "sign": "ed5cccd2065123cc3f659407e1628712ec003340e65ba412c4357137140d1647",
    "path": "/base/base-user/account/v1/login",
    "body": {"identifier": "672955179229782016", "identifierType": "1",
             "security": "3DD9DF4A2A5F4367B5E63F22A36DF2A13DD9DF4A2A5F4367B5E63F22A36DF2A1"},
    "headers": {"source": "leapmotor", "deviceType": "iOS", "channel": "1",
                "version": "1.22.68", "nonce": "1301767810",
                "deviceId": "ios_ee45b9d830bb126d431e998943a7797a",
                "timestamp": "1791350603048", "acceptLanguage": "zh-CN"},
}

# ---------- 靶点 B: 车控 ----------
B = {
    "sign": "cb711ef16bc1ff5d50177bce1d17c303e464e4fef05a1b92911f7ab5440888f6",
    "path": "/app/app-control-service/v3/api/appremotectl",
    "body": dict(urllib.parse.parse_qsl(
        'carvin=LFZ63AA15TH035113&cmdid=400&oppwd=uHTigfMDS5zIuZX4Gq4NVQ%3D%3D&state=%7B%22operation%22%3A%22on%22%7D')),
    "headers": {"acceptLanguage": "zh-CN", "deviceType": "iOS", "source": "leapmotor",
                "version": "1.22.68", "channel": "1",
                "deviceId": "ios_ee45b9d830bb126d431e998943a7797a",
                "timestamp": "1791350711516", "nonce": "470844264"},
}


def sm3_hex(b):
    return sm3.sm3_hash(func.bytes_to_list(b))


def hmac_sm3(key, msg):
    if len(key) > 64:
        key = bytes.fromhex(sm3_hex(key))
    key = key.ljust(64, b"\x00")
    o = bytes(k ^ 0x5c for k in key)
    i = bytes(k ^ 0x36 for k in key)
    return sm3_hex(o + bytes.fromhex(sm3_hex(i + msg)))


def messages(r):
    body, hdrs, path = r["body"], r["headers"], r["path"]
    items = sorted(list(body.items()) + list(hdrs.items()), key=lambda kv: kv[0])
    vals = "".join(str(v) for _, v in items)
    kveq = "&".join(f"{k}={v}" for k, v in items)
    kvno = "".join(f"{k}{v}" for k, v in items)
    bvals = "".join(str(v) for _, v in sorted(body.items()))
    hvals = "".join(str(v) for _, v in sorted(hdrs.items()))
    return {
        "sorted_vals": vals,
        "sorted_kv&": kveq,
        "sorted_kv": kvno,
        "body_vals": bvals,
        "hdr_vals": hvals,
        "body+path": bvals + path,
        "path+body": path + bvals,
        "hdr+body": hvals + bvals,
        "sorted_vals+path": vals + path,
        "path+sorted_vals": path + vals,
        "json": json.dumps(body, separators=(",", ":")),
    }


def keys():
    for h in HEXES:
        yield f"hexstr:{h}", h.encode()
        yield f"hexbytes:{h}", bytes.fromhex(h)
        yield f"HEXupper:{h}", h.upper().encode()


R2 = "6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo="
R3 = "XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884="
for nm, v in [("r2", R2), ("r3", R3)]:
    keys_extra = [("utf8", v.encode()), ("b64", base64.b64decode(v)),
                  ("md5hex", hashlib.md5(v.encode()).hexdigest().encode())]


def all_keys():
    yield from keys()
    for nm, v in [("r2", R2), ("r3", R3)]:
        yield f"{nm}_utf8", v.encode()
        yield f"{nm}_b64", base64.b64decode(v)
        yield f"{nm}_md5hex", hashlib.md5(v.encode()).hexdigest().encode()
        yield f"{nm}_b64md5hex", hashlib.md5(base64.b64decode(v)).hexdigest().encode()


def algs():
    return {
        "hmac_sha256": lambda k, m: hmac.new(k, m, hashlib.sha256).hexdigest(),
        "hmac_sha1": lambda k, m: hmac.new(k, m, hashlib.sha1).hexdigest(),
        "hmac_md5": lambda k, m: hmac.new(k, m, hashlib.md5).hexdigest(),
        "hmac_sm3": hmac_sm3,
        "sm3_m_k": lambda k, m: sm3_hex(m + k),
        "sm3_k_m": lambda k, m: sm3_hex(k + m),
        "sha256_m_k": lambda k, m: hashlib.sha256(m + k).hexdigest(),
        "sha256_k_m": lambda k, m: hashlib.sha256(k + m).hexdigest(),
    }


targets = {"A_login": A, "B_ctl": B}
found = 0
for tname, r in targets.items():
    for mname, msg in messages(r).items():
        mb = msg.encode()
        for kname, key in all_keys():
            for an, fn in algs().items():
                try:
                    out = fn(key, mb)
                except Exception:
                    continue
                if out == r["sign"]:
                    print(f"✅ MATCH [{tname}] key={kname} msg={mname} alg={an}")
                    print(f"   message = {msg}")
                    found += 1
print("命中:", found)
