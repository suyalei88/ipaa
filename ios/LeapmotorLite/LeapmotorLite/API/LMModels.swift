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

    var id: String { vin }

    var displayName: String {
        carAlias?.isEmpty == false ? carAlias! :
        (vinNickname?.isEmpty == false ? vinNickname! : vin)
    }

    static func == (lhs: LMVehicle, rhs: LMVehicle) -> Bool { lhs.vin == rhs.vin }
    func hash(into hasher: inout Hasher) { hasher.combine(vin) }
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
