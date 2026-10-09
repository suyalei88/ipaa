//
//  LMSelfTestViewController.swift
//  LeapmotorLite
//
//  算法自检页（UIKit 版）—— 对应原 `Views/SelfTestView.swift`（82 行 SwiftUI List）。
//
//  ★ 这一页是「我装的到底是哪一版」+「签名/加密实现对不对」的合体入口：
//    · 顶部 hero 显示 `N / M 通过`，全通过才是绿勾；
//    · 下方逐条列出 `LMSelfTest.run()` 的结果；
//    · hero 里带 `LMBuildInfo.displayText`（版本号 + 构建 tag + git 指纹），别删。
//
//  迁移约定（跟 `LMLoginViewController` / `LMSettingsViewController` 一致）：
//    · 继承 `LMBaseViewController`，只覆盖 `buildUI()` / `render()` 两个钩子
//    · 自检结果是纯算法产物、跟车端状态无关，所以放 VC 本地属性，不进 `LMClient`
//    · `render()` 必须幂等：结果行数固定但仍是「列表」，照抄设置页的
//      `rebuildIfNeeded(_:signature:)` 指纹模式（结果只算一次，指纹不变就不再重建）
//
import UIKit

final class LMSelfTestViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI / 纯算法，跟车端无关）

    /// `LMSelfTest.run()` 的结果。原页在 `.onAppear` 里跑一次；UIKit 里等价于
    /// `buildUI()` 里跑一次 —— 它是同步纯计算，不依赖网络。
    private var results: [LMSelfTest.Result] = []

    /// 结果列表的内容指纹缓存：指纹没变就整块跳过，避免每次 `render()` 无脑重建。
    private var rebuildCache: [ObjectIdentifier: String] = [:]

    // MARK: - 控件

    private let heroCard = LMCardView(spacing: 8)
    private let heroIcon = UIImageView()
    private let countLabel = UILabel()
    private let heroSubLabel = UILabel()
    private let buildLabel = UILabel()

    private let resultsHeader = LMSectionHeaderLabel("结果")
    private let resultsCard = LMCardView()
    private let resultsStack = LMUIKit.vStack(spacing: 12)

    private let footerLabel = LMUIKit.footnote("""
    这些向量来自 evidence/har_appgw.har 的真实抓包：
    · signKey = 7C2C1588…AC566
    · oppwd("4211") = uHTigfMDS5zIuZX4Gq4NVQ==
    坐标那几条的参考值由 client/test_coord_vectors.py 独立算出。
    全部通过才说明签名与加密实现与官方 App 逐字节一致。
    """)

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "算法自检"

        let (_, stack) = makeScrollStack(spacing: 16, inset: 16)
        stack.addArrangedSubview(heroCard)
        stack.addArrangedSubview(resultsHeader)
        stack.addArrangedSubview(resultsCard)
        stack.addArrangedSubview(footerLabel)

        buildHero()
        resultsCard.contentStack.addArrangedSubview(resultsStack)

        // 原页 `.onAppear { results = LMSelfTest.run() }`：放这里跑一次即可，
        // `render()` 只负责把结果铺到界面上。
        results = LMSelfTest.run()
    }

    private func buildHero() {
        heroIcon.contentMode = .scaleAspectFit
        heroIcon.tintColor = .lmAccent
        heroIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40)
        heroIcon.translatesAutoresizingMaskIntoConstraints = false
        heroIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        heroIcon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        countLabel.font = .systemFont(ofSize: 20, weight: .bold)
        countLabel.textAlignment = .center
        countLabel.numberOfLines = 1

        heroSubLabel.font = .systemFont(ofSize: 12)
        heroSubLabel.textColor = .secondaryLabel
        heroSubLabel.textAlignment = .center
        heroSubLabel.numberOfLines = 0

        buildLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        buildLabel.textColor = .tertiaryLabel
        buildLabel.textAlignment = .center
        buildLabel.numberOfLines = 0
        buildLabel.text = LMBuildInfo.displayText

        // 原页对构建标识开了 `.textSelection(.enabled)`。
        // ★ UILabel 没有 `isSelectable`（那是 UITextView 的成员），写了会编译失败。
        //   要给 UILabel 复制能力，只能自己挂长按手势写剪贴板 —— 同登录页消息卡。
        buildLabel.isUserInteractionEnabled = true
        let press = UILongPressGestureRecognizer(
            target: self, action: #selector(buildInfoLongPressed(_:)))
        press.minimumPressDuration = 0.4
        buildLabel.addGestureRecognizer(press)

        let inner = LMUIKit.vStack(spacing: 10, alignment: .center)
        inner.addArrangedSubview(heroIcon)
        inner.addArrangedSubview(countLabel)
        inner.addArrangedSubview(heroSubLabel)
        inner.addArrangedSubview(buildLabel)
        heroCard.contentStack.addArrangedSubview(inner)
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        renderResults()
    }

    private func renderResults() {
        let passed = results.filter(\.passed).count
        let allPassed = !results.isEmpty && passed == results.count

        heroIcon.image = UIImage(systemName: allPassed
                                 ? "checkmark.seal.fill" : "xmark.seal.fill")
        heroIcon.tintColor = allPassed ? .lmGood : .lmBad
        countLabel.text = "\(passed) / \(results.count) 通过"
        heroSubLabel.text = allPassed
            ? "签名与加密实现与官方 App 逐字节一致"
            : "有不一致项，车控一定不通，先修这个"

        // 结果只算一次，指纹（名字 + 通过与否 + 详情）不变就不会重建。
        let sig = "\(results.count)\u{1}"
            + results.map { "\($0.name)\u{2}\($0.passed)\u{2}\($0.detail)" }
                     .joined(separator: "\u{1}")
        rebuildIfNeeded(resultsStack, signature: sig) {
            results.map { LMSelfTestResultRow(result: $0) }
        }
    }

    /// 行数会变的内容块专用：指纹没变就整块跳过。
    ///
    /// ★ 这里确实动了 `addArrangedSubview`，属于 `render()` 幂等约定的例外；
    ///   可以这么做的原因是这块里**没有用户输入控件**，重建不会打断输入。
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

    @objc private func buildInfoLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let text = buildLabel.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showAlert(title: "已复制", message: text)
    }
}

// MARK: - 一行自检结果

/// 图标 + 名称 + 等宽详情（过长中间截断）。
/// 对应原 SwiftUI 里 `ForEach(results)` 的那段 `VStack`。
private final class LMSelfTestResultRow: UIView {

    init(result: LMSelfTest.Result) {
        super.init(frame: .zero)

        let iconView = UIImageView(image: UIImage(systemName: result.passed
            ? "checkmark.circle.fill" : "xmark.circle.fill"))
        iconView.tintColor = result.passed ? .lmGood : .lmBad
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let nameLabel = UILabel()
        nameLabel.text = result.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 0

        let head = LMUIKit.hStack(spacing: 8, alignment: .top)
        head.addArrangedSubview(iconView)
        head.addArrangedSubview(nameLabel)

        let detailLabel = UILabel()
        detailLabel.text = result.detail
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 3
        detailLabel.lineBreakMode = .byTruncatingMiddle

        let box = LMUIKit.vStack(spacing: 4)
        box.addArrangedSubview(head)
        box.addArrangedSubview(detailLabel)
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMSelfTestResultRow 只能代码创建")
    }
}
