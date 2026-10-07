//
//  LMSelfTest.swift
//  LeapmotorLite
//
//  内置自检：用真实抓包样本验证四个算法的实现是否逐字节正确。
//  任意一条失败 → 签名/加密实现有问题，车控一定不通。
//
import Foundation

struct LMSelfTest {

    struct Result: Identifiable {
        let id = UUID()
        let name: String
        let passed: Bool
        let detail: String
    }

    /// 真实抓包（evidence/har_appgw.har）中的登录响应
    static let demoToken = """
    eyJub25jZSI6ImEyNzEwYjZkNDgwNDQ2ZTlhMjExOGI2YjIzZmQ3MDU3IiwiYWxnIjoiSFMyNTYiLCJ0eXAiOiJKV1QifQ\
    .eyJ1c2VyX25hbWUiOiJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2LDEsZGV2aWNlSWQ6aW9zX2VlNDViOWQ4MzBi\
    YjEyNmQ0MzFlOTk4OTQzYTc3OTdhLHBhc3N3b3JkOiIsInNjb3BlIjpbInJlYWQiXSwiZXhwIjoxNzkxMzU3ODExLCJhdXRo\
    b3JpdGllcyI6WyJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2Il0sImp0aSI6IjJlZDE3MjcyLTBmOTktNDcwNy04MTE3\
    LTU3OGYxMTAyYWI1NiIsInNpZ25fdGltZSI6MTc5MTM1MDYxMSwiY2xpZW50X2lkIjoiSHpUbWNzQmcifQ\
    .y9ncviOjBWW1YSTbjf0RRJVB4_cWJIOAufJ-ZU7Ci1I
    """

    static let signR2 = "6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo="
    static let signR3 = "XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884="
    static let encR2  = "cYPovbbtY3Bxv+9m0+0+2v7CRs/s1FWbotOguVLySys="
    static let encR3  = "xnYhizldbR6gC4IUdU3o9aN5+Wv9RW95VoxyjSa6BR8="

    static let expectSignKeyHex = "7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566"
    static let expectOppwd      = "uHTigfMDS5zIuZX4Gq4NVQ=="

    /// 抓包样本：signal/info/query 的签名输入
    static let sampleBody: [String: Any] = [
        "appVersion": "1.22.68",
        "isMainApp": "1",
        "osType": "iOS",
        "vin": "LFZ63AA15TH035113",
    ]
    static let sampleHeaders: [String: Any] = [
        "acceptLanguage": "zh-CN",
        "channel": "1",
        "deviceId": "ios_ee45b9d830bb126d431e998943a7797a",
        "deviceType": "iOS",
        "nonce": "2020738377",
        "source": "leapmotor",
        "timestamp": "1791350716506",
        "version": "1.22.68",
    ]
    static let expectValueStr =
        "zh-CN1.22.681ios_ee45b9d830bb126d431e998943a7797aiOS12020738377iOSleapmotor17913507165061.22.68LFZ63AA15TH035113"

    // MARK: - 登录前签名样本（★ 真实链路，实测 code:0 SUCCESS）

    /// `/base/base-user/account/v1/login` 的 body（外层 token 兑换 JWT）
    static let preLoginBody: [String: Any] = [
        "identifier": "672955179229782016",
        "identifierType": "1",
        "security": "8455A42EADA446B8A9FA3F6CCAE4E1808455A42EADA446B8A9FA3F6CCAE4E180",
    ]
    static let preLoginHeaders: [String: Any] = [
        "acceptLanguage": "zh-Hans-CN;q=1, en-CN;q=0.9",
        "channel": "1",
        "deviceId": "ios_ee45b9d830bb126d431e998943a7797a",
        "deviceType": "iOS",
        "nonce": "152242336",
        "source": "leapmotor",
        "timestamp": "1791360825153",
        "version": "1.22.68",
    ]
    static let expectPreLoginValueStr =
        "zh-Hans-CN;q=1, en-CN;q=0.91ios_ee45b9d830bb126d431e998943a7797aiOS67295517922978201611522423368455A42EADA446B8A9FA3F6CCAE4E1808455A42EADA446B8A9FA3F6CCAE4E180leapmotor17913608251531.22.68"
    static let expectPreLoginSign = "066fda165156e717a624dc4c53c7036ecb38a4c0cbd39d4fcb3d6e82c5df0863"

