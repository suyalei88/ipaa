//
//  LMUIKitTheme.swift
//  LeapmotorLite
//
//  UIKit 版主题层 —— 与 `Views/Theme.swift` 一一对应。
//
//  ★ 为什么需要这个文件（2026-10-09，UI 从 SwiftUI 迁到 UIKit）：
//    `Color.lmAccent` / `LMCard` / `MetricTile` 这些在 UIKit 里完全用不了。
//    如果没有一份 UIKit 等价物，每一页都会各写一遍圆角、底色、描边，
//    很快就出现「这一页卡片 18pt、那一页 14pt」的漂移。
//
//  ★ 颜色值必须与 `Theme.swift` 里的 `Color.lm*` **逐位一致**。
//    改任何一边都要同时改另一边 —— 迁移期间两种框架会长期共存，
//    对不上时同一个 App 里两个页面的蓝会不是同一个蓝。
//
//  ★ `LMRadius` 直接复用 `Theme.swift` 里的定义：它是个纯常量枚举，
//    不依赖 SwiftUI，UIKit 文件可以直接用。等 Phase 5 把 `Theme.swift`
//    整体删掉时，再把它搬进本文件。
//
//  ⚠️ 改这个文件之前先跑 `python ios/tools/lint_swift.py`。
//
import UIKit

// MARK: - 圆角半径

/// 圆角半径统一（连续曲率，比默认的圆角顺眼）。
///
/// ★ 2026-10-09（UIKit 迁移）：这个枚举原来定义在 `Views/Theme.swift` 里，
///   现在搬到本文件。原因是它**两种框架都要用**（纯常量，不依赖 SwiftUI），
///   而 `Theme.swift` 会随着迁移完成被整体删除 —— 留在那边会一起消失。
///   数值必须与 `Theme.swift` 原来的一致（card 18 / tile 14 / hero 22）。
enum LMRadius {
    static let card: CGFloat = 18
    static let tile: CGFloat = 14
    static let hero: CGFloat = 22
}

// MARK: - 调色板（与 Color.lm* 逐位对应）

extension UIColor {
    /// 零跑蓝
    static let lmAccent  = UIColor(red: 0.11, green: 0.45, blue: 0.94, alpha: 1)
    /// 亮蓝（渐变用）
    static let lmAccent2 = UIColor(red: 0.36, green: 0.72, blue: 0.98, alpha: 1)
    /// 卡片底
    static let lmCard    = UIColor.secondarySystemGroupedBackground

    static let lmGood    = UIColor(red: 0.16, green: 0.72, blue: 0.42, alpha: 1)
    static let lmWarn    = UIColor(red: 0.98, green: 0.60, blue: 0.12, alpha: 1)
    static let lmBad     = UIColor(red: 0.92, green: 0.26, blue: 0.27, alpha: 1)
    static let lmPurple  = UIColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1)
    static let lmTeal    = UIColor(red: 0.12, green: 0.68, blue: 0.71, alpha: 1)
    static let lmIndigo  = UIColor(red: 0.35, green: 0.38, blue: 0.85, alpha: 1)
}

// MARK: - 卡片

/// UIKit 版 `LMCard`：圆角 + 卡片底色，内容装进 `contentStack`。
///
/// 用法：
/// ```swift
/// let card = LMCardView()
/// card.contentStack.addArrangedSubview(LMUIKit.label("标题", size: 15, weight: .semibold))
/// stack.addArrangedSubview(card)
/// ```
final class LMCardView: UIView {

    /// 往这里塞子视图。垂直排列，间距由 init 的 `spacing` 决定。
    let contentStack = UIStackView()

    init(padding: CGFloat = 16,
         radius: CGFloat = LMRadius.card,
         spacing: CGFloat = 10) {
        super.init(frame: .zero)

        backgroundColor = .lmCard
        layer.cornerRadius = radius
        // 连续曲率，跟 SwiftUI 的 RoundedRectangle(style: .continuous) 观感一致
        layer.cornerCurve = .continuous
        // 不设 masksToBounds：卡片里偶尔要放超出圆角的阴影/角标，
        // 圆角本身由 backgroundColor + cornerRadius 已经画出来了。
        contentStack.axis = .vertical
        contentStack.spacing = spacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LMCardView 只能代码创建")
    }
}

// MARK: - 区块标题

/// UIKit 版 `SectionHeader`：小号半粗灰字，左对齐。
final class LMSectionHeaderLabel: UILabel {

    init(_ text: String) {
        super.init(frame: .zero)
        self.text = text
        font = .systemFont(ofSize: 13, weight: .semibold)
        textColor = .secondaryLabel
        numberOfLines = 0
        // 跟 SwiftUI 版的 .padding(.leading, 4) 对齐
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) {
        fatalError("LMSectionHeaderLabel 只能代码创建")
    }
}

