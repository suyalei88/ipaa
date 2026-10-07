//
//  SignalExplorerView.swift
//  LeapmotorLite
//
//  原始信号浏览器 + 快照对比。
//
//  为什么要有这个页面：
//    零跑的 signalMap 有 130 个 id，但服务端不下发任何名称 —— 抓到的是
//    {"100003":41.4, "3257":298, ...}，全靠反推。已经确认的那十几个
//    （见 LMSignalCatalog）够做车况/定位/充电三页了，剩下 90 多个
//    **只能在车动起来的时候靠「哪个 id 变了」来认**。
//
//    所以这里做两件事：
//      1. 把已知/未知全部摊开，可搜索、带置信度标注；
//      2. 「抓快照 A → 去做一个动作（开车/充电/开空调/锁车）→ 抓快照 B → 对比」，
//         只列出变了的 id。这是唯一能低成本识别未知信号的办法。
//
//  ★ 快照存在内存里，不进 Keychain、不落盘、不上传。复制出来是给用户自己看的。
//
import SwiftUI
import UIKit
import Foundation

struct SignalExplorerView: View {
    @EnvironmentObject var client: LMClient

    @State private var query = ""
    @State private var showOnlyChanged = false
    @State private var snapA: SignalSnapshot?
    @State private var snapB: SignalSnapshot?
    @State private var showDiff = false
    @State private var copied = false

    /// 基线快照：开启「只看变化」时用来比较
    @State private var baseline: SignalSnapshot?

