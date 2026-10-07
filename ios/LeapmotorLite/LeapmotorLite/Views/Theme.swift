//
//  Theme.swift
//  LeapmotorLite
//
//  统一配色 + 复用组件（卡片 / 指标磁贴 / 电量环 / 状态胶囊）
//
//  ⚠️ Swift 编译坑（都真烧过一轮 CI）：
//    · foregroundStyle 收的是泛型 ShapeStyle，前导点简写推不出自定义 Color 成员，
//      必须写 `Color.lmAccent`，不能写 `.lmAccent`。
//    · 三元表达式两个分支必须同类型，`Color.red` 和 `.secondary`
//      （HierarchicalShapeStyle）不能混用。
//    改这个文件之前先跑 python ios/tools/lint_swift.py
//
import SwiftUI
import UIKit
import Foundation

// MARK: - 调色板

extension Color {
    /// 零跑蓝
    static let lmAccent  = Color(red: 0.11, green: 0.45, blue: 0.94)
    /// 亮蓝（渐变用）
    static let lmAccent2 = Color(red: 0.36, green: 0.72, blue: 0.98)
    /// 卡片底
    static let lmCard    = Color(.secondarySystemGroupedBackground)

    static let lmGood    = Color(red: 0.16, green: 0.72, blue: 0.42)
    static let lmWarn    = Color(red: 0.98, green: 0.60, blue: 0.12)
    static let lmBad     = Color(red: 0.92, green: 0.26, blue: 0.27)
    static let lmPurple  = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let lmTeal    = Color(red: 0.12, green: 0.68, blue: 0.71)
    static let lmIndigo  = Color(red: 0.35, green: 0.38, blue: 0.85)
}

/// 圆角半径统一（连续曲率，比默认的圆角顺眼）
enum LMRadius {
    static let card: CGFloat = 18
    static let tile: CGFloat = 14
    static let hero: CGFloat = 22
}

// MARK: - 卡片

/// 一块「系统设置风」的圆角卡片。
struct LMCard<Content: View>: View {
    private let padding: CGFloat
    private let radius: CGFloat
    private let content: Content

    init(padding: CGFloat = 16, radius: CGFloat = LMRadius.card,
         @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.lmCard,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - 指标磁贴

/// 小方块：图标 + 标题 + 主值（+ 可选副标题）。
struct MetricTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    /// 显式写 `= nil`：这样 memberwise init 一定带默认值，`sub:` 可以省略
    var sub: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            if let sub = sub, !sub.isEmpty {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lmCard,
                    in: RoundedRectangle(cornerRadius: LMRadius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LMRadius.tile, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - 电量环

/// 剩余电量环形图。
struct BatteryRing: View {
    /// 0...100；nil 表示还没数据
    let percent: Double?
    var size: CGFloat = 136

    private var clamped: Double {
        guard let p = percent else { return 0 }
        return min(max(p, 0), 100)
    }

    private var tint: Color {
        guard let p = percent else { return Color.lmWarn }
        if p <= 15 { return Color.lmBad }
        if p <= 35 { return Color.lmWarn }
        return Color.lmGood
    }

    private var text: String {
        percent == nil ? "--" : String(Int(clamped.rounded()))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 13)

            Circle()
                .trim(from: 0, to: clamped / 100)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.45), tint], center: .center),
                    style: StrokeStyle(lineWidth: 13, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.55), value: clamped)

            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(text)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("剩余电量")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 状态胶囊

/// 车锁 / 已设防之类的小状态标签。
struct StatusPill: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - 区块标题

/// 小写粗体分区标题，配 ScrollView 用（不是 List 的 Section header）。
struct SectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }
}
