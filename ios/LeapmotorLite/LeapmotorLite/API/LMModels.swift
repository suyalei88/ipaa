//
//  LMModels.swift
//  LeapmotorLite
//
import Foundation

// MARK: - 通用响应信封

struct LMEnvelope<T: Decodable>: Decodable {
    let code: Int?
    let result: Int?
    let message: String?
    let data: T?
}

struct LMEmpty: Decodable {}

// MARK: - 登录

struct LMLoginData: Decodable {
    let accountId: Int64?
    let nickname: String?
    let accessToken: String
    let refreshToken: String?
    let tokenExpireTime: Int?
    let refreshTokenExpireTime: Int?
    let base64Cert: String?
    let signParam: LMRParam?
    let encryptParam: LMRParam?
}

struct LMRParam: Decodable {
    let r2: String
    let r3: String
}

// MARK: - 车辆

struct LMVehicleList: Decodable {
    let bindcars: [LMVehicle]?
    let sharedcars: [LMVehicle]?
}

struct LMVehicle: Decodable, Identifiable, Hashable {
    let carId: Int?
    let vin: String
    let carType: String?
    let carAlias: String?
    let vinNickname: String?
    let plateNumber: String?
    let outColor: String?
    let year: Int?
    let seatLayout: Int?
    let abilities: [String]?

    // ★ 2026-10-08 补齐：`vehicle/list` 的真实响应里本来就有下面这些字段，
    //   之前只建模了上面那几个，所以「车辆档案」页拿不到年款 / 版型 / 空调档位范围。
    //   证据：`appgateway.leapmotor.com_2026_10_07_13_25_47.har` 的 vehicle/list 响应。
    /// 配置代号（实测 14）。含义未公开，按原样展示。
    let allocationCode: Int?
    /// 版型描述。实测是**空串** —— 真正的版型文字在
    /// `carpicture/3d/key` 的 `modelParam.carTypeCode`（"720智尊版 六座"）。
    let carConfigEdition: String?
    /// 车顶颜色代号（实测 "0"）
    let roofColor: String?
    /// CCC（数字钥匙标准）的车辆 ID。实测 `null` = 这台车没绑 CCC 钥匙，
    /// 也解释了为什么 `ccc/pairingcode` 那组接口在二进制里存在但我们用不上。
    let cccVehicleId: String?
    /// 功能能力范围。实测只给了 HVAC 的风量 / 温度区间 —— 见 `LMFuncConfig`。
    let funcConfig: LMFuncConfig?

    var id: String { vin }

    var displayName: String {
        carAlias?.isEmpty == false ? carAlias! :
        (vinNickname?.isEmpty == false ? vinNickname! : vin)
    }

    // MARK: 展示用派生值

    /// 年款，例如 `2026 款`
    var yearText: String { year.map { "\($0) 款" } ?? "--" }

    /// 能力位数量（实测 66 个）
    var abilityCount: Int { abilities?.count ?? 0 }

    /// 能力位按数值升序排好的文本。
    ///
    /// ⚠️ 这 66 个码（1…107 + 100002）的**含义官方没有公开**，我们也没有样本能把
    ///    码位和功能对应起来。所以只按原样排序展示，不做任何猜测性标注 ——
    ///    它的用途是「换车/换版本后对比这串码变没变」。
    var abilitiesSortedText: String {
        guard let a = abilities, !a.isEmpty else { return "--" }
        return a.compactMap { Int($0) }.sorted().map { String($0) }.joined(separator: ", ")
    }

    /// 空调风量档位范围（来自 `funcConfig.HVAC.fan`）
    var hvacFanRange: LMRange? { funcConfig?.HVAC?.fan }
    /// 空调温度范围（来自 `funcConfig.HVAC.temperature`）
    var hvacTempRange: LMRange? { funcConfig?.HVAC?.temperature }

    static func == (lhs: LMVehicle, rhs: LMVehicle) -> Bool { lhs.vin == rhs.vin }
    func hash(into hasher: inout Hasher) { hasher.combine(vin) }
}

// MARK: - 功能能力范围（`vehicle/list` → `funcConfig`）