    static func run() -> [Result] {
        var out: [Result] = []

        // 1) valueStr 构造
        let vs = LMSigner.buildSignValueString(body: sampleBody, signHeaders: sampleHeaders)
        out.append(Result(name: "valueStr 构造（去空 + key 升序 + 只拼 value）",
                          passed: vs == expectValueStr,
                          detail: vs == expectValueStr ? "OK" : "得到 \(vs)"))

        // 2) signKey / encryptKey 派生
        let keys = LMSigner.deriveKeys(
            accessToken: demoToken,
            signParam: (signR2, signR3),
            encryptParam: (encR2, encR3))
        out.append(Result(name: "signKey 派生（XOR3(jwtSig, r2, r3) → HEX 大写）",
                          passed: keys.signKeyHex == expectSignKeyHex,
                          detail: keys.signKeyHex))
        out.append(Result(name: "encryptKey 派生（应与 signKey 相同）",
                          passed: keys.encryptKeyHex == expectSignKeyHex,
                          detail: keys.encryptKeyHex))

        // 3) oppwd 加密（AES-128-CBC-PKCS7 + MD5-16 派生 key/iv）
        do {
            let op = try LMSigner.encryptOppwd(accessToken: demoToken, password: "4211")
            out.append(Result(name: "oppwd 加密（明文 4211）",
                              passed: op == expectOppwd,
                              detail: op))
        } catch {
            out.append(Result(name: "oppwd 加密", passed: false, detail: error.localizedDescription))
        }

        // 4) MD5-16
        let m16 = LMHash.md5Lower16("hello")
        out.append(Result(name: "MD5ForLower16Bate(\"hello\")",
                          passed: m16.count == 16,
                          detail: m16))

        // 5) HMAC key 解析（hex → 字节）
        let keyData = LMHash.parseKey(expectSignKeyHex)
        out.append(Result(name: "HMAC key 解析（64 hex → 32 字节）",
                          passed: keyData.count == 32,
                          detail: "\(keyData.count) bytes"))

        // 6) 完整 sign 复算（用 signKey + 固定 nonce/timestamp）
        if let sign = LMSigner.sign(body: sampleBody, signHeaders: sampleHeaders, signKeyHex: expectSignKeyHex) {
            out.append(Result(name: "HMAC-SHA256 签名（64 hex）",
                              passed: sign.count == 64,
                              detail: sign))
        } else {
            out.append(Result(name: "HMAC-SHA256 签名", passed: false, detail: "返回 nil"))
        }

        // 7) 登录前签名：sign = SHA256(valueStr)（无密钥）
        let pvs = LMSigner.buildSignValueString(body: preLoginBody, signHeaders: preLoginHeaders)
        out.append(Result(name: "登录前 valueStr 构造（8 header + body 合并排序）",
                          passed: pvs == expectPreLoginValueStr,
                          detail: pvs == expectPreLoginValueStr ? "OK" : "得到 \(pvs)"))

        let psign = LMSigner.signPreLogin(body: preLoginBody, signHeaders: preLoginHeaders)
        out.append(Result(name: "登录前签名 SHA256(valueStr)",
                          passed: psign == expectPreLoginSign,
                          detail: psign == expectPreLoginSign ? psign : "得到 \(psign)"))

        // 8) RSA 公钥解析（SPKI → PKCS#1；1024-bit → 140 字节 DER）
        if let spki = Data(base64Encoded: LMRSA.accountIDKeySPKIBase64),
           let pkcs1 = LMRSA.pkcs1FromSPKI(spki) {
            out.append(Result(name: "RSA 公钥 SPKI→PKCS#1（140B）",
                              passed: pkcs1.count == 140,
                              detail: "\(pkcs1.count) bytes"))
        } else {
            out.append(Result(name: "RSA 公钥 SPKI→PKCS#1", passed: false, detail: "解析失败"))
        }

        return out
    }
}
