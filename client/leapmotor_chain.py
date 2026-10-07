#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""完整链路：SMS登录 -> 外层token兑换JWT(sha256签名) -> 派生signKey -> 查车况/车控"""
import base64, hashlib, json, os, random, sys, time
import requests
from cryptography.hazmat.primitives.serialization import load_der_public_key
from cryptography.hazmat.primitives.asymmetric import padding
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from leapmotor_client import (derive_keys_from_login, build_sign_value_string,
                              generate_hmac_sha256, SIGN_HEADER_KEYS)

AK=("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8"
"ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK"
"7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB")
SM=("B1rFqR82E2Z7do2KhMDKziLEuIcoEt4wY8QTy7/43ImlKMu591xoe/c8kgMPsTk4"
"P/nPH8eAUxQCnmA3GjTZODg==")
DEV="ios_ee45b9d830bb126d431e998943a7797a"
ACC="672955179229782016"; VIN="LFZ63AA15TH035113"
USER="https://appuser.leapmotor.cn"; GW="https://app-gw-global-master.leapmotor.com"
AGW="https://appgateway.leapmotor.com"
BASE={"APPImei":DEV,"APPVersion":"1.22.68","APPPlatform":"iOS","C-VERSIONS":"APP","XFX-CDN-VRS":"v4",
      "User-Agent":"leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)",
      "Accept":"*/*","Accept-Language":"zh-Hans-CN;q=1, en-CN;q=0.9"}
SESS=os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),"..","evidence","session.json"))

def enc_phone(p):
    pub=load_der_public_key(base64.b64decode(AK))
    return base64.b64encode(pub.encrypt(p.encode(),padding.PKCS1v15())).decode()

def send_sms(p):
    return requests.get(USER+"/app-user/applogin/compliance/sendmessagecode",
        params={"phoneNo":enc_phone(p),"smDeviceId":SM},headers=BASE,timeout=15).json()

def sms_login(p,code):
    f={"os":"ios","smDeviceId":SM,"phoneNoCiphertext":enc_phone(p),"phoneNumber":p,
       "smsCode":code,"deviceID":DEV,"pageUrl":""}
    h=dict(BASE); h["Content-Type"]="application/x-www-form-urlencoded; charset=UTF-8"
    return requests.post(USER+"/app-user/applogin/check_login_with_phone",data=f,headers=h,timeout=20).json()

def fk(o,k):
    if isinstance(o,dict):
        if o.get(k): return o[k]
        for v in o.values():
            g=fk(v,k)
            if g: return g
    elif isinstance(o,list):
        for v in o:
            g=fk(v,k)
            if g: return g
    return None

def prelogin_sign(body, extra=None):
    """登录前签名 = SHA256(valueStr)（无密钥）"""
    ts=str(int(time.time()*1000)); nz=str(random.randint(0,2147483647))
    sh={"acceptLanguage":"zh-Hans-CN;q=1, en-CN;q=0.9","channel":"1","deviceId":DEV,
        "deviceType":"iOS","nonce":nz,"source":"leapmotor","timestamp":ts,"version":"1.22.68"}
    vs=build_sign_value_string(body, sh)
    sign=hashlib.sha256(vs.encode()).hexdigest()
    h={"userid":ACC,"source":"leapmotor","x-api-signature-version":"2.0","x-region":"CN",
       "x-canary-version":"","devicetype":"iOS","channel":"1","cartype":"D19",
       "x-subversion":"3.22.2-3","version":"1.22.68","deviceid":DEV,
       "acceptLanguage":"zh-Hans-CN;q=1, en-CN;q=0.9","timestamp":ts,"nonce":nz,"sign":sign,
       "Content-Type":"application/json",
       "User-Agent":"leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)"}
    if extra: h.update(extra)
    return h, vs, sign

def exchange(token):
    body={"identifier":ACC,"identifierType":"1","security":token}
    h,vs,sign=prelogin_sign(body)
    r=requests.post(GW+"/base/base-user/account/v1/login",json=body,headers=h,timeout=20)
    return r.json(), vs, sign

def signed_post(sess, url, body):
    """登录后签名 = HMAC-SHA256(valueStr, signKey)"""
    key=sess["signKeyHex"]
    ts=str(int(time.time()*1000)); nz=str(random.randint(0,2147483647))
    sh={"acceptLanguage":"zh-Hans-CN;q=1, en-CN;q=0.9","channel":"1","deviceId":DEV,
        "deviceType":"iOS","nonce":nz,"source":"leapmotor","timestamp":ts,"version":"1.22.68"}
    vs=build_sign_value_string(body, sh)
    sign=generate_hmac_sha256(vs,key)
    h={"userid":str(sess.get("accountId") or ACC),"source":"leapmotor","x-api-signature-version":"2.0",
       "x-region":"CN","x-canary-version":"","devicetype":"iOS","channel":"1","cartype":"D19",
       "x-subversion":"3.22.2-3","version":"1.22.68","deviceid":DEV,
       "acceptLanguage":"zh-Hans-CN;q=1, en-CN;q=0.9","timestamp":ts,"nonce":nz,"sign":sign,
       "token":sess["accessToken"],"carvin":VIN,"Content-Type":"application/json",
       "User-Agent":"leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)"}
    return requests.post(url,json=body,headers=h,timeout=25)

if __name__=="__main__":
    cmd=sys.argv[1]
    if cmd=="send":
        print(json.dumps(send_sms(sys.argv[2]),ensure_ascii=False))
    elif cmd=="run":
        phone, code = sys.argv[2], sys.argv[3]
        j=sms_login(phone,code)
        tok=fk(j,"token")
        print("[1] SMS login:", j.get("msg"), "token=", (tok or "")[:40])
        if not tok: print(json.dumps(j,ensure_ascii=False)[:400]); sys.exit(1)
        r,vs,sg=exchange(tok)
        print("[2] exchange:", r.get("code"), r.get("message"))
        print("    valueStr =", vs)
        print("    sign(sha256) =", sg)
        if r.get("code")!=0:
            print("    full:", json.dumps(r,ensure_ascii=False)[:400]); sys.exit(1)
        d=r["data"]; keys=derive_keys_from_login(d)
        sess={**d,"signKeyHex":keys.get("sign_key_hex"),
              "encryptKeyHex":keys.get("encrypt_key_hex"),"outerToken":tok,
              "capturedAt":int(time.time())}
        json.dump(sess,open(SESS,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
        print("[3] JWT ok. signKey =", sess["signKeyHex"])
        print("    saved ->", SESS)
        # 车况
        r2=signed_post(sess, AGW+"/carownerservice/v3/api/vehicleinfo/commonConfig", {"vin":VIN})
        print("\n[4] commonConfig:", r2.status_code, r2.text[:300])
        r3=signed_post(sess, AGW+"/app/app-signal-service/signal/info/query",
                       {"carId":22129535,"signalList":["100003","1177","1298"]})
        print("[5] signal query:", r3.status_code, r3.text[:300])
