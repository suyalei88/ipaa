//
//  LMDiagnosticsViewController.swift
//  LeapmotorLite
//
//  车控体检（UIKit 版）—— 对应原 `Views/DiagnosticsView.swift`（833 行 SwiftUI List）。
//
//  这一页的目的不是「好看」，是「把真发出去的东西全摊开」：
//  服务端报「操作密码错误 / 累计出错 3 次」时，只用眼睛看 UI 是没法定位的 ——
//  到底是①密码输错、②key/iv 派生错、③base64 在 URL 里被 '+' 吃掉了。
//  所以 token 头尾、派生 key/iv、最终 oppwd、本地回解、上次服务端响应全列出来，
//  还能一键复制，出问题直接把这段发出来就能定案。
//
//  ★ 迁移约定（跟 `LMLoginViewController` / `LMSettingsViewController` 一致）：
//    · 继承 `LMBaseViewController`，只覆盖 `buildUI()` / `render()` 两个钩子
//    · 页内状态（探测结果 / 手输 cmdid / 是否已复制 / 倒计时用的 now）**不进 `LMClient`**
//    · `render()` 幂等：只改已有控件的属性 + 用 `isHidden` 折叠整块，
//      绝不 `addSubview`。唯一的例外是「蓝牙钥匙探测记录」——它的行数会变，
//      照抄 `LMSettingsViewController.rebuildIfNeeded(_:signature:)` 的指纹去重。
//
//  ★ 2026-10-09（Phase 3~6 全部迁完）：`SignalExplorerView` 已有 UIKit 版
//    `LMSignalExplorerViewController`，直接 push —— 过渡期的
//    `import SwiftUI` 与 `pushSwiftUIPage` 都已删除。
//
import UIKit

