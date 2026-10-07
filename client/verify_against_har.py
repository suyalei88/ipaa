#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_against_har.py —— 用真实抓包样本验证 signKey 是否正确
==========================================================================
拿到 Frida dump 的 signKey 后，一条命令确认算法闭环：

    python client/verify_against_har.py "<signKey>"
    python client/verify_against_har.py --hex 604c9ac2a0dabd4c...
    python client/verify_against_har.py --file key.bin

成功会打印:  MATCH 186/186
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from leapmotor_client import build_sign_value_string  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.join(HERE, "..", "evidence", "signed_main.json")

SIGN_KEYS = ["acceptLanguage", "channel", "deviceId", "deviceType",
             "nonce", "source", "timestamp", "version"]


def hdr_values(H: dict) -> dict:
    return {
        "acceptLanguage": H.get("acceptlanguage", ""),
        "channel": H.get("channel", ""),
        "deviceId": H.get("deviceid", ""),
        "deviceType": H.get("devicetype", ""),
        "nonce": H.get("nonce", ""),
        "source": H.get("source", ""),
        "timestamp": H.get("timestamp", ""),
        "version": H.get("version", ""),
    }


def build_value_str(sample: dict) -> str:
    """
    对齐真实 App 行为（HAR 回归 100% 通过）:

      Content-Type: application/json
          body = JSON.parse(raw)            # 非 JSON -> {}
      Content-Type: application/x-www-form-urlencoded
          body = parse_qsl(raw)             # ★ URL 解码后的表单字典
      无 body
          body = {}

      signBody = {**body, **queryParams}    # GET query 合并
      valueStr = buildSignValueString(signBody, signHeaders)
    """
    sign_headers = hdr_values(sample["H"])

    ctype = (sample["H"].get("content-type") or "").lower()
    body = {}
    raw = (sample.get("body") or "").strip()
    if raw:
        if "form-urlencoded" in ctype:
            body = dict(urllib.parse.parse_qsl(raw, keep_blank_values=True))
        elif raw.startswith("{"):
            try:
                j = json.loads(raw)
                if isinstance(j, dict):
                    body = j
            except Exception:
                body = {}

    # URL query params 合并（GET 请求）
    params = {}
    url = sample.get("url", "")
    if "?" in url:
        for kv in url.split("?", 1)[1].split("&"):
            if "=" in kv:
                k, v = kv.split("=", 1)
                params[k] = v

    merged = dict(body)
    merged.update(params) if params else None
    return build_sign_value_string(merged, sign_headers)


def to_key(raw: str, is_hex: bool = False) -> bytes:
    if is_hex:
        return bytes.fromhex(raw)
    # 全 hex 自动 hex 解码（对齐 JS parseKeyString）
    cleaned = "".join(c for c in raw if c in "0123456789abcdefABCDEF")
    if cleaned and len(cleaned) == len(raw.replace(" ", "")):
        if len(cleaned) % 2 == 0:
            return bytes.fromhex(cleaned)
    return raw.encode("utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("key", nargs="?", help="signKey（字符串）")
    ap.add_argument("--hex", help="signKey 为 hex")
    ap.add_argument("--file", help="从二进制文件读 key")
    ap.add_argument("--b64", help="signKey 为 base64")
    ap.add_argument("--samples", default=SAMPLES)
    args = ap.parse_args()

    if args.file:
        key = open(args.file, "rb").read()
    elif args.hex:
        key = bytes.fromhex(args.hex)
    elif args.b64:
        key = base64.b64decode(args.b64)
    elif args.key:
        key = to_key(args.key)
    else:
        ap.error("需要提供 key / --hex / --b64 / --file")

    samples = json.load(open(args.samples, encoding="utf-8"))
    ok = 0
    bad = []
    for i, s in enumerate(samples):
        vs = build_value_str(s)
        sig = hmac.new(key, vs.encode("utf-8"), hashlib.sha256).hexdigest()
        if sig == s["H"]["sign"]:
            ok += 1
        elif len(bad) < 3:
            bad.append((i, s["H"]["sign"], sig, vs[:120]))

    total = len(samples)
    print("=" * 72)
    print("key   = %r" % (key if len(key) <= 64 else key[:64] + b"..."))
    print("keylen= %d bytes" % len(key))
    print("结果  = %s  %d/%d" % ("MATCH ✅" if ok == total else "MISMATCH ❌", ok, total))
    print("=" * 72)
    for i, exp, got, vs in bad:
        print("sample[%d] valueStr = %s" % (i, vs))
        print("   expect = %s" % exp)
        print("   actual = %s" % got)
    return 0 if ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
