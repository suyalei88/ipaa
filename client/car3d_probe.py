#!/usr/bin/env python3
"""
car3d_probe.py — 3D 车模链路探测

链路（全部逆向自官方主二进制 cstring 表 @0xaa1d1c0-0xaa1d560）:
    1. POST /base/base-user/token/v1/refresh          -> 新 accessToken（顺便实测上一轮续期实现）
    2. GET  /carownerservice/v3/api/carpicture/3d/key -> h5Key / srcKey / h5Whole / srcWhole / shareBindUrl
    3. GET  /carownerservice/v3/api/carpicture/key/package -> H5 离线包(zip) 地址
    4. 下载 zip -> %@/index.html (React 3D 应用) -> 内含真 3D 模型

用法:
    python car3d_probe.py                 # 全流程
    python car3d_probe.py --step refresh  # 只做续期
    python car3d_probe.py --step key      # 只做 3d/key
    python car3d_probe.py --step package  # 只做 key/package
"""
import argparse
import hashlib
import hmac
import json
import os
import random
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import requests  # noqa: E402

from leapmotor_client import (  # noqa: E402
    Config,
    Endpoints,
    LeapmotorClient,
    build_sign_value_string,
    parse_key,
)

EVID = os.path.join(HERE, "..", "evidence")
OUT = os.path.join(EVID, "car3d")
SESSION = os.path.join(EVID, "session.json")

REFRESH_PATH = "/base/base-user/token/v1/refresh"
ACCOUNT_HOST = "https://app-gw-global-master.leapmotor.com"
GW_HOST = "https://appgateway.leapmotor.com"


def log(*a):
    print(*a, flush=True)


def load_session():
    """优先用短信登录新拿到的 session_new.json，回退到旧的 session.json。"""
    new = os.path.join(EVID, "session_new.json")
    p = new if os.path.exists(new) else SESSION
    log(f"[session] 使用 {os.path.basename(p)}")
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def cfg_from_session(s):
    c = Config()
    c.sign_key = s["signKeyHex"]
    c.token = s["accessToken"]
    c.refresh_token = s["refreshToken"]
    c.user_id = str(s["accountId"])
    c.carvin = "LFZ63AA15TH035113"
    c.cartype = "D19"
    return c


def sign_headers_only(c: Config, body: dict):
    """返回 (headers, value_str) —— 不做签名，供两种签名方式复用。"""
    ts = str(int(time.time() * 1000))
    nonce = str(random.randint(0, 2147483646))
    sh = {
        "acceptLanguage": c.accept_language,
        "channel": c.channel,
        "deviceId": c.device_id,
        "deviceType": c.device_type,
        "nonce": nonce,
        "source": c.source,
        "timestamp": ts,
        "version": c.version,
    }
    value_str = build_sign_value_string(body or {}, sh)
    headers = {"Content-Type": "application/json"}
    headers.update(sh)
    headers["x-subversion"] = c.subversion
    headers["x-api-signature-version"] = "2.0"
    headers["x-region"] = "CN"
    headers["userId"] = c.user_id
    headers["User-Agent"] = c.user_agent
    headers["Accept-Language"] = "zh-Hans-CN;q=1, en-CN;q=0.9"
    return headers, value_str


def do_refresh(s, mode="sha256", send_token=True, extra=None):
    """调续期接口。mode: sha256(无密钥) | hmac(旧 signKey)"""
    c = cfg_from_session(s)
    body = {"refreshToken": s["refreshToken"]}
    headers, value_str = sign_headers_only(c, body)
    if send_token:
        headers["token"] = s["accessToken"]
    headers["carvin"] = c.carvin
    headers["cartype"] = c.cartype
    for k, v in (extra or {}).items():
        headers[k] = v

    if mode == "sha256":
        headers["sign"] = hashlib.sha256(value_str.encode("utf-8")).hexdigest()
    else:
        headers["sign"] = hmac.new(parse_key(c.sign_key), value_str.encode("utf-8"),
                                   hashlib.sha256).hexdigest()

    url = ACCOUNT_HOST + REFRESH_PATH
    log(f"[refresh:{mode}] POST {url}")
    log(f"[refresh:{mode}] body={json.dumps(body)[:120]}")
    r = requests.post(url, data=json.dumps(body, separators=(",", ":")),
                      headers=headers, timeout=20)
    log(f"[refresh:{mode}] HTTP {r.status_code}")
    txt = r.text
    log(f"[refresh:{mode}] resp {txt[:900]}")
    try:
        return r.json()
    except Exception:
        return {"_raw": txt, "_status": r.status_code}


