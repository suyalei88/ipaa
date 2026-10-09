//
//  LMChargeViewController.swift
//  LeapmotorLite
//
//  充电中心（UIKit 版）—— 对应原 `Views/ChargeView.swift`（884 行 SwiftUI）。
//
//  ★ 这一页是「只读展示 + 可写车控」混合页，迁移时有两条底线：
//    ① 车控指令的 cmdid 是**实测反汇编验证过**的（193 / 480 / 190 / 161），
//       参数和调用顺序一条都不能改 —— 证据见 `LMEndpoints.ChargeCmdid`。
//    ② 「充电状态」是 5 路标志位投票 + 充电电流判出来的，不是猜的；
//       证据卡必须原样保留，让用户能自己跟官方 App 对一眼。
//
//  ★ 迁移约定（与 LMLoginViewController / LMSettingsViewController 一致）：
//    · 继承 LMBaseViewController，只覆盖 buildUI() / render() 两个钩子
//    · 页内状态（预约时间、充电上限、开关）留在 VC 里，**不进 LMClient**
//    · render() 幂等：只改属性 / isHidden，绝不 addSubview
//      （唯一例外是「其它配置项」和「充电判据证据行」这两块**行数会变**的内容，
//        用 rebuildIfNeeded 指纹模式整块重建，见方法注释）
//
//  ⚠️ 本文件**不要** `import SwiftUI`：11 个页面本轮同时迁完，
//     不再有「包一层旧 SwiftUI 页再 push」的需求。本页也**没有**任何 push 目标。
//
import UIKit

