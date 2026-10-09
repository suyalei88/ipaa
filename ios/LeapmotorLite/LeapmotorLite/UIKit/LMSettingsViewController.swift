//
//  LMSettingsViewController.swift
//  LeapmotorLite
//
//  设置页 —— 对应原 `Views/SettingsView.swift`（423 行 SwiftUI Form）。
//
//  ★ 操作密码这一块是「车控报密码错误」的主战场，改动请务必读注释：
//    · 密码框上**不能**挂 `.oneTimeCode` —— 那会让 iOS 把刚收到的短信验证码
//      自动填进这个框，用户输入的数字被悄悄替换掉，结果就是服务端一直回
//      「操作密码错误 / 累计出错 3 次」。
//    · 只留数字、显示位数、可临时明文查看，任何一环出问题用户都能自己看出来。
//
//  ★ 迁移约定（跟 `LMLoginViewController` 一致）：
//    · 继承 `LMBaseViewController`，只覆盖 `buildUI()` / `render()` 两个钩子
//    · 页内状态（操作密码 / 是否明文 / 是否刚保存）**不进 `LMClient`**
//    · `render()` 必须幂等：只改已有控件的属性 + 用 `isHidden` 折叠整行，
//      绝不 `addSubview`（车辆列表和续期日志是例外，见 `rebuildIfNeeded`）
//
//  ⚠️ 本文件里 `import SwiftUI` 只为了一个目的：把**还没迁移**的 SwiftUI 页面
//     包成 VC 再 push（`pushSwiftUIPage`）。等那些页面也迁完，这个 import 和
//     那个方法都能删掉。
//
import UIKit
import SwiftUI

