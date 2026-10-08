import Foundation
import Network

/// 极简回环 HTTP 服务：把 App bundle 里的 `Car3D/` 目录暴露成 `http://127.0.0.1:<port>/`
///
/// ## 为什么必须是 HTTP，而不是 `loadFileURL`
///
/// 官方 3D 车模查看器（three.js 打包产物）用
/// `new Worker("./FBX.worker.js")` 在 **Web Worker** 里解析 FBX，
/// 并用 XHR 拉取 `./D19_2026/D19_2026_full_car.fbx` 与一堆贴图/CSV。
///
/// WKWebView 对 `file://` 页面按「唯一不透明源」处理：
///   · `new Worker("file:///…")` 直接抛 SecurityError
///   · XHR 读本地文件被 CORS 拦掉（除非开私有偏好 allowFileAccessFromFileURLs）
///
/// 换成回环 HTTP 后，Worker / XHR / 相对路径全部回到标准浏览器语义，
/// 官方的 `index.html` + `index.js` + `FBX.worker.js` **一个字节都不用改**。
///
/// ## 实现取舍
///
/// 只实现「GET 一个静态文件」这一条路径，够用且不引入依赖：
///   · 只监听 127.0.0.1（`requiredInterfaceType = .loopback`），不对外暴露
///   · 端口交给系统分配（`.any`），避免与其它 App 撞端口
///   · 每个连接处理完一个请求就 `Connection: close`，不做 keep-alive
///   · 大文件（整车 FBX 5.9 MB）分块发送，避免单次 send 过大
final class Car3DServer {

    static let shared = Car3DServer()

    /// 服务根目录（bundle 内的 Car3D）
    private var root: URL?
    private var listener: NWListener?
    private var loopbackOnly = true

    /// 实际监听到的端口；未启动时为 0
    private(set) var port: UInt16 = 0

    private let queue = DispatchQueue(label: "com.example.leapmotorlite.car3d.server")

    private init() {}

    // MARK: - 启停

    /// 启动服务，返回可用端口。重复调用返回同一端口。
    @discardableResult
    func start() throws -> UInt16 {
        if port > 0, let l = listener, l.state == .ready { return port }

        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Car3D"),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path)
        else {
            throw Car3DServerError.missingBundleAssets
        }
        root = dir

        // 先按「只监听回环」启动；万一该参数在这台设备上不被接受，
        // 退一步不带限制再试一次，保证功能可用（端口随机，不写死）。
        do {
            port = try listen(loopbackOnly: true)
            self.loopbackOnly = true
        } catch {
            port = try listen(loopbackOnly: false)
            self.loopbackOnly = false
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// 页面 URL（`http://127.0.0.1:<port>/index.html`）
    func pageURL() throws -> URL {
        let p = try start()
        guard let u = URL(string: "http://127.0.0.1:\(p)/index.html") else {
            throw Car3DServerError.missingBundleAssets
        }
        return u
    }

    private func listen(loopbackOnly: Bool) throws -> UInt16 {
        listener?.cancel()
        listener = nil

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if loopbackOnly {
            params.requiredInterfaceType = .loopback
        }

        let l = try NWListener(using: params, on: .any)
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.stateUpdateHandler = { st in
            if case .failed(let e) = st {
                NSLog("[Car3D] listener failed: %@", String(describing: e))
            }
        }
        l.start(queue: queue)
        listener = l

        // NWListener 的 port 只有在 .ready 之后才有效
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if l.state == .ready, let p = l.port?.rawValue, p > 0 {
                return p
            }
            if case .failed = l.state {
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        l.cancel()
        listener = nil
        throw Car3DServerError.listenTimeout
    }

    // MARK: - 连接处理

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// 读到 `\r\n\r\n` 为止（只解析请求行，忽略 header/body —— 我们只服务 GET）
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }

            var buf = buffer
            if let d = data, !d.isEmpty { buf.append(d) }

            if let sep = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
                self.serve(conn, requestHead: head)
                return
            }
            if error != nil || isComplete || buf.count > 128 * 1024 {
                conn.cancel()
                return
            }
            self.readRequest(conn, buffer: buf)
        }
    }

    private func serve(_ conn: NWConnection, requestHead: String) {
        let firstLine = requestHead
            .components(separatedBy: "\r\n")
            .first ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)

        guard parts.count >= 2 else {
            reply(conn, status: 400, reason: "Bad Request", mime: "text/plain; charset=utf-8",
                  body: Data("bad request".utf8))
            return
        }
        guard parts[0].uppercased() == "GET" else {
            reply(conn, status: 405, reason: "Method Not Allowed", mime: "text/plain; charset=utf-8",
                  body: Data("method not allowed".utf8))
            return
        }

        var path = parts[1].split(separator: "?").first.map(String.init) ?? "/"
        path = path.removingPercentEncoding ?? path
        if path.isEmpty || path == "/" { path = "/index.html" }

        // 目录穿越防护：只允许根目录内的普通相对路径
        let comps = path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !comps.contains(".."), let root = root else {
            reply(conn, status: 403, reason: "Forbidden", mime: "text/plain; charset=utf-8",
                  body: Data("forbidden".utf8))
            return
        }

        var fileURL = root
        for c in comps { fileURL.appendPathComponent(c) }

        // 确认解析后仍在根目录内（防御符号链接/异常路径）
        let base = root.standardizedFileURL.path
        let target = fileURL.standardizedFileURL.path
        guard target == base || target.hasPrefix(base + "/") else {
            reply(conn, status: 403, reason: "Forbidden", mime: "text/plain; charset=utf-8",
                  body: Data("forbidden".utf8))
            return
        }

        guard let body = try? Data(contentsOf: fileURL) else {
            reply(conn, status: 404, reason: "Not Found", mime: "text/plain; charset=utf-8",
                  body: Data("404".utf8))
            return
        }

        reply(conn, status: 200, reason: "OK", mime: Car3DServer.mime(for: fileURL.pathExtension), body: body)
    }

    private func reply(_ conn: NWConnection, status: Int, reason: String, mime: String, body: Data) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"

        var packet = Data(head.utf8)
        packet.append(body)
        write(conn, packet)
    }

    /// 分块发送，最后一块发完再关连接（避免单次 send 过大被截断）
    private func write(_ conn: NWConnection, _ data: Data, offset: Int = 0) {
        let chunkSize = 256 * 1024
        if offset >= data.count {
            conn.cancel()
            return
        }
        let end = min(offset + chunkSize, data.count)
        let chunk = data.subdata(in: offset..<end)
        let isLast = end >= data.count
        conn.send(content: chunk, isComplete: isLast, completion: .contentProcessed { [weak self] err in
            if err != nil {
                conn.cancel()
                return
            }
            if isLast {
                // 最后一块已交给传输层，稍等一拍再关，确保对端读到 EOF
                self?.queue.asyncAfter(deadline: .now() + 0.05) { conn.cancel() }
            } else {
                self?.write(conn, data, offset: end)
            }
        })
    }

    // MARK: - MIME

    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "csv":         return "text/csv; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp":        return "image/webp"
        case "svg":         return "image/svg+xml"
        case "wasm":        return "application/wasm"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        default:            return "application/octet-stream"
        }
    }
}

enum Car3DServerError: LocalizedError {
    case missingBundleAssets
    case listenTimeout

    var errorDescription: String? {
        switch self {
        case .missingBundleAssets:
            return "App 包内没有 Car3D 资源目录（index.html 缺失）"
        case .listenTimeout:
            return "本地 3D 资源服务启动超时"
        }
    }
}
