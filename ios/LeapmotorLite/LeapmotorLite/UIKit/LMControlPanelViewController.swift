//
//  LMControlPanelViewController.swift
//  LeapmotorLite
//
//  车控面板（UIKit 版）—— 对应原 `Views/ControlPanelView.swift`（686 行 SwiftUI）。
//
//  自上而下：状态提示条 → 动作网格（门锁 / 后备箱·寻车 / 空调开关 / 电源）
//    → 车窗卡（关闭 / 微开 / 半开）→ 空调风量·温度卡 → 蓝牙钥匙入口 → 脚注
//
//  安全设计（与原页一致，别删）：
//    · 每次下发前弹一次确认（车控是会动车的，不该误触就发）；
//    · 服务端「操作密码累计出错 3 次锁 5 分钟」（业务码 70）时，本地倒计时并禁用按钮。
//
//  ★ 迁移约定（与 `LMSettingsViewController` / `LMLoginViewController` 一致）：
//    · 只覆盖 `buildUI()` / `render()`；`render()` 幂等，条件内容用 `isHidden` 折叠
//    · 页内状态（挡位 / 温度 / pendingAction / now）**不进 `LMClient`**
//    · 只 `import UIKit` —— 本轮 11 个页面同时迁成 UIKit，push 一律直接推 VC，
//      不再有 `pushSwiftUIPage` / `import SwiftUI`
//
//  ★★ 关于「时钟」：原页靠 `.lmClock(until:now:)` 每 0.5s 推一次 `now` 来驱动
//     锁定期倒计时。UIKit 没有「@State 变了就重算 body」这回事 ——
//     等价物是自己跑一个 `Timer` 定时调 `render()`。见 `startClock()`。
//     ⚠️ 必须用 `Timer(timeInterval:target:selector:userInfo:repeats:)`（不是 block 版），
//        且 `RunLoop.main.add(_:forMode: .common)` —— 否则用户一拖动 ScrollView
//        计时器就停走，倒计时冻住，锁定期到期后按钮永远不会重新启用。
//
import UIKit

