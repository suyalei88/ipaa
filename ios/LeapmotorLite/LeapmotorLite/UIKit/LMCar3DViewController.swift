//
//  LMCar3DViewController.swift
//  LeapmotorLite
//
//  全屏「3D 看车」页（UIKit 版）—— 对应原 `Views/Car3DView.swift` 里的 `struct Car3DView`。
//
//  ## 这一页到底在干什么
//
//  官方 App 的「3D 看车」不是原生 3D 引擎，而是把官方查看器（three.js 打包产物）
//  跑在 WKWebView 里：
//      GET /carownerservice/v3/api/carpicture/3d/key  → h5Key / srcKey / modelParam
//      GET /carownerservice/v3/api/carpicture/key/package?key=...  → 查看器 zip / 模型 zip
//  两个 zip 离线内置在 `Car3D/`，页面来自 `Car3DServer` 的本地回环 HTTP 服务。
//  真正的加载逻辑都在 `LMCar3DWebView`（UIKit 容器）里，本页只负责：
//      · 铺一层 WebView + loading / 失败态浮层
//      · 把 WebView 回传的 status / ready / failure 反映到浮层
//
//  ★ 迁移约定（与 `LMControlPanelViewController` / `LMLoginViewController` 一致）：
//    · 只覆盖 `buildUI()` / `render()`；`render()` 幂等，条件内容用 `isHidden` 折叠
//    · 页内状态（status / ready / failure）**不进 `LMClient`**
//    · 只 `import UIKit`（+ WebKit 在 LMCar3DWebView 里），不 import SwiftUI
//
import UIKit

final class LMCar3DViewController: LMBaseViewController {

    // MARK: - 页内状态（纯 UI，跟车端无关）

    private var status = "正在启动本地 3D 服务…"
    private var ready = false
    private var failure: String?

    // MARK: - 控件

    private var car3D: LMCar3DWebView?

    private let loadingBox = LMUIKit.vStack(spacing: 10, alignment: .center)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()

    private let failureBox = LMUIKit.vStack(spacing: 10, alignment: .center)
    private let failureIcon = UIImageView()
    private let failureTitle = UILabel()
    private let failureMessage = UILabel()

    // MARK: - 搭视图树（只跑一次）

    override func buildUI() {
        title = "3D 看车"
        navigationItem.largeTitleDisplayMode = .never
        // 原页是 `Color(.systemBackground)` 打底，车模直接浮在上面。
        view.backgroundColor = .systemBackground

        // 3D 容器：整块铺满安全区（导航栏之下的内容区）。
        let web = LMCar3DWebView(serverJSON: Car3DConfig.serverJSON(for: client),
                                 appJSON: Car3DConfig.appJSON(width: currentWidth(),
                                                              height: currentHeight()))
        web.translatesAutoresizingMaskIntoConstraints = false
        // 原页用 `.opacity(ready ? 1 : 0)`：没就绪时先藏着，避免看到白屏 / 半成品
        web.alpha = 0
        // ★ 闭包类型是 `@MainActor`（见 LMCar3DWebView 的声明），
        //   所以这里可以直接摸自己的 @MainActor 状态，不需要再包一层 Task。
        web.onStatus = { [weak self] s in
            self?.status = s
            self?.render()
        }
        web.onReady = { [weak self] in
            guard let self else { return }
            self.ready = true
            self.failure = nil
            self.render()
        }
        web.onFailure = { [weak self] m in
            guard let self else { return }
            self.failure = m
            self.ready = false
            self.render()
        }
        view.addSubview(web)
        car3D = web

        buildLoadingBox()
        buildFailureBox()

        // 浮层：loading 与失败态二选一，居中。放在同一个竖排里，
        // 隐藏的那个会被 StackView 自动塌成 0 高度（等价 SwiftUI 的 `if`）。
        let overlay = LMUIKit.vStack(spacing: 16, alignment: .center)
        overlay.addArrangedSubview(loadingBox)
        overlay.addArrangedSubview(failureBox)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)

        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            overlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor,
                                             constant: 24),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor,
                                              constant: -24),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 对应原页 `.task { if client.car3DKey == nil { await client.refreshVehicleProfile() } }`：
        // 车模参数来自 `3d/key`；没加载过就补一次（失败也不阻塞，用默认版型兜底）。
        if client.car3DKey == nil {
            Task { @MainActor in await client.refreshVehicleProfile() }
        }
    }

    private func buildLoadingBox() {
        spinner.color = .secondaryLabel
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        hintLabel.text = "未取到 3d/key，先用默认版型（D19 六座）渲染"
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        loadingBox.addArrangedSubview(spinner)
        loadingBox.addArrangedSubview(statusLabel)
        loadingBox.addArrangedSubview(hintLabel)
    }

    private func buildFailureBox() {
        failureIcon.image = UIImage(systemName: "exclamationmark.triangle")
        failureIcon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 30)
        // 原页是 `.orange`；调色板里等价的是 lmWarn。
        failureIcon.tintColor = .lmWarn
        failureIcon.contentMode = .scaleAspectFit

        failureTitle.text = "3D 车模加载失败"
        failureTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        failureTitle.textAlignment = .center

        failureMessage.font = .systemFont(ofSize: 12)
        failureMessage.textColor = .secondaryLabel
        failureMessage.textAlignment = .center
        failureMessage.numberOfLines = 0

        let retry = LMUIKit.primaryButton("重试")
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        failureBox.addArrangedSubview(failureIcon)
        failureBox.addArrangedSubview(failureTitle)
        failureBox.addArrangedSubview(failureMessage)
        failureBox.addArrangedSubview(retry)
        failureBox.isHidden = true
    }

    // MARK: - 刷新（会被反复调用，必须幂等）

    override func render() {
        guard let car3D = car3D else { return }

        // 每次 render 都喂一遍参数：内部只在尺寸真变了时才通知查看器，幂等。
        car3D.update(serverJSON: Car3DConfig.serverJSON(for: client),
                     appJSON: Car3DConfig.appJSON(width: currentWidth(),
                                                  height: currentHeight()))
        car3D.alpha = ready ? 1 : 0

        statusLabel.text = status
        // 原页是 `if let f = failure { 失败态 } else { loading }` —— 两者互斥。
        // 这里必须写成「ready 或已失败就收掉 loading」，否则失败时会同时看到
        // 转圈和错误提示两块浮层叠在一起。
        let showLoading = !ready && failure == nil
        loadingBox.isHidden = !showLoading
        if showLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
        hintLabel.isHidden = hasModelParam
        failureBox.isHidden = (failure == nil)
        if let failure = failure { failureMessage.text = failure }
    }

    // MARK: - 动作

    @objc private func retryTapped() {
        failure = nil
        ready = false
        status = "正在重新加载…"
        render()
        car3D?.reload(serverJSON: Car3DConfig.serverJSON(for: client),
                      appJSON: Car3DConfig.appJSON(width: currentWidth(),
                                                   height: currentHeight()))
    }

    // MARK: - 小工具

    /// 是否已经拿到 `3d/key`（拿不到就用默认版型兜底，见 `Car3DConfig`）。
    private var hasModelParam: Bool { client.car3DKey?.modelParam != nil }

    /// 画布宽度：布局前 `view.bounds` 可能是 0，退回窗口宽度（`UIScreen.main` 已弃用）。
    private func currentWidth() -> CGFloat {
        let w = view.bounds.width
        if w > 1 { return w }
        return view.window?.bounds.width ?? 393
    }

    private func currentHeight() -> CGFloat {
        let h = view.bounds.height
        if h > 1 { return h }
        return view.window?.bounds.height ?? 852
    }
}
