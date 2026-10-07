//
//  LMCoordinate.swift
//  LeapmotorLite
//
//  坐标系换算：WGS-84（GPS 原始）↔ GCJ-02（国测局 / 火星坐标）。
//
//  ── 为什么需要这个文件 ──────────────────────────────────────────────
//  车辆定位「偏到隔壁小区」是这类 App 最常见的坑，偏移量正好就是下面这个
//  WGS→GCJ 差值。用合肥实测点 (31.801201, 117.342718) 算：
//      Δlat = -0.001882   Δlng = +0.005655   ≈ 575 米
//
//  ── 为什么不能直接写死一个方向 ──────────────────────────────────────
//  真正的未知量只有一个：**车机上报的坐标系是哪一系**。
//    · 车机 T-Box 的 GPS 模块原生输出 WGS-84；
//    · 但国内不少车企在云端就已经加过偏移（GCJ-02），好让 App 直接画到高德上。
//
//  官方 App（零跑 1.22.68）里**两个方向都实现了**，无法据此判定它把云端值
//  当哪一系用。已确认的符号（全部来自官方 Mach-O 204,405,920 B 的字符串池）：
//      wgs84ToGcj02:  gcj02ToWgs84:  gcj02ToBd09:  wgs84ToBd09:
//      bd09ToGcj02:   bd09ToWgs84:   transformLat:bdLon:  outOfChina:bdLon:
//      ap_wgs2gcj（AMap 内部）    6378245.0（GCJ 长半轴，二进制里唯一一处）
//      setExternalLocation:isAMapCoordinate:   ← 灌外部坐标时要显式声明系别
//      tranfromAMapLocation:fromCoordinateType:toCoordinateType:
//      coordinateType / amapCoordinate2D / hadCacheAmapCoordinate2D
//      PodsDummy_Pods_AMapLocationKit / MAMapView（官方用高德）
//
//  ⚠️ 所以这里**不做假设**：两个方向都实现，交给 `LMCarCoordFix` 选择，
//     用户站在车旁一眼就能定下来（见 LocationView 的「坐标校正」卡片）。
//     早期版本在注释里写死「车机上报的是 WGS-84」，那是**没有证据的断言**，
//     已经删掉。
//
import Foundation
import CoreLocation

/// 坐标系。中国境内地图（Apple 地图 / 高德 / 腾讯）用 GCJ-02；GPS 原始输出是 WGS-84。
enum LMCoordSystem: String, CaseIterable, Identifiable {
    case wgs84
    case gcj02

    var id: String { rawValue }

    var short: String {
        switch self {
        case .wgs84: return "WGS-84"
        case .gcj02: return "GCJ-02"
        }
    }

    var long: String {
        switch self {
        case .wgs84: return "WGS-84（GPS 原始坐标）"
        case .gcj02: return "GCJ-02（国测局 / 火星坐标）"
        }
    }
}

/// 车机坐标要不要校正、往哪个方向校正。
///
/// 三个选项穷举了「车机坐标系 vs 地图坐标系」的全部相对关系，
/// 所以不管官方云端给的是哪一系，总有一个是对的。
enum LMCarCoordFix: String, CaseIterable, Identifiable {
    /// 车机坐标直接当地图坐标用（两者同系，不需要动）
    case none
    /// 车机给 WGS-84、地图要 GCJ-02 → 加偏移
    case wgs84ToGcj02
    /// 车机给 GCJ-02、地图要 WGS-84 → 去偏移
    case gcj02ToWgs84

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:         return "不校正"
        case .wgs84ToGcj02: return "WGS-84 → GCJ-02"
        case .gcj02ToWgs84: return "GCJ-02 → WGS-84"
        }
    }

    var detail: String {
        switch self {
        case .none:
            return "车机给的坐标系和地图要的一致，原样落点。"
        case .wgs84ToGcj02:
            return "车机给的是 GPS 原始坐标，地图要火星坐标 —— 加偏移。"
        case .gcj02ToWgs84:
            return "车机给的已经是火星坐标，地图要 GPS 原始坐标 —— 去偏移。"
        }
    }

    /// 把车机原始坐标换算成「可以直接交给地图」的坐标。
    func apply(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        switch self {
        case .none:
            return c
        case .wgs84ToGcj02:
            return LMCoord.wgs84ToGcj02(c)
        case .gcj02ToWgs84:
            return LMCoord.gcj02ToWgs84(c)
        }
    }

    /// 换算之后坐标属于哪一系。`.none` 因为不知道车机给的是哪系，返回 nil。
    var outputSystem: LMCoordSystem? {
        switch self {
        case .none:         return nil
        case .wgs84ToGcj02: return .gcj02
        case .gcj02ToWgs84: return .wgs84
        }
    }

    /// 把车机原始坐标换算成 **WGS-84**。
    ///
    /// 用在两处：
    ///   1. 交给 Apple 的 CLGeocoder —— 它属于 CoreLocation，和 CLLocationManager
    ///      一样收 WGS-84；
    ///   2. 算「车辆离我多远」—— 本机坐标必然是 WGS-84（CoreLocation 给的），
    ///      要跟车机坐标比距离，两者必须先在同一个坐标系里。
    ///
    /// ⚠️ 算距离时**不能**拿地图上那两个换算后的点去量：地图换算是显示问题，
    ///    换算完两个点已经不在同一物理坐标系里了，量出来的数会白差几百米。
    func toWgs84(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        switch self {
        case .none, .wgs84ToGcj02:
            return c
        case .gcj02ToWgs84:
            return LMCoord.gcj02ToWgs84(c)
        }
    }

    /// 交给高德 URI（uri.amap.com）时该带的 `coordinate=` 参数。
    ///
    /// `.none` 时我们并不知道手上这个值是哪一系，索性不带这个参数，
    /// 让高德按它自己的默认值（gcj02）处理，别替用户瞎声明。
    var amapCoordinateParam: String? {
        switch self {
        case .none:         return nil
        case .wgs84ToGcj02: return "gcj02"
        case .gcj02ToWgs84: return "wgs84"
        }
    }
}

