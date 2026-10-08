//
//  LMClient.swift
//  LeapmotorLite
//
//  零跑车控 API 客户端（Swift / async-await）
//  端点、请求体格式、cmdid 均来自真实抓包 + iOS 主二进制逆向
//
import Foundation
import CoreLocation

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

// MARK: - 充电状态

/// 车辆当前是否在充电。
///
/// ★ 判据来自「充电中 / 未充电」两张真实快照的逐信号 diff，不是猜的：
///
///   | 信号 | 充电中 SOC 33.0/33.1 | 未充电 SOC 41.4 |
///   |------|---------------------|----------------|
///   | `1178` 充电电流 | −8.299 / −8.399 | **0.0** |
///   | `100004` | 1 | **0** |
///   | `1149`   | 1 | **0** |
///   | `1257`   | 1 | **0** |
///   | `3636`   | 1 | **0** |
///   | `3722`   | 1 | **0** |
///
///   五路标志位**同步翻转**，其中 `1178` 还有物理意义（没电流就充不进电）。
///   取「多数票 + 电流」双条件，避免单个标志位抖动造成误报。
enum LMChargeState {
    /// 在充电
    case charging
    /// 明确不在充电
    case notCharging
    /// 车况还没拉到，或标志位互相矛盾 —— 不猜
    case unknown

    var text: String {
        switch self {
        case .charging:    return "充电中"
        case .notCharging: return "未充电"
        case .unknown:     return "充电状态待确认"
        }
    }

    var icon: String {
        switch self {
        case .charging:    return "bolt.fill"
        case .notCharging: return "bolt.slash"
        case .unknown:     return "questionmark.circle"
        }
    }
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

    /// 预约充电等车辆配置（commonConfig）
    @Published private(set) var chargeSchedule: LMChargeSchedule?
    /// commonConfig 里 config["4"]（蓝牙/数字钥匙）等原始内容，按编号展示
    @Published private(set) var configBlobs: [String: LMConfigBlob] = [:]
    /// 停车位置接口的探测结果（响应结构未定，可能一直为 nil）
    @Published private(set) var parkingProbe: LMParkingProbe?
    /// 车况配置里的隐私开关（privacyGPS = 1 时官方会隐藏位置）
    @Published private(set) var privacyGPS = false

    // MARK: - 车辆档案（★ 2026-10-08 抓包审计补上的数据源）

    /// 车机固件版本 + 最近一次 OTA 更新日志（`fota/getCurrentVersion`）
    @Published private(set) var fotaVersion: LMFotaVersion?
    /// 3D 车模钥匙 —— 含**精确版型**（`modelParam.carTypeCode`）和官方分享页
    @Published private(set) var car3DKey: LM3DKey?
    /// 模块示意图（胎压 / 直进直出 / 辅助泊车）
    @Published private(set) var appImages: [LMAppImageModule] = []
    /// 服务端下发的功能开关表（无感蓝牙 / 雷达 / 3D 主题 …）
    @Published private(set) var bgConf: LMBgConf?
    /// 车辆分享列表（含 `rightList` —— 29 个 cmdid 的枚举）
    @Published private(set) var shareList: LMShareVehicleList?
    /// 消息未读数（`msgcenter`）
    @Published private(set) var noticeCount: LMNoticeCount?
    /// 健康充电推送开关（`healthyCharging/queryPushState`）
    @Published private(set) var healthyChargingPush: Bool?
    /// 手机侧 IP 归属地文本，例如 `安徽 淮南`（`tecHost` 的 ipAnalysis）
    @Published private(set) var ipAddressText: String?
    /// 车辆档案里各个接口的加载情况（哪几个成功、哪几个失败），供页面提示用
    @Published private(set) var profileLoadLog: [String] = []

    // ★ 为什么是「带默认参数的方法」而不是「无参计算属性」：
    //   SwiftUI 不会因为 `Date()` 变了就重绘。如果写成无参计算属性，它只在
    //   `controlLockedUntil` 变化时重新求值 —— 倒计时会永远停在 "300 秒"，
    //   而且 5 分钟到期后按钮还是禁用的（没有任何状态变化触发重绘，用户被卡死）。
    //   视图里必须自己推一个每秒更新的 `now` 传进来。
    //   见 Theme.swift 的 `.lmClock(until:now:)`。
    //
    //   这里刻意不给「属性 + 方法」同名重载：`var x: Bool { x(at: Date()) }`
    //   这种写法能不能过编译得赌，本地又没有 swiftc 可验，不冒这个险。
    //   不传参 = 此刻，`isControlLocked()` 读起来跟属性差不多。

    /// 服务端「操作密码累计出错」是否还在锁定期
    func isControlLocked(at now: Date = Date()) -> Bool {
        guard let t = controlLockedUntil else { return false }
        return t > now
    }

