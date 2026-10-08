//
//  DashboardView.swift
//  LeapmotorLite
//
//  首页「车况」。信息架构参考了主流车企 App 的首页：
//    车辆卡 → 电量/续航主卡 → 状态芯片 → 定位卡 → 充电卡 → 指标网格 → 快捷车控
//
//  ★ 每个数字都带「信号 id」出处，方便用户对着「信号浏览器」自己核对。
//    这个 App 的定位是「功能 + 可验证」，不是把数字糊在屏幕上让你信。
//
import SwiftUI
import CoreLocation
import Foundation

struct DashboardView: View {
    @EnvironmentObject var client: LMClient

    @State private var showAllSignals = false
    @State private var toast: String?
    @State private var toastIsError = false
    /// 由 .lmClock 每 0.5 秒推一次，用来驱动锁定期倒计时
    @State private var now = Date()
    /// 待二次确认的快捷动作 key（车控会动车，首页也要确认一次）
    @State private var quickConfirmKey: String?

    private let tiles = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let v = client.selectedVehicle {
                    vehicleHeader(v)
                    heroCard
                    statusChips
                    locationCard
                    chargeCard
                    metricsGrid
                    quickActions
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
        .navigationTitle("车况")
        .refreshable { await client.refreshAll() }
        // ★ 必须有这个：不然倒计时冻在 "300 秒"，而且到期后快捷车控按钮不会重新启用
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
        .onChange(of: client.lastError) { _, newValue in
            guard let e = newValue else { return }
            showToast(e, isError: true)
        }
    }

    // MARK: - 车辆卡

    private func vehicleHeader(_ v: LMVehicle) -> some View {
        LMCard(padding: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "car.side.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.lmAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.lmAccent.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(v.displayName)
                        .font(.headline)
                    HStack(spacing: 6) {
                        if let plate = v.plateNumber, !plate.isEmpty, plate != v.vin {
                            Text(plate).font(.caption)
                        }
                        Text(v.vin)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                lockPill
            }
        }
    }

    private var lockPill: some View {
        Group {
            if let locked = client.isLocked {
                StatusPill(text: locked ? "已上锁" : "未上锁",
                           icon: locked ? "lock.fill" : "lock.open.fill",
                           tint: locked ? Color.lmGood : Color.lmWarn)
            } else {
                StatusPill(text: "锁态未知", icon: "questionmark.circle", tint: Color.secondary)
            }
        }
    }

    // MARK: - 电量 / 续航主卡

    private var heroCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                BatteryRing(percent: client.batteryPercent)

