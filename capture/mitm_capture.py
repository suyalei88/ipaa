#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
零跑 APP 车控接口抓包插件 (mitmproxy addon)
------------------------------------------------
用途：把零跑 APP 的 HTTPS 车控流量抓下来，自动：
  1) 只保留零跑相关域名（可在 TARGET_HOSTS 里加）；
  2) 提取签名相关 header（sign / timestamp / nonce / token ...）；
  3) 把 request/response 按时间戳落盘到 evidence/ 目录，方便离线对比签名。

启动：
  mitmproxy -s mitm_capture.py -p 8080
  # 或
  mitmdump -s mitm_capture.py -p 8080 -w evidence/raw_flow.dump

手机端设置代理到 <PC_IP>:8080，装 mitm 证书（Android 7+ 需 root 或改 APK networkSecurityConfig）。
"""

import json
import os
import time
from datetime import datetime

from mitmproxy import ctx, http

# ------- 配置区 -------
# 零跑常见域名关键词，抓到新域名就加进来
TARGET_HOSTS = [
    "leapmotor",
    "leap-motors",
    "lp-motor",
    "lpmotor",
    "zerorun",
]
# 关注的签名/鉴权 header（不区分大小写匹配）
SIGN_HEADERS = [
    "sign", "signature", "x-sign", "x-signature",
    "timestamp", "ts", "nonce", "x-nonce",
    "authorization", "token", "accesstoken", "access-token",
    "deviceid", "device-id", "appversion", "app-version",
    "channel", "x-request-id", "traceid",
]
# 落盘目录
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "evidence")
os.makedirs(OUT_DIR, exist_ok=True)

_seq = 0


def _is_target(host: str) -> bool:
    host = (host or "").lower()
    return any(k in host for k in TARGET_HOSTS)


def _pick_headers(headers) -> dict:
    out = {}
    for k, v in headers.items():
        if k.lower() in SIGN_HEADERS:
            out[k] = v
    return out


def _safe_body(content: bytes) -> str:
    if not content:
        return ""
    try:
        return content.decode("utf-8", errors="replace")
    except Exception:
        return f"<binary {len(content)} bytes>"


def request(flow: http.HTTPFlow) -> None:
    if not _is_target(flow.request.pretty_host):
        return
    hdrs = _pick_headers(flow.request.headers)
    if hdrs:
        ctx.log.info(f"[SIGN-HDR] {flow.request.method} {flow.request.pretty_url}")
        for k, v in hdrs.items():
            ctx.log.info(f"    {k}: {v}")


def response(flow: http.HTTPFlow) -> None:
    global _seq
    if not _is_target(flow.request.pretty_host):
        return
    _seq += 1
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    rec = {
        "seq": _seq,
        "time": datetime.now().isoformat(),
        "method": flow.request.method,
        "url": flow.request.pretty_url,
        "host": flow.request.pretty_host,
        "path": flow.request.path,
        "req_headers": dict(flow.request.headers),
        "req_sign_headers": _pick_headers(flow.request.headers),
        "req_body": _safe_body(flow.request.raw_content),
        "status": flow.response.status_code,
        "resp_headers": dict(flow.response.headers),
        "resp_body": _safe_body(flow.response.raw_content),
    }
    fn = os.path.join(OUT_DIR, f"flow_{ts}_{_seq:04d}.json")
    with open(fn, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False, indent=2)
    ctx.log.info(f"[SAVED] {fn}  ({flow.request.method} {flow.request.path} -> {flow.response.status_code})")