final class LMControlPanelViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，跟车端无关，所以不进 LMClient）

    /// 正在下发的动作 key（用于显示菊花 + 禁用全部控件）
    private var pendingAction: String?
    /// 空调风量挡位（默认 3，落在 1~9 内）
    private var hvacGear = 3
    /// 空调温度（默认 24，落在 16~32 内）
    private var hvacTemp = 24
    /// 由 `startClock()` 每 0.5s 推一次，驱动锁定期倒计时
    private var now = Date()
    private var clockTimer: Timer?

    /// 挡位行是动态的（挡位范围来自车辆上报），行数变了才重建 —— 见 `rebuildIfNeeded`。
    private var rebuildCache: [ObjectIdentifier: String] = [:]

    // MARK: - 控件：顶部

    private let headerCard = LMCardView(padding: 14)
    private let carIcon = UIImageView()
    private let vehicleNameLabel = UILabel()
    private let vehicleVinLabel = UILabel()
    private let lockPill = LMStatusPillView(text: "已上锁", icon: "lock.fill", tint: .lmGood)

    // MARK: - 控件：提示条

    private let lockedBanner = LMControlBanner()
    private let noPasswordBanner = LMControlBanner()

    // MARK: - 控件：动作网格

    private var actionTiles: [String: LMControlActionTile] = [:]

    // MARK: - 控件：车窗

    private let windowCard = LMCardView(padding: 14)
    private var windowButtons: [LMEndpoints.WindowOpening: LMControlWindowButton] = [:]
    private let windowReportLabel = UILabel()
    private let windowFootnoteLabel = UILabel()

    // MARK: - 控件：空调风量 / 温度

    private let hvacCard = LMCardView(padding: 14)
    private let hvacStateIcon = UIImageView()
    private let hvacStateLabel = UILabel()
    private let gearStack = LMUIKit.vStack(spacing: 6)
    private let gearTitleLabel = UILabel()
    private let gearRangeLabel = UILabel()
    private let tempTitleLabel = UILabel()
    private let tempRangeLabel = UILabel()
    private let tempValueLabel = UILabel()
    private let tempMinusButton = UIButton()
    private let tempPlusButton = UIButton()
    private let hvacSendButton = UIButton()
    private let hvacFootnoteLabel = UILabel()
    private var gearButtons: [Int: LMControlGearButton] = [:]

    // MARK: - 控件：蓝牙钥匙入口 / 脚注 / toast

    private let bleRow = LMControlNavRow(icon: "key.fill", title: "蓝牙钥匙")
    private let footnoteLabel = UILabel()
    private let toastView = UIView()
    private let toastLabel = UILabel()

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "车控"
        navigationItem.largeTitleDisplayMode = .always

        let (scroll, stack) = makeScrollStack(spacing: 18, inset: 16)
        attachRefresh(scroll) { [weak self] in
            try? await self?.client.refreshStatus()
        }

        buildHeader()
        buildBanners()
        buildBleRow()

        footnoteLabel.text = footnoteText
        footnoteLabel.font = .systemFont(ofSize: 12)
        footnoteLabel.textColor = .secondaryLabel
        footnoteLabel.numberOfLines = 0

        stack.addArrangedSubview(headerCard)
        stack.addArrangedSubview(makeBannerSection())
        stack.addArrangedSubview(makeActionSection())
        stack.addArrangedSubview(makeWindowSection())
        stack.addArrangedSubview(makeHvacSection())
        stack.addArrangedSubview(bleRow)
        stack.addArrangedSubview(footnoteLabel)

        buildToast()
    }

    // MARK: - 顶部卡

    private func buildHeader() {
        carIcon.image = UIImage(systemName: "car.fill")
        carIcon.tintColor = .lmAccent
        carIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20)
        carIcon.contentMode = .scaleAspectFit
        carIcon.setContentHuggingPriority(.required, for: .horizontal)

        vehicleNameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        vehicleNameLabel.textColor = .label
        vehicleNameLabel.numberOfLines = 1

        vehicleVinLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        vehicleVinLabel.textColor = .secondaryLabel
        vehicleVinLabel.numberOfLines = 1
        vehicleVinLabel.lineBreakMode = .byTruncatingMiddle

        let texts = LMUIKit.vStack(spacing: 2)
        texts.addArrangedSubview(vehicleNameLabel)
        texts.addArrangedSubview(vehicleVinLabel)

        let row = LMUIKit.hStack(spacing: 12)
        row.addArrangedSubview(carIcon)
        row.addArrangedSubview(texts)
        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(lockPill)
        headerCard.contentStack.addArrangedSubview(row)
    }

    // MARK: - 提示条

    private func buildBanners() {
        lockedBanner.isHidden = true
        noPasswordBanner.isHidden = true
    }

    /// 两条提示条装在同一个竖排里：都隐藏时整块高度自动塌成 0，
    /// 对应原 SwiftUI `@ViewBuilder` 里 `if` 不成立就不渲染的效果。
    private func makeBannerSection() -> UIView {
        let box = LMUIKit.vStack(spacing: 10)
        box.addArrangedSubview(lockedBanner)
        box.addArrangedSubview(noPasswordBanner)
        return box
    }

    // MARK: - 动作网格
    //
    // 分组只是排版 —— 所有动作走的都是同一条 `client.control(key)` 链路。
    // ⚠️ `.window` 分组这里恒为空（车窗三个开度在下面的 windowCard 里），
    //   `keys.isEmpty` 会把它整个跳过，不会渲染出一个空标题。

    private func makeActionSection() -> UIView {
        let section = LMUIKit.vStack(spacing: 18)
        for group in LMEndpoints.Command.Group.allCases {
            let keys = LMEndpoints.actions(in: group)
            if keys.isEmpty { continue }
            let groupStack = LMUIKit.vStack(spacing: 10)
            groupStack.addArrangedSubview(LMSectionHeaderLabel(group.rawValue))
            groupStack.addArrangedSubview(makeActionGrid(keys: keys))
            section.addArrangedSubview(groupStack)
        }
        return section
    }

    /// 原 SwiftUI 是 `LazyVGrid(.adaptive(minimum: 104))`，标准 iPhone 宽度下是 2 列。
    /// 这里用「固定 2 列的横排 StackView」等价复现；tile 数量是静态的（来自命令表），
    /// 所以一次建好，`render()` 里只改状态不重建。
    private func makeActionGrid(keys: [String]) -> UIView {
        let columns = 2
        let rows = LMUIKit.vStack(spacing: 12)
        var index = 0
        while index < keys.count {
            let row = LMUIKit.hStack(spacing: 12)
            row.distribution = .fillEqually
            for _ in 0..<columns {
                if index < keys.count {
                    let key = keys[index]
                    if let cmd = LMEndpoints.commands[key] {
                        let tile = LMControlActionTile(key: key, cmd: cmd,
                                                       accent: accentColor(for: key))
                        tile.addTarget(self, action: #selector(actionTapped(_:)),
                                       for: .touchUpInside)
                        actionTiles[key] = tile
                        row.addArrangedSubview(tile)
                    } else {
                        row.addArrangedSubview(UIView())
                    }
                } else {
                    // 补占位，保证最后一行左对齐、宽度与上一行一致
                    row.addArrangedSubview(UIView())
                }
                index += 1
            }
            rows.addArrangedSubview(row)
        }
        return rows
    }

    private func accentColor(for key: String) -> UIColor {
        switch key {
        case "lock":         return .lmGood
        case "unlock":       return .lmWarn
        case "trunk_open":   return .lmTeal
        case "trunk_close":  return .lmTeal
        case "horn":         return .lmIndigo
        case "window_micro": return .lmPurple
        case "window_half":  return .lmPurple
        case "window_close": return .lmPurple
        case "ac_on":        return .lmAccent
        case "ac_off":       return .lmAccent2
        default:             return .lmBad
        }
    }

    // MARK: - 车窗卡（cmdid 230）
    //
    // ★ 铁证：抓包里 `cmdid 230 {"value":"2"}` 让 1693 / 1694 / 1695 / 1696
    //   四个信号同时 0→2 —— 所以 230 是「四个车窗一起动」，`{"value":"0"}` 是全关。
    // ⚠️ 2 与 5 谁是「半开」谁是「微开」没有直接证据（见 LMEndpoints.WindowOpening）。

    private var windowOpenings: [LMEndpoints.WindowOpening] { [.close, .micro, .half] }

    private func makeWindowSection() -> UIView {
        windowReportLabel.font = .systemFont(ofSize: 12)
        windowReportLabel.textColor = .secondaryLabel
        windowReportLabel.numberOfLines = 0

        windowFootnoteLabel.text = windowFootnote
        windowFootnoteLabel.font = .systemFont(ofSize: 11)
        windowFootnoteLabel.textColor = .secondaryLabel
        windowFootnoteLabel.numberOfLines = 0

        let buttons = LMUIKit.hStack(spacing: 10)
        buttons.distribution = .fillEqually
        for op in windowOpenings {
            let button = LMControlWindowButton(op: op)
            button.addTarget(self, action: #selector(windowTapped(_:)), for: .touchUpInside)
            windowButtons[op] = button
            buttons.addArrangedSubview(button)
        }
        windowCard.contentStack.addArrangedSubview(buttons)
        windowCard.contentStack.addArrangedSubview(windowReportLabel)
        windowCard.contentStack.addArrangedSubview(windowFootnoteLabel)

        let section = LMUIKit.vStack(spacing: 10)
        section.addArrangedSubview(LMSectionHeaderLabel("车窗"))
        section.addArrangedSubview(windowCard)
        return section
    }

    /// 车窗卡里那段长说明。抽成 `-> String` 属性（跟原页同一个理由：
    /// 拼接段数一多，类型检查器容易超时；UIKit 里虽然没有 Text 重载问题，
    /// 但保持「长文案单独成属性」的写法一致，也更好维护）。
    private var windowFootnote: String {
        "cmdid \(LMEndpoints.windowCmdid)，一次会让四个车窗一起动"
        + "。0 = 全关，2 / 5 = 两个开度。\n"
        + "⚠️「2 是微开、5 是半开」是按开度大小排的 —— "
        + "抓包只录到过这两个值，没记录当时按的是哪个按钮。"
        + "实测反了说一声，改一行就行。"
    }

    // MARK: - 空调风量 / 温度卡（cmdid 170）
    //
    // 开 / 关（`{"operate":"auto"|"off"}`）有抓包证据，在动作网格「空调」分组里。
    // 这张卡是**风量和温度**：字段名有证据（官方 IPA 二进制里的
    // `operate` / `manual` / `temperature` / `windlevel`），值域有证据
    // （车辆上报 `funcConfig.HVAC.fan = 1~9` / `temperature = 16~32`），
    // ⚠️ 但「三者拼在一起」这个 payload 没有被抓包证实过。

    private var hvacGears: [Int] {
        if let f = client.selectedVehicle?.hvacFanRange, !f.values.isEmpty { return f.values }
        return LMEndpoints.hvacFanFallback
    }

    private var hvacTemps: [Int] {
        if let t = client.selectedVehicle?.hvacTempRange, !t.values.isEmpty { return t.values }
        return LMEndpoints.hvacTempFallback
    }

    /// 当前将要下发的 state（展示用，和真正发的完全一致）
    private var hvacStateText: String {
        "{\"operate\":\"manual\",\"windlevel\":\"\(hvacGear)\",\"temperature\":\"\(hvacTemp)\"}"
    }

    private var hvacFootnote: String {
        "cmdid \(LMEndpoints.hvacCmdid)，state \(hvacStateText)。\n"
        + "风量 1~9 档、温度 16~32 ℃ 都来自车辆自己上报的能力范围；"
        + "字段名 temperature / windlevel 来自官方 App 二进制。"
        + "但「manual + 风量 + 温度」这个组合没有抓包样本 —— "
        + "试的时候留意车有没有真的响应。指令只改空调状态，不会动车。"
    }

    private func makeHvacSection() -> UIView {
        // 车辆当前上报的空调**开关**状态（信号 1938，1 = 开）。
        // ⚠️ 图标只用**确定存在**的符号名：SF Symbol 名字写错不会编译报错，
        //    只会渲染成空白。`snowflake.circle` 没把握，所以开关两态共用 `snowflake`。
        hvacStateIcon.image = UIImage(systemName: "snowflake")
        hvacStateIcon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        hvacStateIcon.contentMode = .scaleAspectFit
        hvacStateIcon.setContentHuggingPriority(.required, for: .horizontal)

        hvacStateLabel.font = .systemFont(ofSize: 12)
        hvacStateLabel.textColor = .secondaryLabel
        hvacStateLabel.numberOfLines = 0

        let stateRow = LMUIKit.hStack(spacing: 8)
        stateRow.addArrangedSubview(hvacStateIcon)
        stateRow.addArrangedSubview(hvacStateLabel)
        stateRow.addArrangedSubview(LMUIKit.spacer())

        hvacCard.contentStack.addArrangedSubview(stateRow)
        hvacCard.contentStack.addArrangedSubview(makeSeparator())
        hvacCard.contentStack.addArrangedSubview(makeGearBlock())
        hvacCard.contentStack.addArrangedSubview(makeSeparator())
        hvacCard.contentStack.addArrangedSubview(makeTempBlock())
        hvacCard.contentStack.addArrangedSubview(makeSeparator())
        hvacCard.contentStack.addArrangedSubview(makeSendButton())
        hvacCard.contentStack.addArrangedSubview(hvacFootnoteLabel)

        hvacFootnoteLabel.font = .systemFont(ofSize: 11)
        hvacFootnoteLabel.textColor = .secondaryLabel
        hvacFootnoteLabel.numberOfLines = 0

        let section = LMUIKit.vStack(spacing: 10)
        section.addArrangedSubview(LMSectionHeaderLabel("空调风量 / 温度"))
        section.addArrangedSubview(hvacCard)
        return section
    }

    private func makeGearBlock() -> UIView {
        gearTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        gearTitleLabel.textColor = .label
        gearRangeLabel.font = .systemFont(ofSize: 11)
        gearRangeLabel.textColor = .secondaryLabel

        let fanIcon = UIImageView(image: UIImage(systemName: "fanblades"))
        fanIcon.tintColor = .lmAccent
        fanIcon.contentMode = .scaleAspectFit
        fanIcon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        fanIcon.setContentHuggingPriority(.required, for: .horizontal)

        let head = LMUIKit.hStack(spacing: 6)
        head.addArrangedSubview(fanIcon)
        head.addArrangedSubview(gearTitleLabel)
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(gearRangeLabel)

        let block = LMUIKit.vStack(spacing: 8)
        block.addArrangedSubview(head)
        block.addArrangedSubview(gearStack)
        return block
    }

    private func makeTempBlock() -> UIView {
        tempTitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        tempTitleLabel.textColor = .label
        tempRangeLabel.font = .systemFont(ofSize: 11)
        tempRangeLabel.textColor = .secondaryLabel

        let tempIcon = UIImageView(image: UIImage(systemName: "thermometer.medium"))
        tempIcon.tintColor = .lmWarn
        tempIcon.contentMode = .scaleAspectFit
        tempIcon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        tempIcon.setContentHuggingPriority(.required, for: .horizontal)

        let head = LMUIKit.hStack(spacing: 6)
        head.addArrangedSubview(tempIcon)
        head.addArrangedSubview(tempTitleLabel)
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(tempRangeLabel)

        tempValueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        tempValueLabel.textAlignment = .center
        tempValueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        styleStepButton(tempMinusButton, system: "minus")
        tempMinusButton.addTarget(self, action: #selector(tempMinusTapped), for: .touchUpInside)
        styleStepButton(tempPlusButton, system: "plus")
        tempPlusButton.addTarget(self, action: #selector(tempPlusTapped), for: .touchUpInside)

        let control = LMUIKit.hStack(spacing: 12)
        control.addArrangedSubview(tempMinusButton)
        control.addArrangedSubview(tempValueLabel)
        control.addArrangedSubview(tempPlusButton)

        let block = LMUIKit.vStack(spacing: 8)
        block.addArrangedSubview(head)
        block.addArrangedSubview(control)
        return block
    }

    private func styleStepButton(_ button: UIButton, system: String) {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: system)
        cfg.baseForegroundColor = .lmWarn
        cfg.background.backgroundColor = .lmCard
        cfg.background.cornerRadius = 9
        cfg.background.strokeColor = UIColor.lmWarn.withAlphaComponent(0.25)
        cfg.background.strokeWidth = 1
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0,
                                                    bottom: 8, trailing: 0)
        button.configuration = cfg
        button.widthAnchor.constraint(equalToConstant: 52).isActive = true
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    private func makeSendButton() -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = "下发"
        cfg.baseBackgroundColor = UIColor.lmAccent.withAlphaComponent(0.12)
        cfg.baseForegroundColor = .lmAccent
        cfg.cornerStyle = .medium
        cfg.image = UIImage(systemName: "paperplane.fill")
        cfg.imagePadding = 8
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14,
                                                    bottom: 10, trailing: 14)
        hvacSendButton.configuration = cfg
        hvacSendButton.addTarget(self, action: #selector(hvacSendTapped), for: .touchUpInside)
        hvacSendButton.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return hvacSendButton
    }

    // MARK: - 蓝牙钥匙入口
    //
    // 放在动作网格之后：蓝牙钥匙跟「云端下发指令」是两条完全独立的链路
    // （前者是手机直连车端 BLE 模组，后者走 HTTPS 网关）。
    // ⚠️ 这里**只**给入口，绝不放「一键解锁」之类的按钮 —— BLE 协议还没打通。

    private func buildBleRow() {
        bleRow.addTarget(self, action: #selector(bleTapped), for: .touchUpInside)
    }

    // MARK: - Toast

    private func buildToast() {
        toastView.backgroundColor = .lmGood
        toastView.layer.cornerRadius = 18
        toastView.layer.cornerCurve = .continuous
        toastView.layer.shadowColor = UIColor.black.withAlphaComponent(0.12).cgColor
        toastView.layer.shadowRadius = 8
        toastView.layer.shadowOffset = CGSize(width: 0, height: 3)
        toastView.layer.shadowOpacity = 1
        toastView.isHidden = true
        toastView.translatesAutoresizingMaskIntoConstraints = false

        toastLabel.font = LMFont.text(13, weight: .semibold)
        toastLabel.textColor = .lmCanvas
        toastLabel.numberOfLines = 0
        toastLabel.textAlignment = .center
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(toastLabel)

        // toast 挂在 `view`（不是 scroll）上，浮在内容之上，底部对齐安全区。
        view.addSubview(toastView)

        NSLayoutConstraint.activate([
            toastLabel.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 10),
            toastLabel.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -10),
            toastLabel.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -14),

            toastView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                              constant: -24),
            toastView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor,
                                               constant: 16),
            toastView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor,
                                                constant: -16),
        ])
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        let locked = client.isControlLocked(at: now)
        let pending = pendingAction != nil

        renderHeader()
        renderBanners()
        renderActions(locked: locked, pending: pending)
        renderWindow(locked: locked, pending: pending)
        renderHvac(locked: locked, pending: pending)
        renderBle()
    }

    private func renderHeader() {
        guard let v = client.selectedVehicle else {
            headerCard.isHidden = true
            return
        }
        headerCard.isHidden = false
        vehicleNameLabel.text = v.displayName
        vehicleVinLabel.text = v.vin

        if let locked = client.isLocked {
            lockPill.isHidden = false
            lockPill.update(text: locked ? "已上锁" : "未上锁",
                            icon: locked ? "lock.fill" : "lock.open.fill",
                            tint: locked ? .lmGood : .lmWarn)
        } else {
            lockPill.isHidden = true
        }
    }

    private func renderBanners() {
        if client.isControlLocked(at: now) {
            lockedBanner.isHidden = false
            lockedBanner.update(
                icon: "lock.trianglebadge.exclamationmark.fill",
                tint: .lmBad,
                title: "操作密码已锁定",
                text: "服务端返回「操作密码累计出错 3 次以上」，请 "
                    + "\(client.controlLockRemaining(at: now)) 秒后再试。"
                    + "建议先去「设置 → 操作密码」核对密码。")
            noPasswordBanner.isHidden = true
        } else if client.session?.opPassword.isEmpty ?? true {
            lockedBanner.isHidden = true
            noPasswordBanner.isHidden = false
            noPasswordBanner.update(
                icon: "exclamationmark.triangle.fill",
                tint: .lmWarn,
                title: "尚未设置操作密码",
                text: "车控必须带 oppwd。请到「设置 → 操作密码」填写你在官方 App "
                    + "用的那个操作密码（4~6 位数字）。")
        } else {
            lockedBanner.isHidden = true
            noPasswordBanner.isHidden = true
        }
    }

    private func renderActions(locked: Bool, pending: Bool) {
        for (key, tile) in actionTiles {
            tile.update(pending: pending && pendingAction == key, locked: locked)
        }
    }

    private func renderWindow(locked: Bool, pending: Bool) {
        let disabled = locked || pending
        for (_, button) in windowButtons { button.update(disabled: disabled) }

        if let t = client.windowOpeningText {
            windowReportLabel.isHidden = false
            windowReportLabel.text = "车辆当前上报：\(t)"
        } else {
            windowReportLabel.isHidden = true
        }
    }

    private func renderHvac(locked: Bool, pending: Bool) {
        let disabled = locked || pending

        // 车辆当前上报的开关状态（1938）。只报开关，不报风量 / 温度 ——
        // 宁可少显示，也不拿不确定的信号假装成「当前 3 档 / 24℃」。
        let hvacOn = client.hvacOn
        hvacStateIcon.tintColor = hvacOn == true ? .lmAccent : .secondaryLabel
        if let on = hvacOn {
            hvacStateLabel.text = "车辆当前上报：空调\(on ? "开着" : "关着")"
        } else {
            hvacStateLabel.text = "车辆未上报空调开关状态（信号 1938 缺失）"
        }

        gearTitleLabel.text = "风量 \(hvacGear) 档"
        if let f = client.selectedVehicle?.hvacFanRange {
            gearRangeLabel.isHidden = false
            gearRangeLabel.text = "车辆上报 \(f.rangeText)"
        } else {
            gearRangeLabel.isHidden = true
        }
        renderGears(disabled: disabled)

        tempTitleLabel.text = "温度 \(hvacTemp) ℃"
        if let t = client.selectedVehicle?.hvacTempRange {
            tempRangeLabel.isHidden = false
            tempRangeLabel.text = "车辆上报 \(t.rangeText)"
        } else {
            tempRangeLabel.isHidden = true
        }
        tempValueLabel.text = "\(hvacTemp)"
        tempMinusButton.isEnabled = !disabled
        tempPlusButton.isEnabled = !disabled

        hvacFootnoteLabel.text = hvacFootnote

        // ★ 用 `configuration?.title` 而不是 `setTitle(_:for:)`：
        //   按钮是用 UIButton.Configuration 建的，配置里的 title 才是权威来源；
        //   同理字体也由配置决定，直接写 `titleLabel?.font` 会被静默覆盖。
        let hvacPending = pending && (pendingAction?.hasPrefix("hvac_") ?? false)
        hvacSendButton.configuration?.title = "下发：风量 \(hvacGear) 档 · \(hvacTemp) ℃"
        hvacSendButton.configuration?.showsActivityIndicator = hvacPending
        hvacSendButton.isEnabled = !disabled
    }

    /// 挡位行：挡位范围来自车辆上报，行数会变 —— 用指纹去重，没变就不重建。
    private func renderGears(disabled: Bool) {
        let gears = hvacGears
        let signature = gears.map(String.init).joined(separator: ",")
        rebuildIfNeeded(gearStack, signature: signature) {
            gearButtons.removeAll()
            var rows: [UIView] = []
            let perRow = 6
            var index = 0
            while index < gears.count {
                let row = LMUIKit.hStack(spacing: 6)
                row.distribution = .fillEqually
                for _ in 0..<perRow {
                    if index < gears.count {
                        let button = LMControlGearButton(value: gears[index])
                        button.addTarget(self, action: #selector(gearTapped(_:)),
                                         for: .touchUpInside)
                        gearButtons[gears[index]] = button
                        row.addArrangedSubview(button)
                    } else {
                        // 末行补占位，保证每个挡位按钮宽度一致
                        row.addArrangedSubview(UIView())
                    }
                    index += 1
                }
                rows.append(row)
            }
            return rows
        }
        // 选中态就地刷新（不重建，避免闪烁）
        for (value, button) in gearButtons {
            button.update(selected: value == hvacGear, disabled: disabled)
        }
    }

    private func renderBle() {
        if let r = client.bleKeyRecord {
            bleRow.setSubtitle("云端已绑定 \(r.macPretty)（协议 \(r.versionText)）· 查看进度与调试台")
        } else {
            bleRow.setSubtitle("云端暂无绑定记录 · 查看协议进度与 BLE 调试台")
        }
    }

    /// 行数会变的内容（空调挡位行）专用：指纹没变就整块跳过。
    /// ★ 这里是 `render()` 幂等约定的例外 —— 可以重建的前提是这块里
    ///   **没有用户输入控件**；带输入框的区域一律用 `isHidden` 折叠，不重建。
    private func rebuildIfNeeded(_ container: UIStackView,
                                 signature: String,
                                 build: () -> [UIView]) {
        let key = ObjectIdentifier(container)
        guard rebuildCache[key] != signature else { return }
        rebuildCache[key] = signature
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        build().forEach { container.addArrangedSubview($0) }
    }

    // MARK: - 时钟（驱动锁定期倒计时）

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startClock()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 离开页面就停表，避免 Timer 一直持有 self
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func startClock() {
        guard clockTimer == nil else { return }
        // ★ 用 target/selector 版而不是 block 版：block 版收的是 `@Sendable` 闭包，
        //   不继承 @MainActor 隔离，在里面改状态会编译报 actor 隔离错误。
        // ★ 必须加进 `.common` 模式：默认 `.default` 模式下用户一拖 ScrollView 就停走。
        let timer = Timer(timeInterval: 0.5, target: self,
                          selector: #selector(clockTick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    @objc private func clockTick() {
        now = Date()
        render()
    }

    // MARK: - 动作

    @objc private func actionTapped(_ sender: LMControlActionTile) {
        let key = sender.key
        let title: String
        let message: String
        if let cmd = LMEndpoints.commands[key] {
            title = "确认执行「\(cmd.title)」？"
            if cmd.risk == .physical {
                // ★ 2026-10-09：原来这里写「会真的动车门 / 后备箱 / 上电」——
                //   反汇编证实 cmdid 400 是**哨兵模式**（不是上电），而哨兵
                //   已经改成 `.low` 风险走不到这一支；现在 `.physical` 里只剩
                //   门锁 / 后备箱 / 前备箱这些真会开合钣金的动作。
                message = "cmdid \(cmd.cmdid) 会真的开合车门 / 后备箱 / 前备箱。"
                    + "请确认车辆周围安全、车门和后备箱附近没有人，再执行。"
            } else {
                message = "cmdid \(cmd.cmdid)，只改状态（空调开关），不会夹到人。"
            }
        } else {
            title = "确认下发车控指令？"
            message = "将向车辆下发一次真实指令。"
        }
        presentConfirm(title: title, message: message) { [weak self] in
            Task { @MainActor in await self?.run(key: key) }
        }
    }

    @objc private func windowTapped(_ sender: LMControlWindowButton) {
        let op = sender.op
        let title = "确认「车窗\(op.title)」？"
        let message = "cmdid \(LMEndpoints.windowCmdid)，state "
            + "{\"value\":\"\(op.rawValue)\"}。\n"
            + "会让四个车窗一起动，请确认车窗附近没有人、没有夹手风险。"
        presentConfirm(title: title, message: message) { [weak self] in
            Task { @MainActor in await self?.runWindow(op) }
        }
    }

    @objc private func gearTapped(_ sender: LMControlGearButton) {
        hvacGear = sender.value
        render()
    }

    @objc private func tempMinusTapped() {
        hvacTemp = max(hvacTemps.first ?? 16, hvacTemp - 1)
        render()
    }

    @objc private func tempPlusTapped() {
        hvacTemp = min(hvacTemps.last ?? 32, hvacTemp + 1)
        render()
    }

    @objc private func hvacSendTapped() {
        let message = "cmdid \(LMEndpoints.hvacCmdid)，state \(hvacStateText)。\n"
            + "风量范围 1~9、温度 16~32 ℃ 来自车辆配置接口，"
            + "但这个 payload 组合没有抓包证据。指令不会动车。"
        presentConfirm(title: "确认下发空调设置？", message: message) { [weak self] in
            Task { @MainActor in await self?.runHvac() }
        }
    }

    @objc private func bleTapped() {
        // 蓝牙钥匙页已经是 UIKit VC，直接推 —— 不再包 SwiftUI 旧页
        navigationController?.pushViewController(
            LMBLEKeyViewController(client: client), animated: true)
    }

    // MARK: - 业务链路（一个都不能少）

    /// 通用车控：`client.control(key)`（门锁 / 后备箱 / 前备箱 / 鸣笛 / 空调开关 / 哨兵模式）
    private func run(key: String) async {
        pendingAction = key
        render()
        defer {
            pendingAction = nil
            render()
        }
        let title = LMEndpoints.commands[key]?.title ?? key
        let ok = await client.control(key)
        showToast(text: ok ? "\(title) 成功" : (client.lastError ?? "\(title) 失败"),
                  isError: !ok)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hideToast()
        if ok { try? await client.refreshStatus() }
    }

    /// 车窗：`client.controlRaw(cmdid: 230, state: {"value": op})`
    private func runWindow(_ op: LMEndpoints.WindowOpening) async {
        pendingAction = "window_\(op.rawValue)"
        render()
        defer {
            pendingAction = nil
            render()
        }
        let ok = await client.controlRaw(cmdid: LMEndpoints.windowCmdid,
                                         state: LMEndpoints.windowState(op),
                                         label: "车窗\(op.title)")
        showToast(text: ok ? "车窗\(op.title) 成功"
                           : (client.lastError ?? "车窗\(op.title) 失败"),
                  isError: !ok)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hideToast()
        if ok { try? await client.refreshStatus() }
    }

    /// 空调风量 / 温度：`client.controlRaw(cmdid: 170, state: manual payload)`
    private func runHvac() async {
        let gear = hvacGear
        let temp = hvacTemp
        pendingAction = "hvac_\(gear)_\(temp)"
        render()
        defer {
            pendingAction = nil
            render()
        }
        let ok = await client.controlRaw(cmdid: LMEndpoints.hvacCmdid,
                                         state: LMEndpoints.hvacManualState(gear: gear,
                                                                            temperature: temp),
                                         label: "hvac_\(gear)_\(temp)")
        showToast(text: ok ? "风量 \(gear) 档 · \(temp) ℃ 成功"
                           : (client.lastError ?? "空调设置失败"),
                  isError: !ok)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        hideToast()
        if ok { try? await client.refreshStatus() }
    }

    // MARK: - 确认框 / Toast

    private func presentConfirm(title: String, message: String,
                                onConfirm: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认执行", style: .default) { _ in
            onConfirm()
        })
        present(alert, animated: true)
    }

    private func showToast(text: String, isError: Bool) {
        toastLabel.text = text
        toastView.backgroundColor = isError ? .lmBad : .lmGood
        toastView.isHidden = false
    }

    private func hideToast() {
        toastView.isHidden = true
    }

    // MARK: - 小工具

    /// 1 物理像素的分隔线。用 `traitCollection.displayScale` 而不是
    /// 已弃用的 `UIScreen.main`。
    private func makeSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        line.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true
        return line
    }

    /// 脚注长文案抽成 `-> String` 属性（理由见 `windowFootnote`）。
    private var footnoteText: String {
        // ★ 2026-10-09 加：用户问「按钮右上角的感叹号是什么意思」——
        //   那个标记是自己加的物理动作警示（`LMControlActionTile.warnView`），
        //   含义只写在代码注释里，界面上没有任何解释，等于只有开发者看得懂。
        //   这里补一句图例。
        // ★ 2026-10-09 二次修订：脚注里的「上电 400」是错的。反汇编官方主二进制
        //   的 cmdid 分派器证实 `400 = requestForCarSentineMode:`（哨兵模式），
        //   真正的上电是 `410 = requestForOpenOn3`，而 410 没有 payload 样本、没接。
        //   所以这里改成「哨兵模式 400」，并把新接的前备箱 131 列进未验证清单。
        "⚠️ 右上角带感叹号的按钮 = 会让车**真的动起来**的操作"
        + "（开合车门 / 后备箱 / 前备箱），按之前先确认周围没人、没有障碍物；"
        + "不带感叹号的是只改状态的（空调、车窗、充电上限、哨兵模式这类）。\n"
        + "指令下发后会轮询结果。部分功能需要车辆处于对应状态（例如开后备箱前要先解锁）。"
        + "同一账号在官方 App 与本 App 之间不要频繁交叉操作。\n"
        + "已抓包双向验证的：门锁 110、后备箱 130、鸣笛 120、空调开关 170、车窗 230、哨兵模式 400。\n"
        + "未验证的有三处：① 空调风量 / 温度的 payload 组合（字段名和档位范围都有据，"
        + "但没人调过，所以没有样本）；② 车窗的「2 = 微开 / 5 = 半开」哪个是哪个"
        + "（两个值都录到了，但没记录当时按的是哪个按钮）；"
        + "③ 前备箱 131 —— 官方 selector（`requestForFrunkControl:`）与后备箱 130 同族，"
        + "payload 按同族推断为 `{\"value\":\"true\"|\"false\"}`，但没有抓包样本。"
        + "这三处试的时候留意车有没有真的响应。"
        + "「设置 → 诊断」里有官方 42 个 cmdid 的全集表，可以逐个试。"
    }
}

