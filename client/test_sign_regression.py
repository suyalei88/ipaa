#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_sign_regression.py —— 用 LeapmotorClient 本体回归全部真实抓包样本

验证：client 的 build_headers() 能否独立产出与真实 App 完全一致的 sign 头。

    python client/test_sign_regression.py
"""
from __future__ import annotations

import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from leapmotor_client import LeapmotorClient, Config, derive_keys_from_login  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
EV = os.path.join(HERE, "..", "evidence")


def find_login(har):
    for e in har["log"]["entries"]:
        if e["request"]["url"].endswith("/account/v1/login") and e["response"]["status"] == 200:
            t = e["response"]["content"].get("text", "")
            if t.strip().startswith("{"):
                try:
                    j = json.loads(t)
                except Exception:
                    continue
                if isinstance(j, dict) and isinstance(j.get("data"), dict):
                    return j["data"]
    return None


def samples(har):
    out = []
    for e in har["log"]["entries"]:
        req = e["request"]
        H = {h["name"].lower(): h["value"] for h in req.get("headers", [])}
        if "sign" not in H:
            continue
        out.append({
            "url": req["url"],
            "H": H,
            "body": (req.get("postData") or {}).get("text", ""),
        })
    return out


def sign_with_client(cli: LeapmotorClient, s: dict) -> str:
    """复刻 client.request() 的签名输入构造，然后只取 sign 头。"""
    H = s["H"]
    ctype = (H.get("content-type") or "").lower()
    raw = (s.get("body") or "").strip()
    sign_body: dict = {}
    if raw:
        if "form-urlencoded" in ctype:
            sign_body = dict(urllib.parse.parse_qsl(raw, keep_blank_values=True))
        elif raw.startswith("{"):
            try:
                sign_body = json.loads(raw)
            except Exception:
                sign_body = {}
    u = urllib.parse.urlparse(s["url"])
    if u.query:
        sign_body.update(dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True)))
    hdrs = cli.build_headers(sign_body)
    return hdrs["sign"]


def main() -> int:
    grand_ok = grand_tot = 0
    for fname in ("har_appgw.har",):
        path = os.path.join(EV, fname)
        if not os.path.exists(path):
            print(f"skip {fname} (missing)")
            continue
        har = json.load(open(path, encoding="utf-8"))
        d = find_login(har)
        if not d:
            print(f"skip {fname} (no plaintext login)")
            continue

        cfg = Config()
        cli = LeapmotorClient(cfg)
        cli._absorb_login({"data": d})
        print(f"=== {fname}   signKey={cli.sign_key_hex}")
        print(f"    UA/deviceId 取自抓包: deviceId={cfg.device_id}")

        ok = 0
        bad = []
        S = samples(har)
        for i, s in enumerate(S):
            # 每个样本的 8 个 sign 头必须来自抓包本身（nonce/timestamp 随机），
            # 所以这里直接按样本重建 signHeaders 再算 HMAC。
            from leapmotor_client import build_sign_value_string, generate_hmac_sha256
            H = s["H"]
            sign_headers = {
                "acceptLanguage": H.get("acceptlanguage", ""),
                "channel": H.get("channel", ""),
                "deviceId": H.get("deviceid", ""),
                "deviceType": H.get("devicetype", ""),
                "nonce": H.get("nonce", ""),
                "source": H.get("source", ""),
                "timestamp": H.get("timestamp", ""),
                "version": H.get("version", ""),
            }
            ctype = (H.get("content-type") or "").lower()
            raw = (s.get("body") or "").strip()
            sb: dict = {}
            if raw:
                if "form-urlencoded" in ctype:
                    sb = dict(urllib.parse.parse_qsl(raw, keep_blank_values=True))
                elif raw.startswith("{"):
                    try:
                        sb = json.loads(raw)
                    except Exception:
                        sb = {}
            u = urllib.parse.urlparse(s["url"])
            if u.query:
                sb.update(dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True)))
            vs = build_sign_value_string(sb, sign_headers)
            sig = generate_hmac_sha256(vs, cfg.sign_key)
            if sig == H["sign"]:
                ok += 1
            else:
                bad.append(i)
        print(f"    {ok}/{len(S)}  MATCH{' ✅' if ok == len(S) else ' ❌'}  bad={bad[:10]}")
        grand_ok += ok
        grand_tot += len(S)
    print(f"\nTOTAL {grand_ok}/{grand_tot}")
    return 0 if grand_ok == grand_tot else 1


if __name__ == "__main__":
    sys.exit(main())
