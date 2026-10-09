//
//  LMUIKitTheme.swift
//  LeapmotorLite
//
//  设计系统 —— 视觉重设计「碳黑霓虹」（2026-10-09）。
//
//  ★★ 这一版换掉了原来的「iOS 系统默认风」
//     （systemGroupedBackground 底 + 灰白卡片 + 18pt 圆角 + 系统蓝）。
//     新语言：近黑底 + 实心深灰卡片 + 发丝描边 + 等宽大数字 + 单一薄荷霓虹点缀。
//
//  ★★ 这是**纯深色**设计，没有浅色版本。
//     由 `LMAppDelegate` 里的 `window.overrideUserInterfaceStyle = .dark` 锁定，
//     因此 `.label` / `.secondaryLabel` / `.tertiaryLabel` 这些系统语义色
//     在本 App 里恒为「浅色文字」，可以直接用，不需要每处硬编码。
//     ⚠️ 谁要放开浅色模式，必须把下面这些 `static let` 改成动态色
//        （`UIColor { trait in ... }`），否则浅色下会黑底黑字。
//
//  ★ 改这个文件之前先跑 `python ios/tools/lint_swift.py`。
//
import UIKit

// MARK: - 圆角半径

/// 圆角半径统一（连续曲率）。
///
/// ★ 视觉重设计：整体收方一档（card 18→14 / tile 14→12 / hero 22→16），
///   配合发丝描边，得到「克制、硬朗」的观感。
enum LMRadius {
    static let card: CGFloat = 14
    static let tile: CGFloat = 12
    static let hero: CGFloat = 16
}

// MARK: - 调色板

extension UIColor {

    /// 从 0xRRGGBB 造色。纯深色设计，alpha 恒为 1。
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: 1)
    }

    // ---- 底层 ----

    /// 页面底色（近黑，不是纯黑 —— 纯黑在 OLED 上和卡片边界会糊在一起）
    static let lmCanvas   = UIColor(hex: 0x0A0A0C)
    /// 卡片底
    static let lmCard     = UIColor(hex: 0x131316)
    /// 卡片发丝描边
    static let lmCardLine = UIColor(hex: 0x26262C)
    /// 分隔线
    static let lmSep      = UIColor(hex: 0x1F1F24)

    // ---- 主色 ----

    /// 薄荷霓虹（唯一强调色，只做点缀不铺面）
    static let lmAccent   = UIColor(hex: 0x00E39A)
    /// 青（渐变另一端 / 次级强调）
    static let lmAccent2  = UIColor(hex: 0x00B8FF)

    // ---- 文字（显式给出，避免与系统语义色漂移）----

    static let lmText  = UIColor(hex: 0xF5F5F7)
    static let lmText2 = UIColor(white: 1, alpha: 0.46)
    static let lmText3 = UIColor(white: 1, alpha: 0.28)

    // ---- 语义色 ----

    static let lmGood   = UIColor(hex: 0x00E39A)
    static let lmWarn   = UIColor(hex: 0xFFB340)
    static let lmBad    = UIColor(hex: 0xFF5C5C)
    static let lmPurple = UIColor(hex: 0xA78BFA)
    static let lmTeal   = UIColor(hex: 0x00B8FF)
    static let lmIndigo = UIColor(hex: 0x6D8BFF)
}

// MARK: - 字体

/// 字体工具。
///
/// ★ 等宽数字是这套设计的核心特征之一：续航 / 电量 / 温度这些数字
///   会随数据跳动，等宽字保证**跳动时宽度不变**，不会左右抖。
enum LMFont {

