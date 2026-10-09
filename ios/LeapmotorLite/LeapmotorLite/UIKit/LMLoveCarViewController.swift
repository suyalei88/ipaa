//
//  LMLoveCarViewController.swift
//  LeapmotorLite
//
//  「爱车」页（UIKit 版）—— 对应原 `Views/LoveCarView.swift`（1121 行 SwiftUI）。
//
//  ── 这一页复刻了什么 ─────────────────────────────────────────────
//  已绑车态（本页主形态）：
//    顶部车辆栏 → 内嵌 3D 车模（可全方位拖动）→ 续航主数字 + SOC 进度条 + 门锁态
//    → 充电中心入口 → 快捷操作网格（可翻页）→ 预约充电横幅 → 车内温度 / 空调
//    → 地图卡 → 蓝牙钥匙 → 状态芯片 → 指标网格 → 原始信号
//  未绑车态：一张营销空态卡（数据来自 `LMClient`，没有硬编码假数据）。
//
//  ★ 迁移约定（与 `LMControlPanelViewController` / `LMSettingsViewController` 一致）：
//    · 只覆盖 `buildUI()` / `render()`；`render()` 幂等，条件内容用 `isHidden` 折叠
//    · 行数会变的两块（状态芯片 / 原始信号列表）用 `rebuildIfNeeded` 指纹去重
//    · 页内状态（展开态 / 分页 / 二次确认 key / 内嵌 3D 状态）**不进 `LMClient`**
//    · 只 `import UIKit`（+ CoreLocation 取 `CLLocationCoordinate2D`）—— 本轮 11 个
//      页面同时迁成 UIKit，所有 push 目标都已经是 VC，一律直接推，不再 import SwiftUI
//
//  ★★ 关于「时钟」：原页靠 `.lmClock(until:now:)` 每 0.5s 推一次 `now` 来驱动
//     操作密码锁定期的倒计时（否则锁定到期后按钮永远不会重新启用）。
//     UIKit 里没有「@State 变了就重算 body」，等价物是自己跑一个 `Timer` 定时
//     `render()`。⚠️ 必须用 target/selector 版（block 版收 @Sendable 闭包，
//     不继承 @MainActor 隔离），且 `RunLoop.main.add(_:forMode: .common)`。
//
//  ★★ 关于内嵌 3D：原页用 `.navigationDestination` 推全屏页时会**主动拆掉**
//     内嵌 WebView（一个常驻的整车模型实例上百 MB）。UIKit 里 push 不会销毁本页，
//     所以这里在打开全屏前调 `car3D.unload()`（把 WebView 导航到空白页丢掉 JS 堆），
//     返回时（`viewDidAppear`）再 `reload` 拉回来。
//
import UIKit
import CoreLocation