/// 校正选项的本地持久化。
///
/// ★ key 用自己的 `lm3rd.` 前缀，绝不碰官方 App 的 UserDefaults
///   （官方的是 `LMVBLE*` / 自己那一套，改错了会污染官方 App 的行为）。
enum LMCarCoordFixStore {
    private static let storageKey = "lm3rd.loc.carFix"

    /// 默认值。用户报「位置不对」时用的就是 `.none`（等于完全不做换算），
    /// 而车机 GPS 原生就是 WGS-84、国内地图要 GCJ-02，所以默认给这个方向。
    /// 若换成它反而更偏，切到第三个选项即可 —— 三个选项穷举了全部可能。
    static let fallback: LMCarCoordFix = .wgs84ToGcj02

    static func load() -> LMCarCoordFix {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let v = LMCarCoordFix(rawValue: raw) else {
            return fallback
        }
        return v
    }

    static func save(_ v: LMCarCoordFix) {
        UserDefaults.standard.set(v.rawValue, forKey: storageKey)
    }
}

/// GCJ-02 换算本体。公式是国测局公开的那一套，网上有大量同构实现。
enum LMCoord {

    /// 克拉索夫斯基椭球长半轴（GCJ-02 算法规定值）
    private static let a = 6378245.0
    /// 第一偏心率的平方
    private static let ee = 0.00669342162296594323

