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

struct LMCommonConfigData: Decodable {
    let vin: String?
    let isSupportBigModel: Int?
    let privacyGPS: Int?
    let privacyData: Int?
    let parkingAssistConfig: String?
    let isAiParking: Bool?
}
