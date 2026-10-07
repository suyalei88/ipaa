//
//  LMClient.swift
//  LeapmotorLite
//
//  零跑车控 API 客户端（Swift / async-await）
//  端点、请求体格式、cmdid 均来自真实抓包 + iOS 主二进制逆向
//
import Foundation

// MARK: - 配置

struct LMConfig {
    var deviceId: String        = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var deviceType: String      = "iOS"
    var acceptLanguage: String  = "zh-Hans-CN;q=1, en-CN;q=0.9"
    var source: String          = "leapmotor"
    var version: String         = "1.22.68"
    var channel: String         = "1"
    var subversion: String      = "3.22.2-3"
    var userAgent: String       = "leapmotorCarOwner/1.22.68 (iPhone; iOS \(ProcessInfo.processInfo.operatingSystemVersionString); Scale/3.00)"
    var timeout: TimeInterval   = 20

    /// 短信网关用的 SM4 设备指纹（国密，逆向自原生；登录链路必需）
    var smDeviceId: String      = LMConfig.capturedSMDeviceId

    /// 复用官方抓包里的 deviceId 可以避免部分风控；留空则自动生成
    static let capturedDeviceId = "ios_ee45b9d830bb126d431e998943a7797a"
    /// 抓包里的 SM4 设备指纹
    static let capturedSMDeviceId =
        "B1rFqR82E2Z7do2KhMDKziLEuIcoEt4wY8QTy7/43ImlKMu591xoe/c8kgMPsTk4" +
        "P/nPH8eAUxQCnmA3GjTZODg=="
}

// MARK: - 会话

struct LMSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String = ""
    var signKeyHex: String
    var encryptKeyHex: String
    var userId: String = ""
    var accountId: String = ""
    var nickname: String = ""
    /// 操作密码（明文），用于每次车控时派生 oppwd
    var opPassword: String = ""

    var isValid: Bool { !accessToken.isEmpty && !signKeyHex.isEmpty }
}

// MARK: - 错误

enum LMError: LocalizedError {
    case notLoggedIn
    case http(Int, String)
    case business(Int, String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:            return "未登录，请先导入或登录会话"
        case .http(let c, let b):     return "HTTP \(c)：\(b.prefix(200))"
        case .business(let c, let m): return "业务错误 \(c)：\(m)"
        case .decoding(let s):        return "解析失败：\(s)"
        case .transport(let s):       return "网络错误：\(s)"
        }
    }
}

// MARK: - 车控诊断记录

/// 一次车控请求的完整「体检单」。
///
/// 为什么要留这个：服务端报「操作密码错误 / 累计出错」时，光看 UI 完全没法判断
/// 到底是①密码输错了、②key/iv 派生错了、③base64 在 URL 里被吃了。
/// 把派生 key/iv、最终 oppwd、token 头尾都摊在界面上，一眼就能定位。
struct LMControlTrace: Identifiable {
    let id = UUID()
    let time: Date
    let action: String
    let cmdid: Int
    /// 用户输入的操作密码位数（只报位数，不回显明文）
    let passwordLength: Int
    /// md5(accessToken[0..32])[8..24]，16 个 ASCII 字符
    let key: String
    /// md5(accessToken[32..64])[8..24]
    let iv: String
    /// base64(AES-128-CBC-PKCS7(password, key, iv))
    let oppwd: String
    /// 用同一组 key/iv 把 oppwd 解回来 —— 应该正好等于输入的密码
    let roundTrip: String
    let tokenHead: String
    let tokenTail: String
    /// 服务端结论，如 "code 0 请求成功" / "业务错误 70：操作密码累计出错3次以上…"
    var outcome: String

    var roundTripOK: Bool { !roundTrip.isEmpty && roundTrip != "<解密失败>" }
}

// MARK: - 客户端

@MainActor
final class LMClient: ObservableObject {

    // MARK: Published 状态

