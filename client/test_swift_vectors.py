#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_swift_vectors.py —— 校验 iOS 端 `Crypto/LMSelfTest.swift` 里嵌入的全部向量

作用：在没装 Xcode 的机器上（比如 Windows），也能证明 Swift 自测常量是对的。
      Swift 侧只要 `LMSelfTest.run()` 全绿，就说明实现与官方 App 逐字节一致。

    python client/test_swift_vectors.py
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from leapmotor_client import (  # noqa: E402
    build_sign_value_string, derive_sign_key, encrypt_oppwd, md5_lower16, parse_key,
)

# ============================================================
# 与 LMSelfTest.swift 逐字对应的常量
# ============================================================

DEMO_TOKEN = (
    "eyJub25jZSI6ImEyNzEwYjZkNDgwNDQ2ZTlhMjExOGI2YjIzZmQ3MDU3IiwiYWxnIjoiSFMyNTYiLCJ0eXAiOiJKV1QifQ"
    ".eyJ1c2VyX25hbWUiOiJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2LDEsZGV2aWNlSWQ6aW9zX2VlNDViOWQ4MzBi"
    "YjEyNmQ0MzFlOTk4OTQzYTc3OTdhLHBhc3N3b3JkOiIsInNjb3BlIjpbInJlYWQiXSwiZXhwIjoxNzkxMzU3ODExLCJhdXRo"
    "b3JpdGllcyI6WyJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2Il0sImp0aSI6IjJlZDE3MjcyLTBmOTktNDcwNy04MTE3"
    "LTU3OGYxMTAyYWI1NiIsInNpZ25fdGltZSI6MTc5MTM1MDYxMSwiY2xpZW50X2lkIjoiSHpUbWNzQmcifQ"
    ".y9ncviOjBWW1YSTbjf0RRJVB4_cWJIOAufJ-ZU7Ci1I"
)
SIGN_R2 = "6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo="
SIGN_R3 = "XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884="
ENC_R2 = "cYPovbbtY3Bxv+9m0+0+2v7CRs/s1FWbotOguVLySys="
ENC_R3 = "xnYhizldbR6gC4IUdU3o9aN5+Wv9RW95VoxyjSa6BR8="

EXPECT_SIGN_KEY = "7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566"
EXPECT_OPPWD = "uHTigfMDS5zIuZX4Gq4NVQ=="

# HMAC 回归样本（signal/info/query）
HMAC_BODY = {"appVersion": "1.22.68", "isMainApp": "1", "osType": "iOS", "vin": "LFZ63AA15TH035113"}
HMAC_HEADERS = {
    "acceptLanguage": "zh-CN", "channel": "1",
    "deviceId": "ios_ee45b9d830bb126d431e998943a7797a", "deviceType": "iOS",
    "nonce": "2020738377", "source": "leapmotor",
    "timestamp": "1791350716506", "version": "1.22.68",
}
EXPECT_HMAC_VALUESTR = (
    "zh-CN1.22.681ios_ee45b9d830bb126d431e998943a7797aiOS12020738377"
    "iOSleapmotor17913507165061.22.68LFZ63AA15TH035113"
)

# ★ 登录前签名样本（/base/base-user/account/v1/login，实测 code:0）
PRELOGIN_BODY = {
    "identifier": "672955179229782016",
    "identifierType": "1",
    "security": "8455A42EADA446B8A9FA3F6CCAE4E1808455A42EADA446B8A9FA3F6CCAE4E180",
}
PRELOGIN_HEADERS = {
    "acceptLanguage": "zh-Hans-CN;q=1, en-CN;q=0.9", "channel": "1",
    "deviceId": "ios_ee45b9d830bb126d431e998943a7797a", "deviceType": "iOS",
    "nonce": "152242336", "source": "leapmotor",
    "timestamp": "1791360825153", "version": "1.22.68",
}
EXPECT_PRELOGIN_VALUESTR = (
    "zh-Hans-CN;q=1, en-CN;q=0.91ios_ee45b9d830bb126d431e998943a7797aiOS"
    "67295517922978201611522423368455A42EADA446B8A9FA3F6CCAE4E1808455A42EADA446B8A9FA3F6CCAE4E180"
    "leapmotor17913608251531.22.68"
)
EXPECT_PRELOGIN_SIGN = "066fda165156e717a624dc4c53c7036ecb38a4c0cbd39d4fcb3d6e82c5df0863"

# RSA 公钥（SPKI base64，与 LMRSA.swift 一致）
RSA_SPKI_B64 = (
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8"
    "ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK"
    "7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB"
)


def _der_len(b: bytes, i: int) -> tuple[int, int]:
    """读一个 DER 长度，返回 (length, next_index)。"""
    l = b[i]
    i += 1
    if l & 0x80:
        n = l & 0x7F
        l = int.from_bytes(b[i:i + n], "big")
        i += n
    return l, i


