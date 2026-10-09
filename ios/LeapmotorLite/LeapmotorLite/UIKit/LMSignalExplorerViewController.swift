//
//  LMSignalExplorerViewController.swift
//  LeapmotorLite
//
//  原始信号浏览器 + 快照对比（UIKit 版）—— 对应原
//  `Views/SignalExplorerView.swift`（418 行 SwiftUI List）。
//
//  为什么要有这个页面：signalMap 有 130 个 id，服务端不下发名称，
//  剩下 90 多个只能靠「抓快照 → 做动作 → 再抓快照 → 看哪个 id 变了」来认。
//
//  迁移约定（跟 `LMLoginViewController` / `LMSettingsViewController` 一致）：
//    · 继承 `LMBaseViewController`，只覆盖 `buildUI()` / `render()` 两个钩子
//    · 页内状态（搜索词 / 是否只看变化 / 快照 A、B / 基线）**不进 `LMClient`**
//    · `render()` 必须幂等：信号行数会随搜索词 / 模式变化，照抄设置页的
//      `rebuildIfNeeded(_:signature:)` 指纹模式重建列表块；
//      但搜索框在列表块**之外**，重建不会打断正在输入的内容
//
//  ★ 原页的「筛选」是导航栏 Menu（Toggle + 设/清基线）。UIKit 里 UIMenu 的
//    Toggle 状态不会随程序改动自动刷新，需要每次重建整个 UIMenu；这里改成
//    页内的 UISwitch + 两个按钮，行为一致但用 target/selector，编译与状态都更稳。
//
import UIKit

