//
//  LMBLECentral.swift
//  LeapmotorLite
//
//  BLE 车钥匙的 CoreBluetooth 封装。
//
//  ═══════════════════════════════════════════════════════════════════════════
//  这个类**不是**「能解锁车」的实现，它是一个**仪表**。
//  ═══════════════════════════════════════════════════════════════════════════
//  为什么先做仪表：官方那套是 ECDH 临时密钥协商 + 对称加密 + 时间戳防重放的
//  私有协议（证据见 LMBLEProtocol.swift），静态逆向只拿到了字段名和帧模板，
//  拿不到 passwordCard 和 cmdId 表。硬猜着发指令是拿真车做实验，不负责任。
//
//  这个类能做的是把「还差什么」变成可观测的：
//    ① 扫描     —— 按官方服务 UUID 过滤，看车在不在广播、广播里有什么
//    ② 连接     —— 保留 CBPeripheral 引用（CBCentralManager 自己不保留）
//    ③ GATT 树  —— 服务的 UUID / 主次、每个特征的可读写通知属性
//    ④ 订阅     —— 挂上通知，把官方 App 的每一帧原样记下来
//    ⑤ 写       —— 能发任意字节（配合日志就能试出帧格式）
//  有了 ④ 的真实帧，帧语义和 cmdId 表当天就能定下来。
//
//  ── 线程模型（★ 这是个真会炸的坑）─────────────────────────────────────────
//  CBCentralManager 的 delegate 回调**不在主线程**，除非你显式传 queue: nil。
//  在回调里直接写 @Published 会撞 SwiftUI 的「Publishing changes from
//  background threads is not allowed」，轻则界面不刷新，重则崩溃。
//  这里统一用 `queue: nil`（= 主队列），从根上避免，而不是在每个回调里
//  手动 DispatchQueue.main.async（那种写法漏一个就出事）。
//
//  ── 后台运行 ─────────────────────────────────────────────────────────────
//  Info.plist 里已声明 `bluetooth-central` 后台模式 + restore identifier，
//  这样 App 被系统回收后仍能恢复中心设备状态（「无感」体验的前提）。
//  注意：iOS 的后台 BLE 是有节流的，别指望秒级实时。
//
import Foundation
import CoreBluetooth

// MARK: - 扫描到的设备

struct LMBLEDevice: Identifiable {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    /// 广播内容，已渲染成可读文本
    var advertisement: [String: String]
    /// 启发式标记：名字里带 leapmotor/lmv/supcon… 或广播里带官方服务 UUID
    var isLikelyVehicle: Bool
    var lastSeen: Date
    var isConnectable: Bool

    /// `CBPeripheral.identifier` 是 iOS 给这个外设分配的 UUID。
    ///
    /// ★ 注意：**不是** MAC 地址。iOS 从 iOS 7 起就不给 App MAC 了，
    ///   同一个外设在两台手机上拿到的 identifier 也不一样。
    ///   要认车只能靠：名字、广播里的厂商数据、或者连上后读特征值。
    ///   官方 commonConfig 里那个 `mac: C8C83FF5C48E` 是**车端**记录的，
    ///   跟我们这边的 identifier 对不上，别想着直接比对。
    var id: UUID { peripheral.identifier }

    /// identifier 的前 8 位，UI 里显示用
    var shortId: String { peripheral.identifier.uuidString.prefix(8).lowercased() }

    var stateText: String {
        switch peripheral.state {
        case .connected:    return "已连接"
        case .connecting:   return "连接中"
        case .disconnecting:return "断开中"
        case .disconnected: return "未连接"
        @unknown default:   return "未知"
        }
    }
}

// MARK: - GATT 树

struct LMBLECharacteristic: Identifiable {
    let uuid: String
    /// 中文属性标签，如 ["读", "写", "通知"]
    let props: [String]
    let canWrite: Bool
    let canWriteNoResponse: Bool
    let canNotify: Bool
    var isNotifying: Bool
    /// 最近一次收到的值（hex）
    var lastValue: String?

    /// ★ 服务 UUID 可能重复，特征 UUID 也可能重复，所以 id 用「服务/特征」拼
    var id: String { uuid }
}

struct LMBLEService: Identifiable {
    let uuid: String
    let isPrimary: Bool
    var characteristics: [LMBLECharacteristic]
    var id: String { uuid }
}

