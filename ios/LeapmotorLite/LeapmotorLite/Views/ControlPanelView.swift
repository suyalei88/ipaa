//
//  ControlPanelView.swift
//  LeapmotorLite
//
//  车控面板：锁 / 后备箱 / 空调 / 大灯 / 上电
//
import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject var client: LMClient

    @State private var pendingAction: String?
    @State private var toast: String?
    @State private var toastIsError = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let v = client.selectedVehicle {
                    HStack(spacing: 8) {
                        // 注意：不能写 .lmAccent。
                        // foregroundStyle 的参数是泛型 ShapeStyle，前导点简写
                        // 推断不出具体类型，会报 "type 'ShapeStyle' has no member 'lmAccent'"。
                        Image(systemName: "car.fill").foregroundStyle(Color.lmAccent)
                        Text(v.displayName).font(.headline)
                        Spacer()
                        if let locked = client.isLocked {
                            Label(locked ? "已锁" : "未锁",
                                  systemImage: locked ? "lock.fill" : "lock.open.fill")
                                .font(.caption)
                                .foregroundStyle(locked ? .green : .orange)
                        }
                    }
                    .padding(.horizontal)
                }

                if client.session?.opPassword.isEmpty ?? true {
                    warningBanner("尚未设置操作密码，车控会失败。请到「设置」填写 6 位操作密码。")
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(LMEndpoints.quickActions, id: \.self) { key in
                        if let cmd = LMEndpoints.commands[key] {
                            actionTile(key: key, cmd: cmd)
                        }
                    }
                }
                .padding(.horizontal)

                Text("指令下发后会轮询结果，成功/失败会以提示显示。部分功能需车辆处于对应状态（例如上电需先解锁）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle("车控")
        .refreshable { try? await client.refreshStatus() }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(toastIsError ? Color.red.opacity(0.9) : Color.green.opacity(0.9),
                                in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: toast)
    }

    // MARK: - 单个按钮

    private func actionTile(key: String, cmd: LMEndpoints.Command) -> some View {
        Button {
            Task { await run(key: key, cmd: cmd) }
        } label: {
            VStack(spacing: 8) {
                if pendingAction == key {
                    ProgressView()
                        .frame(height: 26)
                } else {
                    Image(systemName: cmd.systemImage)
                        .font(.system(size: 24))
                        .frame(height: 26)
                }
                Text(cmd.title).font(.subheadline.weight(.medium))
                Text("cmdid \(cmd.cmdid)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(Color.lmCard, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.lmAccent.opacity(pendingAction == key ? 0.6 : 0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(pendingAction != nil)
    }

    // MARK: - 执行

    private func run(key: String, cmd: LMEndpoints.Command) async {
        pendingAction = key
        defer { pendingAction = nil }
        let ok = await client.control(key)
        toastIsError = !ok
        toast = ok ? "\(cmd.title) 成功" : (client.lastError ?? "\(cmd.title) 失败")
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        toast = nil
        if ok { try? await client.refreshStatus() }
    }

    private func warningBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
    }
}
