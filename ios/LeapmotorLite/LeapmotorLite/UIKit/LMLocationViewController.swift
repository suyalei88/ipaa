//
//  LMLocationViewController.swift
//  LeapmotorLite
//
//  车辆定位（UIKit 版）—— 对应原 `Views/LocationView.swift`（763 行 SwiftUI）。
//
//  数据来源（与 SwiftUI 版逐条一致，算法一行没动）：
//    · 车机坐标 = signalMap 的 2190/2191（缺失时退 3725/3724），见 `LMClient.coordinate`
//    · 地图 / 地址 / 导航用「按 `carFix` 换算后」的坐标；
//      算距离和逆地理编码则必须先换算回 WGS-84（见下）
//    · 本机位置 = `LMLocationProvider`（`CLLocationManager`），跟「距我多远」同源
//
//  ★★ 2026-10-09 改动：撤掉「当前位置（IP 归属地）」卡。
//    那张卡显示的是手机**网络**的 IP 归属地（`tecHost/ipAnalysis`），
//    不是手机 GPS，也不是车的位置 —— 只精确到城市，还会被代理/热点带偏。
//    用户明确要求撤掉它、改成「本机 GPS 位置」和「车辆位置」并列。
//
//  ★★ 坐标换算（2026-10-07 修「定位偏到隔壁小区」的成果）一律原样调用
//     `LMCarCoordFix.apply / toWgs84 / amapCoordinateParam`，**不要**在本文件里
//     自己写换算。地图要 GCJ-02、CoreLocation（CLGeocoder / CLLocation 距离）要
//     WGS-84，两处方向用错就差 500~600 米 —— 这正是历史上的那个 bug。
//
//  ★ 地图：SwiftUI `Map` → `MKMapView`。三个必须守住的点：
//     1. `setRegion` 只在相机中心**真的变了**时才调。`render()` 会被网络回调反复
//        触发，每次都 setRegion 会把用户正在拖拽的地图硬拉回车辆位置；
//     2. `viewFor` 里直接 new 一个 `MKAnnotationView`，不走 dequeue 复用
//        （本页最多一个车辆图钉，复用队列只会带来「拿不到视图」的坑）；
//     3. 地图高度用约束钉死（260pt）。
//
//  ★ 地图放在滚动栈的第一格（会跟着内容一起滚）。原 SwiftUI 版地图是固定在顶部的，
//    但 `makeScrollStack()` 已经把 scroll 顶边钉在安全区上了，再想在外面塞一块
//    固定高度的地图就得去拆基类的约束 —— 代价不值当，所以让地图进栈。
//
import UIKit
import MapKit
import CoreLocation
import Combine

