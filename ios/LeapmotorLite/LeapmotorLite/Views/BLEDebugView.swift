//
//  BLEDebugView.swift
//  LeapmotorLite
//
//  BLE 调试台 —— 把蓝牙钥匙协议「补完」用的工具。
//
//  它不是一个玩具：官方那套是 ECDH + 对称加密 + 时间戳防重放的私有协议，
//  静态逆向只拿到了字段名和帧模板（见 LMBLEProtocol.swift），
//  拿不到 passwordCard、帧语义、cmdId 表。这三样**只能靠真实抓帧**。
//
//  正确用法（一次就能把帧语义定下来）：
//    ① 站到车旁边 → 扫描 → 找到车（会打「疑似车辆」标）
//    ② 连接 → GATT 树会把服务/特征/属性原样列出来
//       → 这一步解决「FFED0000 是服务还是特征」「FFF2 是什么」
//    ③ 确认有「通知」属性的特征已被订阅（连上后会自动订阅）
//    ④ 这时**切到官方 App**，用它的蓝牙钥匙解一次锁
//    ⑤ 回到本页看日志 —— 每一帧都会以 hex / ASCII / 分号切分三种形式记下来
//    ⑥ 重复 ④ 做一次「闭锁」，两帧一比，cmdId 和字段语义就出来了
//
//  ⚠️ 本页的「发送」只能发**你自己输入**的字节，没有任何内置的「解锁」按钮。
//     原因：帧语义没定之前，随便发字节等于拿真车做实验。
//
import SwiftUI
import UIKit
import Foundation

struct BLEDebugView: View {

    @ObservedObject var ble: LMBLECentral

    @State private var filterByService = true
    @State private var hexInput = ""
    @State private var inputError: String?
    @State private var logFilter: LogFilter = .all
    @State private var writeService: String?
    @State private var writeChar: String?
    @State private var copied = false