// MARK: - 日志

struct LMBLELogEntry: Identifiable {

    enum Direction: String {
        case info  = "系统"
        case tx    = "发送"
        case rx    = "接收"
        case error = "错误"

        var symbol: String {
            switch self {
            case .info:  return "info.circle"
            case .tx:    return "arrow.up.circle.fill"
            case .rx:    return "arrow.down.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }
    }

    let id = UUID()
    let at: Date
    let direction: Direction
    /// 人可读的摘要
    let text: String
    /// 原始字节（hex，空格分隔）
    let hex: String?
    /// 能按 ASCII 读出来时的文本
    let ascii: String?
    /// 按 `;` 切分的结果（官方帧模板就是分号分隔）
    let fields: [String]?

    var hasPayload: Bool { hex != nil }
}

// MARK: - 中心设备

/// BLE 中心设备封装。
///
/// ★ 刻意**不加** `@MainActor`：
///   `CBCentralManagerDelegate` / `CBPeripheralDelegate` 的协议方法在
///   Swift 6 严格并发下不是 main-isolated，把类标成 @MainActor 会引出一堆
///   隔离相关的编译错误。用 `queue: nil` 保证回调落在主队列，
///   再从数据层面保证「所有 @Published 都在主线程写」，等效且不打架。
final class LMBLECentral: NSObject, ObservableObject {

    // MARK: Published

    /// 蓝牙状态（`.poweredOn` 才能扫）
    @Published private(set) var state: LMBLEState = .unknown
    @Published private(set) var devices: [LMBLEDevice] = []
    @Published private(set) var isScanning = false
    /// 当前连接上的设备（同一时刻只连一个 —— 车钥匙场景不需要多连）
    @Published private(set) var connected: LMBLEDevice?
    @Published private(set) var services: [LMBLEService] = []
    @Published private(set) var log: [LMBLELogEntry] = []
    /// 最近一次错误（UI 顶部横幅）
    @Published var lastError: String?

    /// 用户选的写入方式（有应答更可靠，但某些固件只吃无应答）
    @Published var writeWithResponse = true

    // MARK: 私有

    private var central: CBCentralManager?
    /// CBCentralManager **不保留**发现到的外设，必须自己存着，否则 connect 直接失效
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// 当前订阅中的特征，断开时要能取消
    private var subscribed: Set<String> = []
    /// 日志上限 —— 订阅通知时一秒能来几十帧，不封顶会吃光内存
    private let logLimit = 1200

    /// 后台恢复标识。跟 Info.plist 的 bluetooth-central 后台模式配套。
    private static let restoreId = "com.example.leapmotorlite.central"

    // MARK: 生命周期

    override init() {
        super.init()
        // ★ queue: nil = 主队列。见文件头的线程模型说明。
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: LMBLECentral.restoreId])
        append(.info, "CoreBluetooth 已初始化（delegate 队列 = 主队列）")
    }

