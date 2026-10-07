//
//  DiagnosticsView.swift
//  LeapmotorLite
//
//  车控体检 —— 把「真发出去的东西」全摊开
//
//  服务端报「操作密码错误 / 累计出错 3 次」时，只用眼睛看 UI 是没法定位的：
//  到底是①密码输错、②key/iv 派生错、③base64 在 URL 里被 '+' 吃掉了。
//  这一页把 token 头尾、派生 key/iv、最终 oppwd、本地回解明文、上次服务端响应
//  全列出来，还能一键复制，出问题直接把这段发出来就能定案。
//
import SwiftUI
import UIKit
import Foundation

struct DiagnosticsView: View {
    @EnvironmentObject var client: LMClient

    @State private var copied = false

    // 接口探测
    @State private var probeResult: String = ""
    @State private var probeBusy = false

    // 未验证 cmdid 手输下发
    @State private var rawCmdId = "130"
    @State private var rawState = #"{"value":"true"}"#
    @State private var rawConfirm = false
    @State private var rawBusy = false
    @State private var rawResult = ""
    /// 由 .lmClock 每 0.5 秒推一次。
    /// ★ 这个必须有：下面那个「下发」按钮的 disabled 依赖 isControlLocked，
    ///   而它跟当前时间有关。不挂时钟的话倒计时会冻住、锁定期到期后
    ///   按钮也永远不会重新启用 —— R9 规则就是专门拦这个的（这一版真被拦下来了）。
    @State private var now = Date()

    // 蓝牙钥匙接口探测
    @State private var bleBusy = false
    /// 待确认的「会改服务端状态」的蓝牙钥匙操作
    @State private var bleDanger: BLEAction?