    private enum LogFilter: String, CaseIterable, Identifiable {
        case all, rx, tx, info
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:  return "全部"
            case .rx:   return "接收"
            case .tx:   return "发送"
            case .info: return "系统"
            }
        }
    }

    var body: some View {
        List {
            stateSection
            deviceSection
            gattSection
            writeSection
            logSection
        }
        .navigationTitle("BLE 调试台")
        .onAppear { ble.prepare() }
    }

    // MARK: - 状态 / 扫描

    private var stateSection: some View {
        Section {
            HStack {
                Label(ble.state.rawValue,
                      systemImage: ble.state.canUse ? "bluetooth" : "bluetooth.slash")
                    .foregroundStyle(ble.state.canUse ? Color.lmGood : Color.lmWarn)
                Spacer()
                if let c = ble.connected {
                    Text("\(c.rssi) dBm")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("只扫官方服务 UUID", isOn: $filterByService)

            HStack {
                Button {
                    ble.startScan(filterByService: filterByService)
                } label: {
                    Label(ble.isScanning ? "重新扫描" : "开始扫描", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(!ble.state.canUse)

                Spacer()

                if ble.isScanning {
                    Button("停止") { ble.stopScan() }
                }
            }

            if let e = ble.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.lmBad)
            }
        } header: {
            Text("状态")
        } footer: {
            Text("""
            过滤用的 UUID 是从官方二进制里挖的：\(LMBLEUUID.service)
            扫不到车时关掉过滤再扫一次 —— 有可能车只在配对态才广播那个服务。
            """)
        }
    }

    // MARK: - 设备列表

    private var deviceSection: some View {
        Section {
            if ble.devices.isEmpty {
                Text(ble.isScanning ? "扫描中…" : "还没扫到设备 —— 点上面「开始扫描」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(ble.devices.sorted { $0.rssi > $1.rssi }) { d in
                deviceRow(d)
            }
        } header: {
            Text("发现 \(ble.devices.count) 个设备")
        } footer: {
            Text("""
            ⚠️ 这里的 ID 是 iOS 分配给外设的 identifier，**不是 MAC 地址**。
            iOS 从 iOS 7 起就不把 MAC 给 App 了，两台手机上同一个车拿到的 ID 也不同。
            要认车只能靠名字、广播里的厂商数据、或者连上后读特征值。
            官方 commonConfig 里那个 mac（C8C83FF5C48E）是车端记录的，跟这里对不上。
            """)
        }
    }

    @ViewBuilder
    private func deviceRow(_ d: LMBLEDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if d.isLikelyVehicle {
                    Image(systemName: "car.fill").foregroundStyle(Color.lmAccent)
                }
                Text(d.name).font(.footnote.weight(.semibold))
                if d.isLikelyVehicle {
                    Text("疑似车辆")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.lmAccent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.lmAccent.opacity(0.14), in: Capsule())
                }
                Spacer()
                Text("\(d.rssi) dBm")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(d.rssi > -70 ? Color.lmGood : Color.secondary)
            }

            Text("\(d.shortId) · \(d.stateText)\(d.isConnectable ? "" : " · 不可连接")")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            if !d.advertisement.isEmpty {
                DisclosureGroup("广播内容（\(d.advertisement.count) 项）") {
                    // ★ 不用 `ForEach(dict.sorted(by:), id: \.key)` ——
                    //   `sorted(by:)` 返回的是元组数组，`\.key` 是**元组 key path**，
                    //   Swift 的 key path 不能指向元组成员，直接编译不过。
                    //   改成先排 key 再回查字典，彻底绕开。
                    ForEach(d.advertisement.keys.sorted(), id: \.self) { k in
                        HStack(alignment: .top, spacing: 8) {
                            Text(k)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 68, alignment: .leading)
                            Text(d.advertisement[k] ?? "")
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(4)
                                .truncationMode(.middle)
                        }
                    }
                }
                .font(.caption2)
            }

            HStack {
                if ble.connected?.id == d.id {
                    Button("断开") { ble.disconnect() }
                        .font(.caption)
                    Button("重发现服务") { ble.rediscover() }
                        .font(.caption)
                    Button("读 RSSI") { ble.readRSSI() }
                        .font(.caption)
                } else {
                    Button("连接") { ble.connect(d) }
                        .font(.caption)
                        .disabled(!d.isConnectable)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - GATT 树

    private var gattSection: some View {
        Section {
            if ble.connected == nil {
                Text("未连接 —— 先在上面选一个设备点「连接」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if ble.services.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在发现服务与特征…").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(ble.services) { s in
                DisclosureGroup {
                    if s.characteristics.isEmpty {
                        Text("（这个服务下没有特征）").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(s.characteristics) { c in
                        charRow(service: s.uuid, char: c)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.uuid)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if s.uuid.uppercased().hasPrefix("FFED") {
                                Text("官方字面量")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.lmAccent)
                            }
                            Text(s.isPrimary ? "主服务" : "次要服务")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(s.characteristics.count) 个特征")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("GATT 树（\(ble.services.count) 个服务）")
        } footer: {
            Text("连上后会自动订阅所有可通知的特征 —— 抓官方帧就靠这一步。")
        }
    }

    private func charRow(service: String, char c: LMBLECharacteristic) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(c.uuid)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(2)

            HStack(spacing: 4) {
                ForEach(c.props, id: \.self) { p in
                    Text(p)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.lmIndigo)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.lmIndigo.opacity(0.13), in: Capsule())
                }
            }

            if let v = c.lastValue {
                Text("最新值：\(v)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                if c.canNotify {
                    Button(c.isNotifying ? "取消订阅" : "订阅") {
                        ble.toggleNotify(serviceUUID: service, charUUID: c.uuid)
                    }
                    .font(.caption2)
                }
                Button("读一次") {
                    ble.readValue(serviceUUID: service, charUUID: c.uuid)
                }
                .font(.caption2)
                if c.canWrite || c.canWriteNoResponse {
                    Button("设为写入目标") {
                        writeService = service
                        writeChar = c.uuid
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.lmAccent)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 发送

    private var writeSection: some View {
        Section {
            if ble.connected == nil {
                Text("未连接 —— 连上之后才能发字节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let s = writeService, let c = writeChar {
                HStack {
                    Text("目标")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(c)")
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(s)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("还没选写入目标 —— 在上面 GATT 树里点「设为写入目标」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("写入用「有应答」模式", isOn: $ble.writeWithResponse)

            TextField("十六进制，如 FF ED 12 34", text: $hexInput, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1...4)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .onChange(of: hexInput) { _, v in
                    inputError = v.isEmpty ? nil : LMBLEHex.validate(v)
                }

            if let e = inputError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.lmWarn)
            } else if let d = LMBLEHex.data(from: hexInput) {
                Text("= \(d.count) 字节：\(LMBLEHex.string(d))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button {
                send()
            } label: {
                Label("发送", systemImage: "paperplane.fill")
            }
            .disabled(inputError != nil || hexInput.isEmpty || writeChar == nil)

            DisclosureGroup("快捷载荷（连通性测试，不是有效指令）") {
                ForEach(LMBLEPreset.all) { p in
                    Button {
                        hexInput = p.hex
                        inputError = LMBLEHex.validate(p.hex)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.label).font(.caption.weight(.semibold))
                            Text(p.hex)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.lmAccent)
                            Text(p.note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.caption)
        } header: {
            Text("发送原始字节")
        } footer: {
            Text("""
            ⚠️ 官方帧语义还没定（见「协议进度」）。这里的预设只验证「写入通路 + 分包 + 应答」通不通，
            **不是**已知的有效指令。不要凭猜往真车发指令。
            超过 MTU 会自动分包，日志里能看到每一包。
            """)
        }
    }

    private func send() {
        guard let s = writeService, let c = writeChar,
              let d = LMBLEHex.data(from: hexInput) else { return }
        ble.write(serviceUUID: s, charUUID: c, data: d)
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            Picker("过滤", selection: $logFilter) {
                ForEach(LogFilter.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button {
                    UIPasteboard.general.string = ble.exportLog()
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制全部日志", systemImage: "doc.on.doc")
                }
                .font(.caption)
                Spacer()
                Button(role: .destructive) {
                    ble.clearLog()
                    copied = false
                } label: {
                    Text("清空").font(.caption)
                }
            }

            let shown = filteredLog
            if shown.isEmpty {
                Text("（还没有日志）").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown) { e in
                logRow(e)
            }

            if ble.log.count > shown.count {
                Text("只显示最近 \(shown.count) 条（共 \(ble.log.count) 条）")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("日志（帧 \(frameCount) / 共 \(ble.log.count) 条）")
        } footer: {
            Text("""
            「复制全部日志」会把设备、服务列表和每一帧的 hex / 文本 / 分号切分一起导出。
            抓帧步骤：连上车 → 订阅通知 → **切到官方 App 操作一次** → 回来复制日志。
            """)
        }
    }

    private var frameCount: Int { ble.log.filter { $0.hasPayload }.count }

    /// 只渲染最近 300 条 —— 订阅通知后一秒能来几十帧，全渲染会卡死
    private var filteredLog: [LMBLELogEntry] {
        let base: [LMBLELogEntry]
        switch logFilter {
        case .all:  base = ble.log
        case .rx:   base = ble.log.filter { $0.direction == .rx }
        case .tx:   base = ble.log.filter { $0.direction == .tx }
        case .info: base = ble.log.filter { $0.direction == .info || $0.direction == .error }
        }
        return Array(base.suffix(300).reversed())
    }

    private func logRow(_ e: LMBLELogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: e.direction.symbol)
                    .font(.caption2)
                    .foregroundStyle(directionColor(e.direction))
                Text(timeText(e.at))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(e.text)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(3)
            }
            if let h = e.hex {
                Text("hex  \(h)")
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            if let a = e.ascii, a != e.hex {
                Text("text \(a)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.lmTeal)
                    .lineLimit(3)
            }
            if let f = e.fields {
                Text("segs " + f.enumerated()
                        .map { "[\($0.offset)]\($0.element)" }
                        .joined(separator: "  "))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.lmPurple)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 1)
    }

    private func directionColor(_ d: LMBLELogEntry.Direction) -> Color {
        switch d {
        case .info:  return Color.secondary
        case .tx:    return Color.lmAccent
        case .rx:    return Color.lmGood
        case .error: return Color.lmBad
        }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}
