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
            copySection
        }
        .navigationTitle("车控体检")
        .onAppear { copied = false }
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

    /// 这张表是用「多快照线性回归」推出来的，不是抄的：
    ///   快照        100003   1204   3257   3260   1318
    ///   har_appgw    32.9     33    236    190   1909
    ///   har_refresh  36.6     37    262    211   1909
    ///   15:30        41.4     41    298    239   1909
    ///   3257/100003 ≈ 7.16~7.20（满电 717 km），3260/100003 ≈ 5.77（满电 577 km），
    ///   1204 == round(100003) 三组全中 → 100003/1204 才是 SOC。
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
        } header: {
            Text("已确认的信号映射")
        } footer: {
            Text("右侧是该信号此刻的实时值。")
        }
    }

    private static let signalTable: [SignalRef] = [
        SignalRef(id: "100003", name: "剩余电量 %（BMS 原始值，1 位小数）"),
        SignalRef(id: "1204",   name: "剩余电量 %（整数取整）"),
        SignalRef(id: "3257",   name: "剩余续航 km（主显示）"),
        SignalRef(id: "3260",   name: "剩余续航 km（另一标准）"),
        SignalRef(id: "1318",   name: "总里程 km"),
        SignalRef(id: "1349",   name: "车内温度 ℃"),
        SignalRef(id: "1298",   name: "车门锁状态"),
        SignalRef(id: "3262",   name: "车门锁状态（备用）"),
        SignalRef(id: "2190",   name: "纬度"),
        SignalRef(id: "2191",   name: "经度"),
        SignalRef(id: "1200",   name: "剩余充电时间（分钟）"),
    ]

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
