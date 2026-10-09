//
//  LMBLEDebugViewController.swift
//  LeapmotorLite
//
//  BLE 调试台（UIKit 版）—— 对应原来的 `Views/BLEDebugView.swift`（505 行 SwiftUI）。
//
//  这个页面的数据源**不是** `LMClient`，而是另一个 `ObservableObject`：`LMBLECentral`。
//  基类只替我们订阅了 `client.objectWillChange`，**不会**订阅 `ble` —— 所以这里必须
//  自己再挂一根线（见 `buildUI()` 末尾），否则扫描结果 / GATT 树 / 抓帧日志都不会刷新。
//  这也正是本页额外 `import Combine` 的唯一原因（与同域的 `LMBLEKeyViewController` 一致）。
//
//  ★ 三块动态列表（设备 / GATT / 日志）用 `rebuildIfNeeded` 指纹去重：
//    它们的行数会随扫描和抓帧不断变化，必须能重建；而指纹没变时整块跳过 ——
//    抓帧一秒能来几十帧，若无脑重建会把几百行日志反复拆了重搭，直接卡死。
//
//  ★ 「发送原始字节」那块**带输入框**（hex），所以它永远只改 `isHidden` / 文本，
//    绝不在 `render()` 里重建 —— 重建会把用户正在输入的内容清掉。
//
//  ⚠️ 本页的「发送」只能发**用户自己输入**的字节，没有任何内置「解锁」按钮。
//     原因见原页：帧语义没定之前，随便发字节等于拿真车做实验。
//
import UIKit
import Combine

final class LMBLEDebugViewController: LMBaseViewController {

    // MARK: - 依赖

    /// 蓝牙中心设备。由调用方传入（原页是 `BLEDebugView(ble: ble)`），
    /// 跟父页 `LMBLEKeyViewController` 共用同一个实例 —— 这样两页连接状态一致，
    /// 而且蓝牙权限只在真的打开过这些页面时才请求。
    private let ble: LMBLECentral

    // MARK: - 页内 UI 状态（纯界面，跟车端无关，所以不进 LMClient）

    private var filterByService = true
    private var hexInput = ""
    private var inputError: String?
    private var logFilter: LogFilter = .all
    private var writeService: String?
    private var writeChar: String?
    private var copied = false

    /// 设备列表 / 特征行的「反查表」。
    ///
    /// 按钮用 target/action + `tag` 传索引（跟样板页一致），而不是把闭包塞进视图 ——
    /// 闭包跨 `@MainActor` 边界存进视图属性会引出 actor 隔离相关的编译问题。
    /// 行是按当前数组顺序建的，所以 tag 就是这里的下标。
    private var deviceSnapshot: [LMBLEDevice] = []
    private var charTargets: [(service: String, char: String)] = []

    private enum LogFilter: Int, CaseIterable {
        case all = 0, rx, tx, info

        var label: String {
            switch self {
            case .all:  return "全部"
            case .rx:   return "接收"
            case .tx:   return "发送"
            case .info: return "系统"
            }
        }
    }

    // MARK: - ble 刷新订阅

    private var cancellables = Set<AnyCancellable>()
    private var renderPending = false

    /// 列表「内容指纹」缓存：指纹没变就整块跳过重建。
    private var rebuildCache: [ObjectIdentifier: String] = [:]

    // MARK: - 控件：状态 / 扫描

    private let stateHeader = LMSectionHeaderLabel("状态")
    private let stateCard = LMCardView()
    private let stateIcon = UIImageView()
    private let stateLabel = UILabel()
    private let rssiLabel = UILabel()
    private let filterSwitch = UISwitch()
    private let scanButton = UIButton()
    private let stopButton = UIButton()
    private let stateErrorIcon = UIImageView()
    private let stateErrorLabel = UILabel()
    private let stateErrorRow = UIStackView()

    // MARK: - 控件：设备列表

    private let deviceHeader = LMSectionHeaderLabel("发现 0 个设备")
    private let deviceCard = LMCardView()
    private let deviceEmptyLabel = UILabel()
    private let deviceStack = LMUIKit.vStack(spacing: 12)

    // MARK: - 控件：GATT 树

    private let gattHeader = LMSectionHeaderLabel("GATT 树（0 个服务）")
    private let gattCard = LMCardView()
    private let gattNotConnectedLabel = UILabel()
    private let gattDiscoveringRow = UIStackView()
    private let serviceStack = LMUIKit.vStack(spacing: 12)

    // MARK: - 控件：发送

    private let writeHeader = LMSectionHeaderLabel("发送原始字节")
    private let writeCard = LMCardView()
    private let writeNotConnectedLabel = UILabel()
    private let writeNoTargetLabel = UILabel()
    private let targetBox = UIStackView()
    private let targetCharLabel = UILabel()
    private let targetServiceLabel = UILabel()
    private let writeResponseSwitch = UISwitch()
    private let hexField = UITextField()
    private let hexErrorLabel = UILabel()
    private let hexPreviewLabel = UILabel()
    private let sendButton = UIButton()
    private let presetsDisclosure = LMBLEDisclosure(title: "快捷载荷（连通性测试，不是有效指令）")

    // MARK: - 控件：日志

    private let logHeader = LMSectionHeaderLabel("日志（帧 0 / 共 0 条）")
    private let logCard = LMCardView()
    private let logFilterControl = UISegmentedControl(items: ["全部", "接收", "发送", "系统"])
    private let copyLogButton = UIButton()
    private let clearLogButton = UIButton()
    private let logEmptyLabel = UILabel()
    private let logStack = LMUIKit.vStack(spacing: 10)
    private let logOverflowLabel = UILabel()

    // MARK: - init

    /// ★ 本页有两个数据源：全局 `LMClient`（交给基类）和这个页面自己的 `LMBLECentral`。
    ///
    /// 原页签名是 `BLEDebugView(ble: ble)`；迁到 UIKit 后调用方要改成
    /// `LMBLEDebugViewController(client: client, ble: ble)`（`client` 由父页透传）。
    init(client: LMClient, ble: LMBLECentral) {
        self.ble = ble
        super.init(client: client)
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLEDebugViewController 只能代码创建")
    }

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "BLE 调试台"