/// `vehicle/list` → `funcConfig`
///
/// ★ 2026-10-08 从抓包补上。实测样本（D19 / 2026 款）：
/// ```json
/// "funcConfig": {
///   "HVAC": { "fan": {"max":"9","min":"1","unit":"gear"},
///             "temperature": {"max":"32","min":"16","unit":"celsius"} },
///   "valid": true
/// }
/// ```
///
/// ★★ 这是「空调到底有几档」的**唯一权威来源**，价值很高：
///    抓包里 cmdid 230 只出现过 `{"value":"0"|"2"|"5"}`，很容易让人以为
///    空调就三档（关/低/高）。实际上**风量是 1~9 档、温度是 16~32 °C**，
///    抓包那三次只是碰巧只按了低/高。
///    ⚠️ 但注意：这只证明「车支持这些档位」，**没有**证明
///    `{"value":"3"}` 这种 payload 服务端一定接受 —— 所以车控页里
///    1~9 档仍然按「未验证」标注（详见 ControlPanelView 的空调档位卡）。
struct LMFuncConfig: Decodable, Hashable {
    let valid: Bool?
    /// 服务端字段名就是大写 `HVAC`
    let HVAC: LMHVACRange?
}

struct LMHVACRange: Decodable, Hashable {
    let fan: LMRange?
    let temperature: LMRange?
}

/// 一个「最小值 / 最大值 / 单位」的区间。
///
/// 注意服务端的 min/max 是**字符串**（`"9"` 而不是 `9`），所以这里保持 String，
/// 再用 `minValue` / `maxValue` 转成 Int。
struct LMRange: Decodable, Hashable {
    let min: String?
    let max: String?
    let unit: String?

    var minValue: Int? { min.flatMap { Int($0) } }
    var maxValue: Int? { max.flatMap { Int($0) } }

    /// `1 ~ 9 档` / `16 ~ 32 °C`
    var rangeText: String {
        let lo = min ?? "?"
        let hi = max ?? "?"
        switch unit {
        case "gear":       return "\(lo) ~ \(hi) 档"
        case "celsius":    return "\(lo) ~ \(hi) °C"
        case .some(let u): return "\(lo) ~ \(hi) \(u)"
        case .none:        return "\(lo) ~ \(hi)"
        }
    }

    /// 展开成可用档位数组。范围不合理（缺值 / 倒置 / 大得离谱）时返回空数组，
    /// 调用方据此隐藏档位选择器 —— 绝不凭空造一个范围出来。
    var values: [Int] {
        guard let lo = minValue, let hi = maxValue, lo <= hi, hi - lo < 200 else { return [] }
        return Array(lo...hi)
    }
}

// MARK: - 车况

struct LMSignalData: Decodable {
    let vin: String?
    let collectTime: Double?
    let signalMap: [String: LMSignalValue]?
}

/// signalMap 的值可能是数字、字符串、布尔或 null
enum LMSignalValue: Decodable, Hashable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .null
    }

    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        case .null: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s): return (s as NSString).boolValue
        case .null: return nil
        }
    }

    var displayText: String {
        switch self {
        case .number(let d):
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s): return s
        case .bool(let b): return b ? "是" : "否"
        case .null: return "--"
        }
    }
}

// MARK: - 车控

struct LMCtlAck: Decodable {
    let result: Int?
    let code: Int?
    let message: String?
    let timeout: Int?
    let data: String?          // msgID
}

struct LMCtlQuery: Decodable {
    let result: Int?
    let code: Int?
    let data: Int?             // 1 = 成功
}

// MARK: - 里程

struct LMMileageData: Decodable {
    let totalmileage: Double?
    let deliveryDays: Int?
}

// MARK: - 车辆配置

