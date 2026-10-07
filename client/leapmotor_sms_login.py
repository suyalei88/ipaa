#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
零跑 · 短信验证码登录（逆向自 iOS App v1.22.68）

已打通：
  ✅ 发码  GET https://appuser.leapmotor.cn/app-user/applogin/compliance/sendmessagecode
            phoneNo = base64(RSA_PKCS1v15(手机号, AccountIDKey))   128 字节
            smDeviceId = 抓包值（SM4 国密，动态，可复用试）
            不需要 sign / token

待定：
  ⚠️ 用码登录接口格式（check_login_with_phone 在原生 + CFF 混淆里）

用法：
  python client/leapmotor_sms_login.py send 17621058873
  python client/leapmotor_sms_login.py login 17621058873 123456
"""
import base64
import json
import sys
import time

import requests
from cryptography.hazmat.primitives.serialization import load_der_public_key
from cryptography.hazmat.primitives.asymmetric import padding

# ----------------------------------------------------------------------
# 手机号 RSA 公钥（二进制 file offset 0xa9b6471，名为 AccountIDKey）
# ----------------------------------------------------------------------
ACCOUNT_ID_KEY_B64 = (
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8"
    "ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK"
    "7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB"
)

# 抓包里的 smDeviceId（用户本人设备；每次会变，但可先复用）
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


def encrypt_phone(phone: str) -> str:
    """phoneNo = base64(RSA_PKCS1v15(手机号, AccountIDKey))"""
    pub = load_der_public_key(base64.b64decode(ACCOUNT_ID_KEY_B64))
    enc = pub.encrypt(phone.encode(), padding.PKCS1v15())
    return base64.b64encode(enc).decode()


def send_sms(phone: str, sm_device_id: str = SM_DEVICE_ID) -> dict:
    phone_no = encrypt_phone(phone)
    r = requests.get(
        USER_HOST + SEND_SMS_PATH,
        params={"phoneNo": phone_no, "smDeviceId": sm_device_id},
        headers=HEADERS,
        timeout=15,
    )
    try:
        return r.json()
    except Exception:
        return {"_status": r.status_code, "_raw": r.text}


def try_login(phone: str, code: str) -> None:
    """穷举几种可能的用码登录格式，打印每种的服务端响应。"""
    phone_no = encrypt_phone(phone)
    attempts = []

    # 1) GET check_login_with_phone?phoneNo=&smsCode=
    attempts.append((
        "GET  check_login_with_phone ?phoneNo&smsCode",
        lambda: requests.get(USER_HOST + CHECK_PHONE_PATH,
                             params={"phoneNo": phone_no, "smsCode": code},
                             headers=HEADERS, timeout=15),
    ))
    # 2) GET check_login_with_phone?phoneNo&smsCode&smDeviceId
    attempts.append((
        "GET  check_login_with_phone ?phoneNo&smsCode&smDeviceId",
        lambda: requests.get(USER_HOST + CHECK_PHONE_PATH,
                             params={"phoneNo": phone_no, "smsCode": code,
                                     "smDeviceId": SM_DEVICE_ID},
                             headers=HEADERS, timeout=15),
    ))
    # 3) POST check_login_with_phone (json)
    attempts.append((
        "POST check_login_with_phone json{phoneNo,smsCode}",
        lambda: requests.post(USER_HOST + CHECK_PHONE_PATH,
                              json={"phoneNo": phone_no, "smsCode": code},
                              headers=HEADERS, timeout=15),
    ))
    # 4) POST account/v1/login identifierType=2 security=code
    attempts.append((
        "POST account/v1/login {identifier:phone, identifierType:2, security:code}",
        lambda: requests.post(ACCOUNT_HOST + LOGIN_PATH,
                              json={"identifier": phone, "identifierType": "2",
                                    "security": code},
                              headers={**HEADERS, "Content-Type": "application/json"},
                              timeout=15),
    ))
    # 5) POST account/v1/login identifier=phoneNo(密文) identifierType=2
    attempts.append((
        "POST account/v1/login {identifier:phoneNo(rsa), identifierType:2, security:code}",
        lambda: requests.post(ACCOUNT_HOST + LOGIN_PATH,
                              json={"identifier": phone_no, "identifierType": "2",
                                    "security": code},
                              headers={**HEADERS, "Content-Type": "application/json"},
                              timeout=15),
    ))

    for name, fn in attempts:
        try:
            r = fn()
            body = r.text[:300]
            print(f"\n### {name}\n    HTTP {r.status_code}  {body}")
            if '"code":0' in body or '"accessToken"' in body:
                print("    ^^^^^ 可能成功！")
        except Exception as e:
            print(f"\n### {name}\n    ERR {type(e).__name__}: {e}")
        time.sleep(0.6)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "send":
        phone = sys.argv[2]
        print(f"[send] phone={phone}")
        print("phoneNo =", encrypt_phone(phone))
        print("resp    =", json.dumps(send_sms(phone), ensure_ascii=False))
    elif cmd == "login":
        phone, code = sys.argv[2], sys.argv[3]
        print(f"[login] phone={phone} code={code}")
        try_login(phone, code)
    else:
        print(__doc__)