final class LMSignalExplorerViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，跟车端无关）

    private var query = ""
    private var showOnlyChanged = false
    private var snapA: SignalSnapshot?
    private var snapB: SignalSnapshot?
    private var baseline: SignalSnapshot?
    private var copied = false

    /// 信号列表的内容指纹缓存：指纹没变就整块跳过。
    private var rebuildCache: [ObjectIdentifier: String] = [:]

    // MARK: - 控件：搜索

    private let searchCard = LMCardView(padding: 12, spacing: 0)
    private let searchField = UITextField()

    // MARK: - 控件：快照对比

    private let snapshotHeader = LMSectionHeaderLabel("快照对比")
    private let snapshotCard = LMCardView(spacing: 12)
    private let snapAButton = UIButton()
    private let snapBButton = UIButton()
    private let diffButton = UIButton()
    private let copyButton = UIButton()
    private let onlyChangedSwitch = UISwitch()
    private let setBaselineButton = UIButton()
    private let clearBaselineButton = UIButton()
    private let snapshotFooter = LMUIKit.footnote("""
    用法：抓快照 A → 去车上做一个动作（插枪充电 / 开空调 / 锁车 / 开窗）→ 回来刷新车况 → 抓快照 B → 对比。
    变了的 id 就是这个动作对应的信号。这是识别未知信号最省事的办法。

    快照只存在内存里，退出即消失。
    """)

    // MARK: - 控件：信号列表

    private let listCard = LMCardView()
    private let listStack = LMUIKit.vStack(spacing: 14)

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "信号浏览器"
        navigationItem.largeTitleDisplayMode = .never

        let (_, stack) = makeScrollStack(spacing: 16, inset: 16)
        stack.addArrangedSubview(searchCard)
        stack.addArrangedSubview(snapshotHeader)
        stack.addArrangedSubview(snapshotCard)
        stack.addArrangedSubview(snapshotFooter)
        stack.addArrangedSubview(listCard)

        buildSearch()
        buildSnapshotCard()
        listCard.contentStack.addArrangedSubview(listStack)
    }

    private func buildSearch() {
        searchField.placeholder = "搜索 id 或名称"
        searchField.clearButtonMode = .whileEditing
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.font = .systemFont(ofSize: 15)
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.addTarget(self, action: #selector(searchReturn), for: .editingDidEndOnExit)
        searchCard.contentStack.addArrangedSubview(searchField)
    }

    private func buildSnapshotCard() {
        styleSnapshotButton(snapAButton, title: "抓快照 A")
        snapAButton.addTarget(self, action: #selector(snapATapped), for: .touchUpInside)

        styleSnapshotButton(snapBButton, title: "抓快照 B")
        snapBButton.addTarget(self, action: #selector(snapBTapped), for: .touchUpInside)

        let snapRow = LMUIKit.hStack(spacing: 10)
        snapRow.addArrangedSubview(snapAButton)
        snapRow.addArrangedSubview(snapBButton)
        snapAButton.widthAnchor.constraint(equalTo: snapBButton.widthAnchor).isActive = true
        snapshotCard.contentStack.addArrangedSubview(snapRow)

        // 对比 A / B —— 用 filled 主按钮，带一个左右箭头图标。
        var diffCfg = UIButton.Configuration.filled()
        diffCfg.title = "对比 A / B（只列变化）"
        diffCfg.image = UIImage(systemName: "arrow.left.arrow.right")
        diffCfg.imagePadding = 6
        diffCfg.baseBackgroundColor = .lmAccent
        diffCfg.baseForegroundColor = .white
        diffCfg.cornerStyle = .medium
        diffCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14,
                                                        bottom: 10, trailing: 14)
        diffButton.configuration = diffCfg
        diffButton.addTarget(self, action: #selector(diffTapped), for: .touchUpInside)
        snapshotCard.contentStack.addArrangedSubview(diffButton)

        // 复制当前全部信号（JSON）—— 标题会随「已复制」状态变，
        // 所以只能走 `configuration?.title`，不能用 titleLabel（会被配置覆盖）。
        stylePlainButton(copyButton, title: "复制当前全部信号（JSON）",
                         icon: "doc.on.doc", tint: .lmAccent)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        snapshotCard.contentStack.addArrangedSubview(copyButton)

        // 只看有变化的信号（原页是导航栏 Menu 里的 Toggle）
        onlyChangedSwitch.addTarget(self, action: #selector(onlyChangedChanged),
                                    for: .valueChanged)
        let switchRow = LMUIKit.hStack(spacing: 8)
        switchRow.addArrangedSubview(LMUIKit.label("只看有变化的信号", size: 15))
        switchRow.addArrangedSubview(LMUIKit.spacer())
        switchRow.addArrangedSubview(onlyChangedSwitch)
        snapshotCard.contentStack.addArrangedSubview(switchRow)

        // 基线（原页是 Menu 里的两个按钮）
        stylePlainButton(setBaselineButton, title: "把当前值设为基线",
                         icon: "pin", tint: .lmAccent)
        setBaselineButton.addTarget(self, action: #selector(setBaselineTapped),
                                    for: .touchUpInside)
        stylePlainButton(clearBaselineButton, title: "清除基线",
                         icon: "pin.slash", tint: .lmWarn)
        clearBaselineButton.addTarget(self, action: #selector(clearBaselineTapped),
                                      for: .touchUpInside)
        let baselineRow = LMUIKit.hStack(spacing: 8)
        baselineRow.addArrangedSubview(setBaselineButton)
        baselineRow.addArrangedSubview(clearBaselineButton)
        baselineRow.addArrangedSubview(LMUIKit.spacer())
        snapshotCard.contentStack.addArrangedSubview(baselineRow)
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        renderSnapshotControls()
        renderList()
    }

    private func renderSnapshotControls() {
        let hasSignals = !client.signals.isEmpty

        snapAButton.isEnabled = hasSignals
        snapAButton.configuration?.image = UIImage(systemName: snapA != nil
                                                   ? "checkmark.circle.fill" : "camera.fill")
        snapBButton.isEnabled = hasSignals
        snapBButton.configuration?.image = UIImage(systemName: snapB != nil
                                                   ? "checkmark.circle.fill" : "camera.fill")

        diffButton.isEnabled = (snapA != nil && snapB != nil)

        copyButton.isEnabled = hasSignals
        copyButton.configuration?.title = copied
            ? "已复制到剪贴板" : "复制当前全部信号（JSON）"
        copyButton.configuration?.image = UIImage(systemName: copied
                                                  ? "checkmark.circle.fill" : "doc.on.doc")

        onlyChangedSwitch.isOn = showOnlyChanged
        clearBaselineButton.isEnabled = (baseline != nil)
    }

    private func renderList() {
        let signature = listSignature()
        rebuildIfNeeded(listStack, signature: signature) {
            showOnlyChanged ? changedRows() : catalogRows()
        }
    }

    // MARK: - 列表内容（会被 rebuildIfNeeded 调用）

    /// 「只看变化」模式：相对基线只列变化的 id。
    private func changedRows() -> [UIView] {
        var views: [UIView] = []
        let changed = SignalSnapshot.diff(baseline, SignalSnapshot.capture(client.signals))

        views.append(sectionHeader("相对基线的变化", icon: "arrow.left.arrow.right",
                                   trailing: "\(client.signals.count) 个信号"))
        if changed.isEmpty {
            let baseText = baseline == nil ? "未设基线" : "共 \(baseline?.values.count ?? 0) 个信号"
            views.append(LMUIKit.label("相对基线没有变化（\(baseText)）",
                                       size: 15, color: .secondaryLabel))
            return views
        }
        for item in changed { views.append(makeChangedRow(item)) }
        return views
    }

    /// 目录模式：按分类列已知信号，再列未命名信号。
    private func catalogRows() -> [UIView] {
        var views: [UIView] = []
        for group in visibleGroups {
            views.append(sectionHeader(group.category.rawValue, icon: group.category.icon))
            for ref in group.refs {
                views.append(makeSignalRow(id: ref.id, name: ref.name,
                                           badge: ref.confidence.badge,
                                           note: ref.note, unit: ref.unit,
                                           tint: confidenceTint(ref.confidence)))
            }
        }

        let unknown = unknownIds
        views.append(sectionHeader("未命名（\(unknown.count)）", icon: "questionmark.circle"))
        if unknown.isEmpty {
            views.append(LMUIKit.label("没有未命名的信号 —— 目录已经覆盖服务端下发的全部 id。",
                                       size: 15, color: .secondaryLabel))
        } else {
            for id in unknown {
                views.append(makeSignalRow(id: id, name: "未命名信号", badge: "❓",
                                           note: "还没识别出来。做动作前后各抓一次快照就能认。",
                                           unit: "", tint: .secondaryLabel))
            }
        }
        views.append(LMUIKit.footnote(
            "服务端只下发 id 和值，不下发名称。这些需要靠「抓快照 → 做动作 → 再抓快照」来反推。"))
        return views
    }

    // MARK: - 行 / 表头构造

    /// 分类表头：图标 + 小标题（+ 可选右侧计数）。
    private func sectionHeader(_ title: String, icon: String,
                               trailing: String? = nil) -> UIView {
        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = .lmAccent
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let row = LMUIKit.hStack(spacing: 6)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(LMSectionHeaderLabel(title))
        if let trailing {
            row.addArrangedSubview(LMUIKit.spacer())
            row.addArrangedSubview(LMUIKit.label(trailing, size: 11, color: .secondaryLabel))
        }
        return row
    }

    /// 一条信号：`id 徽标 名称 …… 当前值`，下方可带一行说明。
    private func makeSignalRow(id: String, name: String, badge: String,
                               note: String, unit: String, tint: UIColor) -> UIView {
        let idLabel = UILabel()
        idLabel.text = id
        idLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        idLabel.textColor = .secondaryLabel
        idLabel.setContentHuggingPriority(.required, for: .horizontal)

        let badgeLabel = UILabel()
        badgeLabel.text = badge
        badgeLabel.font = .systemFont(ofSize: 11)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1

        let valueLabel = UILabel()
        valueLabel.text = client.signalText(id, unit: unit)
        valueLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = tint
        valueLabel.numberOfLines = 1
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let top = LMUIKit.hStack(spacing: 8, alignment: .firstBaseline)
        top.addArrangedSubview(idLabel)
        top.addArrangedSubview(badgeLabel)
        top.addArrangedSubview(nameLabel)
        top.addArrangedSubview(LMUIKit.spacer())
        top.addArrangedSubview(valueLabel)

        let box = LMUIKit.vStack(spacing: 3)
        box.addArrangedSubview(top)
        if !note.isEmpty {
            box.addArrangedSubview(LMUIKit.label(note, size: 11, color: .secondaryLabel))
        }
        return box
    }

    /// 一条变化：`id 徽标 名称` + `旧值 → 新值`。
    private func makeChangedRow(_ item: SignalSnapshot.Change) -> UIView {
        let idLabel = UILabel()
        idLabel.text = item.id
        idLabel.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        idLabel.setContentHuggingPriority(.required, for: .horizontal)

        let head = LMUIKit.hStack(spacing: 6)
        head.addArrangedSubview(idLabel)
        if let r = LMSignalCatalog.ref(item.id) {
            let badge = UILabel()
            badge.text = r.confidence.badge
            badge.font = .systemFont(ofSize: 11)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            head.addArrangedSubview(badge)
            head.addArrangedSubview(LMUIKit.label(r.name, size: 13, color: .secondaryLabel))
        }
        head.addArrangedSubview(LMUIKit.spacer())

        let oldLabel = UILabel()
        oldLabel.text = item.oldValue
        oldLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        oldLabel.textColor = .secondaryLabel

        let arrow = UIImageView(image: UIImage(systemName: "arrow.right"))
        arrow.tintColor = .secondaryLabel
        arrow.contentMode = .scaleAspectFit
        arrow.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        arrow.setContentHuggingPriority(.required, for: .horizontal)

        let newLabel = UILabel()
        newLabel.text = item.newValue
        newLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        newLabel.textColor = .lmAccent

        let valueRow = LMUIKit.hStack(spacing: 6)
        valueRow.addArrangedSubview(oldLabel)
        valueRow.addArrangedSubview(arrow)
        valueRow.addArrangedSubview(newLabel)
        valueRow.addArrangedSubview(LMUIKit.spacer())

        let box = LMUIKit.vStack(spacing: 3)
        box.addArrangedSubview(head)
        box.addArrangedSubview(valueRow)
        return box
    }

    // MARK: - 过滤 / 派生

    /// 过滤掉搜索后为空的分类（空分区会留一块白）。
    private var visibleGroups: [LMSignalCatalog.LMGroup] {
        LMSignalCatalog.grouped().compactMap { g in
            let refs = g.refs.filter { matches($0.id, $0.name) }
            return refs.isEmpty ? nil : LMSignalCatalog.LMGroup(category: g.category, refs: refs)
        }
    }

    /// 有 id 但目录里没名字的。
    private var unknownIds: [String] {
        client.signals.keys
            .filter { !LMSignalCatalog.knownIds.contains($0) }
            .filter { matches($0, nil) }
            .sorted { LMSignalCatalog.numeric($0) < LMSignalCatalog.numeric($1) }
    }

    private func matches(_ id: String, _ name: String?) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.trimmingCharacters(in: .whitespaces)
        if id.contains(q) { return true }
        if let n = name, n.localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    private func confidenceTint(_ c: LMConfidence) -> UIColor {
        switch c {
        case .confirmed: return .lmGood
        case .observed:  return .lmWarn
        case .unknown:   return .secondaryLabel
        }
    }

    /// 列表内容指纹：模式 + 搜索词 + 基线 + 当前全部信号值。
    /// 任一变化才重建；没变就整块跳过。
    private func listSignature() -> String {
        var parts: [String] = []
        parts.append(showOnlyChanged ? "changed" : "catalog")
        parts.append("q=\(query)")
        parts.append("bl=" + (baseline?.values
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") ?? "-"))
        parts.append("sig=" + client.signals
            .map { "\($0.key)=\($0.value.displayText)" }.sorted().joined(separator: ","))
        return parts.joined(separator: "\u{1}")
    }

    // MARK: - 重建辅助（照抄设置页的指纹去重）

    private func rebuildIfNeeded(_ container: UIStackView,
                                 signature: String,
                                 build: () -> [UIView]) {
        let key = ObjectIdentifier(container)
        guard rebuildCache[key] != signature else { return }
        rebuildCache[key] = signature
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        build().forEach { container.addArrangedSubview($0) }
    }

    // MARK: - 按钮样式

    private func styleSnapshotButton(_ button: UIButton, title: String) {
        var cfg = UIButton.Configuration.gray()
        cfg.title = title
        cfg.image = UIImage(systemName: "camera.fill")
        cfg.imagePadding = 6
        cfg.baseForegroundColor = .lmAccent
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12,
                                                    bottom: 10, trailing: 12)
        button.configuration = cfg
    }

    /// 表单里那种「纯文字按钮」：无底色、指定色文字（可选图标）。
    ///
    /// ★ 写成实例方法而不是 `static func`：`static func` 在属性初始化器里调用
    ///   会被判成「非隔离上下文调用主 actor 方法」。
    private func stylePlainButton(_ button: UIButton, title: String,
                                  icon: String? = nil, tint: UIColor) {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        cfg.baseForegroundColor = tint
        if let icon {
            cfg.image = UIImage(systemName: icon)
            cfg.imagePadding = 6
        }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4,
                                                    bottom: 8, trailing: 4)
        button.configuration = cfg
    }

    // MARK: - 动作

    @objc private func searchChanged() {
        query = searchField.text ?? ""
        renderList()
    }

    @objc private func searchReturn() {
        view.endEditing(true)
    }

    @objc private func snapATapped() {
        snapA = SignalSnapshot.capture(client.signals)
        renderSnapshotControls()
    }

    @objc private func snapBTapped() {
        snapB = SignalSnapshot.capture(client.signals)
        renderSnapshotControls()
    }

    @objc private func diffTapped() {
        let items = SignalSnapshot.diff(snapA, snapB)
        let vc = LMSignalDiffViewController(items: items)
        let nav = UINavigationController(rootViewController: vc)
        nav.navigationBar.tintColor = .lmAccent
        present(nav, animated: true)
    }

    @objc private func copyTapped() {
        copySnapshotJSON()
    }

    @objc private func onlyChangedChanged() {
        showOnlyChanged = onlyChangedSwitch.isOn
        renderList()
    }

    @objc private func setBaselineTapped() {
        baseline = SignalSnapshot.capture(client.signals)
        showOnlyChanged = true
        render()
    }

    @objc private func clearBaselineTapped() {
        baseline = nil
        render()
    }

    // MARK: - 复制

    private func copySnapshotJSON() {
        guard !client.signals.isEmpty else { return }
        var dict: [String: String] = [:]
        for (k, v) in client.signals { dict[k] = v.displayText }
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return }
        UIPasteboard.general.string = s
        copied = true
        renderSnapshotControls()

        // ★ 用 `Task { @MainActor in }` 而不是 `DispatchQueue.main.async { }`：
        //   后者收到 `@Sendable` 闭包、不继承 @MainActor 隔离，改 `copied` 会编译失败。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            self?.copied = false
            self?.renderSnapshotControls()
        }
    }
}

