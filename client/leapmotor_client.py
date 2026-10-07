#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
零跑汽车 车控 API 客户端 (com.leapmotor.developer / iOS 1.22.68)
=========================================================================
端点、请求体格式、cmdid 映射均来自真实抓包 + iOS 主二进制逆向。

────────────────────────────────────────────────────────────────────
签名算法（字节级还原 + HAR 回归 101/105，车控链路 100%）
────────────────────────────────────────────────────────────────────
    sign = HMAC_SHA256(valueStr, signKey).hex()
    valueStr = merge(signBody, signHeaders)
               -> 去空值 -> key 升序(ASCII) -> 只取 value 无分隔 join("")

    signHeaders 固定 8 个 key:
        acceptLanguage / channel / deviceId / deviceType /
        nonce / source / timestamp / version

    signBody（实测规则，见 client/verify_against_har.py）:
        Content-Type: application/json        -> JSON.parse(body)（非 JSON -> {}）
        Content-Type: x-www-form-urlencoded   -> ★ parse_qsl(body) URL 解码后的表单字典
        无 body                                -> {}
        GET 的 query params 一并 merge 进来

────────────────────────────────────────────────────────────────────
signKey 派生（iOS `-[LMVLocalLoginModel modelCustomTransformFromDictionary:]`
@0x106e82c30 + `+[LMVLocalLoginModel xorThreeData:data2:data3:]` @0x106e830fc）
────────────────────────────────────────────────────────────────────
    parts = accessToken.split(".")
    d1    = b64decode( base64url_to_base64(parts[2]) )      # JWT 签名段
    d2    = b64decode(signParam.r2)
    d3    = b64decode(signParam.r3)
    signKey      = UPPER( hex( XOR3(d1, d2, d3) ) )          # -> HKDFDeriveKey
    encryptKey   = UPPER( hex( XOR3(d1, e2, e3) ) )          # -> HKDFEncryptKey

    XOR3: n = max(len(a),len(b),len(c)); out[i] = a[i]^b[i]^c[i]  (越界取 0)

    服务端保证 signParam 与 encryptParam 两组的 r2^r3 相同 => signKey == encryptKey。
    signKey 是服务端每会话下发（由 r2/r3 反推），无需 frida。

依赖: pip install requests
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import random
import time
from dataclasses import dataclass, field
from typing import Any, Optional
from urllib.parse import quote, parse_qsl

import requests


# ============================================================
# 1. 签名实现（与 RN bundle 中 buildSignValueString / generateHmacSha256 对齐）
# ============================================================
SIGN_HEADER_KEYS = [
    "acceptLanguage", "channel", "deviceId", "deviceType",
    "nonce", "source", "timestamp", "version",
]


def _js_str(v: Any) -> str:
    """模拟 JS String(value) / Array.toString()"""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, list):
        has_obj = any(isinstance(i, (dict, list)) for i in v)
        if not has_obj:
            return ",".join(_js_str(x) for x in v)          # JS [1,2].toString()
        parts = []
        for item in v:
            if not isinstance(item, dict):
                parts.append(_js_str(item))
            else:
                inner = ", ".join(f"{k}={_js_str(vv)}" for k, vv in item.items()
                                  if vv is not None and vv != "")
                parts.append("{" + inner + "}")
        return ",".join(parts)
    return str(v)


def build_sign_value_string(body: Optional[dict], sign_headers: dict) -> str:
    """完全对齐 JS buildSignValueString()

    JS 的过滤条件是 `v != null && v !== undefined && v !== ""`：
    只剔除 null / undefined / 空串。注意 **false 与 0 都会被保留**
    （`false !== ""` 为 true），所以这里不能把 False 当成空值。
    """
    sign_obj: dict = {}
    if body:
        for k, v in body.items():
            sign_obj[k] = v
    for k, v in sign_headers.items():
        sign_obj[k] = v
    items = [(k, v) for k, v in sign_obj.items()
             if v is not None and v != ""]
    items.sort(key=lambda kv: kv[0])                       # JS 默认字符串比较
    return "".join(_js_str(v) for _, v in items)           # join("")


