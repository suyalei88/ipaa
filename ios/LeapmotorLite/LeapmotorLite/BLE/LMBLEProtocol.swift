//
//  LMBLEProtocol.swift
//  LeapmotorLite
//
//  蓝牙钥匙（BLE Key）协议知识库 —— 全部来自官方 IPA 主二进制的静态逆向
//
//  ═══════════════════════════════════════════════════════════════════════════
//  证据来源
//  ═══════════════════════════════════════════════════════════════════════════
//  样本：`零跑-1.22.68.ipa`
//        主二进制 `Payload/leapmotorCarOwner.app/leapmotorCarOwner`
//        204,405,920 bytes，未加密的 Mach-O（App Store 版，但字符串表完整）
//
//  Info.plist 里官方自己声明了这两条，直接确认了「蓝牙钥匙」的存在：
//        NSBluetoothAlwaysUsageDescription    = 用于蓝牙钥匙、自动泊车
//        NSBluetoothPeripheralUsageDescription = 用于蓝牙钥匙、自动泊车
//        UIBackgroundModes = [audio, bluetooth-central, bluetooth-peripheral, location]
//  （注意 `bluetooth-peripheral` —— 官方还把自己做成外设，说明有反向通道。）
//
//  ── 1. GATT 层（字符串表 @0xaa3039f / @0xaa303c4，同一块连续字符串池）────────
//        FFED0000-0000-1000-8000-00805F9B34FB    ← 服务（广播用）
//        FFED1234-0000-1000-8000-00805F9B34FB    ← 特征（读写/通知）
//        紧邻的短 id：FFF2、FAFA、FAFB、FFFE
//          · 这四个是 4 位十六进制 → CoreBluetooth 会展开成
//            0000FFF2-0000-1000-8000-00805F9B34FB 这种 SIG 基址形式。
//          · 它们和上面两个 128 位 UUID 混在同一块池子里，
//            说明协议里同时用了「自定义 128 位」和「16 位短 id」两套。
//        ★ 到底哪个是 service、哪个是 characteristic、哪些是 notify ——
//          静态看不出来。BLE 调试页的「GATT 树」会把真机上看到的原样列出来，
//          以那个为准，本文件里的猜测都带 🟡 标记。
//
//  ── 2. 认证握手（字段名，字符串池 @0xaa30427 起）──────────────────────────
//        tempPublicKey / tempPrivateKey      临时（一次性）密钥对
//        myPublicData                        本机公钥数据
//        ecdhPublicKey                       对端 ECDH 公钥
//        passwordCard                        密码卡（服务端下发的凭据）
//        keyType                             密钥类型
//        verifyTime / actionTime             校验时间 / 动作时间（防重放）
//        useToken / useGM                    ★ useGM = 走国密（SM2/SM3/SM4）分支
//        eccHandle                           ECC 句柄
//        AESData / encodeData                加密后的载荷
//        DecodeError / UnKnown               解密失败枚举
//      → 结论：**ECDH 临时密钥协商 + 对称加密（AES 或国密）+ 时间戳防重放**。
//        曲线候选（同一二进制里出现的常量）：
//            secp256r1 / prime256v1 / P-256   ← 最可能
//            secp256k1 / secp384r1 / secp521r1 / curve25519（备选）
//        相关实现符号：`secp256r1secp384r1secp521r1`、`kSecAttrKeyTypeEC`、`X9.62`。
//
//  ── 3. 帧格式（格式字符串，★ 这一条最有价值）─────────────────────────────
//        二进制里存在这三个 printf 模板：
//            "%@;%@;"
//            "%@;%@;%@;%ld;%ld;"
//            "%@;%@;%@;%ld;%ld;%ld;%ld;"
//      → **传输层是分号分隔的文本协议，不是纯二进制！**
//        形如 `字段A;字段B;` / `A;B;C;num1;num2;`
//        这跟「BLE 上跑 JSON/TLV」完全不是一回事，直接决定了调试页该怎么解析：
//        我们把每一帧同时按 hex、ASCII、分号切分三种方式展示。
//
//  ── 4. 指令 / 应答（字段名）──────────────────────────────────────────────
//        cmdId                               指令号
//        dataContent                         指令载荷
//        resultCode                          结果码
//        controllerReplyContent              控制器回包内容
//        RKEResponse                         ★ RKE = Remote Keyless Entry，遥控钥匙应答
//        currentCarStatus                    当前车况
//        error1 / error2                     错误码
//        sendAllYet / canBeSkippedLength     分包发送进度
//        相关符号：readPacket / writePacket / typePacket / specialPacket、
//                  multipleCommandsPendingException（指令队列满了）、
//                  bcmKeyPositionOn（BCM = 车身控制器，钥匙位置）、
//                  dynamicKeyEqualENSt（动态码比对状态）
//
//  ── 5. 三个开关（字符串池）──────────────────────────────────────────────
//        isAutoLock      靠近自动闭锁
//        isAutoUnLock    靠近自动解锁
//        isDoorUnLock    门把手解锁
//      → 官方存这三个的 UserDefaults key（同一池子里）：
//            LMVBLEAutoLockKey / LMVBLEAutoUnLockKey / LMVBLEDoorUnLockKey
//        另有：LMVBLEConfigManager / LMVBLEInsensibility（无感）
//
//  ── 6. 官方类栈（决定「要逆向哪些类才能自己实现」）──────────────────────
//        LMVBLEConnectManager / LMVBLEConnectInteractor / LMVBLEPeripheralInteractor
//        LMVBLERemoteControl          遥控
//        LMVBLEInsensibility          无感（靠近自动迎宾/解锁）
//        LMVBLEConfigManager          配置
//        LMVBluetoothDataManager / LMVBlueToothConnection / LMVBlueToothBuffer
//        LMVBlueToothDataHandler / LMVBluetoothCommandModel / LMVBluetoothKeyDataModel
//        LMVBluetoothCarInforModel / LMVBluetoothCarInforProtocol
//        LMVInsensibilityBluetoothService / LMVInsensibilityBluetoothProtocol
//        LMVBLEKeyModule*（一整套 MVVM：Page / LockType / Select / Switch / Tips）
//        LMVBLEKeySensingAreaRouter   感应区设置
//        LMVBleAutoPark*              蓝牙自动泊车（同一套 BLE 栈复用）
//        _SupconBlueToothConnection   ★ Supcon = 中控，车端 BLE 模组的供应商
//        队列/持久化：com.leapmotor.blekey_queue、com.lmv.bluetooth.buffer.serial
//
//  ── 7. 云端接口（这些是能直接调的，见 LMEndpoints.Path）──────────────────
//        /v3/api/ccc/pairingcode                        取 CCC 配对码
//        /v3/api/ccc/poll                               轮询配对结果
//        /v3/api/ccc/delKey                             删除钥匙
//        /v3/api/bluetoothkey/combine/syncBluetoothKeys 同步已绑定的钥匙
//        /v3/api/bluetoothkey/anchor/point/params/simplify
//        /v3/api/bluetoothkey/uploadRecords
//        /v3/api/bluetoothkey/uploadAutonomyCalibrateParams
//      （CCC = Car Connectivity Consortium 数字钥匙标准）
//
//  ═══════════════════════════════════════════════════════════════════════════
//  ⚠️ 还没拿到的东西（决定「能不能真的解锁」）
//  ═══════════════════════════════════════════════════════════════════════════
//   ① `passwordCard` 的实际内容 —— 服务端在配对后下发。本机 `commonConfig`
//      config["4"] 里只有 `{mac, version, updateTime}`，**不含密钥材料**。
//      要拿到得先调 `/v3/api/ccc/pairingcode` + `/v3/api/ccc/poll` 走完配对，
//      或看 `/v3/api/bluetoothkey/combine/syncBluetoothKeys` 回什么。
//   ② 帧里那三段 `%@` 和数字到底怎么排 —— 格式模板给了形状，没给语义。
//   ③ cmdId 表（哪个数字对应解锁/闭锁/寻车）。
//   ④ ECDH 用哪条曲线、共享密钥怎么 KDF 成 AES key、要不要 SM 分支。
//
//  → ①③④ 只能靠「官方 App 连车时的动态抓包」或继续反汇编那几个 LMVBLE* 类。
//    本文件配套的「BLE 调试」页就是为此准备的工具：
//    扫到车 → 抓广播 → 连上 → dump GATT → 订阅通知 → 记录官方 App 的每一帧。
//    有了真实帧，②③ 当天就能定下来。
//
import Foundation

