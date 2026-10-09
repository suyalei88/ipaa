//
//  LMBaseViewController.swift
//  LeapmotorLite
//
//  所有 UIKit 页面的基类。
//
//  ★ 它替掉的是 SwiftUI 那套「@Published 一变，body 自动重算」的机制。
//    UIKit 没有这个能力，必须自己接一根线：订阅 `client.objectWillChange`，
//    变化时调一次 `render()`。
//
//  ★★ 最容易踩的坑：`objectWillChange` 是在**新值写入之前**触发的
//    （名字里的 "will" 就是这个意思）。如果直接在回调里读 `client.xxx`，
//    拿到的还是**旧值** —— 表现为「界面永远慢一拍」：第一次刷新显示的是
//    上一次的数据，最后一次变化永远看不到。所以必须推到下一轮主队列再刷。
//
//  ★ 第二个坑：一次网络请求回来会连续写十几个 `@Published`
//    （vehicles / signals / lastUpdate / isBusy ...），`objectWillChange`
//    也就连着触发十几次。每次都刷整个页面既浪费又闪。这里用 `renderPending`
//    把同一轮主队列内的多次触发合并成一次。
//
import UIKit
import Combine

@MainActor
class LMBaseViewController: UIViewController {

    /// 全局唯一的数据源。由 `LMAppDelegate` 创建后一路传下来，
    /// 页面**不要**自己 new 一个 —— 那样每个页面会各持一份状态。
    let client: LMClient

    private var cancellables = Set<AnyCancellable>()
    private var renderPending = false

    init(client: LMClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LMBaseViewController 只能代码创建")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .lmCanvas

        // ★ 2026-10-09（视觉重设计「碳黑霓虹」）：整页铺一层辉光底
        //   （近黑底 + 顶部极淡薄荷径向光晕）。它必须是**最底层**，
        //   所以在这里、`buildUI()` 之前加上 —— 之后 `makeScrollStack`
        //   往 `view` 上挂的 scroll 会自然盖在它上面。
        let backdrop = LMGlowBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        view.sendSubviewToBack(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        buildUI()

        client.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRender()
            }
            .store(in: &cancellables)

        // 首次进来先按当前状态铺一遍，不要等第一次变化
        render()
    }

    // MARK: - 子类要覆盖的两个方法

    /// 搭一次视图层级。只在 `viewDidLoad` 里调一次 ——
    /// 这里可以放心创建控件、加约束、绑 target/action。
    func buildUI() {
        // 默认什么都不做
    }

    /// 按 `client` 的当前状态刷新界面。
    ///
    /// ★ 会被反复调用，必须**幂等**：只改已有控件的属性
    /// （text / isHidden / tint / 约束常量），**不要**在这里 addSubview
    /// 或重建视图 —— 否则每来一次网络数据就叠一层控件，很快就卡死。
    func render() {
        // 默认什么都不做
    }

    // MARK: - 刷新节流

    private func scheduleRender() {
        guard !renderPending else { return }
        renderPending = true
        // ★ 用 `Task { @MainActor in }` 而不是 `DispatchQueue.main.async { }`：
        //   后者收到的是 `@Sendable` 闭包，**不继承**外层的 @MainActor 隔离，
        //   在 Swift 5 模式下调用 `render()` 可能被判成
        //   「Call to main actor-isolated instance method in a synchronous
        //   nonisolated context」直接编译失败。
        //   显式标了 `@MainActor` 的 Task 闭包一定是主 actor 隔离的，
        //   而且同样会在「当前这轮主线程工作跑完」之后才执行 ——
        //   正好满足「等 @Published 写完再读」的要求。
        Task { @MainActor in
            self.renderPending = false
            self.render()
        }
    }

    // MARK: - 滚动容器

    /// 建一个「垂直 StackView 装在 ScrollView 里」的滚动容器，铺满安全区。
    ///
    /// 返回 `stack`，调用方往里 `addArrangedSubview` 即可。
    /// 宽度约束挂 `frameLayoutGuide`（可见区）而不是 `contentLayoutGuide`，
    /// 这样内容不会被 ScrollView 撑成横向可滚。
    func makeScrollStack(spacing: CGFloat = 14,
                         inset: CGFloat = 16) -> (scroll: UIScrollView, stack: UIStackView) {
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let stack = LMUIKit.vStack(spacing: spacing)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let content = scroll.contentLayoutGuide
        let frame = scroll.frameLayoutGuide

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),

            stack.widthAnchor.constraint(equalTo: frame.widthAnchor, constant: -2 * inset),
        ])
        return (scroll, stack)
    }

    /// 给滚动容器挂下拉刷新。对应 SwiftUI 的 `.refreshable { }`。
    func attachRefresh(_ scroll: UIScrollView, _ action: @escaping () async -> Void) {
        let control = UIRefreshControl()
        control.tintColor = .lmAccent
        control.addAction(UIAction { [weak control] _ in
            Task { @MainActor in
                await action()
                control?.endRefreshing()
            }
        }, for: .valueChanged)
        scroll.refreshControl = control
    }

    // MARK: - 提示

    /// 弹一个「知道了」的提示框。对应 SwiftUI 里的 `.alert`。
    func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title,
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}