def parse_key(sign_key: Any) -> bytes:
    """
    完全对齐 JS parseKeyString() / generateHmacSha256() 的 key 处理:
      - str  : 全 hex -> hex 解码；否则 UTF-8
      - bytes: 直接用
      - dict / list: Object.values() -> Uint8Array（注意 JS 会把非数字元素变 0）
    """
    if isinstance(sign_key, bytes):
        return sign_key
    if isinstance(sign_key, (list, tuple)):
        return bytes(int(x) & 0xFF for x in sign_key)
    if isinstance(sign_key, dict):
        return bytes(0 for _ in sign_key)                  # JS: new Uint8Array([str,...]) -> [0,0]
    s = str(sign_key)
    cleaned = "".join(c for c in s if c in "0123456789abcdefABCDEF")
    is_likely_hex = len(cleaned) > 0 and len(cleaned) == len(s.replace(" ", "").replace("\t", ""))
    if is_likely_hex:
        if len(cleaned) % 2 != 0:
            raise ValueError("hex signKey length must be even")
        return bytes.fromhex(cleaned)
    return s.encode("utf-8")


def generate_hmac_sha256(message: str, key_input: Any) -> Optional[str]:
    if not message or key_input is None:
        return None
    key = parse_key(key_input)
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).hexdigest()


# ============================================================
# 1b. signKey 派生（逆向自 iOS 原生实现，见文件头注释）
# ============================================================
def _b64url_to_b64(s: str) -> str:
    s = s.replace("-", "+").replace("_", "/")
    return s + "=" * (-len(s) % 4)


def _b64d(s: str) -> bytes:
    s = (s or "").strip()
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s)


def xor3(d1: bytes, d2: bytes, d3: bytes) -> bytes:
    """对齐 +[LMVLocalLoginModel xorThreeData:data2:data3:]，零填充到最长。"""
    n = max(len(d1), len(d2), len(d3))
    return bytes(
        (d1[i] if i < len(d1) else 0)
        ^ (d2[i] if i < len(d2) else 0)
        ^ (d3[i] if i < len(d3) else 0)
        for i in range(n)
    )


def derive_sign_key(access_token: str, r2: str, r3: str) -> bytes:
    """
    从登录响应推导 signKey（返回原始字节；hex 大写形式见 bytes.hex().upper()）。
        signKey = XOR3( b64dec(b64url2b64(accessToken.split(".")[2])), b64dec(r2), b64dec(r3) )
    """
    parts = (access_token or "").split(".")
    if len(parts) < 3:
        raise ValueError("accessToken 不是 >=3 段的 JWT")
    d1 = _b64d(_b64url_to_b64(parts[2]))
    return xor3(d1, _b64d(r2), _b64d(r3))


def derive_keys_from_login(login_data: dict) -> dict:
    """一次性派生 signKey / encryptKey。"""
    tok = login_data.get("accessToken", "")
    out: dict = {}
    sp = login_data.get("signParam") or {}
    ep = login_data.get("encryptParam") or {}
    if sp.get("r2") and sp.get("r3"):
        k = derive_sign_key(tok, sp["r2"], sp["r3"])
        out["sign_key"] = k
        out["sign_key_hex"] = k.hex().upper()
    if ep.get("r2") and ep.get("r3"):
        k = derive_sign_key(tok, ep["r2"], ep["r3"])
        out["encrypt_key"] = k
        out["encrypt_key_hex"] = k.hex().upper()
    return out


# ============================================================
# 1c. oppwd（操作密码）加密
#     逆向自 +[LMVOperatePwInteractor requestSignParamsWithPassword:] @0x106c4433c
#           +[LMVMD5Util MD5ForLower16Bate:]  @0x106e966e0   (= md5hex(s)[8:24])
#           +[LMVAESUtil AESEncryptData:key:iv:] @0x106df4288
#           +[LMVAESUtil AES128Operation:data:key:iv:] @0x106df43c4
# ============================================================
def md5_lower16(s: str) -> str:
    """对齐 +[LMVMD5Util MD5ForLower16Bate:]：md5 hex 的第 8..24 个字符（16 chars）。"""
    return hashlib.md5(s.encode("utf-8")).hexdigest()[8:24]