/// `GET /carownerservice/v3/api/vehicleinfo/commonConfig?vin=...`
///
/// 实测响应（2026-10-07 抓包）：
/// ```json
/// {"data":{
///   "isSupportBigModel":0,"privacyGPS":0,"privacyData":1,
///   "parkingAssistConfig":"1","vin":"LFZ63AA15TH035113",
///   "config":{
///     "3":{"cycles":"1,1,1,1,1,1,1","endTime":"15:00","percent":90,
///          "isEnable":1,"recharge":0,"beginTime":"10:00",
///          "updateTime":"2026-10-07 03:37:42","circulation":1},
///     "4":{"mac":"C8C83FF5C48E","version":"2.0","updateTime":"2026-09-20 11:02:29"}
///   },
///   "isAiParking":false},"result":0,"code":0}
/// ```
///
/// ★ `config["3"]` 就是「预约充电」：beginTime/endTime 是充电窗口，
///   percent 是目标电量，cycles 是「周一~周日」七位启用位（逗号分隔）。
///   抓包时刻 05:23–06:05 UTC = 13:23–14:05 北京时间，正好落在
///   10:00–15:00 窗口内，同时段 SOC 从 32.9% 涨到 36.7% —— 对得上。
/// ★ `config["4"]` 是蓝牙/数字钥匙（mac + 版本），不解析成强类型，按原样展示。
struct LMCommonConfigData: Decodable {
    let vin: String?
    let isSupportBigModel: Int?
    let privacyGPS: Int?
    let privacyData: Int?
    let parkingAssistConfig: String?
    let isAiParking: Bool?
    /// key 是配置项编号的字符串（"3" / "4" …）
    let config: [String: LMConfigBlob]?
}

/// `config` 下每个编号的内容。不同编号字段完全不同，所以全部 optional，
/// 由使用方按编号取。**不要**为 "3" / "4" 各建一个类型 —— 服务端随时加编号。
struct LMConfigBlob: Decodable {
    // config["3"] —— 预约充电
    /// "1,1,1,1,1,1,1"，周一到周日；1 = 当天启用
    let cycles: String?
    /// "10:00"
    let beginTime: String?
    /// "15:00"
    let endTime: String?
    /// 目标电量 %（实测 90）
    let percent: Int?
    /// 预约充电总开关：1 = 开
    let isEnable: Int?
    /// 0/1，含义待确认（疑似「当前是否处于该预约的充电中」）
    let recharge: Int?
    /// 1 = 循环（每周重复）
    let circulation: Int?
    let updateTime: String?

    // config["4"] —— 蓝牙 / 数字钥匙
    let mac: String?
    let version: String?
}

// MARK: - 预约充电（从 LMConfigBlob 抽出来的视图模型）

/// 把 `config["3"]` 整理成 UI 直接能用的形状。
struct LMChargeSchedule {
    var isEnabled: Bool
    /// 周一…周日，7 个布尔
    var weekdayFlags: [Bool]
    var beginTime: String
    var endTime: String
    var targetPercent: Int?
    var isCirculating: Bool
    var updateTime: String?

    /// "1,1,1,1,1,1,1" → [true × 7]
    ///
    /// 只取前 7 段；不足 7 段的用 false 补齐，多余的丢掉。
    /// 不假设服务端一定给 7 段（虽然实测是 7 段）。
    static func parseWeekdays(_ s: String?) -> [Bool] {
        let parts = (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var out = [Bool](repeating: false, count: 7)
        for (i, p) in parts.prefix(7).enumerated() { out[i] = (p == "1") }
        return out
    }

    /// 中文的星期摘要："每天" / "工作日" / "周一、周三"
    var weekdayText: String {
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        let on = weekdayFlags.enumerated().compactMap { $0.element ? names[$0.offset] : nil }
        if on.isEmpty { return "未选择" }
        if on.count == 7 { return "每天" }
        if weekdayFlags == [true, true, true, true, true, false, false] { return "工作日" }
        if weekdayFlags == [false, false, false, false, false, true, true] { return "周末" }
        return "周" + on.joined(separator: "、周")
    }

    init?(blob: LMConfigBlob?) {
        guard let b = blob else { return nil }
        // 全是 nil 说明 config["3"] 不存在，别造一个假的出来
        if b.beginTime == nil && b.endTime == nil && b.percent == nil && b.isEnable == nil {
            return nil
        }
        isEnabled      = (b.isEnable ?? 0) == 1
        weekdayFlags   = LMChargeSchedule.parseWeekdays(b.cycles)
        beginTime      = b.beginTime ?? "--:--"
        endTime        = b.endTime ?? "--:--"
        targetPercent  = b.percent
        isCirculating  = (b.circulation ?? 0) == 1
        updateTime     = b.updateTime
    }
}

// MARK: - 停车位置（响应格式未定，按宽松方式接）

/// `GET /carownerservice/v3/api/vehicleinfo/parking/query`
///
/// ⚠️ 这个端点是**从 IPA 字符串表里挖出来的**（`evidence/ios_endpoints.txt:258`），
///    **没有抓包样本**，所以响应结构未知。这里不解成强类型，只保留原始 JSON，
///    再用候选 key 名去掏经纬度。
///    正常情况下坐标走 signalMap 的 2190/2191 就够，这个接口只是补充。
struct LMParkingProbe {
    /// 原始响应（格式化后的 JSON 文本，直接展示给用户）
    let rawText: String
    /// 掏出来的经纬度（可能是 nil）
    let latitude: Double?
    let longitude: Double?