// MARK: - 动作磁贴

/// 图标 + 标题 + `cmdid`，会动物理世界的动作右上角带警示标。
/// 对应原 SwiftUI `actionTile(key:cmd:)`。`UIControl` 自带 `isEnabled` / 高亮。
private final class LMControlActionTile: UIControl {

    let key: String

    private let accent: UIColor
    private let iconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let cmdidLabel = UILabel()
    private let warnView = UIImageView()

    init(key: String, cmd: LMEndpoints.Command, accent: UIColor) {
        self.key = key
        self.accent = accent
        super.init(frame: .zero)

        backgroundColor = .lmCard
        layer.cornerRadius = LMRadius.tile
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = accent.withAlphaComponent(0.20).cgColor

        iconView.image = UIImage(systemName: cmd.systemImage)
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 23, weight: .medium)
        iconView.tintColor = accent
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 26).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 26).isActive = true

        spinner.color = accent
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = cmd.title
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        cmdidLabel.text = "cmdid \(cmd.cmdid)"
        cmdidLabel.font = .systemFont(ofSize: 10)
        cmdidLabel.textColor = .secondaryLabel
        cmdidLabel.textAlignment = .center

        warnView.image = UIImage(systemName: "exclamationmark.triangle.fill")
        warnView.tintColor = .lmWarn
        warnView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9)
        warnView.contentMode = .scaleAspectFit
        warnView.isHidden = (cmd.risk != .physical)
        warnView.translatesAutoresizingMaskIntoConstraints = false

        let stack = LMUIKit.vStack(spacing: 8, alignment: .center)
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(cmdidLabel)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(spinner)
        addSubview(warnView)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 98),

            // 菊花盖在图标位置：不重建视图，只切 alpha / start-stop
            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            warnView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            warnView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMControlActionTile 只能代码创建")
    }

    func update(pending: Bool, locked: Bool) {
        isEnabled = !(pending || locked)
        if pending {
            // ★ 这里用 alpha 而不是 isHidden：iconView 是 StackView 的 arrangedSubview，
            //   一旦 isHidden 就会被栈塌掉高度，盖在它上面的 spinner 会跟着往上跳。
            iconView.alpha = 0
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
            iconView.alpha = 1
        }
        layer.borderColor = accent.withAlphaComponent(pending ? 0.65 : 0.20).cgColor
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var isHighlighted: Bool {
        didSet { if isEnabled { alpha = isHighlighted ? 0.6 : 1 } }
    }
}

