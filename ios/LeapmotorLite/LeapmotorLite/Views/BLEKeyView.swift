//
//  BLEKeyView.swift
//  LeapmotorLite
//
//  蓝牙钥匙。
//
//  ⚠️ 先读这段再改：
//  这个页面的**上半部分是真的**（钥匙记录来自云端 commonConfig，接口探测真的发请求），
//  **下半部分是进度说明**（协议还差什么）。绝对不要在 UI 上写「点此解锁」——
//  我们还没拿到 passwordCard 和 cmdId 表，发出去的字节是猜的，
//  拿真车做实验不负责任。真正的 BLE 协议证据见 LMBLEProtocol.swift 文件头。
//
//  页面结构：
//    ① 蓝牙状态 + 钥匙记录（云端真数据）
//    ② 三个行为开关（本机记录，明确标注不影响官方 App）
//    ③ 云端接口探测（只读，最重要的一步 —— 看服务端吐不吐钥匙材料）
//    ④ 协议进度（已确认 / 待解决，数据来自 LMBLEQuestions）
//    ⑤ 入口：BLE 调试台 / 协议自检
//
import SwiftUI
import Foundation

struct BLEKeyView: View {

    @EnvironmentObject var client: LMClient

    /// ★ 中心设备由本页持有，再传给调试页。
    ///   好处：蓝牙权限只在用户真的打开这个页面时才请求（不是 App 一启动就弹），
    ///   而且两个页面共用同一个连接状态，不会出现「调试页连着、钥匙页显示未连接」。
    @StateObject private var ble = LMBLECentral()

    @State private var prefs = LMBLEKeyPrefs.load()
    @State private var probing = false

    var body: some View {
        Form {
            bleStatusSection
            keyRecordSection
            switchSection
            cloudSection
            progressSection
            toolSection
        }
        .navigationTitle("蓝牙钥匙")
        .onAppear { ble.prepare() }
        // ★ LMBLEKeyPrefs 是 Equatable，可以整体监听；改了就落盘
        .onChange(of: prefs) { _, new in new.save() }
    }

    // MARK: - ① 蓝牙状态