    /// 候选 key：不同服务端的命名习惯都试一遍，命中即用。
    /// 注意别把 "lat" 放在 "latitude" 前面做前缀匹配 —— 这里是精确取 key，
    /// 不会互相干扰。
    static let latKeys = ["latitude", "lat", "parkingLat", "parkingLatitude", "carLat", "gpsLat", "y"]
    static let lngKeys = ["longitude", "lng", "lon", "parkingLng", "parkingLongitude",
                          "carLng", "gpsLng", "x"]

    /// 递归找第一个 key 命中候选表的数值
    static func pick(_ obj: Any, keys: [String]) -> Double? {
        if let d = obj as? [String: Any] {
            for k in keys {
                if let v = d[k], let num = asDouble(v) { return num }
            }
            for (_, v) in d {
                if let r = pick(v, keys: keys) { return r }
            }
        } else if let a = obj as? [Any] {
            for v in a {
                if let r = pick(v, keys: keys) { return r }
            }
        }
        return nil
    }

    private static func asDouble(_ v: Any) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - OTA 版本（`fota/getCurrentVersion`）

/// `GET /carownerservice/v3/api/fota/getCurrentVersion?vin=...`
///
/// ★ 2026-10-08 从抓包补上。实测响应：
/// ```json
/// {"data":{"vin":"LFZ…5113","versionNo":"4.2614.020",
///          "logContent":"本次OTA新增功能：…（完整中文更新日志）",
///          "updateTime":"2026.08.10"},"result":0,"code":0}
/// ```
///
/// ★ 价值：这是**这台车车机当前固件版本 + 最近一次 OTA 的完整更新日志**。
///   官方 App 只在「OTA 升级」页展示，而且升级完就翻篇了；
///   留在本 App 里就能随时回看「上次升了什么」。
struct LMFotaVersion: Decodable {
    let vin: String?
    /// 固件版本号，例如 `4.2614.020`
    let versionNo: String?
    /// 完整更新日志（中文，多行，带 `\n`）
    let logContent: String?
    /// 升级时间，例如 `2026.08.10`（注意是点分隔，不是横杠）
    let updateTime: String?

