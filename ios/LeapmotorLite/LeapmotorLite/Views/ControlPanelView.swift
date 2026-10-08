//
//  ControlPanelView.swift
//  LeapmotorLite
//
//  车控面板：门锁 / 后备箱·寻车 / 车窗 / 空调 / 电源
//
//  安全设计：每次下发前弹一次确认（车控是会动车的，不该误触就发）。
//  服务端「操作密码累计出错 3 次锁 5 分钟」（业务码 70）时，本地倒计时并禁用按钮。
//
//  ★ 2026-10-08 结构（自上而下）：
//    状态提示条 → 动作网格（门锁 / 后备箱·寻车 / 空调开关 / 电源）
//    → 车窗卡（关闭 / 微开 / 半开）→ 空调风量·温度卡 → 蓝牙钥匙入口 → 脚注
//
//  ⚠️ 车窗与空调风量/温度**不在动作网格里**：它们各自有一张专门的卡。
//    网格里的「空调」分组只放开 / 关两个互斥动作，风量温度是另一个维度。
//
import SwiftUI
import Foundation

struct ControlPanelView: View {
    @EnvironmentObject var client: LMClient

    @State private var pendingAction: String?
    @State private var confirmKey: String?
    @State private var toast: String?
    @State private var toastIsError = false
    /// 由 .lmClock 每 0.5 秒推一次，用来驱动锁定期倒计时
    @State private var now = Date()