        let (_, stack) = makeScrollStack(spacing: 18, inset: 16)

        // ---- ① 状态 / 扫描 ----
        buildStateCard()
        stack.addArrangedSubview(stateHeader)
        stack.addArrangedSubview(stateCard)
        stack.addArrangedSubview(LMUIKit.footnote("""
        过滤用的 UUID 是从官方二进制里挖的：\(LMBLEUUID.service)
        扫不到车时关掉过滤再扫一次 —— 有可能车只在配对态才广播那个服务。
        """))

        // ---- ② 设备列表 ----
        buildDeviceCard()
        stack.addArrangedSubview(deviceHeader)
        stack.addArrangedSubview(deviceCard)
        stack.addArrangedSubview(LMUIKit.footnote("""
        ⚠️ 这里的 ID 是 iOS 分配给外设的 identifier，不是 MAC 地址。
        iOS 从 iOS 7 起就不把 MAC 给 App 了，两台手机上同一个车拿到的 ID 也不同。
        要认车只能靠名字、广播里的厂商数据、或者连上后读特征值。
        官方 commonConfig 里那个 mac（C8C83FF5C48E）是车端记录的，跟这里对不上。
        """))

        // ---- ③ GATT 树 ----
        buildGATTCard()
        stack.addArrangedSubview(gattHeader)
        stack.addArrangedSubview(gattCard)
        stack.addArrangedSubview(LMUIKit.footnote(
            "连上后会自动订阅所有可通知的特征 —— 抓官方帧就靠这一步。"))

        // ---- ④ 发送 ----
        buildWriteCard()
        stack.addArrangedSubview(writeHeader)
        stack.addArrangedSubview(writeCard)
        stack.addArrangedSubview(LMUIKit.footnote("""
        ⚠️ 官方帧语义还没定（见「协议进度」）。这里的预设只验证「写入通路 + 分包 + 应答」通不通，
        不是已知的有效指令。不要凭猜往真车发指令。
        超过 MTU 会自动分包，日志里能看到每一包。
        """))

        // ---- ⑤ 日志 ----
        buildLogCard()
        stack.addArrangedSubview(logHeader)
        stack.addArrangedSubview(logCard)
        stack.addArrangedSubview(LMUIKit.footnote("""
        「复制全部日志」会把设备、服务列表和每一帧的 hex / 文本 / 分号切分一起导出。
        抓帧步骤：连上车 → 订阅通知 → 切到官方 App 操作一次 → 回来复制日志。
        """))

