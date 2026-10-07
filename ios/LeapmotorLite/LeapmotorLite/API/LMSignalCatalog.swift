//
//  LMSignalCatalog.swift
//  LeapmotorLite
//
//  signalMap 的 id → 语义 知识库。
//
//  ★ 这里的每一条都必须有证据，禁止「看着像就写」。
//
//  证据等级（Confidence）：
//    .confirmed —— 多快照线性回归 / 官方接口交叉印证 / 与用户截图逐字对上
//    .observed  —— 抓包里有稳定值且量纲/取值范围自洽，但只有一份证据
//    .unknown   —— 只知道「这个 id 存在、会变」，语义未定
//
//  ── 已确认结论的证据链（2026-10-07 复算）────────────────────────────
//
//  51 个 signalMap 快照（har_appgw / har_refresh / har_stream）按时间排序后：
//
//    时间      SOC(100003)  1204  3257  3260  2188   1200   2183
//    05:23:32    32.9        33   236   190   190    645    23.0
//    05:25:21    33.1        33   237   190   190    645    23.0
//    06:04:38    36.6        37   262   211   211    605    23.0
//    06:05:52    36.7        37   263   211   211    605    23.0
//
//    · 3257 / 100003 = 7.166 … 7.174    → 满电 ≈ 717 km（严格线性）
//    · 3260 / 100003 = 5.775 … 5.750    → 满电 ≈ 577 km（严格线性）
//    · 2188 == 3260 逐帧相等              → 同一物理量的冗余信号
//    · 1204 == round(100003) 全部吻合      → 取整后的 SOC
//
//  ★ 1200 = 剩余充电时间（分钟）—— 两次独立推算互相印证：
//      从 33.1% 到 100% 需 645 min → 578.5 min/%
//      从 36.6% 到 100% 需 605 min → 572.6 min/%
//      两者差 1%，且同一时段实测 SOC 增速 5.12 %/h 与 6.2 %/h 同量级。
//      （更关键的旁证：抓包时刻落在 commonConfig 的预约充电窗口
//        10:00–15:00 内，SOC 确实在涨，车是在充电的。）
//
//  ★ 定位：2190/2191 与 3725/3724 是同一位置的两次采样，差在末位小数。
//      2190=31.801201 2191=117.342718
//      3725=31.801307 3724=117.342719
//      注意 3725/3724 的顺序是「纬度在前」但 id 是反的 —— 3724 是经度。
//      例：31.80 N / 117.34 E ≈ 安徽合肥。两组都落在同一街区，互为校验。
//
//  ── 仍然待定的（不要写进派生属性，只放进浏览器让用户实测）────────────
//
//    · 1177 = 736.1…737.0  —— 停车充电期间缓变，与 SOC 不成比例。
//        候选① 充电功率 ×100 W（= 7.37 kW，7kW 交流桩的典型值）
//        候选② 电池电压 V（但 +3.7% SOC 只涨 0.3 V，与 CC 充电不符）
//        倾向①。用户在「充电中 / 未充电」各抓一次即可判定。
//    · 1178 = -8.4…-3.7    —— 负值、小幅抖动。候选：充电电流(A) 的负向读数。
//    · 2653 / 2646 / 2660 / 2667 —— 与 3260 同值（239/233），续航家族但不知区别。
//    · 644 / 645 / 865 / 866 —— 四路同时在 0 与 21 之间跳（疑似四区空调设定温度）。
//    · 47 / 48 / 49 / 50 —— 四路布尔（1,1,0,0），疑似四门或四窗开合状态。
//    · 10707 = -6，2183 = 23.0（电池温度已按量纲判断，10707 更可能是设定温度）。
//
import Foundation

// MARK: - 置信度

enum LMConfidence: String, CaseIterable, Identifiable {
    case confirmed
    case observed
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .confirmed: return "已确认"
        case .observed:  return "观察"
        case .unknown:   return "待定"
        }
    }

    var badge: String {
        switch self {
        case .confirmed: return "✅"
        case .observed:  return "🟡"
        case .unknown:   return "❓"
        }
    }

    /// 排序权重：已确认在前
    var order: Int {
        switch self {
        case .confirmed: return 0
        case .observed:  return 1
        case .unknown:   return 2
        }
    }
}

// MARK: - 分类

