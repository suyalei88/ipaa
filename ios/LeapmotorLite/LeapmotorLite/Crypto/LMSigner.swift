//
//  LMSigner.swift
//  LeapmotorLite
//
//  请求签名 / signKey 派生 / oppwd 加密
//  ============================================================
//  签名 ★双模式★ —— 原生
//  +[LMVHttpV3InterfaceTool formatHeaderForHTTPRequestHeaders:paras:deviceid:encryption:error:]
//  @ 0x106e6ee9c，`tbz w8, #0, 0x106e6f364` 在 0x106e6f2dc 按 bit0 分叉：
//
//      ┌ 登录前 (bit0 == 0)：sign = SHA256(valueStr).hex()          ← 无密钥
//      │     0x106e6f370: bl objc_msgSend(sha256String:)
//      └ 登录后 (bit0 == 1)：sign = HMAC_SHA256(valueStr, signKey).hex()
//            0x106e6f334: bl objc_msgSend(HMacHashWithKey:plaintext:)
//
//  这解释了此前所有 `302002002 签名信息校验失败` —— 登录请求被错误地 HMAC 签名了。
//
//      valueStr  = merge(signBody, signHeaders)
//                  → 去空值(null/undefined/"") → key 升序(UTF-16 code unit)
//                  → 只取 value，无分隔符 join("")
//
//      signHeaders 固定 8 个 key:
//          acceptLanguage / channel / deviceId / deviceType /
//          nonce / source / timestamp / version
//
//      signBody:
//          application/json       → JSON.parse(body)（非 JSON → {}）
//          x-www-form-urlencoded  → URL 解码后的表单字典 ★
//          无 body                → {}
//          GET 的 query params 一并 merge
//
//  signKey 派生（iOS -[LMVLocalLoginModel modelCustomTransformFromDictionary:]）
//
//      d1 = b64dec( base64url→base64( accessToken.split(".")[2] ) )
//      signKey = UPPER( hex( XOR3( d1, b64dec(signParam.r2), b64dec(signParam.r3) ) ) )
//
//  oppwd（iOS -[LMVOperatePwInteractor requestSignParamsWithPassword:]）
//
//      key = md5hex(accessToken[0..32])[8..24]    (16 个 ASCII 字符)
//      iv  = md5hex(accessToken[32..64])[8..24]   (16 个 ASCII 字符)
//      oppwd = base64( AES-128-CBC-PKCS7( password, key, iv ) )
//
import Foundation

enum LMSigner {

    /// 参与签名的 8 个固定 header（顺序无关，最终会按 key 排序）
    static let signHeaderKeys = [
        "acceptLanguage", "channel", "deviceId", "deviceType",
        "nonce", "source", "timestamp", "version",
    ]

    // MARK: - JS String(value) 语义

    /// 完全对齐 JS 的 `String(value)`：
    ///   null/undefined → ""        true/false → "true"/"false"
    ///   数字            → 整数不带 ".0"；数组 → 元素 join(",")；对象 → "[object Object]"
    static func jsString(_ value: Any?) -> String {
        guard let value = value else { return "" }

        // NSNull 必须最先判断
        if value is NSNull { return "" }

        // NSNumber 必须先于 Bool 判断：Swift 的 Bool 桥接后就是 __NSCFBoolean，
        // 而 NSNumber(1) 用 `as? Bool` 也可能成立，所以用 CFGetTypeID 精确区分。
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            let d = n.doubleValue
            if d.isFinite && d == d.rounded() && abs(d) < 1e15 {
                return String(Int64(d))
            }
            return String(d)
        }

        if let s = value as? String { return s }
        if let b = value as? Bool { return b ? "true" : "false" }

        if let arr = value as? [Any] {
            return arr.map { jsString($0) }.joined(separator: ",")
        }

        if value is [String: Any] { return "[object Object]" }