    /// 更新日志拆成一行一条，方便直接喂给 List。
    ///
    /// 服务端给的是 `"本次OTA新增功能：\n1、…\n2、…"` 这种一整块文本，
    /// 这里只按 `\n` 拆、去掉空行，**不**重排编号（编号是服务端写的，改了反而失真）。
    var logLines: [String] {
        (logContent ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - 3D 车模（`carpicture/3d/key`）

/// `GET /carownerservice/v3/api/carpicture/3d/key?vin=...&osVersion=...`
///
/// ★ 2026-10-08 从抓包补上。实测响应（关键字段）：
/// ```json
/// {"data":{
///   "h5Key":"3D-616d34c0-…","srcKey":"3D-8444a1b9-…",
///   "h5Whole":"w58wdL6R6Dnv3lOzXhYT1Q==","srcWhole":"+idvVcToKuoG3gRrmhmUXw==",
///   "modelType":3,
///   "modelParam":{"carType":"D19","year":2026,"carTypeCode":"720智尊版 六座",
///                 "colorCode":0,"roofColor":"0","selection":"null"},
///   "shareBindUrl":"http://lp-carnet.oss-cn-hangzhou.aliyuncs.com/carModel3D/3D-…?…"}}
/// ```
///
/// ★ 价值有两个：
///   ① `modelParam.carTypeCode` 是**最精确的版型字符串**（"720智尊版 六座"）——
///      `vehicle/list` 里 `carConfigEdition` 是空串，只有这里才有；
///   ② `shareBindUrl` 是官方自己的 3D 车模分享页，可以直接在浏览器里打开。
struct LM3DKey: Decodable {
    let h5Key: String?
    let h5Whole: String?
    let srcKey: String?
    let srcWhole: String?
    /// 实测 3
    let modelType: Int?
    let modelVersion: String?
    let currentTheme: String?
    let shareBindUrl: String?
    let modelParam: LM3DModelParam?
}

struct LM3DModelParam: Decodable {
    let carType: String?
    let year: Int?
    /// ★ 精确版型，例如 "720智尊版 六座"
    let carTypeCode: String?
    let colorCode: Int?
    let roofColor: String?
    /// 实测是字符串 `"null"`（不是 JSON null）—— 所以只能当 String 接。
    let selection: String?
}

// MARK: - 模块示意图（`appImage/getAppImage`）

/// `GET /carownerservice/v3/api/appImage/getAppImage?vin=...`
///
/// ★ 2026-10-08 从抓包补上。实测返回 3 个模块，每个带一张 OSS 图片：
/// ```json
/// {"data":[{"moduleId":1,"moduleName":"胎压",
///           "subModule":[{"subModuleId":1,"subModuleName":"胎压","image":"https://…"}]},
///          {"moduleId":6,"moduleName":"直进直出",…},
///          {"moduleId":7,"moduleName":"辅助泊车",…}]}
/// ```
///
/// ⚠️ 图片 URL 带 `Expires=4927244149`（约 2126 年到期），短期内不会失效；
///    但**不保证**长期有效，所以本 App 只展示 URL 让用户点开看，不做本地缓存。
struct LMAppImageModule: Decodable, Identifiable {
    let moduleId: Int?
    let moduleName: String?
    let subModule: [LMAppImageSub]?

    var id: Int { moduleId ?? -1 }
}

struct LMAppImageSub: Decodable {
    let subModuleId: Int?
    let subModuleName: String?
    let image: String?
}

// MARK: - 后台开关配置（`commoninfo/getBgConf`）

/// `GET /carownerservice/v3/api/commoninfo/getBgConf?vin=...&osType=iOS&…`
///
/// ★ 2026-10-08 从抓包补上。这是服务端下发给 App 的**功能开关表**，
///   实测响应：
/// ```json
/// {"data":{"ble_restoreWakeup":true,"isSupportRadars":false,
///          "token_retryRequesy":false,"shareWhiteList":false,
///          "isSupportSuspendRecovery":true,"preWakeupByBle":false,
///          "threeDTheme":true,"log_uploadAll":false,"canaryVersion":null,
///          "internalTestUser":false,"backBroadcasts":false},
///  "result":0,"code":0}
/// ```
///
/// ★ 价值：它直接回答了「为什么某些功能在我这台车上没有」——
///   比如 `preWakeupByBle=false` 就是**无感蓝牙钥匙没开**，
///   `isSupportRadars=false` 就是没有雷达，`threeDTheme=true` 就是支持 3D 车模。
///   ⚠️ 这些开关是服务端/车端决定的，**本 App 只读不改**。
///
/// 注意 `token_retryRequesy` 是服务端**拼错的**（Requesy ≠ Request），
/// 不能"顺手改成正确的拼写"，否则永远解不出来。
struct LMBgConf: Decodable {
    let bleRestoreWakeup: Bool?
    let isSupportRadars: Bool?
    /// 服务端原字段名 `token_retryRequesy`（拼写错误，照抄）
    let tokenRetryRequest: Bool?
    let shareWhiteList: Bool?
    let isSupportSuspendRecovery: Bool?
    let preWakeupByBle: Bool?
    let threeDTheme: Bool?
    let logUploadAll: Bool?
    let canaryVersion: String?
    let internalTestUser: Bool?
    let backBroadcasts: Bool?

    enum CodingKeys: String, CodingKey {
        case bleRestoreWakeup = "ble_restoreWakeup"
        case tokenRetryRequest = "token_retryRequesy"
        case logUploadAll = "log_uploadAll"
        case isSupportRadars, shareWhiteList, isSupportSuspendRecovery
        case preWakeupByBle, threeDTheme, canaryVersion, internalTestUser, backBroadcasts
    }

    /// 一个开关项。
    ///
    /// ★ 用结构体而不是元组 `(name:on:)`：`ForEach` 需要 key path，
    ///   而 Swift 的 key path **不能指向元组成员**（`\.name` 直接编译不过）。
    ///   这是这个项目已经踩过一次的坑（见 LMEndpoints.UnverifiedCmd 的注释）。
    struct Flag: Identifiable {
        let name: String
        let on: Bool
        var id: String { name }
    }

    /// 按字段名直译出来的开关清单 —— 顺序即展示顺序，只列有明确语义的。
    ///
    /// ⚠️ 中文说明是**按字段名直译**的，不是官方文档。
    ///    含义拿不准的一律不写（宁可少列，也不编）。
    var flags: [Flag] {
        var out: [Flag] = []
        if let v = preWakeupByBle           { out.append(Flag(name: "无感蓝牙钥匙（靠近唤醒）", on: v)) }
        if let v = bleRestoreWakeup         { out.append(Flag(name: "蓝牙断连后自动恢复唤醒", on: v)) }
        if let v = threeDTheme              { out.append(Flag(name: "3D 车模主题", on: v)) }
        if let v = isSupportSuspendRecovery { out.append(Flag(name: "挂起后可恢复", on: v)) }
        if let v = isSupportRadars          { out.append(Flag(name: "毫米波雷达", on: v)) }
        if let v = shareWhiteList           { out.append(Flag(name: "分享白名单", on: v)) }
        if let v = tokenRetryRequest        { out.append(Flag(name: "token 失败自动重试", on: v)) }
        if let v = logUploadAll             { out.append(Flag(name: "全量日志上报", on: v)) }
        if let v = internalTestUser         { out.append(Flag(name: "内部测试账号", on: v)) }
        if let v = backBroadcasts           { out.append(Flag(name: "后台广播", on: v)) }
        return out
    }
}

// MARK: - 车辆分享（`sharecar/getShareVehicleListByVin`）

/// `GET /carownerservice/v3/api/sharecar/getShareVehicleListByVin?vin=...`
///
/// ★ 2026-10-08 从抓包补上。实测响应：
/// ```json
/// {"data":{"carShareInfoList":[{"userid":895491570407612416,
///            "nickName":"LP_9e04ry4s2t31u","carCode":"LFZ…5113",
///            "rightList":"190,192,170,…,500","mobileNumber":"176****9090",
///            "moduleRights":"100,200,400","shareTime":1789198271000,
///            "durationType":0}],
///          "shareMaxCount":"8"},"result":0,"code":0}
/// ```
///
/// ★★ `rightList` 是目前拿到的**最全 cmdid 枚举（30 个）** ——
///    它本身是「这条分享授权允许对方用哪些指令」，但顺带把车控指令的
///    编号空间列全了。本 App 只实现了其中 6 个，这个列表是后续扩展的路线图。
struct LMShareVehicleList: Decodable {
    let carShareInfoList: [LMShareInfo]?
    /// 最多可分享给几个人（实测 "8"）
    let shareMaxCount: String?
}

struct LMShareInfo: Decodable, Identifiable {
    let userid: Int64?
    let nickName: String?
    let carCode: String?
    let identityCode: String?
    /// 逗号分隔的 cmdid 白名单
    let rightList: String?
    /// 服务端已脱敏，例如 `176****9090`
    let mobileNumber: String?
    /// 逗号分隔的模块权限（实测 "100,200,400"）
    let moduleRights: String?
    let email: String?
    let expireTime: String?
    /// 毫秒时间戳
    let shareTime: Int64?
    let durationType: Int?

    var id: String { "\(userid ?? 0)-\(nickName ?? "")" }

    /// `rightList` 解析成 Int 数组（升序、去重）
    var rights: [Int] {
        let parts = (rightList ?? "").split(separator: ",")
        return Array(Set(parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })).sorted()
    }

    /// `shareTime` 毫秒时间戳 → `MM-dd HH:mm`
    var shareTimeText: String {
        guard let t = shareTime, t > 0 else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(t) / 1000))
    }