    @Published private(set) var session: LMSession?
    @Published private(set) var vehicles: [LMVehicle] = []
    @Published private(set) var selectedVehicle: LMVehicle?
    @Published private(set) var signals: [String: LMSignalValue] = [:]
    @Published private(set) var mileage: LMMileageData?
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    /// 服务端「操作密码累计出错」锁定到什么时候（业务码 70，官方提示等 5 分钟）
    @Published private(set) var controlLockedUntil: Date?
    /// 最近一次车控请求的体检单
    @Published private(set) var lastControlTrace: LMControlTrace?

    var isControlLocked: Bool {
        guard let t = controlLockedUntil else { return false }
        return t > Date()
    }

    /// 还剩几秒解锁（向上取整）
    var controlLockRemaining: Int {
        guard let t = controlLockedUntil else { return 0 }
        return max(0, Int(t.timeIntervalSinceNow.rounded(.up)))
    }

    func clearControlLock() { controlLockedUntil = nil }

    var config = LMConfig()

    private let store = LMSessionStore()
    private let urlSession: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        urlSession = URLSession(configuration: cfg)
        session = store.load()
    }

    // MARK: - 会话管理

    /// 写入内存 + Keychain；返回 Keychain 是否真的写成功
    @discardableResult
    func adopt(session newSession: LMSession) -> Bool {
        session = newSession
        return store.save(newSession)
    }

    func signOut() {
        session = nil
        vehicles = []
        selectedVehicle = nil
        signals = [:]
        mileage = nil
        store.clear()
    }

    func select(vehicle: LMVehicle) {
        selectedVehicle = vehicle
    }

    // MARK: - 请求头

    private func buildHeaders(signBody: [String: Any]?, skipAuth: Bool, contentType: String) -> [String: String] {
        if skipAuth { return ["Content-Type": contentType] }

        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = String(Int.random(in: 0...2_147_483_646))

        let signHeaders: [String: Any] = [
            "acceptLanguage": config.acceptLanguage,
            "channel": config.channel,
            "deviceId": config.deviceId,
            "deviceType": config.deviceType,
            "nonce": nonce,
            "source": config.source,
            "timestamp": ts,
            "version": config.version,
        ]

        var headers: [String: String] = ["Content-Type": contentType]
        if let s = session, !s.signKeyHex.isEmpty {
            if let sign = LMSigner.sign(body: signBody, signHeaders: signHeaders, signKeyHex: s.signKeyHex) {
                headers["sign"] = sign
            }
        }
        for (k, v) in signHeaders { headers[k] = String(describing: v) }

        headers["x-subversion"] = config.subversion
        headers["x-canary-version"] = ""
        headers["x-api-signature-version"] = "2.0"
        headers["x-region"] = "CN"
        headers["userId"] = session?.userId ?? ""
        headers["token"] = session?.accessToken ?? ""
        headers["carvin"] = selectedVehicle?.vin ?? ""
        headers["cartype"] = selectedVehicle?.carType ?? ""
        headers["User-Agent"] = config.userAgent
        headers["Accept-Language"] = "zh-Hans-CN;q=1, en-CN;q=0.9"
        return headers
    }

    // MARK: - 通用请求

    @discardableResult
    func request(method: String,
                 path: String,
                 host: String = LMEndpoints.gateway,
                 params: [String: String]? = nil,
                 body: [String: Any]? = nil,
                 form: [String: String]? = nil,
                 skipAuth: Bool = false) async throws -> Any {

        // 1) 组装 URL
        guard let url = makeURL(host: host, path: path, params: params) else {
            throw LMError.transport("URL 非法：\(host + path)")
        }

        // 2) 参与签名的 body 字典
        var signBody: [String: Any] = [:]
        if let form = form {
            for (k, v) in form { signBody[k] = v }
        } else if let body = body {
            signBody = body
        }
        if let params = params {
            for (k, v) in params { signBody[k] = v }
        }

        let contentType = (form != nil) ? "application/x-www-form-urlencoded" : "application/json"
        let headers = buildHeaders(signBody: signBody, skipAuth: skipAuth, contentType: contentType)

        // 3) 请求体
        var bodyData: Data?
        if let form = form {
            bodyData = form
                .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
                .joined(separator: "&")
                .data(using: .utf8)
        } else if let body = body {
            bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }

        // 4) 发送
        return try await send(method: method, url: url, headers: headers,
                              bodyData: bodyData, throwsOnBusinessError: true)
    }

    /// 低层发送：负责 HTTP、解码、业务码校验（可选）
    private func send(method: String,
                      url: URL,
                      headers: [String: String],
                      bodyData: Data?,
                      throwsOnBusinessError: Bool) async throws -> Any {

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.allHTTPHeaderFields = headers
        req.timeoutInterval = config.timeout
        req.httpBody = bodyData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw LMError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw LMError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        if let obj = try? JSONSerialization.jsonObject(with: data) {
            if throwsOnBusinessError, let dict = obj as? [String: Any] {
                if let code = dict["code"] as? Int, code != 0 {
                    let msg = (dict["message"] as? String) ?? (dict["msg"] as? String) ?? ""
                    throw LMError.business(code, msg)
                }
            }
            return obj
        }
        return ["_raw": String(data: data, encoding: .utf8) ?? "",
                "_base64": data.base64EncodedString()]
    }

    /// appuser 短信网关的请求头（未登录 / 无 sign）
    private func userHostHeaders(contentType: String) -> [String: String] {
        [
            "APPImei": config.deviceId,
            "APPVersion": config.version,
            "APPPlatform": "iOS",
            "C-VERSIONS": "APP",
            "XFX-CDN-VRS": "v4",
            "User-Agent": config.userAgent,
            "Accept": "*/*",
            "Accept-Language": config.acceptLanguage,
            "Content-Type": contentType,
        ]
    }

    private func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 拼 URL（含 query string），用严格百分号编码。
    ///
    /// ⚠️ 绝不能用 `URLComponents.queryItems` —— `+` 属于 `CharacterSet.urlQueryAllowed`，
    /// 它**不会**把 `+` 转义成 `%2B`。而 RSA / AES 密文的 base64 里经常出现 `+`，
    /// 服务端按 form 规则解码时会把它当成空格，密文随之损坏，表现为
    ///     业务错误 1019：参数不能为空
    /// （实测：裸 `+` → 1019；`%2B` → code 200）。
    /// 这里用 `urlEncode`（只放行 unreserved 字符）从根上避免。
    private func makeURL(host: String, path: String, params: [String: String]?) -> URL? {
        var s = host + path
        if let params = params, !params.isEmpty {
            // 排序只为输出确定、方便比对日志；服务端不依赖 query 顺序
            let q = params.keys.sorted()
                .map { "\(urlEncode($0))=\(urlEncode(params[$0]!))" }
                .joined(separator: "&")
            s += "?" + q
        }
        return URL(string: s)
    }

    private func decode<T: Decodable>(_ type: T.Type, from any: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject(any) else {
            throw LMError.decoding("响应不是合法 JSON 对象")
        }
        let data = try JSONSerialization.data(withJSONObject: any)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - 登录

    /// 用「导入的登录响应」建立会话（最可靠，100% 已验证）
    /// - Parameter json: 官方 App 登录接口返回的整个 `data` 对象，或
    ///                   `{"accessToken":..,"signParam":{"r2":..,"r3":..},"encryptParam":{..}}`
    func adoptLoginResponse(json: String) throws -> LMSession {
        guard let data = json.data(using: .utf8) else { throw LMError.decoding("空输入") }

        var root = try JSONSerialization.jsonObject(with: data)
        // 容忍直接粘贴整个 {code,message,data:{...}} 信封
        if let dict = root as? [String: Any], let inner = dict["data"] as? [String: Any] {
            root = inner
        }
        guard let dict = root as? [String: Any] else { throw LMError.decoding("不是 JSON 对象") }

        let token = (dict["accessToken"] as? String) ?? ""
        guard !token.isEmpty else { throw LMError.decoding("缺少 accessToken") }

        let sp = dict["signParam"] as? [String: String]
        let ep = dict["encryptParam"] as? [String: String]

        var signKeyHex = ""
        var encryptKeyHex = ""
        if let sp = sp, let r2 = sp["r2"], let r3 = sp["r3"] {
            signKeyHex = LMSigner.deriveKey(accessToken: token, r2: r2, r3: r3)?.hexUppercased ?? ""
        }
        if let ep = ep, let r2 = ep["r2"], let r3 = ep["r3"] {
            encryptKeyHex = LMSigner.deriveKey(accessToken: token, r2: r2, r3: r3)?.hexUppercased ?? ""
        }
        guard !signKeyHex.isEmpty else { throw LMError.decoding("无法派生 signKey（缺少 signParam.r2/r3）") }

        let s = LMSession(
            accessToken: token,
            refreshToken: (dict["refreshToken"] as? String) ?? "",
            signKeyHex: signKeyHex,
            encryptKeyHex: encryptKeyHex,
            userId: String(describing: dict["accountId"] ?? ""),
            accountId: String(describing: dict["accountId"] ?? ""),
            nickname: (dict["nickname"] as? String) ?? "",
            opPassword: session?.opPassword ?? ""
        )
        adopt(session: s)
        return s
    }

    /// 只填 token + 两组 r2/r3 的简写方式
    func adoptManual(accessToken: String,
                     signR2: String, signR3: String,
                     encR2: String = "", encR3: String = "",
                     userId: String = "") throws -> LMSession {
        guard let k = LMSigner.deriveKey(accessToken: accessToken, r2: signR2, r3: signR3) else {
            throw LMError.decoding("signKey 派生失败")
        }
        var encHex = k.hexUppercased
        if !encR2.isEmpty, !encR3.isEmpty,
           let e = LMSigner.deriveKey(accessToken: accessToken, r2: encR2, r3: encR3) {
            encHex = e.hexUppercased
        }
        let s = LMSession(accessToken: accessToken,
                          signKeyHex: k.hexUppercased,
                          encryptKeyHex: encHex,
                          userId: userId,
                          accountId: userId,
                          opPassword: session?.opPassword ?? "")
        adopt(session: s)
        return s
    }

    /// 账号密码登录（已废弃：security 由服务端 SDK 下发，不是密码哈希）
    @available(*, deprecated, message: "改用短信验证码登录 loginWithSMSCode")
    func login(identifier: String, password: String) async throws -> LMSession {
        let h = LMHash.md5Hex(password).uppercased()
        return try await login(identifier: identifier, security: h + h)
    }

    /// 直接传 security（外层 token）的登录
    func login(identifier: String, security: String) async throws -> LMSession {
        try await exchangeOuterToken(security, accountId: identifier)
    }

    // MARK: - 登录（短信验证码 · 全链路实测打通）

    /// 短信登录第 2 步的结果
    struct SMSLoginResult: Equatable {
        var outerToken: String
        var accountId: String
        var nickname: String
    }

    /// 第 1 步：发送短信验证码
    ///
    /// `GET /app-user/applogin/compliance/sendmessagecode?phoneNo=<RSA>&smDeviceId=<SM4>`
    ///   · phoneNo = base64( RSA_PKCS1v15( 手机号 ) )   ← 见 LMRSA
    ///   · 未登录、无 sign
    @discardableResult
    func sendSMSCode(phone: String) async throws -> String {
        let enc = try LMRSA.encrypt(phone)
        // 必须走 makeURL：phoneNo 是 base64 密文，含 '+' 时用 URLComponents 会坏
        guard let url = makeURL(host: LMEndpoints.userHost,
                                path: LMEndpoints.Path.sendSMS,
                                params: ["phoneNo": enc, "smDeviceId": config.smDeviceId]) else {
            throw LMError.transport("URL 非法")
        }

        let any = try await send(method: "GET", url: url,
                                 headers: userHostHeaders(contentType: "application/json"),
                                 bodyData: nil, throwsOnBusinessError: false)
        let d = (any as? [String: Any]) ?? [:]
        let code = (d["code"] as? Int) ?? -1
        let msg = (d["msg"] as? String) ?? (d["message"] as? String) ?? ""
        guard code == 0 || code == 200 else {
            throw LMError.business(code, msg.isEmpty ? "验证码发送失败" : msg)
        }
        return msg.isEmpty ? "验证码已发送" : msg
    }

    /// 第 2 步：验证码 → 外层 token（SDK login token，还不是 JWT）
    ///
    /// `POST /app-user/applogin/check_login_with_phone`，**form-urlencoded**
    ///   （原生 `POST_Form` @0x104e959b0；用 JSON 会得到 1019 参数不能为空）
    func fetchOuterToken(phone: String, code: String) async throws -> SMSLoginResult {
        let enc = try LMRSA.encrypt(phone)
        guard let url = URL(string: LMEndpoints.userHost + LMEndpoints.Path.checkLoginWithPhone) else {
            throw LMError.transport("URL 非法")
        }

        let fields: [String: String] = [
            "os": "ios",
            "smDeviceId": config.smDeviceId,
            "phoneNoCiphertext": enc,
            "phoneNumber": phone,
            "smsCode": code,
            "deviceID": config.deviceId,
            "pageUrl": "",
        ]
        let bodyData = fields
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let any = try await send(method: "POST", url: url,
                                 headers: userHostHeaders(contentType: "application/x-www-form-urlencoded; charset=UTF-8"),
                                 bodyData: bodyData, throwsOnBusinessError: false)
        guard let d = any as? [String: Any] else { throw LMError.decoding("登录响应异常") }

        let code = (d["code"] as? Int) ?? -1
        guard code == 0 || code == 200 else {
            let msg = (d["msg"] as? String) ?? (d["message"] as? String) ?? "登录失败"
            throw LMError.business(code, msg)
        }

        guard let token = LMClient.findValue(d, key: "token") as? String, !token.isEmpty else {
            throw LMError.decoding("响应里没有 appLoginVO.token")
        }
        let accId = LMClient.findValue(d, key: "accountId").map { String(describing: $0) } ?? ""
        let nick  = (LMClient.findValue(d, key: "nickname") as? String) ?? ""
        return SMSLoginResult(outerToken: token, accountId: accId, nickname: nick)
    }

    /// 第 3 步：外层 token 兑换 JWT（★ SHA256 签名，无密钥）
    ///
    /// `POST /base/base-user/account/v1/login`
    /// body = `{"identifier": accountId, "identifierType": "1", "security": <外层token>}`
    /// → `data = { accessToken, refreshToken, signParam{r2,r3}, encryptParam{r2,r3}, ... }`
    func exchangeOuterToken(_ outerToken: String, accountId: String) async throws -> LMSession {
        let body: [String: Any] = [
            "identifier": accountId,
            "identifierType": "1",
            "security": outerToken,
        ]
        let any = try await preLoginRequest(path: LMEndpoints.Path.login,
                                            host: LMEndpoints.accountHost,
                                            body: body,
                                            accountId: accountId)
        guard let dict = any as? [String: Any] else { throw LMError.decoding("登录响应异常") }
        if let code = dict["code"] as? Int, code != 0 {
            let msg = (dict["message"] as? String) ?? (dict["msg"] as? String) ?? ""
            throw LMError.business(code, msg)
        }
        var inner = (dict["data"] as? [String: Any]) ?? dict
        // 兑换接口若没回 accountId，用短信步骤拿到的补上（userId 请求头需要）
        if inner["accountId"] == nil, !accountId.isEmpty { inner["accountId"] = accountId }
        let data = try JSONSerialization.data(withJSONObject: inner)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return try adoptLoginResponse(json: json)
    }

    /// 一步到位：短信登录 → 换 JWT → 建立会话
    func loginWithSMSCode(phone: String, code: String) async throws -> LMSession {
        let r = try await fetchOuterToken(phone: phone, code: code)
        // 正常情况响应里一定带 data.appLoginVO.accountId；缺失时退回手机号当 identifier
        let ident = r.accountId.isEmpty ? phone : r.accountId
        return try await exchangeOuterToken(r.outerToken, accountId: ident)
    }

    // MARK: - 登录前请求（SHA256 签名）

    /// 登录前请求：`sign = SHA256(valueStr)`（无密钥，对应原生 sha256String: @0x106e6f370）
    private func preLoginRequest(path: String, host: String, body: [String: Any],
                                 accountId: String = "") async throws -> Any {
        guard let url = URL(string: host + path) else { throw LMError.transport("URL 非法：\(host + path)") }

        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = String(Int.random(in: 0...2_147_483_646))
        let signHeaders: [String: Any] = [
            "acceptLanguage": config.acceptLanguage,
            "channel": config.channel,
            "deviceId": config.deviceId,
            "deviceType": config.deviceType,
            "nonce": nonce,
            "source": config.source,
            "timestamp": ts,
            "version": config.version,
        ]
        let sign = LMSigner.signPreLogin(body: body, signHeaders: signHeaders)

        // HTTP header 集合与实测 Python 完全一致（注意 signHeaders 用的是驼峰 key 参与签名，
        // 实际发送的 header 名用小写 deviceid/devicetype）
        let headers: [String: String] = [
            "userid": accountId,
            "source": config.source,
            "x-api-signature-version": "2.0",
            "x-region": "CN",
            "x-canary-version": "",
            "devicetype": config.deviceType,
            "channel": config.channel,
            "cartype": "D19",
            "x-subversion": config.subversion,
            "version": config.version,
            "deviceid": config.deviceId,
            "acceptLanguage": config.acceptLanguage,
            "timestamp": ts,
            "nonce": nonce,
            "sign": sign,
            "Content-Type": "application/json",
            "User-Agent": config.userAgent,
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await send(method: "POST", url: url, headers: headers,
                              bodyData: bodyData, throwsOnBusinessError: false)
    }

    /// 递归查找第一个非空 key（对齐 Python find_key）
    static func findValue(_ obj: Any, key: String) -> Any? {
        if let d = obj as? [String: Any] {
            if let v = d[key], !(v is NSNull) {
                if let s = v as? String {
                    if !s.isEmpty { return v }
                } else {
                    return v
                }
            }
            for (_, v) in d {
                if let r = findValue(v, key: key) { return r }
            }
        } else if let a = obj as? [Any] {
            for v in a {
                if let r = findValue(v, key: key) { return r }
            }
        }
        return nil
    }

    // MARK: - 车辆 / 车况

    func loadVehicles() async throws -> [LMVehicle] {
        let any = try await request(method: "GET",
                                    path: LMEndpoints.Path.vehicleList,
                                    host: LMEndpoints.accountHost)
        let env = try decode(LMEnvelope<LMVehicleList>.self, from: any)
        let list = (env.data?.bindcars ?? []) + (env.data?.sharedcars ?? [])
        vehicles = list
        if selectedVehicle == nil { selectedVehicle = list.first }
        return list
    }

    func refreshStatus() async throws {
        guard let vin = selectedVehicle?.vin else { throw LMError.notLoggedIn }
        isBusy = true
        defer { isBusy = false }

        let body: [String: Any] = [
            "appVersion": config.version,
            "isMainApp": "1",
            "osType": config.deviceType,
            "vin": vin,
        ]
        let any = try await request(method: "POST",
                                    path: LMEndpoints.Path.signalQuery,
                                    body: body)
        let env = try decode(LMEnvelope<LMSignalData>.self, from: any)
        signals = env.data?.signalMap ?? [:]
        lastUpdate = Date()
    }

    func refreshMileage() async throws {
        guard let vin = selectedVehicle?.vin else { throw LMError.notLoggedIn }
        let any = try await request(method: "GET",
                                    path: LMEndpoints.Path.mileage,
                                    params: ["vin": vin])
        let env = try decode(LMEnvelope<LMMileageData>.self, from: any)
        mileage = env.data
    }

    func refreshAll() async {
        do {
            if vehicles.isEmpty { _ = try await loadVehicles() }
            try await refreshStatus()
            try await refreshMileage()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 车控

    /// 发送一条车控指令，返回 msgID
    func sendControl(_ actionKey: String) async throws -> String {
        guard let vin = selectedVehicle?.vin else { throw LMError.notLoggedIn }
        guard let cmd = LMEndpoints.commands[actionKey] else {
            throw LMError.business(-1, "未知动作：\(actionKey)")
        }
        guard let s = session else { throw LMError.notLoggedIn }

        // 服务端还在锁定期就别再打 —— 每打一次都在给「累计出错」计数
        if isControlLocked {
            throw LMError.business(70, "操作密码累计出错，请 \(controlLockRemaining) 秒后再试")
        }

        guard !s.opPassword.isEmpty else {
            throw LMError.business(-2, "未设置操作密码（车控需要 4~6 位操作密码）")
        }

        // oppwd：明文操作密码 → 用 accessToken 派生的 key/iv 现场 AES 加密
        let parts = try LMSigner.oppwdKeyIV(accessToken: s.accessToken)
        let oppwd = try LMSigner.encryptOppwd(accessToken: s.accessToken, password: s.opPassword)

        let stateJSON = try jsonString(cmd.state)
        let form: [String: String] = [
            "carvin": vin,
            "cmdid": String(cmd.cmdid),
            "oppwd": oppwd,
            "state": stateJSON,
        ]

        // 记体检单：把「真发出去的东西」原样留下来
        var trace = LMControlTrace(
            time: Date(),
            action: actionKey,
            cmdid: cmd.cmdid,
            passwordLength: s.opPassword.count,
            key: parts.key,
            iv: parts.iv,
            oppwd: oppwd,
            roundTrip: LMSigner.decryptOppwd(accessToken: s.accessToken, oppwd: oppwd),
            tokenHead: parts.tokenHead,
            tokenTail: parts.tokenTail,
            outcome: "已下发，等待结果…")
        lastControlTrace = trace

        do {
            let any = try await request(method: "POST",
                                        path: LMEndpoints.Path.remoteCtl,
                                        form: form)
            let env = try decode(LMEnvelope<String>.self, from: any)
            guard let msgID = env.data, !msgID.isEmpty else {
                trace.outcome = "业务错误 \(env.code ?? -1)：\(env.message ?? "下发失败")"
                lastControlTrace = trace
                throw LMError.business(env.code ?? -1, env.message ?? "下发失败")
            }
            trace.outcome = "已受理，msgID \(msgID)"
            lastControlTrace = trace
            return msgID
        } catch let e as LMError {
            if case .business(let code, let msg) = e {
                trace.outcome = "业务错误 \(code)：\(msg)"
                lastControlTrace = trace
            } else {
                trace.outcome = "失败：\(e.localizedDescription)"
                lastControlTrace = trace
            }
            noteBusinessError(e)
            throw e
        } catch {
            // 解码失败之类不是 LMError 的异常也记一笔，别让体检单停在「等待结果…」
            trace.outcome = "异常：\(error.localizedDescription)"
            lastControlTrace = trace
            throw error
        }
    }

    /// 业务码 70 = 操作密码累计出错 3 次以上，官方要求等 5 分钟。
    /// 记下来，UI 就能显示倒计时并且不再往枪口上撞。
    private func noteBusinessError(_ e: LMError) {
        if case .business(let code, _) = e, code == 70 {
            controlLockedUntil = Date().addingTimeInterval(300)
        }
    }

    /// 轮询车控结果：true = 成功
    func waitControl(msgID: String, timeout: TimeInterval = 25, interval: TimeInterval = 1.2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let any = try await request(method: "GET",
                                            path: LMEndpoints.Path.remoteCtlQuery,
                                            params: ["msgID": msgID])
                let env = try decode(LMEnvelope<Int>.self, from: any)
                if env.data == 1 { return true }
            } catch {
                // 轮询期间的偶发错误忽略，继续重试
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return false
    }

    /// 一步到位：下发 + 等待
    func control(_ actionKey: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let msgID = try await sendControl(actionKey)
            let ok = await waitControl(msgID: msgID)
            if ok { lastError = nil } else { lastError = "指令已下发，但未在超时内确认成功" }
            return ok
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func jsonString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - 常用车况字段
    //
    // signalMap 的 id → 含义是靠「多快照线性回归」反推出来的，不是猜的。
    // 判定依据：真 SOC 必须与所有续航信号严格成正比，且落在 0..100。
    //
    //   快照        100003   1204   3257   3260   1318
    //   har_appgw    32.9     33    236    190   1909
    //   har_refresh  36.6     37    262    211   1909
    //   15:30 抓包    41.4     41    298    239   1909
    //   实时         41.4     41    298    239   1909
    //
    //   3257 / 100003 = 7.16 ~ 7.20   → 满电 717 km（严格线性）
    //   3260 / 100003 = 5.77          → 满电 577 km（严格线性）
    //   1204 == round(100003) 三组全部吻合 → 1204 就是取整后的 SOC
    //
    // 结论：100003 / 1204 是 SOC(%)，3257 / 3260 都是「续航 km」（两套标准）。
    // ★ 以前 batteryPercent 读 3260，屏幕上才会出现「239%」这种数字。

    /// 车门锁状态：true = 已锁
    var isLocked: Bool? { signals["1298"]?.boolValue ?? signals["3262"]?.boolValue }

    /// 剩余电量 %（0...100）
    ///
    ///   100003 —— BMS 上报的 SOC，带 1 位小数，最准
    ///   1204   —— 同一个值的整数取整（实测 1204 == round(100003)）
    ///
    /// ⚠️ 千万不要再读 3260：那是「续航 km」，不是百分比。
    var batteryPercent: Double? {
        guard let raw = signals["100003"]?.doubleValue ?? signals["1204"]?.doubleValue else {
            return nil
        }
        return min(max(raw, 0), 100)
    }

    /// 剩余续航 km（主显示）
    var rangeKm: Double? { signals["3257"]?.doubleValue }

    /// 另一套标准下的剩余续航 km（3257 / 3260 严格成比例 ≈ 1.245，
    /// 一个标称一个动态，具体哪个对应官方 App 首页的「续航」以实测为准：
    /// 用户截图里官方 App 显示 238 km，同一时刻 3257=236、3260=190 → 主显示取 3257）
    var rangeAltKm: Double? { signals["3260"]?.doubleValue }

    /// 车内温度 ℃
    var interiorTemp: Double? { signals["1349"]?.doubleValue }

    /// 总里程 km：优先用实时信号 1318（与用户截图 1909 km 完全一致），
    /// 没有时退回 /drivingrecord/mileage 接口
    var odometerKm: Double? { signals["1318"]?.doubleValue ?? mileage?.totalmileage }
}
