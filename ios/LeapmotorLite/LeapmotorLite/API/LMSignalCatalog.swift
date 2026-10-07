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
//  ★ 1200 —— **不是「剩余充电时间」，而是「预计充到目标电量还要多久」**
//      （2026-10-07 修正。老结论把它当充电状态位用，导致「没充电却显示充电中」。）
//
//      它是**纯 SOC 的线性投影**，跟当前充不充电无关：
//          1200 ≈ round(r × (目标电量 − SOC))，目标电量 = config["3"].percent = 90
//
//      四个实测点（含一个**未充电**的点）：
//          SOC 33.0 → (90−33.0) × r = 645   实测 645   →  r = 11.32
//          SOC 33.1 → (90−33.1) × r = 645   实测 645   →  r = 11.34
//          SOC 36.6 → (90−36.6) × r = 605   实测 605   →  r = 11.33
//          SOC 41.4 → (90−41.4) × r = 550   实测 550   →  r = 11.32（此时 1178 = 0，未充电）
//      速率离散度 0.18%。
//
//      ★ 非循环验证：把「目标电量」当未知量做最小二乘自由拟合，
//        最优解落在 **89.8%** —— 和配置里的 90 独立吻合。
//        作为对比，老假设「充到 100%」的速率离散度是 2.72%（9.39 ~ 9.64），
//        一眼就能看出模型不对，当时却当成「误差 1%」放过去了。
//
//      ★ 决定性事实：18:02 那次快照车**没在充电**（1178 = 0.0），1200 仍然是 550。
//        投影值不可能同时是状态位 —— 这就是误报的根因。
//
//  ★ 充电状态：五路标志位 + 充电电流，来自「充电中 / 未充电」两张快照的逐信号 diff
//
//          信号          充电中(SOC 33.0/33.1)   未充电(SOC 41.4)
//          1178 充电电流      −8.299 / −8.399        0.0
//          100004                    1                0
//          1149                      1                0
//          1257                      1                0
//          3636                      1                0
//          3722                      1                0
//      五路同步翻转；其中 1178 有物理意义（没电流就充不进电）。
//      判据取「多数票 ≥ 3」或「1178 非零」，见 LMClient.chargeState。
//      ⚠️ 1255 / 1480 / 3638 在两张快照里取值不变（2 / 1 / 1），**不能**用来判充电。
//
//  ★ 定位：2190/2191 与 3725/3724 是同一位置的两次采样，差在末位小数。
//      2190=31.801201 2191=117.342718
//      3725=31.801307 3724=117.342719
//      注意 3725/3724 的顺序是「纬度在前」但 id 是反的 —— 3724 是经度。
//      例：31.80 N / 117.34 E ≈ 安徽合肥。两组都落在同一街区，互为校验。
//
//  ⚠️ **坐标系未定**（2026-10-07 新增，用户报「定位偏」）：
//      这两组值属于 WGS-84 还是 GCJ-02 **没有证据能定**。
//      官方 App（1.22.68）里两个方向的换算**都实现了**：
//        wgs84ToGcj02: / gcj02ToWgs84: / transformLat:bdLon: / outOfChina:bdLon:
//        ap_wgs2gcj（AMap 内部）/ 6378245.0（GCJ 长半轴，二进制里唯一一处）
//        setExternalLocation:isAMapCoordinate: ← 灌外部坐标要显式声明系别
//      官方地图用的是高德（PodsDummy_Pods_AMapLocationKit / MAMapView）。
//      合肥实测点按 WGS→GCJ 换算偏移 **574 米**，正是「偏到隔壁小区」的量级。
//      → 所以别猜：坐标换算放在 API/LMCoordinate.swift，由 LMCarCoordFix 三选一，
//        用户在 LocationView 里站到车旁一眼就能定下来。
//
//  ── 仍然待定的（不要写进派生属性，只放进浏览器让用户实测）────────────
//
//    · 1177 —— **已推翻「疑似充电功率」**：未充电时 732.7（不为 0）、
//        充电时 736.7。是功率的话没充电时必须掉到 0，所以它属于**电压类**。
//        具体是电池包电压还是充电机输出电压未定。
//    · 2653 / 2646 / 2660 / 2667 —— 与 3260 同值（239/233），续航家族但不知区别。
//    · 644 / 645 / 865 / 866 —— 四路同时在 0 与 21 之间跳（疑似四区空调设定温度）。
//    · 47 / 48 / 49 / 50 —— 四路布尔（1,1,0,0），疑似四门或四窗开合状态。
//    · 10707 = -6，2183 = 23.0（电池温度已按量纲判断，10707 更可能是设定温度）。
//    · 1624 / 1941 / 1944 / 1182 / 1257 等在两张快照间变过，但只差 1~12，
//        与充电无因果关系，暂不标注。
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
        .init("1200", "预计充至目标电量的时间", unit: "min",
              category: .battery, confidence: .confirmed,
              note: "≈ round(11.33 × (目标电量90 − SOC))，四个实测点离散度 0.18%。"
                  + "★ 是纯 SOC 投影，与是否在充电无关 —— 未充电时照样是 550。不能当充电状态位。"),
        .init("2183", "电池温度", unit: "℃",
              category: .battery, confidence: .observed,
              note: "实测恒为 23.0，量纲与车内温度(1349=29.5)区分得开。"),
        .init("1177", "电池/母线电压（疑似）", unit: "V",
              category: .battery, confidence: .observed,
              note: "未充电 732.7、充电 736.7。★ 已推翻旧的「充电功率」猜想："
                  + "没充电时它不为 0，功率必须为 0。是电压类量已确定，具体是哪一路未定。"),
        .init("1178", "充电电流", unit: "A",
              category: .battery, confidence: .confirmed,
              note: "充电时 −8.299 / −8.399（负号含义未定），未充电时 0.0。"
                  + "★ 唯一带物理意义的充电证据。"),

        // ── 充电状态标志位（来自「充电中 / 未充电」两张快照的逐信号 diff）────
        .init("100004", "充电状态位（疑似）", unit: "",
              category: .battery, confidence: .observed,
              note: "充电时 1、未充电时 0。与 100003(SOC) 同族，位置最像「充电中」标志。"),
        .init("1149", "充电状态位 1149", unit: "",
              category: .battery, confidence: .observed,
              note: "充电时 1、未充电时 0。"),
        .init("1257", "充电状态位 1257", unit: "",
              category: .battery, confidence: .observed,
              note: "充电时 1、未充电时 0。"),
        .init("3636", "充电状态位 3636", unit: "",
              category: .battery, confidence: .observed,
              note: "充电时 1、未充电时 0。注意别和 3638 混 —— 3638 两张快照都是 1，没有区分度。"),
        .init("3722", "充电状态位 3722", unit: "",
              category: .battery, confidence: .observed,
              note: "充电时 1、未充电时 0。"),
        .init("1255", "状态位 1255（无区分度）", unit: "",
              category: .battery, confidence: .unknown,
              note: "两张快照都是 2。★ 不能用来判充电，老注释曾把它列为候选。"),
        .init("1480", "状态位 1480（无区分度）", unit: "",
              category: .battery, confidence: .unknown,
              note: "两张快照都是 1。不能用来判充电。"),

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
