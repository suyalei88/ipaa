#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_login_with_phone 格式探测 —— POST_Form（form-urlencoded）"""
import base64, json, sys, time, uuid
import requests
from cryptography.hazmat.primitives.serialization import load_der_public_key
from cryptography.hazmat.primitives.asymmetric import padding

ACCOUNT_ID_KEY_B64 = (
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8"
    "ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK"
    "7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB")
SM_DEVICE_ID = ("B1rFqR82E2Z7do2KhMDKziLEuIcoEt4wY8QTy7/43ImlKMu591xoe/c8kgMPsTk4"
                "P/nPH8eAUxQCnmA3GjTZODg==")
DEVICE_ID = "ios_ee45b9d830bb126d431e998943a7797a"
HOST = "https://appuser.leapmotor.cn"
PATH = "/app-user/applogin/check_login_with_phone"

HEADERS = {
    "APPImei": DEVICE_ID, "APPVersion": "1.22.68", "APPPlatform": "iOS",
    "C-VERSIONS": "APP", "XFX-CDN-VRS": "v4",
    "User-Agent": "leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)",
    "Accept": "*/*", "Accept-Language": "zh-Hans-CN;q=1, en-CN;q=0.9",
    "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
}

def enc_phone(phone):
    pub = load_der_public_key(base64.b64decode(ACCOUNT_ID_KEY_B64))
    return base64.b64encode(pub.encrypt(phone.encode(), padding.PKCS1v15())).decode()

def probe(name, fields):
    r = requests.post(HOST + PATH, data=fields, headers=HEADERS, timeout=15)
    print(f"\n### {name}")
    print("    fields:", list(fields.keys()))
    print(f"    HTTP {r.status_code}  {r.text[:400]}")
    return r

if __name__ == "__main__":
    phone = sys.argv[1] if len(sys.argv) > 1 else "17621058873"
    code  = sys.argv[2] if len(sys.argv) > 2 else "000000"
    ciph  = enc_phone(phone)
    base = {"os": "ios", "smDeviceId": SM_DEVICE_ID,
            "phoneNoCiphertext": ciph, "phoneNumber": phone, "smsCode": code}

    sets = [
        ("A minimal(os,smDeviceId,phoneNoCiphertext,phoneNumber,smsCode)", dict(base)),
        ("B +deviceID+pageUrl", {**base, "deviceID": DEVICE_ID, "pageUrl": ""}),
        ("C +deviceID+pageUrl+requestId+genTime", {**base, "deviceID": DEVICE_ID,
            "pageUrl": "", "requestId": uuid.uuid4().hex, "genTime": str(int(time.time()*1000))}),
    ]
    for nm, f in sets:
        try:
            probe(nm, f)
        except Exception as e:
            print(f"\n### {nm}\n    ERR {type(e).__name__}: {e}")
        time.sleep(1.5)
