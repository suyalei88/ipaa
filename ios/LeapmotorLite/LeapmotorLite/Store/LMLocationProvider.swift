//
//  LMLocationProvider.swift
//  LeapmotorLite
//
//  本机定位（只为了算「车辆离我多远」）。
//
//  为什么单独搞一个类、而不是在 View 里直接用 CLLocationManager：
//    · CLLocationManager 的 delegate 回调不在主线程，直接改 @Published 会
//      触发 SwiftUI 的「Publishing changes from background threads」告警；
//    · 授权状态有 5 种，散在 View 里很容易漏掉 .denied / .restricted，
//      结果就是「点了没反应」。
//  这里全部收敛：回调统一回主线程，状态用一个枚举给 UI。
//
//  ⚠️ 这个类**不参与任何车控逻辑**。拿不到本机位置只影响「距我多远」这一行字，
//     绝不能让它影响车况/定位主流程。
//
import Foundation
import CoreLocation

/// 本机定位的可用状态（给 UI 直接显示）
enum LMMeState: Equatable {
    /// 还没问过
    case unknown
    /// 已授权，正在取点
    case locating
    /// 已授权且有坐标
    case ready
    /// 用户拒绝了
    case denied
    /// 系统层面受限（家长控制等）
    case restricted
    /// 已授权但取点失败（室内 / 无信号）
    case failed

    var text: String {
        switch self {
        case .unknown:    return "未请求定位权限"
        case .locating:   return "正在获取你的位置…"
        case .ready:      return "已获取"
        case .denied:     return "你拒绝了定位权限"
        case .restricted: return "系统限制了定位"
        case .failed:     return "定位失败（室内或信号弱）"
        }
    }
}

final class LMLocationProvider: NSObject, ObservableObject {

    /// 本机坐标（WGS-84）
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var state: LMMeState = .unknown
    /// 水平精度（米），用来判断这个点靠不靠谱
    @Published private(set) var accuracy: Double?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        applyAuthorization(manager.authorizationStatus, requestIfNeeded: false)
    }

    /// 用户点「获取我的位置」时调
    func request() {
        let s = manager.authorizationStatus
        if s == .notDetermined {
            setState(.locating)
            manager.requestWhenInUseAuthorization()
        } else {
            applyAuthorization(s, requestIfNeeded: true)
        }
    }

    /// 把 CLAuthorizationStatus 翻译成 LMMeState，并决定要不要取点
    private func applyAuthorization(_ s: CLAuthorizationStatus, requestIfNeeded: Bool) {
        switch s {
        case .notDetermined:
            setState(.unknown)
        case .denied:
            setState(.denied)
        case .restricted:
            setState(.restricted)
        case .authorizedAlways, .authorizedWhenInUse:
            if requestIfNeeded || coordinate == nil {
                setState(.locating)
                manager.requestLocation()
            } else {
                setState(.ready)
            }
        @unknown default:
            setState(.unknown)
        }
    }

    /// 所有 @Published 的写入都从主线程走
    private func setState(_ s: LMMeState) {
        if Thread.isMainThread {
            state = s
        } else {
            DispatchQueue.main.async { [weak self] in self?.state = s }
        }
    }
}

extension LMLocationProvider: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            self?.applyAuthorization(s, requestIfNeeded: true)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let c = loc.coordinate
        let acc = loc.horizontalAccuracy
        DispatchQueue.main.async { [weak self] in
            self?.coordinate = c
            self?.accuracy = acc
            self?.state = .ready
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 只把状态标成失败，不弹错、不打断 —— 「距我多远」拿不到就算了
        setState(.failed)
    }
}
