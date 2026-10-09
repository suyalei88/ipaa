//
//  LMBLEProtocolStatusViewController.swift
//  LeapmotorLite
//
//  协议进度页（UIKit 版）—— 对应 `Views/BLEKeyView.swift` 里的 `BLEProtocolStatusView`。
//
//  ★ 这是一页**纯静态**内容：数据全部来自 `LMBLEQuestions`（编译期常量），
//    跟 `client` / 蓝牙都无关。所以 `buildUI()` 里一次性把视图铺好，
//    `render()` 保持空实现 —— 没有任何可刷新的状态。
//    （`client` 仍然要从基类拿，因为它是 `LMBaseViewController` 的构造参数。）
//
import UIKit

final class LMBLEProtocolStatusViewController: LMBaseViewController {

    override func buildUI() {
        title = "协议进度"

        let (_, stack) = makeScrollStack(spacing: 18, inset: 16)

        // ---- 已确认 ----
        let settledCard = LMCardView()
        for s in LMBLEQuestions.settled {
            settledCard.contentStack.addArrangedSubview(settledRow(s))
        }
        stack.addArrangedSubview(
            LMSectionHeaderLabel("已确认（\(LMBLEQuestions.settled.count)）"))
        stack.addArrangedSubview(settledCard)
        stack.addArrangedSubview(LMUIKit.footnote(
            "全部来自官方 IPA 主二进制的静态逆向，证据见 LMBLEProtocol.swift 文件头。"))

        // ---- 待解决 ----
        let blockingCard = LMCardView(spacing: 14)
        for q in LMBLEQuestions.blocking {
            blockingCard.contentStack.addArrangedSubview(blockingRow(q))
        }
        stack.addArrangedSubview(
            LMSectionHeaderLabel("待解决（\(LMBLEQuestions.blocking.count)）"))
        stack.addArrangedSubview(blockingCard)
        stack.addArrangedSubview(LMUIKit.footnote("""
        这五项不解完，就不该往真车发字节。
        前四项靠 BLE 调试台 + 官方 App 抓帧就能定；第五项要动态 hook。
        """))
    }

    /// 静态页没有可刷新的状态。留空实现是为了跟基类的两个钩子对齐，
    /// 也避免以后有人误以为漏了刷新逻辑。
    override func render() {}

    // MARK: - 行构造

    /// 「✅ 已确认的一条」
    private func settledRow(_ text: String) -> UIView {
        let row = LMUIKit.hStack(spacing: 8, alignment: .top)
        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = .lmGood
        icon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(LMUIKit.label(text, size: 13, color: .lmGood))
        return row
    }

    /// 「❓ 待解决的一条」：问题 + 怎么定下来 + 用哪一步
    private func blockingRow(_ q: LMBLEOpenQuestion) -> UIView {
        let box = LMUIKit.vStack(spacing: 6)

        let head = LMUIKit.hStack(spacing: 8, alignment: .top)
        let icon = UIImageView(image: UIImage(systemName: "questionmark.circle.fill"))
        icon.tintColor = .lmWarn
        icon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        head.addArrangedSubview(icon)
        head.addArrangedSubview(LMUIKit.label(q.question, size: 13,
                                              weight: .semibold, color: .lmWarn))
        box.addArrangedSubview(head)

        box.addArrangedSubview(LMUIKit.label("怎么定下来：\(q.howToSettle)",
                                             size: 11, color: .secondaryLabel))
        box.addArrangedSubview(LMUIKit.label("用哪一步：\(q.tool)",
                                             size: 11, color: .lmAccent))
        return box
    }
}
