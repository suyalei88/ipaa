//
//  LoveCarView.swift
//  LeapmotorLite
//
//  「爱车」页 —— 官方 App 底部第 3 个 Tab 的**完整复刻**。
//
//  ── 这一页到底复刻了什么 ─────────────────────────────────────────
//
//  官方「爱车」页有两个状态：
//
//    ① **未绑车态** —— 是营销页。数据来自 OSS 上的三个配置：
//         nativeApp/loveCar/love_car_default_header.txt          （在售车型 + 试驾/预定）
//         nativeApp/loveCar/love_car_information_dev_default_*.txt（在线客服 / 金融方案 / 版型）
//         nativeApp/loveCar/loveCarSwitchConfig-official.txt      （「去看车 / 我的订单」入口）
//       已用真实抓包逐条核对（见 `evidence/lovecar/`）。
//
//    ② **已绑车态** —— 就是用户截图那一页，也是本页复刻的对象：
//         顶部车辆栏 → 续航主数字 + SOC 进度条 + 车门锁态 → 充电中心入口
//         → 3D 车模（可全方位拖动）→ 快捷操作网格（可翻页）
//         → 预约充电横幅 → 车内温度 / 空调 → 地图卡 → 蓝牙钥匙
//
//  ⚠️ 官方「驻车照片」这一块**没有复刻**，原因写在 `mapCard` 的注释里：
//     它是拍照落库的图，接口在 IPA 字符串表里找不到、抓包里也没有样本，
//     宁可不做，也不拿一张假图糊上去。
//
//  ── 数据来源 ─────────────────────────────────────────────────────
//
//  全部来自 `LMClient` 的实时车况信号（每个数字都标了 signalId，
//  可以对着「信号浏览器」自己核对），没有任何硬编码的假数据。
//
import SwiftUI
import CoreLocation
import Foundation

struct LoveCarView: View {

    @EnvironmentObject var client: LMClient
    @Environment(\.openURL) private var openURL

    @State private var now = Date()
    @State private var toast: String?
    @State private var toastIsError = false

    /// 待二次确认的快捷动作 key
    @State private var quickConfirmKey: String?
    /// 车窗开度选择（关闭 / 微开 / 半开）
    @State private var showWindowSheet = false

    @State private var showAllSignals = false
    /// 快捷操作当前页
    @State private var quickPage = 0

    // ── 内嵌 3D 车模的状态 ────────────────────────────────────────
    @State private var car3DStatus = "正在启动本地 3D 服务…"
    @State private var car3DReady = false
    @State private var car3DFailure: String?
    @State private var car3DNonce = UUID()
    /// 是否正在看全屏 3D。
    ///
    /// ★ 这个开关不只是「跳页」——它还负责**把内嵌的 WebView 拆掉**。
    ///   官方查看器要在 Web Worker 里解析 5.9 MB 的 `D19_2026_full_car.fbx`，
    ///   一个实例常驻内存上百 MB。NavigationStack 推入下一页时，本页并不会被销毁，
    ///   所以如果不主动拆，真机上会同时存在**两个**解析完整车模型的 WebView
    ///   —— 内存直接翻倍，低端机有被 jetsam 干掉的风险。
    ///   代价是返回时要重新解析一次（页面里已经有 loading 态兜着）。
    @State private var showCar3DFullScreen = false

