#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HAR 分析器 — 零跑 APP 抓包解析 + 签名自动校验
================================================
用法:
  # 1) 只解析
  python client/har_analyze.py evidence/login.har

  # 2) 解析 + 用已知 signKey 验签（验证算法是否与抓包一致）
  python client/har_analyze.py evidence/login.har --sign-key <hex or str>

  # 3) 只看某主机
  python client/har_analyze.py evidence/login.har --host api.leapmotor.com
"""
import argparse
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from leapmotor_client import build_sign_value_string, generate_hmac_sha256  # noqa: E402

# 参与签名的 header（大小写不敏感匹配）
SIGN_HEADER_KEYS = {
    "acceptlanguage": "acceptLanguage",
    "devicetype": "deviceType",
    "source": "source",
    "version": "version",
    "channel": "channel",
    "deviceid": "deviceId",
    "timestamp": "timestamp",
    "nonce": "nonce",
}
AUTH_HEADERS = ["sign", "token", "userid", "carvin", "cartype",
                "x-api-signature-version", "x-region", "x-subversion", "x-canary-version"]


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def hdrs_to_dict(headers):
    d = {}
    for h in headers:
        d[h["name"]] = h["value"]
    return d


def analyze(path, only_host=None, sign_key=None):
    har = load(path)
    entries = har["log"]["entries"]
    print(f"== HAR: {path}")
    print(f"== entries: {len(entries)}")
    if har["log"].get("creator"):
        print(f"== creator: {har['log']['creator']}")
    print()

    # 主机统计
    from collections import Counter
    hosts = Counter(e["request"]["url"].split("/")[2] for e in entries)
    print("-- 主机分布 --")
    for h, c in hosts.most_common():
        print(f"   {c:4d}  {h}")
    print()

    leap = [e for e in entries
            if "leapmotor" in e["request"]["url"]
            and (only_host is None or only_host in e["request"]["url"])]
    print(f"-- 零跑域名请求: {len(leap)} 条 --\n")

    verified = 0
    for i, e in enumerate(leap):
        r = e["request"]
        h = hdrs_to_dict(r.get("headers", []))
        print(f"[{i}] {r['method']} {r['url']}")
        print(f"    status={e['response'].get('status')}  time={e.get('startedDateTime','')}")
        # 鉴权头
        for k, v in h.items():
            if k.lower() in AUTH_HEADERS or k.lower() in SIGN_HEADER_KEYS:
                print(f"    {k}: {v}")
        body_txt = r.get("postData", {}).get("text", "")
        if body_txt:
            print(f"    body: {body_txt[:400]}{'...' if len(body_txt) > 400 else ''}")

        # 验签
        sign = h.get("sign") or h.get("Sign")
        if sign and sign_key:
            body = {}
            try:
                body = json.loads(body_txt) if body_txt.strip().startswith(("{", "[")) else {}
            except Exception:
                body = {}
            sh = {}
            for hk, canon in SIGN_HEADER_KEYS.items():
                for k, v in h.items():
                    if k.lower() == hk:
                        sh[canon] = v
            vs = build_sign_value_string(body, sh)
            calc = generate_hmac_sha256(vs, sign_key)
            ok = (calc == sign.lower())
            verified += int(ok)
            print(f"    >>> 待签串: {vs[:160]}{'...' if len(vs) > 160 else ''}")
            print(f"    >>> 抓到 sign : {sign}")
            print(f"    >>> 计算 sign : {calc}")
            print(f"    >>> {'✅ MATCH' if ok else '❌ MISMATCH'}")
        print()

    if sign_key:
        print(f"== 验签结果: {verified}/{len(leap)} 通过")
    else:
        print("提示: 加 --sign-key <key> 可自动校验签名是否与抓包一致")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("har")
    ap.add_argument("--host", default=None)
    ap.add_argument("--sign-key", default=None)
    a = ap.parse_args()
    analyze(a.har, a.host, a.sign_key)
