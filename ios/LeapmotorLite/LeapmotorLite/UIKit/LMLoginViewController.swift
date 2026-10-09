//
//  LMLoginViewController.swift
//  LeapmotorLite
//
//  登录页（UIKit 版）—— 对应原来的 `Views/LoginView.swift`。
//
//  两种登录方式：
//    1. 短信验证码（★ 主推，全链路已实测打通）
//    2. 导入登录态（兜底，粘贴官方 App 的登录响应 JSON）
//
//  短信登录三步（全部逆向自 iOS 1.22.68 原生实现）：
//    ① GET  /app-user/applogin/compliance/sendmessagecode
//    ② POST /app-user/applogin/check_login_with_phone   (form-urlencoded)
//    ③ POST /base/base-user/account/v1/login            (sign = SHA256(valueStr))
//
//  ★ 这是 UI 框架迁移（SwiftUI → UIKit）的第一页，也是后续页面的**样板**：
//    继承 `LMBaseViewController`，`buildUI()` 搭一次视图层级，
//    `render()` 按 `client` 状态刷新（必须幂等）。页面自己的输入框内容、
//    倒计时这类**与车端无关**的临时状态放在本地属性里，不进 `LMClient`。
//
import UIKit

final class LMLoginViewController: LMBaseViewController {

    // MARK: - 模式

    private enum Mode: Int {
        case sms = 0
        case importSession = 1
    }

    private var mode: Mode = .sms

    // MARK: - 本地状态（与车端无关，所以不进 LMClient）

    private var phone = ""
    private var code = ""
    private var codeSent = false
    private var countdown = 0
    private var countdownTimer: Timer?
    private var importText = ""
    private var busy = false
    private var message: String?
    private var isError = false

    // MARK: - 控件

    private let heroView = UIView()
    private let heroGradient = CAGradientLayer()
    private let modeControl = UISegmentedControl(items: ["短信验证码", "导入登录态"])

    private let smsStack = UIStackView()
    private let phoneField = UITextField()
    private let codeField = UITextField()
    private let sendCodeButton = UIButton(type: .system)
    private let smsLoginButton = UIButton(type: .system)

    private let importStack = UIStackView()
    private let importView = UITextView()
    private let importButton = UIButton(type: .system)

    private let messageCard = UIView()
    private let messageIcon = UIImageView()
    private let messageLabel = UILabel()

    // MARK: - 搭界面

    override func buildUI() {
        title = "零跑轻控"

        let (_, stack) = makeScrollStack(spacing: 18, inset: 16)
        stack.addArrangedSubview(heroView)
        stack.addArrangedSubview(modeControl)
        stack.addArrangedSubview(smsStack)
        stack.addArrangedSubview(importStack)
        stack.addArrangedSubview(messageCard)
        stack.addArrangedSubview(makeFootnote())

        buildHero()
        buildSMS()
        buildImport()
        buildMessage()

        modeControl.selectedSegmentIndex = Mode.sms.rawValue
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        importStack.isHidden = true
        messageCard.isHidden = true
    }

    // MARK: - 头部

    private func buildHero() {
        heroView.layer.cornerRadius = LMRadius.hero
        heroView.layer.cornerCurve = .continuous
        heroView.layer.masksToBounds = true

        // 原 SwiftUI 版是 lmAccent(0.14) → lmAccent2(0.03) 的斜向渐变。
        // UIKit 用 CAGradientLayer 等价复现；它不参与 Auto Layout，
        // frame 要在 viewDidLayoutSubviews 里手动同步。
        heroGradient.colors = [
            UIColor.lmAccent.withAlphaComponent(0.14).cgColor,
            UIColor.lmAccent2.withAlphaComponent(0.03).cgColor,
        ]
        heroGradient.startPoint = CGPoint(x: 0, y: 0)
        heroGradient.endPoint = CGPoint(x: 1, y: 1)
        heroView.layer.insertSublayer(heroGradient, at: 0)

        let icon = UIImageView(image: UIImage(systemName: "car.fill"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40)
        icon.tintColor = .lmAccent
        icon.contentMode = .center
        icon.backgroundColor = UIColor.lmAccent.withAlphaComponent(0.12)
        icon.layer.cornerRadius = 50
        icon.layer.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 100).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 100).isActive = true