    /// 第一次进页面时再建 central，避免 App 一启动就弹蓝牙权限。
    /// 没权限时 iOS 会直接把 state 置成 .unauthorized，不需要额外处理。
    func prepare() {
        if central == nil {
            central = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionRestoreIdentifierKey: LMBLECentral.restoreId])
        }
    }

    // MARK: 扫描

    /// - Parameter filterByService: true 时只按官方服务 UUID 过滤（车在广播这个服务才看得到）；
    ///   false 时全扫（用来排查「车没广播那个 UUID」的情况）
    func startScan(filterByService: Bool) {
        guard let c = central else { prepare(); return }
        guard state.canUse else {
            lastError = "蓝牙不可用：\(state.rawValue)"
            append(.error, "无法扫描 —— \(state.rawValue)")
            return
        }
        stopScan()

        let uuids = filterByService ? LMBLEUUID.scanFilters.map { CBUUID(string: $0) } : nil
        devices = []
        peripherals = [:]
        // allowDuplicates = true：RSSI 要能持续刷新，否则只能看到一次
        c.scanForPeripherals(withServices: uuids,
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        append(.info, filterByService
               ? "开始扫描（按官方服务 UUID \(LMBLEUUID.service) 过滤）"
               : "开始全量扫描（不过滤服务，可能看到一堆无关设备）")
    }

    func stopScan() {
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
        append(.info, "已停止扫描，共看到 \(devices.count) 个设备")
    }

    // MARK: 连接

    func connect(_ device: LMBLEDevice) {
        guard let p = peripherals[device.id] else {
            lastError = "外设引用已丢失，重新扫一次"
            append(.error, "连接失败：外设引用丢失（CBCentralManager 不保留外设，必须自己存）")
            return
        }
        if let cur = connected, cur.id != device.id { disconnect() }
        stopScan()
        append(.info, "连接 \(device.name) [\(device.shortId)]…")
        services = []
        p.delegate = self
        central?.connect(p, options: nil)
    }

    func disconnect() {
        guard let d = connected, let p = peripherals[d.id] else { connected = nil; return }
        if !subscribed.isEmpty {
            for s in p.services ?? [] {
                for c in s.characteristics ?? [] where c.isNotifying {
                    p.setNotifyValue(false, for: c)
                }
            }
            subscribed.removeAll()
        }
        central?.cancelPeripheralConnection(p)
        append(.info, "主动断开 \(d.name)")
    }

    /// 发现全部服务与特征（连上之后自动跑一次，也可以手动重跑）
    func rediscover() {
        guard let d = connected, let p = peripherals[d.id] else { return }
        services = []
        append(.info, "开始发现服务…")
        p.discoverServices(nil)
    }

    /// 读一次 RSSI（连接状态下才有意义，能粗略判断远近）
    func readRSSI() {
        guard let d = connected, let p = peripherals[d.id] else { return }
        p.readRSSI()
    }

    // MARK: 订阅 / 写入

    /// 挂上通知。**这是抓官方帧的关键动作** —— 挂上之后，官方 App 每次操作
    /// 车机回的每一帧都会走 `didUpdateValueFor`，被原样记进日志。
    func toggleNotify(serviceUUID: String, charUUID: String) {
        guard let d = connected, let p = peripherals[d.id] else { return }
        guard let ch = findCharacteristic(serviceUUID: serviceUUID, charUUID: charUUID) else { return }
        let key = "\(serviceUUID)/\(charUUID)"
        let want = !ch.isNotifying
        p.setNotifyValue(want, for: ch)
        if want { subscribed.insert(key) } else { subscribed.remove(key) }
        append(.info, "\(want ? "订阅" : "取消订阅") \(charUUID)")
    }

    /// 读一次特征值
    func readValue(serviceUUID: String, charUUID: String) {
        guard let d = connected, let p = peripherals[d.id] else { return }
        guard let ch = findCharacteristic(serviceUUID: serviceUUID, charUUID: charUUID) else { return }
        p.readValue(for: ch)
        append(.info, "读取 \(charUUID)")
    }

    /// 发送原始字节。
    ///
    /// 超过单包长度时按 MTU 自动分包 —— 官方有 `canBeSkippedLength` / `sendAllYet`
    /// 两个字段，说明它自己也是分包的，所以这里也分。
    @discardableResult
    func write(serviceUUID: String, charUUID: String, data: Data) -> Bool {
        guard let d = connected, let p = peripherals[d.id] else {
            lastError = "还没连上设备"
            return false
        }
        guard let ch = findCharacteristic(serviceUUID: serviceUUID, charUUID: charUUID) else {
            lastError = "找不到特征 \(charUUID)"
            return false
        }
        let type: CBCharacteristicWriteType = writeWithResponse ? .withResponse : .withoutResponse
        if type == .withResponse && !ch.properties.contains(.write) {
            lastError = "该特征不支持「写(有应答)」，改用无应答"
            append(.error, "\(charUUID) 不支持 withResponse 写入")
            return false
        }
        if type == .withoutResponse && !ch.properties.contains(.writeWithoutResponse) {
            lastError = "该特征不支持「写(无应答)」，改用有应答"
            append(.error, "\(charUUID) 不支持 withoutResponse 写入")
            return false
        }

        let mtu = p.maximumWriteValueLength(for: type)
        let chunks = stride(from: 0, to: data.count, by: max(mtu, 1)).map {
            data.subdata(in: $0..<min($0 + mtu, data.count))
        }
        append(.tx, "写 \(charUUID)（\(type == .withResponse ? "有应答" : "无应答")，"
                    + "\(data.count) 字节 / MTU \(mtu) / \(chunks.count) 包）", data: data)
        for (i, c) in chunks.enumerated() {
            p.writeValue(c, for: ch, type: type)
            if chunks.count > 1 { append(.info, "  └ 第 \(i + 1)/\(chunks.count) 包：\(LMBLEHex.string(c))") }
        }
        return true
    }

    // MARK: 日志

    func clearLog() {
        log.removeAll()
        append(.info, "日志已清空")
    }

    /// 导出成纯文本，方便贴给别人 / 存证
    func exportLog() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        var out = "# LeapmotorLite BLE 日志\n"
        out += "# 设备：\(connected?.name ?? "-") [\(connected?.shortId ?? "-")]\n"
        out += "# 服务：\(services.map { $0.uuid }.joined(separator: ", "))\n"
        out += "# 帧数：\(log.filter { $0.hasPayload }.count)\n\n"
        for e in log {
            out += "\(f.string(from: e.at))  [\(e.direction.rawValue)]  \(e.text)\n"
            if let h = e.hex { out += "      hex : \(h)\n" }
            if let a = e.ascii { out += "      text: \(a)\n" }
            if let fs = e.fields {
                // ★ 先把分号段拼好再插值，不要写成
                //   "\(fs.enumerated().map { "[\($0.offset)]..." }...)"
                //   —— 三层嵌套字符串字面量套在同一个插值里，解析器容易翻车。
                let segs = fs.enumerated()
                    .map { "[\($0.offset)]\($0.element)" }
                    .joined(separator: "  ")
                out += "      segs: \(segs)\n"
            }
        }
        return out
    }

    private func append(_ dir: LMBLELogEntry.Direction, _ text: String, data: Data? = nil) {
        let frame = data.map { LMBLEFrame(raw: $0, at: Date()) }
        let entry = LMBLELogEntry(
            at: Date(),
            direction: dir,
            text: text,
            hex: frame?.hex,
            ascii: frame?.ascii,
            fields: frame?.fields)
        log.append(entry)
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
    }

    private func findCharacteristic(serviceUUID: String, charUUID: String) -> CBCharacteristic? {
        guard let d = connected, let p = peripherals[d.id] else { return nil }
        for s in p.services ?? [] where s.uuid.uuidString.uppercased() == serviceUUID.uppercased() {
            for c in s.characteristics ?? [] where c.uuid.uuidString.uppercased() == charUUID.uppercased() {
                return c
            }
        }
        return nil
    }

    /// `CBCharacteristicProperties` → 中文标签。
    ///
    /// 为什么不用 `String(describing:)`：那个会打出
    /// `CBCharacteristicProperties(rawValue: ...)` 这种带位域数字的字符串，
    /// 又长又看不出「能不能写」。中文标签在 GATT 树上是一眼可读的。
    private static func labels(_ pr: CBCharacteristicProperties) -> [String] {
        var out: [String] = []
        if pr.contains(.broadcast)               { out.append("广播") }
        if pr.contains(.read)                    { out.append("读") }
        if pr.contains(.writeWithoutResponse)    { out.append("写(无应答)") }
        if pr.contains(.write)                   { out.append("写") }
        if pr.contains(.notify)                  { out.append("通知") }
        if pr.contains(.indicate)                { out.append("指示") }
        if pr.contains(.authenticatedSignedWrites) { out.append("签名写") }
        if pr.contains(.extendedProperties)      { out.append("扩展") }
        if pr.contains(.notifyEncryptionRequired) { out.append("通知(需加密)") }
        if pr.contains(.indicateEncryptionRequired) { out.append("指示(需加密)") }
        return out.isEmpty ? ["无"] : out
    }

    /// 从 UUID 字符串反查我们缓存的 GATT 树里的那条（UI 要用它的属性）
    func characteristic(serviceUUID: String, charUUID: String) -> LMBLECharacteristic? {
        services.first { $0.uuid == serviceUUID }?
            .characteristics.first { $0.uuid == charUUID }
    }

    // MARK: 广播渲染

    /// 把 `[String: Any]` 的广播字典渲染成人能读的文本。
    ///
    /// ★ 厂商数据（`CBAdvertisementDataManufacturerDataKey`）值得单独盯：
    ///   很多 BLE 模组会把 MAC 塞在里面，那才是能跟 commonConfig 里
    ///   `mac: C8C83FF5C48E` 对上的东西。
    private func renderAdvertisement(_ adv: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]

        if let n = adv[CBAdvertisementDataLocalNameKey] as? String, !n.isEmpty {
            out["名称"] = n
        }
        if let svc = adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !svc.isEmpty {
            out["服务 UUID"] = svc.map { $0.uuidString }.joined(separator: ", ")
        }
        if let ov = adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID], !ov.isEmpty {
            out["溢出服务"] = ov.map { $0.uuidString }.joined(separator: ", ")
        }
        if let sol = adv[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID], !sol.isEmpty {
            out["请求服务"] = sol.map { $0.uuidString }.joined(separator: ", ")
        }
        if let md = adv[CBAdvertisementDataManufacturerDataKey] as? Data, !md.isEmpty {
            // 前两字节按惯例是公司标识（小端），后面是厂商自定义
            let company = md.count >= 2 ? UInt16(md[0]) | (UInt16(md[1]) << 8) : 0
            var s = LMBLEHex.string(md)
            if md.count >= 2 { s = "公司 0x\(String(format: "%04X", company)) | " + s }
            out["厂商数据"] = s
        }
        if let sd = adv[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], !sd.isEmpty {
            out["服务数据"] = sd.map { "\($0.key.uuidString): \(LMBLEHex.string($0.value))" }
                .sorted().joined(separator: " ; ")
        }
        if let tx = adv[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
            out["发射功率"] = "\(tx.intValue) dBm"
        }
        if let conn = adv[CBAdvertisementDataIsConnectable] as? NSNumber {
            out["可连接"] = conn.boolValue ? "是" : "否"
        }
        return out
    }

    private func looksLikeVehicle(name: String, adv: [String: Any]) -> Bool {
        let lower = name.lowercased()
        if LMBLEUUID.nameHints.contains(where: { lower.contains($0) }) { return true }
        if let svc = adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           svc.contains(where: { $0.uuidString.uppercased() == LMBLEUUID.service.uppercased() }) {
            return true
        }
        return false
    }

    private func upsert(peripheral p: CBPeripheral, adv: [String: Any], rssi: Int, connectable: Bool) {
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String)
            ?? p.name
            ?? "(无名)"
        let rendered = renderAdvertisement(adv)
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].rssi = rssi
            devices[i].name = name
            devices[i].advertisement = rendered
            devices[i].lastSeen = Date()
            devices[i].isConnectable = connectable
            devices[i].isLikelyVehicle = looksLikeVehicle(name: name, adv: adv)
        } else {
            devices.append(LMBLEDevice(
                peripheral: p,
                name: name,
                rssi: rssi,
                advertisement: rendered,
                isLikelyVehicle: looksLikeVehicle(name: name, adv: adv),
                lastSeen: Date(),
                isConnectable: connectable))
        }
    }

    private func rebuildServices(from p: CBPeripheral) {
        var out: [LMBLEService] = []
        for s in p.services ?? [] {
            var chars: [LMBLECharacteristic] = []
            for c in s.characteristics ?? [] {
                let pr = c.properties
                chars.append(LMBLECharacteristic(
                    uuid: c.uuid.uuidString,
                    props: LMBLECentral.labels(pr),
                    canWrite: pr.contains(.write),
                    canWriteNoResponse: pr.contains(.writeWithoutResponse),
                    canNotify: pr.contains(.notify) || pr.contains(.indicate),
                    isNotifying: c.isNotifying,
                    lastValue: c.value.map { LMBLEHex.string($0) }))
            }
            out.append(LMBLEService(uuid: s.uuid.uuidString,
                                    isPrimary: s.isPrimary,
                                    characteristics: chars))
        }
        services = out

        // 自动把「看起来能收通知」的特征挂上 —— 抓官方帧就靠这一步
        if let d = connected, let pp = peripherals[d.id] {
            var auto = 0
            for s in pp.services ?? [] {
                for c in s.characteristics ?? []
                where (c.properties.contains(.notify) || c.properties.contains(.indicate)) && !c.isNotifying {
                    pp.setNotifyValue(true, for: c)
                    subscribed.insert("\(s.uuid.uuidString)/\(c.uuid.uuidString)")
                    auto += 1
                }
            }
            if auto > 0 { append(.info, "自动订阅了 \(auto) 个可通知特征（抓帧用）") }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension LMBLECentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s: LMBLEState
        switch central.state {
        case .poweredOn:    s = .poweredOn
        case .poweredOff:   s = .poweredOff
        case .unauthorized:s = .unauthorized
        case .unsupported:  s = .unsupported
        case .resetting:    s = .resetting
        default:            s = .unknown
        }
        state = s
        append(.info, "蓝牙状态：\(s.rawValue)")
    }

    /// App 被系统回收后恢复。必须重新认领外设，否则恢复出来的 CBPeripheral
    /// 没有 delegate、也没人 retain，等于断了。
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let list = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        for p in list {
            peripherals[p.identifier] = p
            p.delegate = self
        }
        append(.info, "从后台恢复，重新认领 \(list.count) 个外设")
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // ★ 必须存！CBCentralManager 不 retain 外设，不存的话 connect 会静默失效
        peripherals[peripheral.identifier] = peripheral
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        upsert(peripheral: peripheral, adv: advertisementData, rssi: RSSI.intValue, connectable: connectable)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            connected = devices[i]
        }
        append(.info, "已连接 \(peripheral.name ?? peripheral.identifier.uuidString)")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        lastError = "连接失败：\(error?.localizedDescription ?? "未知原因")"
        append(.error, "连接失败 \(peripheral.name ?? "-")：\(error?.localizedDescription ?? "未知原因")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let name = connected?.name ?? peripheral.name ?? "-"
        if error != nil {
            append(.error, "意外断开 \(name)：\(error!.localizedDescription)")
            lastError = "连接断开：\(error!.localizedDescription)"
        } else {
            append(.info, "已断开 \(name)")
        }
        connected = nil
        services = []
        subscribed.removeAll()
    }
}

