//
//  LMHash.swift
//  LeapmotorLite
//
//  哈希 / HMAC / XOR3 —— 与官方 iOS 1.22.68 及 Python 参考实现逐字节对齐
//
//  · md5Hex          : CryptoKit Insecure.MD5
//  · md5Lower16      : md5hex(s)[8:24]   （对齐 +[LMVMD5Util MD5ForLower16Bate:]）
//  · hmacSHA256Hex   : HMAC-SHA256, key 为「原始字节」（signKey 是 hex → 先 hex 解码）
//  · xor3            : 零填充到最长，逐字节异或
//
import Foundation
import CryptoKit

enum LMHash {

    // MARK: - MD5

    /// 32 位小写 hex MD5
    static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 对齐 +[LMVMD5Util MD5ForLower16Bate:]，即 md5hex(s) 的第 8..24 个字符（共 16 个）
    static func md5Lower16(_ s: String) -> String {
        let h = md5Hex(s)
        let start = h.index(h.startIndex, offsetBy: 8)
        let end = h.index(h.startIndex, offsetBy: 24)
        return String(h[start..<end])
    }

    /// 对齐 +[LMVMD5Util MD5ForLower32Bate:]（全 32 位小写 hex）
    static func md5Lower32(_ s: String) -> String { md5Hex(s) }

    // MARK: - SHA256

    /// 64 位小写 hex SHA256
    ///
    /// ★ 登录前签名（`sign = sha256(valueStr)`）用这个，
    ///   对应原生 `-[NSString sha256String]` @ 0x106e6f370
    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HMAC-SHA256

    /// HMAC-SHA256，返回 64 位小写 hex
    static func hmacSHA256Hex(message: String, key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 对齐 JS parseKeyString()：
    ///   · 纯 hex 字符串 → hex 解码成字节
    ///   · 其它字符串   → UTF-8 字节
    static func parseKey(_ signKey: String) -> Data {
        let s = signKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if !s.isEmpty,
           s.unicodeScalars.allSatisfy({ hexSet.contains($0) }),
           s.count % 2 == 0 {
            return Data(hexString: s) ?? Data(s.utf8)
        }
        return Data(s.utf8)
    }

    // MARK: - XOR3

    /// 对齐 +[LMVLocalLoginModel xorThreeData:data2:data3:]
    /// n = max(len(a), len(b), len(c));  out[i] = a[i] ^ b[i] ^ c[i]（越界取 0）
    static func xor3(_ d1: Data, _ d2: Data, _ d3: Data) -> Data {
        let n = max(d1.count, max(d2.count, d3.count))
        var out = Data(count: n)
        for i in 0..<n {
            let a: UInt8 = i < d1.count ? d1[d1.startIndex + i] : 0
            let b: UInt8 = i < d2.count ? d2[d2.startIndex + i] : 0
            let c: UInt8 = i < d3.count ? d3[d3.startIndex + i] : 0
            out[i] = a ^ b ^ c
        }
        return out
    }
}

// MARK: - Data 辅助

extension Data {

    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        self = out
    }

    var hexUppercased: String {
        map { String(format: "%02X", $0) }.joined()
    }

    var hexLowercased: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// base64url → 标准 base64（补 '='）
    static func fromBase64URLString(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        if t.count % 4 != 0 { t += String(repeating: "=", count: 4 - t.count % 4) }
        return Data(base64Encoded: t)
    }

    /// 宽松 base64（自动补 '='，容忍缺失）
    static func fromLooseBase64(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count % 4 != 0 { t += String(repeating: "=", count: 4 - t.count % 4) }
        return Data(base64Encoded: t)
    }
}
