//
//  LMCar3DWebView.swift
//  LeapmotorLite
//
//  UIKit 版「3D 车模」容器 —— 由原 `Views/Car3DView.swift` 里的
//  `enum Car3DConfig`（纯逻辑）与 `struct Car3DWebView: UIViewRepresentable`
//  （WKWebView 包装）合并而来。
//
//  ★ 为什么合并成同一个文件 / 同一个类：
//    SwiftUI 的 `UIViewRepresentable` 在 UIKit 里没有对应物，等价写法就是
//    自己写一个 `UIView` 子类、在里面持有 `WKWebView` 并实现三个 delegate。
//    `Car3DConfig` 只依赖 `LMClient`、不依赖 SwiftUI，且它服务的正是这个
//    WebView，跟着一起搬最不容易漏（全屏页与爱车页内嵌卡必须喂**完全一样**的参数）。
//
//  ★ 为什么把原来的 Coordinator 单独留成一个代理对象，而不是让
//    `LMCar3DWebView` 自己去当 delegate：
//    `WKUserContentController` 会**强引用**注册进去的 message handler，
//    而 handler 又（间接）指向 webView。如果让 view 自己当 handler，就是
//    `view → webView → controller → view` 的经典循环引用，WKWebView 永不释放。
//    所以照搬原 Coordinator：代理对象只持 **weak** 的 webView / host，
//    谁都不强引用宿主 view。
//
//  ★ 为什么状态回传用「闭包回调」而不是 `@Binding`：
//    UIKit 没有 Binding。三个回调标 `@MainActor`，这样 VC 里在闭包内直接读
//    自己的 `@MainActor` 状态（car3DStatus / render()）不会踩并发隔离的坑；
//    代理这边从非隔离上下文触发时统一用 `Task { @MainActor in }` 跳一轮。
//
import UIKit
import WebKit

// MARK: - 喂给官方查看器的两个 JSON（共享）

/// 官方 `index.js` 只认两个 JSON 字符串，全 App 只在这里构造一次。
///
/// 为什么抽出来：爱车页要**内嵌**一个可拖动的 3D 车模卡（固定高度），
/// 而「3D 看车」是全屏页 —— 两处必须喂**完全一样**的参数，
/// 否则同一台车在两个地方会长得不一样（车机会退回查看器的内置默认值，
/// 变成 B10 / 2025 / 510悦享智驾版）。
enum Car3DConfig {

    /// 对应 `index.js` 的 `parseServerJson()` —— 直接吃 `3d/key` 的 `modelParam`。
    ///
    /// 字段名必须与官方一致（`carType` / `year` / `carTypeCode` / `colorCode` / `roofColor`）。
    ///
    /// ★ 必须标 `@MainActor`：`LMClient` 整体是 `@MainActor` 隔离的，
    ///   而这是个 static 方法（默认 non-isolated），直接读 `client.car3DKey`
    ///   会报 `main actor-isolated property 'car3DKey' can not be referenced
    ///   from a non-isolated context` —— 这个错误在 CI 上真烧过一轮（2026-10-08）。
    ///   两处调用方（`Car3DView` / `LoveCarView`）本来就在主线程，
    ///   所以加 `@MainActor` 不需要任何 await。
    @MainActor
    static func serverJSON(for client: LMClient) -> String {
        let mp = client.car3DKey?.modelParam
        var d: [String: Any] = [
            "carType": mp?.carType ?? "D19",
            "year": mp?.year ?? 2026,
            "carTypeCode": mp?.carTypeCode ?? "720智尊版 六座",
            "colorCode": mp?.colorCode ?? 0,
            "roofColor": mp?.roofColor ?? "0",
            // 左舵 0 / 右舵 1
            "rudder": 0,
            // "0" = 让查看器按车型取默认座位数（D19 → 6）
            "seat": "0",
            "sdkVersion": "3.24.2",
            "licenseNumber": "",
        ]
        if let sel = mp?.selection, sel != "null", !sel.isEmpty {
            d["selection"] = sel
        }
        return jsonString(d)
    }