// MARK: - CBPeripheralDelegate

extension LMBLECentral: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error {
            append(.error, "发现服务失败：\(e.localizedDescription)")
            return
        }
        let n = peripheral.services?.count ?? 0
        append(.info, "发现 \(n) 个服务，继续发现特征…")
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
        if n == 0 {
            append(.error, "一个服务都没有 —— 车可能没在广播这个服务，或需要先配对")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let e = error {
            append(.error, "发现特征失败 \(service.uuid.uuidString)：\(e.localizedDescription)")
            return
        }
        rebuildServices(from: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            append(.error, "收值失败 \(characteristic.uuid.uuidString)：\(e.localizedDescription)")
            return
        }
        guard let v = characteristic.value else { return }
        append(.rx, "收 \(characteristic.uuid.uuidString)（\(v.count) 字节）", data: v)
        // 同步到 GATT 树，UI 上能直接看到最新值
        if let si = services.firstIndex(where: {
            $0.characteristics.contains { $0.uuid == characteristic.uuid.uuidString }
        }), let ci = services[si].characteristics.firstIndex(where: {
            $0.uuid == characteristic.uuid.uuidString
        }) {
            services[si].characteristics[ci].lastValue = LMBLEHex.string(v)
            services[si].characteristics[ci].isNotifying = characteristic.isNotifying
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            append(.error, "写入失败 \(characteristic.uuid.uuidString)：\(e.localizedDescription)")
            lastError = "写入失败：\(e.localizedDescription)"
        } else {
            append(.info, "写入已确认 \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            append(.error, "订阅失败 \(characteristic.uuid.uuidString)：\(e.localizedDescription)")
            return
        }
        append(.info, "\(characteristic.isNotifying ? "已订阅" : "已退订") \(characteristic.uuid.uuidString)")
        if let si = services.firstIndex(where: {
            $0.characteristics.contains { $0.uuid == characteristic.uuid.uuidString }
        }), let ci = services[si].characteristics.firstIndex(where: {
            $0.uuid == characteristic.uuid.uuidString
        }) {
            services[si].characteristics[ci].isNotifying = characteristic.isNotifying
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[i].rssi = RSSI.intValue
            devices[i].lastSeen = Date()
        }
        if connected?.id == peripheral.identifier {
            connected?.rssi = RSSI.intValue
        }
        append(.info, "RSSI \(RSSI.intValue) dBm")
    }
}
