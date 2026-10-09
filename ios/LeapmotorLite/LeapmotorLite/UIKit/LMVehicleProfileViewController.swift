//
//  LMVehicleProfileViewController.swift
//  LeapmotorLite
//
//  「车辆档案」页（UIKit 版）—— 对应原 `Views/VehicleProfileView.swift`（522 行）。
//
//  ★ 数据来源（全部有真实抓包样本，见 `LMEndpoints.Path` 注释）：
//    · vehicle/list                      → 车系 / 年款 / 配置代号 / 能力位 / funcConfig
//    · carpicture/3d/key                 → **精确版型** + 官方 3D 分享页
//    · fota/getCurrentVersion            → 车机固件版本 + 最近一次 OTA 完整更新日志
//    · commoninfo/getBgConf              → 服务端下发的功能开关表
//    · sharecar/getShareVehicleListByVin → 分享记录 + rightList（cmdid 枚举）
//    · appImage/getAppImage              → 模块示意图
//    · msgcenter/…/selectmsgcount        → 消息未读数
//
//  ⚠️ 这一页**纯只读**，没有任何下发按钮 —— 所有车控都在「车控」页。
//     这是刻意的：档案页的价值是「看清楚这台车是什么、支持什么」。
//
//  ★ 迁移约定（与 `LMLoginViewController` / `LMSettingsViewController` 一致）：
//    · 继承 `LMBaseViewController`，只覆盖 `buildUI()` / `render()` 两个钩子
//    · 页内状态（loading）**不进 `LMClient`**，留在 VC 里
//    · `render()` 幂等：固定结构用持久控件 + `isHidden` 折叠；
//      行数会变的四块（cmdid 全集 / OTA 日志 / 功能开关表 / 分享记录）
//      用 `rebuildIfNeeded(_:signature:)` 指纹去重，指纹包含列表全部内容
//
import UIKit