    /// 对应 `parseAppJson()` —— 画布尺寸必须跟真实视图一致，否则车会被裁切。
    ///
    /// ★ 内嵌卡每次尺寸变化（旋转 / 分屏）都会重新走这里，
    ///   所以不要缓存结果。
    static func appJSON(width: CGFloat, height: CGFloat) -> String {
        jsonString([
            "width": Int(width.rounded()),
            "height": Int(height.rounded()),
            "energy": 0,
            "inland": 0,
        ])
    }

    static func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}

// MARK: - 3D 车模（WKWebView 容器）

/// 官方 3D 车模的 UIKit 容器：内部持有一个透明 `WKWebView`，
/// 页面来自 `Car3DServer` 的 `http://127.0.0.1:<port>/index.html`
/// （**不能**用 `loadFileURL`，原因见 `Car3DServer` 的注释）。
///
/// 用法（全屏页 / 爱车页内嵌卡通用）：
/// ```swift
/// let web = LMCar3DWebView(serverJSON: Car3DConfig.serverJSON(for: client),
///                          appJSON: Car3DConfig.appJSON(width: w, height: h))
/// web.onStatus = { [weak self] s in self?.status = s; self?.render() }
/// web.onReady  = { [weak self] in self?.ready = true; self?.render() }
/// web.onFailure = { [weak self] m in self?.failure = m; self?.render() }
/// container.addSubview(web)      // 当普通 UIView 用
/// // 之后在 render() 里用 update(...) 刷新尺寸即可
/// ```
///
/// ★ 尺寸怎么走：`update(serverJSON:appJSON:)` 只负责把参数存下来并**尝试启动**；
///   真正的画布尺寸靠 `layoutSubviews` 里的 `window.setRect(w,h)` 通知官方查看器，
///   所以旋转 / 分屏后不用重建 WebView（对应原 `updateUIView` 的行为）。
final class LMCar3DWebView: UIView {

    /// 加载状态文字（对应原 `@Binding status`）。
    var onStatus: (@MainActor (String) -> Void)?
    /// 首帧渲染完成（官方 `window.prompt("onFirstFrame")` 回执）。
    var onReady: (@MainActor () -> Void)?
    /// 失败原因（对应原 `@Binding failure`）。
    var onFailure: (@MainActor (String) -> Void)?

    private let webView: WKWebView
    private let proxy: LM3DWebProxy
    /// 是否已经发起过加载。★ 只启动一次 —— `start()` 里 `pageURL()` 会阻塞
    /// 主线程等回环服务就绪（最多 5s），绝不能每次 layout 都跑一遍。
    private var started = false

    // MARK: - 构造

    init(serverJSON: String, appJSON: String) {
        // ★ 顺序很关键：`WKWebView(frame:configuration:)` 会在初始化时**拷贝**
        //   一份 configuration，所以 message handler 必须在创建 WebView **之前**
        //   就注册进 `cfg.userContentController`，否则回调永远收不到。
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let proxy = LM3DWebProxy()
        cfg.userContentController.add(proxy, name: LM3DWebProxy.bridgeName)

        let wv = WKWebView(frame: .zero, configuration: cfg)
        self.webView = wv
        self.proxy = proxy
        super.init(frame: .zero)

        backgroundColor = .clear

        // 原 `makeUIView` 里的样式原样搬过来
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wv)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        proxy.host = self
        proxy.webView = wv
        wv.navigationDelegate = proxy
        wv.uiDelegate = proxy

