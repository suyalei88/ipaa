#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""derive_signkey.py —— 从登录响应推导 signKey / encryptKey 并用真实抓包闭环验证

算法（iOS `-[LMVLocalLoginModel modelCustomTransformFromDictionary:]`
@0x106e82c30 + `+[LMVLocalLoginModel xorThreeData:data2:data3:]` @0x106e830fc）:

    parts  = accessToken.componentsSeparatedByString(".")
    d1     = base64decode( base64URLToBase64( parts[2] ) )
    d2     = base64decode( signParam.r2 )
    d3     = base64decode( signParam.r3 )
    signKey      = UPPER( hex( XOR3(d1, d2, d3) ) )      -> HKDFDeriveKey
    encryptKey   = UPPER( hex( XOR3(d1, e2, e3) ) )      -> HKDFEncryptKey

    XOR3: n = max(len); out[i] = a[i]^b[i]^c[i]  (越界字节取 0)

用法:
    python client/derive_signkey.py --har evidence/har_appgw.har
    python client/derive_signkey.py --har evidence/har_appgw.har --verify
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_against_har import build_value_str, SIGN_KEYS  # noqa: E402


def b64url_to_b64(s: str) -> str:
    s = s.replace("-", "+").replace("_", "/")
    return s + "=" * (-len(s) % 4)


def b64d(s: str) -> bytes:
    s = s.strip()
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s)


def xor3(d1: bytes, d2: bytes, d3: bytes) -> bytes:
    n = max(len(d1), len(d2), len(d3))
    out = bytearray(n)
    for i in range(n):
        a = d1[i] if i < len(d1) else 0
        b = d2[i] if i < len(d2) else 0
        c = d3[i] if i < len(d3) else 0
        out[i] = a ^ b ^ c
    return bytes(out)


def derive_keys(login_data: dict) -> dict:
    tok = login_data["accessToken"]
    parts = tok.split(".")
    if len(parts) < 3:
        raise ValueError("accessToken 不是 >=3 段的 JWT")
    d1 = b64d(b64url_to_b64(parts[2]))

    sp = login_data.get("signParam") or {}
    ep = login_data.get("encryptParam") or {}
    out = {"jwt_sig": d1, "token_parts": parts}

    if sp.get("r2") and sp.get("r3"):
        d2, d3 = b64d(sp["r2"]), b64d(sp["r3"])
        k = xor3(d1, d2, d3)
        out["sign_key_hex"] = k.hex().upper()
        out["sign_key"] = k
        out["sign_r2"] = d2
        out["sign_r3"] = d3
    if ep.get("r2") and ep.get("r3"):
        e2, e3 = b64d(ep["r2"]), b64d(ep["r3"])
        k = xor3(d1, e2, e3)
        out["enc_key_hex"] = k.hex().upper()
        out["enc_key"] = k
        out["enc_r2"] = e2
        out["enc_r3"] = e3
    return out


def find_login(har: dict):
    for e in har["log"]["entries"]:
        u = e["request"]["url"]
        if u.endswith("/account/v1/login") and e["response"]["status"] == 200:
            txt = e["response"]["content"].get("text", "")
            if txt.strip().startswith("{"):
                try:
                    j = json.loads(txt)
                except Exception:
                    continue
                if isinstance(j, dict) and isinstance(j.get("data"), dict):
                    return j["data"]
    return None


def har_samples(har: dict):
    """把 HAR 里所有带 sign 头的请求抽成 verify_against_har 用的样本格式。"""
    out = []
    for e in har["log"]["entries"]:
        req = e["request"]
        H = {}
        for h in req.get("headers", []):
            H[h["name"].lower()] = h["value"]
        if "sign" not in H:
            continue
        body = (req.get("postData") or {}).get("text", "")
        out.append({"url": req["url"], "H": H, "body": body})
    return out


def verify(samples, key: bytes):
    ok, bad = 0, []
    for i, s in enumerate(samples):
        try:
            vs = build_value_str(s)
        except Exception as ex:
            bad.append((i, "builderr:" + str(ex), "", ""))
            continue
        sig = hmac.new(key, vs.encode("utf-8"), hashlib.sha256).hexdigest()
        if sig == s["H"]["sign"]:
            ok += 1
        elif len(bad) < 5:
            bad.append((i, s["H"]["sign"], sig, vs[:160]))
    return ok, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--har", default="evidence/har_appgw.har")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--dump", help="把派生结果写 JSON")
    args = ap.parse_args()

    har = json.load(open(args.har, encoding="utf-8"))
    data = find_login(har)
    if not data:
        print("!! 该 HAR 里没有明文登录响应")
        return 2

    k = derive_keys(data)
    print("=" * 72)
    print("accessToken parts : %d" % len(k["token_parts"]))
    print("jwt sig (part[2]) : %s" % k["token_parts"][2])
    print("jwt sig bytes     : %d  %s" % (len(k["jwt_sig"]), k["jwt_sig"].hex()))
    if "sign_r2" in k:
        print("signR2 bytes      : %d  %s" % (len(k["sign_r2"]), k["sign_r2"].hex()))
        print("signR3 bytes      : %d  %s" % (len(k["sign_r3"]), k["sign_r3"].hex()))
        print("--> signKey hex   : %s" % k["sign_key_hex"])
        print("--> signKey len   : %d bytes" % len(k["sign_key"]))
    if "enc_key_hex" in k:
        print("--> encKey  hex   : %s" % k["enc_key_hex"])
    print("=" * 72)

    if args.verify:
        samples = har_samples(har)
        print("样本数(带 sign 头) : %d" % len(samples))
        for label, key in (("signKey", k.get("sign_key")), ("encKey", k.get("enc_key"))):
            if not key:
                continue
            ok, bad = verify(samples, key)
            status = "MATCH ✅" if ok == len(samples) else "MISMATCH ❌"
            print(f"[{label}] {status}  {ok}/{len(samples)}")
            for i, exp, got, vs in bad:
                print(f"   sample[{i}] valueStr={vs}")
                print(f"      expect={exp}")
                print(f"      actual={got}")

    if args.dump:
        ser = {kk: (vv.hex() if isinstance(vv, bytes) else vv) for kk, vv in k.items()}
        json.dump(ser, open(args.dump, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print("wrote", args.dump)
    return 0


if __name__ == "__main__":
    sys.exit(main())
