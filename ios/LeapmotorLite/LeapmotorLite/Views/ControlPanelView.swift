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

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let v = client.selectedVehicle {
                    header(v)
                }
                statusBanners
                actionGrid
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("车控")
        .refreshable { try? await client.refreshStatus() }
        .overlay(alignment: .bottom) { toastView }
        .confirmationDialog("确认下发车控指令？",
                            isPresented: confirmBinding,
                            titleVisibility: .visible) {
            Button("确认执行") {
                let k = confirmKey
                confirmKey = nil
                if let k = k { Task { await run(key: k) } }
            }
            Button("取消", role: .cancel) { confirmKey = nil }
        } message: {
            Text("将向车辆下发一次真实指令，请确认车辆周围安全、车门附近无人。")
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
        if client.isControlLocked {
            banner(icon: "lock.trianglebadge.exclamationmark.fill",
                   tint: Color.lmBad,
                   title: "操作密码已锁定",
                   text: "服务端返回「操作密码累计出错 3 次以上」，请 \(client.controlLockRemaining) 秒后再试。"
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

    private var actionGrid: some View {
        VStack(spacing: 10) {
            SectionHeader(text: "车控指令")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(LMEndpoints.quickActions, id: \.self) { key in
                    if let cmd = LMEndpoints.commands[key] {
                        actionTile(key: key, cmd: cmd)
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
        }
        .buttonStyle(.plain)
        .disabled(pendingAction != nil || client.isControlLocked)
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

    private var footnote: some View {
        Text("指令下发后会轮询结果。部分功能需要车辆处于对应状态（例如上电前要先解锁）。"
             + "同一账号在官方 App 与本 App 之间不要频繁交叉操作。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    // MARK: - 执行

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
