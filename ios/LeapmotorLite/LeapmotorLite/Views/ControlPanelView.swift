//
//  ControlPanelView.swift
//  LeapmotorLite
//
//  车控面板：锁 / 后备箱 / 空调 / 大灯 / 上电
//
//  安全设计：每次下发前弹一次确认（车控是会动车的，不该误触就发）。
//  服务端「操作密码累计出错 3 次锁 5 分钟」（业务码 70）时，本地倒计时并禁用按钮。
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

    /// ★ 2026-10-08：空调风量档位（1~9）—— 未验证，见 hvacGearCard
    @State private var hvacGear = 3
    @State private var gearConfirm = false

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
                hvacGearCard
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

    /// 按功能分组显示（门锁/后备箱、空调、灯光、电源）。
    /// 分组只是排版 —— 所有动作走的都是同一条 sendControl 链路。
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
        case "lock":       return Color.lmGood
        case "unlock":     return Color.lmWarn
        case "trunk":      return Color.lmTeal
        case "hvac_off":   return Color.lmTeal
        case "hvac_low":   return Color.lmAccent
        case "hvac_high":  return Color.lmAccent2
        case "light_off":  return Color.lmIndigo
        case "light_auto": return Color.lmPurple
        default:           return Color.lmBad
        }
    }

    // MARK: - 空调风量档位（未验证）
    //
    // ★ 2026-10-08 加。依据：`vehicle/list` 的 `funcConfig.HVAC.fan` 明确写着
    //   `min=1 max=9 unit=gear` —— 这台车**支持 1~9 档风量**。
    //
    // ⚠️ 但抓包里 cmdid 230 只出现过 `{"value":"0"|"2"|"5"}` 三个样本，
    //    所以 1~9 档的 payload **没有直接证据**，属于「范围有依据、payload 靠推」。
    //
    // 为什么不直接塞进上面那个网格？
    //   上面每个磁贴都是「有抓包证据」的。把 1~9 档混进去，用户会以为它们
    //   一样可靠。单独一张卡 + 明确标注 + 单独的确认弹窗，用户才知道自己在试什么。
    //   （这也是这个项目一贯的做法：130 和 161 至今没进车控页。）

    /// 档位候选：优先用车辆自己上报的范围；拿不到就退回 1...9
    /// （1...9 就是 `funcConfig.HVAC.fan` 的实测 min/max，不是随手写的）。
    private var hvacGears: [Int] {
        if let f = client.selectedVehicle?.hvacFanRange, !f.values.isEmpty {
            return f.values
        }
        return Array(1...9)
    }

    private var hvacGearCard: some View {
        VStack(spacing: 10) {
            SectionHeader(text: "空调风量档位（未验证）")
            LMCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    if let f = client.selectedVehicle?.hvacFanRange {
                        HStack(spacing: 6) {
                            Image(systemName: "fanblades")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.lmAccent)
                            Text("车辆上报的支持范围：\(f.rangeText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                    Button {
                        gearConfirm = true
                    } label: {
                        HStack(spacing: 8) {
                            if pendingAction == hvacGearKey {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 13))
                            }
                            Text("下发风量 \(hvacGear) 档")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.lmAccent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(pendingAction != nil || client.isControlLocked(at: now))

                    Text("⚠️ 0 / 2 / 5 三档有抓包证据（在上面「空调」分组里）；"
                         + "这里 1~9 档的**范围**来自车辆配置接口，"
                         + "但 `{\"value\":\"N\"}` 这种 payload **没有样本**，可能无效。"
                         + "指令只改空调状态，不会动车。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog("确认下发风量 \(hvacGear) 档？",
                            isPresented: $gearConfirm,
                            titleVisibility: .visible) {
            Button("确认执行") { Task { await runGear() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("cmdid \(LMEndpoints.hvacCmdid)，state "
                 + "{\"value\":\"\(hvacGear)\"}。\n"
                 + "风量范围 1~9 来自车辆配置接口，但这个 payload 没有抓包证据 —— "
                 + "只有 0/2/5 是实测过的。")
        }
    }

    /// 给档位下发用的伪 action key（只用于按钮上的 loading 状态，不是 commands 表里的 key）
    private var hvacGearKey: String { "hvac_gear_\(hvacGear)" }

    private func runGear() async {
        let key = hvacGearKey
        let gear = hvacGear
        pendingAction = key
        defer { pendingAction = nil }
        let ok = await client.controlRaw(cmdid: LMEndpoints.hvacCmdid,
                                         state: LMEndpoints.hvacState(gear: gear),
                                         label: key)
        toastIsError = !ok
        toast = ok ? "风量 \(gear) 档 成功" : (client.lastError ?? "风量 \(gear) 档 失败")
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
             + "「空调风量档位」那张卡里的 1~9 档是**未验证**的：范围来自车辆配置接口，"
             + "但 payload 没有抓包证据，试的时候留意车有没有真的响应。")
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
        return "cmdid \(cmd.cmdid)，只改状态（空调 / 灯光），不会夹到人。"
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