// MARK: - 车窗按钮

/// 车窗一个开度（关闭 / 微开 / 半开）。对应原 SwiftUI `windowButton(_:)`。
private final class LMControlWindowButton: UIControl {

    let op: LMEndpoints.WindowOpening

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()

    init(op: LMEndpoints.WindowOpening) {
        self.op = op
        super.init(frame: .zero)

        backgroundColor = .lmCard
        layer.cornerRadius = LMRadius.tile
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.lmPurple.withAlphaComponent(0.22).cgColor

        iconView.image = UIImage(systemName: op == .close
                                 ? "window.vertical.closed" : "window.vertical.open")
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        iconView.tintColor = .lmPurple
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true

        titleLabel.text = op.title
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        valueLabel.text = "value \(op.rawValue)"
        valueLabel.font = .systemFont(ofSize: 10)
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .center

        let stack = LMUIKit.vStack(spacing: 6, alignment: .center)
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(valueLabel)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 78),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMControlWindowButton 只能代码创建")
    }

    func update(disabled: Bool) {
        isEnabled = !disabled
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var isHighlighted: Bool {
        didSet { if isEnabled { alpha = isHighlighted ? 0.6 : 1 } }
    }
}

// MARK: - 风量挡位按钮

/// 一个挡位数字。选中时实心零跑蓝 + 白字。对应原 SwiftUI `gearRow` 里的按钮。
private final class LMControlGearButton: UIControl {

