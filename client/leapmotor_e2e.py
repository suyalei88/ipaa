#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SMS 登录 -> 立刻用外层 token 兑换 JWT（原子操作，验证 token 是否短时效/一次性）"""
import base64, json, os, sys, time, random
import requests
from cryptography.hazmat.primitives.serialization import load_der_public_key
from cryptography.hazmat.primitives.asymmetric import padding
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from leapmotor_client import derive_keys_from_login, build_sign_value_string, generate_hmac_sha256

ACCOUNT_ID_KEY_B64=("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8"
"ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK"
"7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB")
SM_DEVICE_ID=("B1rFqR82E2Z7do2KhMDKziLEuIcoEt4wY8QTy7/43ImlKMu591xoe/c8kgMPsTk4"
"P/nPH8eAUxQCnmA3GjTZODg==")
DEV="ios_ee45b9d830bb126d431e998943a7797a"
USER="https://appuser.leapmotor.cn"
GW="https://app-gw-global-master.leapmotor.com"
H={"APPImei":DEV,"APPVersion":"1.22.68","APPPlatform":"iOS","C-VERSIONS":"APP","XFX-CDN-VRS":"v4",
   "User-Agent":"leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)",
   "Accept":"*/*","Accept-Language":"zh-Hans-CN;q=1, en-CN;q=0.9"}

def enc_phone(p):
    pub=load_der_public_key(base64.b64decode(ACCOUNT_ID_KEY_B64))
    return base64.b64encode(pub.encrypt(p.encode(), padding.PKCS1v15())).decode()

def send_sms(p):
    r=requests.get(USER+"/app-user/applogin/compliance/sendmessagecode",
                   params={"phoneNo":enc_phone(p),"smDeviceId":SM_DEVICE_ID},headers=H,timeout=15)
    return r.json()

def sms_login(p, code):
    f={"os":"ios","smDeviceId":SM_DEVICE_ID,"phoneNoCiphertext":enc_phone(p),
       "phoneNumber":p,"smsCode":code,"deviceID":DEV,"pageUrl":""}
    h=dict(H); h["Content-Type"]="application/x-www-form-urlencoded; charset=UTF-8"
    r=requests.post(USER+"/app-user/applogin/check_login_with_phone",data=f,headers=h,timeout=20)
    return r.json()

def find_key(o,k):
    if isinstance(o,dict):
        if o.get(k): return o[k]
        for v in o.values():
            g=find_key(v,k)
            if g: return g
    elif isinstance(o,list):
        for v in o:
            g=find_key(v,k)
            if g: return g
    return None

def exchange(token, acc):
    """立刻用外层 token 兑换 JWT —— 多种头/签组合全试一遍"""
    body={"identifier":str(acc),"identifierType":"1","security":token}
    ts=str(int(time.time()*1000)); nz=str(random.randint(0,2147483647))
    al="zh-Hans-CN;q=1, en-CN;q=0.9"
    sh={"acceptLanguage":al,"channel":"1","deviceId":DEV,"deviceType":"iOS",
        "nonce":nz,"source":"leapmotor","timestamp":ts,"version":"1.22.68"}
    full={"userid":str(acc),"source":"leapmotor","x-api-signature-version":"2.0","x-region":"CN",
          "x-canary-version":"","devicetype":"iOS","channel":"1","cartype":"D19",
          "x-subversion":"3.22.2-3","version":"1.22.68","deviceid":DEV,
          "acceptLanguage":al,"timestamp":ts,"nonce":nz,"Content-Type":"application/json",
          "User-Agent":"leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)"}
    vs=build_sign_value_string(body, sh)
    variants=[]
    variants.append(("minimal", {"Content-Type":"application/json"}))
    variants.append(("full-nosign", dict(full)))
    for kn,key in (("signkey=token",token),("signkey=tokenhex",bytes.fromhex(token)),
                   ("signkey=token[:32]",token[:32]),("signkey=empty","")):
        hh=dict(full); hh["sign"]=generate_hmac_sha256(vs,key)
        variants.append((kn,hh))
    out=[]
    for name,hh in variants:
        try:
            r=requests.post(GW+"/base/base-user/account/v1/login",json=body,headers=hh,timeout=20)
            out.append((name,r.status_code,r.text[:300]))
        except Exception as e:
            out.append((name,"ERR",str(e)))
    return out, body

if __name__=="__main__":
    cmd=sys.argv[1]
    if cmd=="send":
        print(json.dumps(send_sms(sys.argv[2]),ensure_ascii=False))
    elif cmd=="run":
        phone, code = sys.argv[2], sys.argv[3]
        t0=time.time()
        j=sms_login(phone,code)
        print(f"[1] check_login_with_phone ({time.time()-t0:.1f}s)")
        print("    raw:", json.dumps(j,ensure_ascii=False)[:600])
        tok=find_key(j,"token"); acc=find_key(j,"accountId")
        if not tok:
            print("[!] 没拿到外层 token"); sys.exit(1)
        print(f"\n[2] 外层 token = {tok}")
        print(f"    accountId = {acc}   (issued {time.time()-t0:.1f}s ago)")
        res, body = exchange(tok, acc)
        for name,st,txt in res:
            print(f"\n[3] exchange [{name}]  {st}\n    {txt}")
            if '"code":0' in txt or "accessToken" in txt:
                print("\n!!!! SUCCESS !!!!")
                d=json.loads(txt)["data"]
                keys=derive_keys_from_login(d)
                print("  signKeyHex =", keys.get("sign_key_hex"))
                out=os.path.join(os.path.dirname(os.path.abspath(__file__)),"..","evidence","session.json")
                json.dump({**d,"signKeyHex":keys.get("sign_key_hex"),
                           "encryptKeyHex":keys.get("encrypt_key_hex"),
                           "outerToken":tok,"capturedAt":int(time.time())},
                          open(os.path.normpath(out),"w",encoding="utf-8"),ensure_ascii=False,indent=2)
                print("  saved ->", os.path.normpath(out))
                break