// MARK: - UUID

/// 从官方二进制里挖出来的 BLE UUID。
///
/// 置信度：
///   ✅ 字面量确实在二进制里（`grep -a` 命中，见文件头证据）
///   🟡 「哪个是 service / 哪个是 characteristic」是推测
enum LMBLEUUID {

    /// 主服务 UUID。✅ 字面量存在，🟡 角色为推测。
    static let service = "FFED0000-0000-1000-8000-00805F9B34FB"

    /// 主特征 UUID。✅ 字面量存在，🟡 角色为推测。
    static let characteristic = "FFED1234-0000-1000-8000-00805F9B34FB"

    /// 同一字符串池里出现的 4 位短 id。
    ///
    /// 给 `CBUUID(string:)` 用的时候 CoreBluetooth 会自动补成
    /// `0000XXXX-0000-1000-8000-00805F9B34FB`，所以这里存短的就行。
    /// ❓ 各自是 service 还是 characteristic 完全未知，靠 GATT dump 定。
    static let shortIds = ["FFF2", "FAFA", "FAFB", "FFFE"]

    /// 扫描时用来过滤的 UUID 列表（先按主服务过滤，扫不到再放开全扫）。
    static let scanFilters = [service]

    /// 广播里可能出现的名字关键字（车端 BLE 模组是「中控 / Supcon」的）。
    /// ❓ 纯启发式，只用来在列表里打「疑似车辆」标记，不参与连接决策。
    static let nameHints = ["leapmotor", "lmv", "zero", "零跑", "supcon", "c11", "c10", "t03", "c16", "b10"]
}