final class LMLoveCarViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，跟车端无关，所以不进 LMClient）

    /// 待二次确认的快捷动作 key（对应原 `@State quickConfirmKey`）
    private var quickConfirmKey: String?
    /// 「全部信号」是否展开（对应原 `@State showAllSignals`）
    private var showAllSignals = false
    /// 快捷操作当前页（对应原 `@State quickPage`）
    private var quickPage = 0
    /// 是否正在看全屏 3D —— 同时决定要不要把内嵌 WebView 拆掉
    private var showCar3DFullScreen = false

    /// 内嵌 3D 车模状态（对应原 `@State car3DStatus / car3DReady / car3DFailure`）
    private var car3DStatus = "正在启动本地 3D 服务…"
    private var car3DReady = false
    private var car3DFailure: String?

    /// toast
    private var toastText: String?
    private var toastIsError = false
    private var toastSeq = 0
    /// 上一次已提示过的 `client.lastError`，用于复刻原页 `.onChange(of: lastError)`
    private var lastSeenError: String?

    private var lockTimer: Timer?

    /// 行数会变的两块内容（状态芯片 / 原始信号）的「内容指纹」缓存。
    private var rebuildCache: [ObjectIdentifier: String] = [:]
    /// 车辆切换菜单的指纹，避免每次 render（含每 0.5s 的时钟）都重建 UIMenu。
    private var vehicleMenuSignature = ""

    // MARK: - 控件：顶部车辆栏

    private let topBar = LMUIKit.hStack(spacing: 10)
    private let vehicleNameLabel = UILabel()
    private let statusClockIcon = UIImageView()
    private let statusUpdateLabel = UILabel()
    private let heartButton = UIButton(type: .system)
    private let gearButton = UIButton(type: .system)

    // MARK: - 控件：内嵌 3D

    private let car3DContainer = UIView()
    private var car3D: LMCar3DWebView?
    private let car3DLoading = LMUIKit.vStack(spacing: 8, alignment: .center)
    private let car3DSpinner = UIActivityIndicatorView(style: .medium)
    private let car3DStatusLabel = UILabel()
    private let car3DFailureBox = LMUIKit.vStack(spacing: 8, alignment: .center)
    private let car3DFailureIcon = UIImageView()
    private let car3DFailureTitle = UILabel()
    private let car3DFailureMessage = UILabel()
    private let car3DFullScreenButton = UIButton(type: .system)
    private let car3DHintBox = UIView()

    /// 内嵌车模卡高度。★ 2026-10-08 从 230 提到 330（放大、跟背景一起）。
    private let car3DHeight: CGFloat = 330

    // MARK: - 控件：续航 hero

    /// ★ 用专用子类而不是裸 `UIView`：渐变是 `CAGradientLayer`，它不参与
    ///   Auto Layout，`frame` 必须在 `layoutSubviews` 里同步 —— 否则会停在
    ///   `.zero` 上（渐变压根看不见）。见文件末尾 `LMLoveHeroView`。
    private let rangeHero = LMLoveHeroView()
    private let rangeCaptionLabel = UILabel()
    private let rangeNumberLabel = UILabel()
    private let rangeUnitLabel = UILabel()
    private let lockPill = LMStatusPillView(text: "锁态未知",
                                            icon: "questionmark.circle",
                                            tint: .secondaryLabel)
    private let socBar = LMSOCBarView()
    private let socTextLabel = UILabel()
    private let rangeAltLabel = UILabel()

    // MARK: - 控件：充电中心入口

    private let chargeCenterChip = LMChipButton(icon: "bolt.fill",
                                                title: "充电中心",
                                                tint: .lmAccent)

    // MARK: - 控件：快捷分页

    private let pagerBox = LMUIKit.vStack(spacing: 6)
    private let pagerScroll = UIScrollView()
    private let pagerContent = UIStackView()
    private let pageControl = UIPageControl()
    private var quickButtons: [String: LMQuickButton] = [:]

    // MARK: - 控件：预约充电 / 空调 / 地图 / 蓝牙

    private let appointmentBanner = LMLoveNavCard(icon: "clock.badge.checkmark",
                                                  iconTint: .lmGood,
                                                  title: "已预约充电，请及时插枪",
                                                  subtitle: "--:-- – --:--")

    private let climateCard = LMCardView(padding: 14)
    private let interiorTempLabel = UILabel()
    private let interiorUnitLabel = UILabel()
    private let batteryTempLabel = UILabel()
    private let fanButton = LMCircleIconButton()
    private let hvacStateLabel = UILabel()
    private let tempControlButton = LMCircleIconButton()

    private let mapCard = LMCardView(padding: 14)
    private let locationMainLabel = UILabel()
    private let locationCoordLabel = UILabel()
    private let locationAgeLabel = UILabel()
    private let carShareOffNote = LMIconTextRow(
        icon: "exclamationmark.triangle.fill",
        text: "车端已关闭位置数据分享，无法获取车辆实时位置",
        tint: .lmWarn, size: 11)
    private let privacyNote = LMIconTextRow(
        icon: "eye.slash.fill",
        text: "车辆已开启位置隐私，坐标可能不是真实停车点",
        tint: .lmWarn, size: 11)
    private let hornButton = LMUIKit.plainButton("鸣笛寻车")
    private let mapsButton = LMUIKit.plainButton("打开地图")
    private let locationButton = LMUIKit.plainButton("定位页")

    private let bleCard = LMLoveNavCard(icon: "bluetooth",
                                        iconTint: .lmIndigo,
                                        title: "蓝牙钥匙",
                                        subtitle: "未同步数字钥匙")

    // MARK: - 控件：状态芯片

    private let chipsScroll = UIScrollView()
    private let chipsStack = LMUIKit.hStack(spacing: 8)

    // MARK: - 控件：指标网格

    private let metricsStack = LMUIKit.vStack(spacing: 12)
    private let batteryTile = LMMetricTileView(title: "剩余电量", value: "--",
                                               icon: "battery.75", tint: .lmGood,
                                               sub: "信号 100003")
    private let rangeTile = LMMetricTileView(title: "续航", value: "--",
                                             icon: "road.lanes", tint: .lmAccent,
                                             sub: "信号 3257")
    private let fullRangeTile = LMMetricTileView(title: "满电估算", value: "--",
                                                 icon: "battery.100.bolt", tint: .lmPurple,
                                                 sub: "3257 ÷ SOC 反推")
    private let lockTile = LMMetricTileView(title: "车锁", value: "--",
                                            icon: "lock.fill", tint: .lmGood,
                                            sub: "信号 1298 / 3262")
    private let windowTile = LMMetricTileView(title: "车窗", value: "--",
                                              icon: "window.vertical.open", tint: .lmPurple,
                                              sub: "信号 1693–1696")
    private let trunkTile = LMMetricTileView(title: "后备箱", value: "--",
                                             icon: "shippingbox", tint: .lmTeal,
                                             sub: "信号 1281")
    private let interiorTile = LMMetricTileView(title: "车内温度", value: "--",
                                                icon: "thermometer.medium", tint: .lmTeal,
                                                sub: "信号 1349")
    private let batteryTempTile = LMMetricTileView(title: "电池温度", value: "--",
                                                   icon: "thermometer.snowflake",
                                                   tint: .lmIndigo, sub: "信号 2183")
    private let odometerTile = LMMetricTileView(title: "总里程", value: "--",
                                                icon: "gauge.with.dots.needle.67percent",
                                                tint: .lmPurple, sub: "信号 1318")
    private let chargeTargetTile = LMMetricTileView(title: "距目标电量", value: "--",
                                                    icon: "hourglass", tint: .lmGood,
                                                    sub: "信号 1200 · 投影值")

    // MARK: - 控件：原始信号

    private let rawSignalsBox = LMUIKit.vStack(spacing: 10)
    private let signalsToggleButton = UIButton(type: .system)
    private let signalsCard = LMCardView(padding: 8)
    private let signalsListStack = LMUIKit.vStack(spacing: 0)
    private let signalExplorerButton = LMUIKit.plainButton("打开信号浏览器（搜索 / 快照对比）")

    // MARK: - 控件：空态 / toast / 导航栏

    private let emptyStateCard = LMCardView(padding: 24)
    private let toastContainer = UIView()
    private let toastLabel = UILabel()
    private let mainStack = LMUIKit.vStack(spacing: 16)

    private let busyIndicator = UIActivityIndicatorView(style: .medium)
    private var refreshBarItem: UIBarButtonItem?
    private var busyBarItem: UIBarButtonItem?

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "爱车"
        navigationItem.largeTitleDisplayMode = .never

        buildToolbar()

        let (scroll, stack) = makeScrollStack(spacing: 16, inset: 16)
        // ★ 写成多语句闭包（而不是单表达式 `await self?.performPullRefresh()`）：
        //   单表达式闭包会把返回类型推断成 `Void?`，跟 `() async -> Void` 对不上。
        attachRefresh(scroll) { [weak self] in
            guard let self else { return }
            await self.performPullRefresh()
        }

        stack.addArrangedSubview(mainStack)
        stack.addArrangedSubview(emptyStateCard)

        buildTopBar()
        mainStack.addArrangedSubview(topBar)

        buildCar3D()
        mainStack.addArrangedSubview(car3DContainer)

        buildRangeHero()
        mainStack.addArrangedSubview(rangeHero)

        chargeCenterChip.addTarget(self, action: #selector(chargeCenterTapped),
                                   for: .touchUpInside)
        let chipRow = LMUIKit.hStack(spacing: 0)
        chipRow.addArrangedSubview(chargeCenterChip)
        chipRow.addArrangedSubview(LMUIKit.spacer())
        mainStack.addArrangedSubview(chipRow)

        buildPager()
        mainStack.addArrangedSubview(pagerBox)

        appointmentBanner.addTarget(self, action: #selector(chargeCenterTapped),
                                    for: .touchUpInside)
        appointmentBanner.isHidden = true
        mainStack.addArrangedSubview(appointmentBanner)

        buildClimate()
        mainStack.addArrangedSubview(climateCard)

        buildMap()
        mainStack.addArrangedSubview(mapCard)

        bleCard.addTarget(self, action: #selector(bleTapped), for: .touchUpInside)
        mainStack.addArrangedSubview(bleCard)

        buildStatusChips()
        mainStack.addArrangedSubview(chipsScroll)

        buildMetrics()
        mainStack.addArrangedSubview(metricsStack)

        buildRawSignals()
        mainStack.addArrangedSubview(rawSignalsBox)

        buildEmptyState()
        buildToast()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 对应原页 `.task { if client.car3DKey == nil { await client.refreshVehicleProfile() } }`
        if client.car3DKey == nil {
            Task { @MainActor in await client.refreshVehicleProfile() }
        }
    }

    // MARK: - 顶部车辆栏

    private func buildTopBar() {
        // ★ 视觉重设计：车辆名用比例字体 22 semibold、纯白；
        //   下面的更新时间压到最弱一档色（lmText3），把层级拉出来。
        vehicleNameLabel.font = LMFont.text(22, weight: .semibold)
        vehicleNameLabel.textColor = .lmText
        vehicleNameLabel.numberOfLines = 1

        statusClockIcon.image = UIImage(systemName: "clock")
        statusClockIcon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 10)
        statusClockIcon.tintColor = .lmText3
        statusClockIcon.contentMode = .scaleAspectFit
        statusClockIcon.setContentHuggingPriority(.required, for: .horizontal)

        statusUpdateLabel.font = LMFont.text(11.5)
        statusUpdateLabel.textColor = .lmText3
        statusUpdateLabel.numberOfLines = 1

        let statusRow = LMUIKit.hStack(spacing: 5)
        statusRow.addArrangedSubview(statusClockIcon)
        statusRow.addArrangedSubview(statusUpdateLabel)
        statusRow.addArrangedSubview(LMUIKit.spacer())

        let left = LMUIKit.vStack(spacing: 3)
        left.addArrangedSubview(vehicleNameLabel)
        left.addArrangedSubview(statusRow)

        // ♡ 关注车辆 —— 官方是收藏位；本 App 没有服务端收藏位，做成「切换当前车」
        //    的入口（多车时才有意义），照原页保留 UIMenu。
        styleCircleButton(heartButton, icon: "heart", tint: .lmAccent, size: 38)
        heartButton.showsMenuAsPrimaryAction = true
        heartButton.accessibilityLabel = "切换车辆"

        // 齿轮：原页是切到「设置」Tab（设置页需要 UINavigationController 才能 push 子页）。
        // ★ 视觉重设计：齿轮从纯白降到 lmText2 —— 薄荷只留给「主操作」，
        //   两个圆形按钮都亮着会抢掉续航 Hero 的注意力。
        styleCircleButton(gearButton, icon: "gearshape", tint: .lmText2, size: 38)
        gearButton.addTarget(self, action: #selector(gearTapped), for: .touchUpInside)
        gearButton.accessibilityLabel = "设置"

        topBar.addArrangedSubview(left)
        topBar.addArrangedSubview(LMUIKit.spacer())
        topBar.addArrangedSubview(heartButton)
        topBar.addArrangedSubview(gearButton)
    }

    // MARK: - 内嵌 3D 车模

    private func buildCar3D() {
        car3DContainer.translatesAutoresizingMaskIntoConstraints = false
        car3DContainer.heightAnchor.constraint(equalToConstant: car3DHeight).isActive = true

        // ★ 视觉重设计：车底铺一团薄荷辉光，让 3D 车「落」在光上而不是悬空。
        //   `LMCar3DWebView` 内部已设 `isOpaque = false` + `backgroundColor = .clear`，
        //   所以这层辉光能从车模下面透出来。
        let pedestal = LMCar3DPedestalView()
        pedestal.translatesAutoresizingMaskIntoConstraints = false
        car3DContainer.addSubview(pedestal)

        // 当普通 UIView 加进视图树（不是 push）。
        let web = LMCar3DWebView(serverJSON: Car3DConfig.serverJSON(for: client),
                                 appJSON: Car3DConfig.appJSON(width: fallbackWidth(),
                                                              height: car3DHeight))
        web.translatesAutoresizingMaskIntoConstraints = false
        web.alpha = 0
        web.onStatus = { [weak self] s in
            self?.car3DStatus = s
            self?.renderCar3D()
        }
        web.onReady = { [weak self] in
            guard let self else { return }
            self.car3DReady = true
            self.car3DFailure = nil
            self.renderCar3D()
        }
        web.onFailure = { [weak self] m in
            guard let self else { return }
            self.car3DFailure = m
            self.car3DReady = false
            self.renderCar3D()
        }
        car3DContainer.addSubview(web)
        car3D = web
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: car3DContainer.topAnchor),
            web.leadingAnchor.constraint(equalTo: car3DContainer.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: car3DContainer.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: car3DContainer.bottomAnchor),
        ])

        // loading
        car3DSpinner.color = .secondaryLabel
        car3DStatusLabel.font = .systemFont(ofSize: 11)
        car3DStatusLabel.textColor = .secondaryLabel
        car3DStatusLabel.textAlignment = .center
        car3DStatusLabel.numberOfLines = 0
        car3DLoading.addArrangedSubview(car3DSpinner)
        car3DLoading.addArrangedSubview(car3DStatusLabel)
        car3DLoading.translatesAutoresizingMaskIntoConstraints = false
        car3DContainer.addSubview(car3DLoading)

        // 失败态
        car3DFailureIcon.image = UIImage(systemName: "cube.transparent")
        car3DFailureIcon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 26)
        car3DFailureIcon.tintColor = .secondaryLabel
        car3DFailureIcon.contentMode = .scaleAspectFit
        car3DFailureTitle.text = "3D 车模没加载起来"
        car3DFailureTitle.font = .systemFont(ofSize: 13, weight: .medium)
        car3DFailureMessage.font = .systemFont(ofSize: 11)
        car3DFailureMessage.textColor = .secondaryLabel
        car3DFailureMessage.textAlignment = .center
        car3DFailureMessage.numberOfLines = 0
        let retry = LMUIKit.plainButton("重试")
        retry.addTarget(self, action: #selector(car3DRetryTapped), for: .touchUpInside)
        car3DFailureBox.addArrangedSubview(car3DFailureIcon)
        car3DFailureBox.addArrangedSubview(car3DFailureTitle)
        car3DFailureBox.addArrangedSubview(car3DFailureMessage)
        car3DFailureBox.addArrangedSubview(retry)
        car3DFailureBox.isHidden = true
        car3DFailureBox.translatesAutoresizingMaskIntoConstraints = false
        car3DContainer.addSubview(car3DFailureBox)

        // 右上角「全屏」入口
        // ★ 视觉重设计：从「32×32 灰底圆钮」改成「图标 + 文字」的薄荷胶囊 ——
        //   原页那个纯图标按钮没有文字，第一次用的人不知道是干嘛的。
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        cfg.title = "全屏看车"
        cfg.imagePadding = 5
        cfg.baseForegroundColor = .lmAccent
        cfg.background.backgroundColor = .lmCard
        cfg.background.strokeColor = .lmCardLine
        cfg.background.strokeWidth = 1
        cfg.background.cornerRadius = 15
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11)
        cfg.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = LMFont.text(11.5, weight: .semibold)
            return out
        }
        car3DFullScreenButton.configuration = cfg
        car3DFullScreenButton.addTarget(self, action: #selector(fullScreenTapped),
                                        for: .touchUpInside)
        car3DFullScreenButton.accessibilityLabel = "全屏看车"
        car3DFullScreenButton.translatesAutoresizingMaskIntoConstraints = false
        car3DContainer.addSubview(car3DFullScreenButton)

        // 左下角操作提示胶囊
        car3DHintBox.backgroundColor = .lmCard
        car3DHintBox.layer.cornerRadius = 10
        car3DHintBox.layer.cornerCurve = .continuous
        car3DHintBox.layer.borderWidth = 1
        car3DHintBox.layer.borderColor = UIColor.lmCardLine.cgColor
        car3DHintBox.translatesAutoresizingMaskIntoConstraints = false
        let hintRow = LMIconTextRow(icon: "hand.draw",
                                    text: "单指拖动全方位旋转 · 双指缩放",
                                    tint: .lmText3, size: 11)
        hintRow.translatesAutoresizingMaskIntoConstraints = false
        car3DHintBox.addSubview(hintRow)
        car3DContainer.addSubview(car3DHintBox)

        NSLayoutConstraint.activate([
            pedestal.centerXAnchor.constraint(equalTo: car3DContainer.centerXAnchor),
            pedestal.bottomAnchor.constraint(equalTo: car3DContainer.bottomAnchor, constant: -26),
            pedestal.widthAnchor.constraint(equalToConstant: 252),
            pedestal.heightAnchor.constraint(equalToConstant: 44),

            car3DLoading.centerXAnchor.constraint(equalTo: car3DContainer.centerXAnchor),
            car3DLoading.centerYAnchor.constraint(equalTo: car3DContainer.centerYAnchor),

            car3DFailureBox.centerXAnchor.constraint(equalTo: car3DContainer.centerXAnchor),
            car3DFailureBox.centerYAnchor.constraint(equalTo: car3DContainer.centerYAnchor),
            car3DFailureBox.leadingAnchor.constraint(greaterThanOrEqualTo:
                                                        car3DContainer.leadingAnchor,
                                                     constant: 20),
            car3DFailureBox.trailingAnchor.constraint(lessThanOrEqualTo:
                                                        car3DContainer.trailingAnchor,
                                                      constant: -20),

            car3DFullScreenButton.topAnchor.constraint(equalTo: car3DContainer.topAnchor,
                                                       constant: 10),
            car3DFullScreenButton.trailingAnchor.constraint(equalTo: car3DContainer.trailingAnchor,
                                                            constant: -10),

            car3DHintBox.leadingAnchor.constraint(equalTo: car3DContainer.leadingAnchor,
                                                  constant: 10),
            car3DHintBox.bottomAnchor.constraint(equalTo: car3DContainer.bottomAnchor,
                                                 constant: -10),
            hintRow.topAnchor.constraint(equalTo: car3DHintBox.topAnchor, constant: 5),
            hintRow.bottomAnchor.constraint(equalTo: car3DHintBox.bottomAnchor, constant: -5),
            hintRow.leadingAnchor.constraint(equalTo: car3DHintBox.leadingAnchor, constant: 8),
            hintRow.trailingAnchor.constraint(equalTo: car3DHintBox.trailingAnchor,
                                              constant: -8),
        ])
    }

    // MARK: - 续航 hero

    private func buildRangeHero() {
        // ★ 视觉重设计：Hero 从「大面积蓝渐变卡」换成「实心深灰卡 + 发丝描边 +
        //   一层极淡的薄荷洗色」。薄荷是点缀色，只配铺薄薄一层 ——
        //   原来那样整块铺蓝，在这套近黑设计里会把"点缀"变成"主色"。
        rangeHero.layer.cornerRadius = LMRadius.hero
        rangeHero.layer.cornerCurve = .continuous
        rangeHero.layer.masksToBounds = true
        rangeHero.layer.borderWidth = 1
        rangeHero.layer.borderColor = UIColor.lmCardLine.cgColor
        rangeHero.backgroundColor = .lmCard

        // 渐变的 colors / 方向在 LMLoveHeroView 初始化时设好，这里只补颜色。
        rangeHero.gradient.colors = [
            UIColor.lmAccent.withAlphaComponent(0.13).cgColor,
            UIColor.lmAccent.withAlphaComponent(0.0).cgColor,
        ]

        // 主数字用等宽字体：续航数字每次刷新都在变，等宽才不会左右抖。
        rangeNumberLabel.font = LMFont.mono(54, weight: .bold)
        rangeNumberLabel.textColor = .lmText
        rangeNumberLabel.adjustsFontSizeToFitWidth = true
        rangeNumberLabel.minimumScaleFactor = 0.55
        rangeNumberLabel.numberOfLines = 1

        rangeUnitLabel.text = "km"
        rangeUnitLabel.font = LMFont.mono(15, weight: .semibold)
        rangeUnitLabel.textColor = .lmText2

        rangeCaptionLabel.text = "剩余续航"
        rangeCaptionLabel.font = LMFont.text(12, weight: .medium)
        rangeCaptionLabel.textColor = .lmText2
        rangeCaptionLabel.applyTracking(0.4)

        // 第一行：小标题 + 锁态胶囊。锁态是「当前状态」，与续航同级，放右上角。
        let captionRow = LMUIKit.hStack(spacing: 6)
        captionRow.addArrangedSubview(rangeCaptionLabel)
        captionRow.addArrangedSubview(LMUIKit.spacer())
        captionRow.addArrangedSubview(lockPill)

        // 第二行：大数字 + 单位（基线对齐）
        let numberRow = LMUIKit.hStack(spacing: 7, alignment: .lastBaseline)
        numberRow.addArrangedSubview(rangeNumberLabel)
        numberRow.addArrangedSubview(rangeUnitLabel)
        numberRow.addArrangedSubview(LMUIKit.spacer())

        socBar.translatesAutoresizingMaskIntoConstraints = false
        socBar.heightAnchor.constraint(equalToConstant: 8).isActive = true

        socTextLabel.font = LMFont.text(11.5)
        socTextLabel.textColor = .lmText2
        rangeAltLabel.font = LMFont.text(11)
        rangeAltLabel.textColor = .lmText3

        let bottom = LMUIKit.hStack(spacing: 6)
        bottom.addArrangedSubview(socTextLabel)
        bottom.addArrangedSubview(LMUIKit.spacer())
        bottom.addArrangedSubview(rangeAltLabel)

        let col = LMUIKit.vStack(spacing: 11)
        col.addArrangedSubview(captionRow)
        col.addArrangedSubview(numberRow)
        col.addArrangedSubview(socBar)
        col.addArrangedSubview(bottom)
        col.translatesAutoresizingMaskIntoConstraints = false
        rangeHero.addSubview(col)

        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: rangeHero.topAnchor, constant: 17),
            col.leadingAnchor.constraint(equalTo: rangeHero.leadingAnchor, constant: 17),
            col.trailingAnchor.constraint(equalTo: rangeHero.trailingAnchor, constant: -17),
            col.bottomAnchor.constraint(equalTo: rangeHero.bottomAnchor, constant: -17),
        ])
    }

    // MARK: - 快捷操作分页

    private func buildPager() {
        pagerScroll.isPagingEnabled = true
        pagerScroll.showsHorizontalScrollIndicator = false
        pagerScroll.delegate = self
        pagerScroll.translatesAutoresizingMaskIntoConstraints = false
        pagerScroll.heightAnchor.constraint(equalToConstant: 124).isActive = true

        pagerContent.axis = .horizontal
        pagerContent.spacing = 0
        pagerContent.alignment = .fill
        pagerContent.translatesAutoresizingMaskIntoConstraints = false
        pagerScroll.addSubview(pagerContent)

        // 官方第 1 页：解锁 / 上锁 / 后备箱 / 车窗；第 2 页：鸣笛 / 空调开 / 空调关 / 上电
        let pages: [[String]] = [
            ["lock", "unlock", "trunk_open", "window"],
            ["horn", "ac_on", "ac_off", "hello"],
        ]
        for keys in pages {
            let pageStack = LMUIKit.hStack(spacing: 8, alignment: .fill)
            pageStack.distribution = .fillEqually
            for key in keys {
                let button = LMQuickButton(key: key)
                styleQuickButton(button, key: key)
                button.addTarget(self, action: #selector(quickTapped(_:)), for: .touchUpInside)
                quickButtons[key] = button
                pageStack.addArrangedSubview(button)
            }
            pageStack.translatesAutoresizingMaskIntoConstraints = false
            pagerContent.addArrangedSubview(pageStack)
            // 每页宽度 = 可视宽度，配合 isPagingEnabled 实现整页翻动
            pageStack.widthAnchor.constraint(equalTo:
                                                pagerScroll.frameLayoutGuide.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            pagerContent.topAnchor.constraint(equalTo: pagerScroll.contentLayoutGuide.topAnchor),
            pagerContent.bottomAnchor.constraint(equalTo: pagerScroll.contentLayoutGuide.bottomAnchor),
            pagerContent.leadingAnchor.constraint(equalTo: pagerScroll.contentLayoutGuide.leadingAnchor),
            pagerContent.trailingAnchor.constraint(equalTo: pagerScroll.contentLayoutGuide.trailingAnchor),
            pagerContent.heightAnchor.constraint(equalTo: pagerScroll.frameLayoutGuide.heightAnchor),
        ])

        pageControl.numberOfPages = pages.count
        pageControl.currentPageIndicatorTintColor = .lmAccent
        pageControl.pageIndicatorTintColor = UIColor.lmAccent.withAlphaComponent(0.25)
        pageControl.addTarget(self, action: #selector(pageControlChanged), for: .valueChanged)

        pagerBox.addArrangedSubview(pagerScroll)
        pagerBox.addArrangedSubview(pageControl)
    }

    // MARK: - 车内温度 / 空调

    private func buildClimate() {
        // ★ 视觉重设计：温度改等宽字体 —— 26.0 / 26.5 这种一位小数的数字
        //   每次刷新宽度都会变，等宽之后整块不会左右抖。
        interiorTempLabel.font = LMFont.mono(30, weight: .semibold)
        interiorTempLabel.textColor = .lmText
        interiorUnitLabel.text = "℃"
        interiorUnitLabel.font = LMFont.mono(14, weight: .semibold)
        interiorUnitLabel.textColor = .lmText2

        batteryTempLabel.font = LMFont.text(11)
        batteryTempLabel.textColor = .lmText3
        batteryTempLabel.isHidden = true

        let tempTop = LMUIKit.hStack(spacing: 3, alignment: .lastBaseline)
        tempTop.addArrangedSubview(interiorTempLabel)
        tempTop.addArrangedSubview(interiorUnitLabel)

        let left = LMUIKit.vStack(spacing: 4)
        left.addArrangedSubview(tempTop)
        left.addArrangedSubview(LMUIKit.label("车内温度", size: 11, color: .lmText2))
        left.addArrangedSubview(batteryTempLabel)

        hvacStateLabel.font = LMFont.text(11)
        hvacStateLabel.textColor = .lmText2
        hvacStateLabel.textAlignment = .center
        fanButton.addTarget(self, action: #selector(fanTapped), for: .touchUpInside)
        let fanCol = LMUIKit.vStack(spacing: 6, alignment: .center)
        fanCol.addArrangedSubview(fanButton)
        fanCol.addArrangedSubview(hvacStateLabel)

        tempControlButton.addTarget(self, action: #selector(tempControlTapped),
                                    for: .touchUpInside)
        let tempControlLabel = LMUIKit.label("风量/温度", size: 11, color: .lmText2)
        tempControlLabel.textAlignment = .center
        let tcCol = LMUIKit.vStack(spacing: 6, alignment: .center)
        tcCol.addArrangedSubview(tempControlButton)
        tcCol.addArrangedSubview(tempControlLabel)

        let row = LMUIKit.hStack(spacing: 14)
        row.addArrangedSubview(left)
        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(fanCol)
        row.addArrangedSubview(tcCol)
        climateCard.contentStack.addArrangedSubview(row)
    }

    // MARK: - 地图卡

    private func buildMap() {
        let iconBox = UIView()
        iconBox.backgroundColor = UIColor.lmTeal.withAlphaComponent(0.12)
        iconBox.layer.cornerRadius = 11
        iconBox.layer.cornerCurve = .continuous
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: "mappin.and.ellipse"))
        icon.tintColor = .lmTeal
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 38),
            iconBox.heightAnchor.constraint(equalToConstant: 38),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])

        locationMainLabel.font = LMFont.text(15, weight: .semibold)
        locationMainLabel.textColor = .lmText
        locationMainLabel.numberOfLines = 1
        locationMainLabel.adjustsFontSizeToFitWidth = true
        locationMainLabel.minimumScaleFactor = 0.7

        // ★ 视觉重设计：坐标改等宽 —— 一串数字里某一位变化时，
        //   等宽字体不会让整行左右"跳"。
        locationCoordLabel.font = LMFont.mono(11)
        locationCoordLabel.textColor = .lmText3
        locationCoordLabel.numberOfLines = 1
        locationCoordLabel.adjustsFontSizeToFitWidth = true
        locationCoordLabel.minimumScaleFactor = 0.7
        locationCoordLabel.isHidden = true

        locationAgeLabel.font = LMFont.text(11)
        locationAgeLabel.textColor = .lmText3
        locationAgeLabel.isHidden = true

        let texts = LMUIKit.vStack(spacing: 3)
        texts.addArrangedSubview(LMUIKit.label("车辆位置", size: 12, weight: .semibold,
                                               color: .lmText2))
        texts.addArrangedSubview(locationMainLabel)
        texts.addArrangedSubview(locationCoordLabel)
        texts.addArrangedSubview(locationAgeLabel)

        let head = LMUIKit.hStack(spacing: 12, alignment: .top)
        head.addArrangedSubview(iconBox)
        head.addArrangedSubview(texts)
        head.addArrangedSubview(LMUIKit.spacer())

        // ★★ 2026-10-09 用户要求撤掉「当前位置（IP 归属地）」那一套，
        //    改回用车机坐标 —— 那张 `ipSourceNote`（「位置取自手机网络归属地」）
        //    一并删掉，见 `renderMap()` 的说明。
        carShareOffNote.isHidden = true
        privacyNote.isHidden = true

        styleMapButton(hornButton, icon: "speaker.wave.2.fill")
        hornButton.addTarget(self, action: #selector(hornTapped), for: .touchUpInside)
        styleMapButton(mapsButton, icon: "map")
        mapsButton.addTarget(self, action: #selector(mapsTapped), for: .touchUpInside)
        styleMapButton(locationButton, icon: "location.fill")
        locationButton.addTarget(self, action: #selector(locationTapped), for: .touchUpInside)

        let buttons = LMUIKit.hStack(spacing: 10, alignment: .fill)
        buttons.distribution = .fillEqually
        buttons.addArrangedSubview(hornButton)
        buttons.addArrangedSubview(mapsButton)
        buttons.addArrangedSubview(locationButton)

        mapCard.contentStack.addArrangedSubview(head)
        mapCard.contentStack.addArrangedSubview(carShareOffNote)
        mapCard.contentStack.addArrangedSubview(privacyNote)
        mapCard.contentStack.addArrangedSubview(buttons)
    }

    // MARK: - 状态芯片（横向滚动）

    private func buildStatusChips() {
        chipsScroll.showsHorizontalScrollIndicator = false
        chipsScroll.translatesAutoresizingMaskIntoConstraints = false
        // ★ 横向 ScrollView 没有 intrinsic 高度，必须显式给一个高度，
        //   否则它会塌成 0（不能反过来把内容高度绑到 frame 高度 —— 那是循环约束）。
        chipsScroll.heightAnchor.constraint(equalToConstant: 28).isActive = true
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsScroll.addSubview(chipsStack)
        // 内容高度由胶囊自身的 intrinsic 高度决定；只把四边钉到 contentLayoutGuide。
        NSLayoutConstraint.activate([
            chipsStack.topAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.topAnchor),
            chipsStack.bottomAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.bottomAnchor),
            chipsStack.leadingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.leadingAnchor,
                                                constant: 2),
            chipsStack.trailingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.trailingAnchor,
                                                 constant: -2),
        ])
    }

    // MARK: - 指标网格（固定 10 格，一次建好）

    private func buildMetrics() {
        // 原页是 `LazyVGrid` 两列。这里用「固定 2 列的横排 StackView」等价复现。
        let rows: [[LMMetricTileView]] = [
            [batteryTile, rangeTile],
            [fullRangeTile, lockTile],
            [windowTile, trunkTile],
            [interiorTile, batteryTempTile],
            [odometerTile, chargeTargetTile],
        ]
        for row in rows {
            let h = LMUIKit.hStack(spacing: 12, alignment: .fill)
            h.distribution = .fillEqually
            row.forEach { h.addArrangedSubview($0) }
            metricsStack.addArrangedSubview(h)
        }
    }

    // MARK: - 原始信号（可验证区）

    private func buildRawSignals() {
        signalsToggleButton.setTitle("全部信号（0）", for: .normal)
        signalsToggleButton.setTitleColor(.lmText2, for: .normal)
        signalsToggleButton.titleLabel?.font = LMFont.text(13, weight: .semibold)
        signalsToggleButton.tintColor = .lmText3
        signalsToggleButton.contentHorizontalAlignment = .leading
        // 让 image 落到标题右侧（对应原页的「标题 + 上下箭头」）
        signalsToggleButton.semanticContentAttribute = .forceRightToLeft
        signalsToggleButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        signalsToggleButton.addTarget(self, action: #selector(signalsToggleTapped),
                                      for: .touchUpInside)

        signalsCard.contentStack.addArrangedSubview(signalsListStack)
        signalsCard.isHidden = true

        signalExplorerButton.configuration?.image =
            UIImage(systemName: "magnifyingglass.circle")
        signalExplorerButton.configuration?.imagePadding = 6
        signalExplorerButton.addTarget(self, action: #selector(signalExplorerTapped),
                                       for: .touchUpInside)
        signalExplorerButton.isHidden = true

        rawSignalsBox.addArrangedSubview(signalsToggleButton)
        rawSignalsBox.addArrangedSubview(signalsCard)
        rawSignalsBox.addArrangedSubview(signalExplorerButton)
    }

    // MARK: - 空态 / toast / 导航栏

    private func buildEmptyState() {
        let icon = UIImageView(image: UIImage(systemName: "car"))
        icon.tintColor = .lmAccent
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34)

        let titleLabel = LMUIKit.label("还没有车辆", size: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        let hint = LMUIKit.label("下拉刷新，或到「设置」检查登录态", size: 13,
                                 color: .secondaryLabel)
        hint.textAlignment = .center

        let refresh = LMUIKit.primaryButton("立即刷新")
        refresh.addTarget(self, action: #selector(emptyRefreshTapped), for: .touchUpInside)

        let col = LMUIKit.vStack(spacing: 10, alignment: .center)
        col.addArrangedSubview(icon)
        col.addArrangedSubview(titleLabel)
        col.addArrangedSubview(hint)
        col.addArrangedSubview(refresh)
        emptyStateCard.contentStack.addArrangedSubview(col)
        emptyStateCard.isHidden = true
    }

    private func buildToast() {
        // ★ 视觉重设计：toast 用实心薄荷/红底 + **近黑文字**（原来是白字）。
        //   薄荷底上白字对比度只有 1.5:1，基本看不清；近黑字有 12:1。
        toastContainer.layer.cornerRadius = 12
        toastContainer.layer.cornerCurve = .continuous
        toastContainer.layer.shadowColor = UIColor.black.cgColor
        toastContainer.layer.shadowRadius = 16
        toastContainer.layer.shadowOffset = CGSize(width: 0, height: 6)
        toastContainer.layer.shadowOpacity = 0.5
        toastContainer.isHidden = true
        toastContainer.translatesAutoresizingMaskIntoConstraints = false

        toastLabel.font = LMFont.text(13, weight: .semibold)
        toastLabel.textColor = .lmCanvas
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastContainer.addSubview(toastLabel)

        // toast 挂在 `view`（不是 scroll）上，浮在内容之上，底部对齐安全区。
        view.addSubview(toastContainer)

        NSLayoutConstraint.activate([
            toastLabel.topAnchor.constraint(equalTo: toastContainer.topAnchor, constant: 10),
            toastLabel.bottomAnchor.constraint(equalTo: toastContainer.bottomAnchor, constant: -10),
            toastLabel.leadingAnchor.constraint(equalTo: toastContainer.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastContainer.trailingAnchor,
                                                 constant: -14),

            toastContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                   constant: -24),
            toastContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor,
                                                    constant: 24),
            toastContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor,
                                                     constant: -24),
        ])
    }

    private func buildToolbar() {
        let refresh = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"),
                                      style: .plain, target: self,
                                      action: #selector(refreshTapped))
        refresh.accessibilityLabel = "刷新车况"
        refreshBarItem = refresh

        busyIndicator.color = .lmAccent
        busyBarItem = UIBarButtonItem(customView: busyIndicator)
        navigationItem.rightBarButtonItem = refresh
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        let hasVehicle = client.selectedVehicle != nil
        mainStack.isHidden = !hasVehicle
        emptyStateCard.isHidden = hasVehicle

        renderTopBar()
        renderRangeHero()
        renderCar3D()
        renderAppointment()
        renderClimate()
        renderMap()
        renderBLE()
        renderStatusChips()
        renderMetrics()
        renderRawSignals()
        renderToolbar()
        renderErrorToastIfNeeded()
        updateControlAvailability()
    }

    private func renderTopBar() {
        guard let v = client.selectedVehicle else { return }
        vehicleNameLabel.text = v.displayName
        statusUpdateLabel.text = statusUpdateText

        let multi = client.vehicles.count > 1
        heartButton.isHidden = !multi
        guard multi else { return }

        // 只在车辆集合变化时重建菜单（render 可能每 0.5s 被时钟调一次）。
        let sig = client.vehicles.map { "\($0.vin):\($0.displayName)" }.joined(separator: "|")
            + "|" + v.vin
        guard vehicleMenuSignature != sig else { return }
        vehicleMenuSignature = sig

        // ★ UIAction 的 handler 是非隔离闭包，里面读 `self.client`（@MainActor）
        //   会报隔离错误，所以统一用 `Task { @MainActor in }` 跳一轮。
        heartButton.menu = UIMenu(children: client.vehicles.map { veh in
            UIAction(title: veh.displayName,
                     image: UIImage(systemName: veh.vin == v.vin ? "checkmark" : "car")) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.client.select(vehicle: veh)
                    await self.client.refreshAll()
                }
            }
        })
    }

    private func renderRangeHero() {
        rangeNumberLabel.text = rangeNumberText
        if let locked = client.isLocked {
            lockPill.update(text: locked ? "车门已锁" : "车门未锁",
                            icon: locked ? "lock.fill" : "lock.open.fill",
                            tint: locked ? .lmGood : .lmBad)
        } else {
            lockPill.update(text: "锁态未知", icon: "questionmark.circle",
                            tint: .secondaryLabel)
        }
        socBar.set(fraction: socFraction, tint: socTint)
        socTextLabel.text = "剩余电量 \(socText)"
        if let alt = client.rangeAltKm {
            rangeAltLabel.isHidden = false
            rangeAltLabel.text = "另一标准 \(Int(alt.rounded())) km"
        } else {
            rangeAltLabel.isHidden = true
        }
    }

    private func renderCar3D() {
        guard let car3D = car3D else { return }
        if showCar3DFullScreen {
            // 全屏页开着：内嵌这个拆掉，避免两份车模同时在内存里（见文件头注释）
            car3D.isHidden = true
            car3DLoading.isHidden = true
            car3DFailureBox.isHidden = true
            return
        }
        car3D.isHidden = false
        // 宽度取真实布局宽度；拿不到时退回窗口宽度（`UIScreen.main` 已弃用）。
        let w = car3DContainer.bounds.width > 1 ? car3DContainer.bounds.width : fallbackWidth()
        car3D.update(serverJSON: Car3DConfig.serverJSON(for: client),
                     appJSON: Car3DConfig.appJSON(width: w, height: car3DHeight))
        car3D.alpha = car3DReady ? 1 : 0

        car3DStatusLabel.text = car3DStatus
        if car3DReady { car3DSpinner.stopAnimating() } else { car3DSpinner.startAnimating() }
        car3DLoading.isHidden = car3DReady || car3DFailure != nil
        car3DFailureBox.isHidden = (car3DFailure == nil)
        if let car3DFailure = car3DFailure { car3DFailureMessage.text = car3DFailure }
    }

    private func renderAppointment() {
        let enabled = client.chargeSchedule?.isEnabled == true
        appointmentBanner.isHidden = !enabled
        if enabled {
            appointmentBanner.update(icon: "clock.badge.checkmark", tint: .lmGood,
                                     title: "已预约充电，请及时插枪",
                                     subtitle: appointmentTimeText)
        }
    }

    private func renderClimate() {
        interiorTempLabel.text = interiorTempText
        if let bt = client.batteryTemp {
            batteryTempLabel.isHidden = false
            batteryTempLabel.text = String(format: "电池温度 %.1f ℃", bt)
        } else {
            batteryTempLabel.isHidden = true
        }
        let on = client.hvacOn == true
        fanButton.update(icon: on ? "fanblades.fill" : "fanblades",
                         tint: on ? .lmAccent : .lmText2,
                         bg: on ? UIColor.lmAccent.withAlphaComponent(0.16) : .lmCard)
        hvacStateLabel.text = hvacStateText
    }

    private func renderMap() {
        // ★★ 2026-10-09：改回**车机坐标**（用户要求撤掉 IP 归属地那一套）。
        //    原来这里优先显示 `client.ipAddress.regionText`（手机网络的归属地），
        //    那是「服务端认为手机连的网在哪」，不是车在哪 —— 只精确到城市，
        //    还会被 WiFi 专线 / 代理 / 热点带到别的城市。
        if let c = client.coordinate {
            locationMainLabel.text = String(format: "%.5f, %.5f", c.latitude, c.longitude)
            locationCoordLabel.isHidden = false
            locationCoordLabel.text = "车机信号 2190 / 2191"
        } else {
            locationMainLabel.text = "暂无车辆坐标"
            locationCoordLabel.isHidden = true
        }

        if let age = client.locationAge {
            locationAgeLabel.isHidden = false
            locationAgeLabel.text = ageText(age)
        } else {
            locationAgeLabel.isHidden = true
        }

        carShareOffNote.isHidden = !client.carLocationShareOff
        privacyNote.isHidden = !client.locationMayBeHidden

        mapsButton.isEnabled = (client.coordinate != nil)
    }

    private func renderBLE() {
        bleCard.update(icon: "bluetooth", tint: .lmIndigo,
                       title: "蓝牙钥匙", subtitle: bleSubtitle)
    }

    private func renderStatusChips() {
        // 指纹：任一判据变了才重建（芯片数量 / 文案会变）。
        let sig = [
            client.chargeState.text,
            client.isLocked.map { $0 ? "1" : "0" } ?? "-",
            client.windowOpeningText ?? "-",
            client.hvacOn.map { $0 ? "1" : "0" } ?? "-",
            client.coordinate == nil ? "noloc" : "loc",
            client.locationMayBeHidden ? "priv" : "-",
        ].joined(separator: "|")

        rebuildIfNeeded(chipsStack, signature: sig) {
            var views: [UIView] = []
            views.append(LMStatusPillView(text: client.chargeState.text,
                                          icon: client.chargeState.icon,
                                          tint: chargeTint(client.chargeState)))
            if let locked = client.isLocked {
                views.append(LMStatusPillView(text: locked ? "车门已锁" : "车门未锁",
                                              icon: locked ? "lock.fill" : "lock.open.fill",
                                              tint: locked ? .lmGood : .lmBad))
            }
            if let w = client.windowOpeningText {
                views.append(LMStatusPillView(text: w, icon: "window.vertical.open",
                                              tint: .lmPurple))
            }
            if let h = client.hvacOn {
                views.append(LMStatusPillView(text: h ? "空调开" : "空调关",
                                              icon: h ? "fanblades.fill" : "fanblades.slash",
                                              tint: h ? .lmAccent : .secondaryLabel))
            }
            if client.coordinate == nil {
                views.append(LMStatusPillView(text: "无定位", icon: "location.slash",
                                              tint: .lmWarn))
            }
            if client.locationMayBeHidden {
                views.append(LMStatusPillView(text: "位置隐私已开",
                                              icon: "eye.slash.fill", tint: .lmWarn))
            }
            return views
        }
    }

    private func renderMetrics() {
        batteryTile.update(value: client.batteryPercent.map { "\(Int($0.rounded())) %" } ?? "--",
                           sub: "信号 100003")
        rangeTile.update(value: client.rangeKm.map { "\(Int($0.rounded())) km" } ?? "--",
                         sub: client.rangeAltKm.map { "另一标准 \(Int($0.rounded())) km" }
                              ?? "信号 3257")
        fullRangeTile.update(value: client.fullRangeEstimateKm.map { "\(Int($0.rounded())) km" } ?? "--",
                             sub: "3257 ÷ SOC 反推")
        lockTile.update(value: client.isLocked == nil ? "--"
                              : (client.isLocked == true ? "已上锁" : "未上锁"),
                        sub: "信号 1298 / 3262")
        windowTile.update(value: client.windowOpeningText ?? "--", sub: "信号 1693–1696")
        trunkTile.update(value: client.signalNumber("1281").map { $0 >= 0.5 ? "开" : "关" } ?? "--",
                         sub: "信号 1281")
        interiorTile.update(value: client.interiorTemp.map { String(format: "%.1f ℃", $0) } ?? "--",
                            sub: "信号 1349")
        batteryTempTile.update(value: client.batteryTemp.map { String(format: "%.1f ℃", $0) } ?? "--",
                               sub: "信号 2183")
        odometerTile.update(value: client.odometerKm.map { "\(Int($0.rounded())) km" } ?? "--",
                            sub: "信号 1318")
        chargeTargetTile.update(value: client.chargeMinutesToTarget.map { shortMinutes($0) } ?? "--",
                                sub: "信号 1200 · 投影值")
    }

    private func renderRawSignals() {
        signalsToggleButton.setTitle("全部信号（\(client.signals.count)）", for: .normal)
        signalsToggleButton.setImage(
            UIImage(systemName: showAllSignals ? "chevron.up" : "chevron.down"), for: .normal)
        signalsCard.isHidden = !showAllSignals
        signalExplorerButton.isHidden = !showAllSignals
        guard showAllSignals else { return }

        let keys = sortedSignalKeys
        let sig = keys.map { "\($0)=\(client.signalText($0))" }.joined(separator: "\u{1}")
        rebuildIfNeeded(signalsListStack, signature: sig) {
            var views: [UIView] = []
            for (i, k) in keys.enumerated() {
                views.append(makeSignalRow(k))
                if i < keys.count - 1 { views.append(makeSeparator()) }
            }
            return views
        }
    }

    private func renderToolbar() {
        if client.isBusy {
            busyIndicator.startAnimating()
            navigationItem.rightBarButtonItem = busyBarItem
        } else {
            busyIndicator.stopAnimating()
            navigationItem.rightBarButtonItem = refreshBarItem
        }
    }

    /// 复刻原页 `.onChange(of: client.lastError)`：值变了且非空才提示一次。
    private func renderErrorToastIfNeeded() {
        let e = client.lastError
        if e != lastSeenError {
            lastSeenError = e
            if let e { showToast(e, isError: true) }
        }
    }

    /// 车控按钮的可用性（受 isBusy / 操作密码锁定影响）。时钟每 0.5s 也会调它，
    /// 这样锁定到期后按钮能自动重新启用。
    private func updateControlAvailability() {
        let disabled = client.isBusy || client.isControlLocked()
        quickButtons.values.forEach { $0.isEnabled = !disabled }
        fanButton.isEnabled = !disabled
        hornButton.isEnabled = !disabled
    }

    // MARK: - 时钟（驱动操作密码锁定期倒计时）

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startLockTimer()
        // 从全屏 3D 页返回：把之前 unload 掉的内嵌车模拉回来。
        if showCar3DFullScreen {
            showCar3DFullScreen = false
            car3DReady = false
            car3DFailure = nil
            car3DStatus = "正在重新加载车模…"
            reloadCar3D()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 离开页面就停表，避免 Timer 一直持有 self
        lockTimer?.invalidate()
        lockTimer = nil
    }

    private func startLockTimer() {
        guard lockTimer == nil else { return }
        // ★ target/selector 版（不是 block 版）：block 版收 @Sendable 闭包，
        //   不继承 @MainActor 隔离，在回调里改状态会编译报隔离错误。
        // ★ `.common` 模式：默认 `.default` 下用户一拖 ScrollView 计时器就停走。
        let timer = Timer(timeInterval: 0.5, target: self,
                          selector: #selector(lockTick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        lockTimer = timer
    }

    @objc private func lockTick() {
        render()
    }

    // MARK: - 动作

    @objc private func refreshTapped() {
        Task { @MainActor in await client.refreshAll() }
    }

    @objc private func emptyRefreshTapped() {
        Task { @MainActor in await client.refreshAll() }
    }

    @objc private func gearTapped() {
        // 保留原页行为：发通知让 `LMMainTabBarController` 切到「设置」Tab。
        NotificationCenter.default.post(name: .lmSelectSettingsTab, object: nil)
    }

    @objc private func chargeCenterTapped() {
        navigationController?.pushViewController(
            LMChargeViewController(client: client), animated: true)
    }

    @objc private func bleTapped() {
        navigationController?.pushViewController(
            LMBLEKeyViewController(client: client), animated: true)
    }

    @objc private func tempControlTapped() {
        navigationController?.pushViewController(
            LMControlPanelViewController(client: client), animated: true)
    }

    @objc private func locationTapped() {
        navigationController?.pushViewController(
            LMLocationViewController(client: client), animated: true)
    }

    @objc private func signalExplorerTapped() {
        navigationController?.pushViewController(
            LMSignalExplorerViewController(client: client), animated: true)
    }

    @objc private func fullScreenTapped() {
        // 先复位 + 拆内嵌，再跳全屏：返回时这里会用 reload 重建一个干净的车模。
        showCar3DFullScreen = true
        car3DReady = false
        car3DStatus = "正在重新加载车模…"
        car3D?.unload()
        renderCar3D()
        navigationController?.pushViewController(
            LMCar3DViewController(client: client), animated: true)
    }

    @objc private func car3DRetryTapped() {
        car3DFailure = nil
        car3DReady = false
        car3DStatus = "正在重新加载…"
        reloadCar3D()
    }

    @objc private func hornTapped() {
        quickConfirmKey = "horn"
        presentQuickConfirm()
    }

    @objc private func fanTapped() {
        quickConfirmKey = (client.hvacOn == true) ? "ac_off" : "ac_on"
        presentQuickConfirm()
    }

    @objc private func mapsTapped() {
        openInMaps()
    }

    @objc private func signalsToggleTapped() {
        showAllSignals.toggle()
        renderRawSignals()
    }

    @objc private func quickTapped(_ sender: LMQuickButton) {
        if sender.key == "window" {
            presentWindowSheet()
        } else {
            quickConfirmKey = sender.key
            presentQuickConfirm()
        }
    }

    @objc private func pageControlChanged() {
        guard pagerScroll.bounds.width > 0 else { return }
        quickPage = pageControl.currentPage
        let x = CGFloat(quickPage) * pagerScroll.bounds.width
        pagerScroll.setContentOffset(CGPoint(x: x, y: 0), animated: true)
    }

    // MARK: - 业务链路（一个都不能少）

    /// 快捷操作：和车控页走同一条链路（含业务码 70 锁定提示）。
    private func runQuick(key: String) async {
        if client.isControlLocked() {
            showToast("操作密码被锁定，请 \(client.controlLockRemaining()) 秒后再试", isError: true)
            return
        }
        guard let cmd = LMEndpoints.commands[key] else { return }
        let ok = await client.control(key)
        showToast(ok ? "\(cmd.title) 成功" : (client.lastError ?? "\(cmd.title) 失败"), isError: !ok)
        if ok { try? await client.refreshStatus() }
    }

    /// 车窗：官方是一个按钮弹三个开度，走同一个 cmdid 230。
    private func runWindow(_ opening: LMEndpoints.WindowOpening) async {
        if client.isControlLocked() {
            showToast("操作密码被锁定，请 \(client.controlLockRemaining()) 秒后再试", isError: true)
            return
        }
        let ok = await client.controlRaw(cmdid: LMEndpoints.windowCmdid,
                                         state: LMEndpoints.windowState(opening),
                                         label: "车窗\(opening.title)")
        showToast(ok ? "车窗\(opening.title) 已下发"
                     : (client.lastError ?? "车窗\(opening.title) 失败"),
                  isError: !ok)
        if ok { try? await client.refreshStatus() }
    }

    /// 下拉刷新：整页刷新车况。
    private func performPullRefresh() async {
        await client.refreshAll()
    }

    // MARK: - 二次确认 / toast

    private func presentQuickConfirm() {
        presentConfirm(title: quickConfirmTitle, message: quickConfirmMessage) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let k = self.quickConfirmKey
                self.quickConfirmKey = nil
                if let k { await self.runQuick(key: k) }
            }
        }
    }

    private func presentWindowSheet() {
        let alert = UIAlertController(title: "车窗开度", message: windowSheetMessage,
                                      preferredStyle: .alert)
        for op in LMEndpoints.WindowOpening.allCases {
            alert.addAction(UIAlertAction(title: op.title, style: .default) { [weak self] _ in
                Task { @MainActor in await self?.runWindow(op) }
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

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

    private func showToast(_ text: String, isError: Bool) {
        toastIsError = isError
        toastText = text
        toastSeq += 1
        let seq = toastSeq
        applyToast()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 只有「还是同一条 toast」才清掉，避免后一条被前一条的定时器提前抹掉
            if self.toastSeq == seq {
                self.toastText = nil
                self.applyToast()
            }
        }
    }

    private func applyToast() {
        guard let text = toastText else {
            toastContainer.isHidden = true
            return
        }
        toastContainer.isHidden = false
        toastLabel.text = text
        toastContainer.backgroundColor = toastIsError ? .lmBad : .lmGood
    }

    // MARK: - 小工具

    private func styleCircleButton(_ button: UIButton, icon: String, tint: UIColor, size: CGFloat) {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: icon)
        cfg.baseForegroundColor = tint
        // ★ 视觉重设计：卡片底 + 发丝描边（近黑底上没描边的圆钮会「飘」）
        cfg.background.backgroundColor = .lmCard
        cfg.background.strokeColor = .lmCardLine
        cfg.background.strokeWidth = 1
        cfg.background.cornerRadius = size / 2
        cfg.contentInsets = .zero
        button.configuration = cfg
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
    }

    private func styleMapButton(_ button: UIButton, icon: String) {
        button.configuration?.image = UIImage(systemName: icon)
        button.configuration?.imagePadding = 6
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8,
                                                                     bottom: 10, trailing: 8)
    }

    private func styleQuickButton(_ button: LMQuickButton, key: String) {
        let isWindow = (key == "window")
        let cmd = LMEndpoints.commands[key]
        let title = isWindow ? "车窗" : (cmd?.title ?? key)
        let icon = isWindow ? "window.vertical.open" : (cmd?.systemImage ?? "questionmark")
        button.update(icon: icon, tint: quickTint(for: key), title: title)
    }

    /// 按 **actionKey** 判色（不是按 cmdid —— cmdid 的语义被整体纠正过一次，
    /// 按它判色会跟着一起错，这个坑上一轮踩过）。
    private func quickTint(for key: String) -> UIColor {
        switch key {
        case "lock":         return .lmGood
        case "unlock":       return .lmWarn
        case "trunk_open", "trunk_close": return .lmTeal
        case "horn":         return .lmIndigo
        case "window", "window_micro", "window_half", "window_close": return .lmPurple
        case "ac_on":        return .lmAccent
        case "ac_off":       return .lmAccent2
        case "hello":        return .lmBad
        default:             return .lmIndigo
        }
    }

    private func chargeTint(_ s: LMChargeState) -> UIColor {
        switch s {
        case .charging:    return .lmGood
        case .notCharging: return .secondaryLabel
        case .unknown:     return .lmWarn
        }
    }

    private func makeSignalRow(_ k: String) -> UIView {
        let keyLabel = UILabel()
        keyLabel.text = k
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        keyLabel.textColor = .secondaryLabel
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 8)
        row.addArrangedSubview(keyLabel)

        if let r = LMSignalCatalog.ref(k) {
            let nameLabel = UILabel()
            nameLabel.text = r.name
            nameLabel.font = .systemFont(ofSize: 11)
            nameLabel.textColor = .tertiaryLabel
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(nameLabel)
        }

        let valueLabel = UILabel()
        valueLabel.text = client.signalText(k)
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textAlignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(valueLabel)
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        return row
    }

    /// 1 物理像素的分隔线。用 `traitCollection.displayScale`（`UIScreen.main` 已弃用）。
    private func makeSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        line.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true
        return line
    }

    /// 行数会变的内容（状态芯片 / 原始信号）专用：指纹没变就整块跳过。
    /// ★ 这是 `render()` 幂等约定的例外 —— 可以重建的前提是这块里
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

    /// 内嵌车模的宽度：布局前 `car3DContainer.bounds` 可能是 0，退回窗口宽度。
    private func fallbackWidth() -> CGFloat {
        let w = view.bounds.width
        if w > 1 { return w }
        return view.window?.bounds.width ?? 393
    }

    private func reloadCar3D() {
        let w = car3DContainer.bounds.width > 1 ? car3DContainer.bounds.width : fallbackWidth()
        car3D?.reload(serverJSON: Car3DConfig.serverJSON(for: client),
                      appJSON: Car3DConfig.appJSON(width: w, height: car3DHeight))
        render()
    }

    private func openInMaps() {
        // ★★ 2026-10-09：改回按**车机坐标**导航（用户要求撤掉 IP 归属地那一套）。
        //   ⚠️ 已知限制：车机坐标实测可能长期不变（60 个抓包样本里一个数字都没动过），
        //      所以它不一定等于车**现在**停的地方 —— 完整说明在「车辆定位」页底部。
        guard let c = client.coordinate else { return }
        if let url = URL(string: "https://maps.apple.com/?ll=\(c.latitude),\(c.longitude)&q=我的车&z=17") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 文案

    private var rangeNumberText: String {
        guard let km = client.rangeKm else { return "--" }
        return "\(Int(km.rounded()))"
    }

    private var socText: String {
        guard let p = client.batteryPercent else { return "--" }
        return "\(Int(p.rounded()))%"
    }

    private var socFraction: CGFloat {
        guard let p = client.batteryPercent else { return 0 }
        return CGFloat(min(max(p / 100.0, 0), 1))
    }

    private var socTint: UIColor {
        guard let p = client.batteryPercent else { return .lmWarn }
        if p <= 15 { return .lmBad }
        if p <= 35 { return .lmWarn }
        return .lmGood
    }

    private var interiorTempText: String {
        guard let t = client.interiorTemp else { return "--" }
        return String(format: "%.1f", t)
    }

    private var hvacStateText: String {
        switch client.hvacOn {
        case .some(true):  return "空调开"
        case .some(false): return "空调关"
        case .none:        return "空调--"
        }
    }

    private var bleSubtitle: String {
        guard let record = client.bleKeyRecord else { return "未同步数字钥匙" }
        return "已绑定 · \(record.macPretty) · 协议 \(record.versionText)"
    }

    private var appointmentTimeText: String {
        guard let s = client.chargeSchedule else { return "--:-- – --:--" }
        var parts = ["\(s.beginTime)–\(s.endTime)"]
        if let t = s.targetPercent { parts.append("充至 \(t)%") }
        if s.weekdayText != "未选择" { parts.append(s.weekdayText) }
        return parts.joined(separator: " · ")
    }

    private var statusUpdateText: String {
        guard let d = client.lastUpdate else { return "尚未刷新" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "状态更新 今天 \(f.string(from: d))" }
        if cal.isDateInYesterday(d) { return "状态更新 昨天 \(f.string(from: d))" }
        f.dateFormat = "M月d日 HH:mm"
        return "状态更新 \(f.string(from: d))"
    }

    private func shortMinutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h\(m % 60)m" : "\(m)m"
    }

    private func ageText(_ age: TimeInterval) -> String {
        if age < 60 { return "刚刚采集" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前采集" }
        if age < 86400 { return "\(Int(age / 3600)) 小时前采集" }
        return "\(Int(age / 86400)) 天前采集"
    }

    private var sortedSignalKeys: [String] {
        client.signals.keys.sorted { a, b in
            LMSignalCatalog.numeric(a) < LMSignalCatalog.numeric(b)
        }
    }

    // MARK: - 二次确认文案

    private var quickConfirmTitle: String {
        guard let k = quickConfirmKey, let cmd = LMEndpoints.commands[k] else {
            return "确认下发车控指令？"
        }
        return "确认执行「\(cmd.title)」？"
    }

    private var quickConfirmMessage: String {
        guard let k = quickConfirmKey, let cmd = LMEndpoints.commands[k] else {
            return "将向车辆下发一次真实指令。"
        }
        if cmd.risk == .physical {
            return "cmdid \(cmd.cmdid) 会真的动车门 / 后备箱 / 上电。"
                + "请确认车辆周围安全、车门和后备箱附近没有人，再执行。"
        }
        return "cmdid \(cmd.cmdid)，只改状态（空调），不会夹到人。"
    }

    private var windowSheetMessage: String {
        if let t = client.windowOpeningText {
            return "当前上报：\(t)。cmdid \(LMEndpoints.windowCmdid) 会让四个车窗一起动。"
        }
        return "cmdid \(LMEndpoints.windowCmdid) 会让四个车窗一起动，请确认车窗附近没有人。"
    }
}

