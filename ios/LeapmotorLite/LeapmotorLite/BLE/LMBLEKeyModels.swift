//
//  LMBLEKeyModels.swift
//  LeapmotorLite
//
//  蓝牙钥匙的「非 BLE 部分」：云端钥匙记录、本机开关、接口探测结果。
//
//  为什么单独一个文件：BLE 层（LMBLECentral）只管无线电，云端的钥匙记录和
//  用户开关跟无线电没关系，混在一起会让那个文件既连蓝牙又发 HTTP。
//
import Foundation

// MARK: - 云端钥匙记录

/// 已绑定的蓝牙钥匙记录，来自 `commonConfig.config["4"]`。
///
/// 实测样本（2026-10-07 抓包）：
/// ```json
/// "4": { "mac": "C8C83FF5C48E", "version": "2.0", "updateTime": "2026-09-20 11:02:29" }
/// ```
///
/// ★ 这里**没有密钥材料**。`mac` 是车端记录的「哪把钥匙」，`version` 是协议版本。
///   真正用来加密的 `passwordCard` 不在这个接口里 —— 见 LMBLEProtocol.swift
///   文件头「还没拿到的东西 ①」。
///
/// ★ `mac` 跟我们这边的 `CBPeripheral.identifier` **对不上**：
///   iOS 从 iOS 7 起就不把 MAC 给 App 了，两台手机上同一个外设拿到的
///   identifier 也不同。所以别想着拿这个 mac 去匹配扫描结果。
struct LMBLEKeyRecord: Identifiable {

    let mac: String
    let version: String?
    let updateTime: String?

    var id: String { mac }

    /// mac 是 12 位十六进制（6 字节），按 `C8:C8:3F:F5:C4:8E` 排版好看点
    var macPretty: String {
        let clean = mac.uppercased().filter { $0.isHexDigit }
        guard clean.count == 12 else { return mac }
        return stride(from: 0, to: 12, by: 2)
            .map { String(Array(clean)[$0..<$0 + 2]) }
            .joined(separator: ":")
    }

    /// 协议版本。`2.0` 是实测值。
    var versionText: String { version ?? "--" }

    /// 从 `LMConfigBlob`（config["4"]）构造。
    ///
    /// `mac` 为空就返回 nil —— 那说明这台车**没绑过**蓝牙钥匙，
    /// 而不是「绑定信息读取失败」，UI 上要区分开。
    init?(blob: LMConfigBlob?) {
        guard let b = blob, let m = b.mac, !m.isEmpty else { return nil }
        mac = m
        version = b.version
        updateTime = b.updateTime
    }

    /// 直接给测试用
    init(mac: String, version: String?, updateTime: String?) {
        self.mac = mac
        self.version = version
        self.updateTime = updateTime
    }
}

// MARK: - 本机开关

/// 蓝牙钥匙的三个行为开关。
///
/// ★ 官方那三个开关存在官方 App 的 UserDefaults 里，key 是（从二进制字符串池挖的）：
///       LMVBLEAutoLockKey      → isAutoLock     靠近自动闭锁
///       LMVBLEAutoUnLockKey    → isAutoUnLock   靠近自动解锁
///       LMVBLEDoorUnLockKey    → isDoorUnLock   门把手解锁
///
/// ★ 本 App 用**自己的** key（加 `lm3rd.` 前缀）。原因：
///   ① 两个 App 沙盒本来就隔离，用同名 key 没有任何好处；
///   ② 这几个开关在官方那边是跟「配对后的钥匙」绑定的，我们这边还没有可用的
///      钥匙，写了也不会真的生效 —— 用了同名 key 反而让人误以为改了官方设置。
///   所以 UI 上必须写清「本机记录，不影响官方 App」。
///
/// 等 BLE 协议打通、真能自己解锁了，这三个开关才会接上真正的行为。
///
/// ★ 加 `Equatable` 是为了视图里能 `.onChange(of: prefs)` 整体监听 ——
///   三个 Bool 的合成实现是免费的。不这样的话就得写三个 onChange，
///   漏一个那个开关就不落盘。
struct LMBLEKeyPrefs: Equatable {

    /// 靠近自动解锁
    var autoUnlock: Bool
    /// 远离自动闭锁
    var autoLock: Bool
    /// 门把手解锁
    var doorUnlock: Bool