// MARK: - 状态胶囊

/// UIKit 版 `StatusPill`：图标 + 文字，带透明底色的胶囊。
final class LMStatusPillView: UIView {

    private let stack = UIStackView()
    private let iconView = UIImageView()
    private let label = UILabel()

    init(text: String, icon: String, tint: UIColor) {
        super.init(frame: .zero)

        backgroundColor = tint.withAlphaComponent(0.14)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        label.text = text
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = tint
        label.numberOfLines = 1

        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(label)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        // 胶囊宽度由内容决定，不要被父 StackView 拉伸
        setContentHuggingPriority(.required, for: .horizontal)
    }

    /// 状态变了就地更新，避免每次 render 都重建视图。
    func update(text: String, icon: String, tint: UIColor) {
        label.text = text
        label.textColor = tint
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        backgroundColor = tint.withAlphaComponent(0.14)
    }

    required init?(coder: NSCoder) {
        fatalError("LMStatusPillView 只能代码创建")
    }
}

// MARK: - 指标磁贴

/// UIKit 版 `MetricTile`：图标 + 标题 + 主值（+ 可选副标题）。
final class LMMetricTileView: UIView {

    private let headStack = UIStackView()
    private let rootStack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let subLabel = UILabel()

    init(title: String, value: String, icon: String, tint: UIColor, sub: String? = nil) {
        super.init(frame: .zero)

        backgroundColor = .lmCard
        layer.cornerRadius = LMRadius.tile
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = tint.withAlphaComponent(0.18).cgColor

        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 1

        valueLabel.text = value
        valueLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.55
        valueLabel.numberOfLines = 1

        subLabel.text = sub ?? ""
        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabel
        subLabel.numberOfLines = 1
        subLabel.isHidden = (sub ?? "").isEmpty

        headStack.axis = .horizontal
        headStack.spacing = 6
        headStack.alignment = .center
        headStack.addArrangedSubview(iconView)
        headStack.addArrangedSubview(titleLabel)

        rootStack.axis = .vertical
        rootStack.spacing = 8
        rootStack.alignment = .fill
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headStack)
        rootStack.addArrangedSubview(valueLabel)
        rootStack.addArrangedSubview(subLabel)
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    /// 就地刷新主值与副标题（`render()` 里反复调用，不重建视图）。
    func update(value: String, sub: String? = nil) {
        valueLabel.text = value
        let s = sub ?? ""
        subLabel.text = s
        subLabel.isHidden = s.isEmpty
    }

    required init?(coder: NSCoder) {
        fatalError("LMMetricTileView 只能代码创建")
    }
}

// MARK: - 导航控制器

/// 统一的导航控制器：零跑蓝 tint + 大标题。
final class LMNavigationController: UINavigationController {

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        navigationBar.tintColor = .lmAccent
        view.backgroundColor = .systemGroupedBackground
    }
}

// MARK: - 常用控件工厂

/// 造常用控件的小工具。只为少写样板，不含任何状态。
enum LMUIKit {

    /// 正文标签
    static func label(_ text: String? = nil,
                      size: CGFloat = 15,
                      weight: UIFont.Weight = .regular,
                      color: UIColor = .label,
                      lines: Int = 0) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.numberOfLines = lines
        return l
    }

    /// 主按钮（实心零跑蓝）
    static func primaryButton(_ title: String) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.baseBackgroundColor = .lmAccent
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14,
                                                    bottom: 10, trailing: 14)
        return UIButton(configuration: cfg)
    }

    /// 次要按钮（灰底）
    static func plainButton(_ title: String, tint: UIColor = .lmAccent) -> UIButton {
        var cfg = UIButton.Configuration.gray()
        cfg.title = title
        cfg.baseForegroundColor = tint
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14,
                                                    bottom: 10, trailing: 14)
        return UIButton(configuration: cfg)
    }

    /// 竖排 StackView
    static func vStack(spacing: CGFloat = 10,
                       alignment: UIStackView.Alignment = .fill) -> UIStackView {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = spacing
        s.alignment = alignment
        return s
    }

    /// 横排 StackView
    static func hStack(spacing: CGFloat = 8,
                       alignment: UIStackView.Alignment = .center) -> UIStackView {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = spacing
        s.alignment = alignment
        return s
    }

    /// 弹性占位：把后面的元素推到最右。
    static func spacer() -> UIView {
        let v = UIView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    /// 一段可换行的说明文字（灰色小字）
    static func footnote(_ text: String) -> UILabel {
        let l = label(text, size: 12, color: .secondaryLabel)
        return l
    }
}
