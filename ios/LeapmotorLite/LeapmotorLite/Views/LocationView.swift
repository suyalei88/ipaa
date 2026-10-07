//
//  LocationView.swift
//  LeapmotorLite
//
//  车辆定位：地图打点 + 中文地址 + 一键导航。
//
//  数据来源（按可信度排序）：
//    1. signalMap 的 2190/2191（纬度/经度）—— 已确认
//    2. signalMap 的 3725/3724 —— 同一位置的第二次采样，用作交叉校验
//    3. /carownerservice/v3/api/vehicleinfo/parking/query —— 响应结构未知，
//       只在「诊断」页做探测，本页不依赖它
//
//  ★ 坐标系：车机上报的是 WGS-84 原始 GPS。
//    · 跳高德必须带 `coordinate=wgs84`，否则会被当成 GCJ-02 再偏一次（差几百米）；
//    · Apple 地图的 URL scheme 收的就是 WGS-84，不需要自己转换。
//    自己动手做 WGS→GCJ 偏移是常见的错误来源，这里不碰。
//
//  ⚠️ 地图上显示的是**最后一次上报**的位置，不是实时的。车停在地库/隧道里时
//     定位可能十几分钟不更新，所以这里把「采集时间」摆在显眼位置。
//
import SwiftUI
import MapKit
import CoreLocation
import UIKit
import Foundation

struct LocationView: View {
    @EnvironmentObject var client: LMClient
    @Environment(\.openURL) private var openURL

    @StateObject private var me = LMLocationProvider()

    /// 地图相机
    @State private var camera: MapCameraPosition = .automatic
    /// 逆地理编码出来的中文地址
    @State private var address: String?
    @State private var placeName: String?
    @State private var geocoding = false
    @State private var geocodeError: String?