    private static let kAutoUnlock = "lm3rd.ble.autoUnlock"
    private static let kAutoLock   = "lm3rd.ble.autoLock"
    private static let kDoorUnlock = "lm3rd.ble.doorUnlock"

    init(autoUnlock: Bool, autoLock: Bool, doorUnlock: Bool) {
        self.autoUnlock = autoUnlock
        self.autoLock = autoLock
        self.doorUnlock = doorUnlock
    }

    static func load() -> LMBLEKeyPrefs {
        let d = UserDefaults.standard
        return LMBLEKeyPrefs(
            autoUnlock: d.bool(forKey: kAutoUnlock),
            autoLock:   d.bool(forKey: kAutoLock),
            doorUnlock: d.bool(forKey: kDoorUnlock))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(autoUnlock, forKey: LMBLEKeyPrefs.kAutoUnlock)
        d.set(autoLock,   forKey: LMBLEKeyPrefs.kAutoLock)
        d.set(doorUnlock, forKey: LMBLEKeyPrefs.kDoorUnlock)
    }

    /// 官方 App 里对应的文案（从二进制里挖出来的原话，用来说明这些开关干什么）
    static let featureDescription =
        "靠近车辆可自动迎宾、感应解锁、远离车辆自动闭锁、进入车内可启动车辆"

    /// 每个开关对应的官方 UserDefaults key，UI 里当副标题展示（可追溯）
    static let officialKeys = [
        ("autoLock",   "LMVBLEAutoLockKey"),
        ("autoUnlock", "LMVBLEAutoUnLockKey"),
        ("doorUnlock", "LMVBLEDoorUnLockKey"),
    ]
}

// MARK: - 接口探测结果

/// 一次蓝牙钥匙相关接口的探测结果。
///
/// 这些端点的**响应结构全部未知**（路径是从二进制字符串表挖的，没有抓包样本），
/// 所以不解成强类型，原样留着文本。探测失败也是有效信息。
struct LMBLEProbeResult: Identifiable {

    let id = UUID()
    let at: Date
    let title: String
    let path: String
    /// 请求参数（展示用）
    let request: String
    /// 响应原文（格式化 JSON）或 `✗ 失败原因`
    let response: String
    let ok: Bool

    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: at)
    }
}

// MARK: - 调试页的快捷载荷

/// 调试页「快捷发送」的一个预设。
///
/// ⚠️ 这些**不是**已知的有效指令，官方帧语义还没定（见 LMBLEProtocol 文件头）。
///    它们只用来验证「写入通路 + 分包 + 应答」是不是通的。
///    真正的指令要等拿到官方帧之后才能确定。
struct LMBLEPreset: Identifiable {

    let id: String
    let label: String
    let hex: String
    let note: String

    static let all: [LMBLEPreset] = [
        LMBLEPreset(id: "one",  label: "单字节 FF",
                    hex: "FF",
                    note: "最小的写测试：能确认特征可写、通路通"),
        LMBLEPreset(id: "zero", label: "4 字节 00",
                    hex: "00 00 00 00",
                    note: "看车机是否会回包（回包说明有请求/应答机制）"),
        LMBLEPreset(id: "semi", label: "单个分号 ;",
                    hex: "3B",
                    note: "官方帧模板以分号结尾（`%@;%@;`），试试单发一个分号"),
        LMBLEPreset(id: "empty", label: "空帧 ;;;;",
                    hex: "3B 3B 3B 3B",
                    note: "模板 `%@;%@;%@;%ld;%ld;` 的骨架，字段全空"),
    ]
}

// MARK: - 快速自检用的样本

/// 单元自检用的样本，跟 SelfTestView 的风格一致。
enum LMBLEKeySelfCheck {

    /// 用真实解码路径造一个 `LMConfigBlob`。
    ///
    /// ★ 刻意**不**用 memberwise init：`LMConfigBlob` 的字段全是 `let` + Optional，
    ///   Swift 只保证 `var` Optional 属性在 memberwise init 里有默认 nil，
    ///   `let` 的不保证 —— 那种写法能不能过编译得赌，本地又没有 swiftc 可验。
    ///   走 `JSONDecoder` 既没这个风险，又顺带测了真正的解析路径。
    private static func blob(_ json: String) -> LMConfigBlob? {
        try? JSONDecoder().decode(LMConfigBlob.self, from: Data(json.utf8))
    }

