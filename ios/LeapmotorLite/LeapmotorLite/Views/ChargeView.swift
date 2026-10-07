//
//  ChargeView.swift
//  LeapmotorLite
//
//  车辆充电信息：电量 / 剩余充电时间 / 预约充电 / 电池温度 / 续航估算。
//
//  ★ 这个页面严格区分「确认的」和「猜的」：
//      · 电量 100003、取整 1204、剩余充电时间 1200、续航 3257/3260、
//        电池温度 2183、预约充电配置（commonConfig.config["3"]）—— 有证据，正常显示。
//      · 充电功率 / 电流（1177 / 1178）—— 未确认，界面上明确写「疑似」，
//        并且给出两种可能的读法，不替用户下结论。
//      · 「是否在充电」—— 没有找到直接的布尔信号，是从「1200 > 0」推的，
//        所以文案写「疑似充电中」。
//    宁可显得啰嗦，也不要让用户以为「7.37 kW」是官方数字。
//
import SwiftUI
import Foundation

struct ChargeView: View {
    @EnvironmentObject var client: LMClient

    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                if client.isChargingLikely { remainingCard }
                scheduleCard
                batteryCard
                rangeCard
                guessCard
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("充电")
        .refreshable {
            try? await client.refreshStatus()
            try? await client.refreshCommonConfig()
        }
        .task {
            if client.chargeSchedule == nil {
                try? await client.refreshCommonConfig()
            }
        }
        // 充电时的「预计充满时刻」要跟着时间走，挂上 30 秒的时钟
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                now = Date()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if client.isBusy {
                    ProgressView()
                } else {
                    Button {
                        Task {
                            try? await client.refreshStatus()
                            try? await client.refreshCommonConfig()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新充电信息")
                }
            }
        }
    }

    // MARK: - 顶部：电量 + 目标

    private var heroCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                BatteryRing(percent: client.batteryPercent)

                VStack(alignment: .leading, spacing: 10) {
                    statusPill
                    if let t = client.chargeTargetPercent {
                        infoRow("目标电量", "\(t) %", "target", Color.lmAccent)
                    }
                    if let km = client.rangeKm {
                        infoRow("当前续航", "\(Int(km.rounded())) km", "road.lanes", Color.lmTeal)
                    }
                    if let temp = client.batteryTemp {
                        infoRow("电池温度", String(format: "%.1f ℃", temp),
                                "thermometer.medium", Color.lmWarn)
                    }
                }
                Spacer(minLength: 0)
            }

            if let soc = client.batteryPercent, let target = client.chargeTargetPercent, target > 0 {
                chargeProgress(soc: soc, target: Double(target))
            }

            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10))
                Text(updateText)
                    .font(.caption2)
                Spacer(minLength: 0)
                if client.chargeSchedule == nil {
                    Text("预约配置未加载").font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Color.lmGood.opacity(0.16), Color.lmAccent2.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: LMRadius.hero, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LMRadius.hero, style: .continuous)
                .stroke(Color.lmGood.opacity(0.20), lineWidth: 1)
        )
    }

    private var statusPill: some View {
        Group {
            if client.isChargingLikely {
                StatusPill(text: "疑似充电中", icon: "bolt.fill", tint: Color.lmGood)
            } else if client.signals.isEmpty {
                StatusPill(text: "暂无车况", icon: "questionmark.circle", tint: Color.secondary)
            } else {
                StatusPill(text: "未在充电", icon: "bolt.slash", tint: Color.secondary)
            }
        }
    }

    /// 当前 SOC → 目标电量 的进度条
    private func chargeProgress(soc: Double, target: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("充电进度")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(soc.rounded()))% / \(Int(target))%")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(soc, target), total: max(target, 1))
                .progressViewStyle(.linear)
                .tint(soc >= target ? Color.lmGood : Color.lmAccent)
            if soc >= target {
                Text("已达到目标电量")
                    .font(.caption2)
                    .foregroundStyle(Color.lmGood)
            } else {
                Text("还差 \(Int((target - soc).rounded())) 个百分点")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 剩余充电时间

    private var remainingCard: some View {
        LMCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(text: "剩余充电时间")

                if let m = client.chargingRemainingMinutes {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(hoursMinutes(m))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.lmAccent)
                        Text("充满")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.lmTeal)
                        Text("按此推算，约 \(fullAtText(m)) 充满")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.lmPurple)
                        Text(rateText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("信号 1200 为 0，当前没有剩余充电时间。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("信号 1200。判定依据：SOC 33.1% 时 645 min、36.6% 时 605 min，"
                     + "两次独立推算 578.5 / 572.6 分钟每百分点，误差 1%。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func hoursMinutes(_ m: Int) -> String {
        if m >= 60 {
            let h = m / 60
            let mm = m % 60
            return mm == 0 ? "\(h) 小时" : "\(h) 小时 \(mm) 分"
        }
        return "\(m) 分钟"
    }

    private func fullAtText(_ m: Int) -> String {
        let d = now.addingTimeInterval(Double(m) * 60)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// 由「剩余时间 + 剩余电量」反推每小时能充多少
    private var rateText: String {
        guard let m = client.chargingRemainingMinutes, m > 0,
              let soc = client.batteryPercent, soc < 100 else {
            return "充电速率：数据不足"
        }
        let perHour = (100 - soc) / (Double(m) / 60.0)
        return String(format: "折算充电速率约 %.1f ％/小时（剩余 %.1f ％ ÷ %.1f 小时）",
                      perHour, 100 - soc, Double(m) / 60.0)
    }

    // MARK: - 预约充电

    @ViewBuilder
    private var scheduleCard: some View {
        LMCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SectionHeader(text: "预约充电")
                    Spacer(minLength: 0)
                    if let s = client.chargeSchedule {
                        StatusPill(text: s.isEnabled ? "已开启" : "已关闭",
                                   icon: s.isEnabled ? "checkmark.circle.fill" : "xmark.circle",
                                   tint: s.isEnabled ? Color.lmGood : Color.secondary)
                    }
                }

                if let s = client.chargeSchedule {
                    HStack(alignment: .center, spacing: 14) {
                        timeBox("开始", s.beginTime, Color.lmAccent)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        timeBox("结束", s.endTime, Color.lmTeal)
                        Spacer(minLength: 0)
                    }

                    Divider()

                    keyValue("重复", s.weekdayText)
                    keyValue("目标电量", s.targetPercent.map { "\($0) %" } ?? "--")
                    keyValue("每周循环", s.isCirculating ? "是" : "否")
                    if let u = s.updateTime, !u.isEmpty {
                        keyValue("配置更新时间", u)
                    }

                    Text("本页只读。写预约充电的接口没有抓包样本，"
                         + "在没有验证清楚之前不会去改你车上的设置 —— 要用改时间/改目标电量，"
                         + "请先在官方 App 里改。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                        Text("没有读到预约充电配置。下拉刷新，或到官方 App 确认是否设置过。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("重新加载配置") {
                        Task { try? await client.refreshCommonConfig() }
                    }
                    .buttonStyle(.bordered)
                }

                // config["4"] 之类的其它配置项，按编号原样列出来
                if !otherBlobs.isEmpty {
                    Divider()
                    Text("其它车辆配置（commonConfig.config）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(otherBlobs) { item in
                        keyValue("config[\"\(item.id)\"]", item.text)
                    }
                }
            }
        }
    }

    /// ★ 不要用 `ForEach(数组, id: \.key)` 配元组数组 ——
    ///   Swift 的 key path 不能指向元组成员，会报
    ///   "key path cannot refer to tuple element"。上一轮已经踩过一次，
    ///   所以这里老老实实建一个 Identifiable 结构体。
    private struct ConfigBlobRow: Identifiable {
        let id: String
        let text: String
    }

    /// config["3"] 之外的配置项
    private var otherBlobs: [ConfigBlobRow] {
        client.configBlobs
            .filter { $0.key != "3" }
            .sorted { $0.key < $1.key }
            .map { ConfigBlobRow(id: $0.key, text: ChargeView.describe($0.value)) }
    }

    static func describe(_ b: LMConfigBlob) -> String {
        var parts: [String] = []
        if let mac = b.mac, !mac.isEmpty { parts.append("mac \(mac)") }
        if let v = b.version, !v.isEmpty { parts.append("version \(v)") }
        if let t = b.updateTime, !t.isEmpty { parts.append("更新于 \(t)") }
        if let p = b.percent { parts.append("percent \(p)") }
        if let e = b.isEnable { parts.append("isEnable \(e)") }
        if let bt = b.beginTime { parts.append("begin \(bt)") }
        if let et = b.endTime { parts.append("end \(et)") }
        return parts.isEmpty ? "（空）" : parts.joined(separator: " · ")
    }

    private func timeBox(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    // MARK: - 电池

    private var batteryCard: some View {
        VStack(spacing: 10) {
            SectionHeader(text: "电池")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                MetricTile(title: "电池温度",
                           value: client.batteryTemp.map { String(format: "%.1f ℃", $0) } ?? "--",
                           icon: "thermometer.medium",
                           tint: Color.lmWarn,
                           sub: "信号 2183")
                MetricTile(title: "SOC（原始）",
                           value: client.signalText("100003", unit: "%"),
                           icon: "bolt.fill",
                           tint: Color.lmGood,
                           sub: "信号 100003")
                MetricTile(title: "SOC（取整）",
                           value: client.signalText("1204", unit: "%"),
                           icon: "bolt.circle",
                           tint: Color.lmGood,
                           sub: "信号 1204")
                MetricTile(title: "车内温度",
                           value: client.interiorTemp.map { String(format: "%.1f ℃", $0) } ?? "--",
                           icon: "car.side",
                           tint: Color.lmTeal,
                           sub: "信号 1349")
            }
        }
    }

    // MARK: - 续航

    private var rangeCard: some View {
        VStack(spacing: 10) {
            SectionHeader(text: "续航")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                MetricTile(title: "剩余续航（主）",
                           value: client.rangeKm.map { "\(Int($0.rounded())) km" } ?? "--",
                           icon: "road.lanes",
                           tint: Color.lmAccent,
                           sub: "信号 3257")
                MetricTile(title: "剩余续航（副）",
                           value: client.rangeAltKm.map { "\(Int($0.rounded())) km" } ?? "--",
                           icon: "road.lanes.curved.left",
                           tint: Color.lmIndigo,
                           sub: "信号 3260 / 2188")
                MetricTile(title: "满电估算（主）",
                           value: client.fullRangeEstimateKm.map { "\(Int($0.rounded())) km" } ?? "--",
                           icon: "battery.100.bolt",
                           tint: Color.lmPurple,
                           sub: "3257 ÷ SOC 反推")
                MetricTile(title: "满电估算（副）",
                           value: client.fullRangeAltEstimateKm.map { "\(Int($0.rounded())) km" } ?? "--",
                           icon: "battery.75",
                           tint: Color.lmPurple,
                           sub: "3260 ÷ SOC 反推")
            }
            Text("两套续航是不同工况标准（3257/SOC ≈ 7.17、3260/SOC ≈ 5.77，四个快照全部严格线性）。"
                 + "「满电估算」是拿当前续航按 SOC 等比例放大出来的，SOC 越低误差越大，只当参考。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if let h = client.rangeHoursAt60 {
                Text(String(format: "按 60 km/h 均速粗估，当前续航还能跑约 %.1f 小时（估算，不是官方数据）。", h))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - 疑似项

    private var guessCard: some View {
        LMCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.diamond.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.lmWarn)
                    Text("待确认的信号（别当官方数字用）")
                        .font(.footnote.weight(.semibold))
                }

                if let kw = client.chargePowerGuessKW {
                    keyValue("1177 ÷ 100", String(format: "%.2f kW", kw))
                    Text("读作「充电功率 ×100 W」时是 \(String(format: "%.2f", kw)) kW，"
                         + "正好是 7kW 交流桩的典型值。但也可能读作电池电压（736.7 V）。"
                         + "想确认的话：拔枪后抓一次快照 —— 变 0 就是功率。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let a = client.chargeCurrentGuessA {
                    keyValue("1178（绝对值）", String(format: "%.1f A", a))
                    Text("原始值是负的（-3.7 ~ -8.4），负号含义未定。"
                         + "抓包里充电期间一直在小幅抖动，像电流采样。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("这两个是本次分析里唯一没定下来的量。"
                     + "「设置 → 诊断 → 信号浏览器」里可以抓两次快照做对比，"
                     + "充电 / 拔枪各抓一次就能定下来。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 说明

    private var footnote: some View {
        Text("""
        数据来源：signalMap（车况实时信号）+ /carownerservice/v3/api/vehicleinfo/commonConfig（预约充电配置）。
        「疑似充电中」是从「剩余充电时间 > 0」推断的 —— 我们没有找到直接的充电状态位信号，
        所以不敢写成「正在充电」。
        """)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    // MARK: - 小工具

    private func infoRow(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
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

    private func keyValue(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(v)
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    private var updateText: String {
        guard let d = client.lastUpdate else { return "尚未刷新" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "更新于 \(f.string(from: d))"
    }
}
