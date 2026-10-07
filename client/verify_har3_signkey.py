#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 HAR3(15:30) 的登录响应推导 signKey，再拿 HAR3 里的签名请求独立验证。"""
import json, sys, os
sys.path.insert(0, "client")
from leapmotor_client import (derive_keys_from_login, build_sign_value_string,
                              generate_hmac_sha256, SIGN_HEADER_KEYS)

HAR = sys.argv[1] if len(sys.argv) > 1 else \
    "C:/Users/litong/Desktop/appgateway.leapmotor.com_2026_10_07_15_30_32.har"

h = json.load(open(HAR, encoding="utf-8"))
entries = h["log"]["entries"]

# ---- 1) find login response carrying signParam ----
login = None
for i, e in enumerate(entries):
    rt = e.get("response", {}).get("content", {}).get("text", "") or ""
    if "signParam" in rt and "accessToken" in rt:
        try:
            j = json.loads(rt)
        except Exception:
            continue
        d = j.get("data") or {}
        if d.get("signParam") and d.get("accessToken"):
            login = (i, d)
            break

if not login:
    print("[!] no login-with-signParam in", os.path.basename(HAR)); sys.exit(1)

idx, d = login
keys = derive_keys_from_login(d)
print(f"login entry [{idx}]  accountId={d.get('accountId')}")
print("  accessToken  =", d["accessToken"][:60], "...")
print("  signParam.r2 =", d["signParam"]["r2"])
print("  signParam.r3 =", d["signParam"]["r3"])
print("  => signKey   =", keys.get("sign_key_hex"))
print("  => encKey    =", keys.get("encrypt_key_hex"))
sk = keys.get("sign_key")
if not sk:
    sys.exit(1)

# ---- 2) verify against every signed request in the same HAR ----
def hdr(e, name):
    for k, v in e["request"].get("headers", []):
        if k.lower() == name.lower():
            return v
    return None

ok = bad = 0
badlist = []
for i, e in enumerate(entries):
    sig = hdr(e, "sign")
    if not sig:
        continue
    sh = {k: hdr(e, k) for k in SIGN_HEADER_KEYS}
    if any(v is None for v in sh.values()):
        continue
    body = None
    pd = e["request"].get("postData", {}).get("text")
    if pd:
        try:
            body = json.loads(pd)
        except Exception:
            body = None
    try:
        vs = build_sign_value_string(body, sh)
        mine = generate_hmac_sha256(vs, sk)
    except Exception as ex:
        bad += 1; badlist.append((i, f"exc {ex}")); continue
    if mine and mine.lower() == sig.lower():
        ok += 1
    else:
        bad += 1
        badlist.append((i, f"{e['request']['method']} {e['request']['url'][-70:]}"))

print(f"\n=== HAR3 signature verification with derived signKey ===")
print(f"    OK  = {ok}")
print(f"    BAD = {bad}")
for i, info in badlist[:10]:
    print(f"      [{i}] {info}")