// MARK: - 帧

/// 一帧 BLE 载荷的解析结果。
///
/// 官方用的是 `%@;%@;` / `%@;%@;%@;%ld;%ld;` 这类 **分号分隔文本** 模板
/// （见文件头证据 3），所以同一段字节有三种合理读法，全都摊出来给用户看：
///   · hex     —— 万一是二进制
///   · ascii   —— 文本协议时直接可读
///   · fields  —— 按 `;` 切分，末尾空段丢掉
struct LMBLEFrame {

    let raw: Data
    let at: Date

    var hex: String { LMBLEHex.string(raw) }

    /// 按 ASCII 读；含不可打印字符时返回 nil
    var ascii: String? {
        guard !raw.isEmpty else { return nil }
        for b in raw where b < 0x09 || (b > 0x0D && b < 0x20) || b > 0x7E { return nil }
        return String(data: raw, encoding: .ascii)
    }

    /// 按 `;` 切分。至少要有 2 段才算「像官方那个模板」，否则返回 nil。
    var fields: [String]? {
        guard let s = ascii else { return nil }
        let parts = s.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        // 模板都以 ';' 结尾 → 最后一段是空串，去掉
        var out = parts
        while out.last == "" { out.removeLast() }
        guard out.count >= 2 else { return nil }
        return out
    }

    /// 帧长度。官方有 `canBeSkippedLength` / `sendAllYet`，说明是分包传输，
    /// 所以长度本身就是个有用信息。
    var count: Int { raw.count }

    /// 给 UI 用的一行摘要
    var summary: String {
        if let f = fields {
            return "\(count)B · 分号帧 \(f.count) 段 · \(f.joined(separator: " | "))"
        }
        if let a = ascii {
            return "\(count)B · 文本 · \(a)"
        }
        return "\(count)B · 二进制"
    }
}

// MARK: - 十六进制工具

enum LMBLEHex {

    /// 大写、空格分隔，便于肉眼比对（如 `FF ED 12 34`）
    static func string(_ d: Data) -> String {
        d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// 紧凑无分隔（如 `FFED1234`）
    static func compact(_ d: Data) -> String {
        d.map { String(format: "%02X", $0) }.joined()
    }

    /// 解析用户输入的十六进制。容忍空格、换行、`0x` 前缀、逗号、冒号。
    ///
    /// 返回 nil 表示有非法字符或奇数个 hex 位 —— 调用方要把这两种情况分开提示，
    /// 否则用户敲错一个字符只会看到「发送失败」，不知道错在哪。
    static func data(from text: String) -> Data? {
        var cleaned = text.lowercased()
        for junk in ["0x", " ", "\n", "\t", ",", ":", "-", "\r"] {
            cleaned = cleaned.replacingOccurrences(of: junk, with: "")
        }
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count % 2 == 0 else { return nil }
        guard cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }

        var out = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    /// 校验输入并给出人能看懂的原因（诊断/调试页的错误提示用）
    static func validate(_ text: String) -> String? {
        var cleaned = text.lowercased()
        for junk in ["0x", " ", "\n", "\t", ",", ":", "-", "\r"] {
            cleaned = cleaned.replacingOccurrences(of: junk, with: "")
        }
        if cleaned.isEmpty { return "还没输入内容" }
        if let bad = cleaned.first(where: { !$0.isHexDigit }) {
            return "含非十六进制字符：`\(bad)`"
        }
        if cleaned.count % 2 != 0 { return "十六进制位数是奇数（\(cleaned.count)），每个字节要两位" }
        return nil
    }
}

// MARK: - 连接状态（可读化）

/// `CBManagerState` 的中文说明。
///
/// 为什么不直接 `String(describing:)`：`.unauthorized` 和 `.poweredOff` 在用户
/// 眼里都是「用不了」，但解法完全不同（一个去设置里开权限，一个去开蓝牙开关）。
enum LMBLEState: String {
    case unknown      = "未知（还没初始化完）"
    case resetting    = "正在重置"
    case unsupported  = "本机不支持 BLE（模拟器上一定是这个）"
    case unauthorized = "未授权 → 去「设置 → 隐私 → 蓝牙」打开"
    case poweredOff   = "蓝牙已关闭 → 去控制中心打开"
    case poweredOn    = "蓝牙已就绪"