    /// 永久 / 限时
    var durationText: String {
        // durationType 实测 0；0 对应「永久」是官方分享页的默认项，
        // 但**没有第二组样本**能证实 1 是什么，所以只对 0 下结论。
        switch durationType {
        case 0:  return "永久"
        case .some(let v): return "类型 \(v)"
        case .none: return "--"
        }
    }
}

// MARK: - 健康充电推送（`healthyCharging/queryPushState`）

/// `POST /carownerservice/v3/api/healthyCharging/queryPushState`
/// （form: `carvin` + `deviceId`）
///
/// ★ 2026-10-08 从抓包补上。实测响应：
/// ```json
/// {"data":{"isPush":false},"result":0,"code":0,"message":"请求成功"}
/// ```
/// `isPush` = 这台车是否开启了「健康充电」相关的推送提醒。
struct LMHealthyChargingPush: Decodable {
    let isPush: Bool?
}

// MARK: - 手机侧 IP 归属地（`tecHost` 的 `ipAnalysis/getAddressByIp`）

/// `GET https://apptec.leapmotor.cn/ipAnalysis/getAddressByIp`（无参数）
///
/// ★ 2026-10-08 从抓包补上。实测响应：
/// ```json
/// {"message":"执行成功!","data":{"country":"中国","province":"安徽",
///   "city":"淮南","currentTime":1791350572866},"errorCode":"0"}
/// ```
///
/// ★★ 这个接口的**诊断价值大于功能价值**：它返回的是「服务端认为**手机**在哪」，
///    和车端坐标（signalMap 2190/2191）是两个完全独立的来源。
///    实测手机侧 = 安徽 淮南（正确），车端坐标 = 合肥 —— 两者一对照，
///    「定位不对」的责任范围就直接缩到了车端，不用靠猜。
///
/// ⚠️ 响应用的是 `errorCode`（字符串）而**不是** `code`，
///    所以不能用 `LMEnvelope` 里那套 `code != 0 就抛错` 的逻辑。
struct LMIPAddress: Decodable {
    let country: String?
    let province: String?
    let city: String?