final class LMVehicleProfileViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，跟车端无关）

    private var isLoading = false

    /// 行数会变的内容块专用：内容指纹缓存。
    /// 指纹没变就整块跳过重建 —— `render()` 会被网络回调反复触发，
    /// 无脑重建既浪费又会打断滚动。
    private var rebuildCache: [ObjectIdentifier: String] = [:]

    /// 模块示意图可打开的 URL（按钮用 tag 索引回去，避免按钮闭包捕获 VC）。
    private var appImageOpenURLs: [URL] = []
    /// 3D 车模官方分享页 URL（nil = 不显示按钮）。
    private var threeDShareURL: URL?

    // MARK: - 加载提示

    private let loadingRow = LMUIKit.hStack(spacing: 8)
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()

    // MARK: - ① 车辆身份

    private let identitySection = LMUIKit.vStack(spacing: 10)
    private let identityHeader = LMSectionHeaderLabel("车辆身份")
    private let identityCard = LMCardView(padding: 14, spacing: 9)
    private let identityNameLabel = UILabel()
    private let vinRow = LMProfileInfoRow(key: "VIN")
    private let carTypeRow = LMProfileInfoRow(key: "车系 / 车型")
    private let yearRow = LMProfileInfoRow(key: "年款")
    private let editionRow = LMProfileInfoRow(key: "版型")
    private let outColorRow = LMProfileInfoRow(key: "车漆颜色")
    private let roofColorRow = LMProfileInfoRow(key: "车顶颜色代号")
    private let allocationRow = LMProfileInfoRow(key: "配置代号")
    private let carIdRow = LMProfileInfoRow(key: "carId")
    private let cccRow = LMProfileInfoRow(key: "CCC 数字钥匙")
    private let seatRow = LMProfileInfoRow(key: "座椅布局代码")
    private let plateRow = LMProfileInfoRow(key: "车牌号")

    private let abilitiesCard = LMCardView(padding: 14, spacing: 6)
    private let abilitiesTitleLabel = UILabel()
    private let abilitiesTextLabel = UILabel()
    private let abilitiesNoteLabel = UILabel()

    // MARK: - ② 空调能力范围

    private let hvacSection = LMUIKit.vStack(spacing: 10)
    private let hvacHeader = LMSectionHeaderLabel("空调能力范围")
    private let hvacCard = LMCardView(padding: 14, spacing: 9)
    private let fanRow = LMProfileInfoRow(key: "风量")
    private let tempRow = LMProfileInfoRow(key: "温度")
    private let hvacMissingLabel = UILabel()
    private let hvacNoteLabel = UILabel()

    // MARK: - ③ 车机固件 / OTA

    private let fotaSection = LMUIKit.vStack(spacing: 10)
    private let fotaHeader = LMSectionHeaderLabel("车机固件 / 最近一次 OTA")
    private let fotaCard = LMCardView(padding: 14, spacing: 9)
    private let versionRow = LMProfileInfoRow(key: "当前版本")
    private let updateTimeRow = LMProfileInfoRow(key: "升级时间")
    private let logCard = LMCardView(padding: 14, spacing: 7)
    private let logTitleLabel = UILabel()
    private let logStack = LMUIKit.vStack(spacing: 7)

    // MARK: - ④ 功能开关

    private let bgSection = LMUIKit.vStack(spacing: 10)
    private let bgHeader = LMSectionHeaderLabel("功能开关（服务端下发）")
    private let bgCard = LMCardView(padding: 14, spacing: 8)
    private let bgStack = LMUIKit.vStack(spacing: 8)
    private let bgFooterLabel = UILabel()

    // MARK: - ⑤ 车辆分享

    private let shareSection = LMUIKit.vStack(spacing: 10)
    private let shareHeader = LMSectionHeaderLabel("车辆分享")
    private let shareStack = LMUIKit.vStack(spacing: 10)
    private let shareFooterLabel = UILabel()

    // MARK: - ⑥ cmdid 路线图

    private let roadmapSection = LMUIKit.vStack(spacing: 10)
    private let roadmapHeader = LMSectionHeaderLabel("车控指令全集（路线图）")
    private let roadmapCard = LMCardView(padding: 14, spacing: 10)
    private let roadmapStack = LMUIKit.vStack(spacing: 10)

    // MARK: - ⑦ 模块示意图

    private let appImageSection = LMUIKit.vStack(spacing: 10)
    private let appImageHeader = LMSectionHeaderLabel("模块示意图")
    private let appStack = LMUIKit.vStack(spacing: 10)

    // MARK: - ⑧ 3D 车模

    private let threeDSection = LMUIKit.vStack(spacing: 10)
    private let threeDHeader = LMSectionHeaderLabel("3D 车模")
    private let threeDCard = LMCardView(padding: 14, spacing: 9)
    private let h5KeyRow = LMProfileInfoRow(key: "h5Key")
    private let srcKeyRow = LMProfileInfoRow(key: "srcKey")
    private let modelTypeRow = LMProfileInfoRow(key: "modelType")
    private let edition3DRow = LMProfileInfoRow(key: "版型")
    private let colorCodeRow = LMProfileInfoRow(key: "颜色代号")
    private let threeDShareButton = UIButton()

    // MARK: - ⑨ 消息

    private let noticeSection = LMUIKit.vStack(spacing: 10)
    private let noticeHeader = LMSectionHeaderLabel("消息")
    private let noticeCard = LMCardView(padding: 14, spacing: 9)
    private let unreadRow = LMProfileInfoRow(key: "未读")
    private let totalRow = LMProfileInfoRow(key: "总数")
    private let alreadyreadRow = LMProfileInfoRow(key: "已读")
    private let usertotalRow = LMProfileInfoRow(key: "用户消息")
    private let devicetotalRow = LMProfileInfoRow(key: "车辆消息")

    // MARK: - ⑩ 本次加载情况

    private let loadLogSection = LMUIKit.vStack(spacing: 10)
    private let loadLogHeader = LMSectionHeaderLabel("本次加载情况")
    private let loadLogCard = LMCardView(padding: 14, spacing: 5)
    private let loadLogStack = LMUIKit.vStack(spacing: 5)
    private let loadLogFooterLabel = UILabel()

    // MARK: - 搭界面（只跑一次）

    override func buildUI() {
        title = "车辆档案"
        navigationItem.largeTitleDisplayMode = .always

        let (scroll, stack) = makeScrollStack(spacing: 18, inset: 16)

        buildLoadingRow()
        stack.addArrangedSubview(loadingRow)

        buildIdentitySection()
        stack.addArrangedSubview(identitySection)

        buildHVACSection()
        stack.addArrangedSubview(hvacSection)

        buildFotaSection()
        stack.addArrangedSubview(fotaSection)

        buildBgSection()
        stack.addArrangedSubview(bgSection)

        buildShareSection()
        stack.addArrangedSubview(shareSection)

        buildRoadmapSection()
        stack.addArrangedSubview(roadmapSection)

        buildAppImageSection()
        stack.addArrangedSubview(appImageSection)

        build3DSection()
        stack.addArrangedSubview(threeDSection)

        buildNoticeSection()
        stack.addArrangedSubview(noticeSection)

        buildLoadLogSection()
        stack.addArrangedSubview(loadLogSection)

        // 对应原页 `.refreshable { await reload() }`
        attachRefresh(scroll) { [weak self] in
            await self?.reload()
        }
        // 对应原页 `.task { await reload() }`：首帧先拉一遍。
        // ★ 用 `Task { @MainActor }` 而不是 `DispatchQueue.main.async`（原因见基类）。
        Task { @MainActor [weak self] in
            await self?.reload()
        }
    }

    // MARK: - 各区块搭树

    private func buildLoadingRow() {
        loadingSpinner.hidesWhenStopped = true
        loadingLabel.text = "正在读取车辆档案…"
        loadingLabel.font = .systemFont(ofSize: 12)
        loadingLabel.textColor = .secondaryLabel
        loadingRow.addArrangedSubview(loadingSpinner)
        loadingRow.addArrangedSubview(loadingLabel)
        loadingRow.addArrangedSubview(LMUIKit.spacer())
        loadingRow.isHidden = true
    }

    private func buildIdentitySection() {
        identitySection.addArrangedSubview(identityHeader)

        let icon = UIImageView(image: UIImage(systemName: "car.fill"))
        icon.tintColor = .lmAccent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18)
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        identityNameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        identityNameLabel.numberOfLines = 1

        let head = LMUIKit.hStack(spacing: 10)
        head.addArrangedSubview(icon)
        head.addArrangedSubview(identityNameLabel)
        head.addArrangedSubview(LMUIKit.spacer())
        identityCard.contentStack.addArrangedSubview(head)

        [vinRow, carTypeRow, yearRow, editionRow, outColorRow, roofColorRow,
         allocationRow, carIdRow, cccRow, seatRow, plateRow]
            .forEach { identityCard.contentStack.addArrangedSubview($0) }
        identitySection.addArrangedSubview(identityCard)

        // 能力位（数量不定，但结构固定，只改文本不重建）
        abilitiesTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        abilitiesTextLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        abilitiesTextLabel.textColor = .secondaryLabel
        abilitiesTextLabel.numberOfLines = 0
        // UILabel 没有 isSelectable（那是 UITextView 的），要复制只能自己挂长按。
        abilitiesTextLabel.isUserInteractionEnabled = true
        let press = UILongPressGestureRecognizer(
            target: self, action: #selector(copyLabelLongPressed(_:)))
        press.minimumPressDuration = 0.4
        abilitiesTextLabel.addGestureRecognizer(press)

        abilitiesNoteLabel.font = .systemFont(ofSize: 11)
        abilitiesNoteLabel.textColor = .secondaryLabel
        abilitiesNoteLabel.numberOfLines = 0
        abilitiesNoteLabel.text =
            "⚠️ 这些码的含义官方没有公开，我们也没有样本能把码位和功能对应起来。"
            + "这里只按原样排序展示，用途是「换车 / 换版本后对比这串码变没变」。"

        abilitiesCard.contentStack.addArrangedSubview(abilitiesTitleLabel)
        abilitiesCard.contentStack.addArrangedSubview(abilitiesTextLabel)
        abilitiesCard.contentStack.addArrangedSubview(abilitiesNoteLabel)
        identitySection.addArrangedSubview(abilitiesCard)
    }

    private func buildHVACSection() {
        hvacSection.addArrangedSubview(hvacHeader)

        hvacMissingLabel.font = .systemFont(ofSize: 12)
        hvacMissingLabel.textColor = .secondaryLabel
        hvacMissingLabel.numberOfLines = 0
        hvacMissingLabel.text = "这台车的 vehicle/list 没有返回 funcConfig，无法确定档位范围。"

        hvacNoteLabel.font = .systemFont(ofSize: 11)
        hvacNoteLabel.textColor = .secondaryLabel
        hvacNoteLabel.numberOfLines = 0
        hvacNoteLabel.text = hvacNoteText

        hvacCard.contentStack.addArrangedSubview(fanRow)
        hvacCard.contentStack.addArrangedSubview(tempRow)
        hvacCard.contentStack.addArrangedSubview(hvacMissingLabel)
        hvacCard.contentStack.addArrangedSubview(makeSeparator())
        hvacCard.contentStack.addArrangedSubview(hvacNoteLabel)
        hvacSection.addArrangedSubview(hvacCard)
    }

    private func buildFotaSection() {
        fotaSection.addArrangedSubview(fotaHeader)

        fotaCard.contentStack.addArrangedSubview(versionRow)
        fotaCard.contentStack.addArrangedSubview(updateTimeRow)
        fotaSection.addArrangedSubview(fotaCard)

        logTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        logCard.contentStack.addArrangedSubview(logTitleLabel)
        logCard.contentStack.addArrangedSubview(logStack)
        logCard.isHidden = true
        fotaSection.addArrangedSubview(logCard)
    }

    private func buildBgSection() {
        bgSection.addArrangedSubview(bgHeader)
        bgCard.contentStack.addArrangedSubview(bgStack)
        bgSection.addArrangedSubview(bgCard)

        bgFooterLabel.font = .systemFont(ofSize: 11)
        bgFooterLabel.textColor = .secondaryLabel
        bgFooterLabel.numberOfLines = 0
        bgFooterLabel.text =
            "⚠️ 这些开关由服务端 / 车端决定，本 App **只读不改**。"
            + "中文名是按字段名直译的，不是官方文档。"
            + "比如「无感蓝牙钥匙」是关的，就解释了为什么靠不靠近都不会自动解锁。"
        bgSection.addArrangedSubview(bgFooterLabel)
    }

    private func buildShareSection() {
        shareSection.addArrangedSubview(shareHeader)
        shareSection.addArrangedSubview(shareStack)

        shareFooterLabel.font = .systemFont(ofSize: 11)
        shareFooterLabel.textColor = .secondaryLabel
        shareFooterLabel.numberOfLines = 0
        shareSection.addArrangedSubview(shareFooterLabel)
    }

    private func buildRoadmapSection() {
        roadmapSection.addArrangedSubview(roadmapHeader)
        roadmapCard.contentStack.addArrangedSubview(roadmapStack)
        roadmapSection.addArrangedSubview(roadmapCard)
    }

    private func buildAppImageSection() {
        appImageSection.addArrangedSubview(appImageHeader)
        appImageSection.addArrangedSubview(appStack)
    }

    private func build3DSection() {
        threeDSection.addArrangedSubview(threeDHeader)

        threeDCard.contentStack.addArrangedSubview(h5KeyRow)
        threeDCard.contentStack.addArrangedSubview(srcKeyRow)
        threeDCard.contentStack.addArrangedSubview(modelTypeRow)
        threeDCard.contentStack.addArrangedSubview(edition3DRow)
        threeDCard.contentStack.addArrangedSubview(colorCodeRow)

        threeDShareButton.configuration = LMUIKit.plainButton(
            "打开官方 3D 车模分享页", tint: .lmAccent).configuration
        threeDShareButton.configuration?.image = UIImage(systemName: "safari")
        threeDShareButton.configuration?.imagePadding = 6
        threeDShareButton.addTarget(self, action: #selector(open3DShareTapped),
                                    for: .touchUpInside)
        threeDShareButton.isHidden = true
        threeDCard.contentStack.addArrangedSubview(threeDShareButton)

        threeDSection.addArrangedSubview(threeDCard)
    }

    private func buildNoticeSection() {
        noticeSection.addArrangedSubview(noticeHeader)
        [unreadRow, totalRow, alreadyreadRow, usertotalRow, devicetotalRow]
            .forEach { noticeCard.contentStack.addArrangedSubview($0) }
        noticeSection.addArrangedSubview(noticeCard)
    }

    private func buildLoadLogSection() {
        loadLogSection.addArrangedSubview(loadLogHeader)
        loadLogCard.contentStack.addArrangedSubview(loadLogStack)
        loadLogSection.addArrangedSubview(loadLogCard)

        loadLogFooterLabel.font = .systemFont(ofSize: 11)
        loadLogFooterLabel.textColor = .secondaryLabel
        loadLogFooterLabel.numberOfLines = 0
        loadLogFooterLabel.text =
            "某个接口失败不影响其它内容显示 —— 每个接口都单独兜错了。下拉可重新加载。"
        loadLogSection.addArrangedSubview(loadLogFooterLabel)
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        renderLoading()
        renderIdentity()
        renderHVAC()
        renderFota()
        renderBgConf()
        renderShare()
        renderRoadmap()
        renderAppImages()
        render3D()
        renderNotice()
        renderLoadLog()
    }

    private func renderLoading() {
        let show = isLoading && client.profileLoadLog.isEmpty
        loadingRow.isHidden = !show
        if show { loadingSpinner.startAnimating() } else { loadingSpinner.stopAnimating() }
    }

    private func renderIdentity() {
        guard let v = client.selectedVehicle else {
            identitySection.isHidden = true
            return
        }
        identitySection.isHidden = false

        identityNameLabel.text = v.displayName
        vinRow.setValue(v.vin)
        carTypeRow.setValue(lmNonEmpty(v.carType) ?? "--")
        yearRow.setValue(v.yearText)
        // ★ 精确版型只有 3D 接口才有 —— vehicle/list 的 carConfigEdition 实测是空串。
        editionRow.setValue(trimText ?? lmNonEmpty(v.carConfigEdition) ?? "接口未提供")
        outColorRow.setValue(lmNonEmpty(v.outColor) ?? "--")
        roofColorRow.setValue(lmNonEmpty(v.roofColor) ?? "--")
        allocationRow.setValue(v.allocationCode.map { String($0) } ?? "--")
        carIdRow.setValue(v.carId.map { String($0) } ?? "--")
        cccRow.setValue(lmNonEmpty(v.cccVehicleId) ?? "未绑定（null）")
        seatRow.setValue(v.seatLayout.map { String($0) } ?? "--")
        plateRow.setValue(lmNonEmpty(v.plateNumber) ?? "--")

        let abilities = v.abilities ?? []
        abilitiesCard.isHidden = abilities.isEmpty
        if !abilities.isEmpty {
            abilitiesTitleLabel.text = "能力位（\(abilities.count) 个）"
            abilitiesTextLabel.text = v.abilitiesSortedText
        }
    }

    private func renderHVAC() {
        guard let v = client.selectedVehicle else {
            hvacSection.isHidden = true
            return
        }
        hvacSection.isHidden = false

        if let f = v.hvacFanRange {
            fanRow.isHidden = false
            fanRow.setValue(f.rangeText)
        } else {
            fanRow.isHidden = true
        }
        if let t = v.hvacTempRange {
            tempRow.isHidden = false
            tempRow.setValue(t.rangeText)
        } else {
            tempRow.isHidden = true
        }
        hvacMissingLabel.isHidden = (v.funcConfig != nil)
    }

    private func renderFota() {
        guard let f = client.fotaVersion else {
            fotaSection.isHidden = true
            return
        }
        fotaSection.isHidden = false

        versionRow.setValue(lmNonEmpty(f.versionNo) ?? "--")
        updateTimeRow.setValue(lmNonEmpty(f.updateTime) ?? "--")

        let lines = f.logLines
        logCard.isHidden = lines.isEmpty
        guard !lines.isEmpty else { return }
        logTitleLabel.text = "更新日志（\(lines.count) 行）"
        rebuildIfNeeded(logStack, signature: lines.count.description + "\u{1}"
                        + lines.joined(separator: "\u{1}")) {
            lines.map { line -> UIView in
                self.makeCopyableLine(line, size: 11)
            }
        }
    }

    private func renderBgConf() {
        guard let b = client.bgConf, !b.flags.isEmpty else {
            bgSection.isHidden = true
            return
        }
        bgSection.isHidden = false

        let flags = b.flags
        rebuildIfNeeded(bgStack, signature: flags.map { "\($0.name)=\($0.on)" }
            .joined(separator: "\u{1}")) {
            flags.map { f -> UIView in
                let icon = UIImageView(image: UIImage(systemName: f.on
                                                      ? "checkmark.circle.fill"
                                                      : "xmark.circle"))
                icon.tintColor = f.on ? .lmGood : .secondaryLabel
                icon.contentMode = .scaleAspectFit
                icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13)
                icon.setContentHuggingPriority(.required, for: .horizontal)

                let name = LMUIKit.label(f.name, size: 12)
                let state = LMUIKit.label(f.on ? "开" : "关", size: 11, weight: .semibold,
                                          color: f.on ? .lmGood : .secondaryLabel)
                state.setContentHuggingPriority(.required, for: .horizontal)

                let row = LMUIKit.hStack(spacing: 8)
                row.addArrangedSubview(icon)
                row.addArrangedSubview(name)
                row.addArrangedSubview(LMUIKit.spacer())
                row.addArrangedSubview(state)
                return row
            }
        }
    }

    private func renderShare() {
        guard let s = client.shareList else {
            shareSection.isHidden = true
            return
        }
        shareSection.isHidden = false

        shareFooterLabel.text =
            "最多可分享给 \(lmNonEmpty(s.shareMaxCount) ?? "?") 个账号。\n"
            + "「模块权限」是模块级授权（100/200/400）；下面那串 cmdid 是"
            + "**这一条分享**允许对方使用的指令。"

        let list = s.carShareInfoList ?? []
        // 指纹必须覆盖每条分享里**所有会显示的字段**（含 rights 的逐个值），
        // 否则服务端改了授权指令，列表却不会重建。
        let sig = (list.isEmpty ? "empty" : "n:\(list.count)") + "\u{1}"
            + list.map { info in
                "\(info.id)|\(info.nickName ?? "-")|\(info.mobileNumber ?? "-")"
                + "|\(info.moduleRights ?? "-")|\(info.shareTimeText)|\(info.durationText)"
                + "|\(info.rights.map { String($0) }.joined(separator: ","))"
            }.joined(separator: "\u{1}")

        rebuildIfNeeded(shareStack, signature: sig) {
            if list.isEmpty {
                let card = LMCardView(padding: 14)
                card.contentStack.addArrangedSubview(
                    LMUIKit.label("没有分享记录 —— 这台车没有授权给其他账号。",
                                  size: 12, color: .secondaryLabel))
                return [card]
            }
            return list.map { info -> UIView in self.makeShareInfoCard(info) }
        }
    }

    private func renderRoadmap() {
        let all = LMEndpoints.allKnownCmdids
        let implemented = LMEndpoints.implementedCmdids
        let rights = LMEndpoints.knownModuleRights

        let sig = "\(implemented.count)|\(all.map { String($0) }.joined(separator: ","))"
            + "|\(rights.map { String($0) }.joined(separator: ","))"
        rebuildIfNeeded(roadmapStack, signature: sig) {
            var views: [UIView] = []

            let implLabel = LMUIKit.label("已实现 \(implemented.count) 个",
                                          size: 12, weight: .semibold, color: .lmGood)
            let dotLabel = LMUIKit.label("·", size: 12, color: .secondaryLabel)
            let knownLabel = LMUIKit.label("已知 \(all.count) 个",
                                           size: 12, weight: .semibold, color: .secondaryLabel)
            let counts = LMUIKit.hStack(spacing: 6)
            counts.addArrangedSubview(implLabel)
            counts.addArrangedSubview(dotLabel)
            counts.addArrangedSubview(knownLabel)
            counts.addArrangedSubview(LMUIKit.spacer())
            views.append(counts)

            views.append(self.makeChipFlow(all))

            for id in rights { views.append(self.makeModuleRightRow(id)) }

            views.append(self.makeSeparator())

            let legend = UILabel()
            legend.text = self.roadmapLegendText
            legend.font = .systemFont(ofSize: 11)
            legend.textColor = .secondaryLabel
            legend.numberOfLines = 0
            views.append(legend)

            return views
        }
    }

    private func renderAppImages() {
        let modules = client.appImages
        guard !modules.isEmpty else {
            appImageSection.isHidden = true
            return
        }
        appImageSection.isHidden = false

        // 先把可打开 URL 按遍历顺序平铺，按钮用 tag 索引回去 ——
        // 这样按钮只挂 target/selector，不用闭包捕获 VC（闭包不继承 @MainActor）。
        var urls: [URL] = []
        for m in modules {
            for sub in (m.subModule ?? []) {
                let t = sub.image ?? ""
                if !t.isEmpty, let u = URL(string: t) { urls.append(u) }
            }
        }
        appImageOpenURLs = urls

        let sig = modules.map { m in
            "\(m.moduleId ?? -1)|\(m.moduleName ?? "-")|"
            + (m.subModule ?? []).map { "\($0.subModuleName ?? "-")=\($0.image ?? "-")" }
                .joined(separator: ",")
        }.joined(separator: "\u{1}")

        var urlIndex = 0
        rebuildIfNeeded(appStack, signature: sig) {
            modules.map { m -> UIView in
                let card = LMCardView(padding: 14, spacing: 8)
                card.contentStack.addArrangedSubview(
                    LMUIKit.label(lmNonEmpty(m.moduleName) ?? "模块 \(m.moduleId ?? -1)",
                                  size: 15, weight: .medium))
                for sub in (m.subModule ?? []) {
                    let box = LMUIKit.vStack(spacing: 4)
                    box.addArrangedSubview(
                        LMUIKit.label(lmNonEmpty(sub.subModuleName) ?? "示意图",
                                      size: 11, color: .secondaryLabel))
                    let t = sub.image ?? ""
                    if !t.isEmpty, URL(string: t) != nil {
                        let b = LMUIKit.plainButton("打开示意图", tint: .lmAccent)
                        b.configuration?.image = UIImage(systemName: "photo")
                        b.configuration?.imagePadding = 6
                        b.tag = urlIndex
                        urlIndex += 1
                        b.addTarget(self,
                                    action: #selector(LMVehicleProfileViewController
                                        .appImageOpenTapped(_:)),
                                    for: .touchUpInside)
                        box.addArrangedSubview(b)
                    } else {
                        box.addArrangedSubview(
                            LMUIKit.label("没有图片地址", size: 11, color: .secondaryLabel))
                    }
                    card.contentStack.addArrangedSubview(box)
                }
                return card
            }
        }
    }

    private func render3D() {
        guard let k = client.car3DKey else {
            threeDSection.isHidden = true
            threeDShareURL = nil
            return
        }
        threeDSection.isHidden = false

        h5KeyRow.setValue(lmNonEmpty(k.h5Key) ?? "--")
        srcKeyRow.setValue(lmNonEmpty(k.srcKey) ?? "--")
        modelTypeRow.setValue(k.modelType.map { String($0) } ?? "--")

        if let p = k.modelParam {
            edition3DRow.isHidden = false
            edition3DRow.setValue(lmNonEmpty(p.carTypeCode) ?? "--")
            colorCodeRow.isHidden = false
            colorCodeRow.setValue(p.colorCode.map { String($0) } ?? "--")
        } else {
            edition3DRow.isHidden = true
            colorCodeRow.isHidden = true
        }

        if let u = k.shareBindUrl, let url = URL(string: u) {
            threeDShareURL = url
            threeDShareButton.isHidden = false
        } else {
            threeDShareURL = nil
            threeDShareButton.isHidden = true
        }
    }

    private func renderNotice() {
        guard let n = client.noticeCount else {
            noticeSection.isHidden = true
            return
        }
        noticeSection.isHidden = false
        unreadRow.setValue(String(n.unread ?? 0))
        totalRow.setValue(String(n.total ?? 0))
        alreadyreadRow.setValue(String(n.alreadyread ?? 0))
        usertotalRow.setValue(String(n.usertotal ?? 0))
        devicetotalRow.setValue(String(n.devicetotal ?? 0))
    }

    private func renderLoadLog() {
        let log = client.profileLoadLog
        loadLogSection.isHidden = log.isEmpty
        guard !log.isEmpty else { return }
        rebuildIfNeeded(loadLogStack, signature: log.count.description + "\u{1}"
                        + log.joined(separator: "\u{1}")) {
            log.map { line -> UIView in
                self.makeCopyableLine(line, size: 11)
            }
        }
    }

    // MARK: - 重建内容块的小工厂

    private func makeShareInfoCard(_ info: LMShareInfo) -> UIView {
        let card = LMCardView(padding: 14, spacing: 8)

        let icon = UIImageView(image: UIImage(systemName: "person.crop.circle"))
        icon.tintColor = .lmPurple
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16)
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let duration = LMUIKit.label(info.durationText, size: 11, color: .secondaryLabel)
        duration.setContentHuggingPriority(.required, for: .horizontal)

        let head = LMUIKit.hStack(spacing: 8)
        head.addArrangedSubview(icon)
        head.addArrangedSubview(
            LMUIKit.label(lmNonEmpty(info.nickName) ?? "未命名", size: 15, weight: .medium))
        head.addArrangedSubview(LMUIKit.spacer())
        head.addArrangedSubview(duration)
        card.contentStack.addArrangedSubview(head)

        card.contentStack.addArrangedSubview(
            LMProfileInfoRow(key: "手机号", value: lmNonEmpty(info.mobileNumber) ?? "--"))
        card.contentStack.addArrangedSubview(
            LMProfileInfoRow(key: "分享时间", value: info.shareTimeText))
        card.contentStack.addArrangedSubview(
            LMProfileInfoRow(key: "模块权限", value: lmNonEmpty(info.moduleRights) ?? "--"))

        let rights = info.rights
        if !rights.isEmpty {
            let box = LMUIKit.vStack(spacing: 6)
            box.addArrangedSubview(
                LMUIKit.label("可用指令 cmdid（\(rights.count) 个）",
                              size: 11, color: .secondaryLabel))
            box.addArrangedSubview(makeChipFlow(rights))
            card.contentStack.addArrangedSubview(box)
        }
        return card
    }

    /// 一列 cmdid 小方块（自适应列数，等价 SwiftUI 的 LazyVGrid(.adaptive(minimum: 52))）。
    private func makeChipFlow(_ ids: [Int]) -> UIView {
        LMCmdChipFlowView(chips: ids.map { makeChip($0) })
    }

    private func makeChip(_ id: Int) -> UIView {
        let done = LMEndpoints.implementedCmdids.contains(id)
        let tone: UIColor = done ? .lmGood : .secondaryLabel
        let chip = LMCmdChipLabel(frame: .zero)
        chip.text = "\(id)"
        chip.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        chip.textColor = tone
        chip.textAlignment = .center
        chip.numberOfLines = 1
        chip.backgroundColor = tone.withAlphaComponent(0.12)
        chip.layer.cornerRadius = 7
        chip.layer.cornerCurve = .continuous
        chip.layer.masksToBounds = true
        return chip
    }

    private func makeModuleRightRow(_ id: Int) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "square.stack.3d.up.fill"))
        icon.tintColor = .lmTeal
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11)
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let name = UILabel()
        name.text = "模块权限 \(id)"
        name.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        name.textColor = .secondaryLabel
        name.setContentHuggingPriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 8)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(name)
        if id == 400 {
            row.addArrangedSubview(
                LMUIKit.label("= 上电，本 App 已实现", size: 11, color: .lmGood))
        }
        row.addArrangedSubview(LMUIKit.spacer())
        return row
    }

    /// 一段可换行、可长按复制的等宽小字（OTA 日志 / 加载日志）。
    private func makeCopyableLine(_ text: String, size: CGFloat) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        l.isUserInteractionEnabled = true
        let press = UILongPressGestureRecognizer(
            target: self, action: #selector(copyLabelLongPressed(_:)))
        press.minimumPressDuration = 0.4
        l.addGestureRecognizer(press)
        return l
    }

    /// 1 物理像素的分隔线。用 `traitCollection.displayScale`（`UIScreen.main` 已弃用）。
    private func makeSeparator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        let scale = max(1, traitCollection.displayScale)
        line.heightAnchor.constraint(equalToConstant: 1.0 / scale).isActive = true
        return line
    }

    /// 行数会变的内容块专用：指纹没变就整块跳过。
    ///
    /// ★ 这里确实动了 `addArrangedSubview`，属于 `render()` 幂等约定的例外 ——
    ///   可以这么做是因为这些块里**没有用户输入控件**，重建不会打断输入。
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

    private func reload() async {
        isLoading = true
        render()
        await client.refreshVehicleProfile()
        try? await client.refreshNoticeCount()
        isLoading = false
        render()
    }

    @objc private func open3DShareTapped() {
        guard let url = threeDShareURL else { return }
        UIApplication.shared.open(url)
    }

    @objc private func appImageOpenTapped(_ sender: UIButton) {
        let i = sender.tag
        guard i >= 0, i < appImageOpenURLs.count else { return }
        UIApplication.shared.open(appImageOpenURLs[i])
    }

    /// 长按复制（`UILabel` 没有 `isSelectable`，复制能力只能自己给）。
    @objc private func copyLabelLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let label = g.view as? UILabel,
              let text = label.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - 文案

    /// ⚠️ 长文案先算成 String 再交给控件（原因见原 SwiftUI 版注释：
    ///    段数一多会让类型检查器超时）。这里是 `+` 拼的 String，不解析 markdown。
    private var hvacNoteText: String {
        "★ 这是「空调到底有几档」的唯一权威来源。\n"
        + "⚠️ 2026-10-08 修正：这里以前写「抓包里 cmdid 230 只出现过 "
        + "{\"value\":\"0\"|\"2\"|\"5\"}，很容易让人以为空调就三档」"
        + "—— 那句话是错的。230 是车窗，不是空调；"
        + "车窗确实只有三个开度（关 / 微开 / 半开），跟空调档位无关。\n"
        + "空调的风量是 1~9 档、温度是 16~32 °C，就是上面这两个范围。\n"
        + "这只证明车支持这些档位，没有证明 {\"operate\":\"manual\",…} "
        + "这种 payload 服务端一定接受 —— 所以车控页把风量 / 温度"
        + "单独放在标注了「未验证」的卡片里。"
    }

    private var roadmapLegendText: String {
        "绿色 = 本 App 已实现（有抓包确认的 payload）。\n"
        + "灰色 = 已知编号但语义未确认，没有可靠 payload，故意不做 —— "
        + "对一台真车下发「不知道干什么」的指令是不负责任的。\n"
        + "这 \(LMEndpoints.allKnownCmdids.count) 个编号来自 "
        + "sharecar 接口的 rightList（见上方「车辆分享」）。"
    }

    /// 精确版型（只有 `carpicture/3d/key` 的 modelParam.carTypeCode 才有）。
    private var trimText: String? {
        lmNonEmpty(client.car3DKey?.modelParam?.carTypeCode)
    }
}