enum LMSignalCategory: String, CaseIterable, Identifiable, Equatable {
    case battery  = "电池 / 充电"
    case range    = "续航"
    case location = "定位"
    case body     = "车身状态"
    case climate  = "温度 / 空调"
    case meta     = "时间 / 元数据"
    case other    = "其他"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .battery:  return "bolt.fill"
        case .range:    return "road.lanes"
        case .location: return "location.fill"
        case .body:     return "car.fill"
        case .climate:  return "thermometer.medium"
        case .meta:     return "clock"
        case .other:    return "questionmark.circle"
        }
    }
}

// MARK: - 一条信号

struct LMSignalRef: Identifiable, Hashable {
    /// signalMap 的 key，例如 "100003"
    let id: String
    let name: String
    /// 单位；纯枚举/布尔留空
    let unit: String
    let category: LMSignalCategory
    let confidence: LMConfidence
    /// 判定依据 / 待确认点。给别人看的一行说明，别写废话。
    let note: String

    init(_ id: String,
         _ name: String,
         unit: String = "",
         category: LMSignalCategory,
         confidence: LMConfidence,
         note: String = "") {
        self.id = id
        self.name = name
        self.unit = unit
        self.category = category
        self.confidence = confidence
        self.note = note
    }
}

// MARK: - 知识库

enum LMSignalCatalog {

    /// 人工整理过的信号（有名字的）
    static let refs: [LMSignalRef] = [

        // ── 电池 / 充电 ───────────────────────────────────────────────
        .init("100003", "电池 SOC（原始）", unit: "%",
              category: .battery, confidence: .confirmed,
              note: "BMS 上报，带 1 位小数，最准。UI 主用这个。"),
        .init("1204", "电池 SOC（取整）", unit: "%",
              category: .battery, confidence: .confirmed,
              note: "逐帧等于 round(100003)，是同一个值的整数版。"),
        .init("1200", "剩余充电时间", unit: "min",
              category: .battery, confidence: .confirmed,
              note: "两次独立推算 578.5 / 572.6 min/% 吻合，误差 1%。未充电时为 0。"),
        .init("2183", "电池温度", unit: "℃",
              category: .battery, confidence: .observed,
              note: "实测恒为 23.0，量纲与车内温度(1349=29.5)区分得开。"),
        .init("1177", "疑似充电功率", unit: "×100 W",
              category: .battery, confidence: .unknown,
              note: "736.1~737.0 → 7.37 kW，像 7kW 交流桩。也可能读作电池电压，未定。"),
        .init("1178", "疑似充电电流", unit: "A",
              category: .battery, confidence: .unknown,
              note: "-8.4~-3.7 小幅抖动，负号含义未定。"),

        // ── 续航 ─────────────────────────────────────────────────────
        .init("3257", "剩余续航（标准 A）", unit: "km",
              category: .range, confidence: .confirmed,
              note: "3257/100003 = 7.17 严格线性 → 满电约 717 km。首页主显示用这个。"),
        .init("3260", "剩余续航（标准 B）", unit: "km",
              category: .range, confidence: .confirmed,
              note: "3260/100003 = 5.77 严格线性 → 满电约 577 km。两套工况标准。"),
        .init("2188", "剩余续航（冗余副本）", unit: "km",
              category: .range, confidence: .confirmed,
              note: "逐帧等于 3260，同一物理量的冗余上报。"),
        .init("2653", "续航家族（未区分）", unit: "km",
              category: .range, confidence: .unknown,
              note: "停车期恒 239，与 3260 同值。跟 2646/2660/2667 是同一族。"),
        .init("2646", "续航家族（未区分）", unit: "km",
              category: .range, confidence: .unknown,
              note: "停车期恒 239。"),
        .init("2660", "续航家族（未区分）", unit: "km",
              category: .range, confidence: .unknown,
              note: "停车期恒 239。"),
        .init("2667", "续航家族（未区分）", unit: "km",
              category: .range, confidence: .unknown,
              note: "停车期恒 233，比上面几个低 6 km。"),

        // ── 定位 ─────────────────────────────────────────────────────
        .init("2190", "纬度", unit: "°",
              category: .location, confidence: .confirmed,
              note: "31.801201。定位主用这一组。"),
        .init("2191", "经度", unit: "°",
              category: .location, confidence: .confirmed,
              note: "117.342718。"),
        .init("3725", "纬度（高精度）", unit: "°",
              category: .location, confidence: .confirmed,
              note: "31.801307，与 2190 差在末位小数，互为校验。"),
        .init("3724", "经度（高精度）", unit: "°",
              category: .location, confidence: .confirmed,
              note: "117.342719。★ 注意 3724/3725 是「经度在前」，别跟 2190/2191 记混。"),

        // ── 车身状态 ─────────────────────────────────────────────────
        .init("1298", "车门锁", unit: "",
              category: .body, confidence: .confirmed,
              note: "1 = 已上锁，0 = 未上锁。与 3262 冗余。"),
        .init("3262", "车门锁（冗余）", unit: "",
              category: .body, confidence: .confirmed,
              note: "与 1298 同步。两个都读不到才显示「锁态未知」。"),
        .init("1318", "总里程", unit: "km",
              category: .body, confidence: .confirmed,
              note: "实测 1909，与用户截图逐字一致。"),
        .init("47", "状态位 47", unit: "",
              category: .body, confidence: .unknown,
              note: "47/48/49/50 实测 1,1,0,0，疑似四门或四窗开合。"),
        .init("48", "状态位 48", unit: "",
              category: .body, confidence: .unknown, note: "见 47。"),
        .init("49", "状态位 49", unit: "",
              category: .body, confidence: .unknown, note: "见 47。"),
        .init("50", "状态位 50", unit: "",
              category: .body, confidence: .unknown, note: "见 47。"),
        .init("94", "状态位 94", unit: "",
              category: .body, confidence: .unknown,
              note: "在 0/1 之间变过，疑似某个总开关状态。"),
        .init("1255", "状态位 1255", unit: "",
              category: .body, confidence: .unknown,
              note: "取过 0 / 1 / 2，疑似档位或充电枪状态。"),

        // ── 温度 / 空调 ───────────────────────────────────────────────
        .init("1349", "车内温度", unit: "℃",
              category: .climate, confidence: .confirmed,
              note: "实测 29.5。"),
        .init("10707", "疑似设定温度", unit: "℃",
              category: .climate, confidence: .unknown,
              note: "实测 -6。负数不像环境温度，更像「相对设定值」或偏移量。"),
        .init("644", "疑似空调设定 1", unit: "℃",
              category: .climate, confidence: .unknown,
              note: "644/645/865/866 四路同时在 0 与 21 之间跳。"),
        .init("645", "疑似空调设定 2", unit: "℃",
              category: .climate, confidence: .unknown, note: "见 644。"),
        .init("865", "疑似空调设定 3", unit: "℃",
              category: .climate, confidence: .unknown, note: "见 644。"),
        .init("866", "疑似空调设定 4", unit: "℃",
              category: .climate, confidence: .unknown, note: "见 644。"),

        // ── 时间 / 元数据 ─────────────────────────────────────────────
        .init("1", "采集时间戳", unit: "ms",
              category: .meta, confidence: .confirmed,
              note: "13 位毫秒。用它算「定位/车况是几分钟前采集的」。"),
        .init("sts", "服务端时间戳", unit: "ms",
              category: .meta, confidence: .confirmed,
              note: "13 位毫秒，比 1 略晚几十到几百毫秒。"),
        .init("2", "元数据 2", unit: "",
              category: .meta, confidence: .unknown, note: "恒 0.0。"),
        .init("3", "元数据 3", unit: "",
              category: .meta, confidence: .unknown, note: "恒 0.0。"),
    ]