    /// 等宽数字（SF Mono）。用于大数字：续航、SOC、温度、里程。
    static func mono(_ size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// 比例字体（SF Pro）。用于正文、标题、按钮。
    static func text(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - 卡片

/// 圆角 + 实心底 + 发丝描边，内容装进 `contentStack`。
///
/// ★ 视觉重设计：原来是「灰白底无描边」，现在改成「深灰底 + 1pt 描边」——
///   在近黑背景上，光靠明度差区分卡片不够，加一圈描边才有「分层」感。
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

    init(padding: CGFloat = 15,
         radius: CGFloat = LMRadius.card,
         spacing: CGFloat = 10) {
        super.init(frame: .zero)

        backgroundColor = .lmCard
        layer.cornerRadius = radius
        // 连续曲率，跟 SwiftUI 的 RoundedRectangle(style: .continuous) 观感一致
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.lmCardLine.cgColor
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

// MARK: - 页面顶部辉光

/// 铺满整页的背景层：底部是 `lmCanvas`，顶部一团极淡的薄荷径向光晕。
///
/// ★ 为什么需要它：纯平的近黑底在大屏上会显得「死」。顶部那一点光晕
///   让页面有纵深，也是这套设计里唯一的「氛围」元素（刻意不铺面）。
/// ★ `isUserInteractionEnabled = false` —— 它是背景，绝不能吃掉手势。
final class LMGlowBackdropView: UIView {

    private let glow = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .lmCanvas

        glow.type = .radial
        glow.colors = [
            UIColor.lmAccent.withAlphaComponent(0.11).cgColor,
            UIColor.lmAccent.withAlphaComponent(0.0).cgColor,
        ]
        glow.locations = [0, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.0)
        glow.endPoint = CGPoint(x: 1.05, y: 0.62)
        layer.addSublayer(glow)
    }

    required init?(coder: NSCoder) {
        fatalError("LMGlowBackdropView 只能代码创建")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 隐式动画会让旋转/尺寸变化时这层「飘」一下，显式关掉。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - 区块标题

/// 区块标题：小号半粗、字距略放开，弱化色。
///
/// ★ 视觉重设计：从「13pt 半粗灰字」改成「12pt 半粗 + 1.1 字距」——
///   全大写观感在中文里不适用，所以改用**加字距**来制造「标签感」。
final class LMSectionHeaderLabel: UILabel {

    init(_ text: String) {
        super.init(frame: .zero)
        self.text = text
        font = LMFont.text(12, weight: .semibold)
        textColor = .lmText2
        numberOfLines = 0
        setContentHuggingPriority(.required, for: .vertical)
        applyTracking(1.1)
    }

    required init?(coder: NSCoder) {
        fatalError("LMSectionHeaderLabel 只能代码创建")
    }
}

// MARK: - 状态胶囊

/// 图标 + 文字，带透明底色的胶囊。
///
/// ★ 视觉重设计：圆角从 11 收到 8，底色透明度 0.14→0.16
///   （近黑底上淡色底需要更高透明度才看得出来）。
final class LMStatusPillView: UIView {

    private let stack = UIStackView()
    private let iconView = UIImageView()
    private let label = UILabel()

    init(text: String, icon: String, tint: UIColor) {
        super.init(frame: .zero)

        backgroundColor = tint.withAlphaComponent(0.16)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        label.text = text
        label.font = LMFont.text(11, weight: .semibold)
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
        backgroundColor = tint.withAlphaComponent(0.16)
    }

    required init?(coder: NSCoder) {
        fatalError("LMStatusPillView 只能代码创建")
    }
}

// MARK: - 指标磁贴

/// 图标 + 标题 + 主值（+ 可选副标题）。
///
/// ★ 视觉重设计：主值改用**等宽字体**（数字跳动不抖），字号 20→22，
///   卡片从「无描边」改成「发丝描边」，圆角 14→12。
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
        layer.borderColor = UIColor.lmCardLine.cgColor

        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.text = title
        titleLabel.font = LMFont.text(11)
        titleLabel.textColor = .lmText2
        titleLabel.numberOfLines = 1

        valueLabel.text = value
        valueLabel.font = LMFont.mono(22, weight: .semibold)
        valueLabel.textColor = .lmText
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.5
        valueLabel.numberOfLines = 1

        subLabel.text = sub ?? ""
        subLabel.font = LMFont.text(10.5)
        subLabel.textColor = .lmText3
        subLabel.numberOfLines = 1
        subLabel.isHidden = (sub ?? "").isEmpty

        headStack.axis = .horizontal
        headStack.spacing = 5
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

/// 统一的导航控制器：深色导航栏 + 薄荷 tint + 大标题。
///
/// ★ 视觉重设计：显式配 `UINavigationBarAppearance`，把导航栏底色
///   刷成与页面同色的 `lmCanvas` 并**去掉底部投影线**（`shadowColor = .clear`），
///   否则滚动时导航栏和内容之间会出现一道突兀的横线。
final class LMNavigationController: UINavigationController {

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        navigationBar.tintColor = .lmAccent
        view.backgroundColor = .lmCanvas

        let ap = UINavigationBarAppearance()
        ap.configureWithOpaqueBackground()
        ap.backgroundColor = .lmCanvas
        ap.shadowColor = .clear
        ap.titleTextAttributes = [.foregroundColor: UIColor.lmText]
        ap.largeTitleTextAttributes = [
            .foregroundColor: UIColor.lmText,
            .font: UIFont.systemFont(ofSize: 32, weight: .bold),
        ]
        navigationBar.standardAppearance = ap
        navigationBar.scrollEdgeAppearance = ap
        navigationBar.compactAppearance = ap
    }
}

// MARK: - 常用控件工厂

/// 造常用控件的小工具。只为少写样板，不含任何状态。
enum LMUIKit {

    /// 正文标签
    static func label(_ text: String? = nil,
                      size: CGFloat = 15,
                      weight: UIFont.Weight = .regular,
                      color: UIColor = .lmText,
                      lines: Int = 0) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = LMFont.text(size, weight: weight)
        l.textColor = color
        l.numberOfLines = lines
        return l
    }

    /// 等宽数字标签（续航 / 电量 / 温度这类会跳动的数值）
    static func monoLabel(_ text: String? = nil,
                          size: CGFloat = 22,
                          weight: UIFont.Weight = .semibold,
                          color: UIColor = .lmText) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = LMFont.mono(size, weight: weight)
        l.textColor = color
        l.numberOfLines = 1
        return l
    }

    /// 主按钮（实心薄荷，字用近黑保证对比度）
    static func primaryButton(_ title: String) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.baseBackgroundColor = .lmAccent
        cfg.baseForegroundColor = .lmCanvas
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14,
                                                    bottom: 10, trailing: 14)
        return UIButton(configuration: cfg)
    }

    /// 次要按钮（卡片底 + 发丝描边 + 薄荷字）
    static func plainButton(_ title: String, tint: UIColor = .lmAccent) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.baseForegroundColor = tint
        cfg.background.backgroundColor = .lmCard
        cfg.background.strokeColor = .lmCardLine
        cfg.background.strokeWidth = 1
        cfg.background.cornerRadius = 10
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

    /// 一段可换行的说明文字（弱化小字）
    static func footnote(_ text: String) -> UILabel {
        label(text, size: 12, color: .lmText2)
    }
}

// MARK: - 字距小工具

extension UILabel {
    /// 给标签加字距。中文没有大小写，靠字距制造「标签感」。
    func applyTracking(_ value: CGFloat) {
        guard let text else { return }
        attributedText = NSAttributedString(
            string: text,
            attributes: [.kern: value, .font: font as Any, .foregroundColor: textColor as Any])
    }
}