// MARK: - 快捷分页：滚动联动页码

extension LMLoveCarViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pagerScroll, pagerScroll.bounds.width > 0 else { return }
        let page = Int((scrollView.contentOffset.x / pagerScroll.bounds.width).rounded())
        if pageControl.currentPage != page {
            pageControl.currentPage = page
            quickPage = page
        }
    }
}

// MARK: - 快捷操作按钮

/// 圆形图标 + 标题。对应原 SwiftUI `quickButton(_:)`。
private final class LMQuickButton: UIControl {

    let key: String

    private let iconCircle = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    init(key: String) {
        self.key = key
        super.init(frame: .zero)

        // ★ 视觉重设计：从「圆 + 56pt 玻璃底 + 淡描边」改成「圆角方形 + 卡片底 +
        //   主色描边」。圆角方形是这套设计里区分「可点操作」与「状态图标」的记号 ——
        //   圆形在这套语言里表示状态（锁态胶囊、SOC 环）。
        iconCircle.layer.cornerRadius = 17
        iconCircle.layer.cornerCurve = .continuous
        iconCircle.layer.borderWidth = 1
        iconCircle.translatesAutoresizingMaskIntoConstraints = false

        iconView.contentMode = .center
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconCircle.addSubview(iconView)

        titleLabel.font = LMFont.text(11.5, weight: .medium)
        titleLabel.textColor = .lmText2
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75

        let col = LMUIKit.vStack(spacing: 7, alignment: .center)
        col.addArrangedSubview(iconCircle)
        col.addArrangedSubview(titleLabel)
        col.isUserInteractionEnabled = false
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)

