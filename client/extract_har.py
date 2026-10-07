#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从两份 HAR 里提取全部 API 调用（路径/头/体/响应），合并去重输出。"""
import json
import sys
import urllib.parse

FILES = ["evidence/har_appgw.har", "evidence/har_stream.har"]
API_HOSTS = ("appgateway.leapmotor.com", "app-gw-global-master.leapmotor.com",
             "iov-api.leapmotor.com", "appuser.leapmotor.cn")

rows = {}
for f in FILES:
    try:
        d = json.load(open(f, encoding="utf-8"))
    except Exception as e:
        print("skip", f, e)
        continue
    for e in d["log"]["entries"]:
        r = e["request"]
        host = r["url"].split("/")[2]
        if host not in API_HOSTS:
            continue
        path = r["url"].split("/", 3)[3] if r["url"].count("/") >= 3 else ""
        key = (r["method"], path.split("?")[0])
        if key in rows:
            continue
        H = {h["name"]: h["value"] for h in r.get("headers", [])}
        rows[key] = {
            "method": r["method"], "host": host, "path": path,
            "body": r.get("postData", {}).get("text", ""),
            "ct": H.get("content-type", ""),
            "resp_status": e["response"].get("status"),
            "resp": e["response"].get("content", {}).get("text", ""),
            "sign": H.get("sign", ""),
        }

print(f"共 {len(rows)} 个唯一 API 调用\n")
print("=" * 100)
for (m, p), v in sorted(rows.items(), key=lambda kv: kv[1]["path"]):
    print(f"{m:5s} {v['host']}{v['path'][:95]}")
    if v["body"]:
        print(f"      REQ : {v['body'][:200]}")
    rp = v["resp"][:220].replace("\n", " ")
    if rp:
        print(f"      RESP: {rp}")
    print()

# 保存完整
with open("evidence/har_api_dump.txt", "w", encoding="utf-8") as f:
    for (m, p), v in sorted(rows.items(), key=lambda kv: kv[1]["path"]):
        f.write(f"{m} {v['host']}{v['path']}\n")
        if v["body"]:
            f.write(f"  REQ : {v['body']}\n")
        if v["resp"]:
            f.write(f"  RESP: {v['resp'][:2000]}\n")
        f.write("\n")
print("完整 -> evidence/har_api_dump.txt")