final class LMSettingsViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，跟车端无关）

    private var opPassword = ""
    private var revealPassword = false
    private var savedOK = false
    private var keychainOK = true

    /// 车辆行 / 续期日志行的「内容指纹」缓存。
    ///
    /// 这两块的行数是动态的，行数变了就必须重建视图 —— 但 `render()` 会被
    /// 网络回调反复调用，每次无脑重建既浪费又会打断用户滚动。所以先把内容
    /// 拼成一个字符串当指纹，指纹没变就整块跳过。
    private var rebuildCache: [ObjectIdentifier: String] = [:]

    // MARK: - 控件：当前会话

    private let sessionHeader = LMSectionHeaderLabel("当前会话")
    private let sessionCard = LMCardView()
    private let accountRow = LMSettingsKVRow(key: "账号")
    private let userIdRow = LMSettingsKVRow(key: "userId")
    private let signKeyRow = LMSettingsKVRow(key: "signKey")
    private let encryptKeyRow = LMSettingsKVRow(key: "encryptKey")
    private let tokenRow = LMSettingsKVRow(key: "token")
    private let tokenExpiryRow = LMSettingsKVRow(key: "accessToken 有效期")
    private let refreshTokenRow = LMSettingsKVRow(key: "refreshToken")
    private let refreshTTLRow = LMSettingsKVRow(key: "refreshToken 有效期")
    private let refreshStatusRow = LMSettingsKVRow(key: "续期状态")
    private let renewButton = UIButton()
    private let sessionFooter = LMUIKit.footnote("""
    官方 App「验证码登录一次就一直不退出」，靠的就是 refreshToken 续期。
    accessToken 只有约 2 小时，refreshToken 约 7 天。
    本 App 会在 token 剩余不足 5 分钟时自动打 /base/base-user/token/v1/refresh 换新，
    服务端仍判失效时也会自动续期后重放原请求。
    续期用的是 HMAC-SHA256(旧 signKey) 签名（实测确认；无密钥 SHA256 会被判签名失败）。
    服务端每次续期都会下发新的 refreshToken，7 天窗口是**滑动**的 ——
    所以只要 7 天内续过一次，就不会被踢回登录页。
    """)

    // MARK: - 控件：续期日志

    private let logHeader = LMSectionHeaderLabel("续期日志")
    private let logCard = LMCardView()
    private let logStack = LMUIKit.vStack(spacing: 6)

    // MARK: - 控件：操作密码

    private let pwdHeader = LMSectionHeaderLabel("操作密码")
    private let pwdCard = LMCardView()
    private let opPasswordField = UITextField()
    private let eyeButton = UIButton(type: .system)
    private let countLabel = UILabel()
    private let pwdWarnRow = LMSettingsIconNote(
        icon: "exclamationmark.triangle.fill",
        text: "", color: .lmWarn, size: 11)
    private let previewBox = LMSettingsPreviewBox()
    private let saveButton = UIButton()
    private let saveStatusRow = LMSettingsIconNote(
        icon: "checkmark.circle.fill",
        text: "", color: .lmGood, size: 12)
    private let pwdFooter = LMUIKit.footnote("""
    车控接口每次都要带 oppwd：用 accessToken 派生的 key/iv 对操作密码做 AES-128-CBC。
    密码只存本机 Keychain，不会外发（外发的是密文）。

    ⚠️ 必须填「你在官方 App 里车控用的那个操作密码」，不是登录密码、不是短信验证码。
    填错 3 次账号会被服务端锁 5 分钟。
    """)

    // MARK: - 控件：车辆

    private let vehicleHeader = LMSectionHeaderLabel("车辆")
    private let vehicleCard = LMCardView()
    private let vehicleStack = LMUIKit.vStack(spacing: 10)
    private let refreshVehiclesButton = UIButton()

    // MARK: - 控件：功能

    private let featureHeader = LMSectionHeaderLabel("功能")
    private let featureCard = LMCardView()
    private let vehicleProfileRow = LMSettingsNavRow(
        icon: "doc.text.magnifyingglass",
        title: "车辆档案（版型 / 固件 / 功能开关 / 指令全集）")
    private let locationRow = LMSettingsNavRow(
        icon: "location.fill", title: "车辆定位（地图 / 地址 / 导航）")
    private let chargeRow = LMSettingsNavRow(
        icon: "bolt.fill", title: "车辆充电信息（剩余时间 / 预约充电）")
    private let bleKeyRow = LMSettingsNavRow(
        icon: "key.fill", title: "蓝牙钥匙（钥匙记录 / 协议进度 / 调试台）")
    private let signalRow = LMSettingsNavRow(
        icon: "magnifyingglass.circle", title: "信号浏览器（130 个信号 / 快照对比）")

    // MARK: - 控件：诊断

    private let diagHeader = LMSectionHeaderLabel("诊断")
    private let diagCard = LMCardView()
    private let diagnosticsRow = LMSettingsNavRow(
        icon: "stethoscope", title: "车控体检（oppwd / token / 上次请求）")
    private let selfTestRow = LMSettingsNavRow(
        icon: "checkmark.shield", title: "算法自检（HMAC / XOR3 / AES / MD5）")

    // MARK: - 控件：设备

    private let deviceHeader = LMSectionHeaderLabel("设备")
    private let deviceCard = LMCardView()
    private let buildRow = LMSettingsKVRow(key: "本 App 构建", multiline: true, copyable: true)
    private let deviceIdRow = LMSettingsKVRow(key: "deviceId")
    private let officialVersionRow = LMSettingsKVRow(key: "官方版本号")
    private let deviceTypeRow = LMSettingsKVRow(key: "deviceType")
    private let deviceFooter = LMUIKit.footnote(
        "「官方版本号」是伪装给服务端的，不是本 App 的版本；本 App 版本看第一行。")

    // MARK: - 控件：退出登录

    private let signOutCard = LMCardView()
    private let signOutButton = UIButton()

    // MARK: - 被 push 的页面（还没迁移的 SwiftUI 页）

    /// 设置页要 push 的 7 个页面。
    ///
    /// 用 `tag` 传枚举而不是每个页面写一个 `@objc` 方法 —— 7 个 selector
    /// 容易写错，而且以后每迁完一页就要删一个，容易漏。
    private enum SettingsPage: Int {
        case vehicleProfile, location, charge, bleKey, signal, diagnostics, selfTest
    }

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "设置"
        navigationItem.largeTitleDisplayMode = .always

        let (_, stack) = makeScrollStack(spacing: 18, inset: 16)

        // ---- 当前会话 ----
        [accountRow, userIdRow, signKeyRow, encryptKeyRow, tokenRow,
         tokenExpiryRow, refreshTokenRow, refreshTTLRow, refreshStatusRow]
            .forEach { sessionCard.contentStack.addArrangedSubview($0) }
        renewButton.addTarget(self, action: #selector(renewTapped), for: .touchUpInside)
        styleTextButton(renewButton,
                        title: "立即续期 accessToken",
                        icon: "arrow.triangle.2.circlepath")
        sessionCard.contentStack.addArrangedSubview(
            LMUIKit.hStack(spacing: 0).lmAdding([renewButton, LMUIKit.spacer()]))

        stack.addArrangedSubview(sessionHeader)
        stack.addArrangedSubview(sessionCard)
        stack.addArrangedSubview(sessionFooter)

        // ---- 续期日志 ----
        logCard.contentStack.addArrangedSubview(logStack)
        stack.addArrangedSubview(logHeader)
        stack.addArrangedSubview(logCard)

        // ---- 操作密码 ----
        buildPasswordCard()
        stack.addArrangedSubview(pwdHeader)
        stack.addArrangedSubview(pwdCard)
        stack.addArrangedSubview(pwdFooter)

        // ---- 车辆 ----
        vehicleCard.contentStack.addArrangedSubview(vehicleStack)
        styleTextButton(refreshVehiclesButton, title: "刷新车辆列表")
        refreshVehiclesButton.addTarget(self, action: #selector(refreshVehiclesTapped),
                                        for: .touchUpInside)
        vehicleCard.contentStack.addArrangedSubview(
            LMUIKit.hStack(spacing: 0).lmAdding([refreshVehiclesButton, LMUIKit.spacer()]))
        stack.addArrangedSubview(vehicleHeader)
        stack.addArrangedSubview(vehicleCard)

        // ---- 功能 ----
        buildFeatureCard()
        stack.addArrangedSubview(featureHeader)
        stack.addArrangedSubview(featureCard)

        // ---- 诊断 ----
        diagnosticsRow.tag = SettingsPage.diagnostics.rawValue
        selfTestRow.tag = SettingsPage.selfTest.rawValue
        [diagnosticsRow, selfTestRow].forEach {
            $0.addTarget(self, action: #selector(openPage(_:)), for: .touchUpInside)
            diagCard.contentStack.addArrangedSubview($0)
        }
        stack.addArrangedSubview(diagHeader)
        stack.addArrangedSubview(diagCard)

        // ---- 设备 ----
        [buildRow, deviceIdRow, officialVersionRow, deviceTypeRow]
            .forEach { deviceCard.contentStack.addArrangedSubview($0) }
        stack.addArrangedSubview(deviceHeader)
        stack.addArrangedSubview(deviceCard)
        stack.addArrangedSubview(deviceFooter)

        // ---- 退出登录 ----
        styleTextButton(signOutButton, title: "退出登录（清除本机会话）", tint: .lmBad)
        signOutButton.addTarget(self, action: #selector(signOutTapped), for: .touchUpInside)
        signOutCard.contentStack.addArrangedSubview(signOutButton)
        stack.addArrangedSubview(signOutCard)
    }

    // MARK: - 操作密码卡片

    private func buildPasswordCard() {
        opPasswordField.placeholder = "操作密码（4~6 位数字）"
        opPasswordField.keyboardType = .numberPad
        // ★ 这里必须是 `.password`，**绝不能**是 `.oneTimeCode`。
        //   `.oneTimeCode` 会让 iOS 把刚收到的短信验证码自动填进来，
        //   用户输入的数字被悄悄替换掉 —— 服务端只会回「操作密码错误」。
        opPasswordField.textContentType = .password
        opPasswordField.isSecureTextEntry = true
        opPasswordField.font = .systemFont(ofSize: 15)
        // ★ 只挂 `editingChanged` 做「只留数字」，不实现 UITextFieldDelegate ——
        //   代理方法里再拦一次会让两处规则可能不一致，反而难查。
        opPasswordField.addTarget(self, action: #selector(passwordChanged),
                                  for: .editingChanged)
        opPasswordField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        eyeButton.setImage(UIImage(systemName: "eye.fill"), for: .normal)
        eyeButton.tintColor = .lmAccent
        eyeButton.addTarget(self, action: #selector(toggleReveal), for: .touchUpInside)
        eyeButton.setContentHuggingPriority(.required, for: .horizontal)
        eyeButton.accessibilityLabel = "显示密码"

        pwdCard.contentStack.addArrangedSubview(
            LMUIKit.hStack(spacing: 8).lmAdding([opPasswordField, eyeButton]))

        countLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let countRow = LMUIKit.hStack(spacing: 8)
        countRow.addArrangedSubview(LMUIKit.label("已输入", size: 15, color: .secondaryLabel))
        countRow.addArrangedSubview(LMUIKit.spacer())
        countRow.addArrangedSubview(countLabel)
        pwdCard.contentStack.addArrangedSubview(countRow)

        pwdCard.contentStack.addArrangedSubview(pwdWarnRow)
        pwdCard.contentStack.addArrangedSubview(previewBox)

        styleTextButton(saveButton, title: "保存操作密码")
        saveButton.addTarget(self, action: #selector(savePasswordTapped), for: .touchUpInside)
        pwdCard.contentStack.addArrangedSubview(
            LMUIKit.hStack(spacing: 0).lmAdding([saveButton, LMUIKit.spacer()]))
        pwdCard.contentStack.addArrangedSubview(saveStatusRow)
    }

    // MARK: - 功能卡片

    private func buildFeatureCard() {
        let rows: [(LMSettingsNavRow, SettingsPage)] = [
            (vehicleProfileRow, .vehicleProfile),
            (locationRow, .location),
            (chargeRow, .charge),
            (bleKeyRow, .bleKey),
            (signalRow, .signal),
        ]
        for (row, page) in rows {
            row.tag = page.rawValue
            row.addTarget(self, action: #selector(openPage(_:)), for: .touchUpInside)
            featureCard.contentStack.addArrangedSubview(row)
        }
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        renderSession()
        renderRefreshLog()
        renderPassword()
        renderVehicles()
        renderFeatureBadge()
        renderDevice()
    }

    private func renderSession() {
        guard let s = client.session else {
            sessionHeader.isHidden = true
            sessionCard.isHidden = true
            sessionFooter.isHidden = true
            return
        }
        sessionHeader.isHidden = false
        sessionCard.isHidden = false
        sessionFooter.isHidden = false

        accountRow.setValue(s.accountId.isEmpty ? s.nickname : s.accountId)
        userIdRow.setValue(s.userId.isEmpty ? "--" : s.userId)
        signKeyRow.setValue(abbrev(s.signKeyHex, 20))
        encryptKeyRow.setValue(abbrev(s.encryptKeyHex, 20))
        tokenRow.setValue(abbrev(s.accessToken, 24))
        tokenExpiryRow.setValue(tokenExpiryText(s.accessToken))
        refreshTokenRow.setValue(
            s.refreshToken.isEmpty ? "无 —— 到期只能重新登录" : abbrev(s.refreshToken, 20))
        refreshTTLRow.setValue(refreshTokenTTLText())
        refreshStatusRow.setValue(refreshStatusText())
        renewButton.isHidden = s.refreshToken.isEmpty
    }

    private func renderRefreshLog() {
        let log = client.tokenRefreshLog
        rebuildIfNeeded(logStack, signature: "\(log.count)\u{1}" + log.joined(separator: "\u{1}")) {
            if log.isEmpty {
                return [LMUIKit.footnote("暂无记录（token 未临近过期时不会触发续期）")]
            }
            return log.map { line in
                let l = LMUIKit.label(line, size: 11, color: .secondaryLabel)
                l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                return l
            }
        }
    }

    private func renderPassword() {
        // 只在真的不一致时才写回，避免打断用户正在输入的内容
        if opPasswordField.text != opPassword { opPasswordField.text = opPassword }

        countLabel.text = opPassword.isEmpty ? "0 位" : "\(opPassword.count) 位"
        countLabel.textColor = opPassword.isEmpty ? .secondaryLabel : .lmAccent

        eyeButton.setImage(
            UIImage(systemName: revealPassword ? "eye.slash.fill" : "eye.fill"),
            for: .normal)
        eyeButton.accessibilityLabel = revealPassword ? "隐藏密码" : "显示密码"

        // 只提示，不拦。官方操作密码一般是 4~6 位，但没有权威依据去硬拒，
        // 更不能像以前那样 prefix(8) 静默截断 —— 静默改用户输入正是这次
        // 「车控报密码错误」的同类事故（.oneTimeCode 也是悄悄换掉了输入）。
        let outOfRange = !opPassword.isEmpty && !(4...6).contains(opPassword.count)
        pwdWarnRow.isHidden = !outOfRange
        if outOfRange {
            pwdWarnRow.update(
                icon: "exclamationmark.triangle.fill",
                text: "官方操作密码一般是 4~6 位，当前 \(opPassword.count) 位，请确认没多输/少输",
                color: .lmWarn)
        }

        previewBox.isHidden = opPassword.isEmpty
        if !opPassword.isEmpty {
            previewBox.update(oppwd: oppwdPreview(),
                              roundTrip: roundTripPreview(),
                              keyIV: keyIVPreview())
        }

        saveButton.isEnabled = !opPassword.isEmpty

        saveStatusRow.isHidden = !savedOK
        if savedOK {
            saveStatusRow.update(
                icon: keychainOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                text: keychainOK ? "已保存到本机 Keychain"
                                 : "已写入内存，但 Keychain 写入失败",
                color: keychainOK ? .lmGood : .lmWarn)
        }
    }

    private func renderVehicles() {
        let vs = client.vehicles
        let sig = vs.map {
            "\($0.vin)|\($0.displayName)|\($0.yearText)|\($0.carType ?? "-")|\($0.abilityCount)"
        }.joined(separator: "\u{1}") + "|sel:" + (client.selectedVehicle?.vin ?? "-")

        rebuildIfNeeded(vehicleStack, signature: sig) {
            vs.enumerated().map { idx, v in
                let row = LMSettingsVehicleRow(
                    name: v.displayName,
                    vin: v.vin,
                    meta: "\(v.yearText) · \(v.carType ?? "--") · 能力位 \(v.abilityCount)",
                    selected: client.selectedVehicle?.vin == v.vin)
                row.tag = idx
                row.addTarget(self, action: #selector(vehicleRowTapped(_:)),
                              for: .touchUpInside)
                return row
            }
        }
    }

    private func renderFeatureBadge() {
        if let n = client.noticeCount, let unread = n.unread, unread > 0 {
            vehicleProfileRow.setBadge("\(unread) 条未读")
        } else {
            vehicleProfileRow.setBadge(nil)
        }
    }

    private func renderDevice() {
        buildRow.setValue(LMBuildInfo.displayText)
        deviceIdRow.setValue(client.config.deviceId)
        officialVersionRow.setValue(client.config.version)
        deviceTypeRow.setValue(client.config.deviceType)
    }

    /// 行数会变的两块内容（车辆列表 / 续期日志）专用：指纹没变就整块跳过。
    ///
    /// ★ 这里确实动了 `addArrangedSubview`，属于 `render()` 幂等约定的例外。
    ///   可以这么做的原因是这两块里**没有用户输入控件**，重建不会打断输入；
    ///   而像「操作密码」那种带输入框的区域，一律用 `isHidden` 折叠，不重建。
    private func rebuildIfNeeded(_ container: UIStackView,
                                 signature: String,
                                 build: () -> [UIView]) {
        let key = ObjectIdentifier(container)
        guard rebuildCache[key] != signature else { return }
        rebuildCache[key] = signature
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        build().forEach { container.addArrangedSubview($0) }
    }

    // MARK: - 动作

    @objc private func renewTapped() {
        Task { @MainActor in
            await client.refreshSessionIfNeeded(force: true)
        }
    }

    @objc private func refreshVehiclesTapped() {
        Task { @MainActor in
            _ = try? await client.loadVehicles()
        }
    }

    @objc private func vehicleRowTapped(_ sender: UIControl) {
        let idx = sender.tag
        guard idx >= 0, idx < client.vehicles.count else { return }
        client.select(vehicle: client.vehicles[idx])
        Task { @MainActor in
            await client.refreshAll()
        }
    }

    @objc private func passwordChanged() {
        let v = opPasswordField.text ?? ""
        let d = sanitize(v)
        if d != v { opPasswordField.text = d }
        opPassword = d
        // 保存状态一旦被改动就失效，避免用户改完密码还看到「已保存」
        savedOK = false
        renderPassword()
    }

    @objc private func toggleReveal() {
        revealPassword.toggle()
        let wasFirstResponder = opPasswordField.isFirstResponder
        let saved = opPassword

        opPasswordField.isSecureTextEntry = !revealPassword
        // ★ 切换 `isSecureTextEntry` 之后**必须重新赋一次 text**：
        //   UIKit 会在下一次输入时把已有内容清空（已知行为），
        //   不重赋的话用户看到「刚切的明文，一打字就没了」。
        opPasswordField.text = nil
        opPasswordField.text = saved
        if wasFirstResponder { opPasswordField.becomeFirstResponder() }

        renderPassword()
    }

    @objc private func savePasswordTapped() {
        guard var s = client.session else { return }
        s.opPassword = opPassword
        keychainOK = client.adopt(session: s)
        savedOK = true
        renderPassword()
    }

    @objc private func signOutTapped() {
        client.signOut()
    }

    @objc private func openPage(_ sender: UIControl) {
        guard let page = SettingsPage(rawValue: sender.tag) else { return }
        switch page {
        case .vehicleProfile:
            pushSwiftUIPage("车辆档案") { VehicleProfileView() }
        case .location:
            pushSwiftUIPage("车辆定位") { LocationView() }
        case .charge:
            pushSwiftUIPage("车辆充电信息") { ChargeView() }
        case .bleKey:
            pushSwiftUIPage("蓝牙钥匙") { BLEKeyView() }
        case .signal:
            pushSwiftUIPage("信号浏览器") { SignalExplorerView() }
        case .diagnostics:
            pushSwiftUIPage("车控体检") { DiagnosticsView() }
        case .selfTest:
            pushSwiftUIPage("算法自检") { SelfTestView() }
        }
    }

    /// 把一个**还没迁移**的 SwiftUI 页面推进导航栈。
    ///
    /// `ownsNavigationBar: true` 会让 `LMHostingController` 给内容套
    /// `NavigationStack`（`BLEKeyView` / `DiagnosticsView` 内部有
    /// `NavigationLink`，没有它会静默失效），同时藏掉外层 UIKit 导航栏并补返回键。
    /// 详见 `LMHostingController.ownsNavigationBar` 的注释。
    private func pushSwiftUIPage<C: View>(_ title: String,
                                          @ViewBuilder content: () -> C) {
        let vc = LMHostingController(
            client: client,
            title: title,
            ownsNavigationBar: true,
            onBack: { [weak self] in
                self?.navigationController?.popViewController(animated: true)
            },
            content: content)
        navigationController?.pushViewController(vc, animated: true)
    }

    // MARK: - 小工具

    /// 只滤掉非数字，**不截断**。
    ///
    /// 以前这里是 `prefix(8)`，会静默吃掉第 9 位之后的输入 —— 和
    /// `.oneTimeCode` 污染输入是同一类事故：用户看着自己输对了，发出去的却不对。
    /// 长度上限给个宽松的 16 只是防病态输入，正常密码根本到不了。
    private func sanitize(_ v: String) -> String {
        String(v.filter(\.isNumber).prefix(16))
    }

    private func abbrev(_ s: String, _ n: Int) -> String {
        s.isEmpty ? "--" : String(s.prefix(n)) + "…"
    }

    /// refreshToken 的 TTL（服务端下发，实测 604799 秒 ≈ 7 天）
    private func refreshTokenTTLText() -> String {
        guard let ttl = client.session?.refreshTokenExpireTime, ttl > 0 else { return "未知" }
        let days = Double(ttl) / 86400.0
        return String(format: "%.1f 天（%d 秒）", days, ttl)
    }

    private func refreshStatusText() -> String {
        guard let t = client.lastTokenRefresh else { return "尚未续期" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return "\(f.string(from: t))　\(client.lastTokenRefreshOK == true ? "成功" : "失败")"
    }

    /// 现场算一遍 oppwd 并回解，用户肉眼就能判断「发出去的明文」对不对
    private func oppwdPreview() -> String {
        guard let s = client.session, !opPassword.isEmpty,
              let op = try? LMSigner.encryptOppwd(accessToken: s.accessToken,
                                                  password: opPassword)
        else { return "--" }
        return op
    }

    private func roundTripPreview() -> String {
        guard let s = client.session, !opPassword.isEmpty,
              let op = try? LMSigner.encryptOppwd(accessToken: s.accessToken,
                                                  password: opPassword)
        else { return "--" }
        let back = LMSigner.decryptOppwd(accessToken: s.accessToken, oppwd: op)
        return back == opPassword ? "\(back)  ✅ 与输入一致" : "\(back)  ⚠️ 与输入不一致"
    }

    private func keyIVPreview() -> String {
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
        return remain > 0 ? "\(f.string(from: d))（剩 \(remain) 分钟）"
                          : "已过期（\(f.string(from: d))）"
    }

    /// 表单里那种「纯文字按钮」：无底色、零跑蓝（或传入色）文字。
    /// 对应 SwiftUI `Form` 里的 `Button("...")`。
    ///
    /// ★ 写成**实例方法**而不是 `static func`：`static func` 在属性初始化器里
    ///   调用会被判成「非隔离上下文调用主 actor 方法」。属性初始化器只放
    ///   `UIButton()` / `UITextField()` 这种纯构造，样式统一在这里配。
    private func styleTextButton(_ button: UIButton,
                                 title: String,
                                 icon: String? = nil,
                                 tint: UIColor = .lmAccent) {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.baseForegroundColor = tint
        if let icon {
            cfg.image = UIImage(systemName: icon)
            cfg.imagePadding = 6
        }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4,
                                                    bottom: 8, trailing: 4)
        button.configuration = cfg
    }
}

// MARK: - 一行「键 —— 值」

/// 左边灰色键名，右边等宽字体值（过长时中间截断）。
/// 对应 SwiftUI 里的 `row(_:_:)`。
private final class LMSettingsKVRow: UIView {

    private let keyLabel = UILabel()
    private let valueLabel = UILabel()

    init(key: String, multiline: Bool = false, copyable: Bool = false) {
        super.init(frame: .zero)

        keyLabel.text = key
        keyLabel.font = .systemFont(ofSize: 15)
        keyLabel.textColor = .secondaryLabel
        keyLabel.numberOfLines = multiline ? 0 : 1
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = multiline ? 0 : 1
        valueLabel.textAlignment = .right
        if !multiline { valueLabel.lineBreakMode = .byTruncatingMiddle }
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 12, alignment: multiline ? .top : .firstBaseline)
        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(valueLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // UILabel 没有选择能力（UIKit 的 isSelectable 只属于 UITextView），
        // 要让用户能复制只能自己挂长按手势 —— 跟登录页消息卡同一套做法。
        if copyable {
            let press = UILongPressGestureRecognizer(
                target: self, action: #selector(copyValue))
            press.minimumPressDuration = 0.4
            addGestureRecognizer(press)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("LMSettingsKVRow 只能代码创建")
    }

    func setValue(_ v: String) {
        valueLabel.text = v
    }

    @objc private func copyValue() {
        guard let text = valueLabel.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - 一行「图标 + 提示文字」

/// 对应 SwiftUI 里的 `Label("...", systemImage: "...")` 小字提示。
private final class LMSettingsIconNote: UIView {

    private let iconView = UIImageView()
    private let label = UILabel()

    init(icon: String, text: String, color: UIColor, size: CGFloat) {
        super.init(frame: .zero)

        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = color
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        label.text = text
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.numberOfLines = 0

        let row = LMUIKit.hStack(spacing: 5, alignment: .top)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMSettingsIconNote 只能代码创建")
    }

    func update(icon: String, text: String, color: UIColor) {
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = color
        label.text = text
        label.textColor = color
    }
}

// MARK: - oppwd 预览块

/// 对应 SwiftUI 里的 `previewBlock`：三行「键 + 等宽值」，淡蓝底。
private final class LMSettingsPreviewBox: UIView {

    private let oppwdLabel = UILabel()
    private let roundTripLabel = UILabel()
    private let keyIVLabel = UILabel()

    init() {
        super.init(frame: .zero)

        backgroundColor = UIColor.lmAccent.withAlphaComponent(0.07)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous

        let stack = LMUIKit.vStack(spacing: 6)
        stack.addArrangedSubview(makeRow("oppwd", oppwdLabel))
        stack.addArrangedSubview(makeRow("本地回解", roundTripLabel))
        stack.addArrangedSubview(makeRow("key / iv", keyIVLabel))
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMSettingsPreviewBox 只能代码创建")
    }

    func update(oppwd: String, roundTrip: String, keyIV: String) {
        oppwdLabel.text = oppwd
        roundTripLabel.text = roundTrip
        keyIVLabel.text = keyIV
    }

    private func makeRow(_ key: String, _ valueLabel: UILabel) -> UIView {
        let k = UILabel()
        k.text = key
        k.font = .systemFont(ofSize: 11)
        k.textColor = .secondaryLabel
        k.setContentHuggingPriority(.required, for: .horizontal)
        k.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 2
        valueLabel.lineBreakMode = .byTruncatingMiddle

        let row = LMUIKit.hStack(spacing: 8, alignment: .top)
        row.addArrangedSubview(k)
        row.addArrangedSubview(valueLabel)
        k.widthAnchor.constraint(equalToConstant: 60).isActive = true
        return row
    }
}

// MARK: - 一行可点击的导航行

/// 图标 + 标题 + （可选）角标 + 右侧 chevron。
/// 对应 SwiftUI 里 `NavigationLink { } label: { Label(...) }`。
private final class LMSettingsNavRow: UIControl {

    private let badgeLabel = UILabel()

    init(icon: String, title: String) {
        super.init(frame: .zero)

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = .lmAccent
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0

        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .lmBad
        badgeLabel.isHidden = true
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 10)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(badgeLabel)
        row.addArrangedSubview(chevron)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            iconView.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMSettingsNavRow 只能代码创建")
    }

    func setBadge(_ text: String?) {
        badgeLabel.text = text
        badgeLabel.isHidden = (text ?? "").isEmpty
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }
}

// MARK: - 一行车辆

/// 车辆名 + VIN + 「年款 · 车型 · 能力位 N」，选中时右侧打勾。
/// 对应 SwiftUI 里 `vehicleSection` 的 `ForEach(client.vehicles, id: \.vin)`。
private final class LMSettingsVehicleRow: UIControl {

    init(name: String, vin: String, meta: String, selected: Bool) {
        super.init(frame: .zero)

        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1

        let vinLabel = UILabel()
        vinLabel.text = vin
        vinLabel.font = .systemFont(ofSize: 12)
        vinLabel.textColor = .secondaryLabel
        vinLabel.numberOfLines = 1
        vinLabel.lineBreakMode = .byTruncatingMiddle

        let metaLabel = UILabel()
        metaLabel.text = meta
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 1

        let texts = LMUIKit.vStack(spacing: 2)
        texts.addArrangedSubview(nameLabel)
        texts.addArrangedSubview(vinLabel)
        texts.addArrangedSubview(metaLabel)

        let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        check.tintColor = .lmAccent
        check.contentMode = .scaleAspectFit
        check.isHidden = !selected
        check.setContentHuggingPriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 10)
        row.addArrangedSubview(texts)
        row.addArrangedSubview(check)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMSettingsVehicleRow 只能代码创建")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }
}

// MARK: - StackView 小扩展

private extension UIStackView {
    /// 一次塞多个视图，省掉连写 `addArrangedSubview`。
    @discardableResult
    func lmAdding(_ views: [UIView]) -> UIStackView {
        views.forEach { addArrangedSubview($0) }
        return self
    }
}