final class LMLocationViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，不进 LMClient）

    /// 车机坐标 → 地图坐标 的校正方式（持久化，见 `LMCoordinate.swift`）
    private var carFix: LMCarCoordFix = LMCarCoordFixStore.load()

    /// 逆地理编码出来的中文地址
    private var address: String?
    private var placeName: String?
    private var geocoding = false
    private var geocodeError: String?
    private var copied = false

    /// 30 秒推一次的心跳，用来刷新「x 分钟前采集」这类相对时间。
    /// ★ 不用 `DispatchQueue` 定时器：`Timer` + `.common` 模式在滚动时也不会停走。
    private var now = Date()

    /// 本机定位。只服务「距我多远」这一块，拿不到也不影响主流程。
    private let me = LMLocationProvider()
    private var meCancellables = Set<AnyCancellable>()
    private var clockTimer: Timer?

    /// 地图相机「已应用」的中心。只有它真的变了才 setRegion（见文件头注释）。
    private var appliedCenter: CLLocationCoordinate2D?
    /// 车辆图钉。复用同一个 annotation：坐标变了只改 `coordinate`，不反复增删。
    private var carAnnotation: MKPointAnnotation?

    /// `client.lastUpdate` 的上一次值 —— 用来复刻原页 `.onChange(of: client.lastUpdate)`。
    private var lastSeenUpdate: Date?
    private var didInitialLoad = false

    // MARK: - 控件：地图

    private let mapContainer = UIView()
    private let mapView = MKMapView()
    private let mapPill = LMLocMapPill()
    private let recenterButton = UIButton()

    // MARK: - 控件：无坐标占位

    private let noLocationView = UIView()
    private let placeholderBodyLabel = UILabel()
    private let placeholderRefreshButton = UIButton()

    // MARK: - 控件：我的位置（本机 GPS）
    //
    // ★★ 2026-10-09 用户要求：「把当前位置取消掉、改回之前的」
    //    + 「把车辆定位内部加入本机 GPS 位置和车辆位置同时加入」。
    //
    //    原来这里是一张「当前位置（与官方 App 同源）」卡，内容是手机**网络**的
    //    IP 归属地（`tecHost/ipAnalysis`）。它有两个问题：
    //      · 那是「服务端认为手机连的网在哪」，不是手机的 GPS 位置 ——
    //        WiFi 走专线、用代理、开热点都会把它指到别的城市；
    //      · 它只精确到城市，放在「车辆定位」页最上面，很容易被当成「车在哪」。
    //    所以撤掉，换成**真实的本机 GPS 位置**（`CLLocationManager`），
    //    和下面的「车辆位置」并排，两个位置各自标清来源。

    private let mePosHeader = LMSectionHeaderLabel("我的位置（本机 GPS）")
    private let mePosCard = LMCardView()
    private let mePosIcon = UIImageView()
    private let mePosValueLabel = UILabel()
    private let mePosCoordLabel = UILabel()
    private let mePosMetaLabel = UILabel()
    private let mePosStateLabel = UILabel()
    private let mePosRequestButton = UIButton()

    // MARK: - 控件：地址

    private let addressCard = LMCardView()
    private let addressSpinner = UIActivityIndicatorView(style: .medium)
    private let addressValueLabel = UILabel()
    private let addressStatusLabel = UILabel()
    private let placeNameLabel = UILabel()
    private let regeocodeButton = UIButton()
    /// ★ 2026-10-09：这条提示原来挂在「IP 归属地」卡上，那张卡撤了之后挪到这里 ——
    /// 它是**车辆位置**的问题，本来就该跟车辆位置放一起。
    private let carShareOffNote = LMLocIconNote(
        icon: "exclamationmark.triangle.fill",
        text: "车端已关闭位置数据分享，无法获取车辆实时位置",
        iconColor: .lmWarn, textColor: .lmWarn, size: 11)

    // MARK: - 控件：坐标

    private let coordHeader = LMSectionHeaderLabel("坐标（已按当前校正方式换算）")
    private let coordCard = LMCardView()
    private let latRow = LMLocCoordRow(title: "纬度", note: "信号 2190")
    private let lngRow = LMLocCoordRow(title: "经度", note: "信号 2191")
    private let coordEmptyLabel = UILabel()
    private let disagreeRow = LMLocIconNote(
        icon: "checkmark.circle.fill", text: "",
        iconColor: .lmGood, size: 12)
    private let collectedRow = LMLocNoteRow(icon: "clock", key: "车况采集时间")
    private let unchangedRow = LMLocNoteRow(icon: "location.fill", key: "坐标未变化")
    private let staleNote = UILabel()
    private let coordDivider1 = UIView()
    private let coordDivider2 = UIView()

    // MARK: - 控件：坐标校正

    private let fixCard = LMCardView()
    private let fixControl = UISegmentedControl(items: LMCarCoordFix.allCases.map { $0.title })
    private let fixDetailLabel = UILabel()
    private let rawKVRow = LMLocKVRow(key: "车机原始")
    private let fixedKVRow = LMLocKVRow(key: "换算之后")
    private let movedKVRow = LMLocKVRow(key: "两者相距")
    private let fixDivider = UIView()
    private let fixHelpNote = LMLocIconNote(
        icon: "checkmark.circle", text: """
        怎么确认哪个是对的（10 秒）：
        · 站到车旁边，看地图上「车辆」那个针有没有落在车上；
        · 或者打开官方 App 看它把车画在哪儿，跟这里对比一眼。
        不对就换一个选项 —— 只有三个，总有一个是对的。
        """, iconColor: .lmTeal, size: 11)

    // MARK: - 控件：操作

    private let amapButton = UIButton()
    private let appleButton = UIButton()
    private let copyButton = UIButton()
    private let myLocationButton = UIButton()

    // MARK: - 控件：距我多远

    private let distanceHeader = LMSectionHeaderLabel("距我多远")
    private let distanceCard = LMCardView()
    private let distanceValueLabel = UILabel()
    private let distanceUnitLabel = UILabel()
    private let accuracyLabel = UILabel()
    private let driveLabel = UILabel()
    private let distanceHintLabel = UILabel()
    private let meStateLabel = UILabel()
    private let meRequestButton = UIButton()
    private let meDeniedNote = LMLocIconNote(
        icon: "exclamationmark.triangle.fill",
        text: "你拒绝了定位权限。到「设置 → 隐私与安全性 → 定位服务」里给「零跑轻控」打开即可。",
        iconColor: .lmWarn, textColor: .lmWarn, size: 12)
    private let meRestrictedNote = LMLocIconNote(
        icon: "lock.fill", text: "系统限制了定位（可能是屏幕使用时间/家长控制）。",
        iconColor: .lmWarn, textColor: .lmWarn, size: 12)
    private let meFailedLabel = UILabel()
    private let meRetryButton = UIButton()

    // MARK: - 控件：驻车照片（★ 2026-10-09 用户要求「找出驻车照片和驻车位置」）
    //
    // 来源：`GET /carownerservice/v3/api/chassis/query?vin=...`
    //       → `data.fileUrl`（OSS 直链）+ `data.uploadTime`
    // 证据：`evidence/har_appgw.har` #42/#38，图片已存 `evidence/car3d/chassis.jpg`。
    // 详细说明见 `LMParkingSnap` 与 `LMClient.refreshParkingSnap()` 的注释。
    //
    // 「驻车位置」就在这张卡里一起给：照片拍摄时刻车辆所在的坐标
    // （车机 signalMap 2190/2191，即页面上面「车辆位置」那一套）。

    private let snapHeader = LMSectionHeaderLabel("驻车照片")
    private let snapCard = LMCardView()
    private let snapImageView = UIImageView()
    /// 图片高度约束 —— 没图时**必须**关掉，否则 `UIStackView` 里会留一块空白
    /// （hidden 的 arrangedSubview 只是不参与布局，它自己的约束还在，容易打架）
    private var snapHeightConstraint: NSLayoutConstraint?
    private let snapMetaLabel = UILabel()
    private let snapStateLabel = UILabel()
    private let snapButton = UIButton()
    /// 全屏看大图的临时 VC（弱引用；present 之后由 UIKit 持有）
    private weak var snapViewer: UIViewController?

    // MARK: - 控件：说明

    private let sourceNote = UILabel()

    // MARK: - 操作按钮 tag

    private enum Action: Int {
        case amap, apple, copy, me
    }

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "车辆定位"
        // 原页是 `.navigationBarTitleDisplayMode(.inline)`
        navigationItem.largeTitleDisplayMode = .never

        // 右上角「刷新定位」
        let refreshItem = UIBarButtonItem(
            image: UIImage(systemName: "location.circle"),
            style: .plain, target: self, action: #selector(refreshTapped))
        refreshItem.accessibilityLabel = "刷新定位"
        navigationItem.rightBarButtonItem = refreshItem

        let (scroll, stack) = makeScrollStack(spacing: 16, inset: 16)
        // 下拉刷新对应占位文案里的「下拉刷新车况后重试」。
        // ★ 写成多语句闭包（而不是单表达式 `await self?.performPullRefresh()`）：
        //   单表达式闭包会把返回类型推断成 `Void?`，跟 `() async -> Void` 对不上。
        attachRefresh(scroll) { [weak self] in
            guard let self else { return }
            await self.performPullRefresh()
        }

        buildMap()
        buildPlaceholder()
        buildMePositionCard()
        buildAddressCard()
        buildCoordinateCard()
        buildFixCard()
        buildActionRows()
        buildDistanceCard()
        buildSnapCard()
        buildSourceNote()

        stack.addArrangedSubview(mapContainer)
        stack.addArrangedSubview(noLocationView)
        stack.addArrangedSubview(mePosHeader)
        stack.addArrangedSubview(mePosCard)
        stack.addArrangedSubview(addressCard)
        stack.addArrangedSubview(coordHeader)
        stack.addArrangedSubview(coordCard)
        stack.addArrangedSubview(fixCard)
        stack.addArrangedSubview(actionGrid())
        stack.addArrangedSubview(distanceHeader)
        stack.addArrangedSubview(distanceCard)
        stack.addArrangedSubview(snapHeader)
        stack.addArrangedSubview(snapCard)
        stack.addArrangedSubview(sourceNote)

        observeMe()
    }

    // MARK: - 地图

    private func buildMap() {
        mapView.delegate = self
        mapView.layer.cornerRadius = LMRadius.card
        mapView.layer.cornerCurve = .continuous
        mapView.layer.masksToBounds = true
        // ★ 不在 buildUI 里就打开：`showsUserLocation = true` 会立刻要定位权限，
        //   而原页的「我」只有用户点了「获取我的位置」才出现。这里等 me.state 就绪
        //   后再打开，避免进页面就弹权限框（render() 里控制）。
        mapView.showsUserLocation = false
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapContainer.addSubview(mapView)

        mapPill.translatesAutoresizingMaskIntoConstraints = false
        mapContainer.addSubview(mapPill)

        var cfg = UIButton.Configuration.filled()
        cfg.image = UIImage(systemName: "scope")
        cfg.baseBackgroundColor = .lmCard
        cfg.baseForegroundColor = .lmAccent
        cfg.cornerStyle = .capsule
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        recenterButton.configuration = cfg
        recenterButton.addTarget(self, action: #selector(recenterTapped), for: .touchUpInside)
        recenterButton.accessibilityLabel = "回到车辆位置"
        recenterButton.layer.shadowColor = UIColor.black.cgColor
        recenterButton.layer.shadowOpacity = 0.15
        recenterButton.layer.shadowRadius = 4
        recenterButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        recenterButton.translatesAutoresizingMaskIntoConstraints = false
        mapContainer.addSubview(recenterButton)

        NSLayoutConstraint.activate([
            mapContainer.heightAnchor.constraint(equalToConstant: 260),

            mapView.topAnchor.constraint(equalTo: mapContainer.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: mapContainer.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: mapContainer.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: mapContainer.bottomAnchor),

            mapPill.leadingAnchor.constraint(equalTo: mapContainer.leadingAnchor, constant: 10),
            mapPill.bottomAnchor.constraint(equalTo: mapContainer.bottomAnchor, constant: -10),

            recenterButton.trailingAnchor.constraint(equalTo: mapContainer.trailingAnchor, constant: -10),
            recenterButton.bottomAnchor.constraint(equalTo: mapContainer.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - 无坐标占位

    private func buildPlaceholder() {
        noLocationView.backgroundColor = .lmCanvas

        let icon = UIImageView(image: UIImage(systemName: "location.slash"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30)
        icon.tintColor = .lmWarn
        icon.contentMode = .scaleAspectFit

        let title = LMUIKit.label("暂时没有车辆坐标", size: 17, weight: .semibold)
        title.textAlignment = .center

        placeholderBodyLabel.text = ""
        placeholderBodyLabel.font = .systemFont(ofSize: 12)
        placeholderBodyLabel.textColor = .secondaryLabel
        placeholderBodyLabel.numberOfLines = 0
        placeholderBodyLabel.textAlignment = .center

        var cfg = UIButton.Configuration.filled()
        cfg.title = "刷新车况"
        cfg.baseBackgroundColor = .lmAccent
        cfg.baseForegroundColor = .lmCanvas
        cfg.cornerStyle = .medium
        placeholderRefreshButton.configuration = cfg
        placeholderRefreshButton.addTarget(self, action: #selector(placeholderRefreshTapped),
                                           for: .touchUpInside)

        let inner = LMUIKit.vStack(spacing: 10, alignment: .center)
        inner.addArrangedSubview(icon)
        inner.addArrangedSubview(title)
        inner.addArrangedSubview(placeholderBodyLabel)
        inner.addArrangedSubview(placeholderRefreshButton)
        inner.translatesAutoresizingMaskIntoConstraints = false
        noLocationView.addSubview(inner)

        NSLayoutConstraint.activate([
            noLocationView.heightAnchor.constraint(equalToConstant: 240),
            inner.centerXAnchor.constraint(equalTo: noLocationView.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: noLocationView.centerYAnchor),
            inner.leadingAnchor.constraint(equalTo: noLocationView.leadingAnchor, constant: 24),
            inner.trailingAnchor.constraint(equalTo: noLocationView.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - 我的位置卡片（本机 GPS）

    private func buildMePositionCard() {
        mePosIcon.image = UIImage(systemName: "location.fill")
        mePosIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22)
        mePosIcon.tintColor = .lmAccent
        mePosIcon.contentMode = .scaleAspectFit
        mePosIcon.setContentHuggingPriority(.required, for: .horizontal)

        mePosValueLabel.font = LMFont.text(17, weight: .semibold)
        mePosValueLabel.textColor = .lmText
        mePosValueLabel.numberOfLines = 0

        // 坐标用等宽：一串数字里某位变化时整行不会左右"跳"
        mePosCoordLabel.font = LMFont.mono(11.5)
        mePosCoordLabel.textColor = .lmText3
        mePosCoordLabel.numberOfLines = 1
        mePosCoordLabel.adjustsFontSizeToFitWidth = true
        mePosCoordLabel.minimumScaleFactor = 0.7

        mePosMetaLabel.font = LMFont.text(11)
        mePosMetaLabel.textColor = .lmText3
        mePosMetaLabel.numberOfLines = 0

        mePosStateLabel.font = LMFont.text(12)
        mePosStateLabel.textColor = .lmText2
        mePosStateLabel.numberOfLines = 0

        let texts = LMUIKit.vStack(spacing: 3)
        texts.addArrangedSubview(mePosValueLabel)
        texts.addArrangedSubview(mePosCoordLabel)
        texts.addArrangedSubview(mePosMetaLabel)

        let head = LMUIKit.hStack(spacing: 12, alignment: .top)
        head.addArrangedSubview(mePosIcon)
        head.addArrangedSubview(texts)

        styleLinkButton(mePosRequestButton, title: "获取我的位置", icon: "location.fill")
        mePosRequestButton.addTarget(self, action: #selector(requestMeTapped), for: .touchUpInside)

        mePosCard.contentStack.addArrangedSubview(head)
        mePosCard.contentStack.addArrangedSubview(mePosStateLabel)
        mePosCard.contentStack.addArrangedSubview(
            LMUIKit.hStack(spacing: 0).lmAdding([mePosRequestButton, LMUIKit.spacer()]))
    }

    // MARK: - 地址卡片

    private func buildAddressCard() {
        let icon = UIImageView(image: UIImage(systemName: "mappin.and.ellipse"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.tintColor = .lmAccent
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let caption = LMUIKit.label("车辆位置", size: 13, weight: .semibold, color: .secondaryLabel, lines: 1)

        addressSpinner.hidesWhenStopped = true

        let head = LMUIKit.hStack(spacing: 6)
        head.addArrangedSubview(icon)
        head.addArrangedSubview(caption)
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(addressSpinner)

        addressValueLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        addressValueLabel.numberOfLines = 0

        addressStatusLabel.font = .systemFont(ofSize: 16)
        addressStatusLabel.textColor = .secondaryLabel
        addressStatusLabel.numberOfLines = 0

        placeNameLabel.font = .systemFont(ofSize: 12)
        placeNameLabel.textColor = .secondaryLabel
        placeNameLabel.numberOfLines = 0

        styleLinkButton(regeocodeButton, title: "重新解析地址",
                        icon: "arrow.triangle.2.circlepath")
        regeocodeButton.addTarget(self, action: #selector(regeocodeTapped), for: .touchUpInside)

        carShareOffNote.isHidden = true

        addressCard.contentStack.addArrangedSubview(head)
        addressCard.contentStack.addArrangedSubview(addressValueLabel)
        addressCard.contentStack.addArrangedSubview(addressStatusLabel)
        addressCard.contentStack.addArrangedSubview(placeNameLabel)
        addressCard.contentStack.addArrangedSubview(carShareOffNote)
        addressCard.contentStack.addArrangedSubview(
            LMUIKit.hStack(spacing: 0).lmAdding([regeocodeButton, LMUIKit.spacer()]))
    }

    // MARK: - 坐标卡片

    private func buildCoordinateCard() {
        coordEmptyLabel.text = "--"
        coordEmptyLabel.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        coordEmptyLabel.textColor = .secondaryLabel

        staleNote.font = .systemFont(ofSize: 11)
        staleNote.textColor = .lmWarn
        staleNote.numberOfLines = 0
        staleNote.text = """
        车机一直在上报车况（上面的采集时间会一直刷新），但「这个坐标」已经很久没变过了。
        所以图钉很可能不是车现在的位置 —— 常见原因：车停在地库/没信号、
        车机没上传新定位、或定位功能未开启。请以官方 App 或实车为准。
        """

        coordDivider1.backgroundColor = .separator
        coordDivider2.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        coordDivider1.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true
        coordDivider2.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true

        coordCard.contentStack.addArrangedSubview(latRow)
        coordCard.contentStack.addArrangedSubview(coordDivider1)
        coordCard.contentStack.addArrangedSubview(lngRow)
        coordCard.contentStack.addArrangedSubview(coordEmptyLabel)
        coordCard.contentStack.addArrangedSubview(coordDivider2)
        coordCard.contentStack.addArrangedSubview(disagreeRow)
        coordCard.contentStack.addArrangedSubview(makeDivider())
        coordCard.contentStack.addArrangedSubview(collectedRow)
        coordCard.contentStack.addArrangedSubview(unchangedRow)
        coordCard.contentStack.addArrangedSubview(staleNote)
    }

    // MARK: - 坐标校正卡片

    private func buildFixCard() {
        fixControl.selectedSegmentIndex = LMCarCoordFix.allCases.firstIndex(of: carFix) ?? 0
        fixControl.addTarget(self, action: #selector(fixChanged), for: .valueChanged)

        fixDetailLabel.font = .systemFont(ofSize: 11)
        fixDetailLabel.textColor = .secondaryLabel
        fixDetailLabel.numberOfLines = 0

        fixDivider.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        fixDivider.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true

        fixCard.contentStack.addArrangedSubview(LMSectionHeaderLabel("坐标校正"))
        fixCard.contentStack.addArrangedSubview(fixControl)
        fixCard.contentStack.addArrangedSubview(fixDetailLabel)
        fixCard.contentStack.addArrangedSubview(fixDivider)
        fixCard.contentStack.addArrangedSubview(rawKVRow)
        fixCard.contentStack.addArrangedSubview(fixedKVRow)
        fixCard.contentStack.addArrangedSubview(movedKVRow)
        fixCard.contentStack.addArrangedSubview(makeDivider())
        fixCard.contentStack.addArrangedSubview(fixHelpNote)
    }

    // MARK: - 操作按钮

    private func buildActionRows() {
        for (button, action) in [(amapButton, Action.amap), (appleButton, .apple),
                                 (copyButton, .copy), (myLocationButton, .me)] {
            button.tag = action.rawValue
            button.addTarget(self, action: #selector(actionTapped(_:)), for: .touchUpInside)
        }
        styleBigButton(amapButton, title: "高德地图",
                       icon: "arrow.triangle.turn.up.right.circle.fill", tint: .lmAccent)
        styleBigButton(appleButton, title: "Apple 地图", icon: "map.fill", tint: .lmTeal)
        styleBigButton(copyButton, title: "复制坐标", icon: "doc.on.doc", tint: .lmPurple)
        styleBigButton(myLocationButton, title: "获取我的位置", icon: "location.fill", tint: .lmWarn)
    }

    private func actionGrid() -> UIView {
        let row1 = LMUIKit.hStack(spacing: 10)
        row1.distribution = .fillEqually
        row1.addArrangedSubview(amapButton)
        row1.addArrangedSubview(appleButton)

        let row2 = LMUIKit.hStack(spacing: 10)
        row2.distribution = .fillEqually
        row2.addArrangedSubview(copyButton)
        row2.addArrangedSubview(myLocationButton)

        let box = LMUIKit.vStack(spacing: 10)
        box.addArrangedSubview(row1)
        box.addArrangedSubview(row2)
        return box
    }

    // MARK: - 距我多远卡片

    private func buildDistanceCard() {
        distanceValueLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        distanceValueLabel.textColor = .lmAccent
        distanceValueLabel.adjustsFontSizeToFitWidth = true
        distanceValueLabel.minimumScaleFactor = 0.6
        distanceValueLabel.numberOfLines = 1

        distanceUnitLabel.text = "直线距离"
        distanceUnitLabel.font = .systemFont(ofSize: 12)
        distanceUnitLabel.textColor = .secondaryLabel

        // ★ 用 `.center` 而不是 `.firstBaseline`：这一行末尾挂了 `spacer()`，
        //   纯 UIView 的 baseline 是它的底边，基线对齐反而会把文字顶歪。
        let valueRow = LMUIKit.hStack(spacing: 4, alignment: .center)
        valueRow.addArrangedSubview(distanceValueLabel)
        valueRow.addArrangedSubview(distanceUnitLabel)
        valueRow.addArrangedSubview(LMUIKit.spacer())

        accuracyLabel.font = .systemFont(ofSize: 11)
        accuracyLabel.textColor = .secondaryLabel
        accuracyLabel.numberOfLines = 0

        driveLabel.font = .systemFont(ofSize: 12)
        driveLabel.textColor = .secondaryLabel
        driveLabel.numberOfLines = 0

        distanceHintLabel.font = .systemFont(ofSize: 16)
        distanceHintLabel.textColor = .secondaryLabel
        distanceHintLabel.numberOfLines = 0

        meStateLabel.font = .systemFont(ofSize: 16)
        meStateLabel.textColor = .secondaryLabel
        meStateLabel.numberOfLines = 0

        styleLinkButton(meRequestButton, title: "获取我的位置")
        meRequestButton.addTarget(self, action: #selector(requestMeTapped), for: .touchUpInside)

        meFailedLabel.font = .systemFont(ofSize: 16)
        meFailedLabel.textColor = .secondaryLabel
        meFailedLabel.numberOfLines = 0
        meFailedLabel.text = "取不到你的位置（室内或信号弱）。多试一次，或走到窗边。"

        styleLinkButton(meRetryButton, title: "再试一次")
        meRetryButton.addTarget(self, action: #selector(requestMeTapped), for: .touchUpInside)

        distanceCard.contentStack.addArrangedSubview(valueRow)
        distanceCard.contentStack.addArrangedSubview(accuracyLabel)
        distanceCard.contentStack.addArrangedSubview(driveLabel)
        distanceCard.contentStack.addArrangedSubview(distanceHintLabel)
        distanceCard.contentStack.addArrangedSubview(meStateLabel)
        distanceCard.contentStack.addArrangedSubview(
            LMUIKit.hStack(spacing: 0).lmAdding([meRequestButton, LMUIKit.spacer()]))
        distanceCard.contentStack.addArrangedSubview(meDeniedNote)
        distanceCard.contentStack.addArrangedSubview(meRestrictedNote)
        distanceCard.contentStack.addArrangedSubview(meFailedLabel)
        distanceCard.contentStack.addArrangedSubview(
            LMUIKit.hStack(spacing: 0).lmAdding([meRetryButton, LMUIKit.spacer()]))
    }

    // MARK: - 说明

    // MARK: - 驻车照片卡片

    private func buildSnapCard() {
        snapImageView.contentMode = .scaleAspectFit
        snapImageView.backgroundColor = .lmCanvas
        snapImageView.layer.cornerRadius = LMRadius.tile
        snapImageView.layer.cornerCurve = .continuous
        snapImageView.clipsToBounds = true
        snapImageView.translatesAutoresizingMaskIntoConstraints = false
        snapImageView.isUserInteractionEnabled = true
        snapImageView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(snapTapped)))

        // 高度约束先关掉：没图的时候如果它是 active 的，
        // UIStackView 会给这块留 260pt 空白（hidden 只是不参与布局，约束还在）。
        let h = snapImageView.heightAnchor.constraint(equalToConstant: 260)
        h.isActive = false
        snapHeightConstraint = h

        snapMetaLabel.font = LMFont.text(11.5)
        snapMetaLabel.textColor = .lmText3
        snapMetaLabel.numberOfLines = 0

        snapStateLabel.font = LMFont.text(12)
        snapStateLabel.textColor = .lmText2
        snapStateLabel.numberOfLines = 0

        styleLinkButton(snapButton, title: "获取驻车照片", icon: "camera.fill")
        snapButton.addTarget(self, action: #selector(loadSnapTapped), for: .touchUpInside)

        snapCard.contentStack.addArrangedSubview(snapImageView)
        snapCard.contentStack.addArrangedSubview(snapMetaLabel)
        snapCard.contentStack.addArrangedSubview(snapStateLabel)
        snapCard.contentStack.addArrangedSubview(
            LMUIKit.hStack(spacing: 0).lmAdding([snapButton, LMUIKit.spacer()]))
    }

    private func buildSourceNote() {
        sourceNote.text = """
        本页有两个位置，来源完全不同，别混：
        · 「我的位置（本机 GPS）」= 这台手机的 GPS，`CLLocationManager` 直出，米级精度；
        · 「车辆位置」= 车机上报的信号 2190/2191（另一组 3725/3724 做交叉校验），
          不是实时 GPS 跟踪 —— 它反映的是车机最后一次上报的坐标。

        ★ 实测提醒：这组车机坐标**可能长期不变**。在 60 个抓包样本里它一个数字都没动过
        （31.801201 / 117.342718，指向合肥）。要判断新不新，看坐标卡里单独标的
        「坐标未变化」多久：车况采集时间每秒都在刷新，但坐标可以连续几十次完全不变。

        车熄火后位置可能长时间不更新；地库里通常没有定位。
        车机坐标属于哪一系（WGS-84 / GCJ-02）无法从协议静态判定，所以给了「坐标校正」三个选项：
        国内两系相差约 500~600 米，选对了才落得准。
        """
        sourceNote.font = .systemFont(ofSize: 11)
        sourceNote.textColor = .secondaryLabel
        sourceNote.numberOfLines = 0
    }

    // MARK: - 本机定位订阅

    /// 订阅 `LMLocationProvider` 的变化，驱动「距我多远」和地图上的「我」。
    ///
    /// ★ 跟基类订阅 `client.objectWillChange` 一个套路：`objectWillChange` 在**新值写入前**
    ///   触发，所以必须推到下一轮主队列再读 —— 用 `Task { @MainActor in }` 而不是
    ///   `DispatchQueue.main.async`（后者不继承 @MainActor 隔离，可能编译失败）。
    private func observeMe() {
        me.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.meChanged()
                }
            }
            .store(in: &meCancellables)
    }

    private func meChanged() {
        // 复刻原页 `.onChange(of: me.coordinate)` → `if me.state == .ready { centerOnVehicle() }`
        if me.state == .ready { centerOnVehicle() }
        render()
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        // 复刻原页 `.onChange(of: client.lastUpdate)`
        if client.lastUpdate != lastSeenUpdate {
            lastSeenUpdate = client.lastUpdate
            centerOnVehicle()
            Task { @MainActor in await self.reverseGeocode() }
        }

        renderMap()
        renderMePosition()
        renderAddress()
        renderCoordinates()
        renderFix()
        renderActions()
        renderDistance()
        renderSnap()
    }

    private func renderMap() {
        let hasCar = carCoordinate != nil
        mapContainer.isHidden = !hasCar
        noLocationView.isHidden = hasCar

        // 车辆图钉
        if let c = carCoordinate {
            if let a = carAnnotation {
                a.coordinate = c
            } else {
                let a = MKPointAnnotation()
                a.title = "车辆"
                a.coordinate = c
                mapView.addAnnotation(a)
                carAnnotation = a
            }
            centerOnVehicle()
        } else if let a = carAnnotation {
            mapView.removeAnnotation(a)
            carAnnotation = nil
        }

        // 用户蓝点：等本机定位就绪再打开，避免进页面就弹权限框
        mapView.showsUserLocation = (me.state == .ready)

        // 占位文案分两种：官方隐私开关开着 vs 车机没上报（见原页注释）
        placeholderBodyLabel.text = client.locationMayBeHidden
            ? "车辆配置里 privacyGPS = 1，官方会隐藏位置。请到官方 App 关闭位置隐私开关后重试。"
            : "车机可能没有上报位置（地库 / 隧道 / 刚上电）。下拉刷新车况后重试。"

        mapPill.update(text: ageText)
    }

    /// 我的位置（本机 GPS）—— 与「距我多远」同一个数据源（`LMLocationProvider`）。
    /// 幂等：只改已有控件的属性 / `isHidden`，不 `addSubview`。
    private func renderMePosition() {
        let state = me.state

        mePosValueLabel.isHidden = false
        mePosCoordLabel.isHidden = true
        mePosMetaLabel.isHidden = true
        mePosStateLabel.isHidden = true

        if state == .ready, let c = me.coordinate {
            mePosValueLabel.text = "已定位（WGS-84 原始坐标）"
            mePosCoordLabel.isHidden = false
            mePosCoordLabel.text = String(format: "%.6f, %.6f", c.latitude, c.longitude)
            if let acc = me.accuracy {
                mePosMetaLabel.isHidden = false
                mePosMetaLabel.text = String(format: "定位精度约 ±%.0f 米（越小越准）", acc)
            }
            mePosRequestButton.configuration?.title = "刷新我的位置"
        } else {
            mePosValueLabel.text = (state == .locating) ? "正在获取你的位置…" : "还没拿到你的位置"
            mePosStateLabel.isHidden = false
            mePosStateLabel.text = state.text
            mePosRequestButton.configuration?.title = "获取我的位置"
        }
    }

    private func renderAddress() {
        if geocoding { addressSpinner.startAnimating() } else { addressSpinner.stopAnimating() }

        let a = address ?? ""
        if !a.isEmpty {
            addressValueLabel.isHidden = false
            addressValueLabel.text = a
            addressStatusLabel.isHidden = true
        } else {
            addressValueLabel.isHidden = true
            addressStatusLabel.isHidden = false
            if geocoding {
                addressStatusLabel.text = "正在解析地址…"
                addressStatusLabel.textColor = .secondaryLabel
            } else if let e = geocodeError {
                addressStatusLabel.text = e
                addressStatusLabel.textColor = .lmWarn
            } else if carCoordinate == nil {
                addressStatusLabel.text = "--"
                addressStatusLabel.textColor = .secondaryLabel
            } else {
                addressStatusLabel.text = "没能解析出地址（可长按复制下面的经纬度去地图里搜）"
                addressStatusLabel.textColor = .secondaryLabel
            }
        }

        let p = placeName ?? ""
        placeNameLabel.isHidden = p.isEmpty || p == a
        placeNameLabel.text = "地图兴趣点：\(p)"

        regeocodeButton.isEnabled = (carCoordinate != nil) && !geocoding
        carShareOffNote.isHidden = !client.carLocationShareOff
    }

    private func renderCoordinates() {
        if let c = carCoordinate {
            latRow.isHidden = false
            lngRow.isHidden = false
            coordDivider1.isHidden = false
            coordEmptyLabel.isHidden = true
            latRow.setValue(String(format: "%.6f", c.latitude))
            lngRow.setValue(String(format: "%.6f", c.longitude))
        } else {
            latRow.isHidden = true
            lngRow.isHidden = true
            coordDivider1.isHidden = true
            coordEmptyLabel.isHidden = false
        }

        if let diff = client.coordinateDisagreementMeters {
            disagreeRow.isHidden = false
            coordDivider2.isHidden = false
            let warn = diff > 50
            disagreeRow.update(
                icon: warn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                text: warn
                    ? String(format: "两组坐标相差 %.0f 米 —— 有一组可能是缓存或漂移，别完全信", diff)
                    : String(format: "两组坐标（2190/2191 与 3725/3724）相差 %.0f 米，一致", diff),
                iconColor: warn ? .lmWarn : .lmGood)
        } else {
            disagreeRow.isHidden = true
            coordDivider2.isHidden = true
        }

        collectedRow.update(value: collectedText, color: .secondaryLabel)

        let stale = client.coordinateLooksStale
        unchangedRow.update(
            value: coordUnchangedText,
            color: stale ? .lmWarn : .label,
            icon: stale ? "exclamationmark.triangle.fill" : "location.fill",
            iconColor: stale ? .lmWarn : .secondaryLabel)
        staleNote.isHidden = !stale
    }

    private func renderFix() {
        fixControl.selectedSegmentIndex = LMCarCoordFix.allCases.firstIndex(of: carFix) ?? 0
        fixDetailLabel.text = carFix.detail

        if let raw = rawCarCoordinate, let fixed = carCoordinate {
            rawKVRow.isHidden = false
            fixedKVRow.isHidden = false
            movedKVRow.isHidden = false
            fixDivider.isHidden = false
            rawKVRow.setValue(String(format: "%.6f, %.6f", raw.latitude, raw.longitude))
            fixedKVRow.setValue(String(format: "%.6f, %.6f", fixed.latitude, fixed.longitude))
            let moved = LMCoord.distance(raw, fixed)
            movedKVRow.setValue(moved < 1 ? "不足 1 米" : String(format: "%.0f 米", moved))
        } else {
            rawKVRow.isHidden = true
            fixedKVRow.isHidden = true
            movedKVRow.isHidden = true
            fixDivider.isHidden = true
        }
    }

    private func renderActions() {
        let hasCar = carCoordinate != nil
        amapButton.isEnabled = hasCar
        appleButton.isEnabled = hasCar
        copyButton.isEnabled = hasCar
        // ★ 用 configuration 建的按钮，动态标题/图标必须改 `configuration`，
        //   写 `titleLabel?.text` / `setImage` 会被配置覆盖（静默失效）。
        copyButton.configuration?.title = copied ? "已复制" : "复制坐标"
        copyButton.configuration?.image = UIImage(systemName: copied
                                                  ? "checkmark.circle.fill" : "doc.on.doc")
    }

    private func renderDistance() {
        let state = me.state

        // 先按「就绪且有距离」铺一遍，再按状态逐项打开
        let ready = (state == .ready)
        let hasDistance = distanceMeters != nil

        distanceValueLabel.isHidden = !(ready && hasDistance)
        distanceUnitLabel.isHidden = !(ready && hasDistance)
        accuracyLabel.isHidden = !(ready && hasDistance && me.accuracy != nil)
        driveLabel.isHidden = !(ready && hasDistance)
        distanceHintLabel.isHidden = !(ready && !hasDistance)

        meStateLabel.isHidden = !(state == .unknown || state == .locating)
        meRequestButton.isHidden = !(state == .unknown || state == .locating)
        meDeniedNote.isHidden = (state != .denied)
        meRestrictedNote.isHidden = (state != .restricted)
        meFailedLabel.isHidden = (state != .failed)
        meRetryButton.isHidden = (state != .failed)

        if ready, let d = distanceMeters {
            distanceValueLabel.text = distanceText(d)
            if let acc = me.accuracy {
                accuracyLabel.text = String(format: "你的定位精度约 ±%.0f 米", acc)
            }
            driveLabel.text = "按 40 km/h 城市均速粗估约 \(driveMinutes(d)) 分钟车程 —— 只是量感，不是导航结果。"
        } else if ready {
            distanceHintLabel.text = "拿到你的位置了，但车辆坐标缺失，算不出距离。"
        } else if state == .unknown || state == .locating {
            meStateLabel.text = state.text
        }
    }

    /// 驻车照片（幂等）。
    private func renderSnap() {
        let loading = client.parkingSnapLoading
        let snap = client.parkingSnap

        // 图片：有数据才显示，没数据就把高度约束关掉（见 buildSnapCard 的注释）
        if let data = client.parkingSnapImageData, let img = UIImage(data: data) {
            snapImageView.image = img
            snapImageView.isHidden = false
            snapHeightConstraint?.isActive = true
        } else {
            snapImageView.image = nil
            snapImageView.isHidden = true
            snapHeightConstraint?.isActive = false
        }

        // 拍摄时间 + 驻车位置
        if let snap {
            var lines: [String] = []
            lines.append("车端上传时间：" + Self.snapTimeText(snap.uploadTime))
            if let c = carCoordinate {
                lines.append(String(format: "驻车位置：%.6f, %.6f（车机坐标）",
                                    c.latitude, c.longitude))
            } else {
                lines.append("驻车位置：暂时没有车机坐标")
            }
            lines.append("照片由车端哨兵 / 环视系统拍摄后上传到 OSS；"
                         + "链接带签名会过期，过期后点「重新获取」换一条新的。")
            snapMetaLabel.isHidden = false
            snapMetaLabel.text = lines.joined(separator: "\n")
        } else {
            snapMetaLabel.isHidden = true
        }

        // 状态行
        if loading {
            snapStateLabel.isHidden = false
            snapStateLabel.text = "正在获取驻车照片…"
        } else if let e = client.parkingSnapError {
            snapStateLabel.isHidden = false
            snapStateLabel.text = e
        } else if snap == nil {
            snapStateLabel.isHidden = false
            snapStateLabel.text = "还没获取。点下面按钮从车端拉一张。"
        } else if client.parkingSnapImageData == nil {
            snapStateLabel.isHidden = false
            snapStateLabel.text = "拿到图片链接了，正在下载…"
        } else {
            snapStateLabel.isHidden = true
        }

        // ★ 用 configuration 建的按钮，动态标题/图标必须改 configuration，
        //   写 titleLabel?.text 会被配置覆盖（静默失效）。
        snapButton.configuration?.title = (snap == nil) ? "获取驻车照片" : "重新获取"
        snapButton.configuration?.image = UIImage(
            systemName: (snap == nil) ? "camera.fill" : "arrow.triangle.2.circlepath")
        snapButton.isEnabled = !loading
    }

    /// 上传时间 → `2026-10-07 13:26`
    private static func snapTimeText(_ d: Date?) -> String {
        guard let d else { return "未知" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: - 动作

    @objc private func refreshTapped() {
        // 复刻原页 toolbar：刷新车况 → 回中 → 重新解析地址
        Task { @MainActor in
            try? await client.refreshStatus()
            self.centerOnVehicle(force: true)
            await self.reverseGeocode()
            self.render()
        }
    }

    @objc private func recenterTapped() {
        centerOnVehicle(force: true)
    }

    @objc private func placeholderRefreshTapped() {
        Task { @MainActor in
            try? await client.refreshStatus()
        }
    }

    @objc private func regeocodeTapped() {
        Task { @MainActor in
            await self.reverseGeocode(force: true)
        }
    }

    @objc private func requestMeTapped() {
        me.request()
        render()
    }

    @objc private func loadSnapTapped() {
        Task { @MainActor in
            // ★ 2026-10-09：先 render 一次进「获取中」态 ——
            //   不然网络慢的时候点下去界面毫无变化，看起来像按钮坏了。
            self.render()
            _ = await client.refreshParkingSnap()
            if client.parkingSnap != nil {
                _ = await client.downloadParkingSnapImage()
            }
            self.render()
        }
    }

    /// 点缩略图 → 全屏看大图。
    /// 照片里最有用的是**车位号**（画面里那个数字），缩略图上不一定看得清。
    @objc private func snapTapped() {
        guard let img = snapImageView.image else { return }
        let vc = UIViewController()
        vc.view.backgroundColor = .lmCanvas
        vc.modalPresentationStyle = .fullScreen

        let iv = UIImageView(image: img)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(iv)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .lmText2
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(closeSnapViewer), for: .touchUpInside)
        vc.view.addSubview(close)

        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 12),
            iv.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 12),
            iv.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -12),
            iv.bottomAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            close.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -16),
            close.widthAnchor.constraint(equalToConstant: 34),
            close.heightAnchor.constraint(equalToConstant: 34),
        ])
        snapViewer = vc
        present(vc, animated: true)
    }

    @objc private func closeSnapViewer() {
        snapViewer?.dismiss(animated: true)
        snapViewer = nil
    }

    @objc private func fixChanged() {
        let idx = fixControl.selectedSegmentIndex
        guard idx >= 0, idx < LMCarCoordFix.allCases.count else { return }
        carFix = LMCarCoordFix.allCases[idx]
        // 复刻原页 `.onChange(of: carFix)`：落盘 → 重新落点 → 强制重解析地址
        LMCarCoordFixStore.save(carFix)
        centerOnVehicle(force: true)
        render()
        Task { @MainActor in
            await self.reverseGeocode(force: true)
        }
    }

    @objc private func actionTapped(_ sender: UIControl) {
        guard let action = Action(rawValue: sender.tag) else { return }
        switch action {
        case .amap:
            if let u = amapURL { UIApplication.shared.open(u) }
        case .apple:
            if let u = appleMapsURL { UIApplication.shared.open(u) }
        case .copy:
            copyCoordinate()
        case .me:
            me.request()
            render()
        }
    }

    @objc private func clockTick() {
        now = Date()
        render()
    }

    // MARK: - 生命周期

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startClock()
        // 复刻原页的 `.task { centerOnVehicle(); await reverseGeocode() }`
        if !didInitialLoad {
            didInitialLoad = true
            centerOnVehicle(force: true)
            Task { @MainActor in
                await self.reverseGeocode()
                // ★ 2026-10-09：顺手拉一次驻车照片。
                //   失败不弹错 —— 状态写在驻车照片卡里，不打断定位主流程。
                _ = await self.client.refreshParkingSnap()
                if self.client.parkingSnap != nil {
                    _ = await self.client.downloadParkingSnapImage()
                }
                self.render()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 离开页面就停表，别让 Timer 一直持有 self
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func startClock() {
        clockTimer?.invalidate()
        // ★ 用 target/selector 版（block 版收 @Sendable 闭包，不继承 @MainActor 隔离）；
        //   必须加进 `.common` 模式，否则用户一拖 ScrollView 计时器就停走。
        let timer = Timer(timeInterval: 30, target: self,
                          selector: #selector(clockTick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    // MARK: - 计算

    /// 车机原始坐标（未做任何换算）
    private var rawCarCoordinate: CLLocationCoordinate2D? { client.coordinate }

    /// 交给地图 / 地址 / 导航用的坐标（已按 `carFix` 换算）
    private var carCoordinate: CLLocationCoordinate2D? {
        guard let c = client.coordinate else { return nil }
        return carFix.apply(c)
    }

    private var distanceMeters: Double? {
        // ★ 用「换算到 WGS-84 的车机坐标」跟本机坐标量，别用地图上那两个点。
        //   本机坐标必然是 WGS-84；地图换算是显示问题，拿它去量距离会白差几百米。
        guard let raw = client.coordinate, let u = me.coordinate else { return nil }
        let c = carFix.toWgs84(raw)
        return CLLocation(latitude: u.latitude, longitude: u.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    private func distanceText(_ m: Double) -> String {
        m < 1000 ? String(format: "%.0f 米", m) : String(format: "%.1f km", m / 1000)
    }

    private func driveMinutes(_ m: Double) -> Int {
        max(1, Int((m / 1000.0 / 40.0 * 60.0).rounded()))
    }

    private var ageText: String {
        guard let d = client.collectedAt else { return "采集时间未知" }
        // ★ 用本页的心跳 `now` 而不是 `Date()`：这样相对时间只在 30 秒那一拍更新，
        //   和原页 `.lmClock(until:now:)` 的语义一致。
        let age = now.timeIntervalSince(d)
        if age < 60 { return "刚刚采集" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前采集" }
        if age < 86400 { return "\(Int(age / 3600)) 小时前采集" }
        return "\(Int(age / 86400)) 天前采集"
    }

    private var collectedText: String {
        guard let d = client.collectedAt else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return "\(f.string(from: d))（\(ageText)）"
    }

    /// 「坐标未变化」的展示文本：从什么时候开始没变、已经多久。
    private var coordUnchangedText: String {
        guard let since = client.coordinateUnchangedSince else { return "--" }
        let secs = now.timeIntervalSince(since)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let dur: String
        if secs < 60 { dur = "刚刚" }
        else if secs < 3600 { dur = "\(Int(secs / 60)) 分钟" }
        else if secs < 86400 { dur = String(format: "%.1f 小时", secs / 3600) }
        else { dur = String(format: "%.1f 天", secs / 86400) }
        return "\(f.string(from: since)) 起（\(dur)）"
    }

    private var amapURL: URL? {
        guard let c = carCoordinate else { return nil }
        // ★ `coordinate=` 必须跟我们实际传的值对得上，否则高德会按它自己的默认值
        //   再偏一次。取值由 carFix 决定（见 LMCoordinate.swift）：
        //     .wgs84ToGcj02 → 我们传的是 GCJ-02 → coordinate=gcj02
        //     .gcj02ToWgs84 → 我们传的是 WGS-84 → coordinate=wgs84
        //     .none         → 不知道是哪一系，索性不带，让高德按默认处理
        let name = (address ?? "车辆位置").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "car"
        var s = "https://uri.amap.com/marker?position=\(c.longitude),\(c.latitude)"
            + "&name=\(name)&callnative=1&src=leapmotorlite"
        if let sys = carFix.amapCoordinateParam {
            s += "&coordinate=\(sys)"
        }
        return URL(string: s)
    }

    private var appleMapsURL: URL? {
        guard let c = carCoordinate else { return nil }
        let q = (address ?? "车辆位置").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "car"
        return URL(string: "https://maps.apple.com/?ll=\(c.latitude),\(c.longitude)&q=\(q)")
    }

    private func copyCoordinate() {
        guard let c = carCoordinate else { return }
        UIPasteboard.general.string = String(format: "%.6f,%.6f", c.latitude, c.longitude)
        copied = true
        render()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            self?.copied = false
            self?.render()
        }
    }

    private func centerOnVehicle(force: Bool = false) {
        guard let c = carCoordinate else { return }
        // ★ 只在中心真的变了（或 force）时才 setRegion。`render()` 会被网络回调
        //   反复触发，每次都设区域会把用户正在拖拽的地图硬拉回去。
        if !force, let a = appliedCenter,
           abs(a.latitude - c.latitude) < 1e-7,
           abs(a.longitude - c.longitude) < 1e-7 {
            return
        }
        appliedCenter = c
        let region = MKCoordinateRegion(
            center: c,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005))
        mapView.setRegion(region, animated: true)
    }

    // MARK: - 逆地理编码

    /// Apple 的 CLGeocoder（内部用的就是高德数据，国内地址够准），
    /// 不依赖我们那个「参数未验证」的 /v3/geocode/regeo。
    ///
    /// ★ 传进去的必须是 **WGS-84**（CLGeocoder 属于 CoreLocation），
    ///   所以先按 carFix 把车机坐标转回来，别直接拿地图坐标去查。
    private func reverseGeocode(force: Bool = false) async {
        guard let raw = client.coordinate else {
            address = nil
            placeName = nil
            render()
            return
        }
        if !force, address != nil { return }
        geocoding = true
        geocodeError = nil
        render()

        let c = carFix.toWgs84(raw)
        let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(loc)
            guard let p = marks.first else {
                geocodeError = "地图服务没有返回地址"
                geocoding = false
                render()
                return
            }
            address = LMLocationViewController.composeAddress(p)
            placeName = p.name
            if address == nil, placeName == nil {
                geocodeError = "地图服务没有返回地址"
            }
        } catch {
            geocodeError = "地址解析失败：\(error.localizedDescription)"
        }
        geocoding = false
        render()
    }

    /// 把 CLPlacemark 拼成中文习惯的顺序：省 市 区 街道 门牌
    /// 相邻重复段去掉（CLGeocoder 经常把同一个名字同时塞进 locality 和 subLocality）。
    private static func composeAddress(_ p: CLPlacemark) -> String? {
        var parts: [String] = []
        let candidates: [String?] = [
            p.administrativeArea,
            p.locality,
            p.subLocality,
            p.thoroughfare,
            p.subThoroughfare,
        ]
        for c in candidates {
            guard let s = c, !s.isEmpty else { continue }
            if parts.last == s { continue }
            parts.append(s)
        }
        return parts.isEmpty ? nil : parts.joined()
    }

    // MARK: - 小工具

    /// 下拉刷新：刷新车况 + 强制重解析地址。
    ///
    /// ★ 写成实例方法而不是把逻辑塞进 `attachRefresh` 的闭包里：那个闭包是
    ///   非隔离的 `() async -> Void`，直接在里面摸 `self.client`（@MainActor 属性）
    ///   在严格并发下会报错。这里只做一次 actor 跳转调用本类的 @MainActor 方法。
    private func performPullRefresh() async {
        try? await client.refreshStatus()
        await reverseGeocode(force: true)
    }

    /// 1 物理像素的分隔线。用 `traitCollection.displayScale`（`UIScreen.main` 已弃用）。
    private func makeDivider() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        line.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true
        return line
    }

    /// 表单里那种「纯文字按钮」：无底色、零跑蓝文字 + 可选图标。
    ///
    /// ★ 写成**实例方法**而不是 `static func`：`static func` 在属性初始化器里调用
    ///   会被判成「非隔离上下文调用主 actor 方法」。属性只放纯构造，样式在这里配。
    private func styleLinkButton(_ button: UIButton, title: String,
                                 icon: String? = nil, tint: UIColor = .lmAccent) {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.baseForegroundColor = tint
        if let icon {
            cfg.image = UIImage(systemName: icon)
            cfg.imagePadding = 6
        }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        button.configuration = cfg
    }

    /// 操作区的大按钮：图标 + 文字，淡色底、同色前景，固定 48pt 高。
    /// 对应原页的 `bigButton(_:_:_:_:)`。
    private func styleBigButton(_ button: UIButton, title: String,
                                icon: String, tint: UIColor) {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.image = UIImage(systemName: icon)
        cfg.imagePadding = 7
        cfg.baseBackgroundColor = tint.withAlphaComponent(0.11)
        cfg.baseForegroundColor = tint
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        button.configuration = cfg
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
    }
}

// MARK: - 地图代理

extension LMLocationViewController: MKMapViewDelegate {

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        // 用户位置的蓝点交给系统画；只有「车辆」这个 MKPointAnnotation 需要自定义。
        guard annotation is MKPointAnnotation else { return nil }

        // ★ 故意不用 `dequeueReusableAnnotationView(withIdentifier:)`：本页最多一个
        //   车辆图钉，复用队列只会带来「identifier 对不上、拿不到视图」的坑。
        //   直接 new 一个最简单也最不容易出错。
        let view = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
        // 用 alwaysOriginal 上色：MKAnnotationView 对模板图的着色行为不如 UIImageView 明确，
        // 直接烧进图里最保险。
        view.image = UIImage(systemName: "car.fill")?
            .withTintColor(.lmAccent, renderingMode: .alwaysOriginal)
        view.canShowCallout = true
        return view
    }
}

// MARK: - 地图上的「采集时间」胶囊

/// 半透明黑底 + 白色小字，浮在地图左下角。
/// 对应原页 `mapOverlayPill`。
private final class LMLocMapPill: UIView {

    private let iconView = UIImageView()
    private let label = UILabel()

    init() {
        super.init(frame: .zero)

        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        iconView.image = UIImage(systemName: "clock")
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.numberOfLines = 1

        let row = LMUIKit.hStack(spacing: 5)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("LMLocMapPill 只能代码创建")
    }

    func update(text: String) {
        label.text = text
    }
}

// MARK: - 一行「图标 + 提示文字」

/// 对应原页里散落的 `Label("...", systemImage: "...")` 小字提示。
/// 图标与文字可以各自上色（原页有的行图标带色、文字是灰的）。
private final class LMLocIconNote: UIView {

    private let iconView = UIImageView()
    private let label = UILabel()

    init(icon: String, text: String, iconColor: UIColor,
         textColor: UIColor = .secondaryLabel, size: CGFloat = 12) {
        super.init(frame: .zero)

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        label.numberOfLines = 0

        let row = LMUIKit.hStack(spacing: 6, alignment: .top)
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
        update(icon: icon, text: text, iconColor: iconColor, textColor: textColor, size: size)
    }

    required init?(coder: NSCoder) {
        fatalError("LMLocIconNote 只能代码创建")
    }

    func update(icon: String, text: String, iconColor: UIColor,
                textColor: UIColor = .secondaryLabel, size: CGFloat = 12) {
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = iconColor
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        label.text = text
        label.textColor = textColor
        label.font = .systemFont(ofSize: size)
    }
}

// MARK: - 一行「纬度  31.801201        信号 2190」

/// 对应原页的 `coordRow(_:_:id:)`。
private final class LMLocCoordRow: UIView {

    private let valueLabel = UILabel()

    init(title: String, note: String) {
        super.init(frame: .zero)

        let titleLabel = LMUIKit.label(title, size: 12, color: .secondaryLabel, lines: 1)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true

        valueLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        valueLabel.numberOfLines = 1
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6

        let noteLabel = LMUIKit.label(note, size: 10, color: .tertiaryLabel, lines: 1)
        noteLabel.setContentHuggingPriority(.required, for: .horizontal)
        noteLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 8)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(valueLabel)
        row.addArrangedSubview(LMUIKit.spacer())
        row.addArrangedSubview(noteLabel)
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
        fatalError("LMLocCoordRow 只能代码创建")
    }

    func setValue(_ v: String) {
        valueLabel.text = v
    }
}

// MARK: - 一行「图标 + 键名 ……… 等宽值」

/// 对应原页「车况采集时间 / 坐标未变化」两行：左边小图标 + 灰键名，右边等宽值。
private final class LMLocNoteRow: UIView {

    private let iconView = UIImageView()
    private let keyLabel = UILabel()
    private let valueLabel = UILabel()

    init(icon: String, key: String) {
        super.init(frame: .zero)

        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        keyLabel.text = key
        keyLabel.font = .systemFont(ofSize: 12)
        keyLabel.textColor = .secondaryLabel
        keyLabel.numberOfLines = 1
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)

        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabel
        valueLabel.numberOfLines = 1
        valueLabel.textAlignment = .right
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6

        let row = LMUIKit.hStack(spacing: 8)
        row.addArrangedSubview(iconView)
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
        fatalError("LMLocNoteRow 只能代码创建")
    }

    func update(value: String, color: UIColor,
                icon: String? = nil, iconColor: UIColor? = nil) {
        valueLabel.text = value
        valueLabel.textColor = color
        if let icon { iconView.image = UIImage(systemName: icon) }
        if let iconColor { iconView.tintColor = iconColor }
    }
}

// MARK: - 一行「键 ……… 等宽值」

/// 对应原页 `keyRow(_:_:)`：左边灰色小键名，右边等宽小值（可换行、右对齐）。
private final class LMLocKVRow: UIView {

    private let valueLabel = UILabel()

    init(key: String) {
        super.init(frame: .zero)

        let keyLabel = LMUIKit.label(key, size: 11, color: .secondaryLabel, lines: 1)
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 0
        valueLabel.textAlignment = .right

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
        fatalError("LMLocKVRow 只能代码创建")
    }

    func setValue(_ v: String) {
        valueLabel.text = v
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