        NSLayoutConstraint.activate([
            iconCircle.widthAnchor.constraint(equalToConstant: 56),
            iconCircle.heightAnchor.constraint(equalToConstant: 56),
            iconView.centerXAnchor.constraint(equalTo: iconCircle.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconCircle.centerYAnchor),

            col.topAnchor.constraint(equalTo: topAnchor),
            col.bottomAnchor.constraint(equalTo: bottomAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMQuickButton 只能代码创建")
    }

    func update(icon: String, tint: UIColor, title: String) {
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        iconCircle.backgroundColor = .lmCard
        iconCircle.layer.borderColor = tint.withAlphaComponent(0.22).cgColor
        titleLabel.text = title
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var isHighlighted: Bool {
        didSet { if isEnabled { alpha = isHighlighted ? 0.6 : 1 } }
    }
}

// MARK: - 胶囊按钮（充电中心入口）

/// 图标 + 标题 + 右侧 chevron，淡色胶囊底。对应原 SwiftUI `chargeCenterChip`。
private final class LMChipButton: UIControl {

    init(icon: String, title: String, tint: UIColor) {
        super.init(frame: .zero)

        backgroundColor = tint.withAlphaComponent(0.14)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = tint.withAlphaComponent(0.26).cgColor

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

        let label = UILabel()
        label.text = title
        label.font = LMFont.text(13, weight: .semibold)
        label.textColor = tint

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = tint
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)

        let row = LMUIKit.hStack(spacing: 7)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        row.addArrangedSubview(chevron)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        // 胶囊宽度由内容决定，别被父 StackView 拉伸
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("LMChipButton 只能代码创建")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

// MARK: - 圆形图标按钮（空调 / 风量温度）

/// 一个圆形底色 + 居中图标，可禁用变灰。对应原 SwiftUI 里的 `Circle` 按钮。
private final class LMCircleIconButton: UIControl {

    private let iconView = UIImageView()

    init(size: CGFloat = 52) {
        super.init(frame: .zero)
        layer.cornerRadius = size / 2
        layer.cornerCurve = .continuous

        iconView.contentMode = .center
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMCircleIconButton 只能代码创建")
    }

    func update(icon: String, tint: UIColor, bg: UIColor) {
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        backgroundColor = bg
        // ★ 视觉重设计：统一加发丝描边（近黑底上没描边的圆钮会"飘"）
        layer.borderWidth = 1
        layer.borderColor = tint.withAlphaComponent(0.28).cgColor
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.45 }
    }

    override var isHighlighted: Bool {
        didSet { if isEnabled { alpha = isHighlighted ? 0.6 : 1 } }
    }
}

// MARK: - 图标 + 文字行（提示 / 警示）

/// 对应原 SwiftUI 里的 `Label("...", systemImage: "...")` 小字提示。
private final class LMIconTextRow: UIView {

    private let iconView = UIImageView()
    private let label = UILabel()

    init(icon: String, text: String, tint: UIColor, size: CGFloat = 11) {
        super.init(frame: .zero)

        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        label.text = text
        label.font = .systemFont(ofSize: size)
        label.textColor = tint
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
            iconView.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMIconTextRow 只能代码创建")
    }

    func update(icon: String, text: String, tint: UIColor) {
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        label.text = text
        label.textColor = tint
    }
}

// MARK: - 可点击的卡片行（预约充电 / 蓝牙钥匙）

/// 图标方块 + 标题 + 副标题 + 右侧 chevron，整块可点。
/// 对应原 SwiftUI `appointmentBanner` / `bleCard`。
private final class LMLoveNavCard: UIControl {

    private let iconBox = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    init(icon: String, iconTint: UIColor, title: String, subtitle: String) {
        super.init(frame: .zero)

        backgroundColor = .lmCard
        layer.cornerRadius = LMRadius.tile
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.lmCardLine.cgColor

        iconBox.backgroundColor = iconTint.withAlphaComponent(0.14)
        iconBox.layer.cornerRadius = 11
        iconBox.layer.cornerCurve = .continuous
        iconBox.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = iconTint
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(iconView)

        titleLabel.text = title
        titleLabel.font = LMFont.text(14, weight: .semibold)
        titleLabel.textColor = .lmText
        titleLabel.numberOfLines = 0

        subtitleLabel.text = subtitle
        subtitleLabel.font = LMFont.text(12)
        subtitleLabel.textColor = .lmText2
        subtitleLabel.numberOfLines = 1

        let texts = LMUIKit.vStack(spacing: 3)
        texts.addArrangedSubview(titleLabel)
        texts.addArrangedSubview(subtitleLabel)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 12)
        row.addArrangedSubview(iconBox)
        row.addArrangedSubview(texts)
        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(chevron)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 38),
            iconBox.heightAnchor.constraint(equalToConstant: 38),
            iconView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),

            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMLoveNavCard 只能代码创建")
    }