def encrypt_oppwd(token: str, password: str) -> str:
    """
    oppwd = base64( AES-128-CBC-PKCS7( password_utf8, key, iv ) )
        key = md5hex(token[0:32])[8:24]   (16 个 ASCII 字符)
        iv  = md5hex(token[32:64])[8:24]  (16 个 ASCII 字符)

    已用真实抓包 round-trip 验证：
        token = har_appgw 的 accessToken, password = "4211"
        -> "uHTigfMDS5zIuZX4Gq4NVQ=="  ✅
    """
    if len(token) < 64:
        raise ValueError("accessToken 长度需 >= 64")
    key = md5_lower16(token[:32]).encode("ascii")
    iv = md5_lower16(token[32:64]).encode("ascii")
    try:
        from Crypto.Cipher import AES
        from Crypto.Util.Padding import pad
    except ImportError as e:  # pragma: no cover
        raise RuntimeError("需要 pycryptodome: pip install pycryptodome") from e
    ct = AES.new(key, AES.MODE_CBC, iv).encrypt(pad(password.encode("utf-8"), 16))
    return base64.b64encode(ct).decode("ascii")


# ============================================================
# 2. 端点表（全部来自抓包 / iOS 二进制）
# ============================================================
@dataclass
class Endpoints:
    # ---- 登录 ----
    send_sms: str = "/app-user/applogin/compliance/sendmessagecode"          # GET  appuser.leapmotor.cn
    login: str = "/base/base-user/account/v1/login"                          # POST app-gw-global-master
    refresh_token: str = "/token/v1/refresh"
    logout: str = "/account/v1/logout"
    # ---- 车辆 ----
    vehicle_list: str = "/app/app-global-service/v1/vehicle/list"            # GET  app-gw-global-master
    car_route: str = "/app/app-global-service/v1/vehicle/getCarRoute"        # GET  app-gw-global-master
    # ---- 状态 ----
    signal_query: str = "/app/app-signal-service/signal/info/query"          # POST appgateway (JSON body)
    signal_query_distributed: str = "/carownerservice/signal/info/query/distributed"
    # ---- 车控 ----
    remote_ctl: str = "/app/app-control-service/v3/api/appremotectl"         # POST form-urlencoded
    remote_ctl_query: str = "/app/app-control-service/v3/api/appremotectl/query"  # GET ?msgID=
    # ---- 杂项 ----
    common_config: str = "/carownerservice/v3/api/vehicleinfo/commonConfig"
    mileage: str = "/carownerservice/v3/api/drivingrecord/mileage/energy/detail"
    mqtt_token: str = "/mqtt/token/applyToken"                               # mqtt-center.leapmotor.cn


# 车控命令:  cmdid -> (state 模板, 说明)
#   110 车门锁       {"value":"lock"|"unlock"}      [已确认]
#   120 后备箱/寻车   {"value":"true"}               [抓包观察]
#   170 大灯         {"operate":"off"|"auto"}        [抓包观察]
#   230 空调         {"value":"0"|"2"|"5"}           [抓包观察]
#   400 上电/hello   {"operation":"on"}              [已确认]
CTRL_COMMANDS = {
    "lock":          (110, {"value": "lock"}),
    "unlock":        (110, {"value": "unlock"}),
    "trunk":         (120, {"value": "true"}),
    "light_off":     (170, {"operate": "off"}),
    "light_auto":    (170, {"operate": "auto"}),
    "hvac_off":      (230, {"value": "0"}),
    "hvac_low":      (230, {"value": "2"}),
    "hvac_high":     (230, {"value": "5"}),
    "hello":         (400, {"operation": "on"}),
}