    let value: Int

    private let label = UILabel()

    init(value: Int) {
        self.value = value
        super.init(frame: .zero)

        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1

        label.text = "\(value)"
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMControlGearButton 只能代码创建")
    }

    func update(selected: Bool, disabled: Bool) {
        label.textColor = selected ? .lmCanvas : .lmText
        backgroundColor = selected ? .lmAccent : .lmCard
        layer.borderColor = UIColor.lmAccent.withAlphaComponent(selected ? 0 : 0.28).cgColor
        isEnabled = !disabled
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var isHighlighted: Bool {
        didSet { if isEnabled { alpha = isHighlighted ? 0.6 : 1 } }
    }
}

// MARK: - 可点击导航行（蓝牙钥匙入口）

/// 图标 + 标题 + 副标题 + 右侧 chevron。对应原 SwiftUI `bleCard`。
private final class LMControlNavRow: UIControl {

    private let subtitleLabel = UILabel()

    init(icon: String, title: String) {
        super.init(frame: .zero)

        backgroundColor = .lmCard
        layer.cornerRadius = LMRadius.card
        layer.cornerCurve = .continuous

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = .lmPurple
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .left

        let texts = LMUIKit.vStack(spacing: 3)
        texts.addArrangedSubview(titleLabel)
        texts.addArrangedSubview(subtitleLabel)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 12)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(texts)
        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(chevron)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMControlNavRow 只能代码创建")
    }

    func setSubtitle(_ text: String) {
        subtitleLabel.text = text
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

// MARK: - 提示条

/// 图标 + 标题 + 说明文字，整块淡色底。对应原 SwiftUI `banner(icon:tint:title:text:)`。
private final class LMControlBanner: UIView {

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()

    init() {
        super.init(frame: .zero)

        layer.cornerRadius = LMRadius.tile
        layer.cornerCurve = .continuous

        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0

        textLabel.font = .systemFont(ofSize: 12)
        textLabel.textColor = .secondaryLabel
        textLabel.numberOfLines = 0

        let texts = LMUIKit.vStack(spacing: 3)
        texts.addArrangedSubview(titleLabel)
        texts.addArrangedSubview(textLabel)

        let row = LMUIKit.hStack(spacing: 10, alignment: .top)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(texts)
        row.addArrangedSubview(LMUIKit.spacer())
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMControlBanner 只能代码创建")
    }

    func update(icon: String, tint: UIColor, title: String, text: String) {
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        titleLabel.text = title
        textLabel.text = text
        backgroundColor = tint.withAlphaComponent(0.12)
    }
}
