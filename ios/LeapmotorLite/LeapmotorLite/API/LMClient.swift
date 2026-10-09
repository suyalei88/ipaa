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
    /// 设备标识。
    ///
    /// ★★ 2026-10-09 修（用户报「健康充电官方是开的、本 App 显示已关闭」）：
    ///   以前这里写的是「每次启动现生成一个 UUID」——
    ///     `var deviceId = "ios_" + UUID().uuidString...`
    ///   但 `healthyCharging/queryPushState` 这类接口是拿 `carvin + deviceId`
    ///   去查「**这台设备**的状态」的。deviceId 每次启动都变，服务端就永远
    ///   把本机当成一台从没绑定过的新设备，凡是有设备维度的状态一律回默认值
    ///   （false / 0）—— 健康充电开关正是这么被读成「已关闭」的。
    ///   现在改成：**首次生成后持久化**，同一台手机永远是同一个 deviceId。
    var deviceId: String        = LMConfig.stableDeviceId
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

    /// 稳定的设备标识 —— **首次生成后落盘，之后永远复用**。
    ///
    /// 为什么必须稳定（2026-10-09）：`healthyCharging/queryPushState`、
    /// 部分分享/绑定类接口都按 `deviceId` 区分设备。随机 UUID 会让服务端
    /// 每次都认成新设备，带设备维度的状态就全读成默认值（false / 0）——
    /// 用户报的「官方健康充电是开的、本 App 显示已关闭」正是这个表现。
    ///
    /// 首次默认取 `capturedDeviceId`（官方抓包里的那个，服务端认过），
    /// 而不是现造一个随机串 —— 新造的串在服务端是陌生设备，读不到真实状态。
    /// 存 `UserDefaults` 而不是 Keychain：这不是凭据，丢了也只是重新认一次设备，
    /// 不值得为它引入 Keychain 的复杂度。
    static let stableDeviceId: String = {
        let key = "lm.deviceId"
        if let saved = UserDefaults.standard.string(forKey: key),
           saved.hasPrefix("ios_"), saved.count > 8 {
            return saved
        }
        UserDefaults.standard.set(capturedDeviceId, forKey: key)
        return capturedDeviceId
    }()
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

    // MARK: - 登录态有效期
    //
    // ★ 2026-10-08 新增，专治「token 存活时间太短，官方 App 验证码登录一次就不退出」。
    //
    // 官方链路（实测 + 主二进制逆向）：
    //   accessToken   TTL ≈ 7199s  （2 小时）—— 响应字段 tokenExpireTime
    //   refreshToken  TTL ≈ 604799s（7 天）  —— 响应字段 refreshTokenExpireTime
    // 官方 App 靠 `com.tokenServer.refreshToken` 通知 + `_refreshTokenAlive` 倒计时
    // 在 accessToken 到期前主动打 `/token/v1/refresh`，所以「登录一次长期不掉线」。
    // 我们之前只把 refreshToken 存下来却**从不使用**，2 小时一到所有接口全部失败。
    //
    // ⚠️ 这两个字段必须写 Optional。`LMSession` 是 Codable 且已经写进 Keychain，
    //    Swift 合成的 `init(from:)` 对**非 Optional** 属性要求 key 必须存在
    //    （属性默认值不参与解码），加一个非 Optional 字段会让老会话解不出来 →
    //    用户一升级就被踢下线，正好和本次要修的问题相反。
    /// accessToken 的 TTL（秒），来自登录 / 续期响应的 `tokenExpireTime`
    var tokenExpireTime: Int?
    /// refreshToken 的 TTL（秒），来自续期响应的 `refreshTokenExpireTime`。
    ///
    /// ★ 2026-10-08 实测值 **604799**（= 7 天 - 1 秒），并且每次续期都会重新下发一个
    ///   新的 refreshToken —— 即 **refreshToken 是滑动续期的**。所以只要每 7 天内
    ///   成功续过一次，会话就能一直延长下去，这才是「登录一次再也不退出」的真正机制。
    var refreshTokenExpireTime: Int?
    /// 本次 accessToken 的落地时间，用来把 TTL 换算成绝对过期时刻
    var tokenIssuedAt: Date?

    var isValid: Bool { !accessToken.isEmpty && !signKeyHex.isEmpty }

    /// 从 JWT 的 `exp` 声明解出绝对过期时刻。
    ///
    /// 这是**比 tokenExpireTime 更硬的证据**：TTL 字段是服务端配额，而 `exp` 是
    /// 签发时写进 token 里的，服务端校验的就是它。有 exp 时以 exp 为准。
    var jwtExpiresAt: Date? {
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data),
              let obj = json as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// accessToken 的绝对过期时刻。优先信 JWT 的 exp，退化到 tokenExpireTime + 落地时间。
    /// nil = 两个来源都拿不到（例如手工粘贴了一个非 JWT 的 token）
    var tokenExpiresAt: Date? {
        if let e = jwtExpiresAt { return e }
        guard let ttl = tokenExpireTime, ttl > 0, let at = tokenIssuedAt else { return nil }
        return at.addingTimeInterval(TimeInterval(ttl))
    }

    /// 距过期还剩多少秒；负数 = 已过期，nil = 未知
    func tokenRemainingSeconds(at now: Date = Date()) -> Int? {
        guard let exp = tokenExpiresAt else { return nil }
        return Int(exp.timeIntervalSince(now).rounded())
    }

    /// 是否该续期了。
    ///
    /// `skew` 默认 300 秒：提前 5 分钟续，避免「请求在路上时刚好过期」。
    /// TTL 未知（手工粘贴 token 建的会话）时返回 false —— 那种情况走「401 再续」的被动路径。
    func needsRefresh(at now: Date = Date(), skew: TimeInterval = 300) -> Bool {
        guard let exp = tokenExpiresAt else { return false }
        return exp.timeIntervalSince(now) <= skew
    }
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
/// ## 判据的两次修订（第二修订是用户实测逼出来的）
///
/// **第一版（错）**：拿 5 路标志位投票，`≥ 3` 就判「充电中」。
///   依据是「充电中 / 未充电」两张快照的逐信号 diff：
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
///   ⚠️ **样本只有「熄火停放」和「插枪充电」两种工况** —— 没有「车辆通电 /
///   哨兵模式」这一组对照，所以把「高压系统在工作」误读成了「在充电」。
///
/// **第二版（2026-10-09，用户实测后改）**：用户报「车辆通电使用、开启哨兵模式
///   时会错误显示充电中」→ 那 5 位其实是**高压系统激活**标志（车辆 READY /
///   哨兵 / 充电都会点亮）。所以判据换成**充电电流 `1178` 单条硬门槛**：
///   没有电流就一定没有电进电池，这是唯一带物理意义的量。
///
///   标志位降级为 `LMClient.highVoltageActive`，只用来提示「高压系统在工作」。
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

    // MARK: - 驻车照片（★ 2026-10-09 用户要求「找出驻车照片」）

    /// 驻车照片（哨兵照）。`nil` = 还没取 / 取失败。
    /// 来源与证据见 `LMParkingSnap` 的注释。
    @Published private(set) var parkingSnap: LMParkingSnap?
    /// 正在拉取（给 UI 转菊花）
    @Published private(set) var parkingSnapLoading = false
    /// 上一次拉取的失败原因（成功时为 nil）
    @Published private(set) var parkingSnapError: String?
    /// 已经下载好的图片数据（内存缓存，避免每次进页都重新下）
    @Published private(set) var parkingSnapImageData: Data?

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
    /// 健康充电推送开关（`healthyCharging/queryPushState` → `data.isPush`）
    ///
    /// ★ 2026-10-09 补：这个字段的**语义要说清**。
    ///   `queryPushState` 是全网抓包里**唯一**跟健康充电有关的读接口
    ///   （把 411 个响应键全扫过一遍，只有它带 `isPush`）。
    ///   但官方 App 自己调的也是 `{"isPush":false}`（`har_appgw.har` #29 / #161），
    ///   所以：**官方显示「开启」而这里读到 false，说明 `isPush` 不一定是
    ///   那个功能开关本身**（更像「充电相关推送提醒」）。
    ///   在没有新抓包之前，本 App 的做法是：**照实显示读到什么**，
    ///   并把「读取时间 / 原始值 / 出错原因」一起显示出来，
    ///   让用户能判断是「真关闭」还是「读不到」。
    @Published private(set) var healthyChargingPush: Bool?
    /// 健康充电状态是否正在读取（UI 用它做「读取中…」反馈）
    @Published private(set) var healthyChargingLoading = false
    /// 健康充电读取失败的原因（nil = 没出错）。
    /// ★ 以前这里没有这个属性 —— `refreshHealthyCharging()` 把异常整个吞掉只 return nil，
    ///   界面上什么都看不出来，用户点「读取开关状态」就得到一句「没反应」。
    @Published private(set) var healthyChargingError: String?
    /// 上一次**成功**读到健康充电状态的时间（用来区分「刚读的」和「很久以前的」）
    @Published private(set) var healthyChargingReadAt: Date?
    /// 手机侧 IP 归属地文本，例如 `安徽 淮南`（`tecHost` 的 ipAnalysis）
    @Published private(set) var ipAddressText: String?
    /// 手机侧 IP 归属地的结构化值（省 / 市）。
    ///
    /// ★ 2026-10-08 加：用户报「官方 App 定位到车停的位置淮南，本 App 显示合肥」。
    ///   实测结论 —— **官方「车辆位置」用的就是这个 IP 归属地**：
    ///     · 抓包 `GET https://apptec.leapmotor.cn/ipAnalysis/getAddressByIp`
    ///       → `{"country":"中国","province":"安徽","city":"淮南"}`，与官方界面完全一致；
    ///     · 而车机 signalMap 的 `2190/2191` 在 **60 个样本里一个数字都没变**
    ///       （31.801201 / 117.342718，指向合肥）—— 那是**静态值**，不是实时位置。
    ///   所以「车辆位置」以 IP 归属地为准，车机坐标降级为附注。
    @Published private(set) var ipAddress: LMIPAddress?
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
        tokenRefreshLog = []
        lastTokenRefresh = nil
        lastTokenRefreshOK = nil
    }

    // MARK: - 登录态续期（refreshToken）
    //
    // ★ 2026-10-08 新增，专治「token 存活时间太短 / 官方 App 登录一次就不退出」。
    //
    // 之前的状态：`refreshToken` 从登录响应里存进了 Keychain，但**全仓零调用**，
    // `LMEndpoints.Path.refreshToken` 定义了也没人用 → accessToken 2 小时一到，
    // 所有接口全挂，用户被迫重新登录。官方 App 靠 refreshToken 续期，
    // 所以「验证码登录一次就一直不退出」。
    //
    // 官方实现（逆向自主二进制，本地无抓包样本 —— 三份 HAR 里都没有续期请求）：
    //   · 主动续期：ivar `_tokenAliveSec`(double 倒计时) + `_tokenRefreshedFlagTime`
    //     + `_refreshTokenQueue`(串行队列，防并发重复续期)
    //     + 通知名 `com.tokenServer.login` / `com.tokenServer.refreshToken`
    //   · 请求：函数 @0x106E8115C
    //       add x3, x3, #0x9c0  ; @"/token/v1/refresh"
    //       add x3, x3, #0x8c0  ; @"refreshToken"  → setObject:forKey:（body 键）
    //       add x4, x4, #0x960  ; @"POST_Json"     → JSON POST，超时 20s
    //   · 响应：函数 @0x106E82B34 每个字段都同时认扁平键与点路径：
    //       accessToken/data.accessToken、signR2/data.signParam.r2、
    //       encryptR2/data.encryptParam.r2、tokenExpireTime/data.tokenExpireTime …
    //   · 签名：**HMAC_SHA256(valueStr, 旧 signKey)**，不是无密钥 SHA256。
    //     ★★ 2026-10-08 用真实凭据实测定论（这是本轮唯一必须真机/真请求才能定的点）：
    //        sha256  → {"code":302002002,"message":"签名信息校验失败"}
    //        hmac    → {"code":0,"message":"SUCCESS", data:{accessToken, refreshToken,
    //                    tokenExpireTime:7200, refreshTokenExpireTime:604799,
    //                    signParam:{r2,r3}, encryptParam:{…}}}
    //     并且**必须带 token 头**（去掉 token 头后 hmac 也会退化成 302002002），
    //     所以它属于「登录后接口」，用 `buildHeaders` 那套（signKey + token + carvin/cartype）。
    //
    //   · 续期响应实测会**同时返回新的 refreshToken**，`refreshTokenExpireTime=604799`（7 天）
    //     —— 即 refreshToken 是**滑动续期**的：只要每 7 天内续过一次，就能一直不掉线，
    //     这就是官方「验证码登录一次再也不退出」的机制本体。
    //
    // 两条触发路径（缺一不可）：
    //   ① 主动：token 剩余寿命 < 300s 时，在 `request(...)` 发请求前先续（见 request 内）
    //   ② 被动：服务端仍然判 token 失效（401 / token 类业务码）时，续一次再重放原请求

    /// 续期过程日志（诊断页展示，只留最近 30 条）
    @Published private(set) var tokenRefreshLog: [String] = []
    /// 最近一次续期时间
    @Published private(set) var lastTokenRefresh: Date?
    /// 最近一次续期是否成功（nil = 还没试过）
    @Published private(set) var lastTokenRefreshOK: Bool?

    /// 续期任务去重：多个请求同时发现 token 过期时，只打一次接口
    private var refreshTask: Task<LMSession, Error>?

    private func logRefresh(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        tokenRefreshLog.append("[\(f.string(from: Date()))] \(line)")
        if tokenRefreshLog.count > 30 {
            tokenRefreshLog.removeFirst(tokenRefreshLog.count - 30)
        }
    }

    /// 有没有可用于续期的 refreshToken
    var canRefresh: Bool {
        guard let s = session else { return false }
        return !s.refreshToken.isEmpty
    }

    /// 主动续期：token 快过期 / 已过期时调一次 `/token/v1/refresh`。
    ///
    /// 刻意不抛错 —— 调用方是「顺手续一下」的请求路径，续期失败不该让业务请求也失败。
    /// - Returns: true = 当前持有可用 token（含「本来就没到期，无需续」）
    @discardableResult
    func refreshSessionIfNeeded(force: Bool = false) async -> Bool {
        guard let s = session, !s.refreshToken.isEmpty else { return false }
        if !force, !s.needsRefresh() { return true }
        do {
            _ = try await refreshAccessToken()
            return true
        } catch {
            lastTokenRefresh = Date()
            lastTokenRefreshOK = false
            logRefresh("✗ 续期失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 真打续期接口。并发调用复用同一个 Task（对齐官方的 `_refreshTokenQueue` 串行队列）。
    @discardableResult
    func refreshAccessToken() async throws -> LMSession {
        if let t = refreshTask { return try await t.value }
        guard let s = session, !s.refreshToken.isEmpty else {
            throw LMError.notLoggedIn
        }
        let rt = s.refreshToken
        let task = Task<LMSession, Error> { [weak self] in
            guard let self else { throw LMError.notLoggedIn }
            return try await self.performRefresh(refreshToken: rt)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(refreshToken rt: String) async throws -> LMSession {
        logRefresh("→ POST \(LMEndpoints.Path.refreshToken)  body={\"refreshToken\":\"\(rt.prefix(10))…\"}")
        // ★ 必须走 HMAC 签名（用当前 signKey）+ 带 token 头 —— 实测无密钥 SHA256 会被判
        //   「签名信息校验失败」。所以不能复用登录那条 `preLoginRequest`。
        //   这里绕开 `request(...)` 直接发，否则会撞上 request 里的续期钩子无限递归。
        let any = try await signedPost(path: LMEndpoints.Path.refreshToken,
                                       host: LMEndpoints.accountHost,
                                       body: ["refreshToken": rt])
        guard let dict = any as? [String: Any] else {
            throw LMError.decoding("续期响应不是 JSON 对象")
        }
        if let code = dict["code"] as? Int, code != 0 {
            let msg = (dict["message"] as? String) ?? (dict["msg"] as? String) ?? ""
            throw LMError.business(code, msg)
        }
        var inner = (dict["data"] as? [String: Any]) ?? dict
        // 续期响应常常不带 accountId / nickname —— 补上旧值，
        // 否则 adoptLoginResponse 会把它们清成空串（userId 请求头就没了）
        if inner["accountId"] == nil, let old = session?.accountId, !old.isEmpty {
            inner["accountId"] = old
        }
        if inner["nickname"] == nil, let old = session?.nickname, !old.isEmpty {
            inner["nickname"] = old
        }
        let data = try JSONSerialization.data(withJSONObject: inner)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let newSession = try adoptLoginResponse(json: json)
        lastTokenRefresh = Date()
        lastTokenRefreshOK = true
        let rem = newSession.tokenRemainingSeconds().map { "\($0 / 60) 分钟" } ?? "未知"
        logRefresh("✓ 续期成功，新 token 有效期 \(rem)")
        return newSession
    }

    /// 判断一个错误是否「像 token 失效」。
    ///
    /// 官方的失效码表是 ivar `tokenInvalidErrorCodes`，但它的**取值在二进制里查不到**
    /// （只有符号名，没有常量数组），所以这里采取「宁可多试一次」的策略：
    /// 401/403，或业务码/文案带 token 语义，都当成失效。
    /// 多续一次最多浪费一个请求；漏判则会让用户被迫重登 —— 代价不对等。
    static func looksLikeTokenExpired(_ error: Error) -> Bool {
        if let e = error as? LMError {
            switch e {
            case .http(let code, _):
                return code == 401 || code == 403
            case .business(let code, let msg):
                if code == 100101 { return true }   // 二进制里紧挨「Token Refresh」出现的码
                let m = msg.lowercased()
                for kw in ["token", "登录", "过期", "expired", "invalid", "unauthorized", "鉴权", "认证"] {
                    if m.contains(kw) { return true }
                }
                return false
            default:
                return false
            }
        }
        return false
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

        // 4) 主动续期：token 剩余寿命不足就先换掉，别等它真过期被服务端打回来。
        //    ⚠️ 不能在这里 buildHeaders —— 续期会换 accessToken，headers 必须每次重算。
        if !skipAuth, let s = session, !s.refreshToken.isEmpty, s.needsRefresh() {
            await refreshSessionIfNeeded()
        }

        do {
            return try await sendWithFreshHeaders(method: method, url: url, signBody: signBody,
                                                  skipAuth: skipAuth, contentType: contentType,
                                                  bodyData: bodyData)
        } catch {
            // 5) 被动续期：主动判断漏了（TTL 未知 / 服务端提前失效）时兜底 ——
            //    续一次，然后把原请求**原样重放一次**。只重放一次，避免死循环。
            guard !skipAuth, canRefresh, LMClient.looksLikeTokenExpired(error) else { throw error }
            logRefresh("⚠ 命中 token 失效信号，续期后重放：\(error.localizedDescription)")
            guard await refreshSessionIfNeeded(force: true) else { throw error }
            return try await sendWithFreshHeaders(method: method, url: url, signBody: signBody,
                                                  skipAuth: skipAuth, contentType: contentType,
                                                  bodyData: bodyData)
        }
    }

    /// 用「当前最新的 session」现算请求头再发一次。
    ///
    /// 单独抽出来是因为续期会替换 accessToken / signKey，而 headers 里两者都参与，
    /// 提前算好再续期就会拿旧 token 发出去。
    private func sendWithFreshHeaders(method: String, url: URL, signBody: [String: Any],
                                      skipAuth: Bool, contentType: String,
                                      bodyData: Data?) async throws -> Any {
        let headers = buildHeaders(signBody: signBody, skipAuth: skipAuth, contentType: contentType)
        return try await send(method: method, url: url, headers: headers,
                              bodyData: bodyData, throwsOnBusinessError: true)
    }

    /// 带 HMAC 签名的 JSON POST（`buildHeaders` 那套：signKey + token + carvin/cartype）。
    ///
    /// 与 `request(...)` 的区别：**不挂主动/被动续期钩子** —— 续期接口自己不能用它，
    /// 否则 `request` 里发现 token 快过期就会去调续期，续期又走 `request`，直接递归。
    private func signedPost(path: String, host: String, body: [String: Any]) async throws -> Any {
        guard let url = URL(string: host + path) else {
            throw LMError.transport("URL 非法：\(host + path)")
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let headers = buildHeaders(signBody: body, skipAuth: false, contentType: "application/json")
        return try await send(method: "POST", url: url, headers: headers,
                              bodyData: bodyData, throwsOnBusinessError: false)
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

        // ★ 续期响应与登录响应**同构，但可能更扁平**。
        //   原生登录 SDK 对每个字段都同时尝试「点路径」和「扁平键」，见主二进制
        //   0x106E82B34 起的字符串表（同一函数里成对出现）：
        //       data.signParam.r2 / signR2      data.signParam.r3 / signR3
        //       data.encryptParam.r2 / encryptR2  data.encryptParam.r3 / encryptR3
        //       data.accessToken / accessToken  ... tokenExpireTime / data.tokenExpireTime
        //   所以这里两条路都要认，否则续期回来的扁平结构会被判成「派生失败」。
        let sp: Any? = dict["signParam"]
        let ep: Any? = dict["encryptParam"]

        func rValue(_ nested: Any?, _ key: String, _ flatKey: String) -> String? {
            if let d = nested as? [String: Any], let v = d[key] as? String, !v.isEmpty { return v }
            if let d = nested as? [String: String], let v = d[key], !v.isEmpty { return v }
            if let v = dict[flatKey] as? String, !v.isEmpty { return v }
            return nil
        }

        var signKeyHex = ""
        var encryptKeyHex = ""
        if let r2 = rValue(sp, "r2", "signR2"), let r3 = rValue(sp, "r3", "signR3") {
            signKeyHex = LMSigner.deriveKey(accessToken: token, r2: r2, r3: r3)?.hexUppercased ?? ""
        }
        if let r2 = rValue(ep, "r2", "encryptR2"), let r3 = rValue(ep, "r3", "encryptR3") {
            encryptKeyHex = LMSigner.deriveKey(accessToken: token, r2: r2, r3: r3)?.hexUppercased ?? ""
        }
        guard !signKeyHex.isEmpty else {
            throw LMError.decoding("无法派生 signKey（响应里既没有 signParam.r2/r3，也没有 signR2/signR3）")
        }

        // accountId / nickname / refreshToken 在续期响应里可能缺省 → 沿用旧会话的值
        let newAccountId = LMClient.stringValue(dict["accountId"]) ?? session?.accountId ?? ""
        let newNickname = (dict["nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? session?.nickname ?? ""
        let newRefreshToken = (dict["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? session?.refreshToken ?? ""

        // tokenExpireTime 可能是数字也可能是字符串；缺失时沿用旧值
        let ttl = LMClient.intValue(dict["tokenExpireTime"]) ?? session?.tokenExpireTime
        // 续期响应实测会带 refreshTokenExpireTime（604799 ≈ 7 天）
        let rtTtl = LMClient.intValue(dict["refreshTokenExpireTime"]) ?? session?.refreshTokenExpireTime

        let s = LMSession(
            accessToken: token,
            refreshToken: newRefreshToken,
            signKeyHex: signKeyHex,
            encryptKeyHex: encryptKeyHex,
            userId: newAccountId,
            accountId: newAccountId,
            nickname: newNickname,
            opPassword: session?.opPassword ?? "",
            tokenExpireTime: ttl,
            refreshTokenExpireTime: rtTtl,
            tokenIssuedAt: Date()
        )
        adopt(session: s)
        return s
    }

    /// 把 JSON 里可能是 Int / Double / String 的数值统一成 Int
    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int:            return i
        case let d as Double:         return Int(d)
        case let n as NSNumber:       return n.intValue
        case let s as String:         return Int(s)
        default:                      return nil
        }
    }

    /// 把 JSON 里可能是数字 / 字符串的标识统一成 String（accountId 有时是 123 有时是 "123"）
    static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String:         return s.isEmpty ? nil : s
        case let i as Int:            return String(i)
        case let d as Double:         return String(Int(d))
        case let n as NSNumber:       return n.stringValue
        default:                      return nil
        }
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
    /// ★★ 2026-10-09 **更正**：以前这里写的是「一张底盘图片，跟定位无关」——
    ///    **错的**。它确实是 `ChassisPicture/prod/<VIN>`，但那张图是
    ///    **地下停车场俯视哨兵照**（能看到车位号 / 通道 / 周边环境），
    ///    就是官方「驻车拍照」那张图。见 `LMParkingSnap` 的注释与
    ///    `refreshParkingSnap()`。
    ///    「跟定位无关」这半句仍然成立：它不返回经纬度，坐标只来自 signalMap。
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

    // MARK: - 驻车照片（`chassis/query`）

    /// 拉取驻车照片的直链 + 上传时间。
    ///
    /// 只做「拿 fileUrl」这一步，**不下载图片** —— 下载留给 UI 层，
    /// 因为 `LMClient` 只依赖 Foundation，不想为了一个 UIImage 引入 UIKit。
    ///
    /// ⚠️ 两个已知限制（如实标注，不假装能做）：
    ///   1. 车端**没上传过**驻车照片时，`fileUrl` 可能为空 —— 这时返回 nil，
    ///      UI 要显示「车端还没有驻车照片」，而不是空图；
    ///   2. OSS 直链带 `Expires` 签名，过期后必须重新调接口换一条新链，
    ///      所以这里**每次都是现拉**，不做长期缓存。
    @discardableResult
    func refreshParkingSnap() async -> LMParkingSnap? {
        guard let vin = selectedVehicle?.vin else { return nil }
        parkingSnapLoading = true
        parkingSnapError = nil
        defer { parkingSnapLoading = false }
        do {
            let any = try await request(method: "GET",
                                        path: LMEndpoints.Path.chassis,
                                        params: ["vin": vin])
            let env = try? decode(LMEnvelope<LMParkingSnapData>.self, from: any)
            let snap = LMParkingSnap(fileUrl: env?.data?.fileUrl,
                                     uploadTimeMillis: env?.data?.uploadTime)
            if let snap {
                // 直链变了说明换了新图，旧的内存缓存要丢掉
                if parkingSnap?.fileUrl != snap.fileUrl { parkingSnapImageData = nil }
                parkingSnap = snap
            } else {
                parkingSnap = nil
                parkingSnapError = "车端没有可用的驻车照片（接口没返回 fileUrl）"
            }
            return parkingSnap
        } catch {
            parkingSnap = nil
            parkingSnapError = error.localizedDescription
            return nil
        }
    }

    /// 下载驻车照片本体（带内存缓存）。`fileUrl` 为 nil 时直接返回 nil。
    ///
    /// ★★ 2026-10-09 修「获取驻车照片报下载失败」：
    ///   车端返回的 `fileUrl` **是明文 `http://`** —— 实测报文（`har_appgw.har` #42）：
    ///     `http://lp-carnet.oss-cn-hangzhou.aliyuncs.com/ChassisPicture/prod/<VIN>?Expires=…&Signature=…`
    ///   而本 App 的 `NSAllowsArbitraryLoads = false`，ATS 会**直接掐掉**这条请求，
    ///   用户看到的就是「图片下载失败」。两处一起修：
    ///     ① `Info.plist` 给 `aliyuncs.com` 开一条窄口径例外（只放开这一个域的明文 HTTP）；
    ///     ② 这里**优先把 scheme 换成 https** 再试 —— 阿里云 OSS 支持 HTTPS，
    ///        而且 OSS 的签名覆盖的是 `VERB / Content-MD5 / Content-Type / Expires /
    ///        CanonicalizedResource`，**scheme 不参与签名**，所以换 https 不会让签名失效。
    ///        换 https 失败再回退原样（此时由 ① 的例外兜底）。
    @discardableResult
    func downloadParkingSnapImage() async -> Data? {
        if let d = parkingSnapImageData { return d }

        // ★ 2026-10-09 修：原来写的是
        //     `parkingSnap?.fileUrl.flatMap(URL.init(string:))`
        //   —— **编译不过**。可选链 `?.` 会把后面的 `.fileUrl.flatMap` 整段纳入链内，
        //   链内的基类型是**已解包**的 `LMParkingSnap`，于是 `fileUrl` 是非可选 `String`，
        //   这个 `.flatMap` 被解析成 `Sequence.flatMap`（要求 `(Character) -> SegmentOfResult`），
        //   而不是 `Optional.flatMap`（要求 `(String) -> URL?`）。CI 报的就是这个：
        //     cannot convert '(__shared String) -> URL?' to '(String.Element) throws -> URL?'
        //   正确写法：先解出 `fileUrl`（这一步可选链的基类型是 `LMParkingSnap?`，
        //   所以结果是 `String?`），再用 `URL(string:)` 构造 —— 语义等价，且没有歧义。
        guard let fileUrl = parkingSnap?.fileUrl, !fileUrl.isEmpty else {
            parkingSnapError = "没有可下载的图片地址"
            return nil
        }
        guard let url = Self.parseSnapURL(fileUrl) else {
            parkingSnapError = "图片地址不合法，无法解析：\(fileUrl.prefix(120))"
            return nil
        }

        // 候选顺序：https 版优先，失败再回退原样（http 由 ATS 例外兜底）
        var candidates: [URL] = []
        if url.scheme?.lowercased() == "http",
           let https = Self.switchingScheme(url, to: "https") {
            candidates.append(https)
        }
        candidates.append(url)

        var lastError: Error?
        for candidate in candidates {
            do {
                var req = URLRequest(url: candidate)
                req.timeoutInterval = 20
                // OSS 直链不需要 Cookie / 缓存协商
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    lastError = LMError.transport("HTTP \(http.statusCode)（\(candidate.scheme ?? "?")）")
                    continue
                }
                guard !data.isEmpty else {
                    lastError = LMError.transport("服务器返回 0 字节")
                    continue
                }
                parkingSnapImageData = data
                parkingSnapError = nil
                return data
            } catch {
                lastError = error
            }
        }

        let reason = lastError?.localizedDescription ?? "未知错误"
        parkingSnapError = "图片下载失败（\(candidates.count) 个地址都试过）：\(reason)"
        return nil
    }

    /// 解析驻车照片直链。
    ///
    /// `fileUrl` 里的 `Signature` 是**已百分号编码**的（如 `%2F` `%3D`），
    /// `URL(string:)` 能直接吃。但 OSS 偶尔会回未编码的串（含 `+` / 空格 / 中文），
    /// 那种情况下 `URL(string:)` 会返回 nil —— 这时补一次百分号编码再试。
    static func parseSnapURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: trimmed) { return u }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: ":/?&=#[]@!$'()*,;+%~")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              let u = URL(string: encoded) else { return nil }
        return u
    }

    /// 换 scheme（`http` → `https`），host / path / query **原样保留**。
    ///
    /// ⚠️ 这里刻意**不用 `URLComponents`**：本仓库的 lint R1 把
    /// `URLComponents` 列为高危写法（用它 + `queryItems` 重建 query 时
    /// `+` 不会被转义，会踩到「1019 参数不能为空」）。
    /// 而且 OSS 的 `Signature` 是**已百分号编码**的，走 `URLComponents` 重建
    /// 反而可能把 `%2F` 再编码成 `%252F` 让签名失效。
    /// 所以只做最朴素的「前缀替换」，其余一个字符都不动。
    static func switchingScheme(_ url: URL, to scheme: String) -> URL? {
        // ⚠️ `String.Index` 是**绑定到具体字符串实例**的：不能拿 `a` 的 index 去改 `b`。
        //   所以这里只在 `out` 自己身上取 range、再在 `out` 上替换。
        var out = url.absoluteString
        guard let cur = url.scheme, !cur.isEmpty,
              let r = out.range(of: cur + "://") else { return nil }
        out.replaceSubrange(r, with: scheme + "://")
        return URL(string: out)
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
                ipAddress = d
                ipAddressText = d.text
                return "手机侧 IP 归属地：\(d.text)"
            }
            return prettyJSON(any)
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }

    // ★ 2026-10-09 删掉了原来的 `refreshIPAddress()`（轮询版）。
    //   用户已要求撤掉「当前位置（IP 归属地）」那一套，UI 上不再显示它，
    //   再每次刷新都发这个请求就是纯浪费。
    //   需要这个数据时走上面的 `probeIpAddress()` —— 它同样会把结果写进
    //   `ipAddress` / `ipAddressText`，只是由调用方显式触发（诊断页在用）。
    //   留一个未被引用的 private 方法会被编译器报 unused，所以是删不是留。

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
        // ★ 2026-10-09：IP 归属地**不再进轮询**。
        //   用户已要求撤掉「当前位置（IP 归属地）」那一套，页面上没有任何地方
        //   再显示它了，没必要每次刷新都多发一个请求。
        //   方法和属性都保留 —— 诊断页要看得手动点「探测」（`probeIpAddress()`），
        //   那条路径有独立的抓包样本，留着当排查工具。
        // 健康充电开关状态（只读查询）。充电中心页要用它显示开关的当前值。
        _ = await refreshHealthyCharging()
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
                // ★ 2026-10-09：以前这里只写 `env.message ?? "下发失败"`，
                //   服务端一旦回 `{"result":0,"code":0,"data":""}` 这种「没 msgID
                //   也没 message」的响应，界面上就只剩「下发失败」四个字，
                //   完全不知道错在哪。现在把**服务端原始响应**也带上 ——
                //   错误码和字段一眼可见，用户报错时能直接说清。
                let raw = Self.prettyJSON(any)
                let msg = env.message?.isEmpty == false ? env.message! : "服务端未返回 msgID"
                trace.outcome = "业务错误 \(env.code ?? -1)：\(msg)｜原始响应 \(raw)"
                lastControlTrace = trace
                throw LMError.business(env.code ?? -1, "\(msg)｜服务端原始响应 \(raw)")
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

    /// 把服务端返回的任意 JSON 压成一行短字符串，给错误提示 / 体检单用。
    ///
    /// ★ 2026-10-09 新增：以前车控失败只报「下发失败」，看不到服务端到底回了什么。
    ///   只截前 300 字符 —— alert 里塞整个响应体会被撑爆，300 够看清 code/message。
    static func prettyJSON(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "（无法序列化）" }
        return String(s.prefix(300))
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

    /// 车端是否**很可能已关闭位置数据分享** —— 用来复刻官方那句提示
    /// 「车端已关闭位置数据分享，无法获取车辆实时位置」。
    ///
    /// ★ 2026-10-09：用户看到官方 App 有这句提示，而同期 signalMap 的 `2190/2191`
    ///   在 60 个抓包样本里一个数字都没变 —— 两者互相印证，车机确实没上报实时位置。
    ///
    /// ⚠️ 为什么不直接用 `privacyGPS`：抓包里它是 `0`，而车端**确实**关闭了分享，
    ///   所以「`privacyGPS == 1` → 隐藏」这个旧判断方向存疑（语义可能相反，
    ///   也可能这个开关根本不在 `commonConfig` 里）。拿不到明确证据前不拿它下结论。
    ///
    /// 这里改用**可观测的事实**：车机在实时上报车况（SOC 等一直在变），但坐标超过
    /// 24 小时没动过 —— 那更可能是它没分享位置，而不是「车恰好一直停着」。
    /// 阈值取 24 小时（比 `coordinateLooksStale` 的 6 小时保守），减少正常停车误报。
    var carLocationShareOff: Bool {
        guard coordinate != nil else { return false }
        guard let s = coordinateUnchangedFor else { return false }
        return s > 24 * 3600
    }

    // MARK: - 充电控制（★ 2026-10-08 从官方 IPA 主二进制反汇编解出 cmdid）
    //
    // 四个 cmdid 全部来自「官方主二进制的 cmdid 分派函数」反汇编，
    // 详见 `LMEndpoints.ChargeCmdid` 的注释（含每条 case 的指令地址）。
    //
    // 通道：全部走车控 `POST /app/app-control-service/v3/api/appremotectl`
    //      （form: carvin + cmdid + oppwd + state），复用已跑通的 `controlRaw`。
    //
    // ⚠️ 诚实标注：cmdid 是硬证据；**state 字段名**部分有据、部分推断，
    //    每个方法上单独写明来源与置信度，不混为一谈。

    /// 立即充电 / 结束充电（cmdid **193**）。
    ///
    /// cmdid 证据：`0x106c5eeec  cmp x23, #0xc1` → `b.eq 0x106c5f248`
    /// → `bl objc_msgSend$requestForBeginOrEndChargingWithContent:`。
    ///
    /// ⚠️ state：`Begin_Charge` 取自主二进制字符串表
    /// （`LMVChargingAppointment.chargesoc.chargeEnable.recharge.cycles.circulation.Begin_Charge`），
    /// **字段名有据、取值类型无样本**。所以同时带 `Begin_Charge` 和 `recharge`
    /// 两个候选键（都按车端习惯用 1/0）—— 多一个未知键通常被忽略，
    /// 比押注单一键名安全。
    @discardableResult
    func setChargingActive(_ active: Bool) async -> Bool {
        await controlRaw(cmdid: LMEndpoints.ChargeCmdid.startOrStop,
                         state: ["Begin_Charge": active ? 1 : 0,
                                 "recharge": active ? 1 : 0],
                         label: active ? "立即充电" : "结束充电")
    }

    /// 充电上限设置（cmdid **190**）。
    ///
    /// cmdid 证据：`0x106c5f08c  cmp x23, #0xbe` → `bl objc_msgSend$requestForChargingSetContent:`。
    ///
    /// state：`percent` 是**服务端 `config["3"]` 实测回来的字段名**（置信度高），
    /// 同时冗余带上主二进制字段串里的 `chargesoc`。
    @discardableResult
    func setChargeLimit(_ percent: Int) async -> Bool {
        let p = min(max(percent, LMEndpoints.chargeSocRange.lowerBound),
                    LMEndpoints.chargeSocRange.upperBound)
        return await controlRaw(cmdid: LMEndpoints.ChargeCmdid.socLimit,
                                state: ["percent": p, "chargesoc": p],
                                label: "充电上限 \(p)%")
    }

    /// 健康充电开关（cmdid **480**）。
    ///
    /// cmdid 证据：`0x106c5ef28  cmp x23, #0x1e0` → `bl objc_msgSend$requestForChargingHealthControl:`。
    ///
    /// state：`isPush` 是**确认过的字段** —— 查询接口
    /// `healthyCharging/queryPushState` 实测返回 `{"isPush":false}`。
    /// 下发成功后立刻重新查一次，用服务端回值校准本地开关，不靠乐观更新。
    @discardableResult
    func setHealthyCharging(_ on: Bool) async -> Bool {
        let ok = await controlRaw(cmdid: LMEndpoints.ChargeCmdid.health,
                                  state: ["isPush": on],
                                  label: on ? "打开健康充电" : "关闭健康充电")
        if ok { _ = await refreshHealthyCharging() }
        return ok
    }

    /// 预约充电设置（cmdid **161**）。
    ///
    /// cmdid 证据：`0x106c5ee88  cmp x23, #0xa1` → `bl objc_msgSend$requestForAppointmentContrlCmdID:content:`。
    /// （同一分支还接了 `0xab`=171、`0x188`=392，是预约族的另外两个子码。）
    ///
    /// ── ★★ 2026-10-09 修「保存预约充电报下发失败」────────────────
    ///
    ///   老 payload **只带 `config["3"]` 的读取字段名**（`beginTime` /
    ///   `endTime` / `percent` / `isEnable` / `cycles` / `circulation` /
    ///   `recharge`）。那是**服务端下发**用的名字，写回去服务端未必认 ——
    ///   用户实测就是「保存报错下发失败」。
    ///
    ///   官方主二进制的字符串常量池里有一段**连续的 JSON 键名**：
    ///       `LMVChargingAppointment.chargesoc.chargeEnable.recharge.cycles.circulation.Begin_Charge`
    ///   其中 **`chargesoc`**（= 目标电量）与 **`chargeEnable`**（= 预约开关）
    ///   是**写接口专用**的名字 —— `config["3"]` 里从来没有它们，
    ///   而老 payload 恰好缺的就是这两个。
    ///
    ///   现在**两套键名都带上**：多一个未知键服务端通常忽略，比押注单一键名安全。
    ///   这与 `setChargeLimit`（`percent` + `chargesoc`）、
    ///   `setChargingActive`（`Begin_Charge` + `recharge`）的策略一致。
    ///   而 `cycles` / `circulation` / `recharge` 三个键**读写两处都出现过**，
    ///   是最可信的一组。
    ///
    ///   ⚠️ 诚实标注：**没有一份「官方保存预约充电」的抓包样本**
    ///      （手上的 HAR 里只有 `getappointment` 查询，且返回 `data:""`）。
    ///      所以这是「按二进制字段名 + 同族接口惯例」构造的最优猜测，
    ///      真机若仍失败，诊断页有 payload 探测可以直接定位是哪套键名不对。
    @discardableResult
    func saveAppointmentCharge(beginTime: String,
                               endTime: String,
                               percent: Int,
                               enabled: Bool,
                               cycles: String,
                               circulation: Bool) async -> Bool {
        let p = min(max(percent, LMEndpoints.chargeSocRange.lowerBound),
                    LMEndpoints.chargeSocRange.upperBound)
        let state: [String: Any] = [
            // ① 官方**写接口**字段名（主二进制字符串池，老 payload 缺的就是这两个）
            "chargesoc": p,
            "chargeEnable": enabled ? 1 : 0,
            // ② 读写两处都出现过的键（最可信）
            "cycles": cycles,
            "circulation": circulation ? 1 : 0,
            "recharge": 0,
            // ③ config["3"] 读取字段名（服务端下发过，冗余保留）
            "beginTime": beginTime,
            "endTime": endTime,
            "percent": p,
            "isEnable": enabled ? 1 : 0,
        ]
        let ok = await controlRaw(cmdid: LMEndpoints.ChargeCmdid.appointment,
                                  state: state,
                                  label: "预约充电 \(beginTime)–\(endTime) \(p)%")
        if ok { try? await refreshCommonConfig() }
        return ok
    }

    /// 健康充电开关查询（只读，不抛错）。
    ///
    /// 从 `probeHealthyChargingPush()` 抽出来的可复用版本 —— 那个是诊断页
    /// 手动探测用的，返回人类可读字符串；这个返回 `Bool?` 给界面直接用。
    @discardableResult
    func refreshHealthyCharging() async -> Bool? {
        guard let vin = selectedVehicle?.vin else {
            healthyChargingError = "还没有选中车辆（拿不到 VIN）"
            return nil
        }
        // ★ 2026-10-09 重写：以前是
        //     do { … healthyChargingPush = env?.data?.isPush; return healthyChargingPush }
        //     catch { return nil }        ← 异常被整个吞掉，界面完全看不出来
        //   现在把「加载中 / 出错原因 / 读取时间」都记下来，UI 才能给反馈。
        healthyChargingLoading = true
        healthyChargingError = nil
        defer { healthyChargingLoading = false }
        do {
            let any = try await request(method: "POST",
                                        path: LMEndpoints.Path.healthyChargingPush,
                                        form: ["carvin": vin, "deviceId": config.deviceId])
            guard let env = try? decode(LMEnvelope<LMHealthyChargingPush>.self, from: any) else {
                healthyChargingError = "响应解析失败：\(String(describing: any).prefix(160))"
                return nil
            }
            if let code = env.code, code != 0 {
                healthyChargingError = "服务端返回 code=\(code)"
                    + (env.message.map { "（\($0)）" } ?? "")
                return nil
            }
            guard let value = env.data?.isPush else {
                healthyChargingError = "服务端没有返回 isPush 字段"
                return nil
            }
            healthyChargingPush = value
            healthyChargingReadAt = Date()
            return value
        } catch {
            healthyChargingError = "读取失败：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - 充电
    //
    // 证据见 LMSignalCatalog 顶部「充电状态」小节。这里只放「确认过」和「明确标注为疑似」的。

    /// 5 路「**高压系统激活**」标志位。
    ///
    /// ★★ 2026-10-09 用户实测纠正了它的含义 —— **这不是「充电中」标志**。
    ///   用户报「车辆通电使用、开启哨兵模式时也显示充电中」，反证车辆 READY
    ///   （高压上电）与哨兵模式同样会把这 5 位点亮。当时只有「熄火停放 vs
    ///   插枪充电」两张快照，没有「通电 / 哨兵」这一组对照，才把
    ///   「高压系统在工作」误读成「在充电」。
    ///
    ///   现在它只服务 `highVoltageActive`（给 UI 提示用），
    ///   **不再参与** `chargeState`。
    static let chargeFlagIDs = ["100004", "1149", "1257", "3636", "3722"]

    /// 标志位里投「高压系统在工作」的票数，0...5。含义见 `chargeFlagIDs`。
    var chargeFlagVotes: Int {
        LMClient.chargeFlagIDs.reduce(0) { acc, id in
            let v = signals[id]?.doubleValue ?? 0
            return acc + (v == 1 ? 1 : 0)
        }
    }

    /// 高压系统是否处于激活状态（车辆通电 / 哨兵模式 / 充电都会点亮）。
    ///
    /// ⚠️ 它**不能**用来判断是否在充电 —— 这正是用户报的误报来源。
    ///   用它来区分「车没充电但高压在工作」（通电 / 哨兵）与「车彻底歇着」。
    var highVoltageActive: Bool { chargeFlagVotes >= 3 }

    /// 充电电流是否非零（信号 `1178`）。
    ///
    /// 物理量：没有电流就不可能真的在充电。实测充电时 −8.3 ~ −8.4 A、
    /// 未充电时恒为 0.0。留 0.05 的容差是为了避开采样噪声。
    var chargeCurrentNonZero: Bool {
        guard let v = signals["1178"]?.doubleValue else { return false }
        return abs(v) > 0.05
    }

    /// 充电状态。★ 判据 = **充电电流 `1178`**，见 `LMChargeState` 的说明。
    ///
    /// 2026-10-09 改（用户实测逼出来的）：老判据「5 路标志位多数票 ≥ 3」
    /// 在**车辆通电 / 哨兵模式**下会误报「充电中」—— 那 5 位是「高压系统激活」
    /// 而不是「充电中」。改成电流硬门槛：
    ///   · 电流非零           → 充电中
    ///   · 电流为零           → 未充电（不管标志位怎么翻）
    ///   · 车端根本没上报 1178 → 不猜，返回 unknown（宁可说「待确认」也不误报）
    var chargeState: LMChargeState {
        if signals.isEmpty { return .unknown }
        guard signals["1178"] != nil else { return .unknown }
        return chargeCurrentNonZero ? .charging : .notCharging
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

    /// 充电电压 V（信号 `1177`）。
    ///
    /// ── 证据链（2026-10-09 第三次修订）────────────────────────────
    ///   ① 实测取值：未充电 **732.7**、充电 **736.7** —— 只差 4.0 V。
    ///      ★ 老结论「充电功率 ×100 W」早已被这条推翻：功率在没充电时
    ///      必须掉到 0，而它不为 0。充电时抬升 4 V 正是母线电压的行为。
    ///   ② ★ **新增决定性证据**：官方本地化表
    ///      （`LMVLocalizedBundle.bundle/zh-Hans.lproj/Localizable.strings`）
    ///      里充电中心有一组三个键：
    ///          `ChargingCnter_Voltage` = 电压
    ///          `ChargingCnter_Current` = 电流
    ///          `ChargingCnter_Power`   = 功率
    ///      → 官方充电中心**确实显示电压 / 电流 / 功率**三项。
    ///   ③ 130 个信号里，属于「电池电气量」且量纲自洽的**只有 1177/1178 这一对**：
    ///      1178 没充电时正好 0.0（电流的正确行为），充电时 8.3 A；
    ///      1177 没充电时 732.7（电压的正确行为，不能为 0）。
    ///   所以「1177 = 电压、1178 = 电流」是目前唯一自洽的配对。
    ///
    ///   ⚠️ 仍未确证：732.7 V 是**电池包电压**还是**充电机输出电压**；
    ///      也仍未确证官方充电中心读的就是这两个信号（没有充电页的抓包样本）。
    ///      UI 按「电压」显示，并注明来源信号。
    var chargeVoltageV: Double? {
        guard let v = signals["1177"]?.doubleValue, v > 0 else { return nil }
        return v
    }

    /// 充电电流 A（信号 `1178`）。
    ///
    /// 实测：充电时 −8.299 / −8.399（负号含义未定，量级 8.3 A），
    ///       未充电时 0.0。这是**唯一一个带物理意义的充电证据**。
    /// 取绝对值显示 —— 负号最可能是「电流方向」而不是数值本身。
    var chargeCurrentA: Double? {
        guard let v = signals["1178"]?.doubleValue, v != 0 else { return nil }
        return abs(v)
    }

    /// 充电功率 kW —— **由 1177 × 1178 现算**，不是车端上报的信号。
    ///
    /// 依据：官方充电中心有 `ChargingCnter_Power = 功率` 这一项，而 130 个信号里
    /// **没有任何一个**能当功率用（都逐一排查过：唯一的功率候选 1177 在没充电时
    /// 不为 0，已被推翻），所以官方的功率极可能就是电压 × 电流现算的。
    /// 实测量级：736.7 V × 8.399 A ≈ **6.19 kW** —— 与「7 kW 交流慢充」吻合。
    ///
    /// ⚠️ 这是**派生值**。UI 必须写清「电压 × 电流估算」，不能当官方数字用。
    var chargePowerKW: Double? {
        guard let v = chargeVoltageV, let a = chargeCurrentA else { return nil }
        return v * a / 1000.0
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
