# 验证签名算法：把抓包里的明文和 sign 对一下
# 用法: python verify_sign.py flow_2026xxxx.json
#
# 原理: 车控签名 = f(参与签名的字段 + 密钥)。
#       拿抓包记录里的 req_sign_headers + req_body 当输入，
#       用不同拼法/哈希试，直到输出 == 抓到的 sign。

import json
import sys
import hashlib
import itertools


def md5(s): return hashlib.md5(s.encode()).hexdigest()
def sha1(s): return hashlib.sha1(s.encode()).hexdigest()
def sha256(s): return hashlib.sha256(s.encode()).hexdigest()


def load_flow(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def candidate_bases(flow):
    """生成各种可能的签名明文拼接方式。"""
    h = {k.lower(): v for k, v in flow.get("req_sign_headers", {}).items()}
    body = flow.get("req_body", "")
    ts = h.get("timestamp", h.get("ts", ""))
    nonce = h.get("nonce", "")
    device = h.get("deviceid", h.get("device-id", ""))

    fields = {
        "timestamp": ts, "nonce": nonce, "deviceId": device,
        "appVersion": h.get("appversion", ""), "channel": h.get("channel", ""),
        "body": body,
    }
    # 常见拼接形态
    yield "kv_sorted_no_body", "&".join(f"{k}={v}" for k, v in sorted(fields.items()) if k != "body")
    yield "kv_sorted_with_body", "&".join(f"{k}={v}" for k, v in sorted(fields.items()))
    yield "ts_nonce_dev_body", ts + nonce + device + body
    yield "ts_nonce_body", ts + nonce + body
    yield "body_ts_nonce", body + ts + nonce
    yield "concat_all", "".join(str(v) for v in fields.values())
    yield "body_only", body


def main(path):
    flow = load_flow(path)
    sign = flow.get("req_sign_headers", {}).get("sign") \
        or flow.get("req_sign_headers", {}).get("signature") \
        or flow.get("req_sign_headers", {}).get("Sign", "")
    if not sign:
        print("[!] 该记录里没有 sign 字段")
        return
    print(f"[*] target sign = {sign}  (len={len(sign)})")

    hashes = {"md5": md5, "sha1": sha1, "sha256": sha256}
    salts = ["", "leapmotor", "leap", "Leapmotor@2024", "1234567890"]

    for name, base in candidate_bases(flow):
        for salt in salts:
            for hn, hf in hashes.items():
                out = hf(base + salt)
                mark = "  <<< MATCH" if out == sign.lower() else ""
                if mark:
                    print(f"[+] FOUND: base={name} salt='{salt}' hash={hn}{mark}")
                    print(f"    plaintext = {base + salt}")
                    return
    print("[-] 未命中。说明还有：字段顺序特殊 / 有额外 salt / 参数加密 / 走 native。")
    print("    -> 用 frida/hook_sign.js 抓 MessageDigest/HMAC 的输入输出。")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python verify_sign.py <flow_xxx.json>")
    else:
        main(sys.argv[1])
