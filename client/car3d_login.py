#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
car3d_login.py — 短信验证码登录 → 自动续取 3D 车模离线包

为什么需要它：
    `carpicture/3d/key` 与 `carpicture/key/package` 都要求有效 token；
    手上的 session.json 凭据已过期（refreshToken 被服务端轮换作废）。

链路（逆向自主二进制）：
    sendmessagecode (RSA 加密手机号)  →  用户收码
    check_login_with_phone(phoneNo, smsCode)  →  appLoginVO{accessToken, refreshToken, signParam, encryptParam}
    carpicture/3d/key  →  h5Key / srcKey
    carpicture/key/package  →  zip 地址  →  下载解出 index.html + 3DHoleCarImage/*.png

用法:
    python car3d_login.py send  176xxxxxxxx
    python car3d_login.py login 176xxxxxxxx 123456
"""
import base64
import json
import os
import sys
import time

import requests
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.serialization import load_der_public_key

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
EVID = os.path.join(HERE, "..", "evidence")
OUT = os.path.join(EVID, "car3d")

ACCOUNT_ID_KEY_B64 = (
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8"
    "ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK"
    "7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB"
)
SM_DEVICE_ID = ("B1rFqR82E2Z7do2KhMDKziLEuIcoEt4wY8QTy7/43ImlKMu591xoe/c8kgMPsTk4"
                "P/nPH8eAUxQCnmA3GjTZODg==")
DEVICE_ID = "ios_ee45b9d830bb126d431e998943a7797a"
USER_HOST = "https://appuser.leapmotor.cn"
ACCOUNT_HOST = "https://app-gw-global-master.leapmotor.com"
SEND_SMS_PATH = "/app-user/applogin/compliance/sendmessagecode"
CHECK_PHONE_PATH = "/app-user/applogin/check_login_with_phone"
LOGIN_PATH = "/base/base-user/account/v1/login"

HEADERS = {
    "APPImei": DEVICE_ID,
    "APPVersion": "1.22.68",
    "APPPlatform": "iOS",
    "C-VERSIONS": "APP",
    "XFX-CDN-VRS": "v4",
    "User-Agent": "leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)",
    "Accept": "*/*",
    "Accept-Language": "zh-Hans-CN;q=1, en-CN;q=0.9",
}


def log(*a):
    print(*a, flush=True)


def encrypt_phone(phone: str) -> str:
    pub = load_der_public_key(base64.b64decode(ACCOUNT_ID_KEY_B64))
    return base64.b64encode(pub.encrypt(phone.encode(), padding.PKCS1v15())).decode()


def do_send(phone: str) -> None:
    phone_no = encrypt_phone(phone)
    r = requests.get(USER_HOST + SEND_SMS_PATH,
                     params={"phoneNo": phone_no, "smDeviceId": SM_DEVICE_ID},
                     headers=HEADERS, timeout=15)
    log(f"[send] HTTP {r.status_code}  {r.text[:300]}")


def _try_candidates(phone: str, code: str):
    """穷举用码登录格式，返回第一个带 accessToken 的响应。"""
    phone_no = encrypt_phone(phone)
    cands = [
        ("GET  check_login_with_phone ?phoneNo&smsCode",
         lambda: requests.get(USER_HOST + CHECK_PHONE_PATH,
                              params={"phoneNo": phone_no, "smsCode": code},
                              headers=HEADERS, timeout=15)),
        ("GET  check_login_with_phone ?phoneNo&smsCode&smDeviceId",
         lambda: requests.get(USER_HOST + CHECK_PHONE_PATH,
                              params={"phoneNo": phone_no, "smsCode": code,
                                      "smDeviceId": SM_DEVICE_ID},
                              headers=HEADERS, timeout=15)),
        ("POST check_login_with_phone json{phoneNo,smsCode}",
         lambda: requests.post(USER_HOST + CHECK_PHONE_PATH,
                               json={"phoneNo": phone_no, "smsCode": code},
                               headers=HEADERS, timeout=15)),
        ("POST check_login_with_phone form{phoneNo,smsCode}",
         lambda: requests.post(USER_HOST + CHECK_PHONE_PATH,
                               data={"phoneNo": phone_no, "smsCode": code},
                               headers=HEADERS, timeout=15)),
        ("POST account/v1/login {identifier:phoneNo(rsa),identifierType:2,security:code}",
         lambda: requests.post(ACCOUNT_HOST + LOGIN_PATH,
                               json={"identifier": phone_no, "identifierType": "2",
                                     "security": code},
                               headers={**HEADERS, "Content-Type": "application/json"},
                               timeout=15)),
    ]
    for name, fn in cands:
        try:
            r = fn()
            body = r.text
            hit = ('"accessToken"' in body) or ('"code":0' in body and 'token' in body.lower())
            log(f"[login] {name}\n        HTTP {r.status_code}  {body[:400]}")
            if hit:
                log(f"[login] ★ 命中：{name}")
                try:
                    return json.loads(body)
                except Exception:
                    return None
        except Exception as e:
            log(f"[login] {name}\n        ERR {type(e).__name__}: {e}")
        time.sleep(0.5)
    return None


def _find_login_vo(obj):
    """从任意嵌套结构里找出含 accessToken 的那层 dict。"""
    if isinstance(obj, dict):
        if obj.get("accessToken"):
            return obj
        for v in obj.values():
            r = _find_login_vo(v)
            if r:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = _find_login_vo(v)
            if r:
                return r
    return None


def do_login(phone: str, code: str) -> int:
    res = _try_candidates(phone, code)
    if not res:
        log("[login] ✗ 所有候选格式都没拿到 accessToken")
        return 2

    d = _find_login_vo(res)
    if not d:
        log("[login] ✗ 响应里找不到 accessToken 字段")
        return 2

    from leapmotor_client import derive_keys_from_login
    keys = derive_keys_from_login(d)

    sess = {
        "accountId": d.get("accountId") or d.get("userId") or "",
        "nickname": d.get("nickname") or "",
        "accessToken": d.get("accessToken"),
        "refreshToken": d.get("refreshToken") or "",
        "tokenExpireTime": d.get("tokenExpireTime"),
        "refreshTokenExpireTime": d.get("refreshTokenExpireTime"),
        "signParam": d.get("signParam") or {},
        "encryptParam": d.get("encryptParam") or {},
        "signKeyHex": keys.get("sign_key_hex") or "",
        "encryptKeyHex": keys.get("encrypt_key_hex") or "",
        "outerToken": d.get("outerToken") or "",
        "capturedAt": time.time(),
        "_source": "car3d_login.py",
    }
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(EVID, "session_new.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(sess, f, ensure_ascii=False, indent=2)
    log(f"[login] ★ 已保存新会话 -> {p}")
    log(f"[login]   accountId   = {sess['accountId']}")
    log(f"[login]   signKeyHex  = {sess['signKeyHex'][:32]}…")
    log(f"[login]   accessToken = {str(sess['accessToken'])[:40]}…")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        log(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "send":
        do_send(sys.argv[2])
    elif cmd == "login":
        if len(sys.argv) < 4:
            log("用法: car3d_login.py login <phone> <code>")
            sys.exit(1)
        sys.exit(do_login(sys.argv[2], sys.argv[3]))
    else:
        log(f"未知命令 {cmd}")
        sys.exit(1)