final class LMDiagnosticsViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，跟车端无关）

    private var probeResult = ""
    private var probeBusy = false

    private var rawCmdId = "130"
    private var rawState = #"{"value":"true"}"#
    private var rawBusy = false
    private var rawResult = ""

    private var bleBusy = false
    /// 待二次确认的「会改服务端状态」的蓝牙钥匙操作（对应原页的 confirmationDialog）
    private var bleDanger: BLEAction?

    private var copied = false

    /// 锁定期倒计时用的「当前时刻」。原页靠 `.lmClock` 每 0.5 秒推一次 ——
    /// ★ 没有它，`下发` 按钮的 disabled 条件（依赖 `isControlLocked(at: now)`）
    ///   会冻在进入页面那一刻：锁定期到期后按钮永远不重新启用。
    private var now = Date()
    private var lockTimer: Timer?

    /// 行数会变的内容（蓝牙钥匙探测记录）的「内容指纹」缓存。
    /// `render()` 会被网络回调反复调用，指纹没变就整块跳过，避免打断用户滚动。
    private var rebuildCache: [ObjectIdentifier: String] = [:]

    // MARK: - 蓝牙钥匙：会改服务端状态的三个操作
    //
    // ★ 为什么单独列出来：`/v3/api/ccc/*` 和 `bluetoothkey/uploadAutocalibrate*` 都是
    //   **写**操作（建配对会话 / 删钥匙 / 上报数据），路径还只是从二进制字符串表
    //   挖出来的、没验证过。手滑点一下可能把用户已经绑好的蓝牙钥匙删掉 ——
    //   所以它们跟「只读探测」在 UI 上必须是两种东西，不能混在一排按钮里。
    private enum BLEAction: Int, CaseIterable {
        case pairing
        case delKey
        case calibrate

        var title: String {
            switch self {
            case .pairing:   return "取配对码 ccc/pairingcode"
            case .delKey:    return "删除钥匙 ccc/delKey"
            case .calibrate: return "上报标定参数 bluetoothkey/uploadAutonomyCalibrateParams"
            }
        }

        /// 裸路径（前缀由 `probeBleOne` 的调用方拼）
        var path: String {
            switch self {
            case .pairing:   return LMEndpoints.Path.cccPairingCode
            case .delKey:    return LMEndpoints.Path.cccDelKey
            case .calibrate: return LMEndpoints.Path.bleKeyCalib
            }
        }

        var method: String {
            switch self {
            case .pairing:   return "GET"
            case .delKey:    return "GET"
            case .calibrate: return "POST"
            }
        }

        var warning: String {
            switch self {
            case .pairing:
                return "会在服务端建一个「待配对」会话。如果你正在用官方 App 配对，可能会互相干扰。"
            case .delKey:
                return "⚠️ 会删掉已绑定的蓝牙钥匙。删了之后官方 App 的蓝牙钥匙也会失效，需要重新配对。"
            case .calibrate:
                return "会上报一组标定参数，可能覆盖服务端已有的感应区数据，影响官方 App 的「无感」行为。"
            }
        }
    }

    /// 信号对照表的一行。★ 不能用元组数组：Swift 的 key path 不能指向元组成员。
    private struct SignalRef {
        let id: String
        let name: String
    }

    // MARK: - 控件：操作密码体检

    private let passwordHeader = LMSectionHeaderLabel("操作密码体检")
    private let passwordCard = LMCardView(spacing: 8)
    private let passwordEmptyLabel = LMUIKit.footnote("还没设置操作密码。请到「设置 → 操作密码」填写。")
    private let pwdLenRow = LMDiagKVRow(key: "密码位数")
    private let derivedKeyRow = LMDiagKVRow(key: "派生 key")
    private let derivedIVRow = LMDiagKVRow(key: "派生 iv")
    private let oppwdRow = LMDiagKVRow(key: "oppwd")
    private let roundTripRow = LMDiagKVRow(key: "本地回解")
    private let roundTripNote = LMDiagIconNote(
        icon: "checkmark.circle.fill", text: "", color: .lmGood, size: 11)
    private let passwordFooter = LMUIKit.footnote("""
    派生规则（逆向自官方 iOS 1.22.68）：
      key = md5(accessToken[0..32])[8..24]
      iv  = md5(accessToken[32..64])[8..24]
      oppwd = base64(AES-128-CBC-PKCS7(密码, key, iv))

    只要「本地回解」等于你输入的密码，说明 App 侧没问题；
    这时服务端还报密码错，就是密码本身和账号不匹配。
    """)

    // MARK: - 控件：上次车控请求

    private let lastHeader = LMSectionHeaderLabel("上次车控请求")
    private let lastCard = LMCardView(spacing: 8)
    private let lastEmptyLabel = LMUIKit.footnote(
        "本次启动还没发过车控指令。去「车控」点一个按钮，这里就会有记录。")
    private let lastTimeRow = LMDiagKVRow(key: "时间")
    private let lastActionRow = LMDiagKVRow(key: "动作")
    private let lastPwdLenRow = LMDiagKVRow(key: "密码位数")
    private let lastKeyRow = LMDiagKVRow(key: "key")
    private let lastIVRow = LMDiagKVRow(key: "iv")
    private let lastOppwdRow = LMDiagKVRow(key: "oppwd")
    private let lastRoundTripRow = LMDiagKVRow(key: "本地回解")
    private let lastTokenHeadRow = LMDiagKVRow(key: "token 头 32")
    private let lastTokenTailRow = LMDiagKVRow(key: "token 尾 32")
    private let lastOutcomeRow = LMDiagKVRow(key: "服务端", alignRight: true)

    // MARK: - 控件：会话

    private let sessionHeader = LMSectionHeaderLabel("会话")
    private let sessionCard = LMCardView(spacing: 8)
    private let sessionEmptyLabel = LMUIKit.footnote("未登录")
    private let sessAccountIdRow = LMDiagKVRow(key: "accountId")
    private let sessUserIdRow = LMDiagKVRow(key: "userId")
    private let sessTokenHeadRow = LMDiagKVRow(key: "token 头 32")
    private let sessTokenTailRow = LMDiagKVRow(key: "token 尾 32")
    private let sessSignKeyRow = LMDiagKVRow(key: "signKey")
    private let sessEncryptKeyRow = LMDiagKVRow(key: "encryptKey")
    private let sessVinRow = LMDiagKVRow(key: "车架号")
    private let sessCarTypeRow = LMDiagKVRow(key: "cartype")

    // MARK: - 控件：信号对照表

    private let signalHeader = LMSectionHeaderLabel("已确认的信号映射")
    private let signalCard = LMCardView(spacing: 8)
    private let signalStack = LMUIKit.vStack(spacing: 8)
    private let openSignalRow = LMDiagNavRow(
        icon: "magnifyingglass.circle", title: "打开信号浏览器")
    private let signalFooter = LMUIKit.footnote(
        "右侧是该信号此刻的实时值。带 🟡 的是观察级、❓ 是还没定下来的，"
        + "都在信号浏览器里能看到完整说明。")
    /// 已确认信号的 id 顺序 + 每行的值标签（行数固定，`render()` 只改文字、不重建）。
    private var signalIDs: [String] = []
    private var signalRows: [String: LMDiagSignalRow] = [:]

    // MARK: - 控件：官方接口探测

    private let probeHeader = LMSectionHeaderLabel("官方接口探测（结构未知，试出来的）")
    private let probeCard = LMCardView(spacing: 8)
    private let probeBusyRow = LMDiagBusyRow(text: "探测中…")
    private let probeResultLabel = UILabel()
    private let copyProbeButton = UIButton()
    private let probeFooter = LMUIKit.footnote("""
    分两类：

    · 停车位置 / 底盘图 / 逆地理编码 —— 路径是从 IPA 字符串表挖的，
      参数靠推测，**没有抓包样本**。探测结果有意义的话（返回了地址或坐标），
      就把这段发出来，可以接成定位页的地址来源，比 Apple 的 CLGeocoder 更贴官方。

    · 预约查询 / 健康充电推送 / 手机 IP 归属地 —— 这三个**有真实抓包样本**
      （2026-10-08 审计时发现的），路径和参数都是照实写的，所以基本一定成功。
      其中「手机 IP 归属地」返回的是服务端认为**手机**在哪，和车端坐标是
      两个独立来源 —— 车端坐标不对劲时，先用它把责任范围缩一缩。
    """)

    // MARK: - 控件：蓝牙钥匙接口探测

    private let bleHeader = LMSectionHeaderLabel("蓝牙钥匙接口探测（路径从二进制挖的，无样本）")
    private let bleCard = LMCardView(spacing: 8)
    private let bleSyncButton = UIButton()
    private let bleAnchorButton = UIButton()
    private let blePollButton = UIButton()
    private var bleDangerButtons: [UIButton] = []
    private let bleBusyRow = LMDiagBusyRow(text: "探测中…")
    private let bleProbeStack = LMUIKit.vStack(spacing: 10)
    private let copyBLEButton = UIButton()
    private let clearBLEButton = UIButton()
    private let bleFooter = LMUIKit.footnote("""
    这 7 个路径来自官方 IPA 主二进制的字符串表，**没有抓包样本** ——
    前缀（/carownerservice？/app/app-control-service？）、参数、HTTP 方法全是推的。
    所以这里把「试了什么、回了什么」原样留下，失败本身也是有效信息。

    ★ 最值得看的是 syncBluetoothKeys：如果它把 passwordCard（钥匙材料）吐回来，
    整套 BLE 协议就能自己实现，不用再动态 hook 官方 App。
    """)

    // MARK: - 控件：未验证 cmdid

    private let rawHeader = LMSectionHeaderLabel("未验证 cmdid 探测")
    private let rawCard = LMCardView(spacing: 8)
    private let rawCmdField = UITextField()
    private let rawStateField = UITextField()
    private let unverifiedStack = LMUIKit.vStack(spacing: 8)
    private let sendRawButton = UIButton()
    private let lockNote = LMDiagIconNote(icon: "lock.fill", text: "", color: .lmBad, size: 11)
    private let rawBusyRow = LMDiagBusyRow(text: "下发中…")
    private let rawResultLabel = UILabel()
    private let rawFooter = LMUIKit.footnote("""
    上面这些是**有依据但没样本**的指令，所以它们**没有**出现在车控页：

    · cmdid 130 {"value":"true"|"false"} —— 抓包里出现过，但没有任何证据
      说明它开关的是什么。
    · cmdid 230 {"value":"1"} —— 车窗开度 1。抓包里 230 只出现过
      {"value":"0"}（全关）和 {"value":"2"}（一个开度），「1」是否存在未知。

    ★ 2026-10-08 修正：这里原来挂着两条 ——
      「cmdid 230 {"value":"3"} 风量 3 档」和
      「cmdid 230 {"value":"2","temperature":"24"} 温度」。
      **两条都挂错了 cmdid**：230 是车窗，发过去只会动车窗，
      根本调不到风量和温度。已删除。
      空调风量 / 温度的正确入口是车控页的「空调风量 / 温度」卡（cmdid 170）。

    ★ 顺带记一笔：抓包里 cmdid 161 只以「查询」形式出现过
      （getappointment，见上面「官方接口探测」），从来没有以「下发」出现过，
      所以它不在这个列表里 —— 我们不会发一个连方法都没见过的指令。

    发之前请确保：车停在安全位置、你能直接看到车、周围没人。
    另：这一页的请求同样算「操作密码」的尝试次数，密码错 3 次会被服务端锁 5 分钟。
    """)

    // MARK: - 控件：复制

    private let copyCard = LMCardView()
    private let copyButton = UIButton()
    private let copyFooter = LMUIKit.footnote(
        "复制的内容包含 token 与 oppwd 密文。发给别人前请确认对方可信；"
        + "排查完建议「设置 → 退出登录」再重新登录，token 会换新的。")

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "车控体检"
        navigationItem.largeTitleDisplayMode = .always

        let (_, stack) = makeScrollStack(spacing: 18, inset: 16)

        buildPasswordSection()
        stack.addArrangedSubview(passwordHeader)
        stack.addArrangedSubview(passwordCard)
        stack.addArrangedSubview(passwordFooter)

        buildLastControlSection()
        stack.addArrangedSubview(lastHeader)
        stack.addArrangedSubview(lastCard)

        buildSessionSection()
        stack.addArrangedSubview(sessionHeader)
        stack.addArrangedSubview(sessionCard)

        buildSignalSection()
        stack.addArrangedSubview(signalHeader)
        stack.addArrangedSubview(signalCard)
        stack.addArrangedSubview(signalFooter)

        buildProbeSection()
        stack.addArrangedSubview(probeHeader)
        stack.addArrangedSubview(probeCard)
        stack.addArrangedSubview(probeFooter)

        buildBLESection()
        stack.addArrangedSubview(bleHeader)
        stack.addArrangedSubview(bleCard)
        stack.addArrangedSubview(bleFooter)

        buildRawSection()
        stack.addArrangedSubview(rawHeader)
        stack.addArrangedSubview(rawCard)
        stack.addArrangedSubview(rawFooter)

        buildCopySection()
        stack.addArrangedSubview(copyCard)
        stack.addArrangedSubview(copyFooter)
    }

    // MARK: - 各区块搭建

    private func buildPasswordSection() {
        passwordCard.contentStack.addArrangedSubview(passwordEmptyLabel)
        [pwdLenRow, derivedKeyRow, derivedIVRow, oppwdRow, roundTripRow, roundTripNote]
            .forEach { passwordCard.contentStack.addArrangedSubview($0) }
    }

    private func buildLastControlSection() {
        lastCard.contentStack.addArrangedSubview(lastEmptyLabel)
        [lastTimeRow, lastActionRow, lastPwdLenRow, lastKeyRow, lastIVRow,
         lastOppwdRow, lastRoundTripRow, lastTokenHeadRow, lastTokenTailRow, lastOutcomeRow]
            .forEach { lastCard.contentStack.addArrangedSubview($0) }
    }

    private func buildSessionSection() {
        sessionCard.contentStack.addArrangedSubview(sessionEmptyLabel)
        [sessAccountIdRow, sessUserIdRow, sessTokenHeadRow, sessTokenTailRow,
         sessSignKeyRow, sessEncryptKeyRow, sessVinRow, sessCarTypeRow]
            .forEach { sessionCard.contentStack.addArrangedSubview($0) }
    }

    private func buildSignalSection() {
        signalCard.contentStack.addArrangedSubview(signalStack)

        // ★ 已确认信号的行数是**固定**的（来自 LMSignalCatalog，不是运行时数据），
        //   所以这里建一次、把每行的值标签存下来，render() 只改文字、不重建。
        signalIDs = signalTable.map { $0.id }
        for ref in signalTable {
            let row = LMDiagSignalRow(id: ref.id, name: ref.name)
            signalRows[ref.id] = row
            signalStack.addArrangedSubview(row)
        }

        openSignalRow.addTarget(self, action: #selector(openSignalExplorerTapped),
                                for: .touchUpInside)
        signalCard.contentStack.addArrangedSubview(makeSeparator())
        signalCard.contentStack.addArrangedSubview(openSignalRow)
    }

    private func buildProbeSection() {
        let primary: [(String, String, Selector)] = [
            ("探测 停车位置接口（GET parking/query）", "parkingsign.circle",
             #selector(probeParkingTapped)),
            ("探测 停车位置接口（POST + vin）", "parkingsign.circle",
             #selector(probeParkingPostTapped)),
            ("探测 底盘图接口（GET chassis/query）", "car.circle",
             #selector(probeChassisTapped)),
            ("探测 官方逆地理编码（3 种参数各试一次）", "map.circle",
             #selector(probeRegeoTapped)),
        ]
        for (title, icon, action) in primary {
            let b = makeRowButton(title, icon: icon)
            b.addTarget(self, action: action, for: .touchUpInside)
            probeCard.contentStack.addArrangedSubview(b)
        }

        probeCard.contentStack.addArrangedSubview(makeSeparator())

        // ★ 2026-10-08 加：抓包审计里发现、但之前没接的三个**只读**接口。
        //   都是 GET / POST 查询，不会动车，所以做成探测没有风险。
        let audited: [(String, String, Selector)] = [
            ("探测 远程预约查询（getappointment, cmdid 161）", "calendar.badge.clock",
             #selector(probeAppointmentTapped)),
            ("探测 健康充电推送开关（queryPushState）", "bolt.heart",
             #selector(probeHealthyChargingTapped)),
            ("探测 手机侧 IP 归属地（apptec）", "iphone.gen3",
             #selector(probePhoneIPTapped)),
        ]
        for (title, icon, action) in audited {
            let b = makeRowButton(title, icon: icon)
            b.addTarget(self, action: action, for: .touchUpInside)
            probeCard.contentStack.addArrangedSubview(b)
        }

        probeCard.contentStack.addArrangedSubview(probeBusyRow)

        probeResultLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        probeResultLabel.numberOfLines = 40
        probeResultLabel.textColor = .label
        enableCopy(probeResultLabel)
        probeCard.contentStack.addArrangedSubview(probeResultLabel)

        styleRowButton(copyProbeButton, title: "复制探测结果", icon: "doc.on.doc")
        copyProbeButton.addTarget(self, action: #selector(copyProbeTapped), for: .touchUpInside)
        probeCard.contentStack.addArrangedSubview(copyProbeButton)
    }

    private func buildBLESection() {
        styleRowButton(bleSyncButton, title: "同步钥匙（只读，3 个前缀各试一次）",
                       icon: "key.horizontal")
        bleSyncButton.addTarget(self, action: #selector(bleSyncTapped), for: .touchUpInside)
        bleCard.contentStack.addArrangedSubview(bleSyncButton)

        styleRowButton(bleAnchorButton, title: "感应区锚点参数（只读）", icon: "scope")
        bleAnchorButton.addTarget(self, action: #selector(bleAnchorTapped), for: .touchUpInside)
        bleCard.contentStack.addArrangedSubview(bleAnchorButton)

        styleRowButton(blePollButton, title: "轮询配对结果 ccc/poll",
                       icon: "arrow.triangle.2.circlepath")
        blePollButton.addTarget(self, action: #selector(blePollTapped), for: .touchUpInside)
        bleCard.contentStack.addArrangedSubview(blePollButton)

        // 会改服务端状态的三个：红字 + 二次确认
        bleDangerButtons = BLEAction.allCases.map { action in
            let b = makeRowButton(action.title, icon: "exclamationmark.triangle.fill",
                                  tint: .lmBad)
            b.tag = action.rawValue
            b.addTarget(self, action: #selector(bleDangerTapped(_:)), for: .touchUpInside)
            bleCard.contentStack.addArrangedSubview(b)
            return b
        }

        bleCard.contentStack.addArrangedSubview(bleBusyRow)
        bleCard.contentStack.addArrangedSubview(bleProbeStack)

        styleRowButton(copyBLEButton, title: "复制全部探测结果", icon: "doc.on.doc")
        copyBLEButton.addTarget(self, action: #selector(copyBLETapped), for: .touchUpInside)
        bleCard.contentStack.addArrangedSubview(copyBLEButton)

        styleRowButton(clearBLEButton, title: "清空探测记录", icon: "trash", tint: .lmBad)
        clearBLEButton.addTarget(self, action: #selector(clearBLETapped), for: .touchUpInside)
        bleCard.contentStack.addArrangedSubview(clearBLEButton)
    }

    private func buildRawSection() {
        // cmdid 行
        rawCmdField.placeholder = "130"
        rawCmdField.keyboardType = .numberPad
        rawCmdField.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        rawCmdField.textAlignment = .right
        rawCmdField.text = rawCmdId
        rawCmdField.addTarget(self, action: #selector(rawCmdChanged), for: .editingChanged)
        rawCmdField.setContentHuggingPriority(.required, for: .horizontal)
        let cmdRow = LMUIKit.hStack(spacing: 8)
        cmdRow.addArrangedSubview(LMUIKit.label("cmdid", size: 11, color: .secondaryLabel))
        cmdRow.addArrangedSubview(LMUIKit.spacer())
        cmdRow.addArrangedSubview(rawCmdField)
        rawCmdField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        rawCard.contentStack.addArrangedSubview(cmdRow)

        // state 行
        rawStateField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        rawStateField.autocorrectionType = .no
        rawStateField.autocapitalizationType = .none
        rawStateField.text = rawState
        rawStateField.addTarget(self, action: #selector(rawStateChanged), for: .editingChanged)
        let stateRow = LMUIKit.hStack(spacing: 8, alignment: .top)
        stateRow.addArrangedSubview(LMUIKit.label("state", size: 11, color: .secondaryLabel))
        stateRow.addArrangedSubview(rawStateField)
        rawCard.contentStack.addArrangedSubview(stateRow)

        // 已知但语义未确认的 cmdid，点一下把值填进上面两个框
        for item in LMEndpoints.unverifiedCmds {
            let row = LMDiagUnverifiedRow(cmdid: item.cmdid, state: item.state)
            row.addTarget(self, action: #selector(unverifiedRowTapped(_:)), for: .touchUpInside)
            unverifiedStack.addArrangedSubview(row)
        }
        rawCard.contentStack.addArrangedSubview(unverifiedStack)

        styleRowButton(sendRawButton, title: "下发这条指令（会真的发到车上）",
                       icon: "exclamationmark.triangle.fill", tint: .lmBad)
        sendRawButton.addTarget(self, action: #selector(sendRawTapped), for: .touchUpInside)
        rawCard.contentStack.addArrangedSubview(sendRawButton)

        rawCard.contentStack.addArrangedSubview(lockNote)
        rawCard.contentStack.addArrangedSubview(rawBusyRow)

        rawResultLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        rawResultLabel.textColor = .lmAccent
        rawResultLabel.numberOfLines = 0
        enableCopy(rawResultLabel)
        rawCard.contentStack.addArrangedSubview(rawResultLabel)
    }

    private func buildCopySection() {
        styleRowButton(copyButton, title: "复制全部诊断信息", icon: "doc.on.doc")
        copyButton.addTarget(self, action: #selector(copyAllTapped), for: .touchUpInside)
        copyCard.contentStack.addArrangedSubview(copyButton)
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        renderPassword()
        renderLastControl()
        renderSession()
        renderSignals()
        renderProbe()
        renderBLE()
        renderRaw()
        renderCopy()
    }

    private func renderPassword() {
        let rows: [UIView] = [pwdLenRow, derivedKeyRow, derivedIVRow,
                              oppwdRow, roundTripRow, roundTripNote]
        guard let s = client.session, !s.opPassword.isEmpty else {
            passwordEmptyLabel.isHidden = false
            rows.forEach { $0.isHidden = true }
            return
        }
        passwordEmptyLabel.isHidden = true
        rows.forEach { $0.isHidden = false }

        pwdLenRow.setValue("\(s.opPassword.count) 位")
        let kv = keyIV()
        derivedKeyRow.setValue(kv.key)
        derivedIVRow.setValue(kv.iv)
        oppwdRow.setValue(oppwd())
        let rt = roundTrip()
        roundTripRow.setValue(rt)
        let ok = rt == s.opPassword
        roundTripNote.update(
            icon: ok ? "checkmark.circle.fill" : "xmark.circle.fill",
            text: ok ? "加密→解密回到原文，算法链路没问题"
                     : "回解结果和输入不一致，加密链路有问题",
            color: ok ? .lmGood : .lmBad)
    }

    private func renderLastControl() {
        let rows: [UIView] = [lastTimeRow, lastActionRow, lastPwdLenRow, lastKeyRow, lastIVRow,
                              lastOppwdRow, lastRoundTripRow, lastTokenHeadRow,
                              lastTokenTailRow, lastOutcomeRow]
        guard let t = client.lastControlTrace else {
            lastEmptyLabel.isHidden = false
            rows.forEach { $0.isHidden = true }
            return
        }
        lastEmptyLabel.isHidden = true
        rows.forEach { $0.isHidden = false }

        lastTimeRow.setValue(timeText(t.time))
        lastActionRow.setValue("\(t.action)（cmdid \(t.cmdid)）")
        lastPwdLenRow.setValue("\(t.passwordLength) 位")
        lastKeyRow.setValue(t.key)
        lastIVRow.setValue(t.iv)
        lastOppwdRow.setValue(t.oppwd)
        lastRoundTripRow.setValue(t.roundTrip)
        lastTokenHeadRow.setValue(t.tokenHead)
        lastTokenTailRow.setValue(t.tokenTail)
        lastOutcomeRow.setValue(t.outcome)
    }

    private func renderSession() {
        let rows: [UIView] = [sessAccountIdRow, sessUserIdRow, sessTokenHeadRow, sessTokenTailRow,
                              sessSignKeyRow, sessEncryptKeyRow, sessVinRow, sessCarTypeRow]
        guard let s = client.session else {
            sessionEmptyLabel.isHidden = false
            rows.forEach { $0.isHidden = true }
            return
        }
        sessionEmptyLabel.isHidden = true
        rows.forEach { $0.isHidden = false }

        sessAccountIdRow.setValue(s.accountId.isEmpty ? "--" : s.accountId)
        sessUserIdRow.setValue(s.userId.isEmpty ? "--" : s.userId)
        sessTokenHeadRow.setValue(String(s.accessToken.prefix(32)))
        sessTokenTailRow.setValue(s.accessToken.count >= 64
                                  ? String(Array(s.accessToken)[32..<64]) : "--")
        sessSignKeyRow.setValue(s.signKeyHex)
        sessEncryptKeyRow.setValue(s.encryptKeyHex)
        sessVinRow.setValue(client.selectedVehicle?.vin ?? "--")
        sessCarTypeRow.setValue(client.selectedVehicle?.carType ?? "--")
    }

    private func renderSignals() {
        for id in signalIDs {
            signalRows[id]?.setValue(client.signals[id]?.displayText ?? "--")
        }
        openSignalRow.setTitle("打开信号浏览器（全部 \(client.signals.count) 个 / 快照对比）")
    }

    private func renderProbe() {
        probeBusyRow.setActive(probeBusy)
        let hasResult = !probeResult.isEmpty
        probeResultLabel.isHidden = !hasResult
        probeResultLabel.text = probeResult
        copyProbeButton.isHidden = !hasResult
    }

    private func renderBLE() {
        bleBusyRow.setActive(bleBusy)

        let canProbe = !bleBusy && client.selectedVehicle != nil
        ([bleSyncButton, bleAnchorButton, blePollButton] + bleDangerButtons)
            .forEach { $0.isEnabled = canProbe }

        let probes = Array(client.bleProbes.prefix(6))
        let sig = "\(probes.count)\u{1}"
            + probes.map { "\($0.ok ? 1 : 0)|\($0.title)|\($0.response.count)" }
                .joined(separator: "\u{1}")
        rebuildIfNeeded(bleProbeStack, signature: sig) {
            probes.map { LMDiagProbeCell(result: $0) }
        }

        let hasProbes = !client.bleProbes.isEmpty
        copyBLEButton.isHidden = !hasProbes
        clearBLEButton.isHidden = !hasProbes
    }

    private func renderRaw() {
        now = Date()
        rawBusyRow.setActive(rawBusy)
        rawResultLabel.isHidden = rawResult.isEmpty
        rawResultLabel.text = rawResult
        refreshRawControls()
    }

    /// 只刷新「下发按钮可用性 + 锁定期提示 + 倒计时定时器」。
    /// 从 `render()` 和定时器 tick 两处调用，所以必须幂等。
    private func refreshRawControls() {
        let locked = client.isControlLocked(at: now)
        sendRawButton.isEnabled = !rawBusy && !locked
            && !(client.session?.opPassword.isEmpty ?? true)
        lockNote.isHidden = !locked
        if locked {
            lockNote.update(
                icon: "lock.fill",
                text: "操作密码被服务端锁定，还要 \(client.controlLockRemaining(at: now)) 秒",
                color: .lmBad)
        }
        syncLockTimer()
    }

    private func renderCopy() {
        copyButton.configuration?.title = copied ? "已复制到剪贴板" : "复制全部诊断信息"
        copyButton.configuration?.image = UIImage(
            systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
    }

    // MARK: - 锁定期倒计时
    //
    // 原页用 `.lmClock(until:now:)` 每 0.5 秒推一次 `now`。UIKit 里用一个只在本页
    // 存活期间运行的 Timer 等价实现：只在「真的处于锁定期」时才跑，解锁即停。

    private func syncLockTimer() {
        let locked = client.isControlLocked(at: now)
        if locked {
            guard lockTimer == nil else { return }
            // ★ 用 target/selector 版而不是 block 版：block 版收 `@Sendable` 闭包，
            //   **不继承** @MainActor 隔离，在里面改 `now` 可能直接编译报 actor 隔离错误。
            // ★ 必须加进 `.common` 模式：默认的 `.default` 模式下，用户一拖 ScrollView
            //   计时器就停走，倒计时会卡住不动。
            let timer = Timer(timeInterval: 0.5, target: self,
                              selector: #selector(lockTick),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            lockTimer = timer
        } else {
            lockTimer?.invalidate()
            lockTimer = nil
        }
    }

    @objc private func lockTick() {
        now = Date()
        refreshRawControls()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 离开页面就停表，避免 Timer 一直持有 self
        lockTimer?.invalidate()
        lockTimer = nil
    }

    // MARK: - 动作：导航

    @objc private func openSignalExplorerTapped() {
        navigationController?.pushViewController(
            LMSignalExplorerViewController(client: client), animated: true)
    }

    // MARK: - 动作：官方接口探测

    @objc private func probeParkingTapped() {
        Task { @MainActor [weak self] in await self?.probeParking() }
    }

    @objc private func probeParkingPostTapped() {
        Task { @MainActor [weak self] in await self?.probeParkingPost() }
    }

    @objc private func probeChassisTapped() {
        Task { @MainActor [weak self] in await self?.probeChassis() }
    }

    @objc private func probeRegeoTapped() {
        Task { @MainActor [weak self] in await self?.probeRegeo() }
    }

    @objc private func probeAppointmentTapped() {
        Task { @MainActor [weak self] in await self?.probeAppointment161() }
    }

    @objc private func probeHealthyChargingTapped() {
        Task { @MainActor [weak self] in await self?.probeHealthyCharging() }
    }

    @objc private func probePhoneIPTapped() {
        Task { @MainActor [weak self] in await self?.probePhoneIP() }
    }

    // MARK: - 动作：蓝牙钥匙

    @objc private func bleSyncTapped() {
        Task { @MainActor [weak self] in await self?.syncBLEKeysReadOnly() }
    }

    @objc private func bleAnchorTapped() {
        Task { @MainActor [weak self] in
            await self?.probeBleOne(LMEndpoints.Path.bleKeyAnchor, "GET", "感应区锚点参数")
        }
    }

    @objc private func blePollTapped() {
        Task { @MainActor [weak self] in
            await self?.probeBleOne(LMEndpoints.Path.cccPoll, "GET", "轮询配对结果")
        }
    }

    @objc private func bleDangerTapped(_ sender: UIButton) {
        guard let action = BLEAction(rawValue: sender.tag) else { return }
        bleDanger = action
        presentBLEConfirm(action)
    }

    // MARK: - 动作：未验证 cmdid

    @objc private func rawCmdChanged() {
        rawCmdId = rawCmdField.text ?? ""
    }

    @objc private func rawStateChanged() {
        rawState = rawStateField.text ?? ""
    }

    @objc private func unverifiedRowTapped(_ sender: LMDiagUnverifiedRow) {
        // 填入 = 直接写回两个输入框。这是「动作」不是 render，所以可以动输入控件。
        rawCmdId = String(sender.cmdid)
        rawState = sender.stateText
        rawCmdField.text = rawCmdId
        rawStateField.text = rawState
    }

    @objc private func sendRawTapped() {
        let alert = UIAlertController(
            title: "确认下发未验证指令？",
            message: "cmdid \(rawCmdId) 的语义**没有确认过**。这条指令会真的发到车上，"
                + "可能开关某个你不知道的功能。请确保车在安全位置、你能看到车。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确认下发", style: .destructive) { [weak self] _ in
            Task { @MainActor in await self?.sendRaw() }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - 动作：复制 / 清空

    @objc private func copyProbeTapped() {
        guard !probeResult.isEmpty else { return }
        UIPasteboard.general.string = probeResult
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func copyBLETapped() {
        guard !client.bleProbes.isEmpty else { return }
        UIPasteboard.general.string = bleReport
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func clearBLETapped() {
        client.clearBLEProbes()
    }

    @objc private func copyAllTapped() {
        UIPasteboard.general.string = fullReport
        copied = true
        renderCopy()
    }

    /// 长按复制（`UILabel` 没有 `isSelectable` —— 那是 `UITextView` 的成员）。
    @objc private func copyLabelLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began,
              let label = g.view as? UILabel,
              let text = label.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - 探测实现

    private func probeParking() async {
        guard client.selectedVehicle?.vin != nil else {
            probeResult = "✗ 还没选车"
            renderProbe()
            return
        }
        probeBusy = true
        renderProbe()
        // 走 LMClient.probeParking()：它除了打接口，还会用候选 key 名试着掏经纬度，
        // 结果同时留在 client.parkingProbe 里（定位页以后可以直接用）
        let probe = await client.probeParking()
        probeBusy = false
        let head = "GET \(LMEndpoints.Path.parking)?vin=<vin>"
        if let p = probe {
            let extra: String
            if let lat = p.latitude, let lng = p.longitude {
                extra = "\n→ 掏到坐标：\(lat), \(lng)（和 signalMap 的 2190/2191 对一下）"
            } else {
                extra = "\n→ 响应里没找到候选 key 的经纬度"
            }
            probeResult = head + extra + "\n" + p.rawText
        } else {
            probeResult = head + "\n✗ 没拿到响应（路径或参数不对，属于预期内）"
        }
        renderProbe()
    }

    private func probeParkingPost() async {
        guard let vin = client.selectedVehicle?.vin else {
            probeResult = "✗ 还没选车"
            renderProbe()
            return
        }
        probeBusy = true
        renderProbe()
        let r = await client.probePOST(path: LMEndpoints.Path.parking, body: ["vin": vin])
        probeBusy = false
        probeResult = "POST \(LMEndpoints.Path.parking) {\"vin\":...}\n\(r)"
        renderProbe()
    }

    /// 探测 `/v3/api/chassis/query` —— ★ 已证实返回的是**底盘图片**，不是定位。
    private func probeChassis() async {
        guard client.selectedVehicle?.vin != nil else {
            probeResult = "✗ 还没选车"
            renderProbe()
            return
        }
        probeBusy = true
        renderProbe()
        let head = "GET \(LMEndpoints.Path.chassis)?vin=<vin>"
        let p = await client.probeChassis()
        probeBusy = false
        if let p = p {
            let note = "\n→ 抓包已证实：它返回的是 OSS 上的底盘图片"
                + "（ChassisPicture/prod/<VIN>），不是定位。"
            probeResult = head + note + "\n" + p.rawText
        } else {
            probeResult = head + "\n✗ 没拿到响应（路径或参数不对，属于预期内）"
        }
        renderProbe()
    }

    /// regeo 的参数形状完全未知，把常见的三种都试一遍，哪个通了就知道该用哪个
    private func probeRegeo() async {
        guard let c = client.coordinate else {
            probeResult = "✗ 当前没有车辆坐标，先去「定位」页刷新"
            renderProbe()
            return
        }
        probeBusy = true
        renderProbe()
        let lng = String(format: "%.6f", c.longitude)
        let lat = String(format: "%.6f", c.latitude)

        var out: [String] = []
        let attempts: [(String, [String: String])] = [
            ("location=lng,lat", ["location": "\(lng),\(lat)"]),
            ("lat,lng 分开", ["latitude": lat, "longitude": lng]),
            ("lat/lng 短名", ["lat": lat, "lng": lng]),
        ]
        for (label, params) in attempts {
            let r = await client.probeGET(path: LMEndpoints.Path.regeo, params: params)
            out.append("— \(label)\n\(r)")
        }
        probeBusy = false
        probeResult = "GET \(LMEndpoints.Path.regeo)\n" + out.joined(separator: "\n\n")
        renderProbe()
    }

    // MARK: 2026-10-08 抓包审计补上的三个只读探测

    /// `appremotectl/getappointment?carvin=…&cmdid=161`
    private func probeAppointment161() async {
        probeBusy = true
        renderProbe()
        let r = await client.probeAppointment(cmdid: 161)
        probeBusy = false
        probeResult = """
        GET \(LMEndpoints.Path.appointment)?carvin=<VIN>&cmdid=161

        → 抓包里的原样本是 {"result":0,"code":0,"data":""}（data 是空串）。
          说明这台车当前没有预约项；也说明它的响应结构我们仍然不知道。
          161 属于 rightList，但语义未确认（160/161 一组，疑似「预约」相关）。

        \(r)
        """
        renderProbe()
    }

    /// `healthyCharging/queryPushState`（POST form: carvin + deviceId）
    private func probeHealthyCharging() async {
        probeBusy = true
        renderProbe()
        let r = await client.probeHealthyChargingPush()
        probeBusy = false
        probeResult = """
        POST \(LMEndpoints.Path.healthyChargingPush)
             form: carvin=<VIN>&deviceId=<本机 deviceId>

        → 抓包原样本：{"data":{"isPush":false}}

        \(r)
        """
        renderProbe()
    }

    /// `tecHost` 的 `ipAnalysis/getAddressByIp`
    ///
    /// ★ 这个对「车在淮南、App 显示合肥」那个问题最有用：
    ///   它返回的是「服务端认为**手机**在哪」，跟车端坐标是两个独立来源。
    private func probePhoneIP() async {
        probeBusy = true
        renderProbe()
        let r = await client.probeIpAddress()
        probeBusy = false
        probeResult = """
        GET \(LMEndpoints.tecHost)\(LMEndpoints.Path.ipAddress)

        → 抓包原样本：{"data":{"country":"中国","province":"安徽","city":"淮南"}}
          （响应字段是 errorCode 不是 code）

        \(r)
        """
        renderProbe()
    }

    // MARK: - 蓝牙钥匙探测实现

    private func syncBLEKeysReadOnly() async {
        bleBusy = true
        renderBLE()
        await client.probeBLEKeyReadOnly()
        bleBusy = false
        renderBLE()
    }

    /// 单个蓝牙钥匙接口探测：逐个候选前缀试一遍，结果都留在 `client.bleProbes`
    private func probeBleOne(_ barePath: String, _ method: String, _ title: String) async {
        guard let vin = client.selectedVehicle?.vin else { return }
        bleBusy = true
        renderBLE()
        // ★ 显式标类型：`method == "POST" ? ["vin": vin] : nil` 这种三元
        //   一边是 [String: String]、一边是 nil，参数类型却是 [String: Any]?，
        //   让推断去猜不如直接写死。
        let postBody: [String: Any]? = (method == "POST") ? ["vin": vin] : nil
        for prefix in LMEndpoints.pathPrefixes {
            let tag = prefix.isEmpty ? "无前缀" : prefix
            await client.probeBLEKey(barePath: prefix + barePath,
                                     method: method,
                                     params: ["vin": vin],
                                     body: postBody,
                                     title: "\(title)（\(tag)）")
        }
        bleBusy = false
        renderBLE()
    }

    /// 执行一个「会改服务端状态」的蓝牙钥匙操作（已二次确认）
    private func runBLEAction(_ action: BLEAction) async {
        await probeBleOne(action.path, action.method, action.title)
    }

    private func presentBLEConfirm(_ action: BLEAction) {
        let sheet = UIAlertController(
            title: action.title,
            message: action.warning + "\n\n这个接口的响应结构没有样本，结果会原样列出来。",
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "确认执行", style: .destructive) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.bleDanger = nil
                await self.runBLEAction(action)
            }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.bleDanger = nil }
        })
        // iPad 上 actionSheet 需要锚点，否则会崩
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(sheet, animated: true)
    }

    // MARK: - 未验证 cmdid 下发

    private func sendRaw() async {
        guard let id = Int(rawCmdId.trimmingCharacters(in: .whitespaces)) else {
            rawResult = "✗ cmdid 必须是数字"
            renderRaw()
            return
        }
        guard let data = rawState.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else {
            rawResult = "✗ state 不是合法 JSON 对象"
            renderRaw()
            return
        }
        rawBusy = true
        renderRaw()
        let ok = await client.controlRaw(cmdid: id, state: dict, label: "raw-\(id)")
        rawBusy = false
        rawResult = ok
            ? "✓ cmdid \(id) 已受理并确认成功 —— 看看车有什么反应，再去「信号浏览器」抓快照对比"
            : "✗ cmdid \(id)：\(client.lastError ?? "未知失败")"
        renderRaw()
    }

    // MARK: - 计算（与原页逐条对应）

    private var signalTable: [SignalRef] {
        LMSignalCatalog.refs
            .filter { $0.confidence == .confirmed }
            .sorted { LMSignalCatalog.numeric($0.id) < LMSignalCatalog.numeric($1.id) }
            .map { SignalRef(id: $0.id,
                             name: $0.name + ($0.unit.isEmpty ? "" : "（\($0.unit)）")) }
    }

    private func keyIV() -> (key: String, iv: String) {
        guard let s = client.session,
              let p = try? LMSigner.oppwdKeyIV(accessToken: s.accessToken)
        else { return ("--", "--") }
        return (p.key, p.iv)
    }

    private func oppwd() -> String {
        guard let s = client.session, !s.opPassword.isEmpty,
              let op = try? LMSigner.encryptOppwd(accessToken: s.accessToken,
                                                  password: s.opPassword)
        else { return "--" }
        return op
    }

    private func roundTrip() -> String {
        guard let s = client.session, !s.opPassword.isEmpty,
              let op = try? LMSigner.encryptOppwd(accessToken: s.accessToken,
                                                  password: s.opPassword)
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
            let kv = keyIV()
            lines.append("key: \(kv.key)")
            lines.append("iv: \(kv.iv)")
            lines.append("oppwd: \(oppwd())")
            lines.append("roundTrip: \(roundTrip())")
        }
        if let t = client.lastControlTrace {
            lines.append("--- 上次车控 ---")
            lines.append("action: \(t.action) cmdid=\(t.cmdid)")
            lines.append("outcome: \(t.outcome)")
        }
        return lines.joined(separator: "\n")
    }

    private var bleReport: String {
        var out = "# 蓝牙钥匙接口探测记录\n"
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        for p in client.bleProbes {
            out += "\n[\(f.string(from: p.at))] \(p.ok ? "OK" : "FAIL")  \(p.title)\n"
            out += "  path : \(p.path)\n"
            out += "  req  : \(p.request)\n"
            out += "  resp : \(p.response)\n"
        }
        return out
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    // MARK: - 小工具

    /// 行数会变的内容专用：指纹没变就整块跳过。
    ///
    /// ★ 这里确实动了 `addArrangedSubview`，属于 `render()` 幂等约定的例外。
    ///   可以这么做的原因是这一块里**没有用户输入控件**，重建不会打断输入。
    ///   （手输 cmdid / state 那两个框一律不重建，见 `renderRaw`。）
    private func rebuildIfNeeded(_ container: UIStackView,
                                 signature: String,
                                 build: () -> [UIView]) {
        let key = ObjectIdentifier(container)
        guard rebuildCache[key] != signature else { return }
        rebuildCache[key] = signature
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        build().forEach { container.addArrangedSubview($0) }
    }

    /// 造一个「图标 + 文字」的行内按钮（无底色、左对齐）。
    /// 对应原 SwiftUI 里 `Button { } label: { Label("...", systemImage: "...") }`。
    private func makeRowButton(_ title: String,
                               icon: String,
                               tint: UIColor = .lmAccent) -> UIButton {
        let b = UIButton()
        styleRowButton(b, title: title, icon: icon, tint: tint)
        return b
    }

    /// 就地给一个已存在的按钮套上「行内按钮」样式。
    /// ★ 必须改 `configuration` 而不是 `titleLabel?.font` —— 用 `UIButton.Configuration`
    ///   建的按钮，字体/标题都由配置说了算，直接写 `titleLabel?.font` 会被静默覆盖。
    private func styleRowButton(_ button: UIButton,
                                title: String,
                                icon: String,
                                tint: UIColor = .lmAccent) {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.image = UIImage(systemName: icon)
        cfg.imagePadding = 8
        cfg.baseForegroundColor = tint
        cfg.titleAlignment = .leading
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        button.configuration = cfg
        button.titleLabel?.numberOfLines = 0
    }

    /// 给一个 `UILabel` 挂长按复制（`UILabel` 没有 `isSelectable`，只能自己挂手势）。
    private func enableCopy(_ label: UILabel) {
        label.isUserInteractionEnabled = true
        let press = UILongPressGestureRecognizer(
            target: self, action: #selector(copyLabelLongPressed(_:)))
        press.minimumPressDuration = 0.4
        label.addGestureRecognizer(press)
    }

    /// 1 物理像素的分隔线。
    /// 用 `traitCollection.displayScale` 而不是已弃用的 `UIScreen.main`。
    private func makeSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        line.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true
        return line
    }
}

// MARK: - 一行「键 —— 值」

/// 左边灰色键名（固定 74pt），右边等宽字体值（过长中间截断）。
/// 对应原 SwiftUI 里的 `kv(_:_:)`。
private final class LMDiagKVRow: UIView {

    private let valueLabel = UILabel()

    init(key: String, alignRight: Bool = false) {
        super.init(frame: .zero)

        let keyLabel = UILabel()
        keyLabel.text = key
        keyLabel.font = .systemFont(ofSize: 11)
        keyLabel.textColor = .secondaryLabel
        keyLabel.numberOfLines = 0
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        keyLabel.widthAnchor.constraint(equalToConstant: 74).isActive = true

        valueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 3
        valueLabel.lineBreakMode = .byTruncatingMiddle
        if alignRight { valueLabel.textAlignment = .right }
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 8, alignment: .top)
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
        fatalError("LMDiagKVRow 只能代码创建")
    }

    func setValue(_ v: String) { valueLabel.text = v }
}

// MARK: - 一行「图标 + 提示文字」

/// 对应原 SwiftUI 里的 `Label("...", systemImage: "...")` 小字提示。
private final class LMDiagIconNote: UIView {

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
        fatalError("LMDiagIconNote 只能代码创建")
    }

    func update(icon: String, text: String, color: UIColor) {
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = color
        label.text = text
        label.textColor = color
    }
}

// MARK: - 一行「转圈 + 文字」

/// 对应原 SwiftUI 里的 `ProgressView().scaleEffect(0.7)` + 「探测中…」。
private final class LMDiagBusyRow: UIView {

    private let indicator = UIActivityIndicatorView(style: .medium)

    init(text: String) {
        super.init(frame: .zero)

        let label = LMUIKit.label(text, size: 12, color: .secondaryLabel)
        let row = LMUIKit.hStack(spacing: 8)
        row.addArrangedSubview(indicator)
        row.addArrangedSubview(label)
        row.addArrangedSubview(LMUIKit.spacer())
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("LMDiagBusyRow 只能代码创建")
    }

    func setActive(_ active: Bool) {
        isHidden = !active
        if active { indicator.startAnimating() } else { indicator.stopAnimating() }
    }
}

// MARK: - 一行信号

/// id（等宽）+ 名称 + 此刻的实时值。对应原 SwiftUI 的 `signalMapSection` 行。
private final class LMDiagSignalRow: UIView {

    private let valueLabel = UILabel()

    init(id: String, name: String) {
        super.init(frame: .zero)

        let idLabel = UILabel()
        idLabel.text = id
        idLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        idLabel.textColor = .label
        idLabel.numberOfLines = 1
        idLabel.setContentHuggingPriority(.required, for: .horizontal)
        idLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        idLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .lmAccent
        valueLabel.numberOfLines = 1
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 10)
        row.addArrangedSubview(idLabel)
        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(LMUIKit.spacer())
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
        fatalError("LMDiagSignalRow 只能代码创建")
    }

    func setValue(_ v: String) { valueLabel.text = v }
}

// MARK: - 一行「图标 + 标题 + chevron」导航行

/// 对应原页 signalMapSection 里的 `NavigationLink { SignalExplorerView() }`。
private final class LMDiagNavRow: UIControl {

    private let titleLabel = UILabel()

    init(icon: String, title: String) {
        super.init(frame: .zero)

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = .lmAccent
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0

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
        fatalError("LMDiagNavRow 只能代码创建")
    }

    func setTitle(_ text: String) { titleLabel.text = text }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }
}

// MARK: - 一行「未验证 cmdid」（点一下填入）

/// cmdid + state + 「填入」。对应原页 `rawCmdSection` 里 `ForEach(unverifiedCmds)`。
private final class LMDiagUnverifiedRow: UIControl {

    let cmdid: Int
    /// ★ 不能叫 `state` —— `UIControl` 自己有个 `state: UIControl.State`，
    ///   同名会让子类属性「覆盖父类属性」而类型不同，直接编译失败：
    ///     error: property 'state' with type 'String' cannot override
    ///            a property with type 'UIControl.State'
    ///   （2026-10-09 真烧过一轮 CI）
    let stateText: String

    init(cmdid: Int, state: String) {
        self.cmdid = cmdid
        self.stateText = state
        super.init(frame: .zero)

        let cmdLabel = UILabel()
        cmdLabel.text = "cmdid \(cmdid)"
        cmdLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cmdLabel.setContentHuggingPriority(.required, for: .horizontal)
        cmdLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stateLabel = UILabel()
        stateLabel.text = state
        stateLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 1
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let fillLabel = UILabel()
        fillLabel.text = "填入"
        fillLabel.font = .systemFont(ofSize: 11)
        fillLabel.textColor = .lmAccent
        fillLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 8)
        row.addArrangedSubview(cmdLabel)
        row.addArrangedSubview(stateLabel)
        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(fillLabel)
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
        fatalError("LMDiagUnverifiedRow 只能代码创建")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }
}

// MARK: - 一条蓝牙钥匙探测记录

/// ✅/❌ + 标题 + 时间 + path / req / resp（resp 可长按复制）。
/// 对应原页 `bleKeyProbeSection` 里 `ForEach(client.bleProbes.prefix(6))`。
/// 因为行数会变，这个 cell 每次由 `rebuildIfNeeded` 重建，不做就地更新。
private final class LMDiagProbeCell: UIView {

    private let responseLabel = UILabel()

    init(result: LMBLEProbeResult) {
        super.init(frame: .zero)

        let statusLabel = UILabel()
        statusLabel.text = result.ok ? "✅" : "❌"
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = result.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let timeLabel = UILabel()
        timeLabel.text = result.timeText
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .secondaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let head = LMUIKit.hStack(spacing: 6)
        head.addArrangedSubview(statusLabel)
        head.addArrangedSubview(titleLabel)
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(timeLabel)

        let pathLabel = Self.mono(result.path, lines: 2)
        let requestLabel = Self.mono(result.request, lines: 2)

        responseLabel.text = result.response
        responseLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        responseLabel.textColor = .label
        responseLabel.numberOfLines = 12
        responseLabel.isUserInteractionEnabled = true
        let press = UILongPressGestureRecognizer(target: self,
                                                  action: #selector(copyResponse))
        press.minimumPressDuration = 0.4
        responseLabel.addGestureRecognizer(press)

        let stack = LMUIKit.vStack(spacing: 4)
        stack.addArrangedSubview(head)
        stack.addArrangedSubview(pathLabel)
        stack.addArrangedSubview(requestLabel)
        stack.addArrangedSubview(responseLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMDiagProbeCell 只能代码创建")
    }

    private static func mono(_ text: String, lines: Int) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        l.textColor = .secondaryLabel
        l.numberOfLines = lines
        return l
    }

    @objc private func copyResponse() {
        guard let text = responseLabel.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
