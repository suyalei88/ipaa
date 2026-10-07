//
//  SettingsView.swift
//  LeapmotorLite
//
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var client: LMClient

    @State private var opPassword = ""
    @State private var saved = false

    var body: some View {
        Form {
            if let s = client.session {
                Section("当前会话") {
                    row("账号", s.accountId.isEmpty ? s.nickname : s.accountId)
                    row("userId", s.userId)
                    row("signKey", String(s.signKeyHex.prefix(24)) + "…")
                    row("encryptKey", String(s.encryptKeyHex.prefix(24)) + "…")
                    row("token", String(s.accessToken.prefix(28)) + "…")
                }
            }

            Section {
                SecureField("6 位操作密码", text: $opPassword)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("保存操作密码") {
                    guard var s = client.session else { return }
                    s.opPassword = opPassword
                    client.adopt(session: s)
                    saved = true
                }
                .disabled(opPassword.isEmpty)
                if saved {
                    Text("已保存到本机 Keychain").font(.caption).foregroundStyle(.green)
                }
            } header: {
                Text("操作密码")
            } footer: {
                Text("车控接口每次都要带上 oppwd（用 accessToken 派生的 key/iv 对操作密码做 AES-128-CBC）。密码只存本机，不会外发。")
            }

            Section("车辆") {
                // 显式给 id: —— 不依赖 Identifiable 的隐式推断，
                // 也就不会被 ForEach 的 Binding<C> 重载抢走（那会级联出一堆怪错误）。
                ForEach(client.vehicles, id: \.vin) { v in
                    Button {
                        client.select(vehicle: v)
                        Task { await client.refreshAll() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(v.displayName).foregroundStyle(.primary)
                                Text(v.vin).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if client.selectedVehicle?.vin == v.vin {
                                Image(systemName: "checkmark").foregroundStyle(Color.lmAccent)
                            }
                        }
                    }
                }
                Button("刷新车辆列表") {
                    Task { _ = try? await client.loadVehicles() }
                }
            }

            Section("设备") {
                row("deviceId", client.config.deviceId)
                row("version", client.config.version)
                row("deviceType", client.config.deviceType)
            }

            Section("诊断") {
                NavigationLink {
                    SelfTestView()
                } label: {
                    Label("算法自检（HMAC / XOR3 / AES / MD5）", systemImage: "checkmark.shield")
                }
            }

            Section {
                Button(role: .destructive) {
                    client.signOut()
                } label: {
                    Text("退出登录（清除本机会话）")
                }
            }
        }
        .navigationTitle("设置")
        .onAppear { opPassword = client.session?.opPassword ?? "" }
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