final class LMChargeViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，跟车端无关）

    /// 预约充电编辑态。初值只是占位，真实值由服务端 `config["3"]` 覆盖
    /// （见 `syncAppointmentFromServer()`）—— 不凭空造一个假的默认值给用户。
    private var apBegin = "03:00"
    private var apEnd = "08:00"
    private var apPercent = 80
    private var apEnabled = true
    private var apEveryDay = true

    /// 「预计充满时刻」要跟着时间走，以及「操作密码锁定倒计时」到期后按钮要重新启用 ——
    /// 这两件事都依赖当前时间。SwiftUI 版靠 `.lmClock` 推 `@State now`；
    /// UIKit 里没有「因为 Date() 变了就重绘」这回事，得自己跑一个每秒的 Timer
    /// 去调 `render()`（见 `startClock()` 的注释）。
    private var now = Date()
    private var clockTimer: Timer?
    private var didLoadConfig = false

    /// 行数会变的两块内容（其它配置项 / 充电判据证据行）的「内容指纹」缓存。
    /// render() 会被网络回调反复调用，指纹没变就整块跳过，避免无谓重建。
    private var rebuildCache: [ObjectIdentifier: String] = [:]

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - 控件：顶部电量环

    private let heroView = LMChargeHeroView()
    private let ring = LMBatteryRingView()
    private let statusPill = LMStatusPillView(text: "暂无车况",
                                              icon: "questionmark.circle",
                                              tint: .secondaryLabel)
    private let targetRow = LMChargeInfoRow(title: "目标电量", icon: "target", tint: .lmAccent)
    private let rangeRow = LMChargeInfoRow(title: "当前续航", icon: "road.lanes", tint: .lmTeal)
    private let tempRow = LMChargeInfoRow(title: "电池温度", icon: "thermometer.medium", tint: .lmWarn)

    private let progressBlock = UIStackView()
    private let progressTitleLabel = UILabel()
    private let progressValueLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let progressNoteLabel = UILabel()

    private let updateLabel = UILabel()
    private let scheduleNotLoadedLabel = UILabel()

    // MARK: - 控件：充电控制（cmdid 193）

    private let controlCard = LMCardView(padding: 16, spacing: 12)
    private let lockPill = LMStatusPillView(text: "锁定", icon: "lock.fill", tint: .lmWarn)
    private let chargeButton = UIButton()

    // MARK: - 控件：健康充电（cmdid 480）

    private let healthCard = LMCardView(padding: 16, spacing: 10)
    private let healthUnreadLabel = UILabel()
    private let healthSwitch = UISwitch()
    private let healthStateLabel = UILabel()
    private let healthReadRow = UIStackView()
    /// 「读取开关状态」按钮 —— 提成属性才能在 `renderHealth()` 里改标题/可用态
    /// （用 `configuration` 建的按钮，动态标题必须改 `configuration?.title`）。
    private let healthReadButton = UIButton()
    /// ★ 2026-10-09 加：把「这个状态是从哪读的」写在卡里。
    ///   用户报「官方是开启的、本 App 显示已关闭」，而我们能查到的根因是
    ///   `deviceId` 每次启动都变（见 `LMConfig.deviceId` 的注释）——
    ///   服务端把本机当成陌生设备，带设备维度的状态一律回默认 false。
    private let healthSourceLabel = UILabel()
    /// ★ 2026-10-09 加：读取结果反馈行。
    ///
    /// 起因：用户报「读取开关状态没反应」。查下来是
    /// `refreshHealthyCharging()` 以前**把异常整个吞掉**（`catch { return nil }`），
    /// 而且成功时如果值没变，界面也一个字都不会动 ——
    /// 点下去完全没有反馈，看起来就像按钮坏了。
    /// 现在这一行会把「读取中… / 服务端原始值 + 读取时间 / 出错原因」写出来，
    /// 点一下一定看得见变化。
    private let healthFeedbackLabel = UILabel()

    // MARK: - 控件：充电上限（cmdid 190）

    private let socCard = LMCardView(padding: 16, spacing: 10)
    private let socValueLabel = UILabel()
    private let socSlider = UISlider()
    private let socQuickRow = UIStackView()
    private var socQuickButtons: [UIButton] = []
    private let socApplyButton = UIButton()

    // MARK: - 控件：预约充电编辑（cmdid 161）

    private let apCard = LMCardView(padding: 16, spacing: 12)
    private let apEnableSwitch = UISwitch()
    private let apBeginPicker = UIDatePicker()
    private let apEndPicker = UIDatePicker()
    private let apEverydaySwitch = UISwitch()
    private let apSaveButton = UIButton()

    // MARK: - 控件：预计充至目标电量

    private let remainingCard = LMCardView(padding: 16, spacing: 12)
    private let remainingHeader = LMSectionHeaderLabel("预计充至目标电量")
    private let remainingBigLabel = UILabel()
    private let remainingShortLabel = UILabel()
    private let remainingStatusIcon = UIImageView()
    private let remainingStatusLabel = UILabel()
    private let remainingRateLabel = UILabel()

    // MARK: - 控件：预约充电（只读展示）

    private let scheduleCard = LMCardView(padding: 16, spacing: 12)
    private let schedulePill = LMStatusPillView(text: "已关闭",
                                                icon: "xmark.circle",
                                                tint: .secondaryLabel)
    private let scheduleDetailStack = UIStackView()
    private let scheduleEmptyStack = UIStackView()
    private let scheduleBeginBox = LMChargeTimeBox(title: "开始", tint: .lmAccent)
    private let scheduleEndBox = LMChargeTimeBox(title: "结束", tint: .lmTeal)
    private let scheduleRepeatRow = LMChargeKVRow(key: "重复")
    private let scheduleTargetRow = LMChargeKVRow(key: "目标电量")
    private let scheduleCirculateRow = LMChargeKVRow(key: "每周循环")
    private let scheduleUpdateRow = LMChargeKVRow(key: "配置更新时间")
    private let otherBlobsTitle = UILabel()
    private let otherBlobsStack = UIStackView()

    // MARK: - 控件：电池 / 续航磁贴

    private let batteryHeader = LMSectionHeaderLabel("电池")
    private let tileBatteryTemp = LMMetricTileView(
        title: "电池温度", value: "--", icon: "thermometer.medium", tint: .lmWarn, sub: "信号 2183")
    private let tileSocRaw = LMMetricTileView(
        title: "SOC（原始）", value: "--", icon: "bolt.fill", tint: .lmGood, sub: "信号 100003")
    private let tileSocRound = LMMetricTileView(
        title: "SOC（取整）", value: "--", icon: "bolt.circle", tint: .lmGood, sub: "信号 1204")
    private let tileInterior = LMMetricTileView(
        title: "车内温度", value: "--", icon: "car.side", tint: .lmTeal, sub: "信号 1349")

    private let rangeHeader = LMSectionHeaderLabel("续航")
    private let tileRangeMain = LMMetricTileView(
        title: "剩余续航（主）", value: "--", icon: "road.lanes", tint: .lmAccent, sub: "信号 3257")
    private let tileRangeAlt = LMMetricTileView(
        title: "剩余续航（副）", value: "--", icon: "road.lanes.curved.left",
        tint: .lmIndigo, sub: "信号 3260 / 2188")
    private let tileFullMain = LMMetricTileView(
        title: "满电估算（主）", value: "--", icon: "battery.100.bolt",
        tint: .lmPurple, sub: "3257 ÷ SOC 反推")
    private let tileFullAlt = LMMetricTileView(
        title: "满电估算（副）", value: "--", icon: "battery.75",
        tint: .lmPurple, sub: "3260 ÷ SOC 反推")
    private let rangeHoursNote = UILabel()

    // MARK: - 控件：充电判据证据 / 充电功率

    private let evidenceCard = LMCardView(padding: 16, spacing: 10)
    private let evidenceStack = UIStackView()
    private let guessCard = LMCardView(padding: 16, spacing: 10)
    /// ★ 2026-10-09：这张卡从「待确认的信号」升级成「充电功率」——
    ///   官方本地化表里有 `ChargingCnter_Voltage / _Current / _Power`
    ///   三个键，说明官方充电中心确实显示电压 / 电流 / 功率。
    private let powerRow = LMChargeKVRow(key: "充电功率")
    private let voltageRow = LMChargeKVRow(key: "电压（1177）")
    private let currentRow = LMChargeKVRow(key: "电流（1178）")
    private let powerNote = UILabel()

    // MARK: - 导航栏

    private let refreshItem = UIBarButtonItem()

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "充电"

        refreshItem.image = UIImage(systemName: "arrow.clockwise")
        refreshItem.target = self
        refreshItem.action = #selector(refreshTapped)
        refreshItem.accessibilityLabel = "刷新充电信息"
        navigationItem.rightBarButtonItem = refreshItem

        let (scroll, stack) = makeScrollStack(spacing: 18, inset: 16)

        buildHero()
        buildControlCard()
        buildHealthCard()
        buildSocCard()
        buildAppointmentCard()
        buildRemainingCard()
        buildScheduleCard()
        buildTiles()
        buildEvidenceCard()
        buildGuessCard()

        stack.addArrangedSubview(heroView)
        stack.addArrangedSubview(controlCard)
        stack.addArrangedSubview(healthCard)
        stack.addArrangedSubview(socCard)
        stack.addArrangedSubview(apCard)
        stack.addArrangedSubview(remainingCard)
        stack.addArrangedSubview(scheduleCard)
        stack.addArrangedSubview(batteryHeader)
        stack.addArrangedSubview(makeTileRow(tileBatteryTemp, tileSocRaw))
        stack.addArrangedSubview(makeTileRow(tileSocRound, tileInterior))
        stack.addArrangedSubview(rangeHeader)
        stack.addArrangedSubview(makeTileRow(tileRangeMain, tileRangeAlt))
        stack.addArrangedSubview(makeTileRow(tileFullMain, tileFullAlt))
        stack.addArrangedSubview(LMUIKit.label(
            "两套续航是不同工况标准（3257/SOC ≈ 7.17、3260/SOC ≈ 5.77，四个快照全部严格线性）。"
            + "「满电估算」是拿当前续航按 SOC 等比例放大出来的，SOC 越低误差越大，只当参考。",
            size: 11, color: .secondaryLabel))
        stack.addArrangedSubview(rangeHoursNote)
        stack.addArrangedSubview(evidenceCard)
        stack.addArrangedSubview(guessCard)
        stack.addArrangedSubview(LMUIKit.label(
            "数据来源：signalMap（车况实时信号）+ commonConfig（预约充电配置）。\n"
            + "充电状态由「5 路标志位投票 + 充电电流」判定，证据是「充电中 / 未充电」两张真实快照的逐信号对比。\n"
            + "信号 1200 是「预计充到目标电量还要多久」的投影值，与是否在充电无关，不参与状态判定。",
            size: 11, color: .secondaryLabel))

        // 首帧先按默认折叠态摆好，具体内容交给 render()
        remainingCard.isHidden = true
        rangeHoursNote.isHidden = true
        progressBlock.isHidden = true

        attachRefresh(scroll) { [weak self] in
            // 多语句 + 显式 return，避免单表达式闭包把 `Void?` 当成返回值的类型推断麻烦
            guard let self else { return }
            await self.refreshAll()
        }
    }

    // MARK: - 顶部电量环

    private func buildHero() {
        let topRow = LMUIKit.hStack(spacing: 18, alignment: .center)
        topRow.addArrangedSubview(ring)

        let infoCol = LMUIKit.vStack(spacing: 10, alignment: .leading)
        infoCol.addArrangedSubview(statusPill)
        infoCol.addArrangedSubview(targetRow)
        infoCol.addArrangedSubview(rangeRow)
        infoCol.addArrangedSubview(tempRow)
        topRow.addArrangedSubview(infoCol)
        topRow.addArrangedSubview(LMUIKit.spacer())
        heroView.contentStack.addArrangedSubview(topRow)

        progressTitleLabel.text = "充电进度"
        progressTitleLabel.font = .systemFont(ofSize: 11)
        progressTitleLabel.textColor = .secondaryLabel
        progressValueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        progressValueLabel.textColor = .secondaryLabel
        let progressHead = LMUIKit.hStack(spacing: 8)
        progressHead.addArrangedSubview(progressTitleLabel)
        progressHead.addArrangedSubview(LMUIKit.spacer())
        progressHead.addArrangedSubview(progressValueLabel)

        progressBar.progressTintColor = .lmAccent
        progressNoteLabel.font = .systemFont(ofSize: 11)
        progressNoteLabel.numberOfLines = 0

        progressBlock.axis = .vertical
        progressBlock.spacing = 6
        progressBlock.addArrangedSubview(progressHead)
        progressBlock.addArrangedSubview(progressBar)
        progressBlock.addArrangedSubview(progressNoteLabel)
        heroView.contentStack.addArrangedSubview(progressBlock)

        let clockIcon = UIImageView(image: UIImage(systemName: "clock"))
        clockIcon.tintColor = .secondaryLabel
        clockIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10)
        clockIcon.setContentHuggingPriority(.required, for: .horizontal)
        updateLabel.font = .systemFont(ofSize: 11)
        updateLabel.textColor = .secondaryLabel
        scheduleNotLoadedLabel.font = .systemFont(ofSize: 11)
        scheduleNotLoadedLabel.textColor = .secondaryLabel
        scheduleNotLoadedLabel.text = "预约配置未加载"
        let updateRow = LMUIKit.hStack(spacing: 6)
        updateRow.addArrangedSubview(clockIcon)
        updateRow.addArrangedSubview(updateLabel)
        updateRow.addArrangedSubview(LMUIKit.spacer())
        updateRow.addArrangedSubview(scheduleNotLoadedLabel)
        heroView.contentStack.addArrangedSubview(updateRow)
    }

    // MARK: - 充电控制（cmdid 193）

    private func buildControlCard() {
        let head = LMUIKit.hStack(spacing: 8)
        head.addArrangedSubview(LMSectionHeaderLabel("充电控制"))
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(lockPill)
        lockPill.isHidden = true
        controlCard.contentStack.addArrangedSubview(head)

        var cfg = UIButton.Configuration.filled()
        cfg.title = "立即充电"
        cfg.image = UIImage(systemName: "bolt.fill")
        cfg.imagePadding = 6
        cfg.baseBackgroundColor = .lmGood
        cfg.baseForegroundColor = .lmCanvas
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        chargeButton.configuration = cfg
        chargeButton.addTarget(self, action: #selector(chargeTapped), for: .touchUpInside)
        controlCard.contentStack.addArrangedSubview(chargeButton)

        controlCard.contentStack.addArrangedSubview(LMUIKit.label(
            "cmdid 193（官方 requestForBeginOrEndChargingWithContent:）。"
            + "能不能真的充起来还取决于是否插枪、枪是否锁止 —— 车端自己判断，"
            + "本 App 只负责把指令发过去并回报结果。",
            size: 11, color: .secondaryLabel))
    }

    // MARK: - 健康充电（cmdid 480）

    private func buildHealthCard() {
        healthUnreadLabel.text = "未读取"
        healthUnreadLabel.font = .systemFont(ofSize: 11)
        healthUnreadLabel.textColor = .secondaryLabel
        let head = LMUIKit.hStack(spacing: 8)
        head.addArrangedSubview(LMSectionHeaderLabel("健康充电"))
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(healthUnreadLabel)
        healthCard.contentStack.addArrangedSubview(head)

        healthSwitch.onTintColor = .lmGood
        healthSwitch.addTarget(self, action: #selector(healthSwitchChanged), for: .valueChanged)
        healthStateLabel.font = .systemFont(ofSize: 15, weight: .medium)
        let toggleRow = LMUIKit.hStack(spacing: 10)
        toggleRow.addArrangedSubview(healthSwitch)
        toggleRow.addArrangedSubview(healthStateLabel)
        toggleRow.addArrangedSubview(LMUIKit.spacer())
        healthCard.contentStack.addArrangedSubview(toggleRow)

        // 与 `LMUIKit.plainButton(_:)` 同款样式，只是这里是属性而不是局部变量
        var readCfg = UIButton.Configuration.plain()
        readCfg.title = "读取开关状态"
        readCfg.baseForegroundColor = .lmAccent
        readCfg.background.backgroundColor = .lmCard
        readCfg.background.strokeColor = .lmCardLine
        readCfg.background.strokeWidth = 1
        readCfg.background.cornerRadius = 10
        readCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14,
                                                        bottom: 10, trailing: 14)
        healthReadButton.configuration = readCfg
        healthReadButton.addTarget(self, action: #selector(healthReadTapped), for: .touchUpInside)
        // 用「按钮 + 弹簧」的横排容器，避免按钮被纵向 StackView 拉满宽；
        // 这个容器跟开关互斥，render 里靠 isHidden 折叠（所以做成属性）。
        healthReadRow.axis = .horizontal
        healthReadRow.spacing = 0
        healthReadRow.addArrangedSubview(healthReadButton)
        healthReadRow.addArrangedSubview(LMUIKit.spacer())
        healthCard.contentStack.addArrangedSubview(healthReadRow)

        // 读取结果反馈（读取中 / 原始值 + 时间 / 出错原因）
        healthFeedbackLabel.font = .systemFont(ofSize: 11.5)
        healthFeedbackLabel.textColor = .secondaryLabel
        healthFeedbackLabel.numberOfLines = 0
        healthFeedbackLabel.isHidden = true
        healthCard.contentStack.addArrangedSubview(healthFeedbackLabel)

        healthCard.contentStack.addArrangedSubview(LMUIKit.label(
            "打开后，将根据车辆电池状态自动调整充电上限，以保持电池健康。"
            + "官方说明：健康充电期间可能无法把上限调到 90% 以上，属正常保护。",
            size: 11, color: .secondaryLabel))

        // ★ 2026-10-09：把状态来源和「读不到怎么办」写清楚。
        //   以前卡里只有一句「已关闭」，用户对着官方 App 的「已开启」完全没辙 ——
        //   既不知道这个值从哪来，也没有重读的入口。
        //   ★ 再补一层：这个接口回的 `isPush` **未必等于官方那个功能开关**
        //     （官方自己调也拿到 false），所以不写「已关闭」，写「服务端返回 …」。
        healthSourceLabel.text = "状态来源：healthyCharging/queryPushState 的 data.isPush"
            + "（按 VIN + 设备号查询）。⚠️ 官方 App 自己调这条也拿到 false，"
            + "所以它更像「充电推送提醒」而不是「健康充电功能开关」——"
            + "两边不一致时以官方 App 为准。点「读取开关状态」可随时重读。"
        healthSourceLabel.font = .systemFont(ofSize: 11)
        healthSourceLabel.textColor = .secondaryLabel
        healthSourceLabel.numberOfLines = 0
        healthCard.contentStack.addArrangedSubview(healthSourceLabel)
    }

    // MARK: - 充电上限（cmdid 190）

    private func buildSocCard() {
        socValueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        socValueLabel.textColor = .lmAccent
        let head = LMUIKit.hStack(spacing: 8)
        head.addArrangedSubview(LMSectionHeaderLabel("充电上限"))
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(socValueLabel)
        socCard.contentStack.addArrangedSubview(head)

        socSlider.minimumValue = 50
        socSlider.maximumValue = 100
        socSlider.isContinuous = true
        socSlider.addTarget(self, action: #selector(socSliderChanged), for: .valueChanged)
        socCard.contentStack.addArrangedSubview(socSlider)

        socQuickRow.axis = .horizontal
        socQuickRow.spacing = 8
        for v in [80, 90, 100] {
            let b = LMUIKit.plainButton("\(v)%")
            b.tag = v
            b.addTarget(self, action: #selector(socQuickTapped(_:)), for: .touchUpInside)
            socQuickButtons.append(b)
            socQuickRow.addArrangedSubview(b)
        }
        socQuickRow.addArrangedSubview(LMUIKit.spacer())
        socCard.contentStack.addArrangedSubview(socQuickRow)

        var cfg = UIButton.Configuration.filled()
        cfg.title = "下发充电上限 80%"
        cfg.image = UIImage(systemName: "battery.75")
        cfg.imagePadding = 6
        cfg.baseBackgroundColor = .lmAccent
        cfg.baseForegroundColor = .lmCanvas
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        socApplyButton.configuration = cfg
        socApplyButton.addTarget(self, action: #selector(socApplyTapped), for: .touchUpInside)
        socCard.contentStack.addArrangedSubview(socApplyButton)

        socCard.contentStack.addArrangedSubview(LMUIKit.label(
            "cmdid 190（官方 requestForChargingSetContent:）。"
            + "官方给的推荐值是 80% 与 90%（「最佳限值80%/90%」）。",
            size: 11, color: .secondaryLabel))
    }

    // MARK: - 预约充电编辑（cmdid 161）

    private func buildAppointmentCard() {
        apEnableSwitch.onTintColor = .lmAccent
        apEnableSwitch.addTarget(self, action: #selector(apEnableChanged), for: .valueChanged)
        let head = LMUIKit.hStack(spacing: 8)
        head.addArrangedSubview(LMSectionHeaderLabel("设置预约充电"))
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(apEnableSwitch)
        apCard.contentStack.addArrangedSubview(head)

        configureTimePicker(apBeginPicker, initial: apBegin,
                            action: #selector(apBeginChanged))
        configureTimePicker(apEndPicker, initial: apEnd,
                            action: #selector(apEndChanged))
        let arrow = UIImageView(image: UIImage(systemName: "arrow.right"))
        arrow.tintColor = .secondaryLabel
        arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        arrow.setContentHuggingPriority(.required, for: .horizontal)
        let timeRow = LMUIKit.hStack(spacing: 14, alignment: .center)
        timeRow.addArrangedSubview(makePickerColumn("开始", apBeginPicker))
        timeRow.addArrangedSubview(arrow)
        timeRow.addArrangedSubview(makePickerColumn("结束", apEndPicker))
        timeRow.addArrangedSubview(LMUIKit.spacer())
        apCard.contentStack.addArrangedSubview(timeRow)

        apEverydaySwitch.onTintColor = .lmAccent
        apEverydaySwitch.addTarget(self, action: #selector(apEverydayChanged), for: .valueChanged)
        let everyRow = LMUIKit.hStack(spacing: 10)
        everyRow.addArrangedSubview(apEverydaySwitch)
        everyRow.addArrangedSubview(LMUIKit.label("每天重复", size: 15))
        everyRow.addArrangedSubview(LMUIKit.spacer())
        apCard.contentStack.addArrangedSubview(everyRow)

        var cfg = UIButton.Configuration.filled()
        cfg.title = "保存预约"
        cfg.image = UIImage(systemName: "clock.badge.checkmark")
        cfg.imagePadding = 6
        cfg.baseBackgroundColor = .lmAccent
        cfg.baseForegroundColor = .lmCanvas
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        apSaveButton.configuration = cfg
        apSaveButton.addTarget(self, action: #selector(apSaveTapped), for: .touchUpInside)
        apCard.contentStack.addArrangedSubview(apSaveButton)

        apCard.contentStack.addArrangedSubview(LMUIKit.label(
            "cmdid 161（官方 requestForAppointmentContrlCmdID:content:）。"
            + "字段沿用服务端 config[\"3\"] 的原名回传（读什么写什么）。"
            + "官方限制：仅支持慢充；开始时间需在当前时间 5 分钟后、12 小时内；"
            + "开始与结束时间不能相同。",
            size: 11, color: .secondaryLabel))
    }

    private func configureTimePicker(_ picker: UIDatePicker,
                                     initial: String,
                                     action: Selector) {
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        if let d = Self.hmFormatter.date(from: initial) { picker.date = d }
        picker.addTarget(self, action: action, for: .valueChanged)
    }

    /// 「小标题 + 时间选择器」的竖排组合，对应原 SwiftUI 里手写的 label + DatePicker。
    private func makePickerColumn(_ caption: String, _ picker: UIDatePicker) -> UIView {
        let col = LMUIKit.vStack(spacing: 4, alignment: .leading)
        col.addArrangedSubview(LMUIKit.label(caption, size: 11, color: .secondaryLabel))
        col.addArrangedSubview(picker)
        return col
    }

    // MARK: - 预计充至目标电量

    private func buildRemainingCard() {
        remainingCard.contentStack.addArrangedSubview(remainingHeader)

        remainingBigLabel.font = .systemFont(ofSize: 32, weight: .bold)
        remainingBigLabel.textColor = .lmAccent
        remainingBigLabel.setContentHuggingPriority(.required, for: .horizontal)
        remainingShortLabel.font = .systemFont(ofSize: 15)
        remainingShortLabel.textColor = .secondaryLabel
        let bigRow = LMUIKit.hStack(spacing: 4, alignment: .firstBaseline)
        bigRow.addArrangedSubview(remainingBigLabel)
        bigRow.addArrangedSubview(remainingShortLabel)
        bigRow.addArrangedSubview(LMUIKit.spacer())
        remainingCard.contentStack.addArrangedSubview(bigRow)

        remainingStatusIcon.contentMode = .scaleAspectFit
        remainingStatusIcon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12)
        remainingStatusIcon.setContentHuggingPriority(.required, for: .horizontal)
        remainingStatusLabel.font = .systemFont(ofSize: 13)
        remainingStatusLabel.textColor = .secondaryLabel
        remainingStatusLabel.numberOfLines = 0
        let statusRow = LMUIKit.hStack(spacing: 8, alignment: .top)
        statusRow.addArrangedSubview(remainingStatusIcon)
        statusRow.addArrangedSubview(remainingStatusLabel)
        remainingCard.contentStack.addArrangedSubview(statusRow)

        remainingCard.contentStack.addArrangedSubview(makeDivider())

        let rateIcon = UIImageView(image: UIImage(systemName: "gauge.with.dots.needle.33percent"))
        rateIcon.tintColor = .lmPurple
        rateIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12)
        rateIcon.setContentHuggingPriority(.required, for: .horizontal)
        remainingRateLabel.font = .systemFont(ofSize: 13)
        remainingRateLabel.textColor = .secondaryLabel
        remainingRateLabel.numberOfLines = 0
        let rateRow = LMUIKit.hStack(spacing: 8, alignment: .top)
        rateRow.addArrangedSubview(rateIcon)
        rateRow.addArrangedSubview(remainingRateLabel)
        remainingCard.contentStack.addArrangedSubview(rateRow)

        remainingCard.contentStack.addArrangedSubview(LMUIKit.label(
            "信号 1200。★ 它「不是」充电状态位 —— 实测它是纯 SOC 投影："
            + "1200 ≈ round(11.33 × (目标电量 − SOC))，四个实测点离散度 0.18%。"
            + "18:02 车没在充电时它照样是 550，所以「有没有在充电」另有判据。",
            size: 11, color: .tertiaryLabel))
    }

    // MARK: - 预约充电（只读展示）

    private func buildScheduleCard() {
        let head = LMUIKit.hStack(spacing: 8)
        head.addArrangedSubview(LMSectionHeaderLabel("预约充电"))
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(schedulePill)
        scheduleCard.contentStack.addArrangedSubview(head)

        scheduleDetailStack.axis = .vertical
        scheduleDetailStack.spacing = 12
        let arrow = UIImageView(image: UIImage(systemName: "arrow.right"))
        arrow.tintColor = .secondaryLabel
        arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        arrow.setContentHuggingPriority(.required, for: .horizontal)
        let timeRow = LMUIKit.hStack(spacing: 14, alignment: .center)
        timeRow.addArrangedSubview(scheduleBeginBox)
        timeRow.addArrangedSubview(arrow)
        timeRow.addArrangedSubview(scheduleEndBox)
        timeRow.addArrangedSubview(LMUIKit.spacer())
        scheduleDetailStack.addArrangedSubview(timeRow)
        scheduleDetailStack.addArrangedSubview(makeDivider())
        scheduleDetailStack.addArrangedSubview(scheduleRepeatRow)
        scheduleDetailStack.addArrangedSubview(scheduleTargetRow)
        scheduleDetailStack.addArrangedSubview(scheduleCirculateRow)
        scheduleDetailStack.addArrangedSubview(scheduleUpdateRow)
        scheduleDetailStack.addArrangedSubview(LMUIKit.label(
            "本页只读。写预约充电的接口没有抓包样本，在没有验证清楚之前不会去改你车上的设置 —— "
            + "要用改时间/改目标电量，请先在官方 App 里改。",
            size: 11, color: .secondaryLabel))
        scheduleCard.contentStack.addArrangedSubview(scheduleDetailStack)

        scheduleEmptyStack.axis = .vertical
        scheduleEmptyStack.spacing = 12
        let qIcon = UIImageView(image: UIImage(systemName: "questionmark.circle"))
        qIcon.tintColor = .secondaryLabel
        qIcon.setContentHuggingPriority(.required, for: .horizontal)
        let hint = LMUIKit.label("没有读到预约充电配置。下拉刷新，或到官方 App 确认是否设置过。",
                                 size: 15, color: .secondaryLabel)
        let hintRow = LMUIKit.hStack(spacing: 8, alignment: .top)
        hintRow.addArrangedSubview(qIcon)
        hintRow.addArrangedSubview(hint)
        scheduleEmptyStack.addArrangedSubview(hintRow)
        let reload = LMUIKit.plainButton("重新加载配置")
        reload.addTarget(self, action: #selector(reloadConfigTapped), for: .touchUpInside)
        let reloadRow = LMUIKit.hStack(spacing: 0)
        reloadRow.addArrangedSubview(reload)
        reloadRow.addArrangedSubview(LMUIKit.spacer())
        scheduleEmptyStack.addArrangedSubview(reloadRow)
        scheduleCard.contentStack.addArrangedSubview(scheduleEmptyStack)
        scheduleEmptyStack.isHidden = true

        otherBlobsTitle.text = "其它车辆配置（commonConfig.config）"
        otherBlobsTitle.font = .systemFont(ofSize: 11)
        otherBlobsTitle.textColor = .secondaryLabel
        otherBlobsStack.axis = .vertical
        otherBlobsStack.spacing = 6
        scheduleCard.contentStack.addArrangedSubview(otherBlobsTitle)
        scheduleCard.contentStack.addArrangedSubview(otherBlobsStack)
        otherBlobsTitle.isHidden = true
        otherBlobsStack.isHidden = true
    }

    // MARK: - 磁贴网格

    private func buildTiles() {
        rangeHoursNote.font = .systemFont(ofSize: 11)
        rangeHoursNote.textColor = .tertiaryLabel
        rangeHoursNote.numberOfLines = 0
    }

    private func makeTileRow(_ a: LMMetricTileView, _ b: LMMetricTileView) -> UIStackView {
        let row = LMUIKit.hStack(spacing: 12, alignment: .fill)
        row.distribution = .fillEqually
        row.addArrangedSubview(a)
        row.addArrangedSubview(b)
        return row
    }

    // MARK: - 充电判据证据

    private func buildEvidenceCard() {
        let icon = UIImageView(image: UIImage(systemName: "checklist"))
        icon.tintColor = .lmTeal
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = LMUIKit.label("充电状态是怎么判出来的", size: 13, weight: .semibold)
        let head = LMUIKit.hStack(spacing: 6)
        head.addArrangedSubview(icon)
        head.addArrangedSubview(title)
        evidenceCard.contentStack.addArrangedSubview(head)

        evidenceStack.axis = .vertical
        evidenceStack.spacing = 10
        evidenceCard.contentStack.addArrangedSubview(evidenceStack)
    }

    // MARK: - 待确认信号

    private func buildGuessCard() {
        let icon = UIImageView(image: UIImage(systemName: "bolt.badge.automatic.fill"))
        icon.tintColor = .lmAccent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = LMUIKit.label("充电功率（电压 × 电流）", size: 13, weight: .semibold)
        let head = LMUIKit.hStack(spacing: 6)
        head.addArrangedSubview(icon)
        head.addArrangedSubview(title)
        guessCard.contentStack.addArrangedSubview(head)

        // ★ 2026-10-09：证据升级 —— 以前这张卡叫「待确认的信号（别当官方数字用）」，
        //   因为 1177 只知道是「电压类量」、1178 只知道是「电流类量」。
        //   现在官方本地化表给出了充电中心的三个键，电压/电流这对配对就立住了。
        powerNote.text = "官方充电中心有「电压 / 电流 / 功率」三项"
            + "（本地化表 ChargingCnter_Voltage / _Current / _Power）。"
            + "车端上报的信号里只有 1177（电压）与 1178（电流）这一对量纲自洽，"
            + "功率按「电压 × 电流」现算 —— 它是**派生值**，不是车端直接给的数字。"
        powerNote.font = .systemFont(ofSize: 11)
        powerNote.textColor = .secondaryLabel
        powerNote.numberOfLines = 0

        guessCard.contentStack.addArrangedSubview(powerRow)
        guessCard.contentStack.addArrangedSubview(voltageRow)
        guessCard.contentStack.addArrangedSubview(currentRow)
        guessCard.contentStack.addArrangedSubview(powerNote)
        guessCard.contentStack.addArrangedSubview(LMUIKit.label(
            "「设置 → 诊断 → 信号浏览器」可以抓两次快照做对比，"
            + "验证 1177 是否随充电抬升、1178 是否随插枪跳到非零。",
            size: 11, color: .tertiaryLabel))
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        renderHero()
        renderControl()
        renderHealth()
        renderSoc()
        renderAppointment()
        renderRemaining()
        renderSchedule()
        renderTiles()
        renderEvidence()
        renderGuess()
        refreshItem.isEnabled = !client.isBusy
    }

    private func renderHero() {
        ring.update(progress: client.batteryPercent, tint: ringTint(client.batteryPercent))

        if client.signals.isEmpty {
            statusPill.update(text: "暂无车况", icon: "questionmark.circle", tint: .secondaryLabel)
        } else {
            let s = client.chargeState
            statusPill.update(text: s.text, icon: s.icon, tint: chargeStateTint(s))
        }

        if let t = client.chargeTargetPercent {
            targetRow.isHidden = false
            targetRow.update(value: "\(t) %")
        } else {
            targetRow.isHidden = true
        }
        if let km = client.rangeKm {
            rangeRow.isHidden = false
            rangeRow.update(value: "\(Int(km.rounded())) km")
        } else {
            rangeRow.isHidden = true
        }
        if let temp = client.batteryTemp {
            tempRow.isHidden = false
            tempRow.update(value: String(format: "%.1f ℃", temp))
        } else {
            tempRow.isHidden = true
        }

        if let soc = client.batteryPercent,
           let target = client.chargeTargetPercent, target > 0 {
            progressBlock.isHidden = false
            progressValueLabel.text = "\(Int(soc.rounded()))% / \(target)%"
            progressBar.progress = Float(min(soc, Double(target)) / max(Double(target), 1))
            if soc >= Double(target) {
                progressBar.progressTintColor = .lmGood
                progressNoteLabel.text = "已达到目标电量"
                progressNoteLabel.textColor = .lmGood
            } else {
                progressBar.progressTintColor = .lmAccent
                progressNoteLabel.text = "还差 \(Int((Double(target) - soc).rounded())) 个百分点"
                progressNoteLabel.textColor = .secondaryLabel
            }
        } else {
            progressBlock.isHidden = true
        }

        updateLabel.text = updateText()
        scheduleNotLoadedLabel.isHidden = (client.chargeSchedule != nil)
    }

    private func renderControl() {
        let locked = client.controlLockRemaining() > 0
        lockPill.isHidden = !locked
        if locked {
            lockPill.update(text: "锁定 \(client.controlLockRemaining())s",
                            icon: "lock.fill", tint: .lmWarn)
        }
        // 按钮语义跟随**实测充电状态**，不跟随本地按钮状态 ——
        // 否则会出现「点了没生效但按钮已经变了」的错觉。
        let charging = client.isCharging
        chargeButton.configuration?.title = charging ? "结束充电" : "立即充电"
        chargeButton.configuration?.image =
            UIImage(systemName: charging ? "stop.circle.fill" : "bolt.fill")
        chargeButton.configuration?.baseBackgroundColor = charging ? .lmWarn : .lmGood
        chargeButton.isEnabled = !client.isBusy && !locked
    }

    private func renderHealth() {
        let locked = client.controlLockRemaining() > 0
        let loading = client.healthyChargingLoading

        if let on = client.healthyChargingPush {
            healthUnreadLabel.isHidden = true
            healthSwitch.isHidden = false
            healthStateLabel.isHidden = false
            healthStateLabel.text = on ? "已开启" : "已关闭"
            // ★ 用颜色区分：开启给主色，关闭给次级文字色 ——
            //   以前两种情况都是同一个颜色，扫一眼分不出开还是关。
            healthStateLabel.textColor = on ? .lmGood : .lmText2
            healthSwitch.setOn(on, animated: false)
            healthSwitch.isEnabled = !client.isBusy && !locked && !loading
        } else {
            healthUnreadLabel.isHidden = false
            healthSwitch.isHidden = true
            healthStateLabel.isHidden = true
        }

        // ★ 2026-10-09：读取按钮**不再隐藏**。
        //   以前读到一次就把它藏了，用户看到「已关闭」却没有任何重读的入口，
        //   对着官方 App 的「已开启」只能干瞪眼。现在随时可点。
        healthReadRow.isHidden = false
        healthReadRow.isUserInteractionEnabled = !client.isBusy && !loading
        // 读取中要有明确反馈，否则用户以为按钮坏了
        healthReadRow.alpha = loading ? 0.5 : 1.0
        // ★ 用 configuration 建的按钮，动态标题必须改 `configuration?.title`
        //   （写 `titleLabel?.text` 会被配置覆盖，静默失效）。
        healthReadButton.configuration?.title = loading ? "读取中…" : "读取开关状态"
        healthReadButton.isEnabled = !client.isBusy && !loading

        // ★ 读取结果反馈：一定要写出「点完之后发生了什么」。
        //   优先级：读取中 > 出错 > 成功（原始值 + 时间）。
        if loading {
            healthFeedbackLabel.isHidden = false
            healthFeedbackLabel.textColor = .lmAccent
            healthFeedbackLabel.text = "正在向车端查询…"
        } else if let err = client.healthyChargingError {
            healthFeedbackLabel.isHidden = false
            healthFeedbackLabel.textColor = .lmBad
            healthFeedbackLabel.text = "⚠️ \(err)"
        } else if let on = client.healthyChargingPush {
            healthFeedbackLabel.isHidden = false
            healthFeedbackLabel.textColor = .secondaryLabel
            let raw = on ? "true" : "false"
            healthFeedbackLabel.text =
                "已读取：服务端返回 isPush = \(raw)"
                + "（\(Self.healthTimeText(client.healthyChargingReadAt))）"
        } else {
            healthFeedbackLabel.isHidden = true
        }
    }

    /// `2026-10-09 17:33:08`
    private static func healthTimeText(_ d: Date?) -> String {
        guard let d else { return "时间未知" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func renderSoc() {
        let locked = client.controlLockRemaining() > 0
        let enabled = !client.isBusy && !locked
        socValueLabel.text = "\(apPercent) %"
        // 用户正在拖时不要回写，否则会跟手指抢
        if !socSlider.isTracking { socSlider.value = Float(apPercent) }
        socSlider.isEnabled = enabled
        socApplyButton.configuration?.title = "下发充电上限 \(apPercent)%"
        socApplyButton.isEnabled = enabled
        socQuickButtons.forEach { $0.isEnabled = enabled }
    }

    private func renderAppointment() {
        let locked = client.controlLockRemaining() > 0
        let enabled = !client.isBusy && !locked
        apEnableSwitch.setOn(apEnabled, animated: false)
        apEnableSwitch.isEnabled = enabled
        apEverydaySwitch.setOn(apEveryDay, animated: false)
        apEverydaySwitch.isEnabled = enabled
        // 只在真的不一致时才写回，避免打断用户正在转的滚轮
        if Self.hmFormatter.string(from: apBeginPicker.date) != apBegin,
           let d = Self.hmFormatter.date(from: apBegin) {
            apBeginPicker.setDate(d, animated: false)
        }
        if Self.hmFormatter.string(from: apEndPicker.date) != apEnd,
           let d = Self.hmFormatter.date(from: apEnd) {
            apEndPicker.setDate(d, animated: false)
        }
        apBeginPicker.isEnabled = enabled
        apEndPicker.isEnabled = enabled
        apSaveButton.configuration?.title = "保存预约（\(apBegin)–\(apEnd) · \(apPercent)%）"
        apSaveButton.isEnabled = enabled
    }

    private func renderRemaining() {
        guard let m = client.chargeMinutesToTarget else {
            remainingCard.isHidden = true
            return
        }
        remainingCard.isHidden = false
        remainingHeader.text = targetTitle()
        remainingBigLabel.text = hoursMinutes(m)
        remainingShortLabel.text = targetShort()

        // ★ 只有真的在充电，才把「几点到」写出来。没充电时那是个假设值，
        //   写时刻会让人以为在倒计时。
        if client.isCharging {
            remainingStatusIcon.image = UIImage(systemName: "clock.badge.checkmark")
            remainingStatusIcon.tintColor = .lmTeal
            remainingStatusLabel.text = "按此推算，约 \(fullAtText(m)) 到达目标电量"
        } else {
            remainingStatusIcon.image = UIImage(systemName: "pause.circle")
            remainingStatusIcon.tintColor = .lmWarn
            remainingStatusLabel.text = "车当前没在充电 —— 这只是「插上充电枪后」的估算，不是倒计时。"
        }
        remainingRateLabel.text = rateText()
    }

    private func renderSchedule() {
        if let s = client.chargeSchedule {
            schedulePill.isHidden = false
            schedulePill.update(text: s.isEnabled ? "已开启" : "已关闭",
                                icon: s.isEnabled ? "checkmark.circle.fill" : "xmark.circle",
                                tint: s.isEnabled ? .lmGood : .secondaryLabel)
            scheduleDetailStack.isHidden = false
            scheduleEmptyStack.isHidden = true
            scheduleBeginBox.update(s.beginTime)
            scheduleEndBox.update(s.endTime)
            scheduleRepeatRow.update(s.weekdayText)
            scheduleTargetRow.update(s.targetPercent.map { "\($0) %" } ?? "--")
            scheduleCirculateRow.update(s.isCirculating ? "是" : "否")
            if let u = s.updateTime, !u.isEmpty {
                scheduleUpdateRow.isHidden = false
                scheduleUpdateRow.update(u)
            } else {
                scheduleUpdateRow.isHidden = true
            }
        } else {
            schedulePill.isHidden = true
            scheduleDetailStack.isHidden = true
            scheduleEmptyStack.isHidden = false
        }
        renderOtherBlobs()
    }

    private func renderOtherBlobs() {
        let blobs = client.configBlobs
            .filter { $0.key != "3" }
            .sorted { $0.key < $1.key }
        let sig = blobs.map { "\($0.key)=\(describe($0.value))" }.joined(separator: "\u{1}")
        otherBlobsTitle.isHidden = blobs.isEmpty
        otherBlobsStack.isHidden = blobs.isEmpty
        rebuildIfNeeded(otherBlobsStack, signature: sig) { () -> [UIView] in
            blobs.map { item -> UIView in
                let row = LMChargeKVRow(key: "config[\"\(item.key)\"]")
                row.update(describe(item.value))
                return row
            }
        }
    }

    private func renderTiles() {
        tileBatteryTemp.update(
            value: client.batteryTemp.map { String(format: "%.1f ℃", $0) } ?? "--",
            sub: "信号 2183")
        tileSocRaw.update(value: client.signalText("100003", unit: "%"), sub: "信号 100003")
        tileSocRound.update(value: client.signalText("1204", unit: "%"), sub: "信号 1204")
        tileInterior.update(
            value: client.interiorTemp.map { String(format: "%.1f ℃", $0) } ?? "--",
            sub: "信号 1349")
        tileRangeMain.update(
            value: client.rangeKm.map { "\(Int($0.rounded())) km" } ?? "--", sub: "信号 3257")
        tileRangeAlt.update(
            value: client.rangeAltKm.map { "\(Int($0.rounded())) km" } ?? "--",
            sub: "信号 3260 / 2188")
        tileFullMain.update(
            value: client.fullRangeEstimateKm.map { "\(Int($0.rounded())) km" } ?? "--",
            sub: "3257 ÷ SOC 反推")
        tileFullAlt.update(
            value: client.fullRangeAltEstimateKm.map { "\(Int($0.rounded())) km" } ?? "--",
            sub: "3260 ÷ SOC 反推")
        if let h = client.rangeHoursAt60 {
            rangeHoursNote.isHidden = false
            rangeHoursNote.text = String(
                format: "按 60 km/h 均速粗估，当前续航还能跑约 %.1f 小时（估算，不是官方数据）。", h)
        } else {
            rangeHoursNote.isHidden = true
        }
    }

    private func renderEvidence() {
        let votes = "\(client.chargeFlagVotes) / \(LMClient.chargeFlagIDs.count)"
        let hvText = (client.highVoltageActive ? "已激活 · " : "未激活 · ") + votes
        let currentText = client.chargeCurrentA.map { String(format: "%.2f A", $0) } ?? "0.00 A"
        let stateText = client.chargeState.text
        let sig = [hvText, currentText, stateText].joined(separator: "\u{1}")
        rebuildIfNeeded(evidenceStack, signature: sig) { () -> [UIView] in
            var views: [UIView] = []
            // ★ 判据 = 电流，放最上面（用户最该看的就是这一行）
            let cRow = LMChargeKVRow(key: "充电电流 1178")
            cRow.update(currentText)
            views.append(cRow)
            views.append(LMUIKit.label(
                "★ 判据只看它：没有电流就一定没有电进电池。电流为零 = 未充电，"
                + "不管别的标志位怎么翻。", size: 11, color: .secondaryLabel))
            views.append(makeDivider())
            // ★ 高压系统状态：以前这 5 位被当成「充电中」投票，是误报来源。
            let hRow = LMChargeKVRow(key: "高压系统")
            hRow.update(hvText)
            views.append(hRow)
            views.append(LMUIKit.label(
                "\(LMClient.chargeFlagIDs.joined(separator: " / ")) 这 5 路信号"
                + "**不代表在充电** —— 车辆通电（READY）、开哨兵模式时它们同样会亮"
                + "（2026-10-09 用户实测）。所以现在只用来提示「高压系统在工作」，"
                + "不参与充电判定。", size: 11, color: .secondaryLabel))
            views.append(makeDivider())
            let sRow = LMChargeKVRow(key: "结论")
            sRow.update(stateText)
            views.append(sRow)
            views.append(LMUIKit.label(
                "★ 信号 1200 也不参与判断 —— 它是纯 SOC 投影，未充电时照样有值（实测 550）。"
                + "老版本拿它当状态位，误报过一次。", size: 11, color: .tertiaryLabel))
            return views
        }
    }

    private func renderGuess() {
        let v = client.chargeVoltageV
        let a = client.chargeCurrentA
        let p = client.chargePowerKW

        // 功率在最上面（用户最关心的那个数），下面两行是它的两个因子。
        if let p {
            powerRow.isHidden = false
            powerRow.update(String(format: "%.2f kW", p))
        } else {
            powerRow.isHidden = true
        }
        if let v {
            voltageRow.isHidden = false
            voltageRow.update(String(format: "%.1f V", v))
        } else {
            voltageRow.isHidden = true
        }
        if let a {
            currentRow.isHidden = false
            currentRow.update(String(format: "%.2f A", a))
        } else {
            currentRow.isHidden = true
        }
        // 两个信号都没有时，整张卡只剩标题 + 说明，那就把说明也收起来，
        // 免得用户对着一堆读不到的值发愣。
        //
        // ★ 2026-10-09：「电压有值但电流为 0」是最常见的困惑态 —— 车辆通电
        //   （READY）/ 哨兵模式下母线电压照样上报，但没插枪就没电流。
        //   必须明说「没有电流」，否则用户会以为功率读不到是坏了。
        if v != nil && a == nil {
            powerNote.isHidden = false
            powerNote.text = "读到了母线电压，但**充电电流为 0** —— 没有电进电池，"
                + "所以功率不显示。车辆通电（READY）或哨兵模式下就是这个状态，"
                + "不是读数坏了。"
        } else if v == nil && a == nil {
            powerNote.isHidden = true
        } else {
            powerNote.isHidden = false
            powerNote.text = "官方充电中心有「电压 / 电流 / 功率」三项"
                + "（本地化表 ChargingCnter_Voltage / _Current / _Power）。"
                + "车端上报的信号里只有 1177（电压）与 1178（电流）这一对量纲自洽，"
                + "功率按「电压 × 电流」现算 —— 它是派生值，不是车端直接给的数字。"
        }
    }

    // MARK: - 动作（全部走原页那套 client.xxx，参数一字不改）

    @objc private func refreshTapped() {
        Task { @MainActor [weak self] in
            await self?.refreshAll()
        }
    }

    @objc private func chargeTapped() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCharging(!self.client.isCharging)
        }
    }

    @objc private func healthSwitchChanged() {
        let on = healthSwitch.isOn
        Task { @MainActor [weak self] in
            await self?.runHealth(on)
        }
    }

    @objc private func healthReadTapped() {
        // ★ 2026-10-09 修「读取开关状态没反应」：
        //   以前这里只 `await`，既不先刷「读取中」，也不在结束后显式 render()——
        //   如果请求抛错（异常被 client 吞掉）或返回值跟上次一样，
        //   界面**一个字都不会变**，用户就得到「没反应」。
        //   现在：点下去立刻进「读取中…」态 → 等结果 → 再刷一次把结果/错误写出来。
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.render()
            _ = await self.client.refreshHealthyCharging()
            self.render()
        }
    }

    @objc private func socSliderChanged() {
        apPercent = Int(socSlider.value.rounded())
        renderSoc()
    }

    @objc private func socQuickTapped(_ sender: UIButton) {
        apPercent = sender.tag
        renderSoc()
    }

    @objc private func socApplyTapped() {
        let p = apPercent
        Task { @MainActor [weak self] in
            await self?.runSocLimit(p)
        }
    }

    @objc private func apEnableChanged() {
        apEnabled = apEnableSwitch.isOn
    }

    @objc private func apEverydayChanged() {
        apEveryDay = apEverydaySwitch.isOn
    }

    @objc private func apBeginChanged() {
        apBegin = Self.hmFormatter.string(from: apBeginPicker.date)
        renderAppointment()
    }

    @objc private func apEndChanged() {
        apEnd = Self.hmFormatter.string(from: apEndPicker.date)
        renderAppointment()
    }

    @objc private func apSaveTapped() {
        Task { @MainActor [weak self] in
            await self?.runAppointment()
        }
    }

    @objc private func reloadConfigTapped() {
        Task { @MainActor [weak self] in
            try? await self?.client.refreshCommonConfig()
        }
    }

    private func runCharging(_ active: Bool) async {
        let ok = await client.setChargingActive(active)
        showResult(ok ? (active ? "已下发「立即充电」" : "已下发「结束充电」")
                      : (client.lastError ?? "下发失败"), ok: ok)
        if ok { try? await client.refreshStatus() }
    }

    private func runHealth(_ on: Bool) async {
        let ok = await client.setHealthyCharging(on)
        showResult(ok ? (on ? "健康充电已开启" : "健康充电已关闭")
                      : (client.lastError ?? "下发失败"), ok: ok)
    }

    private func runSocLimit(_ p: Int) async {
        let ok = await client.setChargeLimit(p)
        showResult(ok ? "充电上限已下发 \(p)%" : (client.lastError ?? "下发失败"), ok: ok)
        if ok { try? await client.refreshCommonConfig() }
    }

    private func runAppointment() async {
        let ok = await client.saveAppointmentCharge(
            beginTime: apBegin,
            endTime: apEnd,
            percent: apPercent,
            enabled: apEnabled,
            cycles: apEveryDay ? "1,1,1,1,1,1,1" : "0,0,0,0,0,0,0",
            circulation: apEveryDay)
        showResult(ok ? "预约充电已保存（\(apBegin)–\(apEnd)）"
                      : (client.lastError ?? "下发失败"), ok: ok)
        if ok { try? await client.refreshCommonConfig() }
    }

    /// 下发结果用 alert 而不是一闪而过的提示 —— 这几个动作会动车的高压充电状态，
    /// 用户必须明确看到「成功 / 失败」。
    private func showResult(_ text: String, ok: Bool) {
        showAlert(title: ok ? "充电中心" : "下发失败", message: text)
    }

    private func refreshAll() async {
        try? await client.refreshStatus()
        try? await client.refreshCommonConfig()
        _ = await client.refreshHealthyCharging()
    }

    /// 用服务端下发的 `config["3"]` 回填编辑区。
    ///
    /// ★ 只在服务端有值时才覆盖 —— 服务端没配过预约时保持占位默认值，
    ///   而不是把「未设置」写成一堆 00:00 骗用户。
    private func syncAppointmentFromServer() {
        guard let s = client.chargeSchedule else { return }
        if s.beginTime != "--:--" { apBegin = s.beginTime }
        if s.endTime != "--:--" { apEnd = s.endTime }
        if let p = s.targetPercent { apPercent = min(max(p, 50), 100) }
        apEnabled = s.isEnabled
        apEveryDay = !s.weekdayFlags.isEmpty && s.weekdayFlags.allSatisfy { $0 }
    }

    // MARK: - 时钟（驱动锁定倒计时与「预计充满时刻」）

    private func startClock() {
        guard clockTimer == nil else { return }
        // ★ 用 target/selector 版而不是 block 版：block 版收的是 @Sendable 闭包，
        //   不继承 @MainActor 隔离，里面改状态可能直接编译报 actor 隔离错误。
        // ★ 必须加进 `.common` 模式：默认的 `.default` 模式下用户一拖 ScrollView
        //   计时器就停走，倒计时会卡住不动。
        let timer = Timer(timeInterval: 1, target: self,
                          selector: #selector(clockTick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    @objc private func clockTick() {
        now = Date()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startClock()
        if !didLoadConfig {
            didLoadConfig = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.client.chargeSchedule == nil {
                    try? await self.client.refreshCommonConfig()
                }
                self.syncAppointmentFromServer()
                self.render()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 离开页面就停表，避免 Timer 一直持有 self
        stopClock()
    }

    // MARK: - 小工具

    /// 行数会变的两块内容（其它配置项 / 充电判据证据行）专用：指纹没变就整块跳过。
    ///
    /// ★ 这里确实动了 `addArrangedSubview`，属于 render() 幂等约定的例外。
    ///   可以这么做的原因是这两块里**没有用户输入控件**，重建不会打断输入。
    private func rebuildIfNeeded(_ container: UIStackView,
                                 signature: String,
                                 build: () -> [UIView]) {
        let key = ObjectIdentifier(container)
        guard rebuildCache[key] != signature else { return }
        rebuildCache[key] = signature
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        build().forEach { container.addArrangedSubview($0) }
    }

    private func ringTint(_ p: Double?) -> UIColor {
        guard let p else { return .lmWarn }
        if p <= 15 { return .lmBad }
        if p <= 35 { return .lmWarn }
        return .lmGood
    }

    private func chargeStateTint(_ s: LMChargeState) -> UIColor {
        switch s {
        case .charging:    return .lmGood
        case .notCharging: return .secondaryLabel
        case .unknown:     return .lmWarn
        }
    }

    private func targetTitle() -> String {
        if let t = client.chargeTargetPercent { return "预计充至目标电量（\(t)%）" }
        return "预计充至目标电量"
    }

    private func targetShort() -> String {
        if let t = client.chargeTargetPercent { return "充到 \(t)%" }
        return "充到目标电量"
    }

    private func hoursMinutes(_ m: Int) -> String {
        if m >= 60 {
            let h = m / 60
            let mm = m % 60
            return mm == 0 ? "\(h) 小时" : "\(h) 小时 \(mm) 分"
        }
        return "\(m) 分钟"
    }

    private func fullAtText(_ m: Int) -> String {
        let d = now.addingTimeInterval(Double(m) * 60)
        return Self.hmFormatter.string(from: d)
    }

    /// 由「预计耗时 + 还差多少电量」反推每小时能充多少
    private func rateText() -> String {
        guard let m = client.chargeMinutesToTarget, m > 0,
              let soc = client.batteryPercent,
              let target = client.chargeTargetPercent, Double(target) > soc else {
            return "充电速率：数据不足"
        }
        let gap = Double(target) - soc
        let perHour = gap / (Double(m) / 60.0)
        return String(format: "折算充电速率约 %.1f ％/小时（还差 %.1f ％ ÷ %.1f 小时）",
                      perHour, gap, Double(m) / 60.0)
    }

    private func updateText() -> String {
        guard let d = client.lastUpdate else { return "尚未刷新" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "更新于 \(f.string(from: d))"
    }

    /// config["3"] 之外的配置项：按编号原样列出来。
    private func describe(_ b: LMConfigBlob) -> String {
        var parts: [String] = []
        if let mac = b.mac, !mac.isEmpty { parts.append("mac \(mac)") }
        if let v = b.version, !v.isEmpty { parts.append("version \(v)") }
        if let t = b.updateTime, !t.isEmpty { parts.append("更新于 \(t)") }
        if let p = b.percent { parts.append("percent \(p)") }
        if let e = b.isEnable { parts.append("isEnable \(e)") }
        if let bt = b.beginTime { parts.append("begin \(bt)") }
        if let et = b.endTime { parts.append("end \(et)") }
        return parts.isEmpty ? "（空）" : parts.joined(separator: " · ")
    }

    /// 1 物理像素的分隔线。用 `traitCollection.displayScale` 而不是已弃用的 `UIScreen.main`。
    private func makeDivider() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        line.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true
        return line
    }
}

// MARK: - 电量环

/// UIKit 版 `BatteryRing`：轨道 + 进度弧两层 CAShapeLayer，中间叠数字。
///
/// ★ `path` 依赖 bounds，所以**只能在 `layoutSubviews()` 里更新** ——
///   在 `init` 里算出来的话，那时 bounds 还是 .zero，环会画不出来。
///   进度用 `strokeEnd` 表达，`update` 里只改数值 + `setNeedsLayout()`。
final class LMBatteryRingView: UIView {

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let valueLabel = UILabel()
    private let percentLabel = UILabel()
    private let captionLabel = UILabel()
    private let lineWidth: CGFloat = 13
    /// 0...100
    private var clamped: Double = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for layer in [trackLayer, progressLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = lineWidth
            layer.lineCap = .round
        }
        trackLayer.strokeColor = UIColor.label.withAlphaComponent(0.08).cgColor
        progressLayer.strokeColor = UIColor.lmWarn.cgColor
        progressLayer.strokeEnd = 0
        layer.addSublayer(trackLayer)
        layer.addSublayer(progressLayer)

        valueLabel.font = .systemFont(ofSize: 36, weight: .bold)
        valueLabel.textColor = .label
        valueLabel.text = "--"
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        percentLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        percentLabel.textColor = .secondaryLabel
        percentLabel.text = "%"
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabel
        captionLabel.text = "剩余电量"
        captionLabel.textAlignment = .center

        let numRow = LMUIKit.hStack(spacing: 1, alignment: .firstBaseline)
        numRow.addArrangedSubview(valueLabel)
        numRow.addArrangedSubview(percentLabel)

        let center = LMUIKit.vStack(spacing: 1, alignment: .center)
        center.addArrangedSubview(numRow)
        center.addArrangedSubview(captionLabel)
        center.translatesAutoresizingMaskIntoConstraints = false
        center.isUserInteractionEnabled = false
        addSubview(center)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 136),
            heightAnchor.constraint(equalToConstant: 136),
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMBatteryRingView 只能代码创建")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = lineWidth / 2
        let radius = min(bounds.width, bounds.height) / 2 - inset
        guard radius > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = UIBezierPath(arcCenter: center, radius: radius,
                                startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
        // 关掉隐式动画：render() 每秒都会调，逐帧动画会闪
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.strokeEnd = CGFloat(clamped / 100)
        CATransaction.commit()
    }

    /// `progress` 是 0...100 的 SOC 百分比（nil = 还没数据）。
    func update(progress: Double?, tint: UIColor) {
        clamped = min(max(progress ?? 0, 0), 100)
        progressLayer.strokeColor = tint.cgColor
        valueLabel.text = progress == nil ? "--" : String(Int(clamped.rounded()))
        setNeedsLayout()
    }
}

// MARK: - 顶部渐变容器

/// 电量环那张卡的容器：`LMCardView` 只有纯色底，这里需要
/// `lmGood(0.16) → lmAccent2(0.04)` 的斜向渐变 + 描边。
///
/// 渐变是 `CAGradientLayer`，不参与 Auto Layout，frame 在 `layoutSubviews` 里同步。
final class LMChargeHeroView: UIView {

    let contentStack = UIStackView()
    private let gradient = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = LMRadius.hero
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.lmGood.withAlphaComponent(0.20).cgColor
        // 要裁掉渐变的直角，让圆角成立（卡片内容都在内边距里，裁不到）
        layer.masksToBounds = true

        gradient.colors = [
            UIColor.lmGood.withAlphaComponent(0.16).cgColor,
            UIColor.lmAccent2.withAlphaComponent(0.04).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradient, at: 0)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMChargeHeroView 只能代码创建")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }
}

// MARK: - 一行「图标 + 小标题 + 值」

/// 对应原 SwiftUI 里的 `infoRow(_:_:_:_:)`。
final class LMChargeInfoRow: UIView {

    private let valueLabel = UILabel()

    init(title: String, icon: String, tint: UIColor) {
        super.init(frame: .zero)

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabel

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 1

        let textCol = LMUIKit.vStack(spacing: 0, alignment: .leading)
        textCol.addArrangedSubview(titleLabel)
        textCol.addArrangedSubview(valueLabel)

        let row = LMUIKit.hStack(spacing: 8)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(textCol)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMChargeInfoRow 只能代码创建")
    }

    func update(value: String) {
        valueLabel.text = value
    }
}

// MARK: - 一行「键 —— 值」

/// 左边灰色键名，右边等宽字体值。对应原 SwiftUI 里的 `keyValue(_:_:)`。
final class LMChargeKVRow: UIView {

    private let valueLabel = UILabel()

    init(key: String, value: String = "") {
        super.init(frame: .zero)

        let keyLabel = UILabel()
        keyLabel.text = key
        keyLabel.font = .systemFont(ofSize: 12)
        keyLabel.textColor = .secondaryLabel
        keyLabel.numberOfLines = 0
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.text = value
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 0
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 12, alignment: .top)
        row.addArrangedSubview(keyLabel)
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
        fatalError("LMChargeKVRow 只能代码创建")
    }

    func update(_ v: String) {
        valueLabel.text = v
    }
}

// MARK: - 时间方块

/// 「小标题 + 大号等宽时刻」，对应原 SwiftUI 里的 `timeBox(_:_:_:)`。
final class LMChargeTimeBox: UIView {

    private let valueLabel = UILabel()

    init(title: String, tint: UIColor) {
        super.init(frame: .zero)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabel

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        valueLabel.textColor = tint
        valueLabel.text = "--:--"
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let col = LMUIKit.vStack(spacing: 2, alignment: .leading)
        col.addArrangedSubview(titleLabel)
        col.addArrangedSubview(valueLabel)
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)

        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
            col.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMChargeTimeBox 只能代码创建")
    }

    func update(_ v: String) {
        valueLabel.text = v
    }
}
