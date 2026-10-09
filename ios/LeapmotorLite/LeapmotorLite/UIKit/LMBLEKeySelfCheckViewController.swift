//
//  LMBLEKeySelfCheckViewController.swift
//  LeapmotorLite
//
//  协议自检页（UIKit 版）—— 对应 `Views/BLEKeyView.swift` 里的 `BLEKeySelfCheckView`。
//
//  ★ 同样是一页**纯静态**内容：结果由 `LMBLEKeySelfCheck.run()` 在 `buildUI()` 里
//    跑一次算出（对应原页 `private let results = LMBLEKeySelfCheck.run()`），
//    之后不再变化，所以 `render()` 保持空实现。
//
//  ⚠️ 自检只保证「解析层」正确（MAC 排版 / config["4"] 构造 / hex 容错 / 分号帧切分），
//    帧的**语义**还没定 —— 别把「通过」理解成「协议已通」。
//
import UIKit

final class LMBLEKeySelfCheckViewController: LMBaseViewController {

    /// 自检结果。放 `buildUI()` 里算一次，不放在属性初始化器里 ——
    /// 属性初始化器只放纯构造，任何方法调用都挪进 `buildUI()`。
    private var results: [LMBLEKeyCheck] = []

    private var passedCount: Int { results.filter(\.passed).count }

    override func buildUI() {
        title = "协议自检"

        results = LMBLEKeySelfCheck.run()

        let (_, stack) = makeScrollStack(spacing: 18, inset: 16)

        // ---- 通过数汇总 ----
        let summaryCard = LMCardView()
        let summaryRow = LMUIKit.hStack(spacing: 8)
        summaryRow.addArrangedSubview(LMUIKit.label("通过", size: 15))
        summaryRow.addArrangedSubview(LMUIKit.spacer())
        let valueLabel = UILabel()
        valueLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        valueLabel.text = "\(passedCount) / \(results.count)"
        valueLabel.textColor = passedCount == results.count ? .lmGood : .lmBad
        summaryRow.addArrangedSubview(valueLabel)
        summaryCard.contentStack.addArrangedSubview(summaryRow)
        stack.addArrangedSubview(summaryCard)

        // ---- 明细 ----
        let detailCard = LMCardView(spacing: 12)
        for r in results {
            detailCard.contentStack.addArrangedSubview(checkRow(r))
        }
        stack.addArrangedSubview(LMSectionHeaderLabel("解析自检"))
        stack.addArrangedSubview(detailCard)
        stack.addArrangedSubview(LMUIKit.footnote("""
        测的是「解析层」：MAC 排版、config["4"] 构造、hex 容错、
        以及官方那三个分号帧模板的切分是否正确。
        帧的**语义**还没定，自检只保证切分不切错。
        """))
    }

    /// 静态页没有可刷新的状态，留空实现以对齐基类的两个钩子。
    override func render() {}

    // MARK: - 行构造

    /// 一条自检：图标 + 名称，下面跟等宽字体的明细。
    private func checkRow(_ r: LMBLEKeyCheck) -> UIView {
        let box = LMUIKit.vStack(spacing: 3)

        let head = LMUIKit.hStack(spacing: 6)
        let icon = UIImageView(image: UIImage(systemName: r.passed
                                              ? "checkmark.circle.fill" : "xmark.circle.fill"))
        icon.tintColor = r.passed ? .lmGood : .lmBad
        icon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        head.addArrangedSubview(icon)
        head.addArrangedSubview(LMUIKit.label(r.name, size: 13))
        box.addArrangedSubview(head)

        let detail = LMUIKit.label(r.detail, size: 11, color: .secondaryLabel, lines: 3)
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        box.addArrangedSubview(detail)

        return box
    }
}