    private var bleStatusSection: some View {
        Section {
            HStack {
                Label(ble.state.rawValue,
                      systemImage: ble.state.canUse ? "bluetooth" : "bluetooth.slash")
                    .foregroundStyle(ble.state.canUse ? Color.lmGood : Color.lmWarn)
                Spacer()
                if ble.isScanning {
                    Text("扫描中").font(.caption).foregroundStyle(Color.lmAccent)
                }
            }

            if let c = ble.connected {
                HStack {
                    Label("已连接 \(c.name)", systemImage: "link")
                        .foregroundStyle(Color.lmGood)
                    Spacer()
                    Text("\(c.rssi) dBm")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if ble.state.needsUserAction {
                Label("需要你手动处理：\(ble.state.rawValue)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.lmWarn)
            }
        } header: {
            Text("蓝牙")
        } footer: {
            Text("""
            官方 App 的 Info.plist 里写得很明白：
            权限用途 = 「用于蓝牙钥匙、自动泊车」，后台模式含 bluetooth-central 和 bluetooth-peripheral。
            也就是说蓝牙钥匙走的是手机直连车端 BLE 模组，跟车控走的 HTTPS 是两条完全独立的链路。
            """)
        }
    }

    // MARK: - ② 钥匙记录（云端）

    private var keyRecordSection: some View {
        Section {
            if let r = client.bleKeyRecord {
                row("车端钥匙 MAC", r.macPretty)
                row("协议版本", r.versionText)
                if let t = r.updateTime { row("绑定时间", t) }
                Label("已绑定", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.lmGood)
            } else if client.configBlobs.isEmpty {
                Label("还没读到车辆配置", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Button("刷新车辆配置") {
                    Task { try? await client.refreshCommonConfig() }
                }
            } else {
                Label("这台车在云端没有蓝牙钥匙记录", systemImage: "xmark.seal")
                    .foregroundStyle(Color.lmWarn)
                Text("说明还没在官方 App 里绑定过蓝牙钥匙。绑定后才能拿到钥匙材料。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("云端钥匙记录")
        } footer: {
            Text("""
            来自 GET /carownerservice/v3/api/vehicleinfo/commonConfig 的 config["4"]。

            ⚠️ 这里只有「哪把钥匙」（MAC）和协议版本，**没有密钥材料**。
            真正用来加密的 passwordCard 是配对时服务端下发的，不在这个接口里。
            """)
        }
    }

    // MARK: - ③ 三个开关

    private var switchSection: some View {
        Section {
            Toggle("靠近自动解锁", isOn: $prefs.autoUnlock)
            Toggle("远离自动闭锁", isOn: $prefs.autoLock)
            Toggle("门把手解锁", isOn: $prefs.doorUnlock)
        } header: {
            Text("行为开关")
        } footer: {
            Text("""
            \(LMBLEKeyPrefs.featureDescription)

            ⚠️ 这三个开关目前**只是本机记录，不影响官方 App、也不会真的触发任何动作**。
            官方把它们存在自己的 UserDefaults 里（LMVBLEAutoLockKey / LMVBLEAutoUnLockKey /
            LMVBLEDoorUnLockKey），且是跟「配对后的钥匙」绑定的。
            等 BLE 协议打通、能自己解锁了，它们才会接上真正的行为。
            """)
        }
    }

    // MARK: - ④ 云端接口探测

    private var cloudSection: some View {
        Section {
            Button {
                Task {
                    probing = true
                    await client.probeBLEKeyReadOnly()
                    probing = false
                }
            } label: {
                HStack {
                    Label("探测云端钥匙接口（只读）", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if probing { ProgressView() }
                }
            }
            .disabled(probing || client.selectedVehicle == nil)

            ForEach(client.bleProbes.prefix(3)) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(p.ok ? "✅" : "❌")
                        Text(p.title).font(.caption.weight(.semibold))
                        Spacer()
                        Text(p.timeText).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(p.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(p.response.prefix(400))
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(6)
                }
            }

            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("更多接口探测（含配对码 / 删钥匙）", systemImage: "stethoscope")
            }
        } header: {
            Text("云端接口")
        } footer: {
            Text("""
            只探 syncBluetoothKeys —— 它是唯一「语义上是取数据」的接口。
            ccc/pairingcode 会在服务端建待配对会话、ccc/delKey 会删钥匙，
            这两个是**改状态**的，只能在诊断页手动触发。

            ★ 这一步是解锁 BLE 的关键：如果服务端在这里把 passwordCard 吐回来，
            整套 BLE 协议就能自己实现。
            """)
        }
    }

    // MARK: - ⑤ 协议进度

    private var progressSection: some View {
        Section {
            NavigationLink {
                BLEProtocolStatusView()
            } label: {
                HStack {
                    Label("协议进度", systemImage: "list.bullet.clipboard")
                    Spacer()
                    Text("\(LMBLEQuestions.settled.count) 项已定 / \(LMBLEQuestions.blocking.count) 项待解决")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - ⑥ 工具入口

    private var toolSection: some View {
        Section {
            NavigationLink {
                BLEDebugView(ble: ble)
            } label: {
                Label("BLE 调试台（扫描 / GATT / 抓帧）", systemImage: "wave.3.right")
            }
            NavigationLink {
                BLEKeySelfCheckView()
            } label: {
                Label("协议自检（帧切分 / hex / MAC）", systemImage: "checkmark.shield")
            }
        } header: {
            Text("工具")
        } footer: {
            Text("调试台是「把协议补完」的工具：连上车、订阅通知、然后用官方 App 操作一次车，每一帧都会被原样记下来。")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - 协议进度页

struct BLEProtocolStatusView: View {

    var body: some View {
        List {
            Section {
                ForEach(LMBLEQuestions.settled, id: \.self) { s in
                    Label(s, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.lmGood)
                }
            } header: {
                Text("已确认（\(LMBLEQuestions.settled.count)）")
            } footer: {
                Text("全部来自官方 IPA 主二进制的静态逆向，证据见 LMBLEProtocol.swift 文件头。")
            }

            Section {
                ForEach(LMBLEQuestions.blocking) { q in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(q.question, systemImage: "questionmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.lmWarn)
                        Text("怎么定下来：\(q.howToSettle)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("用哪一步：\(q.tool)")
                            .font(.caption2)
                            .foregroundStyle(Color.lmAccent)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("待解决（\(LMBLEQuestions.blocking.count)）")
            } footer: {
                Text("""
                这五项不解完，就不该往真车发字节。
                前四项靠 BLE 调试台 + 官方 App 抓帧就能定；第五项要动态 hook。
                """)
            }
        }
        .navigationTitle("协议进度")
    }
}

// MARK: - 协议自检页

struct BLEKeySelfCheckView: View {

    private let results = LMBLEKeySelfCheck.run()

    private var passed: Int { results.filter(\.passed).count }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("通过")
                    Spacer()
                    Text("\(passed) / \(results.count)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(passed == results.count ? Color.lmGood : Color.lmBad)
                }
            }
            Section {
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.passed ? Color.lmGood : Color.lmBad)
                            Text(r.name).font(.footnote)
                        }
                        Text(r.detail)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            } header: {
                Text("解析自检")
            } footer: {
                Text("""
                测的是「解析层」：MAC 排版、config["4"] 构造、hex 容错、
                以及官方那三个分号帧模板的切分是否正确。
                帧的**语义**还没定，自检只保证切分不切错。
                """)
            }
        }
        .navigationTitle("协议自检")
    }
}