    /// ★ 返回结构体数组而不是 `[(String, Bool, String)]`：
    ///   视图里 `ForEach(results, id: \.0)` 是**元组 key path**，
    ///   Swift 的 key path 不能指向元组成员，直接编译不过。
    ///   （本会话在 `LMSignalCatalog.grouped()` 和 `LMEndpoints.unverifiedCmds`
    ///     上已经踩过两次，这是第三次改法。）
    static func run() -> [LMBLEKeyCheck] {
        var out: [LMBLEKeyCheck] = []

        func add(_ name: String, _ passed: Bool, _ detail: String) {
            out.append(LMBLEKeyCheck(id: name, name: name, passed: passed, detail: detail))
        }

        // 1. mac 排版
        let rec = LMBLEKeyRecord(mac: "C8C83FF5C48E", version: "2.0", updateTime: nil)
        add("mac 排版", rec.macPretty == "C8:C8:3F:F5:C4:8E", rec.macPretty)

        // 2. 空 mac 必须返回 nil（区分「没绑过」和「读取失败」）
        let empty = LMBLEKeyRecord(blob: blob(#"{"mac":"","version":"2.0"}"#))
        add("空 mac → nil", empty == nil, empty == nil ? "正确" : "错误地造出了记录")

        // 3. 缺 mac 字段也必须返回 nil
        let missing = LMBLEKeyRecord(blob: blob(#"{"version":"2.0"}"#))
        add("缺 mac → nil", missing == nil, missing == nil ? "正确" : "错误地造出了记录")

        // 4. 从真实的 config["4"] 样本构造
        let fromBlob = LMBLEKeyRecord(blob: blob(
            #"{"mac":"C8C83FF5C48E","version":"2.0","updateTime":"2026-09-20 11:02:29"}"#))
        add("从 config[\"4\"] 样本构造",
            fromBlob?.mac == "C8C83FF5C48E" && fromBlob?.versionText == "2.0",
            "\(fromBlob?.mac ?? "nil") / \(fromBlob?.versionText ?? "nil")")

        // 5. hex 解析：容忍各种分隔
        let variants = ["FFED1234", "ff ed 12 34", "0xFF-ED:12,34", "FFED 1234"]
        add("hex 解析容忍分隔符",
            variants.allSatisfy { LMBLEHex.data(from: $0)?.count == 4 },
            variants.map { "\($0) → \(LMBLEHex.data(from: $0)?.count ?? -1)B" }
                .joined(separator: " · "))

        // 6. 奇数位必须被拒
        add("奇数 hex 位被拒", LMBLEHex.validate("FFE") != nil,
            LMBLEHex.validate("FFE") ?? "没拦住")

        // 7. 非法字符必须被拒
        add("非法 hex 字符被拒", LMBLEHex.validate("FFGG") != nil,
            LMBLEHex.validate("FFGG") ?? "没拦住")

        // 8. 分号帧切分：`%@;%@;` → 2 段（末尾空段丢掉）
        let f1 = LMBLEFrame(raw: Data("abc;def;".utf8), at: Date())
        add("分号帧 `%@;%@;` → 2 段", f1.fields?.count == 2,
            (f1.fields ?? []).joined(separator: " | "))

        // 9. 分号帧切分：3 文本 + 2 数字 → 5 段
        let f2 = LMBLEFrame(raw: Data("a;b;c;12;34;".utf8), at: Date())
        add("分号帧 `%@;%@;%@;%ld;%ld;` → 5 段", f2.fields?.count == 5,
            (f2.fields ?? []).joined(separator: " | "))

        // 10. 纯二进制帧不该被当成分号帧
        let f3 = LMBLEFrame(raw: Data([0xFF, 0x00, 0x3B]), at: Date())
        add("二进制帧不误判为文本帧", f3.fields == nil && f3.ascii == nil, f3.summary)

        // 11. 单个分号 `;` 去掉尾部空段后只剩 0 段 → 不算帧（避免把心跳当数据）
        let f4 = LMBLEFrame(raw: Data(";".utf8), at: Date())
        add("单个分号不算帧", f4.fields == nil, f4.summary)

        return out
    }
}

/// 一条自检结果。
///
/// 单独建类型而不是用元组 —— 见 `LMBLEKeySelfCheck.run()` 的注释。
struct LMBLEKeyCheck: Identifiable {
    let id: String
    let name: String
    let passed: Bool
    let detail: String
}