        proxy.configure(serverJSON: serverJSON, appJSON: appJSON)
    }

    required init?(coder: NSCoder) {
        fatalError("LMCar3DWebView 只能代码创建")
    }

    // MARK: - 对外接口

    /// 幂等刷新：存下最新的两个 JSON，并在还没启动时尝试启动。
    ///
    /// ★ 供 `render()` 反复调用 —— 里面不 addSubview、不重建 WebView，
    ///   只做「存参数 + 必要时 setRect」。
    func update(serverJSON: String, appJSON: String) {
        proxy.configure(serverJSON: serverJSON, appJSON: appJSON)
        startIfNeeded()
        proxy.pushSize(bounds.size)
    }

    /// 重新加载（重试 / 从 `unload()` 恢复）。
    ///
    /// 对应原 SwiftUI 里「改 `nonce` 让 `Car3DWebView` 整个重建」的语义：
    /// 重置内部状态后重新走一遍「启动 → 注入 → 等首帧」。
    func reload(serverJSON: String, appJSON: String) {
        proxy.configure(serverJSON: serverJSON, appJSON: appJSON)
        started = true
        proxy.reload()
    }

    /// 卸载重型页面（打开全屏 3D 前调用，避免两份车模同时在内存里）。
    ///
    /// 官方查看器要在 Web Worker 里解析 5.9 MB 的整车 FBX，一个实例常驻内存上百 MB。
    /// 这里把 WebView 导航到一个空白页，等于把整棵 JS 堆（含 worker）丢掉，
    /// 之后再用 `reload(...)` 拉回来。
    func unload() {
        proxy.unload()
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        // 首次拿到有效尺寸时启动；之后尺寸变化只通知查看器改画布。
        startIfNeeded()
        proxy.pushSize(bounds.size)
    }

    private func startIfNeeded() {
        guard !started, bounds.width > 1, bounds.height > 1 else { return }
        started = true
        proxy.start()
    }
}

// MARK: - WKWebView delegate 代理（原 Coordinator）

