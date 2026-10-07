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

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let v = client.selectedVehicle {
                    header(v)
                }
                statusBanners
                actionGrid
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
             + "同一账号在官方 App 与本 App 之间不要频繁交叉操作。")
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
