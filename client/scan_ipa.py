#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IPA 静态侦察 — 对标 scan_apk.py，用于 iOS 解密 IPA
====================================================
用法:
  python client/scan_ipa.py <decrypted.ipa> [out.txt]

会做:
  1) 解包 IPA，定位 Payload/*.app 与主二进制
  2) 找 RN bundle / Hermes 字节码（如果有）
  3) 全量扫 URL / 域名 / 签名关键词
  4) 输出零跑相关域名 + 疑似接口路径

前提: IPA 必须已脱壳（FairPlay 解密），否则主二进制是密文，扫不出东西。
"""
import os
import re
import sys
import zipfile

URL_RX = re.compile(rb"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]{4,200}")
DOMAIN_RX = re.compile(rb"\b(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+(?:com|cn|net|org|io|co|vip|top|xyz)\b")
PATH_RX = re.compile(rb"[\"/]([a-zA-Z0-9_\-/]{4,80})")
KW_RX = re.compile(rb"(?i)(sign|signature|nonce|appkey|app_secret|secretkey|access_key|token|carvin|cartype|/api/|/vehicle)")
INTEREST = ("leapmotor", "leap", "dahua", "zerorun", "lpmotor", "lp-motor")

# 媒体/字体等跳过
SKIP_EXT = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".mp4", ".ttf", ".otf",
            ".caf", ".m4a", ".mp3", ".car", ".nib", ".storyboardc")


def is_encrypted_binary(data: bytes) -> bool:
    """检查 Mach-O LC_ENCRYPTION_INFO cryptid (粗略: 找 'cryptid' 附近非 0)"""
    if data[:4] not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                        b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        return False
    # cryptid 字段在 LC_ENCRYPTION_INFO 里，简单启发式: 找 "crypt" 字符串
    return b"cryptid" in data[:0x4000] or b"LC_ENCRYPTION" in data[:0x4000]


def main(ipa, out):
    z = zipfile.ZipFile(ipa)
    names = z.namelist()

    app_prefix = None
    for n in names:
        if n.startswith("Payload/") and ".app/" in n:
            app_prefix = n.split(".app/")[0] + ".app/"
            break
    print(f"== IPA: {ipa}")
    print(f"== app: {app_prefix}")

    # 主二进制
    binary = None
    if app_prefix:
        app_name = app_prefix.rstrip("/").split("/")[-1][:-4]
        cand = app_prefix + app_name
        if cand in names:
            binary = cand
    print(f"== main binary: {binary}")

    # 找 RN / JS bundle
    jsb = [n for n in names if n.endswith((".jsbundle", ".bundle")) and "assets" not in n.lower()]
    jsb += [n for n in names if re.search(r"main\.jsbundle|index\.ios\.bundle|\.hbc$", n)]
    print(f"== RN/JS bundles: {jsb[:10]}")

    # 加密检查
    if binary:
        data = z.read(binary)
        print(f"== binary size: {len(data):,} bytes")
        enc = is_encrypted_binary(data)
        print(f"== FairPlay 加密: {'⚠️ 是（需先脱壳！）' if enc else '否（已解密 ✅）'}")

    # 扫描
    urls, domains, hits = set(), set(), []
    for info in z.infolist():
        if info.is_dir() or info.file_size > 80_000_000:
            continue
        n = info.filename
        if n.endswith(SKIP_EXT):
            continue
        # 只扫: 主二进制 / Frameworks / JS bundle / 配置
        if not (n == binary or "/Frameworks/" in n or n.endswith((".jsbundle", ".hbc", ".json", ".plist"))
                or n == app_prefix + "Info.plist"):
            if info.file_size > 2_000_000 and not n.endswith(".dylib"):
                continue
        try:
            data = z.read(info)
        except Exception:
            continue
        for m in URL_RX.finditer(data):
            urls.add((n, m.group().decode("ascii", "ignore")))
        for m in DOMAIN_RX.finditer(data):
            domains.add(m.group().decode("ascii", "ignore"))
        if KW_RX.search(data):
            hits.append(n)

    interesting = sorted(d for d in domains if any(k in d.lower() for k in INTEREST))

    lines = []
    lines.append(f"=== {len(urls)} URLs ===")
    for n, u in sorted(urls):
        lines.append(f"{u}\t[{n}]")
    lines.append(f"\n=== {len(interesting)} INTERESTING domains ===")
    lines += interesting
    lines.append(f"\n=== files with sign/token/api keywords ({len(set(hits))}) ===")
    lines += sorted(set(hits))

    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"\n-- 零跑相关域名 ({len(interesting)}) --")
    for d in interesting:
        print("   ", d)
    print(f"\n-- URL 样本 --")
    for n, u in sorted(urls)[:30]:
        print("   ", u)
    print(f"\nfull report -> {out}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python client/scan_ipa.py <decrypted.ipa> [out.txt]")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "evidence/scan_ipa.txt")
