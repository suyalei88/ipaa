//
//  LMAES.swift
//  LeapmotorLite
//
//  AES-128-CBC + PKCS7 —— 对齐 +[LMVAESUtil AESEncryptData:key:iv:]
//                              +[LMVAESUtil AES128Operation:data:key:iv:]
//
//  原实现：CCCrypt(op, kCCAlgorithmAES, kCCOptionPKCS7Padding, keyCStr, 16, ivCStr, ...)
//  key / iv 通过 getCString:maxLength:17 encoding:NSUTF8StringEncoding 取 → 各 16 字节 ASCII
//
import Foundation
import CommonCrypto

enum LMAES {

    enum AESError: Error { case badKeyOrIV, cryptFailed(Int32), encodeFailed }

    /// AES-128-CBC + PKCS7 加密，返回密文的 base64（UTF-8 字符串）
    static func encryptToBase64(plaintext: String, key: String, iv: String) throws -> String {
        let ct = try crypt(operation: CCOperation(kCCEncrypt),
                           data: Data(plaintext.utf8),
                           key: key, iv: iv)
        return ct.base64EncodedString()
    }

    /// AES-128-CBC + PKCS7 解密（输入 base64）
    static func decryptFromBase64(cipherB64: String, key: String, iv: String) throws -> String {
        guard let ct = Data.fromLooseBase64(cipherB64) else { throw AESError.encodeFailed }
        let pt = try crypt(operation: CCOperation(kCCDecrypt), data: ct, key: key, iv: iv)
        guard let s = String(data: pt, encoding: .utf8) else { throw AESError.encodeFailed }
        return s
    }

    // MARK: - 核心

    /// key / iv 均为 16 个 ASCII 字符（与原生 getCString:maxLength:17 一致）
    static func crypt(operation: CCOperation, data: Data, key: String, iv: String) throws -> Data {
        let keyBytes = Array(key.utf8)
        let ivBytes = Array(iv.utf8)
        guard keyBytes.count == kCCKeySizeAES128, ivBytes.count == kCCBlockSizeAES128 else {
            throw AESError.badKeyOrIV
        }

        // 容量必须在闭包外取出来。
        // out.withUnsafeMutableBytes 是对 out 的**修改**访问，若在它内部再读
        // out.count，Swift 的独占访问检查会直接报错：
        //   "overlapping accesses to 'out', but modification requires exclusive access"
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let inLength = data.count
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                keyBytes.withUnsafeBytes { kBuf in
                    ivBytes.withUnsafeBytes { ivBuf in
                        CCCrypt(operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),   // ← 注意：无 ECB，即 CBC
                                kBuf.baseAddress, kCCKeySizeAES128,
                                ivBuf.baseAddress,
                                inBuf.baseAddress, inLength,
                                outBuf.baseAddress, outCapacity,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw AESError.cryptFailed(status) }
        out.removeSubrange(moved..<out.count)
        return out
    }
}
