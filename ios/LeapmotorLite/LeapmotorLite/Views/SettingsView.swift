//
//  SettingsView.swift
//  LeapmotorLite
//
//  设置：会话 / 操作密码 / 车辆 / 诊断 / 设备
//
//  ★ 操作密码这一块是「车控报密码错误」的主战场，改动请务必读注释：
//    · SecureField 上**不能**挂 .textContentType(.oneTimeCode) —— 那会让 iOS
//      把刚收到的短信验证码自动填进这个框，用户输入的数字被悄悄替换掉，
//      结果就是服务端一直回「操作密码错误 / 累计出错 3 次」。
//    · 只留数字、显示位数、可临时明文查看，任何一环出问题用户都能自己看出来。
//
import SwiftUI
import Foundation

struct SettingsView: View {
    @EnvironmentObject var client: LMClient

    @State private var opPassword = ""
    @State private var revealPassword = false
    @State private var savedOK: Bool?
    @State private var keychainOK = true

    var body: some View {
        Form {
            sessionSection
            opPasswordSection
            vehicleSection
            diagnosticsSection
            deviceSection
            signOutSection
        }
        .navigationTitle("设置")
        .onAppear { opPassword = client.session?.opPassword ?? "" }
    }

    // MARK: - 当前会话

    @ViewBuilder
    private var sessionSection: some View {
        if let s = client.session {
            Section("当前会话") {
                row("账号", s.accountId.isEmpty ? s.nickname : s.accountId)
                row("userId", s.userId.isEmpty ? "--" : s.userId)
                row("signKey", prefix(s.signKeyHex, 20))
                row("encryptKey", prefix(s.encryptKeyHex, 20))
                row("token", prefix(s.accessToken, 24))
                row("会话有效期", tokenExpiryText(s.accessToken))
            }
        }
    }

    // MARK: - 操作密码

    private var opPasswordSection: some View {
        Section {
            HStack(spacing: 8) {
                if revealPassword {
                    TextField("操作密码（4~6 位数字）", text: $opPassword)
                        .keyboardType(.numberPad)
                        .textContentType(.password)
                        .onChange(of: opPassword) { _, v in
                            let d = sanitize(v)
                            if d != v { opPassword = d }
                        }
                } else {
                    SecureField("操作密码（4~6 位数字）", text: $opPassword)
                        .keyboardType(.numberPad)
                        .textContentType(.password)
                        .onChange(of: opPassword) { _, v in
                            let d = sanitize(v)
                            if d != v { opPassword = d }
                        }
                }

                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(Color.lmAccent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealPassword ? "隐藏密码" : "显示密码")
            }

            HStack {
                Text("已输入")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(opPassword.isEmpty ? "0 位" : "\(opPassword.count) 位")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(opPassword.isEmpty ? Color.secondary : Color.lmAccent)
            }

            if !opPassword.isEmpty {
                previewBlock
            }

            Button("保存操作密码") {
                guard var s = client.session else { return }
                s.opPassword = opPassword
                keychainOK = client.adopt(session: s)
                savedOK = true
            }
            .disabled(opPassword.isEmpty)

            if savedOK == true {
                Label(keychainOK ? "已保存到本机 Keychain" : "已写入内存，但 Keychain 写入失败",
                      systemImage: keychainOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(keychainOK ? Color.lmGood : Color.lmWarn)
            }
        } header: {
            Text("操作密码")
        } footer: {
            Text("""
            车控接口每次都要带 oppwd：用 accessToken 派生的 key/iv 对操作密码做 AES-128-CBC。
            密码只存本机 Keychain，不会外发（外发的是密文）。

            ⚠️ 必须填「你在官方 App 里车控用的那个操作密码」，不是登录密码、不是短信验证码。
            填错 3 次账号会被服务端锁 5 分钟。
            """)
        }
    }

    /// 现场算一遍 oppwd 并回解，用户肉眼就能判断「发出去的明文」对不对
    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewRow("oppwd", oppwdPreview)
            previewRow("本地回解", roundTripPreview)
            previewRow("key / iv", keyIVPreview)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lmAccent.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func previewRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(v)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 车辆

    private var vehicleSection: some View {
        Section("车辆") {
            // 显式给 id: —— 不依赖 Identifiable 的隐式推断，
            // 也就不会被 ForEach 的 Binding<C> 重载抢走（那会级联出一堆怪错误）。
            ForEach(client.vehicles, id: \.vin) { v in
                Button {
                    client.select(vehicle: v)
                    Task { await client.refreshAll() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.displayName).foregroundStyle(.primary)
                            Text(v.vin).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if client.selectedVehicle?.vin == v.vin {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.lmAccent)
                        }
                    }
                }
            }
            Button("刷新车辆列表") {
                Task { _ = try? await client.loadVehicles() }
            }
        }
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        Section("诊断") {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("车控体检（oppwd / token / 上次请求）", systemImage: "stethoscope")
            }
            NavigationLink {
                SelfTestView()
            } label: {
                Label("算法自检（HMAC / XOR3 / AES / MD5）", systemImage: "checkmark.shield")
            }
        }
    }

    // MARK: - 设备

    private var deviceSection: some View {
        Section("设备") {
            row("deviceId", client.config.deviceId)
            row("version", client.config.version)
            row("deviceType", client.config.deviceType)
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                client.signOut()
            } label: {
                Text("退出登录（清除本机会话）")
            }
        }
    }

    // MARK: - 小工具

    private func sanitize(_ v: String) -> String {
        String(v.filter(\.isNumber).prefix(8))
    }

    private func prefix(_ s: String, _ n: Int) -> String {
        s.isEmpty ? "--" : String(s.prefix(n)) + "…"
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

    private var oppwdPreview: String {
        guard let s = client.session, !opPassword.isEmpty,
              let op = try? LMSigner.encryptOppwd(accessToken: s.accessToken, password: opPassword)
        else { return "--" }
        return op
    }

    private var roundTripPreview: String {
        guard let s = client.session, !opPassword.isEmpty,
              let op = try? LMSigner.encryptOppwd(accessToken: s.accessToken, password: opPassword)
        else { return "--" }
        let back = LMSigner.decryptOppwd(accessToken: s.accessToken, oppwd: op)
        return back == opPassword ? "\(back)  ✅ 与输入一致" : "\(back)  ⚠️ 与输入不一致"
    }

    private var keyIVPreview: String {
        guard let s = client.session,
              let p = try? LMSigner.oppwdKeyIV(accessToken: s.accessToken)
        else { return "--" }
        return "\(p.key) / \(p.iv)"
    }

    /// 解出 JWT 的 exp，提醒 token 什么时候过期（过期后所有已登录接口都会失败）
    private func tokenExpiryText(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return "--" }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data),
              let obj = json as? [String: Any],
              let exp = obj["exp"] as? Double
        else { return "--" }
        let d = Date(timeIntervalSince1970: exp)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let remain = Int(d.timeIntervalSinceNow / 60)
        return remain > 0 ? "\(f.string(from: d))（剩 \(remain) 分钟）" : "已过期（\(f.string(from: d))）"
    }
}