    /// ★ 2026-10-08 修正：空调是 cmdid 170（不是 230），车窗才是 230。
    ///   风量 / 温度的范围来自车辆自己上报的 `funcConfig.HVAC`。
    @State private var hvacGear = 3
    @State private var hvacTemp = 24
    @State private var hvacConfirm = false
    /// 待确认的车窗开度
    @State private var windowConfirm: LMEndpoints.WindowOpening?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]
    private let gearColumns = [GridItem(.adaptive(minimum: 46), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let v = client.selectedVehicle {
                    header(v)
                }
                statusBanners
                actionGrid
                windowCard
                hvacCard
                bleCard
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("车控")
        .refreshable { try? await client.refreshStatus() }
        // ★ 必须有这个：不然倒计时冻在 "300 秒"，而且到期后按钮不会重新启用
        .lmClock(until: client.controlLockedUntil, now: $now)
        .overlay(alignment: .bottom) { toastView }
        .confirmationDialog(confirmTitle,
                            isPresented: confirmBinding,
                            titleVisibility: .visible) {
            Button("确认执行") {
                let k = confirmKey
                confirmKey = nil
                if let k = k { Task { await run(key: k) } }
            }
            Button("取消", role: .cancel) { confirmKey = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - 顶部

    private func header(_ v: LMVehicle) -> some View {
        LMCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "car.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.lmAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.displayName).font(.headline)
                    Text(v.vin)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let locked = client.isLocked {
                    StatusPill(text: locked ? "已上锁" : "未上锁",
                               icon: locked ? "lock.fill" : "lock.open.fill",
                               tint: locked ? Color.lmGood : Color.lmWarn)
                }
            }
        }
    }

    // MARK: - 提示条

    @ViewBuilder
    private var statusBanners: some View {
        if client.isControlLocked(at: now) {
            banner(icon: "lock.trianglebadge.exclamationmark.fill",
                   tint: Color.lmBad,
                   title: "操作密码已锁定",
                   text: "服务端返回「操作密码累计出错 3 次以上」，请 \(client.controlLockRemaining(at: now)) 秒后再试。"
                       + "建议先去「设置 → 操作密码」核对密码。")
        } else if client.session?.opPassword.isEmpty ?? true {
            banner(icon: "exclamationmark.triangle.fill",
                   tint: Color.lmWarn,
                   title: "尚未设置操作密码",
                   text: "车控必须带 oppwd。请到「设置 → 操作密码」填写你在官方 App 用的那个操作密码（4~6 位数字）。")
        }
    }

    private func banner(icon: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.footnote.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: LMRadius.tile, style: .continuous))
    }

    // MARK: - 动作网格

    /// 按功能分组显示（门锁 / 后备箱·寻车 / 空调开关 / 电源）。
    /// 分组只是排版 —— 所有动作走的都是同一条 sendControl 链路。
    ///
    /// ⚠️ `.window` 分组这里恒为空（车窗三个开度在下面的 windowCard 里），
    ///   `if !keys.isEmpty` 会把它整个跳过，不会渲染出一个空标题。
    private var actionGrid: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(LMEndpoints.Command.Group.allCases, id: \.self) { group in
                let keys = LMEndpoints.actions(in: group)
                if !keys.isEmpty {
                    VStack(spacing: 10) {
                        SectionHeader(text: group.rawValue)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(keys, id: \.self) { key in
                                if let cmd = LMEndpoints.commands[key] {
                                    actionTile(key: key, cmd: cmd)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func actionTile(key: String, cmd: LMEndpoints.Command) -> some View {
        // 局部变量别叫 tint —— 会和下面的 tint(for:) 撞名，Swift 会报
        // "use of local variable before its declaration"
        let accent = tint(for: key)
        return Button {
            confirmKey = key
        } label: {
            VStack(spacing: 8) {
                if pendingAction == key {
                    ProgressView().frame(height: 26)
                } else {
                    Image(systemName: cmd.systemImage)
                        .font(.system(size: 23, weight: .medium))
                        .frame(height: 26)
                        .foregroundStyle(accent)
                }
                Text(cmd.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("cmdid \(cmd.cmdid)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 98)
            .background(Color.lmCard,
                        in: RoundedRectangle(cornerRadius: LMRadius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LMRadius.tile, style: .continuous)
                    .stroke(accent.opacity(pendingAction == key ? 0.65 : 0.20), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                // 会动物理世界的动作（车门 / 后备箱 / 上电）打个标，别误触
                if cmd.risk == .physical {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.lmWarn)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(pendingAction != nil || client.isControlLocked(at: now))
    }

    private func tint(for key: String) -> Color {
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
        default:             return Color.lmBad
        }
    }

    // MARK: - 车窗（cmdid 230）
    //
    // ★ 铁证：抓包里 `cmdid 230 {"value":"2"}` 让 **1693 / 1694 / 1695 / 1696
    //   四个信号同时 0→2** —— 这四个信号就是四个车窗的位置。
    //   所以 230 是「四个车窗一起动」，`{"value":"0"}` 是全关。
    //
    // ⚠️ 2 与 5 谁是「半开」谁是「微开」没有直接证据（详见
    //    LMEndpoints.WindowOpening 的注释）。这里按「数值越大开得越大」排：
    //    2 = 微开，5 = 半开。若实测反了，只改那里的 rawValue 即可。

    private var windowOpenings: [LMEndpoints.WindowOpening] { [.close, .micro, .half] }

    private var windowCard: some View {
        VStack(spacing: 10) {
            SectionHeader(text: "车窗")
            LMCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(windowOpenings, id: \.rawValue) { op in
                            windowButton(op)
                        }
                    }

                    if let t = client.windowOpeningText {
                        Text("车辆当前上报：\(t)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // ⚠️ 这里必须用 Text + Text 拼接，**不能**写成
                    //    Text("...**加粗**..." + "...") —— SwiftUI 只在
                    //    **字符串字面量**上解析 markdown；一旦用 `+` 拼成
                    //    String，加粗就失效，用户会看到字面的星号。
                    (
                        Text("cmdid \(LMEndpoints.windowCmdid)，一次会让")
                        + Text("四个车窗一起动").bold()
                        + Text("。0 = 全关，2 / 5 = 两个开度。\n"
                               + "⚠️「2 是微开、5 是半开」是按开度大小排的 —— "
                               + "抓包只录到过这两个值，没记录当时按的是哪个按钮。"
                               + "实测反了说一声，改一行就行。")
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog(windowConfirmTitle,
                            isPresented: windowConfirmBinding,
                            titleVisibility: .visible) {
            Button("确认执行") {
                let op = windowConfirm
                windowConfirm = nil
                if let op = op { Task { await runWindow(op) } }
            }
            Button("取消", role: .cancel) { windowConfirm = nil }
        } message: {
            Text("cmdid \(LMEndpoints.windowCmdid)，state "
                 + "{\"value\":\"\(windowConfirm?.rawValue ?? 0)\"}。\n"
                 + "会让四个车窗一起动，请确认车窗附近没有人、没有夹手风险。")
        }
    }

    private func windowButton(_ op: LMEndpoints.WindowOpening) -> some View {
        Button {
            windowConfirm = op
        } label: {
            VStack(spacing: 6) {
                Image(systemName: op == .close ? "window.vertical.closed" : "window.vertical.open")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.lmPurple)
                Text(op.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("value \(op.rawValue)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(Color.lmCard,
                        in: RoundedRectangle(cornerRadius: LMRadius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LMRadius.tile, style: .continuous)
                    .stroke(Color.lmPurple.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(pendingAction != nil || client.isControlLocked(at: now))
    }

    private var windowConfirmTitle: String {
        guard let op = windowConfirm else { return "确认车窗操作？" }
        return "确认「车窗\(op.title)」？"
    }

    private var windowConfirmBinding: Binding<Bool> {
        Binding(get: { windowConfirm != nil },
                set: { if !$0 { windowConfirm = nil } })
    }

    private func runWindow(_ op: LMEndpoints.WindowOpening) async {
        pendingAction = "window_\(op.rawValue)"
        defer { pendingAction = nil }
        let ok = await client.controlRaw(cmdid: LMEndpoints.windowCmdid,
                                         state: LMEndpoints.windowState(op),
                                         label: "车窗\(op.title)")
        toastIsError = !ok
        toast = ok ? "车窗\(op.title) 成功" : (client.lastError ?? "车窗\(op.title) 失败")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        toast = nil
        if ok { try? await client.refreshStatus() }
    }

    // MARK: - 空调风量 / 温度（cmdid 170）
    //
    // 开 / 关（`{"operate":"auto"|"off"}`）有抓包证据，在上面「空调」分组里。
    // 这张卡是**风量和温度**：
    //   · 字段名有证据 —— 官方 IPA 主二进制的车控字符串常量里明确有
    //     `operate` / `manual` / `temperature` / `windlevel`
    //   · 值域有证据 —— 车辆自己上报 `funcConfig.HVAC.fan = 1~9 档`、
    //     `temperature = 16~32 ℃`
    //   · ⚠️ 但「三者拼在一起」这个 payload **没有被抓包证实过**：
    //     抓包里用户从没调过风量 / 温度，只按过 auto 和 off。

    private var hvacGears: [Int] {
        if let f = client.selectedVehicle?.hvacFanRange, !f.values.isEmpty { return f.values }
        return LMEndpoints.hvacFanFallback
    }

    private var hvacTemps: [Int] {
        if let t = client.selectedVehicle?.hvacTempRange, !t.values.isEmpty { return t.values }
        return LMEndpoints.hvacTempFallback
    }

    private var hvacCard: some View {
        VStack(spacing: 10) {
            SectionHeader(text: "空调风量 / 温度")
            LMCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    hvacStateRow
                    Divider()
                    gearRow
                    Divider()
                    tempRow
                    Divider()
                    hvacSendButton
                    Text(hvacFootnote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog("确认下发空调设置？",
                            isPresented: $hvacConfirm,
                            titleVisibility: .visible) {
            Button("确认执行") { Task { await runHvac() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("cmdid \(LMEndpoints.hvacCmdid)，state \(hvacStateText)。\n"
                 + "风量范围 1~9、温度 16~32 ℃ 来自车辆配置接口，"
                 + "但这个 payload 组合没有抓包证据。指令不会动车。")
        }
    }

    /// 车辆当前上报的空调**开关**状态（信号 1938，1 = 开）。
    ///
    /// ⚠️ 只报开关，**不报风量 / 温度** —— 抓包里用户从没调过风量温度，
    ///   所以 1941 / 1943 / 1944 / 1945 那几个伴随位到底是什么语义还没有定论
    ///   （见 LMSignalCatalog 的标注）。宁可这里少显示，也不拿不确定的信号
    ///   假装成「当前 3 档 / 24℃」，那会误导人。
    @ViewBuilder
    private var hvacStateRow: some View {
        HStack(spacing: 8) {
            // ⚠️ 图标只用**确定存在**的符号名：SF Symbol 名字写错不会编译报错，
            //    只会渲染成一片空白，看起来像坏了。`snowflake.circle` 没把握，
            //    所以这里开关两态共用 `snowflake`，靠颜色区分。
            Image(systemName: "snowflake")
                .font(.system(size: 13))
                .foregroundStyle(client.hvacOn == true ? Color.lmAccent : Color.secondary)
            if let on = client.hvacOn {
                Text("车辆当前上报：空调\(on ? "开着" : "关着")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("车辆未上报空调开关状态（信号 1938 缺失）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// 当前将要下发的 state（展示用，和真正发的完全一致）
    private var hvacStateText: String {
        "{\"operate\":\"manual\",\"windlevel\":\"\(hvacGear)\",\"temperature\":\"\(hvacTemp)\"}"
    }

    /// ⚠️ 这段是普通 String（由 `+` 拼成），**不会**解析 markdown ——
    ///   所以别在这里写 `**加粗**` 或 `` `code` ``，会原样显示出来。
    private var hvacFootnote: String {
        "cmdid \(LMEndpoints.hvacCmdid)，state \(hvacStateText)。\n"
        + "风量 1~9 档、温度 16~32 ℃ 都来自车辆自己上报的能力范围；"
        + "字段名 temperature / windlevel 来自官方 App 二进制。"
        + "但「manual + 风量 + 温度」这个组合没有抓包样本 —— "
        + "试的时候留意车有没有真的响应。指令只改空调状态，不会动车。"
    }

    private var gearRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "fanblades")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.lmAccent)
                Text("风量 \(hvacGear) 档").font(.caption.weight(.medium))
                Spacer(minLength: 4)
                if let f = client.selectedVehicle?.hvacFanRange {
                    Text("车辆上报 \(f.rangeText)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: gearColumns, spacing: 6) {
                ForEach(hvacGears, id: \.self) { g in
                    Button {
                        hvacGear = g
                    } label: {
                        Text("\(g)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(g == hvacGear ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(g == hvacGear ? Color.lmAccent : Color.lmCard,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.lmAccent.opacity(g == hvacGear ? 0 : 0.28),
                                            lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(pendingAction != nil || client.isControlLocked(at: now))
                }
            }
        }
    }

    private var tempRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.lmWarn)
                Text("温度 \(hvacTemp) ℃").font(.caption.weight(.medium))
                Spacer(minLength: 4)
                if let t = client.selectedVehicle?.hvacTempRange {
                    Text("车辆上报 \(t.rangeText)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                stepButton(system: "minus") {
                    hvacTemp = max(hvacTemps.first ?? 16, hvacTemp - 1)
                }
                Text("\(hvacTemp)")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                stepButton(system: "plus") {
                    hvacTemp = min(hvacTemps.last ?? 32, hvacTemp + 1)
                }
            }
        }
    }

    private func stepButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 52, height: 40)
                .background(Color.lmCard,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.lmWarn.opacity(0.25), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(pendingAction != nil || client.isControlLocked(at: now))
    }

    private var hvacSendButton: some View {
        Button {
            hvacConfirm = true
        } label: {
            HStack(spacing: 8) {
                if pendingAction?.hasPrefix("hvac_") == true {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "paperplane.fill").font(.system(size: 13))
                }
                Text("下发：风量 \(hvacGear) 档 · \(hvacTemp) ℃")
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(Color.lmAccent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pendingAction != nil || client.isControlLocked(at: now))
    }

    private func runHvac() async {
        let gear = hvacGear
        let temp = hvacTemp
        pendingAction = "hvac_\(gear)_\(temp)"
        defer { pendingAction = nil }
        let ok = await client.controlRaw(cmdid: LMEndpoints.hvacCmdid,
                                         state: LMEndpoints.hvacManualState(gear: gear,
                                                                            temperature: temp),
                                         label: "hvac_\(gear)_\(temp)")
        toastIsError = !ok
        toast = ok ? "风量 \(gear) 档 · \(temp) ℃ 成功" : (client.lastError ?? "空调设置失败")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        toast = nil
        if ok { try? await client.refreshStatus() }
    }

    // MARK: - 蓝牙钥匙入口
    //
    // 放在动作网格之后：蓝牙钥匙跟「云端下发指令」是两条完全独立的链路
    // （前者是手机直连车端 BLE 模组，后者走 HTTPS 网关），
    // 但它同属「控制车」这件事，所以入口放车控页比塞进设置里合理。
    //
    // ⚠️ 这里**只**给入口，绝不放「一键解锁」之类的按钮 ——
    //    BLE 协议还没打通（见 LMBLEProtocol.swift 文件头），
    //    没有可用的钥匙材料，也没有 cmdId 表。

    private var bleCard: some View {
        NavigationLink {
            BLEKeyView()
        } label: {
            LMCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.lmPurple)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("蓝牙钥匙")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(bleSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var bleSubtitle: String {
        if let r = client.bleKeyRecord {
            return "云端已绑定 \(r.macPretty)（协议 \(r.versionText)）· 查看进度与调试台"
        }
        return "云端暂无绑定记录 · 查看协议进度与 BLE 调试台"
    }

    // MARK: - 脚注

    private var footnote: some View {
        Text("指令下发后会轮询结果。部分功能需要车辆处于对应状态（例如上电前要先解锁）。"
             + "同一账号在官方 App 与本 App 之间不要频繁交叉操作。\n"
             + "已抓包双向验证的：门锁 110、后备箱 130、鸣笛 120、空调开关 170、车窗 230、上电 400。\n"
             + "未验证的只有两处：① 空调风量/温度的 payload 组合（字段名和档位范围都有据，"
             + "但没人调过，所以没有样本）；② 车窗的「2 = 微开 / 5 = 半开」哪个是哪个"
             + "（两个值都录到了，但没记录当时按的是哪个按钮）。"
             + "这两处试的时候留意车有没有真的响应。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    // MARK: - 执行

    /// 待确认动作的标题
    private var confirmTitle: String {
        guard let k = confirmKey, let cmd = LMEndpoints.commands[k] else {
            return "确认下发车控指令？"
        }
        return "确认执行「\(cmd.title)」？"
    }

    /// 会动物理世界的动作给更重的提示
    private var confirmMessage: String {
        guard let k = confirmKey, let cmd = LMEndpoints.commands[k] else {
            return "将向车辆下发一次真实指令。"
        }
        if cmd.risk == .physical {
            return "cmdid \(cmd.cmdid) 会真的动车门 / 后备箱 / 上电。"
                + "请确认车辆周围安全、车门和后备箱附近没有人，再执行。"
        }
        return "cmdid \(cmd.cmdid)，只改状态（空调开关），不会夹到人。"
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirmKey != nil },
                set: { if !$0 { confirmKey = nil } })
    }

    private func run(key: String) async {
        pendingAction = key
        defer { pendingAction = nil }
        let title = LMEndpoints.commands[key]?.title ?? key
        let ok = await client.control(key)
        toastIsError = !ok
        toast = ok ? "\(title) 成功" : (client.lastError ?? "\(title) 失败")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        toast = nil
        if ok { try? await client.refreshStatus() }
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
}