// MARK: - 快照对比 Sheet

/// 对应原页 `.sheet` 里的 `diffSheet`。
/// 用等宽 `UITextView` 承载差异文本（自带选择/复制），导航栏再补一个「复制」按钮。
private final class LMSignalDiffViewController: UIViewController {

    private let items: [SignalSnapshot.Change]
    private let textView = UITextView()

    init(items: [SignalSnapshot.Change]) {
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LMSignalDiffViewController 只能代码创建")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "快照对比"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭", style: .plain, target: self, action: #selector(closeTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "复制", style: .plain, target: self, action: #selector(copyTapped))

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.text = diffText()
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func diffText() -> String {
        if items.isEmpty {
            return "两个快照完全相同 —— 说明这期间车辆没有任何信号变化。"
        }
        var lines: [String] = ["\(items.count) 个信号发生变化", ""]
        for i in items {
            let name = LMSignalCatalog.ref(i.id)
                .map { "\($0.confidence.badge)\($0.name)" } ?? "未命名"
            lines.append("\(i.id)  \(name)")
            lines.append("    \(i.oldValue) → \(i.newValue)")
            if let r = LMSignalCatalog.ref(i.id), !r.note.isEmpty {
                lines.append("    \(r.note)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = textView.text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - 快照

/// 一份 signalMap 的只读拷贝。值统一转成展示文本 —— 我们只关心「变了没」。
struct SignalSnapshot {
    let takenAt: Date
    /// id → 展示文本
    let values: [String: String]

    struct Change: Identifiable {
        let id: String
        let oldValue: String
        let newValue: String
    }

    static func capture(_ signals: [String: LMSignalValue]) -> SignalSnapshot {
        var m: [String: String] = [:]
        for (k, v) in signals { m[k] = v.displayText }
        return SignalSnapshot(takenAt: Date(), values: m)
    }

    /// 只列出值不同的 id（并集）。任一侧缺失时显示 "--"。
    ///
    /// 注意：新增/消失的 id 也算「变化」—— 车辆休眠时服务端会少下发一批信号，
    /// 这个本身就是信息（比如「哪几个 id 只在充电时出现」）。
    static func diff(_ a: SignalSnapshot?, _ b: SignalSnapshot?) -> [Change] {
        guard let a = a, let b = b else { return [] }
        var keys = Set(a.values.keys)
        keys.formUnion(b.values.keys)
        let changes = keys.compactMap { k -> Change? in
            let old = a.values[k] ?? "--"
            let new = b.values[k] ?? "--"
            guard old != new else { return nil }
            return Change(id: k, oldValue: old, newValue: new)
        }
        return changes.sorted { LMSignalCatalog.numeric($0.id) < LMSignalCatalog.numeric($1.id) }
    }
}
