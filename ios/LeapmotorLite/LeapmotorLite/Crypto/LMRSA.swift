//
//  LMRSA.swift
//  LeapmotorLite
//
//  RSA-1024 PKCS#1 v1.5 公钥加密 —— 对齐原生 `EncodeForStrV1:`
//
//  用途（登录链路）：
//      phoneNoCiphertext = base64( RSA_PKCS1v15( 手机号, AccountIDKey ) )
//    · 发短信  GET  .../compliance/sendmessagecode?phoneNo=<enc>
//    · 登录    POST .../check_login_with_phone  form 字段 phoneNoCiphertext=<enc>
//
//  公钥是 X.509 SubjectPublicKeyInfo（SPKI）DER；
//  Security.framework 的 SecKeyCreateWithData 对 RSA 公钥要求 PKCS#1 格式，
//  所以这里先从 SPKI 里剥出内层 RSAPublicKey（SEQUENCE{ modulus, exponent }）。
//
import Foundation
import Security

enum LMRSA {

    enum RSAError: Error, LocalizedError {
        case badPublicKey(String)
        case encryptFailed(String)
        var errorDescription: String? {
            switch self {
            case .badPublicKey(let s):  return "RSA 公钥解析失败：\(s)"
            case .encryptFailed(let s): return "RSA 加密失败：\(s)"
            }
        }
    }

    /// 账号服务公钥（SPKI DER, base64）—— 来自 iOS 主二进制 AccountIDKey
    static let accountIDKeySPKIBase64 =
        "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8" +
        "ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK" +
        "7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB"

    /// 用内置公钥加密（PKCS#1 v1.5），返回 base64 密文
    static func encrypt(_ plaintext: String) throws -> String {
        try encrypt(plaintext, spkiBase64: accountIDKeySPKIBase64)
    }

    /// 指定 SPKI 公钥加密
    static func encrypt(_ plaintext: String, spkiBase64: String) throws -> String {
        guard let spki = Data(base64Encoded: spkiBase64) else {
            throw RSAError.badPublicKey("base64 解码失败")
        }
        // 优先按 SPKI 剥壳；已是 PKCS#1 时 pkcs1FromSPKI 返回 nil → 直接用原数据
        let pkcs1 = pkcs1FromSPKI(spki) ?? spki

        let attrs: [CFString: Any] = [
            kSecAttrKeyType as String:  kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, nil) else {
            throw RSAError.badPublicKey("SecKeyCreateWithData 失败（PKCS#1 DER \(pkcs1.count) 字节，1024-bit 应为 140）")
        }

        guard let cipher = SecKeyCreateEncryptedData(key,
                                                     .rsaEncryptionPKCS1,
                                                     Data(plaintext.utf8) as CFData,
                                                     nil) else {
            throw RSAError.encryptFailed("SecKeyCreateEncryptedData 返回 nil")
        }
        return (cipher as Data).base64EncodedString()
    }

    // MARK: - SPKI → PKCS#1

    /// 从 `SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }` 中取出内层 PKCS#1
    static func pkcs1FromSPKI(_ d: Data) -> Data? {
        var i = 0

        // 读一个 DER length（支持短格式 / 0x81 / 0x82）
        func readLen(_ idx: inout Int) -> Int? {
            guard idx < d.count else { return nil }
            let b0 = Int(d[idx]); idx += 1
            if b0 & 0x80 == 0 { return b0 }
            let n = b0 & 0x7F
            guard n >= 1, n <= 4, idx + n <= d.count else { return nil }
            var v = 0
            for _ in 0..<n { v = (v << 8) | Int(d[idx]); idx += 1 }
            return v
        }

        // 外层 SEQUENCE
        guard i < d.count, d[i] == 0x30 else { return nil }
        i += 1
        guard readLen(&i) != nil else { return nil }

        // AlgorithmIdentifier SEQUENCE（跳过）
        guard i < d.count, d[i] == 0x30 else { return nil }
        i += 1
        guard let algLen = readLen(&i) else { return nil }
        i += algLen

        // BIT STRING
        guard i < d.count, d[i] == 0x03 else { return nil }
        i += 1
        guard let bitLen = readLen(&i) else { return nil }

        // BIT STRING 首字节 = unused bits（应为 0）
        guard i < d.count, d[i] == 0x00 else { return nil }
        i += 1

        let contentLen = bitLen - 1
        guard contentLen > 0, i + contentLen <= d.count else { return nil }
        return d.subdata(in: i..<(i + contentLen))
    }
}