    /// id → 定义
    static let byId: [String: LMSignalRef] = {
        var m: [String: LMSignalRef] = [:]
        for r in refs { m[r.id] = r }
        return m
    }()

    static func ref(_ id: String) -> LMSignalRef? { byId[id] }

    /// 有名字的 id 集合
    static var knownIds: Set<String> { Set(byId.keys) }

    /// 按分类分组（保持 LMSignalCategory.allCases 顺序）
    ///
    /// ★ 刻意返回结构体数组而不是元组数组：`ForEach` 的 `id:` 需要 key path，
    ///   而 Swift 的 key path **不能指向元组成员**（`\.0` 会报
    ///   "key path cannot refer to tuple element"）。上一轮已经被这个坑烧过一次。
    static func grouped() -> [LMGroup] {
        LMSignalCategory.allCases.compactMap { cat in
            let items = refs
                .filter { $0.category == cat }
                .sorted { a, b in
                    if a.confidence.order != b.confidence.order {
                        return a.confidence.order < b.confidence.order
                    }
                    return numeric(a.id) < numeric(b.id)
                }
            return items.isEmpty ? nil : LMGroup(category: cat, refs: items)
        }
    }

    /// 一个分类分组
    struct LMGroup: Identifiable {
        let category: LMSignalCategory
        let refs: [LMSignalRef]
        var id: String { category.rawValue }
    }

    /// 数字 id 排序用；"sts" 这种非数字排到最后
    static func numeric(_ id: String) -> Int { Int(id) ?? Int.max }
}