// MARK: - 一行「键 —— 值」

/// 左边固定宽度灰色键名，右边等宽值（可换行、可长按复制）。
/// 对应原 SwiftUI 的 `infoRow(_:_:)`（key 宽 112、`.textSelection(.enabled)`）。
private final class LMProfileInfoRow: UIView {

    private let keyLabel = UILabel()
    private let valueLabel = UILabel()

    init(key: String, value: String = "") {
        super.init(frame: .zero)

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
        valueLabel.lineBreakMode = .byCharWrapping
        // 允许被压窄换行，不要撑破卡片
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 10, alignment: .top)
        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(valueLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            keyLabel.widthAnchor.constraint(equalToConstant: 112),
        ])

        // UILabel 没有 isSelectable —— 复制只能自己挂长按手势。
        let press = UILongPressGestureRecognizer(target: self, action: #selector(copyValue))
        press.minimumPressDuration = 0.4
        addGestureRecognizer(press)
    }

    required init?(coder: NSCoder) {
        fatalError("LMProfileInfoRow 只能代码创建")
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

// MARK: - cmdid 小方块

/// 带内边距的等宽小方块。`drawText` 内缩让文字居中于背景色块里。
private final class LMCmdChipLabel: UILabel {

    private let hInset: CGFloat = 8
    private let vInset: CGFloat = 5

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("LMCmdChipLabel 只能代码创建")
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + hInset * 2, height: s.height + vInset * 2)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: hInset, dy: vInset))
    }
}