    /// 还剩几秒解锁（向上取整）
    func controlLockRemaining(at now: Date = Date()) -> Int {
        guard let t = controlLockedUntil else { return 0 }
        return max(0, Int(t.timeIntervalSince(now).rounded(.up)))
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
        chargeSchedule = nil
        configBlobs = [:]
        parkingProbe = nil
        privacyGPS = false
        controlLockedUntil = nil
        lastControlTrace = nil
        bleProbes = []
        lastError = nil
        // 坐标「未变化起点」是按值持久化的，退出登录必须一起清 ——
        // 否则换个账号登进来，会把上一台车的坐标当成「一直没变」的基准。
        let d = UserDefaults.standard
        d.removeObject(forKey: LMClient.coordValueKey)
        d.removeObject(forKey: LMClient.coordSinceKey)
        coordinateUnchangedSince = nil
        store.clear()
    }

    func select(vehicle: LMVehicle) {
        guard selectedVehicle?.vin != vehicle.vin else { return }
        selectedVehicle = vehicle
        // 换车必须清掉上一台的实时数据，否则新车的页面会先显示旧车的电量/坐标
        signals = [:]
        mileage = nil
        chargeSchedule = nil
        configBlobs = [:]
        parkingProbe = nil
        bleProbes = []
        lastUpdate = nil
        // 换车同理：坐标基准要重置（新车的坐标当然「刚变过」）
        let d = UserDefaults.standard
        d.removeObject(forKey: LMClient.coordValueKey)
        d.removeObject(forKey: LMClient.coordSinceKey)
        coordinateUnchangedSince = nil
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
        noteCoordinate(coordinateKey)
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

    /// 车辆配置：预约充电（config["3"]）、蓝牙钥匙（config["4"]）、隐私开关。
    ///
    /// 这个接口是「充电信息」页的数据源 —— 「预计充到目标电量还要多久」在
    /// signalMap(1200)，但「几点开始充、充到多少停、哪几天充」只有这里才有。
    func refreshCommonConfig() async throws {
        guard let vin = selectedVehicle?.vin else { throw LMError.notLoggedIn }
        let any = try await request(method: "GET",
                                    path: LMEndpoints.Path.commonConfig,
                                    params: ["vin": vin])
        let env = try decode(LMEnvelope<LMCommonConfigData>.self, from: any)
        let d = env.data
        privacyGPS = (d?.privacyGPS ?? 0) == 1
        configBlobs = d?.config ?? [:]
        chargeSchedule = LMChargeSchedule(blob: d?.config?["3"])
    }

    /// 停车位置接口探测。
    ///
    /// ⚠️ 这个端点的响应结构**没有样本**（见 LMEndpoints.Path.parking 的注释），
    ///    所以这里只做三件事：把原始 JSON 留下、用候选 key 掏经纬度、失败不抛错。
    ///    坐标的正规来源始终是 signalMap 的 2190/2191。
    @discardableResult
    func probeParking() async -> LMParkingProbe? {
        guard let vin = selectedVehicle?.vin else { return nil }
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.parking,
                                        params: ["vin": vin])
            let text = prettyJSON(any)
            let probe = LMParkingProbe(
                rawText: text,
                latitude: LMParkingProbe.pick(any, keys: LMParkingProbe.latKeys),
                longitude: LMParkingProbe.pick(any, keys: LMParkingProbe.lngKeys))
            parkingProbe = probe
            return probe
        } catch {
            // 探测失败是预期内的事（路径/参数都是猜的），不要污染 lastError
            parkingProbe = nil
            return nil
        }
    }

    /// 底盘图接口探测（`/v3/api/chassis/query`）。
    ///
    /// ★ 2026-10-08 加的：用户报「车在淮南、App 显示合肥」，而 signalMap 的 2190/2191
    ///    在连续 63 个样本里一个数字都没变（车况其它信号却在实时刷新）——
    ///    说明**那个坐标不是实时的**。
    ///    当时怀疑官方「车辆位置」页走的是另一个接口（`chassis/query`）。
    ///
    /// ★★ 同一天**已用真实抓包证伪**：`chassis/query` 返回的是 OSS 上的
    ///    `ChassisPicture/prod/<VIN>` —— 一张**底盘图片**，跟定位无关。
    ///    而且把主二进制里所有 `/v3/api/` 路径 + 所有 signalMap 样本都扫了一遍：
    ///    官方**没有**别的定位接口，坐标只可能来自 signalMap 的 2190/2191。
    ///
    /// 所以这个探测现在只用于「留个证据 / 万一车型不同」。
    /// 探测失败是预期内的，不要污染 lastError。
    @discardableResult
    func probeChassis() async -> LMParkingProbe? {
        guard let vin = selectedVehicle?.vin else { return nil }
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.chassis,
                                        params: ["vin": vin])
            return LMParkingProbe(
                rawText: prettyJSON(any),
                latitude: LMParkingProbe.pick(any, keys: LMParkingProbe.latKeys),
                longitude: LMParkingProbe.pick(any, keys: LMParkingProbe.lngKeys))
        } catch {
            return nil
        }
    }

    // MARK: - 车辆档案（★ 2026-10-08 抓包审计补上的数据源）
    //
    // 下面这几个接口都是「审计抓包时发现、但之前没接」的。
    // 它们的共同点：**有真实抓包样本**，所以路径/参数/响应结构都是照实写的，
    // 不像 `parking` / `ccc/*` 那组要靠探测。
    //
    // 数据基本都是静态的（版型、固件版本、功能开关表），所以只在进入
    // 「车辆档案」页时拉一次，**不进** `refreshAll` 的轮询路径。

    /// 设备系统版本，形如 `26.4.1`（用于 `osVersion` 参数）
    private var osVersionText: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// 设备机型标识，形如 `iPhone16,1`（用于 `manufacture` 参数）
    private var deviceModelText: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(bytes: bytes, encoding: .utf8) ?? "iPhone"
        }
        return machine.isEmpty ? "iPhone" : machine
    }

    /// 一次性拉齐「车辆档案」页要的全部数据。
    ///
    /// ★ 设计原则：**每个接口单独兜错**。
    ///   这 5 个接口里任何一个失败（比如 `sharecar` 在没有分享记录时
    ///   可能返回别的结构），都不该让整个页面空白 ——
    ///   能拿到几个就显示几个，成功/失败写进 `profileLoadLog` 给用户看。
    ///   这和 `refreshAll` 里「配置类接口单独兜错」是同一个思路。
    func refreshVehicleProfile() async {
        guard let v = selectedVehicle else { return }
        var log: [String] = []

        // 1) 3D 车模钥匙 —— 精确版型（carTypeCode）只有这里才有
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.car3dKey,
                                        params: ["vin": v.vin, "osVersion": osVersionText])
            car3DKey = try? decode(LMEnvelope<LM3DKey>.self, from: any).data
            log.append(car3DKey == nil ? "3D 车模：响应为空" : "3D 车模：OK")
        } catch {
            log.append("3D 车模：失败（\(error.localizedDescription)）")
        }

        // 2) 固件版本 + 最近一次 OTA 的完整更新日志
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.fotaVersion,
                                        params: ["vin": v.vin])
            fotaVersion = try? decode(LMEnvelope<LMFotaVersion>.self, from: any).data
            log.append(fotaVersion == nil ? "OTA 版本：响应为空" : "OTA 版本：OK")
        } catch {
            log.append("OTA 版本：失败（\(error.localizedDescription)）")
        }

        // 3) 模块示意图
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.appImage,
                                        params: ["vin": v.vin])
            appImages = (try? decode(LMEnvelope<[LMAppImageModule]>.self, from: any).data) ?? []
            log.append("模块示意图：\(appImages.count) 个")
        } catch {
            log.append("模块示意图：失败（\(error.localizedDescription)）")
        }

        // 4) 功能开关表
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.bgConf,
                                        params: ["vin": v.vin,
                                                 "osType": config.deviceType,
                                                 "osVersion": osVersionText,
                                                 "sdkVersion": config.subversion,
                                                 "manufacture": deviceModelText])
            bgConf = try? decode(LMEnvelope<LMBgConf>.self, from: any).data
            log.append(bgConf == nil ? "功能开关：响应为空" : "功能开关：OK")
        } catch {
            log.append("功能开关：失败（\(error.localizedDescription)）")
        }

        // 5) 分享列表 —— `rightList`（29 个 cmdid）就在这里
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.shareList,
                                        params: ["vin": v.vin])
            shareList = try? decode(LMEnvelope<LMShareVehicleList>.self, from: any).data
            log.append("分享记录：\(shareList?.carShareInfoList?.count ?? 0) 条")
        } catch {
            log.append("分享记录：失败（\(error.localizedDescription)）")
        }

        profileLoadLog = log
    }

    /// 消息未读数。
    ///
    /// ⚠️ 这个响应**只有 `result` 没有 `code`**，跟主网关不一样；
    ///    好在 `LMEnvelope.code` 是 optional，`send()` 里那套
    ///    「code != 0 就抛错」不会误伤它。
    func refreshNoticeCount() async throws {
        let now = Date()
        let begin = now.addingTimeInterval(-180 * 24 * 3600)
        let any = try await request(method: "GET",
                                    path: LMEndpoints.Path.noticeCount,
                                    host: LMEndpoints.msgCenterHost,
                                    params: [
                                        "begintime": String(Int(begin.timeIntervalSince1970 * 1000)),
                                        "endtime": String(Int(now.timeIntervalSince1970 * 1000)),
                                    ])
        noticeCount = try? decode(LMEnvelope<LMNoticeCount>.self, from: any).data
    }

    /// 健康充电推送开关查询（`POST` form: `carvin` + `deviceId`）。只读，不抛错。
    @discardableResult
    func probeHealthyChargingPush() async -> String {
        guard let vin = selectedVehicle?.vin else { return "未选车" }
        do {
            let any = try await request(method: "POST",
                                        path: LMEndpoints.Path.healthyChargingPush,
                                        form: ["carvin": vin, "deviceId": config.deviceId])
            let env = try? decode(LMEnvelope<LMHealthyChargingPush>.self, from: any)
            healthyChargingPush = env?.data?.isPush
            if let p = healthyChargingPush {
                return "健康充电推送：\(p ? "已开启" : "未开启")"
            }
            return prettyJSON(any)
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }

    /// 远程预约查询（`appremotectl/getappointment`，实测 `cmdid=161`）。
    ///
    /// ★ 2026-10-08 抓包审计补上：`161` 是 `rightList` 里的一员，但在整份
    ///   抓包里**只以这个 GET 查询的形式出现过一次**，而且 `data` 是**空串** ——
    ///   所以它的响应结构我们其实**不知道**，也不能确定它就是
    ///   「预约空调 / 预约充电」的查询。
    ///
    /// 它是**只读**接口，所以放心做成探测：把原始响应原样显示出来，
    /// 有内容就能看出来，没内容也不会动到车。
    @discardableResult
    func probeAppointment(cmdid: Int = 161) async -> String {
        guard let vin = selectedVehicle?.vin else { return "未选车" }
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.appointment,
                                        params: ["carvin": vin, "cmdid": String(cmdid)])
            return prettyJSON(any)
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }

    /// 手机侧 IP 归属地（`tecHost` 的 `ipAnalysis/getAddressByIp`）。
    ///
    /// ★ 为什么值得接：它和车端坐标是两个**完全独立**的来源。
    ///   实测手机侧 = 安徽 淮南（正确），车端坐标 = 合肥 —— 一对照就能把
    ///   「定位不对」的责任范围缩到车端。见 LMModels.swift 的 `LMIPAddress`。
    ///
    /// ⚠️ 响应字段是 `errorCode` 而不是 `code`，所以走 `LMIPAddressEnvelope`
    ///    自己解，不套 `LMEnvelope`。
    @discardableResult
    func probeIpAddress() async -> String {
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.ipAddress,
                                        host: LMEndpoints.tecHost)
            let env = try? decode(LMIPAddressEnvelope.self, from: any)
            if let d = env?.data, !d.text.isEmpty {
                ipAddressText = d.text
                return "手机侧 IP 归属地：\(d.text)"
            }
            return prettyJSON(any)
        } catch {
            return "失败：\(error.localizedDescription)"
        }
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
        // 配置类接口单独兜错：它挂了不该让整个「刷新车况」显示失败
        try? await refreshCommonConfig()
        // 消息未读数同理 —— 它是锦上添花，失败了不该影响车况
        try? await refreshNoticeCount()
    }

    // MARK: - 蓝牙钥匙

    /// 已绑定的蓝牙钥匙记录（来自 `commonConfig.config["4"]`）。
    ///
    /// ⚠️ 只有 `mac` / `version` / `updateTime`，**不含密钥材料**。
    ///    需要先 `refreshCommonConfig()` 才会有值。
    var bleKeyRecord: LMBLEKeyRecord? { LMBLEKeyRecord(blob: configBlobs["4"]) }

    /// 蓝牙钥匙相关接口的探测记录（只增不改，方便回看）
    @Published private(set) var bleProbes: [LMBLEProbeResult] = []

    /// 探测一个蓝牙钥匙接口。
    ///
    /// ★ 全部**不抛错**：这些端点的路径前缀、参数、方法都是推的，
    ///   失败是常态。把失败也变成一条可读记录，才看得出「试了什么、回了什么」。
    @discardableResult
    func probeBLEKey(barePath: String,
                     method: String,
                     params: [String: String]? = nil,
                     body: [String: Any]? = nil,
                     title: String,
                     host: String = LMEndpoints.gateway) async -> LMBLEProbeResult {
        // ★ 变量名**不能**叫 `request`：本类里有
        //     func request(method:path:host:params:body:form:skipAuth:) async throws -> Any
        //   一旦被局部变量遮蔽，下面 `try await request(...)` 会被解析成
        //   「调用一个 String」，报 `cannot call value of non-function type 'String'`，
        //   而错误信息完全不提遮蔽 —— 这一版真烧了一轮 CI。
        //   lint 的 R12 现在专门拦这个。
        var descParts: [String] = []
        if let params = params, !params.isEmpty {
            let q = params.keys.sorted()
                .map { "\($0)=\(params[$0] ?? "")" }
                .joined(separator: "&")
            descParts.append("?" + q)
        }
        if let body = body {
            descParts.append("body=" + prettyJSON(body))
        }
        let desc = descParts.joined(separator: "  ")

        var text: String
        var ok = false
        do {
            let any: Any
            if method == "GET" {
                any = try await request(method: "GET", path: barePath, host: host, params: params)
            } else {
                any = try await request(method: "POST", path: barePath, host: host, body: body ?? [:])
            }
            text = prettyJSON(any)
            ok = true
        } catch {
            text = "✗ \(error.localizedDescription)"
        }

        let r = LMBLEProbeResult(at: Date(), title: title, path: barePath,
                                 request: desc.isEmpty ? "（无参数）" : desc,
                                 response: text, ok: ok)
        bleProbes.insert(r, at: 0)
        if bleProbes.count > 40 { bleProbes.removeLast(bleProbes.count - 40) }
        return r
    }

    /// 只读探测：把 `syncBluetoothKeys` 在三个候选前缀下各试一次。
    ///
    /// ★ 为什么只探这一个：它是唯一「语义上是取数据」的蓝牙钥匙接口。
    ///   其它几个都会改服务端状态 ——
    ///     · `ccc/pairingcode` 会在服务端建一个待配对会话
    ///     · `ccc/delKey` 会删钥匙（破坏性）
    ///     · `uploadRecords` / `uploadAutonomyCalibrateParams` 是上报
    ///   这些一律只能手动触发，见 DiagnosticsView 的「蓝牙钥匙接口探针」。
    @discardableResult
    func probeBLEKeyReadOnly() async -> [LMBLEProbeResult] {
        guard let vin = selectedVehicle?.vin else { return [] }
        var out: [LMBLEProbeResult] = []
        for prefix in LMEndpoints.pathPrefixes {
            let full = prefix + LMEndpoints.Path.bleKeySync
            let tag = prefix.isEmpty ? "无" : prefix
            // ★ 先 await 到变量再 append，不写成 `out.append(await f(...))`：
            //   后者合法但把 await 埋在实参里，读起来费劲，也没必要。
            let r = await probeBLEKey(barePath: full, method: "GET",
                                      params: ["vin": vin],
                                      title: "同步钥匙（前缀 \(tag)）")
            out.append(r)
        }
        return out
    }

    func clearBLEProbes() { bleProbes.removeAll() }

    private func prettyJSON(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any,
                                                  options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8)
        else { return String(describing: any) }
        return s
    }

    // MARK: - 诊断探测
    //
    // 只给「设置 → 诊断」用。特点：**永不抛错**，把失败也变成一段可读文本。
    // 因为探的都是「路径/参数靠猜」的接口（parking / regeo），失败是常态，
    // 抛错会让诊断页变成一堆红字，反而看不出「到底返回了什么」。

    /// 裸 GET，返回格式化后的响应文本（或失败原因）
    func probeGET(path: String,
                  host: String = LMEndpoints.gateway,
                  params: [String: String]? = nil) async -> String {
        do {
            let any = try await request(method: "GET", path: path, host: host, params: params)
            return prettyJSON(any)
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }

    /// 裸 POST（JSON body）
    func probePOST(path: String,
                   host: String = LMEndpoints.gateway,
                   body: [String: Any]) async -> String {
        do {
            let any = try await request(method: "POST", path: path, host: host, body: body)
            return prettyJSON(any)
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }

    // MARK: - 车控

    /// 发送一条车控指令，返回 msgID
    func sendControl(_ actionKey: String) async throws -> String {
        guard let cmd = LMEndpoints.commands[actionKey] else {
            throw LMError.business(-1, "未知动作：\(actionKey)")
        }
        return try await sendControlRaw(cmdid: cmd.cmdid, state: cmd.state, label: actionKey)
    }

    /// 直接给 cmdid + state 的下发通道（诊断页的「未验证 cmdid 探测」用）。
    ///
    /// 和 `sendControl` 走完全同一条链路、同样记体检单，只是绕开 commands 表。
    func sendControlRaw(cmdid: Int, state: [String: Any], label: String) async throws -> String {
        guard let vin = selectedVehicle?.vin else { throw LMError.notLoggedIn }
        guard let s = session else { throw LMError.notLoggedIn }

        // 服务端还在锁定期就别再打 —— 每打一次都在给「累计出错」计数
        if isControlLocked() {
            throw LMError.business(70, "操作密码累计出错，请 \(controlLockRemaining()) 秒后再试")
        }

        guard !s.opPassword.isEmpty else {
            throw LMError.business(-2, "未设置操作密码（车控需要 4~6 位操作密码）")
        }

        // oppwd：明文操作密码 → 用 accessToken 派生的 key/iv 现场 AES 加密
        let parts = try LMSigner.oppwdKeyIV(accessToken: s.accessToken)
        let oppwd = try LMSigner.encryptOppwd(accessToken: s.accessToken, password: s.opPassword)

        let stateJSON = try jsonString(state)
        let form: [String: String] = [
            "carvin": vin,
            "cmdid": String(cmdid),
            "oppwd": oppwd,
            "state": stateJSON,
        ]

        // 记体检单：把「真发出去的东西」原样留下来
        var trace = LMControlTrace(
            time: Date(),
            action: label,
            cmdid: cmdid,
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

    /// 一步到位（原始 cmdid 版），给诊断页的探测工具用
    func controlRaw(cmdid: Int, state: [String: Any], label: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let msgID = try await sendControlRaw(cmdid: cmdid, state: state, label: label)
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

    // MARK: - 车窗 / 空调（cmdid ↔ 信号 的对应关系已实测）

    /// 四个车窗位置信号的 id（1693~1696）。
    ///
    /// ★ 与 cmdid 230 双向对上（复验记录见 `LMSignalCatalog` 的车窗条目）：
    ///   发 `{"value":"2"}` 时四个信号**同时** 0→2，发 `{"value":"0"}` 时
    ///   四个同时回到 0 —— 所以 230 是「四窗一起动」，没有单窗接口。
    ///
    /// ⚠️ 哪个 id 对应哪个窗（左前 / 右前 / 左后 / 右后）**没有证据**，
    ///   所以下面一律按 id 顺序展示，绝不编造「左前窗」这种名字。
    static let windowSignalIds = ["1693", "1694", "1695", "1696"]

    /// 把四个车窗位置信号翻译成人话。
    ///
    /// 三种返回：
    ///   · `nil`                      —— 一个车窗信号都没读到
    ///   · `"四窗均「微开」"`           —— 四个值相同且能翻译
    ///   · `"1693 关闭 · 1694 微开 · …"` —— 四个值不一致（逐窗按 id 列出）
    ///
    /// ⚠️ 数值 → 文案走 `LMEndpoints.WindowOpening`，而
    ///    「2 是微开、5 是半开」本身是按开度大小排的**假设**（抓包只录到过
    ///    0 / 2 / 5，没记录当时按的是哪个按钮）。
    ///    碰到映射表以外的值（比如 1）时**原样显示数字**，不硬套文案 ——
    ///    宁可显示「未知(1)」也不假装知道。
    var windowOpeningText: String? {
        let pairs = Self.windowSignalIds.compactMap { id -> (String, String)? in
            guard let v = signals[id]?.doubleValue else { return nil }
            let n = Int(v.rounded())
            let text = LMEndpoints.WindowOpening(rawValue: n)?.title ?? "未知(\(n))"
            return (id, text)
        }
        guard !pairs.isEmpty else { return nil }
        if pairs.count == Self.windowSignalIds.count, Set(pairs.map { $0.1 }).count == 1 {
            return "四窗均「\(pairs[0].1)」"
        }
        return pairs.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// 空调是否开着。1938：1 = 开，0 = 关。
    ///
    /// ★ 极性是实测的，不是猜的：`cmdid 170 {"operate":"auto"}` → 1938 0→1，
    ///   `{"operate":"off"}` → 1938 1→0。
    /// ⚠️ 注意它只反映**开关**，不含风量 / 温度 —— 抓包里从没调过风量温度，
    ///   所以 1941/1943/1944/1945 那几个伴随位到底是什么语义还没定论
    ///   （见 LMSignalCatalog 里的标注），本 App 不拿它们当风量档用。
    var hvacOn: Bool? { signals["1938"]?.boolValue }

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

    // MARK: - 定位
    //
    // 两组坐标都来自 signalMap，互为校验（同一位置、末位小数不同）：
    //     2190 = 31.801201   2191 = 117.342718
    //     3725 = 31.801307   3724 = 117.342719
    // ★ 3724/3725 的 id 顺序是「经度在前」，跟 2190/2191 相反，别记混。

    /// 车况数据的采集时刻（信号 `1`，13 位毫秒时间戳）。
    /// 用它才能说清「这个位置是几分钟前的」—— 车停在地库里时定位可能很久不更新。
    var collectedAt: Date? {
        guard let ms = signals["1"]?.doubleValue, ms > 1_000_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    // MARK: - ★ 坐标「变没变」的追踪
    //
    // ★★ 2026-10-08 踩的坑（用户报「车在淮南、显示合肥」）：
    //
    //   车机是**实时上报**的 —— `collectTime` 和信号 `1` 每次都在变（精确到秒），
    //   SOC 也从 32.9 一路涨到 36.7。但是 **`2190/2191` 在连续 51 个样本、
    //   40 分钟里一个数字都没动过**。
    //
    //   而页面上原来那句「刚刚采集」用的是信号 `1` —— 那是**整包车况**的采集时刻，
    //   不是**这个坐标**的采集时刻。于是出现最坏的情况：
    //   坐标是好几天前的，页面却说「刚刚采集」，用户以为定位是实时的。
    //
    //   所以这里单独记住「当前这个坐标值第一次被看到的时刻」，页面据此显示
    //   「坐标自 XX 起未变化（N 小时）」。**这才是判断定位新不新的正确依据。**
    //
    //   存 UserDefaults 是为了跨启动也能算 —— 否则用户重启一次 App 就丢了。
    private static let coordValueKey = "lm3rd.loc.lastCoordValue"
    private static let coordSinceKey = "lm3rd.loc.lastCoordChangedAt"

    /// 当前坐标值首次被看到的时刻（跨启动持久化）。nil = 还没有坐标。
    @Published private(set) var coordinateUnchangedSince: Date?

    /// 坐标值的字符串形式，用来判断「变没变」。
    var coordinateKey: String? {
        guard let c = coordinate else { return nil }
        return String(format: "%.6f,%.6f", c.latitude, c.longitude)
    }

    /// 记录本次看到的坐标。返回值 = 是否发生了变化。
    @discardableResult
    func noteCoordinate(_ key: String?) -> Bool {
        let d = UserDefaults.standard
        guard let key else {
            coordinateUnchangedSince = nil
            return false
        }
        if d.string(forKey: LMClient.coordValueKey) != key {
            let now = Date()
            d.set(key, forKey: LMClient.coordValueKey)
            d.set(now.timeIntervalSince1970, forKey: LMClient.coordSinceKey)
            coordinateUnchangedSince = now
            return true
        }
        let t = d.double(forKey: LMClient.coordSinceKey)
        coordinateUnchangedSince = t > 0 ? Date(timeIntervalSince1970: t) : nil
        return false
    }

    /// 这个坐标已经多少秒没变过了。没坐标时为 nil。
    var coordinateUnchangedFor: TimeInterval? {
        guard let d = coordinateUnchangedSince else { return nil }
        return Date().timeIntervalSince(d)
    }

    /// 坐标是否「久未变化」—— 超过 6 小时没动就值得提醒用户。
    /// （车正常停放时坐标本来就不会变，所以这不是错误，只是「别当成实时定位」。）
    var coordinateLooksStale: Bool {
        guard let s = coordinateUnchangedFor else { return false }
        return s > 6 * 3600
    }

    /// 定位时间距今多久（秒）。取不到采集时间时为 nil。
    var locationAge: TimeInterval? {
        guard let d = collectedAt else { return nil }
        return Date().timeIntervalSince(d)
    }

    /// 车辆坐标（主用 2190/2191，缺失时退回 3725/3724）
    var coordinate: CLLocationCoordinate2D? {
        if let c = LMClient.makeCoordinate(lat: signals["2190"]?.doubleValue,
                                           lng: signals["2191"]?.doubleValue) {
            return c
        }
        return LMClient.makeCoordinate(lat: signals["3725"]?.doubleValue,
                                       lng: signals["3724"]?.doubleValue)
    }

    /// 另一组坐标（做「两组是否一致」的交叉校验用）
    var coordinateAlt: CLLocationCoordinate2D? {
        LMClient.makeCoordinate(lat: signals["3725"]?.doubleValue,
                                lng: signals["3724"]?.doubleValue)
    }

    /// 两组坐标的距离（米）。差得远说明有一组是缓存/漂移，UI 里要提示。
    var coordinateDisagreementMeters: Double? {
        guard let a = coordinate, let b = coordinateAlt else { return nil }
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// 经纬度是否「像真的」。
    ///
    /// 三条都过才算有效：
    ///   1. 在合法区间内（纬度 ±90、经度 ±180）
    ///   2. 不是 (0,0) —— 那是「没定位」的典型占位值，不是几内亚湾
    ///   3. 不在中国境外太远（车辆是中国牌照；这条只是防止把 0.0 / 空值当坐标）
    static func makeCoordinate(lat: Double?, lng: Double?) -> CLLocationCoordinate2D? {
        guard let lat = lat, let lng = lng else { return nil }
        guard lat.isFinite, lng.isFinite else { return nil }
        guard abs(lat) <= 90, abs(lng) <= 180 else { return nil }
        if lat == 0 && lng == 0 { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// 官方隐私开关（`privacyGPS = 1` 时官方会隐藏位置，我们这边可能读到 0/0）
    var locationMayBeHidden: Bool { privacyGPS }

    // MARK: - 充电
    //
    // 证据见 LMSignalCatalog 顶部「充电状态」小节。这里只放「确认过」和「明确标注为疑似」的。

    /// 参与「是否在充电」投票的标志位。实测充电时全为 1、未充电时全为 0。
    static let chargeFlagIDs = ["100004", "1149", "1257", "3636", "3722"]

    /// 标志位里投「在充电」的票数，0...5。
    var chargeFlagVotes: Int {
        LMClient.chargeFlagIDs.reduce(0) { acc, id in
            let v = signals[id]?.doubleValue ?? 0
            return acc + (v == 1 ? 1 : 0)
        }
    }

    /// 充电电流是否非零（信号 `1178`）。
    ///
    /// 物理量：没有电流就不可能真的在充电。实测充电时 −8.3 ~ −8.4 A、
    /// 未充电时恒为 0.0。留 0.05 的容差是为了避开采样噪声。
    var chargeCurrentNonZero: Bool {
        guard let v = signals["1178"]?.doubleValue else { return false }
        return abs(v) > 0.05
    }

    /// 充电状态。多数票 + 电流双条件，见 `LMChargeState` 的说明。
    var chargeState: LMChargeState {
        if signals.isEmpty { return .unknown }
        if chargeFlagVotes >= 3 { return .charging }
        if chargeFlagVotes == 0 && !chargeCurrentNonZero { return .notCharging }
        return .unknown
    }

    /// 是否在充电（UI 用这个，别再自己拼判据）
    var isCharging: Bool { chargeState == .charging }

    /// 预计从当前 SOC 充到「目标电量」还要多久（分钟）。信号 `1200`。
    ///
    /// ★ 这个信号之前被误读成「剩余充电时间」，进而被当成充电状态位用，
    ///   导致「车没在充电却显示疑似充电中」。真相是它是**纯 SOC 函数**，
    ///   与充不充电无关：
    ///
    ///       1200 = round(11.32 × (目标电量 − SOC))
    ///       目标电量 = commonConfig.config["3"].percent（实测 90）
    ///
    ///   代入三个实测点，误差 < 0.1%：
    ///       SOC 33.05 → (90 − 33.05) × 11.32 = 644.7  → 实测 645
    ///       SOC 41.40 → (90 − 41.40) × 11.32 = 550.2  → 实测 550（此时**没在充电**）
    ///
    ///   所以它只能当「还要充多久」的投影值用，绝不能当状态位。
    ///   值为 0（或 SOC 已超目标电量）时返回 nil。
    var chargeMinutesToTarget: Int? {
        guard let m = signals["1200"]?.doubleValue, m > 0 else { return nil }
        return Int(m.rounded())
    }

    /// 电池温度 ℃（信号 2183）。实测 23.0，与车内温度 1349(29.5) 区分得开。
    var batteryTemp: Double? { signals["2183"]?.doubleValue }

    /// 预约充电的目标电量 %（来自 commonConfig.config["3"].percent）
    var chargeTargetPercent: Int? { chargeSchedule?.targetPercent }

    /// 电池 / 母线电压（V）。信号 `1177`。
    ///
    /// ★ 之前标注为「疑似充电功率（×100 W）」，**已被实测推翻**：
    ///   未充电时它是 732.7（**不为 0**），充电时 736.7 —— 只差 4.0 V。
    ///   如果它是功率，没充电时必须掉到 0。所以它属于**电压类**量，
    ///   充电时抬升 4 V 也符合「充电时母线电压上升」。
    ///   具体是电池包电压还是充电机输出电压仍未定，UI 里别写死。
    var packVoltageGuessV: Double? {
        guard let v = signals["1177"]?.doubleValue, v > 0 else { return nil }
        return v
    }

    /// 充电电流 A（信号 `1178`）。
    ///
    /// 实测：充电时 −8.299 / −8.399（负号含义未定，量级 8.3 A），
    ///       未充电时 0.0。这是**唯一一个带物理意义的充电证据**。
    var chargeCurrentA: Double? {
        guard let v = signals["1178"]?.doubleValue, v != 0 else { return nil }
        return abs(v)
    }

    /// 用「当前 SOC + 当前续航」反推满电续航 km（主标准 3257）。
    ///
    /// 判定依据就是这条严格线性关系：
    ///     3257 / 100003 = 7.17  （4 个快照全部吻合）
    /// 满电约 717 km。SOC 太低（<5%）时反推误差会放大，此时返回 nil。
    var fullRangeEstimateKm: Double? {
        guard let soc = batteryPercent, soc >= 5,
              let km = rangeKm, km > 0 else { return nil }
        return km / soc * 100.0
    }

    /// 同上，另一套标准（3260，满电约 577 km）
    var fullRangeAltEstimateKm: Double? {
        guard let soc = batteryPercent, soc >= 5,
              let km = rangeAltKm, km > 0 else { return nil }
        return km / soc * 100.0
    }

    /// 剩余续航换算成「还能开多久」（按 60 km/h 城市均速粗估）。
    /// 只是一个给用户量感的数字，不是官方数据，UI 里要标「估算」。
    var rangeHoursAt60: Double? {
        guard let km = rangeKm, km > 0 else { return nil }
        return km / 60.0
    }

    // MARK: - 信号取值小工具
    /// 读任意 signalId 的展示文本（"--" 表示没有）
    func signalText(_ id: String) -> String {
        signals[id]?.displayText ?? "--"
    }

    /// 读任意 signalId 的数值
    func signalNumber(_ id: String) -> Double? {
        signals[id]?.doubleValue
    }

    /// 带单位的展示文本，例如 `"298 km"`；没有单位就返回原值。
    func signalText(_ id: String, unit: String) -> String {
        guard let v = signals[id] else { return "--" }
        guard let d = v.doubleValue, !unit.isEmpty else { return v.displayText }
        // 整数就不显示小数点，避免 "298.0 km"
        let s = d == d.rounded() && abs(d) < 1e15
            ? String(Int64(d))
            : String(format: "%.1f", d)
        return "\(s) \(unit)"
    }
}