    /// 能不能开始扫描
    var canUse: Bool { self == .poweredOn }

    /// 是不是「需要用户去动手」的状态（UI 里给更强的提示）
    var needsUserAction: Bool {
        self == .unauthorized || self == .poweredOff
    }
}

// MARK: - 待验证项清单（UI 里直接展示，告诉用户「还差什么」）

/// 一条「还没定下来」的协议细节。
///
/// 把它做成数据结构而不是写死在 View 里，是因为这份清单会随着真实抓包
/// 不断缩短 —— 改这里就行，不用动 UI。
struct LMBLEOpenQuestion: Identifiable {
    let id: String
    let question: String
    let howToSettle: String
    /// 用调试页的哪一步能搞定
    let tool: String
}

enum LMBLEQuestions {

    /// 挡住「真正能解锁」的四个问题（对应文件头 ⚠️ ①②③④）
    static let blocking: [LMBLEOpenQuestion] = [
        LMBLEOpenQuestion(
            id: "gatt",
            question: "FFED0000 / FFED1234 到底哪个是 service、哪个是 characteristic？FFF2 / FAFA / FAFB / FFFE 又是什么？",
            howToSettle: "连上车看 GATT 树，服务的 UUID 和每个特征的可读写/通知属性会原样列出来",
            tool: "① 扫描 → ② 连接 → ③ GATT 树"),

        LMBLEOpenQuestion(
            id: "passwordCard",
            question: "passwordCard（服务端下发的凭据）本机拿不到 —— commonConfig 里只有 mac + version",
            howToSettle: "走一遍 /v3/api/ccc/pairingcode + /poll，或看 /v3/api/bluetoothkey/combine/syncBluetoothKeys 返回什么",
            tool: "设置 → 诊断 → 蓝牙钥匙接口探针"),

        LMBLEOpenQuestion(
            id: "frame",
            question: "帧里 `%@;%@;` 那几段分别是什么？数字段是 cmdId 还是时间戳？",
            howToSettle: "用官方 App 连车操作一次，同时在本页订阅 FFED1234 的通知，把每一帧的 hex/ASCII/分号切分都记下来",
            tool: "④ 订阅通知 → ⑤ 操作官方 App → 看日志"),

        LMBLEOpenQuestion(
            id: "cmdTable",
            question: "cmdId 表：哪个数字对应解锁 / 闭锁 / 寻车 / 上电？",
            howToSettle: "同上，一次操作对应一帧，比对 cmdId 字段即可",
            tool: "同上（需要至少 2 组「操作 ↔ 帧」样本）"),

        LMBLEOpenQuestion(
            id: "crypto",
            question: "ECDH 用哪条曲线？共享密钥怎么 KDF 成 AES key？要不要走 useGM（国密）分支？",
            howToSettle: "继续反汇编 LMVBLEConnectManager / LMVBluetoothDataManager；或动态 hook 这几个类打印中间值",
            tool: "Frida（需要越狱机或官方 App 可注入）"),
    ]

    /// 已经确认的部分（给用户吃个定心丸，也让后续接手的人知道进度）
    static let settled: [String] = [
        "服务/特征 UUID 字面量（FFED0000 / FFED1234 + FFF2 / FAFA / FAFB / FFFE）",
        "认证是 ECDH 临时密钥协商 + 对称加密 + 时间戳防重放（tempPublicKey / ecdhPublicKey / verifyTime）",
        "载荷是分号分隔文本帧（`%@;%@;` 等三个模板）",
        "指令字段名（cmdId / dataContent / resultCode / RKEResponse / currentCarStatus / error1 / error2）",
        "三个开关（isAutoLock / isAutoUnLock / isDoorUnLock）",
        "七个云端接口路径",
        "车端 BLE 模组供应商是「中控 / Supcon」（_SupconBlueToothConnection）",
    ]
}