def auth_headers(c: Config, sign_body: dict):
    cli = LeapmotorClient(c)
    return cli.build_headers(sign_body)


def do_get(c: Config, path: str, params: dict, tag: str):
    headers = auth_headers(c, dict(params or {}))
    url = GW_HOST + path
    log(f"[{tag}] GET {url}  params={params}")
    r = requests.get(url, params=params, headers=headers, timeout=20)
    log(f"[{tag}] HTTP {r.status_code}")
    txt = r.text
    log(f"[{tag}] resp {txt[:1500]}")
    try:
        return r.json()
    except Exception:
        return {"_raw": txt, "_status": r.status_code}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--step", default="all",
                    choices=["all", "refresh", "key", "package"])
    ap.add_argument("--mode", default="sha256", choices=["sha256", "hmac"])
    ap.add_argument("--no-token", action="store_true",
                    help="续期时不带 accessToken 头（排除「先校验 token 再校验 refreshToken」的干扰）")
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    s = load_session()
    c = cfg_from_session(s)

    state = {}

    if args.step in ("all", "refresh"):
        res = do_refresh(s, args.mode, send_token=not args.no_token)
        state["refresh"] = res
        with open(os.path.join(OUT, "refresh_resp.json"), "w", encoding="utf-8") as f:
            json.dump(res, f, ensure_ascii=False, indent=2)
        d = (res or {}).get("data") or {}
        if d.get("accessToken"):
            c.token = d["accessToken"]
            log("[refresh] ★ 续期成功，已拿到新 accessToken")
            # 派生新 signKey（若响应带 signParam）
            try:
                from leapmotor_client import derive_keys_from_login
                keys = derive_keys_from_login(d)
                if keys.get("sign_key_hex"):
                    c.sign_key = keys["sign_key_hex"]
                    log(f"[refresh] 新 signKey = {keys['sign_key_hex'][:32]}…")
            except Exception as e:
                log(f"[refresh] 派生 signKey 跳过: {e}")
        else:
            log("[refresh] ✗ 响应里没有 accessToken")

    if args.step in ("all", "key"):
        res = do_get(c, "/carownerservice/v3/api/carpicture/3d/key",
                     {"osVersion": "26.4.1", "vin": c.carvin}, "3d/key")
        state["key"] = res
        with open(os.path.join(OUT, "3dkey_resp.json"), "w", encoding="utf-8") as f:
            json.dump(res, f, ensure_ascii=False, indent=2)

    if args.step in ("all", "package"):
        # 参数待反汇编确认；先按「key/package?key=<h5Key>」试探
        key_resp = state.get("key")
        if not key_resp:
            p = os.path.join(OUT, "3dkey_resp.json")
            if os.path.exists(p):
                key_resp = json.load(open(p, encoding="utf-8"))
        d = (key_resp or {}).get("data") or {}
        h5k = d.get("h5Key") or ""
        src = d.get("srcKey") or ""
        log(f"[package] h5Key={h5k} srcKey={src}")
        for probe in [
            {"key": h5k},
            {"carPictureKey": h5k},
            {"h5Key": h5k},
            {"key": src},
            {"vin": c.carvin},
        ]:
            res = do_get(c, "/carownerservice/v3/api/carpicture/key/package",
                         probe, "key/package")
            if isinstance(res, dict) and res.get("code") == 0:
                log(f"[package] ★ 命中参数 {probe}")
                with open(os.path.join(OUT, "package_resp.json"), "w",
                          encoding="utf-8") as f:
                    json.dump(res, f, ensure_ascii=False, indent=2)
                break
            time.sleep(0.4)

    log("\n[done]")


if __name__ == "__main__":
    main()
