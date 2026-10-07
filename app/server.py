#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
零跑车控 干净后端 (FastAPI)
================================================
架构:
  浏览器/手机前端  <--HTTP-->  本后端  <--签名+HTTPS-->  零跑云
后端持有逆向出的签名逻辑, 前端只管 UI, 天然"无广告"。

运行:
  python -m pip install fastapi uvicorn requests pycryptodome
  python app/server.py
  打开 http://127.0.0.1:8000

配置: 复制 app/config.example.json -> app/config.json 并填好
      account / password（会自动派生 signKey 与 oppwd）/ carvin
      —— 也可手动填 sign_key / token / oppwd 覆盖。

★ 加密体系已完整还原（见 evidence/FINDINGS_CRYPTO.md）：
    signKey = UPPER(HEX(XOR3(b64dec(b64url2b64(accessToken[2])), b64dec(signParam.r2), b64dec(signParam.r3))))
    oppwd   = base64(AES-128-CBC-PKCS7(op_password, md5hex(tok[:32])[8:24], md5hex(tok[32:64])[8:24]))
  不需要 Frida。
"""

import json
import os
import sys

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "client"))
from leapmotor_client import (  # noqa: E402
    CTRL_COMMANDS, Config, Endpoints, LeapmotorClient,
)

app = FastAPI(title="Leapmotor Clean Client")

CFG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")
_d = {}
if os.path.exists(CFG_PATH):
    with open(CFG_PATH, "r", encoding="utf-8") as f:
        _d = json.load(f)

cfg = Config(
    base_url=_d.get("base_url", "https://appgateway.leapmotor.com"),
    account_url=_d.get("account_url", "https://app-gw-global-master.leapmotor.com"),
    sign_key=_d.get("sign_key", ""),
    token=_d.get("token", ""),
    device_id=_d.get("device_id", ""),
    device_type=_d.get("device_type", "iOS"),
    version=_d.get("version", "1.22.68"),
    channel=_d.get("channel", "1"),
    subversion=_d.get("subversion", "3.22.2-3"),
    carvin=_d.get("carvin", ""),
    cartype=_d.get("cartype", ""),
    user_id=_d.get("user_id", ""),
    op_password=_d.get("op_password", ""),
    oppwd=_d.get("oppwd", ""),
)
ep = Endpoints(**_d.get("endpoints", {})) if _d.get("endpoints") else Endpoints()
cli = LeapmotorClient(cfg, ep)


# ---------------- 模型 ----------------
class LoginReq(BaseModel):
    identifier: str
    identifier_type: str = "1"
    security: str = ""


class SetKeyReq(BaseModel):
    sign_key: str = ""
    token: str = ""
    op_password: str = ""
    oppwd: str = ""
    carvin: str = ""
    cartype: str = ""
    user_id: str = ""


class ControlReq(BaseModel):
    action: str                      # lock/unlock/trunk/hello/hvac_off/hvac_low/hvac_high/light_off/light_auto
    vin: str = ""
    op_password: str = ""
    oppwd: str = ""
    state: dict = {}
    wait: bool = True


# ---------------- 路由 ----------------
@app.get("/", response_class=HTMLResponse)
def index():
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


@app.get("/api/actions")
def actions():
    return {k: {"cmdid": v[0], "state": v[1]} for k, v in CTRL_COMMANDS.items()}


@app.post("/api/config")
def set_config(r: SetKeyReq):
    """运行时注入 token / 操作密码（signKey 与 oppwd 会自动派生）"""
    if r.sign_key:
        cli.cfg.sign_key = r.sign_key
    if r.token:
        cli.cfg.token = r.token
    if r.op_password:
        cli.cfg.op_password = r.op_password
    if r.oppwd:
        cli.cfg.oppwd = r.oppwd
    if r.carvin:
        cli.cfg.carvin = r.carvin
    if r.cartype:
        cli.cfg.cartype = r.cartype
    if r.user_id:
        cli.cfg.user_id = r.user_id
    return {"ok": True, "has_sign_key": bool(cli.cfg.sign_key),
            "has_token": bool(cli.cfg.token), "carvin": cli.cfg.carvin}


@app.post("/api/login")
def login(r: LoginReq):
    try:
        res = cli.login(r.identifier, r.identifier_type, r.security)
        return {"ok": True,
                "sign_key_hex": getattr(cli, "sign_key_hex", None),
                "encrypt_key_hex": getattr(cli, "encrypt_key_hex", None),
                "sign_param": getattr(cli, "sign_param", {}),
                "encrypt_param": getattr(cli, "encrypt_param", {}),
                "has_token": bool(cli.cfg.token), "raw": res}
    except Exception as e:
        raise HTTPException(400, str(e))


@app.get("/api/vehicles")
def vehicles():
    try:
        return cli.vehicle_list()
    except Exception as e:
        raise HTTPException(400, str(e))


@app.get("/api/status")
def status(vin: str = ""):
    try:
        return cli.status(vin or cli.cfg.carvin)
    except Exception as e:
        raise HTTPException(400, str(e))


@app.get("/api/mileage")
def mileage(vin: str = ""):
    try:
        return cli.mileage(vin or cli.cfg.carvin)
    except Exception as e:
        raise HTTPException(400, str(e))


@app.post("/api/control")
def control(r: ControlReq):
    vin = r.vin or cli.cfg.carvin
    if not vin:
        raise HTTPException(400, "vin 未配置")
    try:
        if r.op_password:
            cli.cfg.op_password = r.op_password
        res = cli.ctl(r.action, vin, oppwd=(r.oppwd or None),
                      extra_state=r.state or None)
        out = {"ok": True, "raw": res}
        msg_id = (res or {}).get("data") if isinstance(res, dict) else None
        if isinstance(msg_id, str) and msg_id.isdigit():
            out["msg_id"] = msg_id
            if r.wait:
                out["success"] = cli.ctl_wait(msg_id)
        return out
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(400, str(e))


@app.get("/api/ctl_query")
def ctl_query(msg_id: str):
    try:
        return cli.ctl_query(msg_id)
    except Exception as e:
        raise HTTPException(400, str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)