/// 把一堆 chip 按当前宽度铺成自适应列数的网格。
/// 等价于原 SwiftUI 的 `LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)])`。
///
/// ★ 不参与 Auto Layout 的子视图用 frame 手工摆放；本视图自身高度靠
///   `intrinsicContentSize` 上报（宽度变化会重新算行数并 invalidate）。
private final class LMCmdChipFlowView: UIView {

    private let spacing: CGFloat = 6
    private let minChipWidth: CGFloat = 52
    private let chips: [UIView]
    private var lastHeight: CGFloat = 0

    init(chips: [UIView]) {
        self.chips = chips
        super.init(frame: .zero)
        chips.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("LMCmdChipFlowView 只能代码创建")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let h = performLayout(width: bounds.width)
        if abs(h - lastHeight) > 0.5 {
            lastHeight = h
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: lastHeight)
    }

    @discardableResult
    private func performLayout(width: CGFloat) -> CGFloat {
        guard !chips.isEmpty else { return 0 }
        let cols = max(1, Int((width + spacing) / (minChipWidth + spacing)))
        let chipWidth = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (i, chip) in chips.enumerated() {
            if i > 0 && i % cols == 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            let h = chip.intrinsicContentSize.height
            chip.frame = CGRect(x: x, y: y, width: chipWidth, height: h)
            x += chipWidth + spacing
            rowHeight = max(rowHeight, h)
        }
        return y + rowHeight
    }
}

// MARK: - 小工具

/// 去掉 nil 和「只有空白」的字符串。定义成文件内自由函数，
/// 好让嵌套的私有小类也能用（且不受主 actor 隔离影响）。
private func lmNonEmpty(_ s: String?) -> String? {
    guard let s = s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return s
}