    @State private var copied = false
    /// 每 30 秒推一次，用来刷新「x 分钟前」这种相对时间
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            mapArea
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    addressCard
                    coordinateCard
                    actionRow
                    distanceCard
                    sourceNote
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("车辆定位")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        try? await client.refreshStatus()
                        centerOnVehicle()
                        await reverseGeocode()
                    }
                } label: {
                    Image(systemName: "location.circle")
                }
                .accessibilityLabel("刷新定位")
            }
        }
        .task {
            centerOnVehicle()
            await reverseGeocode()
        }
        // 每 30 秒推一次 now，让「x 分钟前采集」跟着走。
        // ★ 不用 `let timer = Timer.publish(...).autoconnect()`：View 结构体每次
        //   重建都会生成一个新的 publisher，父视图一刷新就换一个定时器，
        //   是常见的内存/抖动来源。这里用 task 循环，跟 .lmClock 一个套路。
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                now = Date()
            }
        }
        .onChange(of: client.lastUpdate) { _, _ in
            centerOnVehicle()
            Task { await reverseGeocode() }
        }
        // 本机坐标到了就重画（多一个「我」的针）
        .onChange(of: me.coordinate?.latitude) { _, _ in
            if me.state == .ready { centerOnVehicle() }
        }
    }

    // MARK: - 地图

    @ViewBuilder
    private var mapArea: some View {
        if client.coordinate != nil {
            Map(position: $camera) {
                if let c = client.coordinate {
                    Marker("车辆", systemImage: "car.fill", coordinate: c)
                        .tint(Color.lmAccent)
                }
                if let u = me.coordinate {
                    Marker("我", systemImage: "location.fill", coordinate: u)
                        .tint(Color.lmWarn)
                }
            }
            .frame(height: 280)
            .overlay(alignment: .bottomLeading) { mapOverlayPill }
            .overlay(alignment: .bottomTrailing) { recenterButton }
        } else {
            noLocationPlaceholder
        }
    }

    private var mapOverlayPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text(ageText)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.45), in: Capsule())
        .padding(10)
    }

    private var recenterButton: some View {
        Button {
            centerOnVehicle()
        } label: {
            Image(systemName: "scope")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.lmAccent)
                .frame(width: 34, height: 34)
                .background(Color.lmCard, in: Circle())
                .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(10)
        .accessibilityLabel("回到车辆位置")
    }

    private var noLocationPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "location.slash")
                .font(.system(size: 30))
                .foregroundStyle(Color.lmWarn)
            Text("暂时没有车辆坐标")
                .font(.headline)
            Text(client.locationMayBeHidden
                 ? "车辆配置里 privacyGPS = 1，官方会隐藏位置。请到官方 App 关闭位置隐私开关后重试。"
                 : "车机可能没有上报位置（地库 / 隧道 / 刚上电）。下拉刷新车况后重试。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("刷新车况") {
                Task { try? await client.refreshStatus() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .padding(.horizontal, 24)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 地址

    private var addressCard: some View {
        LMCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.lmAccent)
                    Text("车辆位置")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if geocoding { ProgressView().scaleEffect(0.7) }
                }

                if let a = address, !a.isEmpty {
                    Text(a)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                } else if geocoding {
                    Text("正在解析地址…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let e = geocodeError {
                    Text(e)
                        .font(.callout)
                        .foregroundStyle(Color.lmWarn)
                } else if client.coordinate == nil {
                    Text("--")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("没能解析出地址（可长按复制下面的经纬度去地图里搜）")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let p = placeName, !p.isEmpty, p != address {
                    Text("地图兴趣点：\(p)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await reverseGeocode(force: true) }
                } label: {
                    Label("重新解析地址", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(client.coordinate == nil || geocoding)
            }
        }
    }

    // MARK: - 坐标

    private var coordinateCard: some View {
        LMCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "坐标（WGS-84）")

                if let c = client.coordinate {
                    coordRow("纬度", String(format: "%.6f", c.latitude), id: "2190")
                    Divider()
                    coordRow("经度", String(format: "%.6f", c.longitude), id: "2191")
                } else {
                    Text("--").font(.system(.callout, design: .monospaced))
                }

                if let diff = client.coordinateDisagreementMeters {
                    Divider()
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: diff > 50 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(diff > 50 ? Color.lmWarn : Color.lmGood)
                        Text(diff > 50
                             ? String(format: "两组坐标相差 %.0f 米 —— 有一组可能是缓存或漂移，别完全信", diff)
                             : String(format: "两组坐标（2190/2191 与 3725/3724）相差 %.0f 米，一致", diff))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("采集时间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(collectedText)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    private func coordRow(_ title: String, _ value: String, id: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
            Spacer(minLength: 8)
            Text("信号 \(id)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 操作

    private var actionRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                bigButton("高德地图", "arrow.triangle.turn.up.right.circle.fill", Color.lmAccent) {
                    if let u = amapURL { openURL(u) }
                }
                bigButton("Apple 地图", "map.fill", Color.lmTeal) {
                    if let u = appleMapsURL { openURL(u) }
                }
            }
            HStack(spacing: 10) {
                bigButton(copied ? "已复制" : "复制坐标", copied ? "checkmark.circle.fill" : "doc.on.doc",
                          Color.lmPurple) {
                    copyCoordinate()
                }
                bigButton("获取我的位置", "location.fill", Color.lmWarn) {
                    me.request()
                }
            }
        }
        .disabled(client.coordinate == nil)
    }

    private func bigButton(_ title: String, _ icon: String, _ tint: Color,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(tint.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: LMRadius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 距离我

    @ViewBuilder
    private var distanceCard: some View {
        LMCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "距我多远")

                switch me.state {
                case .ready:
                    if let d = distanceMeters {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(distanceText(d))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.lmAccent)
                            Text("直线距离")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let acc = me.accuracy {
                            Text(String(format: "你的定位精度约 ±%.0f 米", acc))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("按 40 km/h 城市均速粗估约 \(driveMinutes(d)) 分钟车程 —— 只是量感，不是导航结果。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("拿到你的位置了，但车辆坐标缺失，算不出距离。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                case .unknown, .locating:
                    Text(me.state.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("获取我的位置") { me.request() }
                        .buttonStyle(.bordered)

                case .denied:
                    Label("你拒绝了定位权限。到「设置 → 隐私与安全性 → 定位服务」里给「零跑轻控」打开即可。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.lmWarn)

                case .restricted:
                    Label("系统限制了定位（可能是屏幕使用时间/家长控制）。", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Color.lmWarn)

                case .failed:
                    Text("取不到你的位置（室内或信号弱）。多试一次，或走到窗边。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("再试一次") { me.request() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - 说明

    private var sourceNote: some View {
        Text("""
        位置来自车机上报的信号 2190/2191（另一组 3725/3724 做交叉校验），不是实时 GPS 跟踪。
        车熄火后位置可能长时间不更新；地库里通常没有定位。
        跳转高德时已按 WGS-84 标注坐标，不会出现常见的「偏到隔壁小区」问题。
        """)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    // MARK: - 计算

    private var distanceMeters: Double? {
        guard let c = client.coordinate, let u = me.coordinate else { return nil }
        return CLLocation(latitude: u.latitude, longitude: u.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    private func distanceText(_ m: Double) -> String {
        m < 1000 ? String(format: "%.0f 米", m) : String(format: "%.1f km", m / 1000)
    }

    private func driveMinutes(_ m: Double) -> Int {
        max(1, Int((m / 1000.0 / 40.0 * 60.0).rounded()))
    }

    private var ageText: String {
        guard let age = client.locationAge else { return "采集时间未知" }
        if age < 60 { return "刚刚采集" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前采集" }
        if age < 86400 { return "\(Int(age / 3600)) 小时前采集" }
        return "\(Int(age / 86400)) 天前采集"
    }

    private var collectedText: String {
        guard let d = client.collectedAt else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return "\(f.string(from: d))（\(ageText)）"
    }

    private var amapURL: URL? {
        guard let c = client.coordinate else { return nil }
        // ★ coordinate=wgs84 必须带：告诉高德这是原始 GPS 坐标，让它自己转 GCJ-02。
        //   不带的话高德会把 WGS-84 当 GCJ-02 再偏一次，落点差几百米。
        let name = (address ?? "车辆位置").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "car"
        let s = "https://uri.amap.com/marker?position=\(c.longitude),\(c.latitude)"
            + "&name=\(name)&coordinate=wgs84&callnative=1&src=leapmotorlite"
        return URL(string: s)
    }

    private var appleMapsURL: URL? {
        guard let c = client.coordinate else { return nil }
        let q = (address ?? "车辆位置").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "car"
        return URL(string: "https://maps.apple.com/?ll=\(c.latitude),\(c.longitude)&q=\(q)")
    }

    private func copyCoordinate() {
        guard let c = client.coordinate else { return }
        UIPasteboard.general.string = String(format: "%.6f,%.6f", c.latitude, c.longitude)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            copied = false
        }
    }

    private func centerOnVehicle() {
        guard let c = client.coordinate else { return }
        let region = MKCoordinateRegion(
            center: c,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005))
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .region(region)
        }
    }

    // MARK: - 逆地理编码

    /// Apple 的 CLGeocoder（内部用的就是高德数据，国内地址够准），
    /// 不依赖我们那个「参数未验证」的 /v3/geocode/regeo。
    private func reverseGeocode(force: Bool = false) async {
        guard let c = client.coordinate else {
            address = nil
            placeName = nil
            return
        }
        if !force, address != nil { return }
        geocoding = true
        geocodeError = nil
        defer { geocoding = false }

        let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(loc)
            guard let p = marks.first else {
                geocodeError = "地图服务没有返回地址"
                return
            }
            address = LocationView.composeAddress(p)
            placeName = p.name
            if address == nil, placeName == nil {
                geocodeError = "地图服务没有返回地址"
            }
        } catch {
            geocodeError = "地址解析失败：\(error.localizedDescription)"
        }
    }

    /// 把 CLPlacemark 拼成中文习惯的顺序：省 市 区 街道 门牌
    /// 相邻重复段去掉（CLGeocoder 经常把同一个名字同时塞进 locality 和 subLocality）。
    static func composeAddress(_ p: CLPlacemark) -> String? {
        var parts: [String] = []
        let candidates: [String?] = [
            p.administrativeArea,
            p.locality,
            p.subLocality,
            p.thoroughfare,
            p.subThoroughfare,
        ]
        for c in candidates {
            guard let s = c, !s.isEmpty else { continue }
            if parts.last == s { continue }
            parts.append(s)
        }
        return parts.isEmpty ? nil : parts.joined()
    }
}
