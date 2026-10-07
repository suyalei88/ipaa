//
//  LoginView.swift
//  LeapmotorLite
//
//  登录方式：
//   1. 短信验证码（★ 主推，全链路已实测打通）
//   2. 导入登录态（兜底，粘贴官方 App 的登录响应 JSON）
//
//  短信登录三步（全部逆向自 iOS 1.22.68 原生实现）：
//    ① GET  /app-user/applogin/compliance/sendmessagecode
//    ② POST /app-user/applogin/check_login_with_phone   (form-urlencoded)
//    ③ POST /base/base-user/account/v1/login            (sign = SHA256(valueStr))
//
import SwiftUI
import Foundation

struct LoginView: View {
    @EnvironmentObject var client: LMClient

    enum Mode: String, CaseIterable {
        case sms = "短信验证码"
        case importSession = "导入登录态"
    }

    @State private var mode: Mode = .sms

    // 短信
    @State private var phone = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var countdown = 0

    // 导入
    @State private var importText = ""

    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    modePicker
                    switch mode {
                    case .sms:           smsCard
                    case .importSession: importCard
                    }
                    if let message = message { messageCard(message) }
                    footnote
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("零跑轻控")
        }
    }

    // MARK: - 头部

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "car.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.lmAccent)
                .padding(20)
                .background(Color.lmAccent.opacity(0.12), in: Circle())

            Text("零跑轻控")
                .font(.title2.weight(.bold))
            Text("第三方客户端 · 无广告 · 只做功能")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            LinearGradient(
                colors: [Color.lmAccent.opacity(0.14), Color.lmAccent2.opacity(0.03)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: LMRadius.hero, style: .continuous)
        )
    }

    private var modePicker: some View {
        Picker("方式", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 短信验证码

    private var smsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(text: "短信验证码登录")

            LMCard {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("手机号").font(.caption2).foregroundStyle(.secondary)
                        TextField("11 位手机号", text: $phone)
                            .keyboardType(.numberPad)
                            .textContentType(.telephoneNumber)
                            .font(.body.monospacedDigit())
                            .onChange(of: phone) { _, newValue in
                                // 只留数字
                                let digits = newValue.filter(\.isNumber)
                                if digits != newValue { phone = digits }
                            }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("验证码").font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            // 这里 .oneTimeCode 是**正确**用法：它就是收短信验证码的框
                            TextField("6 位验证码", text: $code)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                .font(.body.monospacedDigit())
                                .onChange(of: code) { _, newValue in
                                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                                    if digits != newValue { code = digits }
                                }

                            Button {
                                Task { await doSendCode() }
                            } label: {
                                if busy && !codeSent {
                                    ProgressView()
                                } else {
                                    Text(countdown > 0 ? "\(countdown)s" : (codeSent ? "重发" : "获取验证码"))
                                        .font(.footnote.weight(.medium))
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(busy || countdown > 0 || phone.count < 11)
                        }
                    }
                }
            }

            Button {
                Task { await doSMSCodeLogin() }
            } label: {
                HStack(spacing: 6) {
                    if busy && codeSent { ProgressView().tint(.white) }
                    Text("登录").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !codeSent || code.count < 4 || phone.count < 11)

            Text("""
            手机号用 RSA 加密后发送（与官方 App 完全一致），验证码 5 分钟内有效、一次性。
            登录成功后自动换取 JWT 并派生 signKey。
            """)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func doSendCode() async {
        busy = true; message = nil; isError = false
        defer { busy = false }
        do {
            let msg = try await client.sendSMSCode(phone: phone)
            codeSent = true
            message = msg.isEmpty ? "验证码已发送，请查收短信" : msg
            startCountdown()
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func doSMSCodeLogin() async {
        busy = true; message = nil; isError = false
        defer { busy = false }
        do {
            let s = try await client.loginWithSMSCode(phone: phone, code: code)
            isError = false
            message = "登录成功：\(s.nickname.isEmpty ? s.accountId : s.nickname)\nsignKey = \(s.signKeyHex.prefix(16))…"
            await client.refreshAll()
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func startCountdown() {
        countdown = 60
        Task { @MainActor in
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdown -= 1
            }
        }
    }

    // MARK: - 导入登录态

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(text: "粘贴登录响应 JSON")

            LMCard {
                TextEditor(text: $importText)
                    .frame(minHeight: 170)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
            }

            Button {
                doImport()
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().tint(.white) }
                    Text("导入并登录").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text("""
            把下面任意一种内容整段粘进来即可：
            · 官方 App 登录接口返回的整个 JSON（含 data.accessToken / data.signParam / data.encryptParam）
            · 或只含 accessToken + signParam{r2,r3} + encryptParam{r2,r3} 的对象

            获取方式见项目 README「如何拿到登录态」。
            """)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func doImport() {
        busy = true; message = nil
        defer { busy = false }
        do {
            let s = try client.adoptLoginResponse(json: importText)
            isError = false
            message = "已登录：\(s.accountId.isEmpty ? s.nickname : s.accountId)\nsignKey = \(s.signKeyHex.prefix(16))…"
            Task { await client.refreshAll() }
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    // MARK: - 消息 / 脚注

    private func messageCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.lmBad : Color.lmGood)
            Text(text)
                .font(.footnote)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.lmBad : Color.lmGood).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: LMRadius.tile, style: .continuous))
    }

    private var footnote: some View {
        Text("本 App 为第三方客户端，仅用于控制本人账号下的本人车辆。会话仅保存在本机 Keychain。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}