/// 原 `Car3DWebView.Coordinator` 的等价物。
///
/// 三个协议全在这一个对象上：
///   · `WKNavigationDelegate` —— 页面加载完成 / 失败
///   · `WKUIDelegate`         —— 官方 `index.js` 用 `window.prompt("onFirstFrame")` 回报首帧
///   · `WKScriptMessageHandler` —— 页面里 `window.webkit.messageHandlers.lm3d` 的事件
///
/// ★ 引用关系（照搬原 Coordinator 的 weak 处理）：
///   `host` / `webView` 都是 weak。`WKUserContentController` 会强引用本对象，
///   所以本对象绝不能强引用 host（否则 host ↔ controller ↔ proxy 成环）。
private final class LM3DWebProxy: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    static let bridgeName = "lm3d"

    weak var host: LMCar3DWebView?
    weak var webView: WKWebView?

    /// ★ 叫 `serverJSONText` 而不是 `serverJSON`：
    ///   同文件里 `Car3DConfig.serverJSON(for:)` 是个方法名，
    ///   属性叫同名会遮蔽它（lint R12）。
    private var serverJSONText = "{}"
    private var appJSONText = "{}"
    private var booted = false
    private var ready = false
    private var lastSize: CGSize = .zero

    // MARK: - 生命周期

    func configure(serverJSON: String, appJSON: String) {
        serverJSONText = serverJSON
        appJSONText = appJSON
    }

    /// 启动本地回环服务并加载查看器页面（对应原 `start(serverJSON:appJSON:)`）。
    func start() {
        // 画布尺寸优先用 WebView 的真实 bounds —— 它比调用方在布局前
        // 估的宽度更准，能避免首帧把车裁掉（之后 setRect 还会再校正一次）。
        if let b = webView?.bounds, b.width > 1, b.height > 1 {
            appJSONText = Car3DConfig.appJSON(width: b.width, height: b.height)
        }
        do {
            let url = try Car3DServer.shared.pageURL()
            reportStatus("正在加载 3D 查看器…")
            let req = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
            webView?.load(req)
        } catch {
            reportFailure(error.localizedDescription)
            reportStatus("启动失败")
        }
    }

    func reload() {
        booted = false
        ready = false
        lastSize = .zero
        start()
    }

    func unload() {
        // ★ 置 `booted = true`：空白页也会触发 `didFinish`，不拦住的话
        //   会在空白页上注入 `newInit` 并报「newInit 未就绪」的假失败。
        booted = true
        ready = false
        lastSize = .zero
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
    }

    /// 尺寸变化后告知官方查看器改画布（对应原 `updateSize`）。
    func pushSize(_ size: CGSize) {
        guard ready, size.width > 1, size.height > 1 else { return }
        if abs(size.width - lastSize.width) < 1, abs(size.height - lastSize.height) < 1 { return }
        lastSize = size
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        // 官方导出过 window.setRect；旋转 / 分屏后重新告知画布尺寸
        webView?.evaluateJavaScript("""
        (function(){ try { if (typeof window.setRect === 'function') { window.setRect(\(w), \(h)); } } catch(e){} })();
        """, completionHandler: nil)
    }

    // MARK: - 页面加载完成 → 驱动官方查看器

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        boot()
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        let ns = error as NSError
        // 页面内主动取消（比如我们自己的重试）不算失败
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        reportStatus("加载失败")
        reportFailure(error.localizedDescription)
    }

    private func boot() {
        guard !booted else { return }
        booted = true
        reportStatus("正在解析车模…")

        // `index.js` 是 `type="module"`，执行时机晚于 DOMContentLoaded，
        // 所以这里轮询等 `window.newInit` 就绪，而不是假设它一定在。
        let js = """
        (function(){
          var tries = 0;
          function post(o){
            try { window.webkit.messageHandlers.\(Self.bridgeName).postMessage(o); } catch(e){}
          }
          function go(){
            if (typeof window.newInit !== 'function') {
              if (++tries > 40) { post({event:'error', message:'newInit 未就绪（index.js 可能没加载成功）'}); return; }
              setTimeout(go, 250); return;
            }
            try {
              // 必须先打开这个开关：查看器内部据此把「首帧完成」通过
              // window.prompt("onFirstFrame") 上报给原生（见 handleSwitchCar）
              if (typeof window.onIOSWebview === 'function') { window.onIOSWebview(); }
              post({event:'api-ready'});
              window.newInit(\(Self.jsLiteral(serverJSONText)), \(Self.jsLiteral(appJSONText)));
              post({event:'init-called'});
            } catch (e) {
              post({event:'error', message: String(e)});
            }
          }
          go();
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] _, err in
            if let err = err {
                self?.reportStatus("注入失败")
                self?.reportFailure(err.localizedDescription)
            }
        }
    }

    /// 把一个 Swift 字符串转成合法的 JS 字符串字面量（含引号）
    static func jsLiteral(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
           let out = String(data: d, encoding: .utf8) {
            return out
        }
        return "\"{}\""
    }

    // MARK: - 官方查看器的原生回执

    /// 官方 `index.js` 在首帧渲染完成后会调 `window.prompt("onFirstFrame")`。
    /// 这就是「车模已经画出来了」的权威信号 —— 用它把 loading 收掉。
    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        if prompt == "onFirstFrame" {
            // 本代理是非隔离的，直接写 `host.onReady`（@MainActor 属性）会报
            // 「main actor-isolated ... in a synchronous nonisolated context」，
            // 所以统一用 Task 跳回主 actor 再回调。
            ready = true
            reportReady()
        }
        // 必须同步回调，否则页面里的 JS 会一直挂着
        completionHandler(nil)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }

        switch event {
        case "api-ready":
            reportStatus("正在加载车模文件…")
        case "init-called":
            reportStatus("正在解析车模…")
        case "error":
            reportStatus("加载失败")
            reportFailure((body["message"] as? String) ?? "未知错误")
        default:
            break
        }
    }

    // MARK: - 回调（统一跳回主 actor）

    private func reportStatus(_ s: String) {
        guard let host = host else { return }
        Task { @MainActor in host.onStatus?(s) }
    }

    private func reportReady() {
        guard let host = host else { return }
        Task { @MainActor in host.onReady?() }
    }

    private func reportFailure(_ m: String) {
        guard let host = host else { return }
        Task { @MainActor in host.onFailure?(m) }
    }
}