        // ★ 关键：订阅 ble 自己的变化。基类只订了 client ——
        //   不补这一根线的话，扫描 / 连接 / 抓帧都不会刷新界面。
        //   用 `Task { @MainActor in }` 推到下一轮主队列再刷，原因同基类：
        //   `objectWillChange` 在**新值写入之前**触发，直接读会拿到旧值。
        //   先订阅、后 `prepare()`：`prepare()` 会建 CBCentralManager，
        //   它的首次状态回调（`objectWillChange`）就不会被漏掉。
        ble.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRender()
            }
            .store(in: &cancellables)

        // ★ 对应原页 `.onAppear { ble.prepare() }`：第一次进页面才建 central，
        //   避免 App 一启动就弹蓝牙权限。
        //   （放在 `buildUI()` 里是为了遵守「只覆盖 buildUI / render 两个钩子」；
        //     `buildUI()` 本来就在 `viewDidLoad` 里被调一次，效果等同。）
        ble.prepare()
    }

    // MARK: - ① 状态 / 扫描

    private func buildStateCard() {
        stateIcon.contentMode = .scaleAspectFit
        stateIcon.setContentHuggingPriority(.required, for: .horizontal)
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        stateIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        stateLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        stateLabel.numberOfLines = 0

        rssiLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        rssiLabel.textColor = .secondaryLabel
        rssiLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stateRow = LMUIKit.hStack(spacing: 8)
        stateRow.addArrangedSubview(stateIcon)
        stateRow.addArrangedSubview(stateLabel)
        stateRow.addArrangedSubview(LMUIKit.spacer())
        stateRow.addArrangedSubview(rssiLabel)

        filterSwitch.onTintColor = .lmAccent
        filterSwitch.addTarget(self, action: #selector(filterSwitchChanged), for: .valueChanged)
        let filterRow = LMUIKit.hStack(spacing: 8)
        filterRow.addArrangedSubview(LMUIKit.label("只扫官方服务 UUID", size: 14))
        filterRow.addArrangedSubview(LMUIKit.spacer())
        filterRow.addArrangedSubview(filterSwitch)

        var scanCfg = UIButton.Configuration.filled()
        scanCfg.title = "开始扫描"
        scanCfg.image = UIImage(systemName: "dot.radiowaves.left.and.right")
        scanCfg.imagePadding = 6
        scanCfg.baseBackgroundColor = .lmAccent
        scanCfg.baseForegroundColor = .lmCanvas
        scanCfg.cornerStyle = .medium
        scanCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        scanButton.configuration = scanCfg
        scanButton.addTarget(self, action: #selector(startScanTapped), for: .touchUpInside)

        var stopCfg = UIButton.Configuration.gray()
        stopCfg.title = "停止"
        stopCfg.baseForegroundColor = .lmBad
        stopCfg.cornerStyle = .medium
        stopCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        stopButton.configuration = stopCfg
        stopButton.addTarget(self, action: #selector(stopScanTapped), for: .touchUpInside)

        let scanRow = LMUIKit.hStack(spacing: 8)
        scanRow.addArrangedSubview(scanButton)
        scanRow.addArrangedSubview(LMUIKit.spacer())
        scanRow.addArrangedSubview(stopButton)

        stateErrorIcon.contentMode = .scaleAspectFit
        stateErrorIcon.setContentHuggingPriority(.required, for: .horizontal)
        stateErrorIcon.translatesAutoresizingMaskIntoConstraints = false
        stateErrorIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        stateErrorLabel.font = .systemFont(ofSize: 12)
        stateErrorLabel.textColor = .lmBad
        stateErrorLabel.numberOfLines = 0

        stateErrorRow.axis = .horizontal
        stateErrorRow.spacing = 5
        stateErrorRow.alignment = .top
        stateErrorRow.addArrangedSubview(stateErrorIcon)
        stateErrorRow.addArrangedSubview(stateErrorLabel)

        stateCard.contentStack.addArrangedSubview(stateRow)
        stateCard.contentStack.addArrangedSubview(makeSeparator())
        stateCard.contentStack.addArrangedSubview(filterRow)
        stateCard.contentStack.addArrangedSubview(makeSeparator())
        stateCard.contentStack.addArrangedSubview(scanRow)
        stateCard.contentStack.addArrangedSubview(stateErrorRow)
    }

    private func renderState() {
        let canUse = ble.state.canUse
        let tint: UIColor = canUse ? .lmGood : .lmWarn
        stateIcon.image = UIImage(systemName: canUse ? "bluetooth" : "bluetooth.slash")
        stateIcon.tintColor = tint
        stateLabel.text = ble.state.rawValue
        stateLabel.textColor = tint

        if let c = ble.connected {
            rssiLabel.isHidden = false
            rssiLabel.text = "\(c.rssi) dBm"
        } else {
            rssiLabel.isHidden = true
        }

        // 只在真的不一致时写回，避免和用户正在拨动的开关打架
        if filterSwitch.isOn != filterByService { filterSwitch.isOn = filterByService }

        scanButton.isEnabled = canUse
        // ★ 走 `configuration?.title` 而不是 `setTitle(_:for:)`：按钮是用 Configuration 建的，
        //   配置里的 title 才是权威来源（`titleLabel?.font` 那类写法会被配置静默覆盖）。
        scanButton.configuration?.title = ble.isScanning ? "重新扫描" : "开始扫描"
        stopButton.isHidden = !ble.isScanning

        if let e = ble.lastError {
            stateErrorRow.isHidden = false
            stateErrorIcon.image = UIImage(systemName: "exclamationmark.triangle.fill")
            stateErrorIcon.tintColor = .lmBad
            stateErrorLabel.text = e
        } else {
            stateErrorRow.isHidden = true
        }
    }

    // MARK: - ② 设备列表

    private func buildDeviceCard() {
        deviceEmptyLabel.font = .systemFont(ofSize: 12)
        deviceEmptyLabel.textColor = .secondaryLabel
        deviceEmptyLabel.numberOfLines = 0

        deviceCard.contentStack.addArrangedSubview(deviceEmptyLabel)
        deviceCard.contentStack.addArrangedSubview(deviceStack)
    }

    private func renderDevices() {
        let sorted = ble.devices.sorted { $0.rssi > $1.rssi }
        deviceSnapshot = sorted

        deviceHeader.text = "发现 \(ble.devices.count) 个设备"

        deviceEmptyLabel.isHidden = !ble.devices.isEmpty
        deviceEmptyLabel.text = ble.isScanning ? "扫描中…" : "还没扫到设备 —— 点上面「开始扫描」"

        // 指纹里带上「哪台已连接」，因为操作按钮会随连接状态切换
        var sig = "\(ble.connected?.id.uuidString ?? "-")|"
        for d in sorted {
            sig += "\(d.id.uuidString)|\(d.name)|\(d.rssi)|\(d.stateText)|\(d.isConnectable)|\(d.isLikelyVehicle)|"
            sig += d.advertisement.keys.sorted()
                .map { "\($0)=\(d.advertisement[$0] ?? "")" }
                .joined(separator: ",")
            sig += "\u{1}"
        }

        rebuildIfNeeded(deviceStack, signature: sig) {
            sorted.enumerated().map { idx, d in
                let row = LMBLEDebugDeviceRow(device: d, isConnected: ble.connected?.id == d.id)
                row.connectButton.tag = idx
                row.connectButton.addTarget(self, action: #selector(deviceConnectTapped(_:)),
                                            for: .touchUpInside)
                row.disconnectButton.tag = idx
                row.disconnectButton.addTarget(self, action: #selector(deviceDisconnectTapped(_:)),
                                               for: .touchUpInside)
                row.rediscoverButton.addTarget(self, action: #selector(deviceRediscoverTapped),
                                               for: .touchUpInside)
                row.readRSSIButton.addTarget(self, action: #selector(deviceReadRSSITapped),
                                             for: .touchUpInside)
                return row
            }
        }
    }

    // MARK: - ③ GATT 树

    private func buildGATTCard() {
        gattNotConnectedLabel.font = .systemFont(ofSize: 12)
        gattNotConnectedLabel.textColor = .secondaryLabel
        gattNotConnectedLabel.text = "未连接 —— 先在上面选一个设备点「连接」"
        gattNotConnectedLabel.numberOfLines = 0

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        gattDiscoveringRow.axis = .horizontal
        gattDiscoveringRow.spacing = 8
        gattDiscoveringRow.alignment = .center
        gattDiscoveringRow.addArrangedSubview(spinner)
        gattDiscoveringRow.addArrangedSubview(
            LMUIKit.label("正在发现服务与特征…", size: 12, color: .secondaryLabel))

        gattCard.contentStack.addArrangedSubview(gattNotConnectedLabel)
        gattCard.contentStack.addArrangedSubview(gattDiscoveringRow)
        gattCard.contentStack.addArrangedSubview(serviceStack)
    }

    private func renderGATT() {
        let connected = ble.connected != nil
        gattHeader.text = "GATT 树（\(ble.services.count) 个服务）"

        gattNotConnectedLabel.isHidden = connected
        gattDiscoveringRow.isHidden = !(connected && ble.services.isEmpty)

        // 先把「服务/特征」拍平成一张索引表，按钮的 tag 就是它的下标
        var targets: [(service: String, char: String)] = []
        var sig = ""
        for s in ble.services {
            sig += "\(s.uuid)|\(s.isPrimary)|"
            for c in s.characteristics {
                sig += "\(c.uuid)|\(c.props.joined(separator: ","))|\(c.canNotify)|\(c.isNotifying)"
                    + "|\(c.canWrite)|\(c.canWriteNoResponse)|\(c.lastValue ?? "")|"
                targets.append((s.uuid, c.uuid))
            }
            sig += "\u{1}"
        }
        charTargets = targets

        var cursor = 0
        rebuildIfNeeded(serviceStack, signature: sig) {
            ble.services.map { s in
                let charRows: [UIView] = s.characteristics.map { c in
                    let row = LMBLEDebugCharRow(char: c)
                    let idx = cursor
                    cursor += 1
                    row.toggleNotifyButton.tag = idx
                    row.toggleNotifyButton.addTarget(self, action: #selector(charToggleNotifyTapped(_:)),
                                                     for: .touchUpInside)
                    row.readButton.tag = idx
                    row.readButton.addTarget(self, action: #selector(charReadTapped(_:)),
                                             for: .touchUpInside)
                    row.setWriteTargetButton.tag = idx
                    row.setWriteTargetButton.addTarget(self, action: #selector(charSetWriteTargetTapped(_:)),
                                                       for: .touchUpInside)
                    return row
                }
                return LMBLEDebugServiceRow(service: s, charRows: charRows)
            }
        }
    }

    // MARK: - ④ 发送

    private func buildWriteCard() {
        writeNotConnectedLabel.font = .systemFont(ofSize: 12)
        writeNotConnectedLabel.textColor = .secondaryLabel
        writeNotConnectedLabel.text = "未连接 —— 连上之后才能发字节"
        writeNotConnectedLabel.numberOfLines = 0

        writeNoTargetLabel.font = .systemFont(ofSize: 12)
        writeNoTargetLabel.textColor = .secondaryLabel
        writeNoTargetLabel.text = "还没选写入目标 —— 在上面 GATT 树里点「设为写入目标」"
        writeNoTargetLabel.numberOfLines = 0

        targetCharLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        targetCharLabel.lineBreakMode = .byTruncatingMiddle
        targetCharLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        targetServiceLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        targetServiceLabel.textColor = .secondaryLabel
        targetServiceLabel.lineBreakMode = .byTruncatingMiddle

        let targetRow = LMUIKit.hStack(spacing: 8)
        targetRow.addArrangedSubview(LMUIKit.label("目标", size: 14, color: .secondaryLabel))
        targetRow.addArrangedSubview(LMUIKit.spacer())
        targetRow.addArrangedSubview(targetCharLabel)

        targetBox.axis = .vertical
        targetBox.spacing = 2
        targetBox.addArrangedSubview(targetRow)
        targetBox.addArrangedSubview(targetServiceLabel)

        writeResponseSwitch.onTintColor = .lmAccent
        writeResponseSwitch.addTarget(self, action: #selector(writeResponseSwitchChanged),
                                      for: .valueChanged)
        let respRow = LMUIKit.hStack(spacing: 8)
        respRow.addArrangedSubview(LMUIKit.label("写入用「有应答」模式", size: 14))
        respRow.addArrangedSubview(LMUIKit.spacer())
        respRow.addArrangedSubview(writeResponseSwitch)

        hexField.placeholder = "十六进制，如 FF ED 12 34"
        hexField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        hexField.borderStyle = .roundedRect
        hexField.autocorrectionType = .no
        hexField.spellCheckingType = .no
        hexField.autocapitalizationType = .allCharacters
        hexField.clearButtonMode = .whileEditing
        hexField.addTarget(self, action: #selector(hexChanged), for: .editingChanged)
        hexField.heightAnchor.constraint(equalToConstant: 40).isActive = true

        hexErrorLabel.font = .systemFont(ofSize: 11)
        hexErrorLabel.textColor = .lmWarn
        hexErrorLabel.numberOfLines = 0

        hexPreviewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hexPreviewLabel.textColor = .secondaryLabel
        hexPreviewLabel.numberOfLines = 0

        var sendCfg = UIButton.Configuration.filled()
        sendCfg.title = "发送"
        sendCfg.image = UIImage(systemName: "paperplane.fill")
        sendCfg.imagePadding = 6
        sendCfg.baseBackgroundColor = .lmAccent
        sendCfg.baseForegroundColor = .lmCanvas
        sendCfg.cornerStyle = .medium
        sendButton.configuration = sendCfg
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        buildPresets()

        writeCard.contentStack.addArrangedSubview(writeNotConnectedLabel)
        writeCard.contentStack.addArrangedSubview(writeNoTargetLabel)
        writeCard.contentStack.addArrangedSubview(targetBox)
        writeCard.contentStack.addArrangedSubview(respRow)
        writeCard.contentStack.addArrangedSubview(hexField)
        writeCard.contentStack.addArrangedSubview(hexErrorLabel)
        writeCard.contentStack.addArrangedSubview(hexPreviewLabel)
        writeCard.contentStack.addArrangedSubview(sendButton)
        writeCard.contentStack.addArrangedSubview(presetsDisclosure)
    }

    private func buildPresets() {
        for (i, p) in LMBLEPreset.all.enumerated() {
            let row = LMBLEDebugPresetRow(preset: p)
            row.tag = i
            row.addTarget(self, action: #selector(presetTapped(_:)), for: .touchUpInside)
            presetsDisclosure.contentStack.addArrangedSubview(row)
        }
    }

    private func renderWrite() {
        let connected = ble.connected != nil

        // 三态互斥，跟原页的 if / else if / else 一一对应（用 isHidden 折叠，UIStackView 自动收拢）
        writeNotConnectedLabel.isHidden = connected
        writeNoTargetLabel.isHidden = !(connected && writeChar == nil)
        targetBox.isHidden = !(connected && writeChar != nil)

        if let c = writeChar, let s = writeService {
            targetCharLabel.text = c
            targetServiceLabel.text = s
        }

        if writeResponseSwitch.isOn != ble.writeWithResponse {
            writeResponseSwitch.isOn = ble.writeWithResponse
        }

        // ★ 输入框内容以 `hexInput` 为准；只有真的不一致时才写回 ——
        //   否则会在用户输入过程中把内容/光标重置掉。
        if hexField.text != hexInput { hexField.text = hexInput }

        if let e = inputError {
            hexErrorLabel.isHidden = false
            hexErrorLabel.text = e
            hexPreviewLabel.isHidden = true
        } else {
            hexErrorLabel.isHidden = true
            if let d = LMBLEHex.data(from: hexInput) {
                hexPreviewLabel.isHidden = false
                hexPreviewLabel.text = "= \(d.count) 字节：\(LMBLEHex.string(d))"
            } else {
                hexPreviewLabel.isHidden = true
            }
        }

        sendButton.isEnabled = inputError == nil && !hexInput.isEmpty && writeChar != nil
    }

    // MARK: - ⑤ 日志

    private func buildLogCard() {
        logFilterControl.selectedSegmentIndex = LogFilter.all.rawValue
        logFilterControl.addTarget(self, action: #selector(logFilterChanged), for: .valueChanged)

        var copyCfg = UIButton.Configuration.plain()
        copyCfg.title = "复制全部日志"
        copyCfg.image = UIImage(systemName: "doc.on.doc")
        copyCfg.imagePadding = 6
        copyCfg.baseForegroundColor = .lmAccent
        copyCfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        copyLogButton.configuration = copyCfg
        copyLogButton.addTarget(self, action: #selector(copyLogTapped), for: .touchUpInside)

        var clearCfg = UIButton.Configuration.plain()
        clearCfg.title = "清空"
        clearCfg.baseForegroundColor = .lmBad
        clearCfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        clearLogButton.configuration = clearCfg
        clearLogButton.addTarget(self, action: #selector(clearLogTapped), for: .touchUpInside)

        let toolsRow = LMUIKit.hStack(spacing: 8)
        toolsRow.addArrangedSubview(copyLogButton)
        toolsRow.addArrangedSubview(LMUIKit.spacer())
        toolsRow.addArrangedSubview(clearLogButton)

        logEmptyLabel.font = .systemFont(ofSize: 12)
        logEmptyLabel.textColor = .secondaryLabel
        logEmptyLabel.text = "（还没有日志）"

        logOverflowLabel.font = .systemFont(ofSize: 11)
        logOverflowLabel.textColor = .secondaryLabel
        logOverflowLabel.numberOfLines = 0

        logCard.contentStack.addArrangedSubview(logFilterControl)
        logCard.contentStack.addArrangedSubview(toolsRow)
        logCard.contentStack.addArrangedSubview(logEmptyLabel)
        logCard.contentStack.addArrangedSubview(logStack)
        logCard.contentStack.addArrangedSubview(logOverflowLabel)
    }

    private func renderLog() {
        logHeader.text = "日志（帧 \(frameCount) / 共 \(ble.log.count) 条）"

        if logFilterControl.selectedSegmentIndex != logFilter.rawValue {
            logFilterControl.selectedSegmentIndex = logFilter.rawValue
        }
        copyLogButton.configuration?.title = copied ? "已复制" : "复制全部日志"

        let shown = filteredLog()
        logEmptyLabel.isHidden = !shown.isEmpty

        var sig = "\(logFilter.rawValue)|"
        for e in shown {
            sig += "\(e.id.uuidString)\(e.direction.rawValue)\(e.text)\(e.hex ?? "")"
                + "\(e.ascii ?? "")\(e.fields?.joined(separator: ",") ?? "")\u{1}"
        }
        rebuildIfNeeded(logStack, signature: sig) {
            shown.map { LMBLEDebugLogRow(entry: $0) }
        }

        let overflow = ble.log.count > shown.count
        logOverflowLabel.isHidden = !overflow
        if overflow {
            logOverflowLabel.text = "只显示最近 \(shown.count) 条（共 \(ble.log.count) 条）"
        }
    }

    private var frameCount: Int { ble.log.filter { $0.hasPayload }.count }

    /// 只渲染最近 300 条 —— 订阅通知后一秒能来几十帧，全渲染会卡死（原页同样的上限）。
    private func filteredLog() -> [LMBLELogEntry] {
        let base: [LMBLELogEntry]
        switch logFilter {
        case .all:  base = ble.log
        case .rx:   base = ble.log.filter { $0.direction == .rx }
        case .tx:   base = ble.log.filter { $0.direction == .tx }
        case .info: base = ble.log.filter { $0.direction == .info || $0.direction == .error }
        }
        return Array(base.suffix(300).reversed())
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        renderState()
        renderDevices()
        renderGATT()
        renderWrite()
        renderLog()
    }

    // MARK: - 动作

    @objc private func filterSwitchChanged() {
        filterByService = filterSwitch.isOn
    }

    @objc private func startScanTapped() {
        ble.startScan(filterByService: filterByService)
    }

    @objc private func stopScanTapped() {
        ble.stopScan()
    }

    @objc private func deviceConnectTapped(_ sender: UIControl) {
        guard sender.tag >= 0, sender.tag < deviceSnapshot.count else { return }
        ble.connect(deviceSnapshot[sender.tag])
    }

    @objc private func deviceDisconnectTapped(_ sender: UIControl) {
        // 同一时刻只连一个设备，断开不区分 sender
        _ = sender.tag
        ble.disconnect()
    }

    @objc private func deviceRediscoverTapped() {
        ble.rediscover()
    }

    @objc private func deviceReadRSSITapped() {
        ble.readRSSI()
    }

    @objc private func charToggleNotifyTapped(_ sender: UIControl) {
        guard let t = charTarget(sender.tag) else { return }
        ble.toggleNotify(serviceUUID: t.service, charUUID: t.char)
    }

    @objc private func charReadTapped(_ sender: UIControl) {
        guard let t = charTarget(sender.tag) else { return }
        ble.readValue(serviceUUID: t.service, charUUID: t.char)
    }

    @objc private func charSetWriteTargetTapped(_ sender: UIControl) {
        guard let t = charTarget(sender.tag) else { return }
        writeService = t.service
        writeChar = t.char
        renderWrite()
    }

    private func charTarget(_ tag: Int) -> (service: String, char: String)? {
        guard tag >= 0, tag < charTargets.count else { return nil }
        return charTargets[tag]
    }

    @objc private func writeResponseSwitchChanged() {
        ble.writeWithResponse = writeResponseSwitch.isOn
    }

    @objc private func hexChanged() {
        let v = hexField.text ?? ""
        hexInput = v
        inputError = v.isEmpty ? nil : LMBLEHex.validate(v)
        renderWrite()
    }

    @objc private func sendTapped() {
        guard let s = writeService, let c = writeChar,
              let d = LMBLEHex.data(from: hexInput) else { return }
        ble.write(serviceUUID: s, charUUID: c, data: d)
    }

    @objc private func presetTapped(_ sender: UIControl) {
        guard sender.tag >= 0, sender.tag < LMBLEPreset.all.count else { return }
        let p = LMBLEPreset.all[sender.tag]
        hexInput = p.hex
        inputError = LMBLEHex.validate(p.hex)
        hexField.text = hexInput
        renderWrite()
    }

    @objc private func logFilterChanged() {
        logFilter = LogFilter(rawValue: logFilterControl.selectedSegmentIndex) ?? .all
        renderLog()
    }

    @objc private func copyLogTapped() {
        UIPasteboard.general.string = ble.exportLog()
        copied = true
        renderLog()
    }

    @objc private func clearLogTapped() {
        ble.clearLog()
        copied = false
        renderLog()
    }

    // MARK: - 小工具

    /// ble 变化的刷新节流：同一轮主队列内的多次触发合并成一次。
    /// （跟基类的 `scheduleRender` 一个道理 —— 一次扫描会连着写十几个 `@Published`。）
    private func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        // ★ 用 `Task { @MainActor in }` 而不是 `DispatchQueue.main.async { }`：
        //   后者收到的是 `@Sendable` 闭包，不继承 @MainActor 隔离，可能直接编译失败。
        Task { @MainActor in
            self.renderPending = false
            self.render()
        }
    }

    /// 行数会变的那几块（设备 / GATT / 日志）专用：指纹没变就整块跳过。
    ///
    /// ★ 这是 `render()` 幂等约定的例外，可以这么做的原因是这几块里**没有用户输入控件**；
    ///   带输入框的「发送」区一律用 `isHidden` 折叠，绝不重建。
    private func rebuildIfNeeded(_ container: UIStackView,
                                 signature: String,
                                 build: () -> [UIView]) {
        let key = ObjectIdentifier(container)
        guard rebuildCache[key] != signature else { return }
        rebuildCache[key] = signature
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        build().forEach { container.addArrangedSubview($0) }
    }

    /// 1 物理像素分隔线。用 `traitCollection.displayScale` 而不是已弃用的 `UIScreen.main`。
    private func makeSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        line.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true
        return line
    }
}

// MARK: - 折叠区（对应 SwiftUI 的 DisclosureGroup）

/// 「标题 + 可折叠内容」。展开态是纯 UI 状态，留在视图里即可 —— 它不影响任何车端行为。
///
/// ★ 为什么用「透明按钮盖在标题上」而不是让本视图自己当 `UIControl`：
///   内容区里有别的按钮，把整块做成 UIControl 会让标题区之外的点击也触发折叠；
///   而把标题包进一个 StackView 后，点击会被 StackView 自己吃掉、传不到控件。
///   盖一个只覆盖标题的透明按钮最稳。
private final class LMBLEDisclosure: UIView {

    let contentStack = LMUIKit.vStack(spacing: 8)

    private let titleLabel = UILabel()
    private let chevron = UIImageView()
    private var expanded = false

    init(title: String) {
        super.init(frame: .zero)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0

        chevron.image = UIImage(systemName: "chevron.right")
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let header = LMUIKit.hStack(spacing: 6, alignment: .top)
        header.addArrangedSubview(chevron)
        header.addArrangedSubview(titleLabel)

        contentStack.isHidden = true

        let outer = LMUIKit.vStack(spacing: 8)
        outer.addArrangedSubview(header)
        outer.addArrangedSubview(contentStack)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
        ])

        let tap = UIButton(type: .custom)
        tap.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tap)
        NSLayoutConstraint.activate([
            tap.topAnchor.constraint(equalTo: header.topAnchor),
            tap.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            tap.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            tap.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        tap.addTarget(self, action: #selector(toggle), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLEDisclosure 只能代码创建")
    }

    @objc private func toggle() {
        expanded.toggle()
        contentStack.isHidden = !expanded
        chevron.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
    }
}

// MARK: - 一行设备

/// 名称 + 广播摘要 + 广播内容折叠 + 连接操作。
/// 对应原页 `deviceRow(_:)`。
private final class LMBLEDebugDeviceRow: UIView {

    // 由 VC 取走绑 target/action；行只负责显示与按连接态切换显隐。
    let connectButton = UIButton()
    let disconnectButton = UIButton()
    let rediscoverButton = UIButton()
    let readRSSIButton = UIButton()

    init(device d: LMBLEDevice, isConnected: Bool) {
        super.init(frame: .zero)

        let nameRow = LMUIKit.hStack(spacing: 6)
        if d.isLikelyVehicle {
            let car = UIImageView(image: UIImage(systemName: "car.fill"))
            car.tintColor = .lmAccent
            car.contentMode = .scaleAspectFit
            car.preferredSymbolConfiguration =
                UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            car.setContentHuggingPriority(.required, for: .horizontal)
            nameRow.addArrangedSubview(car)
        }
        nameRow.addArrangedSubview(LMUIKit.label(d.name, size: 13, weight: .semibold, lines: 1))
        if d.isLikelyVehicle {
            nameRow.addArrangedSubview(
                LMStatusPillView(text: "疑似车辆", icon: "car.fill", tint: .lmAccent))
        }
        nameRow.addArrangedSubview(LMUIKit.spacer())

        let rssi = LMUIKit.label("\(d.rssi) dBm", size: 11,
                                 color: d.rssi > -70 ? .lmGood : .secondaryLabel, lines: 1)
        rssi.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rssi.setContentHuggingPriority(.required, for: .horizontal)
        nameRow.addArrangedSubview(rssi)

        let meta = LMUIKit.label(
            "\(d.shortId) · \(d.stateText)\(d.isConnectable ? "" : " · 不可连接")",
            size: 11, color: .secondaryLabel, lines: 1)
        meta.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let stack = LMUIKit.vStack(spacing: 6)
        stack.addArrangedSubview(nameRow)
        stack.addArrangedSubview(meta)

        // 广播内容（可折叠）。★ 用 `keys.sorted()` 回查字典，而不是 ForEach(元组) ——
        //   元组的 key path 在 Swift 里不能用，直接编译不过（原页注释同样的坑）。
        if !d.advertisement.isEmpty {
            let disc = LMBLEDisclosure(title: "广播内容（\(d.advertisement.count) 项）")
            for k in d.advertisement.keys.sorted() {
                let keyLabel = LMUIKit.label(k, size: 11, color: .secondaryLabel, lines: 1)
                keyLabel.setContentHuggingPriority(.required, for: .horizontal)
                keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                keyLabel.translatesAutoresizingMaskIntoConstraints = false
                keyLabel.widthAnchor.constraint(equalToConstant: 68).isActive = true

                let valueLabel = LMUIKit.label(d.advertisement[k] ?? "", size: 11, lines: 4)
                valueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                valueLabel.lineBreakMode = .byTruncatingMiddle

                let row = LMUIKit.hStack(spacing: 8, alignment: .top)
                row.addArrangedSubview(keyLabel)
                row.addArrangedSubview(valueLabel)
                disc.contentStack.addArrangedSubview(row)
            }
            stack.addArrangedSubview(disc)
        }

        let actions = LMUIKit.hStack(spacing: 8)
        if isConnected {
            styleAction(disconnectButton, title: "断开", tint: .lmBad)
            styleAction(rediscoverButton, title: "重发现服务", tint: .lmAccent)
            styleAction(readRSSIButton, title: "读 RSSI", tint: .lmAccent)
            actions.addArrangedSubview(disconnectButton)
            actions.addArrangedSubview(rediscoverButton)
            actions.addArrangedSubview(readRSSIButton)
        } else {
            styleAction(connectButton, title: "连接", tint: .lmAccent)
            connectButton.isEnabled = d.isConnectable
            actions.addArrangedSubview(connectButton)
        }
        actions.addArrangedSubview(LMUIKit.spacer())
        stack.addArrangedSubview(actions)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLEDebugDeviceRow 只能代码创建")
    }

    /// 小号灰底按钮，对应原页 `.font(.caption)` 的 borderless Button。
    private func styleAction(_ button: UIButton, title: String, tint: UIColor) {
        var cfg = UIButton.Configuration.gray()
        cfg.title = title
        cfg.baseForegroundColor = tint
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        button.configuration = cfg
    }
}

// MARK: - 一行特征

/// 特征 UUID + 属性胶囊 + 最新值 + 订阅 / 读取 / 设为写入目标。
/// 对应原页 `charRow(service:char:)`。
private final class LMBLEDebugCharRow: UIView {

    let toggleNotifyButton = UIButton()
    let readButton = UIButton()
    let setWriteTargetButton = UIButton()

    init(char c: LMBLECharacteristic) {
        super.init(frame: .zero)

        let uuidLabel = LMUIKit.label(c.uuid, size: 11, lines: 2)
        uuidLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        uuidLabel.lineBreakMode = .byTruncatingMiddle

        let propsRow = LMUIKit.hStack(spacing: 4)
        for p in c.props {
            propsRow.addArrangedSubview(
                LMStatusPillView(text: p, icon: "circle.fill", tint: .lmIndigo))
        }
        propsRow.addArrangedSubview(LMUIKit.spacer())

        let stack = LMUIKit.vStack(spacing: 5)
        stack.addArrangedSubview(uuidLabel)
        stack.addArrangedSubview(propsRow)

        if let v = c.lastValue {
            let last = LMUIKit.label("最新值：\(v)", size: 11, color: .secondaryLabel, lines: 3)
            last.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            stack.addArrangedSubview(last)
        }

        let actions = LMUIKit.hStack(spacing: 10)
        if c.canNotify {
            styleSmall(toggleNotifyButton, title: c.isNotifying ? "取消订阅" : "订阅")
            actions.addArrangedSubview(toggleNotifyButton)
        }
        styleSmall(readButton, title: "读一次")
        actions.addArrangedSubview(readButton)
        if c.canWrite || c.canWriteNoResponse {
            styleSmall(setWriteTargetButton, title: "设为写入目标")
            actions.addArrangedSubview(setWriteTargetButton)
        }
        actions.addArrangedSubview(LMUIKit.spacer())
        stack.addArrangedSubview(actions)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLEDebugCharRow 只能代码创建")
    }

    private func styleSmall(_ button: UIButton, title: String, tint: UIColor = .lmAccent) {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.baseForegroundColor = tint
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        button.configuration = cfg
    }
}

// MARK: - 一行服务（含特征折叠）

/// 服务 UUID + 主次 / 特征数 + 可折叠的特征列表。对应原页 `gattSection` 里的 `DisclosureGroup`。
/// 特征行由 VC 建好传进来（因为按钮的 target/action 要绑在 VC 上）。
private final class LMBLEDebugServiceRow: UIView {

    let contentStack = LMUIKit.vStack(spacing: 10)

    private let chevron = UIImageView()
    private var expanded = false

    init(service s: LMBLEService, charRows: [UIView]) {
        super.init(frame: .zero)

        let uuidLabel = LMUIKit.label(s.uuid, size: 12, weight: .semibold, lines: 2)
        uuidLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        uuidLabel.lineBreakMode = .byTruncatingMiddle

        let badgeRow = LMUIKit.hStack(spacing: 6)
        if s.uuid.uppercased().hasPrefix("FFED") {
            badgeRow.addArrangedSubview(
                LMStatusPillView(text: "官方字面量", icon: "checkmark.seal.fill", tint: .lmAccent))
        }
        badgeRow.addArrangedSubview(
            LMUIKit.label(s.isPrimary ? "主服务" : "次要服务", size: 11, color: .secondaryLabel, lines: 1))
        badgeRow.addArrangedSubview(
            LMUIKit.label("\(s.characteristics.count) 个特征", size: 11, color: .secondaryLabel, lines: 1))
        badgeRow.addArrangedSubview(LMUIKit.spacer())

        let titleBox = LMUIKit.vStack(spacing: 2)
        titleBox.addArrangedSubview(uuidLabel)
        titleBox.addArrangedSubview(badgeRow)

        chevron.image = UIImage(systemName: "chevron.right")
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let header = LMUIKit.hStack(spacing: 6, alignment: .top)
        header.addArrangedSubview(chevron)
        header.addArrangedSubview(titleBox)

        if charRows.isEmpty {
            contentStack.addArrangedSubview(
                LMUIKit.label("（这个服务下没有特征）", size: 11, color: .secondaryLabel))
        } else {
            charRows.forEach { contentStack.addArrangedSubview($0) }
        }
        contentStack.isHidden = true

        let outer = LMUIKit.vStack(spacing: 8)
        outer.addArrangedSubview(header)
        outer.addArrangedSubview(contentStack)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)

        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
        ])

        // 透明按钮只盖标题区，展开后里面的特征按钮照常可点
        let tap = UIButton(type: .custom)
        tap.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tap)
        NSLayoutConstraint.activate([
            tap.topAnchor.constraint(equalTo: header.topAnchor),
            tap.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            tap.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            tap.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        tap.addTarget(self, action: #selector(toggle), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLEDebugServiceRow 只能代码创建")
    }

    @objc private func toggle() {
        expanded.toggle()
        contentStack.isHidden = !expanded
        chevron.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
    }
}

// MARK: - 一行日志

/// 方向图标 + 时间 + 摘要，下面按需跟 hex / 文本 / 分号切分三行。
/// 对应原页 `logRow(_:)`。日志很长，全部用等宽字体并允许多行换行。
private final class LMBLEDebugLogRow: UIView {

    init(entry e: LMBLELogEntry) {
        super.init(frame: .zero)

        let icon = UIImageView(image: UIImage(systemName: e.direction.symbol))
        icon.tintColor = LMBLEDebugLogRow.color(e.direction)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let timeLabel = LMUIKit.label(LMBLEDebugLogRow.time(e.at), size: 11,
                                      color: .secondaryLabel, lines: 1)
        timeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let textLabel = LMUIKit.label(e.text, size: 11, weight: .semibold, lines: 3)
        textLabel.lineBreakMode = .byTruncatingTail

        let head = LMUIKit.hStack(spacing: 5, alignment: .top)
        head.addArrangedSubview(icon)
        head.addArrangedSubview(timeLabel)
        head.addArrangedSubview(textLabel)

        let stack = LMUIKit.vStack(spacing: 4)
        stack.addArrangedSubview(head)
        if let h = e.hex {
            stack.addArrangedSubview(mono("hex  \(h)", color: .label))
        }
        if let a = e.ascii, a != e.hex {
            stack.addArrangedSubview(mono("text \(a)", color: .lmTeal))
        }
        if let f = e.fields {
            // ★ 先把分号段拼成一个字符串再插值，避免多层嵌套字符串字面量（原页/central 同样的坑）
            let segs = f.enumerated()
                .map { "[\($0.offset)]\($0.element)" }
                .joined(separator: "  ")
            stack.addArrangedSubview(mono("segs " + segs, color: .lmPurple))
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLEDebugLogRow 只能代码创建")
    }

    private func mono(_ text: String, color: UIColor) -> UILabel {
        let l = LMUIKit.label(text, size: 11, color: color, lines: 3)
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.lineBreakMode = .byTruncatingMiddle
        return l
    }

    private static func color(_ d: LMBLELogEntry.Direction) -> UIColor {
        switch d {
        case .info:  return .secondaryLabel
        case .tx:    return .lmAccent
        case .rx:    return .lmGood
        case .error: return .lmBad
        }
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}

// MARK: - 一行快捷载荷

/// 标题 + hex + 说明，整行可点。对应原页「快捷载荷」里的 `Button { hexInput = p.hex }`。
/// 用 `tag` 反查 `LMBLEPreset.all`，避免把闭包存进视图。
private final class LMBLEDebugPresetRow: UIControl {

    init(preset p: LMBLEPreset) {
        super.init(frame: .zero)

        let label = LMUIKit.label(p.label, size: 11, weight: .semibold)
        let hex = LMUIKit.label(p.hex, size: 11, color: .lmAccent)
        hex.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let note = LMUIKit.label(p.note, size: 11, color: .secondaryLabel)

        let stack = LMUIKit.vStack(spacing: 2)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(hex)
        stack.addArrangedSubview(note)
        stack.isUserInteractionEnabled = false   // 让点击落到本控件
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMBLEDebugPresetRow 只能代码创建")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }
}