    /// 是否在中国境外。GCJ-02 只在国内生效，境外必须原样返回，
    /// 否则会把境外的点也推走几百米。
    static func outOfChina(lat: Double, lng: Double) -> Bool {
        if lng < 72.004 || lng > 137.8347 { return true }
        if lat < 0.8293 || lat > 55.8271 { return true }
        return false
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * Double.pi) + 40.0 * sin(y / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * Double.pi) + 320.0 * sin(y * Double.pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLng(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * Double.pi) + 40.0 * sin(x / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * Double.pi) + 300.0 * sin(x / 30.0 * Double.pi)) * 2.0 / 3.0
        return ret
    }

    /// WGS-84 → GCJ-02（加偏移）
    static func wgs84ToGcj02(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        wgs84ToGcj02(lat: c.latitude, lng: c.longitude)
    }

    /// WGS-84 → GCJ-02（加偏移）
    static func wgs84ToGcj02(lat: Double, lng: Double) -> CLLocationCoordinate2D {
        if outOfChina(lat: lat, lng: lng) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        var dLat = transformLat(lng - 105.0, lat - 35.0)
        var dLng = transformLng(lng - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * Double.pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Double.pi)
        dLng = (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * Double.pi)
        return CLLocationCoordinate2D(latitude: lat + dLat, longitude: lng + dLng)
    }

    /// GCJ-02 → WGS-84（去偏移）。
    ///
    /// GCJ-02 是**单向**的（偏移量里带三角函数），业界统一用迭代逼近：
    /// 反复「按当前估计值正算一次偏移、把误差减回去」。这里跑 6 轮并在
    /// 残差 < 1e-9 度（≈ 0.1 毫米）时提前退出，远超 GPS 本身精度。
    static func gcj02ToWgs84(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        gcj02ToWgs84(lat: c.latitude, lng: c.longitude)
    }

    /// GCJ-02 → WGS-84（去偏移）
    static func gcj02ToWgs84(lat: Double, lng: Double) -> CLLocationCoordinate2D {
        if outOfChina(lat: lat, lng: lng) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        var wLat = lat
        var wLng = lng
        for _ in 0..<6 {
            let g = wgs84ToGcj02(lat: wLat, lng: wLng)
            let errLat = g.latitude - lat
            let errLng = g.longitude - lng
            if abs(errLat) < 1e-9 && abs(errLng) < 1e-9 { break }
            wLat -= errLat
            wLng -= errLng
        }
        return CLLocationCoordinate2D(latitude: wLat, longitude: wLng)
    }

    /// 两点直线距离（米）
    static func distance(_ p: CLLocationCoordinate2D, _ q: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: p.latitude, longitude: p.longitude)
            .distance(from: CLLocation(latitude: q.latitude, longitude: q.longitude))
    }

    // MARK: - 内置自检

    /// 自检结果项。
    ///
    /// ★ 用结构体而不是元组：元组成员没有 key path，
    ///   一旦要在 ForEach 里渲染就会报 `key path cannot refer to tuple element`。
    ///   这个坑在本仓库踩过好几次（BLE 那批代码踩了两次）。
    struct Check: Identifiable {
        let id = UUID()
        let name: String
        let passed: Bool
        let detail: String
    }

    /// 坐标换算自检。全部通过时返回的每一项 `passed` 都是 true。
    ///
    /// 参考向量由 Python 独立实现算出（`client/test_coord_vectors.py`），
    /// 两边必须逐位一致 —— 不一致就说明常量或公式被改坏了。
    static func selfCheck() -> [Check] {
        var out: [Check] = []

        // 1) 合肥实测点：车机上报的原始值当 WGS-84 转 GCJ-02
        let hefei = CLLocationCoordinate2D(latitude: 31.801201, longitude: 117.342718)
        let expectLat = 31.79931886581182
        let expectLng = 117.34837296266286
        let got = wgs84ToGcj02(hefei)
        let ok1 = abs(got.latitude - expectLat) < 1e-9 && abs(got.longitude - expectLng) < 1e-9
        let moved = distance(hefei, got)
        out.append(Check(
            name: "WGS-84 → GCJ-02（合肥实测点，偏移应 ≈574 米）",
            passed: ok1,
            detail: ok1
                ? String(format: "偏移 %.1f 米，与参考向量逐位一致", moved)
                : String(format: "得到 %.12f, %.12f；应为 %.12f, %.12f",
                         got.latitude, got.longitude, expectLat, expectLng)))

        // 2) 迭代反解精度
        let back = gcj02ToWgs84(got)
        let residual = distance(hefei, back)
        out.append(Check(
            name: "GCJ-02 → WGS-84 迭代反解（往返残差应 < 1 毫米）",
            passed: residual < 0.001,
            detail: String(format: "往返残差 %.6f 米", residual)))

        // 3) 境外不偏移
        let tokyo = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        let ny = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let t = wgs84ToGcj02(tokyo)
        let n = wgs84ToGcj02(ny)
        let ok3 = t.latitude == tokyo.latitude && t.longitude == tokyo.longitude
            && n.latitude == ny.latitude && n.longitude == ny.longitude
        out.append(Check(
            name: "境外坐标不做偏移（GCJ-02 只在国内生效）",
            passed: ok3,
            detail: ok3
                ? "东京 / 纽约 原样返回"
                : String(format: "东京被推到了 %.6f, %.6f", t.latitude, t.longitude)))

        // 4) 三个校正选项的语义：outputSystem 与 apply 必须自洽
        let f1 = LMCarCoordFix.wgs84ToGcj02.apply(hefei)
        let f2 = LMCarCoordFix.gcj02ToWgs84.apply(hefei)
        let f3 = LMCarCoordFix.none.apply(hefei)
        let ok4 = distance(f3, hefei) < 0.001
            && distance(f1, hefei) > 100
            && distance(f2, hefei) > 100
            && LMCarCoordFix.none.outputSystem == nil
            && LMCarCoordFix.wgs84ToGcj02.outputSystem == .gcj02
            && LMCarCoordFix.gcj02ToWgs84.outputSystem == .wgs84
        out.append(Check(
            name: "三个校正选项的语义自洽（.none 原样、另两个各偏约 574 米）",
            passed: ok4,
            detail: String(format: "none %.3f 米 / wgs→gcj %.1f 米 / gcj→wgs %.1f 米",
                           distance(f3, hefei), distance(f1, hefei), distance(f2, hefei))))

        return out
    }
}
