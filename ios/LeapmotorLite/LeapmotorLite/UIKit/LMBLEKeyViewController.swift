//
//  LMBLEKeyViewController.swift
//  LeapmotorLite
//
//  蓝牙钥匙页（UIKit 版）—— 对应原来的 `Views/BLEKeyView.swift` 里的 `BLEKeyView`。
//
//  ⚠️ 先读这段再改（跟原页一致）：
//  这个页面的**上半部分是真的**（钥匙记录来自云端 commonConfig，接口探测真的发请求），
//  **下半部分是进度说明**（协议还差什么）。绝对不要在 UI 上写「点此解锁」——
//  我们还没拿到 passwordCard 和 cmdId 表，发出去的字节是猜的，
//  拿真车做实验不负责任。
//
//  ★ 迁移约定（与 `LMSettingsViewController` 一致）：
//    · 只覆盖 `buildUI()` / `render()`；`render()` 幂等，条件内容用 `isHidden` 折叠
//    · 页内状态（行为开关 / 探测中标志）不进 `LMClient`
//    · `ble`（`LMBLECentral`）由本页持有，跟原 `@StateObject` 一样 ——
//      蓝牙权限只在真的打开这个页面时才请求，而且和调试台共用同一个连接状态
//
//  ★ 为什么额外 `import Combine`：`LMBLECentral` 是 `ObservableObject`，UIKit 没有
//    `@StateObject` 那套「一变就重算 body」，必须自己订阅它的 `objectWillChange`
//    来触发 `render()`，否则蓝牙状态 / 连接 / 扫描结果变化时界面不会更新。
//  ★ 2026-10-09（Phase 3~6 全部迁完）：push 目标 `DiagnosticsView` /
//    `BLEDebugView` 都已有 UIKit 版，直接推 —— 过渡期的 `import SwiftUI`
//    与 `pushSwiftUIPage` 都已删除。
//
import UIKit
import Combine