def spki_to_pkcs1(der: bytes) -> bytes:
    """与 Swift LMRSA.pkcs1FromSPKI 等价的极简 DER 剥壳。

    SPKI = SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }
    """
    i = 0

    def read_len() -> int:
        nonlocal i
        b0 = der[i]
        i += 1
        if b0 & 0x80 == 0:
            return b0
        n = b0 & 0x7F
        v = int.from_bytes(der[i:i + n], "big")
        i += n
        return v

    assert der[i] == 0x30, hex(der[i])   # 外层 SEQUENCE
    i += 1
    read_len()
    assert der[i] == 0x30, hex(der[i])   # AlgorithmIdentifier
    i += 1
    alg_len = read_len()                 # 注意：不能写 i += read_len()
    i += alg_len                         # （Python 会先取 i 旧值再加，少跳一字节）
    assert der[i] == 0x03, hex(der[i])   # BIT STRING
    i += 1
    bit_len = read_len()
    assert der[i] == 0x00, hex(der[i])   # unused bits
    i += 1
    return der[i:i + bit_len - 1]


def main() -> int:
    results: list[tuple[str, bool, str]] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        results.append((name, ok, detail))

    # 1) signKey 派生
    k = derive_sign_key(DEMO_TOKEN, SIGN_R2, SIGN_R3).hex().upper()
    add("signKey 派生 (XOR3)", k == EXPECT_SIGN_KEY, k)
    ke = derive_sign_key(DEMO_TOKEN, ENC_R2, ENC_R3).hex().upper()
    add("encryptKey 派生 (== signKey)", ke == EXPECT_SIGN_KEY, ke)

    # 2) oppwd
    op = encrypt_oppwd(DEMO_TOKEN, "4211")
    add("oppwd('4211')", op == EXPECT_OPPWD, op)

    # 3) MD5-16
    m16 = md5_lower16("hello")
    add("MD5ForLower16Bate('hello')", len(m16) == 16, m16)

    # 4) HMAC key 解析
    add("HMAC key 解析 (64hex → 32B)", len(parse_key(EXPECT_SIGN_KEY)) == 32,
        f"{len(parse_key(EXPECT_SIGN_KEY))} bytes")

    # 5) HMAC valueStr + sign
    vs = build_sign_value_string(HMAC_BODY, HMAC_HEADERS)
    add("HMAC valueStr 构造", vs == EXPECT_HMAC_VALUESTR, vs if vs != EXPECT_HMAC_VALUESTR else "OK")
    sig = hmac.new(parse_key(EXPECT_SIGN_KEY), vs.encode(), hashlib.sha256).hexdigest()
    add("HMAC-SHA256 签名 (64hex)", len(sig) == 64, sig)

    # 6) ★ 登录前 valueStr + SHA256
    pvs = build_sign_value_string(PRELOGIN_BODY, PRELOGIN_HEADERS)
    add("登录前 valueStr 构造", pvs == EXPECT_PRELOGIN_VALUESTR,
        pvs if pvs != EXPECT_PRELOGIN_VALUESTR else "OK")
    psig = hashlib.sha256(pvs.encode()).hexdigest()
    add("登录前签名 SHA256(valueStr)", psig == EXPECT_PRELOGIN_SIGN,
        psig if psig != EXPECT_PRELOGIN_SIGN else "OK")

    # 7) RSA SPKI → PKCS#1（1024-bit → 140 字节 DER：30 81 89 02 81 81 00 … 02 03 01 00 01）
    pk = spki_to_pkcs1(base64.b64decode(RSA_SPKI_B64))
    add("RSA SPKI→PKCS#1 (140B)", len(pk) == 140, f"{len(pk)} bytes")

    # 顺带确认 PKCS#1 能解出合法 RSA-1024 公钥
    try:
        from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers
        j = 1
        _, j = _der_len(pk, j)
        assert pk[j] == 0x02
        j += 1
        ml, j = _der_len(pk, j)
        mod = int.from_bytes(pk[j:j + ml], "big")
        j += ml
        assert pk[j] == 0x02
        j += 1
        el, j = _der_len(pk, j)
        exp = int.from_bytes(pk[j:j + el], "big")
        RSAPublicNumbers(exp, mod).public_key()
        add("PKCS#1 → RSA-1024 (e=65537)", mod.bit_length() == 1024 and exp == 65537,
            f"{mod.bit_length()} bits, e={exp}")
    except ImportError:
        pass

    width = max(len(n) for n, _, _ in results)
    allok = True
    for name, ok, detail in results:
        allok &= ok
        print(f"[{'OK ' if ok else 'FAIL'}] {name.ljust(width)}  {detail}")

    print(f"\n{sum(1 for _, o, _ in results if o)}/{len(results)} passed"
          f"  {'✅ 与 Swift 自测常量一致' if allok else '❌ 有不一致'}")
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main())
