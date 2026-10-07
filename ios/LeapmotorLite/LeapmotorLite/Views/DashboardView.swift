//
//  DashboardView.swift
//  LeapmotorLite
//
//  车况总览：电量环 + 指标磁贴 + 可折叠的原始信号表
//
import SwiftUI
import Foundation

struct DashboardView: View {
    @EnvironmentObject var client: LMClient

    @State private var showAllSignals = false
    @State private var toast: String?
    @State private var toastIsError = false
    /// 由 .lmClock 每 0.5 秒推一次，用来驱动锁定期倒计时
    @State private var now = Date()

    private let tiles = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let v = client.selectedVehicle {
                    hero(v)
                    tilesGrid
                    quickLinks
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
        .onChange(of: client.lastError) { _, newValue in
            guard let e = newValue else { return }
            toastIsError = true
            toast = e
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if toast == e { toast = nil }
            }
        }
    }

    // MARK: - 顶部主卡

    private func hero(_ v: LMVehicle) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(v.displayName)
                        .font(.title3.weight(.bold))
                    Text(v.vin)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let plate = v.plateNumber, !plate.isEmpty, plate != v.vin {
                        Text(plate)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                lockPill
            }

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
                Spacer()
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

    // MARK: - 磁贴

    private var tilesGrid: some View {
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

            MetricTile(title: "总里程",
                       value: client.odometerKm.map { "\(Int($0.rounded())) km" } ?? "--",
                       icon: "gauge.with.dots.needle.67percent",
                       tint: Color.lmPurple,
                       sub: "信号 1318")
        }
    }

    // MARK: - 快捷入口

    private var quickLinks: some View {
        VStack(spacing: 10) {
            SectionHeader(text: "快捷操作")
            LMCard(padding: 12) {
                HStack(spacing: 10) {
                    quickButton("锁车", "lock.fill", Color.lmGood, "lock")
                    quickButton("解锁", "lock.open.fill", Color.lmWarn, "unlock")
                    quickButton("上电", "power", Color.lmAccent, "hello")
                }
            }
        }
    }

    private func quickButton(_ title: String, _ icon: String, _ tint: Color, _ key: String) -> some View {
        Button {
            Task { await runQuick(key: key, title: title) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(tint.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(client.isBusy || client.isControlLocked(at: now))
    }

    /// 快捷操作：和车控页走同一条链路（含业务码 70 锁定提示）
    private func runQuick(key: String, title: String) async {
        if client.isControlLocked(at: now) {
            toastIsError = true
            toast = "操作密码被锁定，请 \(client.controlLockRemaining(at: now)) 秒后再试"
            return
        }
        let ok = await client.control(key)
        toastIsError = !ok
        toast = ok ? "\(title) 成功" : (client.lastError ?? "\(title) 失败")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        toast = nil
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
                                Spacer(minLength: 8)
                                Text(client.signals[k]?.displayText ?? "--")
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
            }
        }
    }

    private var sortedSignalKeys: [String] {
        client.signals.keys.sorted { a, b in
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (nil, _?):    return false
            case (_?, nil):    return true
            default:           return a < b
            }
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
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(toastIsError ? Color.lmBad : Color.lmGood, in: Capsule())
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
}