                VStack(alignment: .leading, spacing: 12) {
                    heroRow("续航", rangeText, "road.lanes", Color.lmAccent)
                    heroRow("车内", tempText, "thermometer.medium", Color.lmWarn)
                    heroRow("总里程", odometerText, "gauge.with.dots.needle.67percent", Color.lmPurple)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text(updateText)
                    .font(.caption2)
                Spacer(minLength: 0)
                if client.isBusy {
                    Text("刷新中…").font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.lmAccent.opacity(0.16), Color.lmAccent2.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: LMRadius.hero, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LMRadius.hero, style: .continuous)
                .stroke(Color.lmAccent.opacity(0.20), lineWidth: 1)
        )
    }

    private func heroRow(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 状态芯片

    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LMChargePill(state: client.chargeState)

                StatusPill(text: client.coordinate == nil ? "无定位" : "已定位",
                           icon: client.coordinate == nil ? "location.slash" : "location.fill",
                           tint: client.coordinate == nil ? Color.lmWarn : Color.lmTeal)

                if let age = client.locationAge {
                    StatusPill(text: ageText(age), icon: "clock",
                               tint: age < 900 ? Color.lmGood : Color.lmWarn)
                }

                if let locked = client.isLocked {
                    StatusPill(text: locked ? "车门已锁" : "车门未锁",
                               icon: locked ? "lock.fill" : "lock.open.fill",
                               tint: locked ? Color.lmGood : Color.lmBad)
                }

                if client.locationMayBeHidden {
                    StatusPill(text: "位置隐私已开", icon: "eye.slash.fill", tint: Color.lmWarn)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    // MARK: - 定位卡

    private var locationCard: some View {
        NavigationLink {
            LocationView()
        } label: {
            LMCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.lmTeal)
                        .frame(width: 38, height: 38)
                        .background(Color.lmTeal.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("车辆定位")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let c = client.coordinate {
                            Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                                .font(.system(.callout, design: .monospaced).weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else {
                            Text("暂无坐标")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let age = client.locationAge {
                            Text(ageText(age))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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

    // MARK: - 充电卡

    private var chargeCard: some View {
        NavigationLink {
            ChargeView()
        } label: {
            LMCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.lmGood)
                            .frame(width: 38, height: 38)
                            .background(Color.lmGood.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("车辆充电")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(chargeHeadline)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }

                    if client.batteryPercent != nil || client.chargeTargetPercent != nil {
                        HStack(spacing: 8) {
                            if let soc = client.batteryPercent {
                                miniStat("当前", "\(Int(soc.rounded())) %")
                            }
                            if let t = client.chargeTargetPercent {
                                miniStat("目标", "\(t) %")
                            }
                            if let m = client.chargeMinutesToTarget {
                                miniStat("待充", shortMinutes(m))
                            }
                            if let s = client.chargeSchedule {
                                miniStat("预约", s.isEnabled ? "\(s.beginTime)–\(s.endTime)" : "关")
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func miniStat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(v)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chargeHeadline: String {
        // ★ 只有真的在充电，才把 1200 说成「还需多久」。
        //   没充电时 1200 是「插枪后大概要充多久」的投影值，不能说成倒计时。
        if client.isCharging {
            if let m = client.chargeMinutesToTarget {
                return "充电中 · 距目标电量还需 \(shortMinutes(m))"
            }
            return "充电中"
        }
        if let soc = client.batteryPercent, let t = client.chargeTargetPercent, soc >= Double(t) {
            return "已达到目标电量 \(t)%"
        }
        if let m = client.chargeMinutesToTarget {
            return "未在充电 · 插枪后约需 \(shortMinutes(m))"
        }
        if client.chargeSchedule?.isEnabled == true {
            return "未在充电 · 已设预约充电"
        }
        return "未在充电"
    }

    private func shortMinutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h\(m % 60)m" : "\(m)m"
    }

    // MARK: - 指标网格

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

    // MARK: - 快捷车控

    private var quickActions: some View {
        VStack(spacing: 10) {
            HStack {
                SectionHeader(text: "快捷操作")
                Spacer()
                NavigationLink {
                    ControlPanelView()
                } label: {
                    Text("全部")
                        .font(.caption.weight(.medium))
                }
            }

            LMCard(padding: 12) {
                HStack(spacing: 10) {
                    ForEach(LMEndpoints.primaryActions, id: \.self) { key in
                        if let cmd = LMEndpoints.commands[key] {
                            quickButton(key: key, cmd: cmd)
                        }
                    }
                }
            }
        }
    }

    private func quickButton(key: String, cmd: LMEndpoints.Command) -> some View {
        let accent = quickTint(for: key)
        return Button {
            quickConfirmKey = key
        } label: {
            VStack(spacing: 6) {
                Image(systemName: cmd.systemImage).font(.system(size: 20, weight: .semibold))
                Text(cmd.title).font(.caption.weight(.medium))
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(accent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(client.isBusy || client.isControlLocked(at: now))
    }

    /// ★ 2026-10-08 修正：以前这里按 `cmdid` 判色，而 cmdid 的语义刚被整体
    ///   纠正过（170 从「大灯」改成「空调」、230 从「空调」改成「车窗」），
    ///   按 cmdid 判色会跟着一起错。改成按 **actionKey** 判，语义才稳定。
    private func quickTint(for key: String) -> Color {
        switch key {
        case "lock":         return Color.lmGood
        case "unlock":       return Color.lmWarn
        case "trunk_open":   return Color.lmTeal
        case "trunk_close":  return Color.lmTeal
        case "horn":         return Color.lmIndigo
        case "window_micro": return Color.lmPurple
        case "window_half":  return Color.lmPurple
        case "window_close": return Color.lmPurple
        case "ac_on":        return Color.lmAccent
        case "ac_off":       return Color.lmAccent2
        default:             return Color.lmIndigo
        }
    }

    /// 快捷操作：和车控页走同一条链路（含业务码 70 锁定提示）。
    ///
    /// ★ 2026-10-08 改动：以前「会动物理世界」的动作在首页只弹一句
    ///   「请到车控页确认后执行」。但 `primaryActions` 里恰好有
    ///   上锁 / 解锁两个 physical 动作 —— 等于首页 4 个快捷按钮有 2 个
    ///   点下去什么也不做，只是把你支走。现在改成**在首页直接弹确认框**，
    ///   确认后照常下发，链路和车控页完全一致（确认文案也复用同一套）。
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

    // MARK: - 快捷动作的二次确认
    //
    // 文案刻意和车控页保持一致 —— 同一个动作在哪个页面点，提示都该一样。

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

    // MARK: - 原始信号

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

    // MARK: - 文案

    private var rangeText: String {
        guard let km = client.rangeKm else { return "--" }
        return "\(Int(km.rounded())) km"
    }

    private var tempText: String {
        guard let t = client.interiorTemp else { return "--" }
        return String(format: "%.1f ℃", t)
    }

    private var odometerText: String {
        guard let km = client.odometerKm else { return "--" }
        return "\(Int(km.rounded())) km"
    }

    private var updateText: String {
        guard let d = client.lastUpdate else { return "尚未刷新" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "更新于 \(f.string(from: d))"
    }

    private func ageText(_ age: TimeInterval) -> String {
        if age < 60 { return "刚刚采集" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前采集" }
        if age < 86400 { return "\(Int(age / 3600)) 小时前采集" }
        return "\(Int(age / 86400)) 天前采集"
    }
}