        let titleLabel = LMUIKit.label("零跑轻控", size: 22, weight: .bold)
        titleLabel.textAlignment = .center
        let subLabel = LMUIKit.label("第三方客户端 · 无广告 · 只做功能",
                                     size: 12, color: .secondaryLabel)
        subLabel.textAlignment = .center

        let inner = LMUIKit.vStack(spacing: 12, alignment: .center)
        inner.addArrangedSubview(icon)
        inner.addArrangedSubview(titleLabel)
        inner.addArrangedSubview(subLabel)
        inner.translatesAutoresizingMaskIntoConstraints = false
        heroView.addSubview(inner)

        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: heroView.topAnchor, constant: 18),
            inner.bottomAnchor.constraint(equalTo: heroView.bottomAnchor, constant: -18),
            inner.leadingAnchor.constraint(equalTo: heroView.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: heroView.trailingAnchor, constant: -16),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        heroGradient.frame = heroView.bounds
    }

    // MARK: - 短信验证码

    private func buildSMS() {
        smsStack.axis = .vertical
        smsStack.spacing = 14
        smsStack.addArrangedSubview(LMSectionHeaderLabel("短信验证码登录"))

        let card = LMCardView(spacing: 14)

        phoneField.placeholder = "11 位手机号"
        phoneField.keyboardType = .numberPad
        phoneField.textContentType = .telephoneNumber
        phoneField.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        phoneField.addTarget(self, action: #selector(phoneChanged), for: .editingChanged)
        card.contentStack.addArrangedSubview(labelled("手机号", phoneField))
        card.contentStack.addArrangedSubview(makeSeparator())

        codeField.placeholder = "6 位验证码"
        codeField.keyboardType = .numberPad
        // ★ 这里 `.oneTimeCode` 是**正确**用法：它就是用来收短信验证码的框。
        //   会出错的是「操作密码」那种框 —— 见 lint R8 的说明。
        codeField.textContentType = .oneTimeCode
        codeField.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        codeField.addTarget(self, action: #selector(codeChanged), for: .editingChanged)

        var sendCfg = UIButton.Configuration.plain()
        sendCfg.baseForegroundColor = .lmAccent
        sendCfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10,
                                                        bottom: 6, trailing: 10)
        sendCodeButton.configuration = sendCfg
        sendCodeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        sendCodeButton.addTarget(self, action: #selector(sendCodeTapped), for: .touchUpInside)
        sendCodeButton.setContentHuggingPriority(.required, for: .horizontal)

        let codeRow = LMUIKit.hStack(spacing: 8)
        codeRow.addArrangedSubview(codeField)
        codeRow.addArrangedSubview(sendCodeButton)
        card.contentStack.addArrangedSubview(labelled("验证码", codeRow))

        smsStack.addArrangedSubview(card)

        var loginCfg = UIButton.Configuration.filled()
        loginCfg.title = "登录"
        loginCfg.baseBackgroundColor = .lmAccent
        loginCfg.baseForegroundColor = .white
        loginCfg.cornerStyle = .medium
        smsLoginButton.configuration = loginCfg
        smsLoginButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        smsLoginButton.addTarget(self, action: #selector(smsLoginTapped), for: .touchUpInside)
        smsLoginButton.heightAnchor.constraint(equalToConstant: 46).isActive = true

        smsStack.addArrangedSubview(smsLoginButton)

        smsStack.addArrangedSubview(LMUIKit.footnote(
            "手机号用 RSA 加密后发送（与官方 App 完全一致），验证码 5 分钟内有效、一次性。\n"
            + "登录成功后自动换取 JWT 并派生 signKey。"))
    }

    // MARK: - 导入登录态

    private func buildImport() {
        importStack.axis = .vertical
        importStack.spacing = 14
        importStack.addArrangedSubview(LMSectionHeaderLabel("粘贴登录响应 JSON"))

        let card = LMCardView()
        importView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        importView.autocorrectionType = .no
        importView.autocapitalizationType = .none
        importView.backgroundColor = .clear
        importView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        importView.textContainer.lineFragmentPadding = 0
        importView.delegate = self
        importView.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        card.contentStack.addArrangedSubview(importView)
        importStack.addArrangedSubview(card)

        var cfg = UIButton.Configuration.filled()
        cfg.title = "导入并登录"
        cfg.baseBackgroundColor = .lmAccent
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .medium
        importButton.configuration = cfg
        importButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        importButton.heightAnchor.constraint(equalToConstant: 46).isActive = true

        importStack.addArrangedSubview(importButton)

        importStack.addArrangedSubview(LMUIKit.footnote(
            "把下面任意一种内容整段粘进来即可：\n"
            + "· 官方 App 登录接口返回的整个 JSON"
            + "（含 data.accessToken / data.signParam / data.encryptParam）\n"
            + "· 或只含 accessToken + signParam{r2,r3} + encryptParam{r2,r3} 的对象\n\n"
            + "获取方式见项目 README「如何拿到登录态」。"))
    }

    // MARK: - 消息 / 脚注

    private func buildMessage() {
        messageCard.layer.cornerRadius = LMRadius.tile
        messageCard.layer.cornerCurve = .continuous

        messageIcon.contentMode = .scaleAspectFit
        messageIcon.setContentHuggingPriority(.required, for: .horizontal)
        messageIcon.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.numberOfLines = 0
        // 对应原 SwiftUI 的 .textSelection(.enabled)：允许长按复制（含 signKey）
        messageLabel.isSelectable = true
        messageLabel.isUserInteractionEnabled = true

        let row = LMUIKit.hStack(spacing: 10, alignment: .top)
        row.addArrangedSubview(messageIcon)
        row.addArrangedSubview(messageLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        messageCard.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: messageCard.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: messageCard.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: messageCard.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: messageCard.bottomAnchor, constant: -12),
        ])
    }

    private func makeFootnote() -> UILabel {
        let l = LMUIKit.label(
            "本 App 为第三方客户端，仅用于控制本人账号下的本人车辆。会话仅保存在本机 Keychain。",
            size: 12, color: .secondaryLabel)
        l.textAlignment = .center
        return l
    }

    /// 「小标题 + 控件」的竖排组合，对应原 SwiftUI 里手写的 label + field。
    private func labelled(_ caption: String, _ control: UIView) -> UIView {
        let box = LMUIKit.vStack(spacing: 4)
        box.addArrangedSubview(LMUIKit.label(caption, size: 11, color: .secondaryLabel))
        box.addArrangedSubview(control)
        return box
    }

    /// 1 物理像素的分隔线。
    /// 用 `traitCollection.displayScale` 而不是 `UIScreen.main` —— 后者已弃用。
    private func makeSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        line.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true
        return line
    }

    // MARK: - 刷新

    override func render() {
        // 这一页基本不依赖车端状态（登录前 client 是空的），
        // 但登录成功那一刻 session 变化会走到这里 —— 顺带把按钮状态对齐一遍。
        refreshControls()
    }

    /// 按当前 `busy` / `countdown` / 输入长度刷新按钮可用性与文案。
    /// ★ 必须幂等：只改属性，不重建视图。
    private func refreshControls() {
        modeControl.selectedSegmentIndex = mode.rawValue

        let canSend = !busy && countdown <= 0 && phone.count >= 11
        sendCodeButton.isEnabled = canSend
        let sendTitle = countdown > 0 ? "\(countdown)s" : (codeSent ? "重发" : "获取验证码")
        sendCodeButton.setTitle(sendTitle, for: .normal)
        sendCodeButton.configuration?.showsActivityIndicator = (busy && !codeSent)

        smsLoginButton.isEnabled = !busy && codeSent && code.count >= 4 && phone.count >= 11
        smsLoginButton.configuration?.showsActivityIndicator = (busy && codeSent)

        importButton.isEnabled = !busy
            && !importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        importButton.configuration?.showsActivityIndicator = busy
    }

    private func updateMessage() {
        guard let text = message else {
            messageCard.isHidden = true
            return
        }
        messageCard.isHidden = false
        let tint: UIColor = isError ? .lmBad : .lmGood
        messageCard.backgroundColor = tint.withAlphaComponent(0.10)
        messageIcon.image = UIImage(systemName: isError
                                    ? "exclamationmark.triangle.fill"
                                    : "checkmark.circle.fill")
        messageIcon.tintColor = tint
        messageLabel.text = text
    }

    private func setBusy(_ value: Bool) {
        busy = value
        refreshControls()
    }

    // MARK: - 动作

    @objc private func modeChanged() {
        mode = Mode(rawValue: modeControl.selectedSegmentIndex) ?? .sms
        smsStack.isHidden = (mode != .sms)
        importStack.isHidden = (mode != .importSession)
        view.endEditing(true)
        refreshControls()
    }

    @objc private func phoneChanged() {
        // 只留数字（对应原 SwiftUI 的 onChange 过滤）
        let digits = (phoneField.text ?? "").filter(\.isNumber)
        if digits != phoneField.text { phoneField.text = digits }
        phone = digits
        refreshControls()
    }

    @objc private func codeChanged() {
        let digits = String((codeField.text ?? "").filter(\.isNumber).prefix(6))
        if digits != codeField.text { codeField.text = digits }
        code = digits
        refreshControls()
    }

    @objc private func sendCodeTapped() {
        Task { @MainActor [weak self] in
            await self?.sendCode()
        }
    }

    @objc private func smsLoginTapped() {
        Task { @MainActor [weak self] in
            await self?.smsCodeLogin()
        }
    }

    @objc private func importTapped() {
        doImport()
    }

    private func sendCode() async {
        setBusy(true)
        message = nil
        isError = false
        updateMessage()
        do {
            let msg = try await client.sendSMSCode(phone: phone)
            codeSent = true
            message = msg.isEmpty ? "验证码已发送，请查收短信" : msg
            startCountdown()
        } catch {
            isError = true
            message = error.localizedDescription
        }
        setBusy(false)
        updateMessage()
    }

    private func smsCodeLogin() async {
        setBusy(true)
        message = nil
        isError = false
        updateMessage()
        do {
            let s = try await client.loginWithSMSCode(phone: phone, code: code)
            isError = false
            message = "登录成功：\(s.nickname.isEmpty ? s.accountId : s.nickname)\n"
                + "signKey = \(s.signKeyHex.prefix(16))…"
            await client.refreshAll()
        } catch {
            isError = true
            message = error.localizedDescription
        }
        setBusy(false)
        updateMessage()
    }

    private func doImport() {
        setBusy(true)
        message = nil
        updateMessage()
        do {
            let s = try client.adoptLoginResponse(json: importText)
            isError = false
            message = "已登录：\(s.accountId.isEmpty ? s.nickname : s.accountId)\n"
                + "signKey = \(s.signKeyHex.prefix(16))…"
            Task { @MainActor [weak self] in
                await self?.client.refreshAll()
            }
        } catch {
            isError = true
            message = error.localizedDescription
        }
        setBusy(false)
        updateMessage()
    }

    // MARK: - 倒计时

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdown = 60

        // ★ 用 target/selector 版而不是 block 版：
        //   block 版收的是 `@Sendable` 闭包，**不继承** @MainActor 隔离，
        //   在里面改 `countdown` 可能直接编译报 actor 隔离错误。
        // ★ 必须加进 `.common` 模式：默认的 `.default` 模式下，
        //   用户一拖动 ScrollView 计时器就停走，倒计时会卡住不动。
        let timer = Timer(timeInterval: 1, target: self,
                          selector: #selector(countdownTick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
        refreshControls()
    }

    @objc private func countdownTick() {
        countdown -= 1
        if countdown <= 0 {
            countdown = 0
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
        refreshControls()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 离开页面就停表，避免 Timer 一直持有 self
        countdownTimer?.invalidate()
        countdownTimer = nil
    }
}

// MARK: - 导入框

extension LMLoginViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        importText = textView.text
        refreshControls()
    }
}