    var body: some View {
        List {
            snapshotSection

            if showOnlyChanged {
                changedSection
            } else {
                // ★ ForEach 的元素**必须直接是 Section**。
                //   写成 `ForEach(...) { Group { if ... { Section {...} } } }` 时，
                //   List 拿到的元素是「Group 包着 Optional<Section>」，静态识别不出分区，
                //   分区头会消失、样式退化成普通行。所以这里先在数组里过滤干净，
                //   ForEach 里第一层就是 Section。
                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.refs) { ref in
                            signalRow(id: ref.id,
                                      name: ref.name,
                                      badge: ref.confidence.badge,
                                      note: ref.note,
                                      unit: ref.unit,
                                      tint: confidenceTint(ref.confidence))
                        }
                    } header: {
                        Label(group.category.rawValue, systemImage: group.category.icon)
                    }
                }
                unknownSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("信号浏览器")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索 id 或名称")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("只看有变化的信号", isOn: $showOnlyChanged)
                    Divider()
                    Button {
                        baseline = SignalSnapshot.capture(client.signals)
                        showOnlyChanged = true
                    } label: {
                        Label("把当前值设为基线", systemImage: "pin")
                    }
                    Button {
                        baseline = nil
                    } label: {
                        Label("清除基线", systemImage: "pin.slash")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("筛选")
            }
        }
        .sheet(isPresented: $showDiff) {
            NavigationStack { diffSheet }
        }
    }

    // MARK: - 快照工具

    private var snapshotSection: some View {
        Section {
            HStack(spacing: 10) {
                snapshotButton(title: "抓快照 A", filled: snapA != nil) {
                    snapA = SignalSnapshot.capture(client.signals)
                }
                snapshotButton(title: "抓快照 B", filled: snapB != nil) {
                    snapB = SignalSnapshot.capture(client.signals)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Button {
                showDiff = true
            } label: {
                Label("对比 A / B（只列变化）", systemImage: "arrow.left.arrow.right")
            }
            .disabled(snapA == nil || snapB == nil)

            Button {
                copySnapshotJSON()
            } label: {
                Label(copied ? "已复制到剪贴板" : "复制当前全部信号（JSON）",
                      systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
            }
            .disabled(client.signals.isEmpty)
        } header: {
            Text("快照对比")
        } footer: {
            Text("""
            用法：抓快照 A → 去车上做一个动作（插枪充电 / 开空调 / 锁车 / 开窗）→ 回来刷新车况 → 抓快照 B → 对比。
            变了的 id 就是这个动作对应的信号。这是识别未知信号最省事的办法。

            快照只存在内存里，退出即消失。
            """)
        }
    }

    private func snapshotButton(title: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: filled ? "checkmark.circle.fill" : "camera.fill")
                    .font(.system(size: 13))
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
        .disabled(client.signals.isEmpty)
    }

    // MARK: - 差异表

    private var changedSection: some View {
        Section {
            let changed = SignalSnapshot.diff(baseline, SignalSnapshot.capture(client.signals))
            if changed.isEmpty {
                Text("相对基线没有变化（\(baseline == nil ? "未设基线" : "共 \(baseline?.values.count ?? 0) 个信号")）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(changed) { item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.id)
                                .font(.system(.callout, design: .monospaced))
                            if let r = LMSignalCatalog.ref(item.id) {
                                Text("\(r.confidence.badge) \(r.name)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            Text(item.oldValue)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(item.newValue)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Color.lmAccent)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("相对基线的变化")
                Spacer()
                Text("\(client.signals.count) 个信号")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 分类列表

    /// 过滤掉搜索后为空的分类（空分区在 List 里会留一块白）
    private var visibleGroups: [LMSignalCatalog.LMGroup] {
        LMSignalCatalog.grouped().compactMap { g in
            let refs = g.refs.filter { matches($0.id, $0.name) }
            return refs.isEmpty ? nil : LMSignalCatalog.LMGroup(category: g.category, refs: refs)
        }
    }

    /// 有 id 但目录里没名字的
    private var unknownIds: [String] {
        client.signals.keys
            .filter { !LMSignalCatalog.knownIds.contains($0) }
            .filter { matches($0, nil) }
            .sorted { LMSignalCatalog.numeric($0) < LMSignalCatalog.numeric($1) }
    }

    /// 这一块**恒为一个 Section**（内部再判空），
    /// 否则「有未命名信号才出现」的分区会被 List 当成非分区内容。
    private var unknownSection: some View {
        Section {
            if unknownIds.isEmpty {
                Text("没有未命名的信号 —— 目录已经覆盖服务端下发的全部 id。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(unknownIds, id: \.self) { id in
                    signalRow(id: id,
                              name: "未命名信号",
                              badge: "❓",
                              note: "还没识别出来。做动作前后各抓一次快照就能认。",
                              unit: "",
                              tint: Color.secondary)
                }
            }
        } header: {
            Label("未命名（\(unknownIds.count)）", systemImage: "questionmark.circle")
        } footer: {
            Text("服务端只下发 id 和值，不下发名称。这些需要靠「抓快照 → 做动作 → 再抓快照」来反推。")
        }
    }

    private func signalRow(id: String, name: String, badge: String,
                           note: String, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(id)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(badge)
                    .font(.caption2)
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(client.signalText(id, unit: unit))
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            if !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// ★ 方法名别叫 `tint` —— 会和 View 自带的 `.tint(_:)` 修饰符同名。
    ///   上一轮在 ControlPanelView 里踩过同类坑（`let tint = tint(for:)` 报
    ///   "use of local variable before its declaration"），这里直接改名躲开。
    private func confidenceTint(_ c: LMConfidence) -> Color {
        switch c {
        case .confirmed: return Color.lmGood
        case .observed:  return Color.lmWarn
        case .unknown:   return Color.secondary
        }
    }

    private func matches(_ id: String, _ name: String?) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.trimmingCharacters(in: .whitespaces)
        if id.contains(q) { return true }
        if let n = name, n.localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    // MARK: - 对比 Sheet

    private var diffSheet: some View {
        let items = SignalSnapshot.diff(snapA, snapB)
        return List {
            if items.isEmpty {
                Section {
                    Text("两个快照完全相同 —— 说明这期间车辆没有任何信号变化。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.id)
                                    .font(.system(.callout, design: .monospaced))
                                if let r = LMSignalCatalog.ref(item.id) {
                                    Text(r.confidence.badge)
                                        .font(.caption2)
                                    Text(r.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                            }
                            HStack(spacing: 6) {
                                Text(item.oldValue)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Text(item.newValue)
                                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(Color.lmAccent)
                            }
                            if let r = LMSignalCatalog.ref(item.id), !r.note.isEmpty {
                                Text(r.note)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("\(items.count) 个信号发生变化")
                }

                Section {
                    Button {
                        copyDiff(items)
                    } label: {
                        Label("复制差异（文本）", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationTitle("快照对比")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { showDiff = false }
            }
        }
    }

    // MARK: - 复制

    private func copySnapshotJSON() {
        guard !client.signals.isEmpty else { return }
        var dict: [String: String] = [:]
        for (k, v) in client.signals { dict[k] = v.displayText }
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return }
        UIPasteboard.general.string = s
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            copied = false
        }
    }

    private func copyDiff(_ items: [SignalSnapshot.Change]) {
        var lines: [String] = ["signalId\t旧\t新\t备注"]
        for i in items {
            let name = LMSignalCatalog.ref(i.id).map { "\($0.confidence.badge)\($0.name)" } ?? "未命名"
            lines.append("\(i.id)\t\(i.oldValue)\t\(i.newValue)\t\(name)")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
    }
}

// MARK: - 快照

/// 一份 signalMap 的只读拷贝。值统一转成展示文本 —— 我们只关心「变了没」。
struct SignalSnapshot {
    let takenAt: Date
    /// id → 展示文本
    let values: [String: String]

    struct Change: Identifiable {
        let id: String
        let oldValue: String
        let newValue: String
    }

    static func capture(_ signals: [String: LMSignalValue]) -> SignalSnapshot {
        var m: [String: String] = [:]
        for (k, v) in signals { m[k] = v.displayText }
        return SignalSnapshot(takenAt: Date(), values: m)
    }

    /// 只列出值不同的 id（并集）。任一侧缺失时显示 "--"。
    ///
    /// 注意：新增/消失的 id 也算「变化」—— 车辆休眠时服务端会少下发一批信号，
    /// 这个本身就是信息（比如「哪几个 id 只在充电时出现」）。
    static func diff(_ a: SignalSnapshot?, _ b: SignalSnapshot?) -> [Change] {
        guard let a = a, let b = b else { return [] }
        var keys = Set(a.values.keys)
        keys.formUnion(b.values.keys)
        let changes = keys.compactMap { k -> Change? in
            let old = a.values[k] ?? "--"
            let new = b.values[k] ?? "--"
            guard old != new else { return nil }
            return Change(id: k, oldValue: old, newValue: new)
        }
        return changes.sorted { LMSignalCatalog.numeric($0.id) < LMSignalCatalog.numeric($1.id) }
    }
}
