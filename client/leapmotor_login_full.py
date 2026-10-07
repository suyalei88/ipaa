#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
零跑 · 短信验证码登录（完整打通版）

流程（全部逆向自 iOS 1.22.68 原生实现）：
  1) GET  /app-user/applogin/compliance/sendmessagecode?phoneNo=<RSA>&smDeviceId=<SM4>
  2) POST /app-user/applogin/check_login_with_phone   type = POST_Form (form-urlencoded)
        os              = "ios"                      (LPMBaseLoginCheckRequestParams -init @0x104f0b00c)
        smDeviceId      = <SM4 国密>
        phoneNoCiphertext = EncodeForStrV1(phone)     (+[LMLoginToolsManager EncodeForStrV1:error:])
        phoneNumber     = <明文手机号>
        smsCode         = <验证码>
        deviceID        = [LMIdentifierKit getPhoneID]
        pageUrl         = [LPMLoginPathProvider getLoginPageMarksOrActionCode]  (可空)
  3) 响应 data.appLoginVO -> accessToken / refreshToken / signParam{r2,r3} / encryptParam{r2,r3}
  4) signKey = UPPER(hex(XOR3(b64(jwt[2]), b64(r2), b64(r3))))

用法：
  python client/leapmotor_login_full.py send  17621058873
  python client/leapmotor_login_full.py login 17621058873 123456
"""
import base64
import json
import os
import sys
import time
import uuid

import requests
from cryptography.hazmat.primitives.serialization import load_der_public_key
from cryptography.hazmat.primitives.asymmetric import padding

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from leapmotor_client import derive_keys_from_login          # noqa: E402

ACCOUNT_ID_KEY_B64 = (
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8"
    "ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK"
    "7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB")
SM_DEVICE_ID = ("B1rFqR82E2Z7do2KhMDKziLEuIcoEt4wY8QTy7/43ImlKMu591xoe/c8kgMPsTk4"
                "P/nPH8eAUxQCnmA3GjTZODg==")
DEVICE_ID = "ios_ee45b9d830bb126d431e998943a7797a"
HOST = "https://appuser.leapmotor.cn"
SEND_SMS_PATH = "/app-user/applogin/compliance/sendmessagecode"
CHECK_PHONE_PATH = "/app-user/applogin/check_login_with_phone"
SESSION_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "evidence", "session.json")

HEADERS = {
    "APPImei": DEVICE_ID, "APPVersion": "1.22.68", "APPPlatform": "iOS",
    "C-VERSIONS": "APP", "XFX-CDN-VRS": "v4",
    "User-Agent": "leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)",
    "Accept": "*/*", "Accept-Language": "zh-Hans-CN;q=1, en-CN;q=0.9",
}


def enc_phone(phone: str) -> str:
    pub = load_der_public_key(base64.b64decode(ACCOUNT_ID_KEY_B64))
    return base64.b64encode(pub.encrypt(phone.encode(), padding.PKCS1v15())).decode()


def send_sms(phone: str, sm_device_id: str = SM_DEVICE_ID) -> dict:
    r = requests.get(HOST + SEND_SMS_PATH,
                     params={"phoneNo": enc_phone(phone), "smDeviceId": sm_device_id},
                     headers=HEADERS, timeout=15)
    try:
        return r.json()
    except Exception:
        return {"_status": r.status_code, "_raw": r.text}


def find_key(obj, key):
    """递归找第一个 key。"""
    if isinstance(obj, dict):
        if key in obj and obj[key] not in (None, ""):
            return obj[key]
        for v in obj.values():
            got = find_key(v, key)
            if got is not None:
                return got
    elif isinstance(obj, list):
        for v in obj:
            got = find_key(v, key)
            if got is not None:
                return got
    return None


def login(phone: str, code: str) -> dict:
    fields = {
        "os": "ios",
        "smDeviceId": SM_DEVICE_ID,
        "phoneNoCiphertext": enc_phone(phone),
        "phoneNumber": phone,
        "smsCode": code,
        "deviceID": DEVICE_ID,
        "pageUrl": "",
    }
    h = dict(HEADERS)
    h["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    r = requests.post(HOST + CHECK_PHONE_PATH, data=fields, headers=h, timeout=20)
    print(f"[login] HTTP {r.status_code}")
    print("[login] raw:", r.text[:1200])
    try:
        return r.json()
    except Exception:
        return {"_status": r.status_code, "_raw": r.text}


def save_session(j: dict) -> None:
    at = find_key(j, "accessToken")
    rt = find_key(j, "refreshToken")
    if not at:
        print("[!] 响应里没有 accessToken，未保存")
        return
    sp = find_key(j, "signParam") or {}
    ep = find_key(j, "encryptParam") or {}
    data = {"accessToken": at, "refreshToken": rt,
            "signParam": sp, "encryptParam": ep,
            "accountId": find_key(j, "accountId"),
            "nickname": find_key(j, "nickname"),
            "tokenExpireTime": find_key(j, "tokenExpireTime"),
            "refreshTokenExpireTime": find_key(j, "refreshTokenExpireTime"),
            "capturedAt": int(time.time())}
    keys = derive_keys_from_login({"accessToken": at, "signParam": sp, "encryptParam": ep})
    data["signKeyHex"] = keys.get("sign_key_hex")
    data["encryptKeyHex"] = keys.get("encrypt_key_hex")
    out = os.path.normpath(SESSION_OUT)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("\n=== LOGIN SUCCESS ===")
    print("  accountId    =", data["accountId"])
    print("  nickname     =", data["nickname"])
    print("  accessToken  =", at[:70], "...")
    print("  refreshToken =", (rt or "")[:50], "...")
    print("  signKeyHex   =", data["signKeyHex"])
    print("  encryptKeyHex=", data["encryptKeyHex"])
    print(f"\n  saved -> {out}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "send":
        phone = sys.argv[2]
        print("[send]", phone)
        print("  phoneNo =", enc_phone(phone))
        print("  resp    =", json.dumps(send_sms(phone), ensure_ascii=False))
    elif cmd == "login":
        phone, code = sys.argv[2], sys.argv[3]
        j = login(phone, code)
        if j.get("code") in (0, 200) or find_key(j, "accessToken"):
            save_session(j)
        else:
            print("\n[!] 登录失败:", j.get("code"), j.get("msg") or j.get("message"))
    else:
        print(__doc__)