    private let tiles = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let v = client.selectedVehicle {
                    topBar(v)
                    // ★ 2026-10-08 调整：车模提到顶部、放大、去掉卡片底色。
                    //   官方爱车页的车模是「页面背景的一部分」而不是一张卡片，
                    //   所以这里紧跟顶部车辆栏，且不套 `LMCard` / 不画圆角底色。
                    car3DCard
                    rangeHero
                    chargeCenterChip
                    quickActionsPager
                    if client.chargeSchedule?.isEnabled == true { appointmentBanner }
                    climateCard
                    mapCard
                    bleCard
                    statusChips
                    metricsGrid
                    rawSignals
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("爱车")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showCar3DFullScreen) { Car3DView() }
        .refreshable { await client.refreshAll() }
        // ★ 必须有这个：不然锁定期倒计时冻住，到期后按钮也不会重新启用
        .lmClock(until: client.controlLockedUntil, now: $now)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if client.isBusy {
                    ProgressView()
                } else {
                    Button {
                        Task { await client.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新车况")
                }
            }
        }
        .overlay(alignment: .bottom) { toastView }
        // 会动物理世界的动作：确认一次
        .confirmationDialog(quickConfirmTitle,
                            isPresented: quickConfirmBinding,
                            titleVisibility: .visible) {
            Button("确认执行") {
                let k = quickConfirmKey
                quickConfirmKey = nil
                if let k = k { Task { await runQuick(key: k) } }
            }
            Button("取消", role: .cancel) { quickConfirmKey = nil }
        } message: {
            Text(quickConfirmMessage)
        }
        // 车窗：官方是一个按钮弹出三个开度
        .confirmationDialog("车窗开度",
                            isPresented: $showWindowSheet,
                            titleVisibility: .visible) {
            ForEach(LMEndpoints.WindowOpening.allCases, id: \.rawValue) { op in
                Button(op.title) { Task { await runWindow(op) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(windowSheetMessage)
        }
        .onChange(of: client.lastError) { _, newValue in
            guard let e = newValue else { return }
            showToast(e, isError: true)
        }
        .task {
            // 3D 车模参数来自 `3d/key`；没加载过就补一次（失败不阻塞，用默认版型兜底）
            if client.car3DKey == nil { await client.refreshVehicleProfile() }
        }
    }

    // MARK: - 1. 顶部车辆栏
    //
    //  官方：左侧「D19」+「状态更新 今天 11:27」，右侧「♡」+「⚙️」。

    private func topBar(_ v: LMVehicle) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(v.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text(statusUpdateText).font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // ♡ 关注车辆 —— 官方是收藏/关注，本 App 没有服务端收藏位，
            //    做成「把这台车设为当前车」的显式入口（多车时才有意义）
            if client.vehicles.count > 1 {
                Menu {
                    ForEach(client.vehicles) { veh in
                        Button {
                            client.select(vehicle: veh)
                            Task { await client.refreshAll() }
                        } label: {
                            Label(veh.displayName,
                                  systemImage: veh.vin == v.vin ? "checkmark" : "car")
                        }
                    }
                } label: {
                    Image(systemName: "heart")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.lmAccent)
                        .frame(width: 38, height: 38)
                        .background(Color.lmCard, in: Circle())
                }
                .accessibilityLabel("切换车辆")
            }

            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(Color.lmCard, in: Circle())
            }
            .accessibilityLabel("设置")
        }
    }

    // MARK: - 2. 续航主数字 + SOC 进度条 + 车门锁态
    //
    //  官方：大号「224km」，下面一条绿色进度条，右侧「🔒 车门已锁」。

    private var rangeHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rangeNumberText)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("km")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                lockPill
            }

            // SOC 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(socTint)
                        .frame(width: max(4, geo.size.width * socFraction))
                }
            }
            .frame(height: 7)

            HStack(spacing: 6) {
                Text("剩余电量 \(socText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let alt = client.rangeAltKm {
                    Text("另一标准 \(Int(alt.rounded())) km")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Color.lmAccent.opacity(0.16), Color.lmAccent2.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: LMRadius.hero, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LMRadius.hero, style: .continuous)
                .stroke(Color.lmAccent.opacity(0.20), lineWidth: 1)
        )
    }

    private var lockPill: some View {
        Group {
            if let locked = client.isLocked {
                StatusPill(text: locked ? "车门已锁" : "车门未锁",
                           icon: locked ? "lock.fill" : "lock.open.fill",
                           tint: locked ? Color.lmGood : Color.lmBad)
            } else {
                StatusPill(text: "锁态未知", icon: "questionmark.circle", tint: Color.secondary)
            }
        }
    }

    // MARK: - 3. 充电中心入口

    private var chargeCenterChip: some View {
        NavigationLink {
            ChargeView()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "bolt.fill").font(.system(size: 12, weight: .semibold))
                Text("充电中心").font(.footnote.weight(.semibold))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.lmAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.lmAccent.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 4. 内嵌 3D 车模
    //
    //  ★ 这是本页和官方爱车页最像的一块：车模**直接在这一页上**，
    //    单指拖动就能全方位旋转，不需要点进子页面。
    //
    //  实现：复用 `Car3DWebView`（官方查看器 + 本地回环 HTTP 服务），
    //  只是把尺寸从「全屏」换成固定高度。右上角给一个「全屏」入口。

    private var car3DCard: some View {
        // ★ 用 GeometryReader 量真实宽度喂给 `appJSON`：
        //   官方查看器要求画布尺寸和视图一致，否则车会被裁切。
        //   不用 `UIScreen.main.bounds` —— 那样分屏 / 旋转后会算错。
        GeometryReader { geo in
            car3DBody(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: car3DHeight)
    }

    /// 内嵌车模卡的高度。
    ///
    /// ★ 2026-10-08 从 230 提到 330：用户要求「放大、跟背景一起」。
    ///   330 接近官方爱车页车模区占屏的比例（约 40% 屏高），
    ///   且宽高比 361:330 ≈ 1.09，官方查看器在这个比例下不会裁切车头/车尾。
    private var car3DHeight: CGFloat { 330 }

    private func car3DBody(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let f = car3DFailure {
                    car3DFailureView(f)
                } else if showCar3DFullScreen {
                    // 全屏页开着的时候把内嵌这个拆掉，避免两份车模同时在内存里
                    // （见 `showCar3DFullScreen` 的注释）
                    Color.clear
                } else {
                    ZStack {
                        Car3DWebView(serverJSON: Car3DConfig.serverJSON(for: client),
                                     appJSON: Car3DConfig.appJSON(width: width, height: height),
                                     status: $car3DStatus,
                                     ready: $car3DReady,
                                     failure: $car3DFailure)
                            .id(car3DNonce)
                            .opacity(car3DReady ? 1 : 0)

                        if !car3DReady {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text(car3DStatus)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            // ★ 2026-10-08：不再铺卡片底色、不再裁剪圆角 —— 车模直接浮在页面背景上，
            //   与官方爱车页一致。WebView 本身是透明的（`isOpaque = false` +
            //   `backgroundColor = .clear`），所以去掉底色后不会有白块。

            Button {
                // 先复位，再跳全屏：返回时这里会用新 nonce 重建一个干净的 WebView
                car3DReady = false
                car3DStatus = "正在重新加载车模…"
                car3DNonce = UUID()
                showCar3DFullScreen = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(10)
            .accessibilityLabel("全屏看车")
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 5) {
                Image(systemName: "hand.draw").font(.system(size: 10))
                Text("单指拖动全方位旋转 · 双指缩放").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
        }
    }

    private func car3DFailureView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("3D 车模没加载起来")
                .font(.footnote.weight(.medium))
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button("重试") {
                car3DFailure = nil
                car3DStatus = "正在重新加载…"
                car3DNonce = UUID()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 5. 快捷操作（分页）
    //
    //  官方第 1 页：解锁 / 上锁 / 后备箱 / 车窗（截图逐字一致）。
    //  第 2 页：鸣笛寻车 / 空调开 / 空调关 / 上电 ——
    //  这 4 个来自官方 RN bundle 里的 `quickActions` 常量
    //  （`[{unlock:110},{trunk:130},{horn:120},{ac:170},{windows:230}]`）
    //  加上已实测的 cmdid 400（上电）。

    private let quickPages: [[String]] = [
        ["lock", "unlock", "trunk_open", "window"],
        ["horn", "ac_on", "ac_off", "hello"],
    ]

    private var quickActionsPager: some View {
        TabView(selection: $quickPage) {
            // ★ 用 indices 而不是 `Array(pages.enumerated())`：
            //   后者在 ForEach 里要解构元组，写法上更容易踩坑，
            //   直接用下标既清楚又不会歧义。
            ForEach(quickPages.indices, id: \.self) { idx in
                HStack(spacing: 8) {
                    ForEach(quickPages[idx], id: \.self) { key in
                        quickButton(key)
                    }
                }
                .padding(.horizontal, 2)
                .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        .frame(height: 124)
    }

    private func quickButton(_ key: String) -> some View {
        let cmd = LMEndpoints.commands[key]
        let isWindow = (key == "window")
        let title = isWindow ? "车窗" : (cmd?.title ?? key)
        let icon = isWindow ? "window.vertical.open" : (cmd?.systemImage ?? "questionmark")
        let tint = quickTint(for: key)

        return Button {
            if isWindow {
                showWindowSheet = true
            } else {
                quickConfirmKey = key
            }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 56, height: 56)
                    .background(Color.lmCard, in: Circle())
                    .overlay(Circle().stroke(tint.opacity(0.16), lineWidth: 1))
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(client.isBusy || client.isControlLocked(at: now))
    }

    /// 按 **actionKey** 判色（不是按 cmdid —— cmdid 的语义被整体纠正过一次，
    /// 按它判色会跟着一起错，这个坑上一轮踩过）。
    private func quickTint(for key: String) -> Color {
        switch key {
        case "lock":         return Color.lmGood
        case "unlock":       return Color.lmWarn
        case "trunk_open":   return Color.lmTeal
        case "trunk_close":  return Color.lmTeal
        case "horn":         return Color.lmIndigo
        case "window":       return Color.lmPurple
        case "window_micro": return Color.lmPurple
        case "window_half":  return Color.lmPurple
        case "window_close": return Color.lmPurple
        case "ac_on":        return Color.lmAccent
        case "ac_off":       return Color.lmAccent2
        case "hello":        return Color.lmBad
        default:             return Color.lmIndigo
        }
    }

    // MARK: - 6. 预约充电横幅
    //
    //  官方：「已预约充电，请及时插枪」+「22:05–次日07:55」。
    //  数据来自 `commonConfig` 的 `config["3"]`（`LMChargeSchedule`）。

    private var appointmentBanner: some View {
        NavigationLink {
            ChargeView()
        } label: {
            LMCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.lmGood)
                        .frame(width: 38, height: 38)
                        .background(Color.lmGood.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("已预约充电，请及时插枪")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(appointmentTimeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var appointmentTimeText: String {
        guard let s = client.chargeSchedule else { return "--:-- – --:--" }
        var parts = ["\(s.beginTime)–\(s.endTime)"]
        if let t = s.targetPercent { parts.append("充至 \(t)%") }
        if s.weekdayText != "未选择" { parts.append(s.weekdayText) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 7. 车内温度 / 空调
    //
    //  官方左侧是大号设定温度、下面一行「车内温度 24.5℃」，右侧一个风扇按钮。
    //
    //  ⚠️ 我们**没有**空调设定温度的可靠信号：
    //     10707 实测 −6（像偏移量）、644/645/865/866 在 0 与 21 之间跳，
    //     四个都标着「疑似」。所以这里大号数字放的是**已确认的车内温度**（1349），
    //     不拿一个「疑似设定值」冒充官方那个 23℃。
    //     风量 / 温度的真实下发在「车控」页的空调卡里。

    private var climateCard: some View {
        LMCard(padding: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(interiorTempText)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("℃").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text("车内温度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let bt = client.batteryTemp {
                        Text(String(format: "电池温度 %.1f ℃", bt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)

                VStack(spacing: 6) {
                    Button {
                        quickConfirmKey = (client.hvacOn == true) ? "ac_off" : "ac_on"
                    } label: {
                        Image(systemName: client.hvacOn == true
                              ? "fanblades.fill" : "fanblades")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(client.hvacOn == true ? Color.lmAccent : Color.secondary)
                            .frame(width: 52, height: 52)
                            .background(Color.lmAccent.opacity(client.hvacOn == true ? 0.14 : 0.06),
                                        in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(client.isBusy || client.isControlLocked(at: now))

                    Text(hvacStateText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    ControlPanelView()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.lmPurple)
                            .frame(width: 52, height: 52)
                            .background(Color.lmPurple.opacity(0.10), in: Circle())
                        Text("风量/温度")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hvacStateText: String {
        switch client.hvacOn {
        case .some(true):  return "空调开"
        case .some(false): return "空调关"
        case .none:        return "空调--"
        }
    }

    // MARK: - 8. 地图卡
    //
    //  ⚠️ 官方这一块是「驻车照片 + 鸣笛寻车」：驻车照片是车停稳时拍的一张图，
    //     存服务端再按停车点回放。
    //     **本 App 不复刻驻车照片**，因为：
    //       · IPA 字符串表里扫不到对应的取图路径；
    //       · 三份抓包里也没有任何一次请求像「取驻车照片」；
    //       · `vehicleinfo/parking/query` 是纯路径猜测，实测响应里没有图片字段。
    //     与其放一张假图，不如把**已确认**的东西做扎实：
    //     车机坐标（2190/2191）+ 采集时间 + 鸣笛寻车 + 一键跳地图。

    private var mapCard: some View {
        LMCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.lmTeal)
                        .frame(width: 38, height: 38)
                        .background(Color.lmTeal.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("车辆位置")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        // ★ 主位置 = IP 归属地，与官方 App 的「车辆位置」**完全同源**。
                        //   抓包实测：官方 `ipAnalysis/getAddressByIp` → 安徽 淮南（与官方界面一致）；
                        //   而车机 signalMap 的 2190/2191 在 111 个样本里一个数字都没变
                        //   （31.801201 / 117.342718，指向合肥）—— 那是静态值，只能当附注。
                        if let ip = client.ipAddress, !ip.regionText.isEmpty {
                            Text(ip.regionText)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else if let c = client.coordinate {
                            Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                                .font(.system(.callout, design: .monospaced).weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else {
                            Text("暂无位置").font(.callout).foregroundStyle(.secondary)
                        }
                        if let c = client.coordinate {
                            Text(String(format: "车机坐标 %.5f, %.5f", c.latitude, c.longitude))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        if let age = client.locationAge {
                            Text(ageText(age)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                }

                if let ip = client.ipAddress, !ip.regionText.isEmpty {
                    Text("位置取自手机网络归属地，与官方 App 同源")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // ★ 复刻官方原话（2026-10-09 用户实机看到）：
                //   「车端已关闭位置数据分享，无法获取车辆实时位置」
                //   判据是可观测事实（车机在实时上报车况但坐标 >24h 没动），
                //   不用语义存疑的 privacyGPS，见 LMClient.carLocationShareOff。
                if client.carLocationShareOff {
                    Label("车端已关闭位置数据分享，无法获取车辆实时位置",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.lmWarn)
                }

                if client.locationMayBeHidden {
                    Label("车辆已开启位置隐私，坐标可能不是真实停车点",
                          systemImage: "eye.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.lmWarn)
                }

                HStack(spacing: 10) {
                    Button {
                        quickConfirmKey = "horn"
                    } label: {
                        Label("鸣笛寻车", systemImage: "speaker.wave.2.fill")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                    .disabled(client.isBusy || client.isControlLocked(at: now))

                    Button {
                        openInMaps()
                    } label: {
                        Label("打开地图", systemImage: "map")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                    .disabled(client.ipAddress == nil && client.coordinate == nil)

                    NavigationLink {
                        LocationView()
                    } label: {
                        Label("定位页", systemImage: "location.fill")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                }
                .labelStyle(.titleAndIcon)
            }
        }
    }

    private func openInMaps() {
        // ★ 优先按 IP 归属地的城市名搜 —— 与官方「车辆位置」同源。
        //   车机坐标是静态值（实测 111 个样本不变），直接拿它导航会导到**错误城市**
        //   （用户实车在淮南，坐标却指向合肥）。城市名虽粗，但方向是对的。
        if let ip = client.ipAddress, !ip.regionText.isEmpty {
            let q = ip.regionText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                ?? ip.regionText
            if let url = URL(string: "https://maps.apple.com/?q=\(q)&z=12") { openURL(url) }
            return
        }
        guard let c = client.coordinate else { return }
        let url = URL(string: "https://maps.apple.com/?ll=\(c.latitude),\(c.longitude)&q=我的车&z=17")
        if let url = url { openURL(url) }
    }

    // MARK: - 9. 蓝牙钥匙卡

    private var bleCard: some View {
        NavigationLink {
            BLEKeyView()
        } label: {
            LMCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "bluetooth")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.lmIndigo)
                        .frame(width: 38, height: 38)
                        .background(Color.lmIndigo.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("蓝牙钥匙")
                            .font(.headline)
                        Text(bleSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var bleSubtitle: String {
        guard let record = client.bleKeyRecord else { return "未同步数字钥匙" }
        return "已绑定 · \(record.macPretty) · 协议 \(record.versionText)"
    }

    // MARK: - 10. 状态芯片

    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LMChargePill(state: client.chargeState)

                if let locked = client.isLocked {
                    StatusPill(text: locked ? "车门已锁" : "车门未锁",
                               icon: locked ? "lock.fill" : "lock.open.fill",
                               tint: locked ? Color.lmGood : Color.lmBad)
                }

                if let w = client.windowOpeningText {
                    StatusPill(text: w, icon: "window.vertical.open", tint: Color.lmPurple)
                }

                if let h = client.hvacOn {
                    StatusPill(text: h ? "空调开" : "空调关",
                               icon: h ? "fanblades.fill" : "fanblades.slash",
                               tint: h ? Color.lmAccent : Color.secondary)
                }

                if client.coordinate == nil {
                    StatusPill(text: "无定位", icon: "location.slash", tint: Color.lmWarn)
                }

                if client.locationMayBeHidden {
                    StatusPill(text: "位置隐私已开", icon: "eye.slash.fill", tint: Color.lmWarn)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    // MARK: - 11. 指标网格

    private var metricsGrid: some View {
        LazyVGrid(columns: tiles, spacing: 12) {
            MetricTile(title: "剩余电量",
                       value: client.batteryPercent.map { "\(Int($0.rounded())) %" } ?? "--",
                       icon: "battery.75",
                       tint: Color.lmGood,
                       sub: "信号 100003")

            MetricTile(title: "续航",
                       value: client.rangeKm.map { "\(Int($0.rounded())) km" } ?? "--",
                       icon: "road.lanes",
                       tint: Color.lmAccent,
                       sub: client.rangeAltKm.map { "另一标准 \(Int($0.rounded())) km" } ?? "信号 3257")

            MetricTile(title: "满电估算",
                       value: client.fullRangeEstimateKm.map { "\(Int($0.rounded())) km" } ?? "--",
                       icon: "battery.100.bolt",
                       tint: Color.lmPurple,
                       sub: "3257 ÷ SOC 反推")

            MetricTile(title: "车锁",
                       value: client.isLocked == nil ? "--" : (client.isLocked == true ? "已上锁" : "未上锁"),
                       icon: client.isLocked == true ? "lock.fill" : "lock.open.fill",
                       tint: client.isLocked == true ? Color.lmGood : Color.lmWarn,
                       sub: "信号 1298 / 3262")

            MetricTile(title: "车窗",
                       value: client.windowOpeningText ?? "--",
                       icon: "window.vertical.open",
                       tint: Color.lmPurple,
                       sub: "信号 1693–1696")

            MetricTile(title: "后备箱",
                       value: client.signalNumber("1281").map { $0 >= 0.5 ? "开" : "关" } ?? "--",
                       icon: "shippingbox",
                       tint: Color.lmTeal,
                       sub: "信号 1281")

            MetricTile(title: "车内温度",
                       value: client.interiorTemp.map { String(format: "%.1f ℃", $0) } ?? "--",
                       icon: "thermometer.medium",
                       tint: Color.lmTeal,
                       sub: "信号 1349")

            MetricTile(title: "电池温度",
                       value: client.batteryTemp.map { String(format: "%.1f ℃", $0) } ?? "--",
                       icon: "thermometer.snowflake",
                       tint: Color.lmIndigo,
                       sub: "信号 2183")

            MetricTile(title: "总里程",
                       value: client.odometerKm.map { "\(Int($0.rounded())) km" } ?? "--",
                       icon: "gauge.with.dots.needle.67percent",
                       tint: Color.lmPurple,
                       sub: "信号 1318")

            MetricTile(title: "距目标电量",
                       value: client.chargeMinutesToTarget.map { shortMinutes($0) } ?? "--",
                       icon: "hourglass",
                       tint: Color.lmGood,
                       sub: "信号 1200 · 投影值")
        }
    }

    // MARK: - 12. 原始信号（可验证区）

    private var rawSignals: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAllSignals.toggle() }
            } label: {
                HStack {
                    SectionHeader(text: "全部信号（\(client.signals.count)）")
                    Image(systemName: showAllSignals ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showAllSignals {
                LMCard(padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(sortedSignalKeys, id: \.self) { k in
                            HStack(spacing: 8) {
                                Text(k)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if let r = LMSignalCatalog.ref(k) {
                                    Text(r.name)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(client.signalText(k))
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)

                            if k != sortedSignalKeys.last {
                                Divider().padding(.leading, 8)
                            }
                        }
                    }
                }

                NavigationLink {
                    SignalExplorerView()
                } label: {
                    Label("打开信号浏览器（搜索 / 快照对比）", systemImage: "magnifyingglass.circle")
                        .font(.caption)
                }
            }
        }
    }

    private var sortedSignalKeys: [String] {
        client.signals.keys.sorted { a, b in
            LMSignalCatalog.numeric(a) < LMSignalCatalog.numeric(b)
        }
    }

    // MARK: - 空态 / 提示

    private var emptyState: some View {
        LMCard(padding: 24) {
            VStack(spacing: 10) {
                Image(systemName: "car")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.lmAccent)
                Text("还没有车辆")
                    .font(.headline)
                Text("下拉刷新，或到「设置」检查登录态")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("立即刷新") {
                    Task { await client.refreshAll() }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 40)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = toast {
            Text(toast)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(toastIsError ? Color.lmBad : Color.lmGood, in: Capsule())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 动作

    /// 快捷操作：和车控页走同一条链路（含业务码 70 锁定提示）。
    private func runQuick(key: String) async {
        if client.isControlLocked(at: now) {
            showToast("操作密码被锁定，请 \(client.controlLockRemaining(at: now)) 秒后再试", isError: true)
            return
        }
        guard let cmd = LMEndpoints.commands[key] else { return }
        let ok = await client.control(key)
        showToast(ok ? "\(cmd.title) 成功" : (client.lastError ?? "\(cmd.title) 失败"), isError: !ok)
        if ok { try? await client.refreshStatus() }
    }

    /// 车窗：官方是一个按钮弹三个开度，走同一个 cmdid 230。
    private func runWindow(_ opening: LMEndpoints.WindowOpening) async {
        if client.isControlLocked(at: now) {
            showToast("操作密码被锁定，请 \(client.controlLockRemaining(at: now)) 秒后再试", isError: true)
            return
        }
        let ok = await client.controlRaw(cmdid: LMEndpoints.windowCmdid,
                                         state: LMEndpoints.windowState(opening),
                                         label: "车窗\(opening.title)")
        showToast(ok ? "车窗\(opening.title) 已下发" : (client.lastError ?? "车窗\(opening.title) 失败"),
                  isError: !ok)
        if ok { try? await client.refreshStatus() }
    }

    // MARK: - 二次确认文案

    private var quickConfirmTitle: String {
        guard let k = quickConfirmKey, let cmd = LMEndpoints.commands[k] else {
            return "确认下发车控指令？"
        }
        return "确认执行「\(cmd.title)」？"
    }

    private var quickConfirmMessage: String {
        guard let k = quickConfirmKey, let cmd = LMEndpoints.commands[k] else {
            return "将向车辆下发一次真实指令。"
        }
        if cmd.risk == .physical {
            return "cmdid \(cmd.cmdid) 会真的动车门 / 后备箱 / 上电。"
                + "请确认车辆周围安全、车门和后备箱附近没有人，再执行。"
        }
        return "cmdid \(cmd.cmdid)，只改状态（空调），不会夹到人。"
    }

    private var windowSheetMessage: String {
        if let t = client.windowOpeningText {
            return "当前上报：\(t)。cmdid \(LMEndpoints.windowCmdid) 会让四个车窗一起动。"
        }
        return "cmdid \(LMEndpoints.windowCmdid) 会让四个车窗一起动，请确认车窗附近没有人。"
    }

    private var quickConfirmBinding: Binding<Bool> {
        Binding(get: { quickConfirmKey != nil },
                set: { if !$0 { quickConfirmKey = nil } })
    }

    private func showToast(_ text: String, isError: Bool) {
        toastIsError = isError
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == text { toast = nil }
        }
    }

    // MARK: - 文案

    private var rangeNumberText: String {
        guard let km = client.rangeKm else { return "--" }
        return "\(Int(km.rounded()))"
    }

    private var socText: String {
        guard let p = client.batteryPercent else { return "--" }
        return "\(Int(p.rounded()))%"
    }

    private var socFraction: Double {
        guard let p = client.batteryPercent else { return 0 }
        return min(max(p / 100.0, 0), 1)
    }

    private var socTint: Color {
        guard let p = client.batteryPercent else { return Color.lmWarn }
        if p <= 15 { return Color.lmBad }
        if p <= 35 { return Color.lmWarn }
        return Color.lmGood
    }

    private var interiorTempText: String {
        guard let t = client.interiorTemp else { return "--" }
        return String(format: "%.1f", t)
    }

    private var statusUpdateText: String {
        guard let d = client.lastUpdate else { return "尚未刷新" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "状态更新 今天 \(f.string(from: d))" }
        if cal.isDateInYesterday(d) { return "状态更新 昨天 \(f.string(from: d))" }
        f.dateFormat = "M月d日 HH:mm"
        return "状态更新 \(f.string(from: d))"
    }

    private func shortMinutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h\(m % 60)m" : "\(m)m"
    }

    private func ageText(_ age: TimeInterval) -> String {
        if age < 60 { return "刚刚采集" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前采集" }
        if age < 86400 { return "\(Int(age / 3600)) 小时前采集" }
        return "\(Int(age / 86400)) 天前采集"
    }
}
