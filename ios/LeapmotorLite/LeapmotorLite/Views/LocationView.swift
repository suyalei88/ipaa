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
//  ★ 坐标系（2026-10-07 重写）：
//    老版本在注释里写死「车机上报的是 WGS-84 原始 GPS」—— 那是**没有证据的断言**，
//    而且正好是「定位偏到隔壁小区」的成因。真实情况是：
//      · 车机 T-Box 的 GPS 原生输出 WGS-84；
//      · 但国内不少车企在云端就加过偏移（GCJ-02），好让 App 直接画到高德上；
//      · 官方 App（1.22.68）里**两个方向都实现了**（wgs84ToGcj02: / gcj02ToWgs84:
//        / transformLat:bdLon: / outOfChina:bdLon: / ap_wgs2gcj），
//        还有 setExternalLocation:isAMapCoordinate: 这种「灌外部坐标要声明系别」的接口，
//        所以无法据此判定云端给的是哪一系。
//      · 合肥实测点 (31.801201, 117.342718) 两个方向相差 **574 米**。
//    → 结论：**不猜**。换算实现在 API/LMCoordinate.swift，由 `carFix` 三选一，
//      用户站到车旁（或跟官方 App 对比）一眼就能定下来。
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

    /// 车机坐标 → 地图坐标 的校正方式（持久化，见 LMCoordinate.swift）
    @State private var carFix: LMCarCoordFix = LMCarCoordFixStore.load()

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

    /// 车机原始坐标（未做任何换算）
    private var rawCarCoordinate: CLLocationCoordinate2D? { client.coordinate }

    /// 交给地图 / 地址 / 导航用的坐标（已按 `carFix` 换算）
    private var carCoordinate: CLLocationCoordinate2D? {
        guard let c = client.coordinate else { return nil }
        return carFix.apply(c)
    }

    var body: some View {
        VStack(spacing: 0) {
            mapArea
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ipLocationCard
                    addressCard
                    coordinateCard
                    coordFixCard
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
        // 换了校正方式：落盘 + 重新落点 + 重新解析地址
        .onChange(of: carFix) { _, newValue in
            LMCarCoordFixStore.save(newValue)
            centerOnVehicle()
            Task { await reverseGeocode(force: true) }
        }
    }

    // MARK: - 地图

    @ViewBuilder
    private var mapArea: some View {
        if carCoordinate != nil {
            Map(position: $camera) {
                if let c = carCoordinate {
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

    // MARK: - IP 归属地（★ 与官方 App「车辆位置」同源）

    /// 官方那个「驻车照片 + 定位 + 鸣笛寻车」卡片里的**位置显示**，
    /// 抓包实测来自 `GET apptec.leapmotor.cn/ipAnalysis/getAddressByIp`
    /// —— 返回 `{"province":"安徽","city":"淮南"}`，与官方界面一致。
    ///
    /// ★ 为什么把这张卡放在最上面：
    ///   用户报「官方显示淮南、本 App 显示合肥」。根因是之前拿车机 signalMap 的
    ///   `2190/2191` 当位置，而那组坐标在 **111 个抓包样本里一个数字都没变**
    ///   （31.801201 / 117.342718，指向合肥）—— 是静态值，不是实时位置。
    ///   IP 归属地是唯一能复现官方结果的来源，所以它是**主位置**，
    ///   车机坐标降级到下面的「坐标」卡里当附注。
    private var ipLocationCard: some View {
        LMCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "当前位置（与官方 App 同源）")

                if let ip = client.ipAddress, !ip.text.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.lmTeal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ip.regionText)
                                .font(.title3.weight(.semibold))
                            Text(ip.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("取自手机网络的 IP 归属地。官方 App 的「车辆位置」用的就是这个来源 —— "
                         + "所以它只精确到城市，且跟手机所在网络有关，不一定是车的实际停车点。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // ★ 复刻官方原话：「车端已关闭位置数据分享，无法获取车辆实时位置」
                    //   这解释了为什么车机坐标会是静态值 —— 车端压根没在分享位置。
                    if client.carLocationShareOff {
                        Label("车端已关闭位置数据分享，无法获取车辆实时位置",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.lmWarn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("还没取到 IP 归属地（下拉刷新试试）")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await client.probeIpAddress() }
                } label: {
                    Label("重新获取", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

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
                } else if carCoordinate == nil {
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
                .disabled(carCoordinate == nil || geocoding)
            }
        }
    }

    // MARK: - 坐标

    private var coordinateCard: some View {
        LMCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "坐标（已按当前校正方式换算）")

                if let c = carCoordinate {
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

                // ★ 两个「时间」必须分开显示，别混成一个：
                //   · 车况采集时间 = 信号 `1`，车机每次上报都会变（精确到秒）
                //   · 坐标未变化   = 这个坐标值最后一次**变化**到现在有多久
                //   车机可能一直在实时上报（前者一直是「刚刚」），但坐标好几天没动
                //   （后者很大）。只看前者会以为定位是实时的 —— 2026-10-08 就是这么误导的。
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("车况采集时间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(collectedText)
                        .font(.system(.caption, design: .monospaced))
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: client.coordinateLooksStale
                          ? "exclamationmark.triangle.fill" : "location.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(client.coordinateLooksStale ? Color.lmWarn : Color.secondary)
                    Text("坐标未变化")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(coordUnchangedText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(client.coordinateLooksStale ? Color.lmWarn : Color.primary)
                        .multilineTextAlignment(.trailing)
                }

                if client.coordinateLooksStale {
                    Text("""
                    车机一直在上报车况（上面的采集时间会一直刷新），但「这个坐标」已经很久没变过了。
                    所以图钉很可能不是车现在的位置 —— 常见原因：车停在地库/没信号、
                    车机没上传新定位、或定位功能未开启。请以官方 App 或实车为准。
                    """)
                        .font(.caption2)
                        .foregroundStyle(Color.lmWarn)
                        .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - 坐标校正

    /// 车辆定位偏移的头号原因是坐标系不一致。
    ///
    /// 这里不替用户猜方向 —— 车机给的是 WGS-84 还是 GCJ-02 无法从二进制静态判定
    /// （官方 App 两个方向的换算都实现了）。三个选项穷举了全部可能，
    /// 用户站到车旁看一眼地图就能定下来。
    private var coordFixCard: some View {
        LMCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.lmIndigo)
                    Text("坐标校正")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                Picker("校正方式", selection: $carFix) {
                    ForEach(LMCarCoordFix.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.menu)

                Text(carFix.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let raw = rawCarCoordinate, let fixed = carCoordinate {
                    Divider()
                    keyRow("车机原始", String(format: "%.6f, %.6f", raw.latitude, raw.longitude))
                    keyRow("换算之后", String(format: "%.6f, %.6f", fixed.latitude, fixed.longitude))
                    let moved = LMCoord.distance(raw, fixed)
                    keyRow("两者相距", moved < 1
                           ? "不足 1 米"
                           : String(format: "%.0f 米", moved))
                }

                Divider()

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.lmTeal)
                    Text("""
                    怎么确认哪个是对的（10 秒）：
                    · 站到车旁边，看地图上「车辆」那个针有没有落在车上；
                    · 或者打开官方 App 看它把车画在哪儿，跟这里对比一眼。
                    不对就换一个选项 —— 只有三个，总有一个是对的。
                    """)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func keyRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(v)
                .font(.system(.caption2, design: .monospaced))
                .multilineTextAlignment(.trailing)
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
        .disabled(carCoordinate == nil)
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
        ★ 主位置（最上面那张卡）来自手机网络的 IP 归属地 —— 和官方 App 的「车辆位置」是同一个接口
        （apptec.leapmotor.cn/ipAnalysis/getAddressByIp）。它只精确到城市，且取决于手机当前连的网络，
        不保证等于车的实际停车点。

        下面的坐标来自车机上报的信号 2190/2191（另一组 3725/3724 做交叉校验），不是实时 GPS 跟踪。

        ★ 实测提醒：这组车机坐标**可能长期不变**。在 111 个抓包样本里它一个数字都没动过
        （31.801201 / 117.342718，指向合肥），而同一时间官方 App 显示的是淮南 ——
        所以别把它当成「车在哪」的答案，它更像一个静态基准值。要判断新不新，看上面单独标的
        「坐标未变化」多久：车况采集时间每秒都在刷新，但坐标可以连续几十次完全不变。

        车熄火后位置可能长时间不更新；地库里通常没有定位。
        车机坐标属于哪一系（WGS-84 / GCJ-02）无法从协议静态判定，所以给了「坐标校正」三个选项：
        国内两系相差约 500~600 米，选对了才落得准。
        """)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    // MARK: - 计算

    private var distanceMeters: Double? {
        // ★ 用「换算到 WGS-84 的车机坐标」跟本机坐标量，别用地图上那两个点。
        //   本机坐标必然是 WGS-84；地图换算是显示问题，拿它去量距离会白差几百米。
        guard let raw = client.coordinate, let u = me.coordinate else { return nil }
        let c = carFix.toWgs84(raw)
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

    /// 「坐标未变化」的展示文本：从什么时候开始没变、已经多久。
    private var coordUnchangedText: String {
        guard let since = client.coordinateUnchangedSince,
              let secs = client.coordinateUnchangedFor else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let dur: String
        if secs < 60 { dur = "刚刚" }
        else if secs < 3600 { dur = "\(Int(secs / 60)) 分钟" }
        else if secs < 86400 { dur = String(format: "%.1f 小时", secs / 3600) }
        else { dur = String(format: "%.1f 天", secs / 86400) }
        return "\(f.string(from: since)) 起（\(dur)）"
    }

    private var amapURL: URL? {
        guard let c = carCoordinate else { return nil }
        // ★ `coordinate=` 必须跟我们实际传的值对得上，否则高德会按它自己的默认值
        //   再偏一次。取值由 carFix 决定（见 LMCoordinate.swift）：
        //     .wgs84ToGcj02 → 我们传的是 GCJ-02 → coordinate=gcj02
        //     .gcj02ToWgs84 → 我们传的是 WGS-84 → coordinate=wgs84
        //     .none         → 不知道是哪一系，索性不带，让高德按默认处理
        let name = (address ?? "车辆位置").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "car"
        var s = "https://uri.amap.com/marker?position=\(c.longitude),\(c.latitude)"
            + "&name=\(name)&callnative=1&src=leapmotorlite"
        if let sys = carFix.amapCoordinateParam {
            s += "&coordinate=\(sys)"
        }
        return URL(string: s)
    }

    private var appleMapsURL: URL? {
        guard let c = carCoordinate else { return nil }
        let q = (address ?? "车辆位置").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "car"
        return URL(string: "https://maps.apple.com/?ll=\(c.latitude),\(c.longitude)&q=\(q)")
    }

    private func copyCoordinate() {
        guard let c = carCoordinate else { return }
        UIPasteboard.general.string = String(format: "%.6f,%.6f", c.latitude, c.longitude)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            copied = false
        }
    }

    private func centerOnVehicle() {
        guard let c = carCoordinate else { return }
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
    ///
    /// ★ 传进去的必须是 **WGS-84**（CLGeocoder 属于 CoreLocation），
    ///   所以先按 carFix 把车机坐标转回来，别直接拿地图坐标去查。
    private func reverseGeocode(force: Bool = false) async {
        guard let raw = client.coordinate else {
            address = nil
            placeName = nil
            return
        }
        if !force, address != nil { return }
        geocoding = true
        geocodeError = nil
        defer { geocoding = false }

        let c = carFix.toWgs84(raw)
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