        return String(describing: value)
    }

    // MARK: - valueStr

    /// 完全对齐 JS buildSignValueString()
    static func buildSignValueString(body: [String: Any]?, signHeaders: [String: Any]) -> String {
        var merged: [String: Any] = [:]
        if let body = body {
            for (k, v) in body { merged[k] = v }
        }
        for (k, v) in signHeaders { merged[k] = v }

        // 过滤：null / undefined / ""
        let items = merged.filter { _, v in
            if v is NSNull { return false }
            if let s = v as? String, s.isEmpty { return false }
            return true
        }

        // key 升序（JS 默认字符串比较 = UTF-16 code unit）
        let sorted = items.keys.sorted(by: jsKeyLess)

        // 只取 value，无分隔符拼接
        return sorted.map { jsString(items[$0]) }.joined()
    }

    /// JS 的 `a < b`（UTF-16 code unit 序），不是 Swift 的 Unicode 语义序
    static func jsKeyLess(_ a: String, _ b: String) -> Bool {
        let ua = Array(a.utf16), ub = Array(b.utf16)
        let n = min(ua.count, ub.count)
        var i = 0
        while i < n {
            if ua[i] != ub[i] { return ua[i] < ub[i] }
            i += 1
        }
        return ua.count < ub.count
    }

    // MARK: - 签名

    /// 登录前签名：`sign = SHA256(valueStr)`（无密钥）
    ///
    /// 用于 `/base/base-user/account/v1/login` 这类「换 token」请求。
    /// 对应原生 `-[NSString sha256String]` @ 0x106e6f370。
    static func signPreLogin(body: [String: Any]?, signHeaders: [String: Any]) -> String {
        LMHash.sha256Hex(buildSignValueString(body: body, signHeaders: signHeaders))
    }

    /// 登录后签名：`sign = HMAC_SHA256(valueStr, signKey)`；signKey 为空时返回 nil
    ///
    /// 用于车况 / 车控等所有已登录请求。
    static func sign(body: [String: Any]?, signHeaders: [String: Any], signKeyHex: String) -> String? {
        guard !signKeyHex.isEmpty else { return nil }
        let valueStr = buildSignValueString(body: body, signHeaders: signHeaders)
        return LMHash.hmacSHA256Hex(message: valueStr, key: LMHash.parseKey(signKeyHex))
    }

    // MARK: - signKey / encryptKey 派生

    /// signKey = UPPER(hex(XOR3(b64dec(b64url2b64(jwt[2])), b64dec(r2), b64dec(r3))))
    static func deriveKey(accessToken: String, r2: String, r3: String) -> Data? {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        guard let d1 = Data.fromBase64URLString(parts[2]),
              let d2 = Data.fromLooseBase64(r2),
              let d3 = Data.fromLooseBase64(r3) else { return nil }
        return LMHash.xor3(d1, d2, d3)
    }

    /// 一次性派生 signKey / encryptKey（实测两者相等，服务端保证 r2^r3 相同）
    static func deriveKeys(accessToken: String,
                           signParam: (r2: String, r3: String)?,
                           encryptParam: (r2: String, r3: String)?) -> (signKeyHex: String, encryptKeyHex: String) {
        var signKeyHex = ""
        var encryptKeyHex = ""
        if let sp = signParam, let k = deriveKey(accessToken: accessToken, r2: sp.r2, r3: sp.r3) {
            signKeyHex = k.hexUppercased
        }
        if let ep = encryptParam, let k = deriveKey(accessToken: accessToken, r2: ep.r2, r3: ep.r3) {
            encryptKeyHex = k.hexUppercased
        }
        return (signKeyHex, encryptKeyHex)
    }

    // MARK: - oppwd

    /// oppwd = base64( AES-128-CBC-PKCS7( 操作密码, key, iv ) )
    static func encryptOppwd(accessToken: String, password: String) throws -> String {
        guard accessToken.count >= 64 else {
            throw NSError(domain: "LMSigner", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "accessToken 长度需 >= 64"])
        }
        let t = Array(accessToken)
        let head = String(t[0..<32])
        let tail = String(t[32..<64])
        let key = LMHash.md5Lower16(head)
        let iv = LMHash.md5Lower16(tail)
        return try LMAES.encryptToBase64(plaintext: password, key: key, iv: iv)
    }
}