# ============================================================
# 3. 配置
# ============================================================
@dataclass
class Config:
    # 主网关（车控 / 信号）
    base_url: str = "https://appgateway.leapmotor.com"
    # 账号/登录网关
    account_url: str = "https://app-gw-global-master.leapmotor.com"
    # 短信网关
    user_url: str = "https://appuser.leapmotor.cn"
    # 登录后拿到的 signKey（原生派生，需 frida dump）
    sign_key: Any = ""
    token: str = ""
    refresh_token: str = ""
    # 设备参数（抓包值）
    device_id: str = "ios_ee45b9d830bb126d431e998943a7797a"
    device_type: str = "iOS"
    accept_language: str = "zh-CN"
    source: str = "leapmotor"
    version: str = "1.22.68"
    channel: str = "1"
    subversion: str = "3.22.2-3"
    user_agent: str = "leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)"
    # 车辆
    carvin: str = ""
    cartype: str = ""
    user_id: str = ""
    # 操作密码（明文 6 位；会自动用 token 派生的 key/iv 加密成 oppwd）
    op_password: str = ""
    # 或者直接填抓到的密文 oppwd（优先级高于 op_password）
    oppwd: str = ""
    timeout: int = 15


# ============================================================
# 4. 客户端
# ============================================================
class LeapmotorClient:
    def __init__(self, cfg: Optional[Config] = None, ep: Optional[Endpoints] = None):
        self.cfg = cfg or Config()
        self.ep = ep or Endpoints()
        self.s = requests.Session()

    # ---------- 请求头 ----------
    def build_headers(self, sign_body: Optional[dict] = None,
                      skip_auth: bool = False) -> dict:
        """
        sign_body 必须是**已解析的字典**（form 用 parse_qsl，JSON 用 loads），
        因为它会按 key 排序后参与 HMAC 计算。
        """
        c = self.cfg
        if skip_auth:
            return {"Content-Type": "application/json"}
        ts = str(int(time.time() * 1000))
        nonce = str(random.randint(0, 2147483646))

        sign_headers = {
            "acceptLanguage": c.accept_language,
            "channel": c.channel,
            "deviceId": c.device_id,
            "deviceType": c.device_type,
            "nonce": nonce,
            "source": c.source,
            "timestamp": ts,
            "version": c.version,
        }
        headers = {"Content-Type": "application/json"}
        if c.sign_key:
            value_str = build_sign_value_string(sign_body or {}, sign_headers)
            sign = generate_hmac_sha256(value_str, c.sign_key)
            if sign:
                headers["sign"] = sign
        headers.update(sign_headers)
        headers["x-subversion"] = c.subversion
        headers["x-canary-version"] = ""
        headers["x-api-signature-version"] = "2.0"
        headers["x-region"] = "CN"
        headers["userId"] = c.user_id
        headers["token"] = c.token or ""
        headers["carvin"] = c.carvin or ""
        headers["cartype"] = c.cartype or ""
        headers["User-Agent"] = c.user_agent
        headers["Accept-Language"] = "zh-Hans-CN;q=1, en-CN;q=0.9"
        return headers

    # ---------- 通用请求 ----------
    def request(self, method: str, path: str, *, host: Optional[str] = None,
                params: dict = None, body: dict = None, form: Any = None,
                skip_auth: bool = False) -> Any:
        base = (host or self.cfg.base_url).rstrip("/")
        url = base + "/" + path.lstrip("/")

        # 1) 先算出参与签名的 body 字典
        sign_body: dict = {}
        if form is not None:
            sign_body = dict(form) if isinstance(form, dict) else dict(parse_qsl(str(form)))
        elif body is not None:
            sign_body = dict(body)
        # GET query 参数也并入签名
        if params:
            sign_body.update({k: v for k, v in params.items()})

        headers = self.build_headers(sign_body, skip_auth)
        kwargs = dict(params=params or None, headers=headers, timeout=self.cfg.timeout)

        if form is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            if isinstance(form, dict):
                kwargs["data"] = "&".join(f"{quote(str(k), safe='')}={quote(str(v), safe='')}"
                                          for k, v in form.items())
            else:
                kwargs["data"] = form
        elif body is not None:
            kwargs["data"] = json.dumps(body, separators=(",", ":"), ensure_ascii=False)

        r = self.s.request(method, url, **kwargs)
        txt = r.text
        try:
            return r.json()
        except Exception:
            return {"_raw": txt, "_status": r.status_code,
                    "_b64": _try_b64(txt)}

    # ============================================================
    # 登录
    # ============================================================
    def send_sms(self, phone: str, sm_device_id: str = "") -> dict:
        return self.request("GET", self.ep.send_sms, host=self.cfg.user_url,
                            params={"phoneNo": phone, "smDeviceId": sm_device_id},
                            skip_auth=True)

    def login(self, identifier: str, identifier_type: str = "1", security: str = "") -> dict:
        """
        identifier: 手机号 / accountId
        security  : 密码哈希，形如 MD5(pwd).upper() 重复两遍（64 hex）
        """
        body = {"identifier": identifier, "identifierType": identifier_type, "security": security}
        res = self.request("POST", self.ep.login, host=self.cfg.account_url, body=body,
                           skip_auth=False)
        self._absorb_login(res)
        return res

    def _absorb_login(self, res: dict) -> None:
        d = (res or {}).get("data") or {}
        if d.get("accessToken"):
            self.cfg.token = d["accessToken"]
        if d.get("refreshToken"):
            self.cfg.refresh_token = d["refreshToken"]
        if d.get("accountId"):
            self.cfg.user_id = str(d["accountId"])
        self.sign_param = d.get("signParam") or {}
        self.encrypt_param = d.get("encryptParam") or {}
        # ★ 直接派生 signKey，无需 frida
        keys = derive_keys_from_login(d)
        if keys.get("sign_key") is not None:
            self.cfg.sign_key = keys["sign_key"]          # bytes
            self.sign_key_hex = keys["sign_key_hex"]
        if keys.get("encrypt_key") is not None:
            self.encrypt_key = keys["encrypt_key"]
            self.encrypt_key_hex = keys["encrypt_key_hex"]

    # ============================================================
    # 车辆 / 状态
    # ============================================================
    def vehicle_list(self) -> dict:
        return self.request("GET", self.ep.vehicle_list, host=self.cfg.account_url)

    def car_route(self, vin: str) -> dict:
        return self.request("GET", self.ep.car_route, host=self.cfg.account_url,
                            params={"vin": vin})

    def status(self, vin: str) -> dict:
        """车况信号 (约 150 个 signalId)"""
        return self.request("POST", self.ep.signal_query,
                            body={"appVersion": self.cfg.version, "isMainApp": "1",
                                  "osType": self.cfg.device_type, "vin": vin})

    def status_distributed(self, vin: str) -> dict:
        return self.request("POST", self.ep.signal_query_distributed, body={"vin": vin})

    def mileage(self, vin: str) -> dict:
        return self.request("GET", self.ep.mileage, params={"vin": vin})

    # ============================================================
    # 车控
    # ============================================================
    def remote_ctl(self, vin: str, cmdid: int, state: dict,
                   oppwd: Optional[str] = None, control_source: str = "app") -> Any:
        """
        POST /app/app-control-service/v3/api/appremotectl
        Content-Type: application/x-www-form-urlencoded
        body: carvin=..&cmdid=..&oppwd=..&state=<urlencoded json>

        注意：签名用的是 URL 解码后的表单字典（含 state 的 JSON 原文），
              不是 raw body 字符串。
        """
        state_json = json.dumps(state, separators=(",", ":"), ensure_ascii=False)
        pw = oppwd if oppwd is not None else self.cfg.oppwd
        if not pw and self.cfg.op_password:
            pw = encrypt_oppwd(self.cfg.token, self.cfg.op_password)
        form = {
            "carvin": vin,
            "cmdid": str(cmdid),
            "oppwd": pw,
            "state": state_json,
        }
        return self.request("POST", self.ep.remote_ctl, form=form)

    def ctl(self, action: str, vin: str, oppwd: Optional[str] = None,
            extra_state: Optional[dict] = None) -> Any:
        if action not in CTRL_COMMANDS:
            raise ValueError(f"unknown action: {action}; known={list(CTRL_COMMANDS)}")
        cmdid, state = CTRL_COMMANDS[action]
        state = dict(state)
        if extra_state:
            state.update(extra_state)
        return self.remote_ctl(vin, cmdid, state, oppwd=oppwd)

    def ctl_query(self, msg_id: str) -> dict:
        """轮询车控结果: data 0=进行中/失败 1=成功"""
        return self.request("GET", self.ep.remote_ctl_query, params={"msgID": msg_id})

    def ctl_wait(self, msg_id: str, timeout: int = 20, interval: float = 1.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            r = self.ctl_query(msg_id)
            if r.get("data") == 1:
                return True
            time.sleep(interval)
        return False

    # 便捷方法
    def lock(self, vin: str, **kw):    return self.ctl("lock", vin, **kw)
    def unlock(self, vin: str, **kw):  return self.ctl("unlock", vin, **kw)
    def trunk(self, vin: str, **kw):   return self.ctl("trunk", vin, **kw)
    def hello(self, vin: str, **kw):   return self.ctl("hello", vin, **kw)


def _try_b64(txt: str):
    """车控二进制响应 (LMVCloudBinaryPacket) 用 base64 传输"""
    t = txt.strip()
    if not t or len(t) < 8:
        return None
    try:
        raw = base64.b64decode(t + "=" * (-len(t) % 4))
        return {"len": len(raw), "hex": raw.hex()}
    except Exception:
        return None


# ============================================================
# 5. 自测
# ============================================================
if __name__ == "__main__":
    # ---- 1) valueStr 构造（对齐抓包样本） ----
    body = {"appVersion": "1.22.68", "isMainApp": "1", "osType": "iOS",
            "vin": "LFZ63AA15TH035113"}
    sh = {"acceptLanguage": "zh-CN", "channel": "1",
          "deviceId": "ios_ee45b9d830bb126d431e998943a7797a", "deviceType": "iOS",
          "nonce": "2020738377", "source": "leapmotor",
          "timestamp": "1791350716506", "version": "1.22.68"}
    print("valueStr =", build_sign_value_string(body, sh))

    # ---- 2) signKey 派生（用 evidence/har_appgw.har 的真实登录响应） ----
    demo_login = {
        "accessToken": (
            "eyJub25jZSI6ImEyNzEwYjZkNDgwNDQ2ZTlhMjExOGI2YjIzZmQ3MDU3IiwiYWxnIjoiSFMyNTYiLCJ0eXAiOiJKV1QifQ"
            ".eyJ1c2VyX25hbWUiOiJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2LDEsZGV2aWNlSWQ6aW9zX2VlNDViOWQ4MzBi"
            "YjEyNmQ0MzFlOTk4OTQzYTc3OTdhLHBhc3N3b3JkOiIsInNjb3BlIjpbInJlYWQiXSwiZXhwIjoxNzkxMzU3ODExLCJhdXRo"
            "b3JpdGllcyI6WyJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2Il0sImp0aSI6IjJlZDE3MjcyLTBmOTktNDcwNy04MTE3"
            "LTU3OGYxMTAyYWI1NiIsInNpZ25fdGltZSI6MTc5MTM1MDYxMSwiY2xpZW50X2lkIjoiSHpUbWNzQmcifQ"
            ".y9ncviOjBWW1YSTbjf0RRJVB4_cWJIOAufJ-ZU7Ci1I"
        ),
        "signParam": {
            "r2": "6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo=",
            "r3": "XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884=",
        },
        "encryptParam": {
            "r2": "cYPovbbtY3Bxv+9m0+0+2v7CRs/s1FWbotOguVLySys=",
            "r3": "xnYhizldbR6gC4IUdU3o9aN5+Wv9RW95VoxyjSa6BR8=",
        },
    }
    keys = derive_keys_from_login(demo_login)
    print("signKey hex =", keys.get("sign_key_hex"))
    print("expect      = 7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566")
    print("encKey  hex =", keys.get("encrypt_key_hex"))
    assert keys.get("sign_key_hex") == "7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566", "signKey 派生错误"
    print("OK ✅  signKey 派生与真实抓包一致")

    # ---- 3) oppwd 加密（真实抓包 round-trip） ----
    opp = encrypt_oppwd(demo_login["accessToken"], "4211")
    print("oppwd('4211') =", opp)
    assert opp == "uHTigfMDS5zIuZX4Gq4NVQ==", "oppwd 加密错误"
    print("OK ✅  oppwd 加密与真实抓包一致（明文 = 4211）")
