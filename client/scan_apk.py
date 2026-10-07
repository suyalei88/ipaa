#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""扫描整个 APK（所有条目）里的 URL / 域名 / 关键词，输出到 evidence/scan_urls.txt

注：`evidence/leapmotor.apk` 已在 2026-10-07 的清理中删除（安卓侧分析早已完成，
结论见 evidence/FINDINGS.md）。要重跑这个脚本，自己放一份官方 APK 到默认路径，
或者直接把路径当第一个参数传进来：

    python client/scan_apk.py /path/to/leapmotor.apk evidence/scan_urls.txt
"""
import os
import re
import zipfile
import sys

APK = sys.argv[1] if len(sys.argv) > 1 else "evidence/leapmotor.apk"
OUT = sys.argv[2] if len(sys.argv) > 2 else "evidence/scan_urls.txt"

if not os.path.exists(APK):
    sys.exit(f"[x] 找不到 APK：{APK}\n"
             f"    evidence/leapmotor.apk 已在清理中删除，请自行放入官方包或指定路径。")

URL_RX = re.compile(rb"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]{4,200}")
DOMAIN_RX = re.compile(rb"\b(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+(?:com|cn|net|org|io|co|vip|top|xyz)\b")
KW_RX = re.compile(rb"(?i)(sign|signature|nonce|appkey|app_secret|secretkey|access_key|/api/|/app/|/vehicle|token)")

urls = set()
domains = set()
hits = []

z = zipfile.ZipFile(APK)
for info in z.infolist():
    if info.is_dir():
        continue
    name = info.filename
    # 跳过巨大的媒体/地图资源
    if any(name.endswith(e) for e in (".png", ".jpg", ".jpeg", ".webp", ".gif", ".mp4", ".ttf", ".otf", ".so")):
        # so 只扫小的自定义库
        if not (name.endswith(".so") and info.file_size < 12_000_000):
            continue
    try:
        data = z.read(info)
    except Exception:
        continue
    for m in URL_RX.finditer(data):
        urls.add((name, m.group().decode("ascii", "ignore")))
    for m in DOMAIN_RX.finditer(data):
        d = m.group().decode("ascii", "ignore")
        if not d.endswith((".png", ".jpg", ".json")):
            domains.add(d)
    if KW_RX.search(data):
        hits.append(name)

# 关注零跑/大华域名
interesting = [d for d in domains if any(k in d.lower() for k in
               ("leapmotor", "leap", "dahua", "zerorun", "lpmotor", "lp-motor", "autolink", "dahuasecurity"))]

with open(OUT, "w", encoding="utf-8") as f:
    f.write(f"=== {len(urls)} URLs ===\n")
    for n, u in sorted(urls):
        f.write(f"{u}\t[{n}]\n")
    f.write(f"\n=== {len(domains)} domains ===\n")
    for d in sorted(domains):
        f.write(d + "\n")
    f.write(f"\n=== {len(interesting)} INTERESTING domains ===\n")
    for d in sorted(interesting):
        f.write(d + "\n")
    f.write(f"\n=== files containing sign/token/api keywords ({len(hits)}) ===\n")
    for h in sorted(set(hits)):
        f.write(h + "\n")

print(f"URLs={len(urls)} domains={len(domains)} interesting={len(interesting)} kwfiles={len(set(hits))}")
print("--- INTERESTING DOMAINS ---")
for d in sorted(interesting):
    print("  ", d)
print("--- sample URLs ---")
for n, u in sorted(urls)[:40]:
    print("  ", u)
print(f"\nfull report -> {OUT}")