final class LMBLEKeyViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，跟车端无关）

    /// 中心设备由本页持有 —— 跟原 `@StateObject private var ble = LMBLECentral()` 等价。
    private let ble = LMBLECentral()

    /// 行为开关的当前值。构造时给纯默认值，真正的读取放在 `buildUI()`：
    /// ★ 属性初始化器只放纯构造，任何 `load()` 这类调用都挪进 `buildUI()`，
    ///   避免被判「非隔离上下文调用主 actor 方法」。
    private var prefs = LMBLEKeyPrefs(autoUnlock: false, autoLock: false, doorUnlock: false)

    /// 接口探测进行中（对应原 `@State private var probing`）
    private var probing = false

    private var cancellables = Set<AnyCancellable>()

    /// 探测结果行是动态的（`prefix(3)`），用指纹缓存避免每次 render 都重建。
    private var rebuildCache: [ObjectIdentifier: String] = [:]

    // MARK: - 控件：蓝牙

    private let bleHeader = LMSectionHeaderLabel("蓝牙")
    private let bleCard = LMCardView()
    private let statePill = LMStatusPillView(text: "未知（还没初始化完）",
                                             icon: "bluetooth.slash", tint: .lmWarn)
    private let scanningLabel = UILabel()
    private let connectedRow = LMBLEIconRow(icon: "link", text: "", color: .lmGood)
    private let actionNote = LMBLEIconRow(icon: "exclamationmark.triangle.fill",
                                          text: "", color: .lmWarn, size: 12)
    private let bleFooter = LMUIKit.footnote("""
    官方 App 的 Info.plist 里写得很明白：
    权限用途 = 「用于蓝牙钥匙、自动泊车」，后台模式含 bluetooth-central 和 bluetooth-peripheral。
    也就是说蓝牙钥匙走的是手机直连车端 BLE 模组，跟车控走的 HTTPS 是两条完全独立的链路。
    """)

    // MARK: - 控件：云端钥匙记录

    private let keyHeader = LMSectionHeaderLabel("云端钥匙记录")
    private let keyCard = LMCardView()
    private let macRow = LMBLEKVRow(key: "车端钥匙 MAC")
    private let versionRow = LMBLEKVRow(key: "协议版本")
    private let bindTimeRow = LMBLEKVRow(key: "绑定时间")
    private let boundNote = LMBLEIconRow(icon: "checkmark.seal.fill",
                                         text: "已绑定", color: .lmGood, size: 12)
    private let configEmptyNote = LMBLEIconRow(icon: "questionmark.circle",
                                               text: "还没读到车辆配置",
                                               color: .secondaryLabel)
    private let refreshConfigRow = LMUIKit.hStack(spacing: 0)
    private let refreshConfigButton = UIButton(type: .system)
    private let noRecordNote = LMBLEIconRow(icon: "xmark.seal",
                                            text: "这台车在云端没有蓝牙钥匙记录",
                                            color: .lmWarn)
    private let noRecordHint = LMUIKit.footnote(
        "说明还没在官方 App 里绑定过蓝牙钥匙。绑定后才能拿到钥匙材料。")
    private let keyFooter = LMUIKit.footnote("""
    来自 GET /carownerservice/v3/api/vehicleinfo/commonConfig 的 config["4"]。

    ⚠️ 这里只有「哪把钥匙」（MAC）和协议版本，**没有密钥材料**。
    真正用来加密的 passwordCard 是配对时服务端下发的，不在这个接口里。
    """)

    // MARK: - 控件：行为开关

    private let switchHeader = LMSectionHeaderLabel("行为开关")
    private let switchCard = LMCardView()
    private let autoUnlockSwitch = UISwitch()
    private let autoLockSwitch = UISwitch()
    private let doorUnlockSwitch = UISwitch()
    private let switchFooter = LMUIKit.footnote("""
    \(LMBLEKeyPrefs.featureDescription)

    ⚠️ 这三个开关目前**只是本机记录，不影响官方 App、也不会真的触发任何动作**。
    官方把它们存在自己的 UserDefaults 里（LMVBLEAutoLockKey / LMVBLEAutoUnLockKey /
    LMVBLEDoorUnLockKey），且是跟「配对后的钥匙」绑定的。
    等 BLE 协议打通、能自己解锁了，它们才会接上真正的行为。
    """)

    // MARK: - 控件：云端接口

    private let cloudHeader = LMSectionHeaderLabel("云端接口")
    private let cloudCard = LMCardView()
    private let probeButton = LMUIKit.plainButton("探测云端钥匙接口（只读）")
    private let probeStack = LMUIKit.vStack(spacing: 12)
    private let moreProbeRow = LMBLENavRow(icon: "stethoscope",
                                           title: "更多接口探测（含配对码 / 删钥匙）")
    private let cloudFooter = LMUIKit.footnote("""
    只探 syncBluetoothKeys —— 它是唯一「语义上是取数据」的接口。
    ccc/pairingcode 会在服务端建待配对会话、ccc/delKey 会删钥匙，
    这两个是**改状态**的，只能在诊断页手动触发。

    ★ 这一步是解锁 BLE 的关键：如果服务端在这里把 passwordCard 吐回来，
    整套 BLE 协议就能自己实现。
    """)

    // MARK: - 控件：协议进度

    private let progressCard = LMCardView()
    private let progressRow = LMBLENavRow(icon: "list.bullet.clipboard", title: "协议进度")

    // MARK: - 控件：工具

    private let toolHeader = LMSectionHeaderLabel("工具")
    private let toolCard = LMCardView()
    private let debugRow = LMBLENavRow(icon: "wave.3.right",
                                       title: "BLE 调试台（扫描 / GATT / 抓帧）")
    private let selfCheckRow = LMBLENavRow(icon: "checkmark.shield",
                                           title: "协议自检（帧切分 / hex / MAC）")
    private let toolFooter = LMUIKit.footnote(
        "调试台是「把协议补完」的工具：连上车、订阅通知、然后用官方 App 操作一次车，每一帧都会被原样记下来。")

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "蓝牙钥匙"

        // 真正的开关读取放这里（属性初始化器只放纯默认值）
        prefs = LMBLEKeyPrefs.load()

        let (_, stack) = makeScrollStack(spacing: 18, inset: 16)

        // ---- ① 蓝牙 ----
        buildBLECard()
        stack.addArrangedSubview(bleHeader)
        stack.addArrangedSubview(bleCard)
        stack.addArrangedSubview(bleFooter)

        // ---- ② 云端钥匙记录 ----
        buildKeyCard()
        stack.addArrangedSubview(keyHeader)
        stack.addArrangedSubview(keyCard)
        stack.addArrangedSubview(keyFooter)

        // ---- ③ 行为开关 ----
        buildSwitchCard()
        stack.addArrangedSubview(switchHeader)
        stack.addArrangedSubview(switchCard)
        stack.addArrangedSubview(switchFooter)

        // ---- ④ 云端接口 ----
        buildCloudCard()
        stack.addArrangedSubview(cloudHeader)
        stack.addArrangedSubview(cloudCard)
        stack.addArrangedSubview(cloudFooter)

        // ---- ⑤ 协议进度（原页这一段没有 header）----
        progressRow.addTarget(self, action: #selector(progressTapped), for: .touchUpInside)
        progressCard.contentStack.addArrangedSubview(progressRow)
        stack.addArrangedSubview(progressCard)

        // ---- ⑥ 工具 ----
        buildToolCard()
        stack.addArrangedSubview(toolHeader)
        stack.addArrangedSubview(toolCard)
        stack.addArrangedSubview(toolFooter)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 对应原页 `.onAppear { ble.prepare() }`：第一次进页面才建 central，
        // 避免 App 一启动就弹蓝牙权限。
        ble.prepare()

        // ★ 订阅中心设备的发布：UIKit 没有 @StateObject 的自动重算。
        //   用 Task { @MainActor } 推到下一轮主队列再刷 —— 原因同 `LMBaseViewController`：
        //   `objectWillChange` 在**新值写入之前**触发，直接在回调里读会拿到旧值。
        ble.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.render()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - ① 蓝牙

    private func buildBLECard() {
        scanningLabel.text = "扫描中"
        scanningLabel.font = .systemFont(ofSize: 12)
        scanningLabel.textColor = .lmAccent
        scanningLabel.isHidden = true
        scanningLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stateRow = LMUIKit.hStack(spacing: 8)
        stateRow.addArrangedSubview(statePill)
        stateRow.addArrangedSubview(LMUIKit.spacer())
        stateRow.addArrangedSubview(scanningLabel)
        bleCard.contentStack.addArrangedSubview(stateRow)

        connectedRow.isHidden = true
        bleCard.contentStack.addArrangedSubview(connectedRow)

        actionNote.isHidden = true
        bleCard.contentStack.addArrangedSubview(actionNote)
    }

    private func renderBLE() {
        let canUse = ble.state.canUse
        statePill.update(text: ble.state.rawValue,
                         icon: canUse ? "bluetooth" : "bluetooth.slash",
                         tint: canUse ? .lmGood : .lmWarn)
        scanningLabel.isHidden = !ble.isScanning

        if let c = ble.connected {
            connectedRow.isHidden = false
            connectedRow.update(icon: "link", text: "已连接 \(c.name)",
                                color: .lmGood, trailing: "\(c.rssi) dBm")
        } else {
            connectedRow.isHidden = true
        }

        let needsAction = ble.state.needsUserAction
        actionNote.isHidden = !needsAction
        if needsAction {
            actionNote.update(icon: "exclamationmark.triangle.fill",
                              text: "需要你手动处理：\(ble.state.rawValue)",
                              color: .lmWarn, size: 12)
        }
    }

    // MARK: - ② 云端钥匙记录

    private func buildKeyCard() {
        [macRow, versionRow, bindTimeRow].forEach { keyCard.contentStack.addArrangedSubview($0) }

        boundNote.isHidden = true
        keyCard.contentStack.addArrangedSubview(boundNote)

        configEmptyNote.isHidden = true
        keyCard.contentStack.addArrangedSubview(configEmptyNote)

        styleTextButton(refreshConfigButton, title: "刷新车辆配置")
        refreshConfigButton.addTarget(self, action: #selector(refreshConfigTapped),
                                      for: .touchUpInside)
        refreshConfigRow.addArrangedSubview(refreshConfigButton)
        refreshConfigRow.addArrangedSubview(LMUIKit.spacer())
        refreshConfigRow.isHidden = true
        keyCard.contentStack.addArrangedSubview(refreshConfigRow)

        noRecordNote.isHidden = true
        keyCard.contentStack.addArrangedSubview(noRecordNote)
        noRecordHint.isHidden = true
        keyCard.contentStack.addArrangedSubview(noRecordHint)
    }

    private func renderKeyRecord() {
        // 三态互斥，原页是 if / else if / else，这里用 isHidden 折叠（UIStackView 自动收拢）
        let hasRecord = client.bleKeyRecord != nil
        let configEmpty = client.configBlobs.isEmpty

        if let r = client.bleKeyRecord {
            macRow.isHidden = false
            versionRow.isHidden = false
            macRow.setValue(r.macPretty)
            versionRow.setValue(r.versionText)
            if let t = r.updateTime {
                bindTimeRow.isHidden = false
                bindTimeRow.setValue(t)
            } else {
                bindTimeRow.isHidden = true
            }
            boundNote.isHidden = false
        } else {
            macRow.isHidden = true
            versionRow.isHidden = true
            bindTimeRow.isHidden = true
            boundNote.isHidden = true
        }

        configEmptyNote.isHidden = hasRecord || !configEmpty
        refreshConfigRow.isHidden = hasRecord || !configEmpty

        let noRecord = !hasRecord && !configEmpty
        noRecordNote.isHidden = !noRecord
        noRecordHint.isHidden = !noRecord
    }

    // MARK: - ③ 行为开关

    private func buildSwitchCard() {
        // 用 tag 传索引而不是每个开关写一个 @objc 方法 —— 三个 selector 容易写错
        autoUnlockSwitch.tag = 0
        autoLockSwitch.tag = 1
        doorUnlockSwitch.tag = 2
        for sw in [autoUnlockSwitch, autoLockSwitch, doorUnlockSwitch] {
            sw.addTarget(self, action: #selector(prefToggled(_:)), for: .valueChanged)
        }
        switchCard.contentStack.addArrangedSubview(switchRow("靠近自动解锁", autoUnlockSwitch))
        switchCard.contentStack.addArrangedSubview(switchRow("远离自动闭锁", autoLockSwitch))
        switchCard.contentStack.addArrangedSubview(switchRow("门把手解锁", doorUnlockSwitch))
    }

    private func switchRow(_ title: String, _ toggle: UISwitch) -> UIView {
        let row = LMUIKit.hStack(spacing: 8)
        row.addArrangedSubview(LMUIKit.label(title, size: 15))
        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(toggle)
        return row
    }

    private func renderSwitches() {
        // 只在真的不一致时才写回，避免和用户正在拨动的开关打架
        if autoUnlockSwitch.isOn != prefs.autoUnlock { autoUnlockSwitch.isOn = prefs.autoUnlock }
        if autoLockSwitch.isOn != prefs.autoLock { autoLockSwitch.isOn = prefs.autoLock }
        if doorUnlockSwitch.isOn != prefs.doorUnlock { doorUnlockSwitch.isOn = prefs.doorUnlock }
    }

    // MARK: - ④ 云端接口

    private func buildCloudCard() {
        // 在封装好的 plainButton 上补图标（标题已由 LMUIKit 配好，不要再动 titleLabel.font，
        // 会被 configuration 覆盖）
        probeButton.configuration?.image =
            UIImage(systemName: "antenna.radiowaves.left.and.right")
        probeButton.configuration?.imagePadding = 6
        probeButton.addTarget(self, action: #selector(probeTapped), for: .touchUpInside)
        cloudCard.contentStack.addArrangedSubview(probeButton)

        cloudCard.contentStack.addArrangedSubview(probeStack)

        moreProbeRow.addTarget(self, action: #selector(moreProbeTapped), for: .touchUpInside)
        cloudCard.contentStack.addArrangedSubview(moreProbeRow)
    }

    private func renderProbes() {
        // 探测中 或 没有选中车辆时不可点（对应原页 .disabled(probing || selectedVehicle == nil)）
        probeButton.isEnabled = !probing && client.selectedVehicle != nil
        probeButton.configuration?.showsActivityIndicator = probing

        let probes = Array(client.bleProbes.prefix(3))
        let sig = probes.map {
            "\($0.ok)|\($0.title)|\($0.timeText)|\($0.path)|\($0.response.prefix(400))"
        }.joined(separator: "\u{1}")

        rebuildIfNeeded(probeStack, signature: sig) {
            probes.map { self.makeProbeRow($0) }
        }
    }

    private func makeProbeRow(_ p: LMBLEProbeResult) -> UIView {
        let box = LMUIKit.vStack(spacing: 4)

        let head = LMUIKit.hStack(spacing: 6)
        let icon = UIImageView(image: UIImage(systemName: p.ok
                                              ? "checkmark.circle.fill" : "xmark.circle.fill"))
        icon.tintColor = p.ok ? .lmGood : .lmBad
        icon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        head.addArrangedSubview(icon)
        head.addArrangedSubview(LMUIKit.label(p.title, size: 12, weight: .semibold))
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(LMUIKit.label(p.timeText, size: 11, color: .secondaryLabel))
        box.addArrangedSubview(head)

        let path = LMUIKit.label(p.path, size: 11, color: .secondaryLabel, lines: 2)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        box.addArrangedSubview(path)

        let resp = LMUIKit.label(String(p.response.prefix(400)), size: 11, lines: 6)
        resp.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        box.addArrangedSubview(resp)

        return box
    }

    // MARK: - ⑥ 工具

    private func buildToolCard() {
        debugRow.addTarget(self, action: #selector(debugTapped), for: .touchUpInside)
        selfCheckRow.addTarget(self, action: #selector(selfCheckTapped), for: .touchUpInside)
        toolCard.contentStack.addArrangedSubview(debugRow)
        toolCard.contentStack.addArrangedSubview(selfCheckRow)
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        renderBLE()
        renderKeyRecord()
        renderSwitches()
        renderProbes()
        renderProgress()
    }

    private func renderProgress() {
        progressRow.setDetail(
            "\(LMBLEQuestions.settled.count) 项已定 / \(LMBLEQuestions.blocking.count) 项待解决")
    }

    /// 行数会变的那块（探测结果）专用：指纹没变就整块跳过。
    ///
    /// ★ 这是 `render()` 幂等约定的例外，可以这么做的原因是这块里**没有用户输入控件**；
    ///   带输入框的区域一律用 `isHidden` 折叠，绝不重建（否则会清掉用户正在输的内容）。
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

    @objc private func refreshConfigTapped() {
        Task { @MainActor in
            try? await client.refreshCommonConfig()
        }
    }

    @objc private func probeTapped() {
        Task { @MainActor in
            probing = true
            render()
            _ = await client.probeBLEKeyReadOnly()
            probing = false
            render()
        }
    }

    @objc private func prefToggled(_ sender: UISwitch) {
        switch sender.tag {
        case 0: prefs.autoUnlock = sender.isOn
        case 1: prefs.autoLock = sender.isOn
        case 2: prefs.doorUnlock = sender.isOn
        default: break
        }
        // 对应原页 `.onChange(of: prefs) { _, new in new.save() }`：任一开关变了就整体落盘
        prefs.save()
    }

    @objc private func moreProbeTapped() {
        navigationController?.pushViewController(
            LMDiagnosticsViewController(client: client), animated: true)
    }

    @objc private func progressTapped() {
        // 本页和协议进度页在同一次迁移里，直接推新的 VC
        navigationController?.pushViewController(
            LMBLEProtocolStatusViewController(client: client), animated: true)
    }

    @objc private func debugTapped() {
        // 复用本页持有的同一个 ble，保证两页连接状态一致。
        navigationController?.pushViewController(
            LMBLEDebugViewController(client: client, ble: ble), animated: true)
    }

    @objc private func selfCheckTapped() {
        navigationController?.pushViewController(
            LMBLEKeySelfCheckViewController(client: client), animated: true)
    }

    // MARK: - 小工具

    /// 表单里那种「纯文字按钮」：无底色、零跑蓝文字。
    /// ★ 写成实例方法而不是 `static func` —— 见 `LMSettingsViewController` 的说明。
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

// MARK: - 一行「图标 + 文字（+ 可选右值）」

/// 对应 SwiftUI 里 `Label("...", systemImage: "...")` 的那类行。
/// 右侧 trailing 是可选的小字（如 RSSI），传 nil 就隐藏。
private final class LMBLEIconRow: UIView {

    private let iconView = UIImageView()
    private let label = UILabel()
    private let trailing = UILabel()

    init(icon: String, text: String, color: UIColor, size: CGFloat = 15, trailing: String? = nil) {
        super.init(frame: .zero)

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        label.numberOfLines = 0

        self.trailing.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        self.trailing.textColor = .secondaryLabel
        self.trailing.setContentHuggingPriority(.required, for: .horizontal)
        self.trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 8)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(self.trailing)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        update(icon: icon, text: text, color: color, size: size, trailing: trailing)
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLEIconRow 只能代码创建")
    }

    func update(icon: String, text: String, color: UIColor,
                size: CGFloat = 15, trailing: String? = nil) {
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = color
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        label.text = text
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        self.trailing.text = trailing
        self.trailing.isHidden = (trailing ?? "").isEmpty
    }
}

// MARK: - 一行「键 —— 值」

/// 左边灰色键名，右边等宽字体值。对应原页的 `row(_:_:)`。
private final class LMBLEKVRow: UIView {

    private let keyLabel = UILabel()
    private let valueLabel = UILabel()

    init(key: String) {
        super.init(frame: .zero)

        keyLabel.text = key
        keyLabel.font = .systemFont(ofSize: 15)
        keyLabel.textColor = .secondaryLabel
        keyLabel.numberOfLines = 1
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 1
        valueLabel.textAlignment = .right
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 12, alignment: .firstBaseline)
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
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLEKVRow 只能代码创建")
    }

    func setValue(_ v: String) {
        valueLabel.text = v
    }
}

// MARK: - 一行可点击的导航行

/// 图标 + 标题 + （可选）右侧说明 + chevron。
/// 对应 SwiftUI 里 `NavigationLink { } label: { Label(...) }`。
private final class LMBLENavRow: UIControl {

    private let detailLabel = UILabel()

    init(icon: String, title: String, detail: String? = nil) {
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

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .right
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 10)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(detailLabel)
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

        setDetail(detail)
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLENavRow 只能代码创建")
    }

    func setDetail(_ s: String?) {
        detailLabel.text = s
        detailLabel.isHidden = (s ?? "").isEmpty
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }
}