    /// 会改服务端状态的蓝牙钥匙接口 —— 必须二次确认才能打。
    ///
    /// ★ 为什么单独列出来：`/v3/api/ccc/*` 和 `/v3/api/bluetoothkey/upload*` 都是
    ///   **写**操作（建配对会话 / 删钥匙 / 上报数据），路径还只是从二进制字符串表
    ///   挖出来的、没验证过。手滑点一下可能把用户已经绑好的蓝牙钥匙删掉。
    ///   所以它们跟「只读探测」在 UI 上必须是两种东西，不能混在一排按钮里。
    private enum BLEAction: String, CaseIterable, Identifiable {
        case pairing
        case delKey
        case calibrate

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pairing:   return "取配对码 ccc/pairingcode"
            case .delKey:    return "删除钥匙 ccc/delKey"
            case .calibrate: return "上报标定参数 bluetoothkey/uploadAutonomyCalibrateParams"
            }
        }

        /// 裸路径（前缀由 probeBLEKey 的调用方拼）
        var path: String {
            switch self {
            case .pairing:   return LMEndpoints.Path.cccPairingCode
            case .delKey:    return LMEndpoints.Path.cccDelKey
            case .calibrate: return LMEndpoints.Path.bleKeyCalib
            }
        }

        var method: String {
            switch self {
            case .pairing:   return "GET"
            case .delKey:    return "GET"
            case .calibrate: return "POST"
            }
        }

        var warning: String {
            switch self {
            case .pairing:
                return "会在服务端建一个「待配对」会话。如果你正在用官方 App 配对，可能会互相干扰。"
            case .delKey:
                return "⚠️ 会删掉已绑定的蓝牙钥匙。删了之后官方 App 的蓝牙钥匙也会失效，需要重新配对。"
            case .calibrate:
                return "会上报一组标定参数，可能覆盖服务端已有的感应区数据，影响官方 App 的「无感」行为。"
            }
        }
    }

    /// ⚠️ 不能用元组数组 + `id: \.id` —— Swift 不支持指向元组成员的 key path。
    /// 老老实实定义个 struct。
    private struct SignalRef: Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        List {
            passwordSection
            lastControlSection
            sessionSection
            signalMapSection
            endpointProbeSection
            bleKeyProbeSection
            rawCmdSection
            copySection
        }
        .navigationTitle("车控体检")
        .onAppear { copied = false }
        // ★ 驱动锁定期倒计时。没有它，「下发」按钮会永久禁用（见上面 now 的注释）。
        .lmClock(until: client.controlLockedUntil, now: $now)
        .confirmationDialog(bleDanger?.title ?? "确认？",
                            isPresented: bleDangerBinding,
                            titleVisibility: .visible) {
            Button("确认执行", role: .destructive) {
                let a = bleDanger
                bleDanger = nil
                if let a = a { Task { await runBLEAction(a) } }
            }
            Button("取消", role: .cancel) { bleDanger = nil }
        } message: {
            Text((bleDanger?.warning ?? "") + "\n\n这个接口的响应结构没有样本，结果会原样列出来。")
        }
        .confirmationDialog("确认下发未验证指令？",
                            isPresented: $rawConfirm,
                            titleVisibility: .visible) {
            Button("确认下发", role: .destructive) {
                Task { await sendRaw() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("cmdid \(rawCmdId) 的语义**没有确认过**。这条指令会真的发到车上，"
                 + "可能开关某个你不知道的功能。请确保车在安全位置、你能看到车。")
        }
    }

    // MARK: - 操作密码

    private var passwordSection: some View {
        Section {
            if let s = client.session, !s.opPassword.isEmpty {
                kv("密码位数", "\(s.opPassword.count) 位")
                kv("派生 key", keyIV.key)
                kv("派生 iv", keyIV.iv)
                kv("oppwd", oppwd)
                kv("本地回解", roundTrip)
                HStack {
                    Image(systemName: roundTrip == s.opPassword
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(roundTrip == s.opPassword ? Color.lmGood : Color.lmBad)
                    Text(roundTrip == s.opPassword
                         ? "加密→解密回到原文，算法链路没问题"
                         : "回解结果和输入不一致，加密链路有问题")
                        .font(.caption)
                }
            } else {
                Text("还没设置操作密码。请到「设置 → 操作密码」填写。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("操作密码体检")
        } footer: {
            Text("""
            派生规则（逆向自官方 iOS 1.22.68）：
              key = md5(accessToken[0..32])[8..24]
              iv  = md5(accessToken[32..64])[8..24]
              oppwd = base64(AES-128-CBC-PKCS7(密码, key, iv))

            只要「本地回解」等于你输入的密码，说明 App 侧没问题；
            这时服务端还报密码错，就是密码本身和账号不匹配。
            """)
        }
    }

    // MARK: - 上次车控请求

    private var lastControlSection: some View {
        Section("上次车控请求") {
            if let t = client.lastControlTrace {
                kv("时间", timeText(t.time))
                kv("动作", "\(t.action)（cmdid \(t.cmdid)）")
                kv("密码位数", "\(t.passwordLength) 位")
                kv("key", t.key)
                kv("iv", t.iv)
                kv("oppwd", t.oppwd)
                kv("本地回解", t.roundTrip)
                kv("token 头 32", t.tokenHead)
                kv("token 尾 32", t.tokenTail)
                HStack(alignment: .top) {
                    Text("服务端")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(t.outcome)
                        .font(.system(.caption2, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }
            } else {
                Text("本次启动还没发过车控指令。去「车控」点一个按钮，这里就会有记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 会话

    private var sessionSection: some View {
        Section("会话") {
            if let s = client.session {
                kv("accountId", s.accountId.isEmpty ? "--" : s.accountId)
                kv("userId", s.userId.isEmpty ? "--" : s.userId)
                kv("token 头 32", String(s.accessToken.prefix(32)))
                kv("token 尾 32", s.accessToken.count >= 64
                   ? String(Array(s.accessToken)[32..<64]) : "--")
                kv("signKey", s.signKeyHex)
                kv("encryptKey", s.encryptKeyHex)
                kv("车架号", client.selectedVehicle?.vin ?? "--")
                kv("cartype", client.selectedVehicle?.carType ?? "--")
            } else {
                Text("未登录").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 信号对照表

    /// 表内容来自 LMSignalCatalog（有证据、带置信度），不是这里硬编码的。
    /// 完整版（含未命名信号、搜索、快照对比）在 SignalExplorerView。
    private var signalMapSection: some View {
        Section {
            ForEach(Self.signalTable) { row in
                HStack(spacing: 10) {
                    Text(row.id)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 62, alignment: .leading)
                    Text(row.name)
                        .font(.caption)
                    Spacer(minLength: 8)
                    Text(client.signals[row.id]?.displayText ?? "--")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.lmAccent)
                }
            }
            NavigationLink {
                SignalExplorerView()
            } label: {
                Label("打开信号浏览器（全部 \(client.signals.count) 个 / 快照对比）",
                      systemImage: "magnifyingglass.circle")
            }
        } header: {
            Text("已确认的信号映射")
        } footer: {
            Text("右侧是该信号此刻的实时值。带 🟡 的是观察级、❓ 是还没定下来的，"
                 + "都在信号浏览器里能看到完整说明。")
        }
    }

    /// 只列 ✅ 已确认的，按 id 排序
    private static var signalTable: [SignalRef] {
        LMSignalCatalog.refs
            .filter { $0.confidence == .confirmed }
            .sorted { LMSignalCatalog.numeric($0.id) < LMSignalCatalog.numeric($1.id) }
            .map { SignalRef(id: $0.id,
                             name: $0.name + ($0.unit.isEmpty ? "" : "（\($0.unit)）")) }
    }

    // MARK: - 官方接口探测
    //
    // parking/query 与 geocode/regeo 都是从 IPA 字符串表里挖出来的，
    // **路径前缀和参数都是推的**，没有抓包样本。这里做成手动探测，
    // 让用户（或者以后的我）能在真机上把响应结构试出来。

    private var endpointProbeSection: some View {
        Section {
            Button {
                Task { await probeParking() }
            } label: {
                Label("探测 停车位置接口（GET parking/query）", systemImage: "parkingsign.circle")
            }

            Button {
                Task { await probeParkingPost() }
            } label: {
                Label("探测 停车位置接口（POST + vin）", systemImage: "parkingsign.circle")
            }

            // ★ 2026-10-08 加：官方「车辆位置」页疑似用的就是这个接口。
            //   背景：用户报「车在淮南、显示合肥」，而 signalMap 的 2190/2191
            //   连续 51 个样本没变过（其它车况信号却在实时刷新）—— 那个坐标不是实时的。
            Button {
                Task { await probeChassis() }
            } label: {
                Label("探测 车辆状态接口（GET chassis/query）", systemImage: "car.circle")
            }

            Button {
                Task { await probeRegeo() }
            } label: {
                Label("探测 官方逆地理编码（3 种参数各试一次）", systemImage: "map.circle")
            }

            if probeBusy {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("探测中…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !probeResult.isEmpty {
                Text(probeResult)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(40)
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = probeResult
                } label: {
                    Label("复制探测结果", systemImage: "doc.on.doc")
                }
            }
        } header: {
            Text("官方接口探测（结构未知，试出来的）")
        } footer: {
            Text("""
            这两个端点的路径是从 IPA 字符串表挖的，参数靠推测，没有抓包样本。
            探测结果有意义的话（返回了地址或坐标），就把这段发出来，
            可以把它接成定位页的地址来源，比 Apple 的 CLGeocoder 更贴官方。
            """)
        }
    }

    // MARK: - 蓝牙钥匙接口
    //
    // 这 7 个接口全部是「只有路径、没有样本」（见 LMEndpoints.Path 的注释）。
    // 分成两排：
    //   · 只读探测 —— 随便点，失败是常态
    //   · 改状态   —— 必须二次确认（BLEAction）
    // 目的就一个：把响应结构试出来，尤其是 syncBluetoothKeys 会不会吐钥匙材料。

    private var bleKeyProbeSection: some View {
        Section {
            Button {
                Task {
                    bleBusy = true
                    await client.probeBLEKeyReadOnly()
                    bleBusy = false
                }
            } label: {
                Label("同步钥匙（只读，3 个前缀各试一次）", systemImage: "key.horizontal")
            }
            .disabled(bleBusy || client.selectedVehicle == nil)

            Button {
                Task { await probeBleOne(LMEndpoints.Path.bleKeyAnchor, "GET", "感应区锚点参数") }
            } label: {
                Label("感应区锚点参数（只读）", systemImage: "scope")
            }
            .disabled(bleBusy || client.selectedVehicle == nil)

            Button {
                Task { await probeBleOne(LMEndpoints.Path.cccPoll, "GET", "轮询配对结果") }
            } label: {
                Label("轮询配对结果 ccc/poll", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(bleBusy || client.selectedVehicle == nil)

            ForEach(BLEAction.allCases) { a in
                Button(role: .destructive) {
                    bleDanger = a
                } label: {
                    Label(a.title, systemImage: "exclamationmark.triangle.fill")
                }
                .disabled(bleBusy || client.selectedVehicle == nil)
            }

            if bleBusy {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("探测中…").font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(client.bleProbes.prefix(6)) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(p.ok ? "✅" : "❌")
                        Text(p.title).font(.caption.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(p.timeText).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(p.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(2)
                    Text(p.request)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(2)
                    Text(p.response)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(12)
                        .textSelection(.enabled)
                }
            }

            if !client.bleProbes.isEmpty {
                Button {
                    UIPasteboard.general.string = bleReport
                } label: {
                    Label("复制全部探测结果", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    client.clearBLEProbes()
                } label: {
                    Text("清空探测记录")
                }
            }
        } header: {
            Text("蓝牙钥匙接口探测（路径从二进制挖的，无样本）")
        } footer: {
            Text("""
            这 7 个路径来自官方 IPA 主二进制的字符串表，**没有抓包样本** ——
            前缀（/carownerservice？/app/app-control-service？）、参数、HTTP 方法全是推的。
            所以这里把「试了什么、回了什么」原样留下，失败本身也是有效信息。

            ★ 最值得看的是 syncBluetoothKeys：如果它把 passwordCard（钥匙材料）吐回来，
            整套 BLE 协议就能自己实现，不用再动态 hook 官方 App。
            """)
        }
    }

    private var bleDangerBinding: Binding<Bool> {
        Binding(get: { bleDanger != nil },
                set: { if !$0 { bleDanger = nil } })
    }

    /// 单个蓝牙钥匙接口探测：逐个候选前缀试一遍，结果都留在 client.bleProbes
    private func probeBleOne(_ barePath: String, _ method: String, _ title: String) async {
        guard let vin = client.selectedVehicle?.vin else { return }
        bleBusy = true
        defer { bleBusy = false }
        // ★ 显式标类型：`method == "POST" ? ["vin": vin] : nil` 这种三元
        //   一边是 [String: String]、一边是 nil，参数类型却是 [String: Any]?，
        //   让推断去猜不如直接写死。
        let postBody: [String: Any]? = (method == "POST") ? ["vin": vin] : nil
        for prefix in LMEndpoints.pathPrefixes {
            let tag = prefix.isEmpty ? "无前缀" : prefix
            await client.probeBLEKey(barePath: prefix + barePath,
                                     method: method,
                                     params: ["vin": vin],
                                     body: postBody,
                                     title: "\(title)（\(tag)）")
        }
    }

    /// 执行一个「会改服务端状态」的蓝牙钥匙操作
    private func runBLEAction(_ a: BLEAction) async {
        await probeBleOne(a.path, a.method, a.title)
    }

    private var bleReport: String {
        var out = "# 蓝牙钥匙接口探测记录\n"
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        for p in client.bleProbes {
            out += "\n[\(f.string(from: p.at))] \(p.ok ? "OK" : "FAIL")  \(p.title)\n"
            out += "  path : \(p.path)\n"
            out += "  req  : \(p.request)\n"
            out += "  resp : \(p.response)\n"
        }
        return out
    }

    // MARK: - 未验证 cmdid

    private var rawCmdSection: some View {
        Section {
            HStack {
                Text("cmdid").font(.caption).foregroundStyle(.secondary)
                TextField("130", text: $rawCmdId)
                    .keyboardType(.numberPad)
                    .font(.system(.callout, design: .monospaced))
                    .multilineTextAlignment(.trailing)
            }
            HStack(alignment: .top) {
                Text("state").font(.caption).foregroundStyle(.secondary)
                TextField(#"{"value":"true"}"#, text: $rawState)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            ForEach(LMEndpoints.unverifiedCmds) { item in
                Button {
                    rawCmdId = String(item.cmdid)
                    rawState = item.state
                } label: {
                    HStack(spacing: 8) {
                        Text("cmdid \(item.cmdid)")
                            .font(.system(.caption, design: .monospaced))
                        Text(item.state)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("填入").font(.caption2).foregroundStyle(Color.lmAccent)
                    }
                }
            }

            Button(role: .destructive) {
                rawConfirm = true
            } label: {
                Label("下发这条指令（会真的发到车上）", systemImage: "exclamationmark.triangle.fill")
            }
            .disabled(rawBusy
                      || client.isControlLocked(at: now)
                      || (client.session?.opPassword.isEmpty ?? true))

            if client.isControlLocked(at: now) {
                Label("操作密码被服务端锁定，还要 \(client.controlLockRemaining(at: now)) 秒",
                      systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Color.lmBad)
            }

            if rawBusy {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("下发中…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !rawResult.isEmpty {
                Text(rawResult)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.lmAccent)
            }
        } header: {
            Text("未验证 cmdid 探测")
        } footer: {
            Text("""
            cmdid 130 {"value":"true"|"false"} 在抓包里出现过，但没有任何证据说明它开关的是什么 ——
            所以它**没有**出现在车控页。想确认它是干什么的，只能自己发一次看车有什么反应。

            发之前请确保：车停在安全位置、你能直接看到车、周围没人。
            另：这一页的请求同样算「操作密码」的尝试次数，密码错 3 次会被服务端锁 5 分钟。
            """)
        }
    }

    private func probeParking() async {
        guard client.selectedVehicle?.vin != nil else {
            probeResult = "✗ 还没选车"
            return
        }
        probeBusy = true
        defer { probeBusy = false }
        // 走 LMClient.probeParking()：它除了打接口，还会用候选 key 名试着掏经纬度，
        // 结果同时留在 client.parkingProbe 里（定位页以后可以直接用）
        let probe = await client.probeParking()
        let head = "GET \(LMEndpoints.Path.parking)?vin=<vin>"
        guard let p = probe else {
            probeResult = head + "\n✗ 没拿到响应（路径或参数不对，属于预期内）"
            return
        }
        var extra = ""
        if let lat = p.latitude, let lng = p.longitude {
            extra = "\n→ 掏到坐标：\(lat), \(lng)（和 signalMap 的 2190/2191 对一下）"
        } else {
            extra = "\n→ 响应里没找到候选 key 的经纬度"
        }
        probeResult = head + extra + "\n" + p.rawText
    }

    private func probeParkingPost() async {
        guard let vin = client.selectedVehicle?.vin else {
            probeResult = "✗ 还没选车"
            return
        }
        probeBusy = true
        defer { probeBusy = false }
        let r = await client.probePOST(path: LMEndpoints.Path.parking, body: ["vin": vin])
        probeResult = "POST \(LMEndpoints.Path.parking) {\"vin\":...}\n\(r)"
    }

    /// 探测 `/v3/api/chassis/query` —— 官方「车辆位置」页的疑似数据源。
    private func probeChassis() async {
        guard client.selectedVehicle?.vin != nil else {
            probeResult = "✗ 还没选车"
            return
        }
        probeBusy = true
        defer { probeBusy = false }
        let head = "GET \(LMEndpoints.Path.chassis)?vin=<vin>"
        guard let p = await client.probeChassis() else {
            probeResult = head + "\n✗ 没拿到响应（路径或参数不对，属于预期内）"
            return
        }
        var extra = ""
        if let lat = p.latitude, let lng = p.longitude {
            extra = "\n→ 掏到坐标：\(lat), \(lng)"
                + "\n→ 跟 signalMap 的 2190/2191 对一下：不一样就说明这才是实时位置"
        } else {
            extra = "\n→ 响应里没找到候选 key 的经纬度"
        }
        probeResult = head + extra + "\n" + p.rawText
    }

    /// regeo 的参数形状完全未知，把常见的三种都试一遍，哪个通了就知道该用哪个
    private func probeRegeo() async {
        guard let c = client.coordinate else {
            probeResult = "✗ 当前没有车辆坐标，先去「定位」页刷新"
            return
        }
        probeBusy = true
        defer { probeBusy = false }
        let lng = String(format: "%.6f", c.longitude)
        let lat = String(format: "%.6f", c.latitude)

        var out: [String] = []
        let attempts: [(String, [String: String])] = [
            ("location=lng,lat", ["location": "\(lng),\(lat)"]),
            ("lat,lng 分开", ["latitude": lat, "longitude": lng]),
            ("lat/lng 短名", ["lat": lat, "lng": lng]),
        ]
        for (label, params) in attempts {
            let r = await client.probeGET(path: LMEndpoints.Path.regeo, params: params)
            out.append("— \(label)\n\(r)")
        }
        probeResult = "GET \(LMEndpoints.Path.regeo)\n" + out.joined(separator: "\n\n")
    }

    private func sendRaw() async {
        guard let id = Int(rawCmdId.trimmingCharacters(in: .whitespaces)) else {
            rawResult = "✗ cmdid 必须是数字"
            return
        }
        guard let data = rawState.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else {
            rawResult = "✗ state 不是合法 JSON 对象"
            return
        }
        rawBusy = true
        defer { rawBusy = false }
        let ok = await client.controlRaw(cmdid: id, state: dict, label: "raw-\(id)")
        rawResult = ok
            ? "✓ cmdid \(id) 已受理并确认成功 —— 看看车有什么反应，再去「信号浏览器」抓快照对比"
            : "✗ cmdid \(id)：\(client.lastError ?? "未知失败")"
    }

    // MARK: - 复制

    private var copySection: some View {
        Section {
            Button {
                UIPasteboard.general.string = fullReport
                copied = true
            } label: {
                Label(copied ? "已复制到剪贴板" : "复制全部诊断信息",
                      systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
            }
        } footer: {
            Text("复制的内容包含 token 与 oppwd 密文。发给别人前请确认对方可信；"
                 + "排查完建议「设置 → 退出登录」再重新登录，token 会换新的。")
        }
    }

    // MARK: - 计算

    private var keyIV: (key: String, iv: String) {
        guard let s = client.session,
              let p = try? LMSigner.oppwdKeyIV(accessToken: s.accessToken)
        else { return ("--", "--") }
        return (p.key, p.iv)
    }

    private var oppwd: String {
        guard let s = client.session, !s.opPassword.isEmpty,
              let op = try? LMSigner.encryptOppwd(accessToken: s.accessToken, password: s.opPassword)
        else { return "--" }
        return op
    }

    private var roundTrip: String {
        guard let s = client.session, !s.opPassword.isEmpty,
              let op = try? LMSigner.encryptOppwd(accessToken: s.accessToken, password: s.opPassword)
        else { return "--" }
        return LMSigner.decryptOppwd(accessToken: s.accessToken, oppwd: op)
    }

    private var fullReport: String {
        var lines: [String] = ["=== 零跑轻控 · 车控体检 ==="]
        if let s = client.session {
            lines.append("accountId: \(s.accountId)")
            lines.append("userId: \(s.userId)")
            lines.append("tokenHead32: \(String(s.accessToken.prefix(32)))")
            lines.append("tokenTail32: " + (s.accessToken.count >= 64
                                            ? String(Array(s.accessToken)[32..<64]) : "--"))
            lines.append("signKey: \(s.signKeyHex)")
            lines.append("passwordLength: \(s.opPassword.count)")
            lines.append("key: \(keyIV.key)")
            lines.append("iv: \(keyIV.iv)")
            lines.append("oppwd: \(oppwd)")
            lines.append("roundTrip: \(roundTrip)")
        }
        if let t = client.lastControlTrace {
            lines.append("--- 上次车控 ---")
            lines.append("action: \(t.action) cmdid=\(t.cmdid)")
            lines.append("outcome: \(t.outcome)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 行

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(v)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