    /// `中国 安徽 淮南`
    var text: String {
        [country, province, city]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `安徽 淮南` —— 省 + 市，用于「车辆位置」主显示。
    ///
    /// ★ 为什么不带 `country`：官方 App 的车辆位置只显示到省市，
    ///   带上「中国」既啰嗦又挤占宽度。省市都缺时退回 `text`。
    var regionText: String {
        let r = [province, city]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return r.isEmpty ? text : r
    }
}

struct LMIPAddressEnvelope: Decodable {
    let message: String?
    let errorCode: String?
    let data: LMIPAddress?
}

// MARK: - 消息未读数（`msgcenter/v1/noticemsg/selectmsgcount`）

/// `GET https://msgcenter.leapmotor.cn/msgcenter/v1/noticemsg/selectmsgcount?begintime=…&endtime=…`
///
/// ★ 2026-10-08 从抓包补上。实测响应：
/// ```json
/// {"result":0,"message":"请求成功",
///  "data":{"devicetotal":0,"total":0,"unread":0,"usertotal":0,"alreadyread":0}}
/// ```
/// ⚠️ 这个响应**没有 `code` 字段**（只有 `result`）—— 和主网关不一样，
///    所以不能用 `LMEnvelope` 里「code != 0 就抛错」那套判断。
struct LMNoticeCount: Decodable {
    let total: Int?
    let unread: Int?
    let alreadyread: Int?
    let usertotal: Int?
    let devicetotal: Int?
}