    func update(icon: String, tint: UIColor, title: String, subtitle: String) {
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        iconBox.backgroundColor = tint.withAlphaComponent(0.14)
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

// MARK: - SOC 进度条

/// 轨道 + 进度填充两层 `CALayer`。对应原 SwiftUI 里那段手画的 `Capsule`。
/// 圆角胶囊用 `cornerRadius = 高度 / 2` 得到，宽度变化在 `layoutSubviews` 里同步。
///
/// ★ 视觉重设计：填充从「单色实心」换成「主色 → 青色 的横向渐变 + 辉光」。
/// ★★ 两个容易踩的点：
///   ① 渐变层的 `frame` 必须跟着填充宽度走，所以它也在 `layoutSubviews` 里同步
///      （`CAGradientLayer` 不参与 Auto Layout，跟 `LMLoveHeroView` 同款处理）。
///   ② **阴影和 `masksToBounds` 不能放同一层** —— 开了裁剪，阴影就被裁掉。
///      所以拆成两层：`fill` 只负责阴影（不裁），`fillGradient` 负责裁剪圆角。
private final class LMSOCBarView: UIView {

    private let track = CALayer()
    private let fill = CALayer()
    private let fillGradient = CAGradientLayer()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        track.backgroundColor = UIColor.white.withAlphaComponent(0.09).cgColor
        layer.addSublayer(track)

        fillGradient.startPoint = CGPoint(x: 0, y: 0.5)
        fillGradient.endPoint = CGPoint(x: 1, y: 0.5)
        fillGradient.colors = [UIColor.lmGood.cgColor, UIColor.lmAccent2.cgColor]
        fillGradient.masksToBounds = true
        fill.addSublayer(fillGradient)

        fill.shadowColor = UIColor.lmGood.cgColor
        fill.shadowOpacity = 0.55
        fill.shadowRadius = 7
        fill.shadowOffset = .zero
        layer.addSublayer(fill)
    }

    required init?(coder: NSCoder) {
        fatalError("LMSOCBarView 只能代码创建")
    }

    func set(fraction: CGFloat, tint: UIColor) {
        self.fraction = min(max(fraction, 0), 1)
        fill.shadowColor = tint.cgColor
        fillGradient.colors = [tint.cgColor, UIColor.lmAccent2.cgColor]
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 关掉隐式动画：每次数据刷新都重排，否则进度条会「缓慢滑过去」。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height
        let r = h / 2
        track.frame = bounds
        track.cornerRadius = r
        // 原页是 `max(4, width * fraction)`：有电量时至少画出一小截
        let w = max(4, bounds.width * fraction)
        fill.frame = CGRect(x: 0, y: 0, width: w, height: h)
        fill.cornerRadius = r
        fill.shadowPath = UIBezierPath(roundedRect: fill.bounds, cornerRadius: r).cgPath
        fillGradient.frame = fill.bounds
        fillGradient.cornerRadius = r
        CATransaction.commit()
    }
}

// MARK: - 3D 车模底部的辉光

/// 车底那团薄荷辉光。一个椭圆径向渐变，纯装饰。
///
/// ★ 为什么单独一个类：`CAGradientLayer` 不参与 Auto Layout，
///   view 尺寸一变就要手动同步 `frame`（与 `LMLoveHeroView` / `LMChargeHeroView` 同款）。
private final class LMCar3DPedestalView: UIView {

    private let glow = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        glow.type = .radial
        glow.colors = [
            UIColor.lmAccent.withAlphaComponent(0.34).cgColor,
            UIColor.lmAccent.withAlphaComponent(0.0).cgColor,
        ]
        glow.locations = [0, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1.0, y: 0.5)
        layer.addSublayer(glow)
    }

    required init?(coder: NSCoder) {
        fatalError("LMCar3DPedestalView 只能代码创建")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - 渐变底 hero（续航卡）

/// 续航卡的渐变底。为什么单独一个类：`CAGradientLayer` 不参与 Auto Layout，
/// view 尺寸变了不会自动跟着变，必须在 `layoutSubviews` 里把 `frame` 同步成
/// `bounds` —— 裸 `UIView` 没有这个回调，写在外层 VC 的 `viewDidLayoutSubviews`
/// 里又要多一处耦合，不如封成一个自洽的小类（与 `LMChargeHeroView` 同款做法）。
private final class LMLoveHeroView: UIView {

    let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradient, at: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("LMLoveHeroView 只能代码创建")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }
}
