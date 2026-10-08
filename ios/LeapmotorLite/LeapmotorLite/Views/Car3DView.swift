import SwiftUI
import WebKit

// MARK: - 3D 看车

/// 官方 3D 车模页。
///
/// ## 这套东西是怎么来的
///
/// 官方 App 的「3D 看车」**不是原生 3D 引擎**，而是：
///
/// ```
///   GET /carownerservice/v3/api/carpicture/3d/key      → h5Key / srcKey / modelParam
///   GET /carownerservice/v3/api/carpicture/key/package?key=<h5Key>   → 查看器 zip（three.js）
///   GET /carownerservice/v3/api/carpicture/key/package?key=<srcKey>  → 模型 zip（FBX + 贴图 + 配置）
/// ```
///
/// 两个 zip 解开后就是 `index.html` + `index.js`（1.6 MB three.js 打包产物）
/// + `FBX.worker.js` + `D19_2026/D19_2026_full_car.fbx`（5.9 MB 整车）。
///
/// 本 App 把这两包**离线内置**在 `Car3D/` 目录里，所以看车不依赖网络，
/// 只有「车型 / 颜色」参数走一次 `3d/key` 接口（拿到 `modelParam` 才能对上你车的真实配色）。
///
/// ## 交互
///
/// 官方的 `index.js` 自带 OrbitControls（`rotateSpeed` / `enableDamping` / `autoRotate`），
/// 单指拖动 = 全方位旋转，双指 = 缩放，这就是「可以全方位移动」的实现方式。
struct Car3DView: View {

    @EnvironmentObject var client: LMClient

    @State private var status = "正在启动本地 3D 服务…"
    @State private var ready = false
    @State private var failure: String?
    @State private var nonce = UUID()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                Car3DWebView(serverJSON: serverJSON,
                             appJSON: appJSON(width: geo.size.width, height: geo.size.height),
                             status: $status,
                             ready: $ready,
                             failure: $failure)
                    .id(nonce)
                    .opacity(ready ? 1 : 0)

                if !ready {
                    VStack(spacing: 12) {
                        if let f = failure {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30))
                                .foregroundStyle(.orange)
                            Text("3D 车模加载失败")
                                .font(.headline)
                            Text(f)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            Button("重试") {
                                failure = nil
                                status = "正在重新加载…"
                                nonce = UUID()
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            ProgressView()
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("3D 看车")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 车模参数来自 `3d/key`；没加载过就补一次（失败也不阻塞，用默认版型兜底）
            if client.car3DKey == nil {
                await client.refreshVehicleProfile()
            }
        }
    }

    // MARK: - 喂给官方查看器的两个 JSON

    /// 对应 `index.js` 里的 `parseServerJson()` —— 直接吃 `3d/key` 的 `modelParam`。
    ///
    /// 字段名必须与官方一致（`carType` / `year` / `carTypeCode` / `colorCode` / `roofColor`），
    /// 否则查看器会退回它自己的默认值（B10 / 2025 / 510悦享智驾版），车就变成别的车型。
    private var serverJSON: String {
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
        return Car3DView.jsonString(d)
    }

    /// 对应 `parseAppJson()` —— 画布尺寸必须跟真实视图一致，否则车会被裁切。
    private func appJSON(width: CGFloat, height: CGFloat) -> String {
        Car3DView.jsonString([
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

// MARK: - WKWebView 包装

/// 把官方查看器跑在 WKWebView 里。
///
/// 页面来自 `Car3DServer` 的 `http://127.0.0.1:<port>/index.html`
/// （**不能**用 `loadFileURL`，原因见 `Car3DServer` 的注释）。
struct Car3DWebView: UIViewRepresentable {

    let serverJSON: String
    let appJSON: String

    @Binding var status: String
    @Binding var ready: Bool
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(status: $status, ready: $ready, failure: $failure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.userContentController.add(context.coordinator, name: Coordinator.bridgeName)

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never

        context.coordinator.webViewRef = wv
        context.coordinator.start(serverJSON: serverJSON, appJSON: appJSON)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.updateSize(uiView.bounds.size)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController
            .removeScriptMessageHandler(forName: Coordinator.bridgeName)
        uiView.stopLoading()
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        static let bridgeName = "lm3d"

        private let status: Binding<String>
        private let ready: Binding<Bool>
        private let failure: Binding<String?>

        weak var webViewRef: WKWebView?
        private var serverJSON = "{}"
        private var appJSONText = "{}"
        private var booted = false
        private var lastSize: CGSize = .zero

        init(status: Binding<String>, ready: Binding<Bool>, failure: Binding<String?>) {
            self.status = status
            self.ready = ready
            self.failure = failure
        }

        // MARK: 启动

        func start(serverJSON: String, appJSON: String) {
            self.serverJSON = serverJSON
            self.appJSONText = appJSON
            do {
                let url = try Car3DServer.shared.pageURL()
                status.wrappedValue = "正在加载 3D 查看器…"
                let req = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 30)
                webViewRef?.load(req)
            } catch {
                failure.wrappedValue = error.localizedDescription
                status.wrappedValue = "启动失败"
            }
        }

        func updateSize(_ size: CGSize) {
            guard ready.wrappedValue, size.width > 1, size.height > 1 else { return }
            if abs(size.width - lastSize.width) < 1, abs(size.height - lastSize.height) < 1 { return }
            lastSize = size
            let w = Int(size.width.rounded())
            let h = Int(size.height.rounded())
            // 官方导出过 window.setRect；旋转 / 分屏后重新告知画布尺寸
            webViewRef?.evaluateJavaScript("""
            (function(){ try { if (typeof window.setRect === 'function') { window.setRect(\(w), \(h)); } } catch(e){} })();
            """, completionHandler: nil)
        }

        // MARK: 页面加载完成 → 驱动官方查看器

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
            status.wrappedValue = "加载失败"
            failure.wrappedValue = error.localizedDescription
        }

        private func boot() {
            guard !booted else { return }
            booted = true
            status.wrappedValue = "正在解析车模…"

            // `index.js` 是 `type="module"`，执行时机晚于 DOMContentLoaded，
            // 所以这里轮询等 `window.newInit` 就绪，而不是假设它一定在。
            let js = """
            (function(){
              var tries = 0;
              function post(o){
                try { window.webkit.messageHandlers.\(Coordinator.bridgeName).postMessage(o); } catch(e){}
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
                  window.newInit(\(Self.jsLiteral(serverJSON)), \(Self.jsLiteral(appJSONText)));
                  post({event:'init-called'});
                } catch (e) {
                  post({event:'error', message: String(e)});
                }
              }
              go();
            })();
            """
            webViewRef?.evaluateJavaScript(js) { [weak self] _, err in
                if let err = err {
                    self?.status.wrappedValue = "注入失败"
                    self?.failure.wrappedValue = err.localizedDescription
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

        // MARK: 官方查看器的原生回执

        /// 官方 `index.js` 在首帧渲染完成后会调 `window.prompt("onFirstFrame")`。
        /// 这就是「车模已经画出来了」的权威信号 —— 用它把 loading 收掉。
        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            if prompt == "onFirstFrame" {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.ready.wrappedValue = true
                    self.status.wrappedValue = "就绪"
                }
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
                status.wrappedValue = "正在加载车模文件…"
            case "init-called":
                status.wrappedValue = "正在解析车模…"
            case "error":
                status.wrappedValue = "加载失败"
                failure.wrappedValue = (body["message"] as? String) ?? "未知错误"
            default:
                break
            }
        }
    }
}
