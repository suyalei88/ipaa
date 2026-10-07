//
//  LMEndpoints.swift
//  LeapmotorLite
//
//  端点表 + cmdid 表（全部来自真实抓包 + iOS 主二进制）
//
import Foundation

enum LMEndpoints {

    // MARK: - Hosts

    /// 主网关（车控 / 车况）
    static let gateway      = "https://appgateway.leapmotor.com"
    /// 账号 / 登录 / 车辆列表网关
    static let accountHost  = "https://app-gw-global-master.leapmotor.com"
    /// 短信 / appuser 网关
    static let userHost     = "https://appuser.leapmotor.cn"

    // MARK: - Paths

    enum Path {
        // 登录
        static let sendSMS            = "/app-user/applogin/compliance/sendmessagecode"
        static let checkLoginWithPhone = "/app-user/applogin/check_login_with_phone"   // POST_Form
        static let login              = "/base/base-user/account/v1/login"             // 外层token换JWT
        static let refreshToken       = "/token/v1/refresh"
        static let logout             = "/account/v1/logout"

        // 车辆
        static let vehicleList    = "/app/app-global-service/v1/vehicle/list"
        static let carRoute       = "/app/app-global-service/v1/vehicle/getCarRoute"

        // 车况
        static let signalQuery    = "/app/app-signal-service/signal/info/query"
        static let signalDistributed = "/carownerservice/signal/info/query/distributed"

        // 车控
        static let remoteCtl      = "/app/app-control-service/v3/api/appremotectl"
        static let remoteCtlQuery = "/app/app-control-service/v3/api/appremotectl/query"

        // 杂项
        static let commonConfig   = "/carownerservice/v3/api/vehicleinfo/commonConfig"
        static let mileage        = "/carownerservice/v3/api/drivingrecord/mileage/energy/detail"
        static let chassis        = "/carownerservice/v3/api/chassis/query"

        /// 停车位置查询。
        ///
        /// ⚠️ 从 IPA 字符串表挖出来的（`evidence/ios_endpoints.txt:258`），
        ///    路径前缀 `/carownerservice` 是照 `commonConfig` 的实测全路径推的
        ///    （字符串表里只有 `/v3/api/vehicleinfo/parking/query`，
        ///      服务名前缀是运行时拼的）。**没有抓包样本，响应结构未知。**
        ///    所以调用方必须容忍失败：坐标优先用 signalMap 的 2190/2191。
        static let parking        = "/carownerservice/v3/api/vehicleinfo/parking/query"

        /// 官方逆地理编码（经纬度 → 地址）。
        ///
        /// ⚠️ 同样只有字符串表里的 `/v3/geocode/regeo`，**参数与响应都未验证**。
        ///    App 里默认走 Apple 的 CLGeocoder，这个只在「诊断」页做探测用。
        static let regeo         = "/carownerservice/v3/geocode/regeo"

        // MARK: 蓝牙钥匙 / 数字钥匙
        //
        // ⚠️⚠️ 下面这一组**全部只有路径、没有抓包样本**。
        //   来源：官方 IPA 主二进制（`零跑-1.22.68.ipa`，204 MB 未加密 Mach-O）
        //         的字符串表，`grep -aoE "/v3/api/[a-zA-Z0-9/_.-]+"` 直接命中。
        //   响应结构、参数、甚至 HTTP 方法都**未知**。
        //   所以：
        //     · 一律只做「探测」，把原始响应留给人看，绝不解析成强类型；
        //     · 前缀不确定 → 用 `pathPrefixes` 逐个试（见下面的说明）；
        //     · 探测失败是常态，不能污染 lastError，更不能让页面崩。

        /// 取 CCC 配对码。CCC = Car Connectivity Consortium 数字钥匙标准。
        static let cccPairingCode = "/v3/api/ccc/pairingcode"
        /// 轮询配对结果（配对码是异步的，官方也是轮询）
        static let cccPoll        = "/v3/api/ccc/poll"
        /// 删除已绑定的钥匙
        static let cccDelKey      = "/v3/api/ccc/delKey"

        /// 同步已绑定的蓝牙钥匙。
        ///
        /// ★ 这个是最有价值的探测目标：如果服务端在这里把钥匙材料
        ///   （`passwordCard`）吐回来，BLE 协议就能自己实现了。
        static let bleKeySync     = "/v3/api/bluetoothkey/combine/syncBluetoothKeys"
        /// 感应区锚点参数（「无感」功能的标定数据）
        static let bleKeyAnchor   = "/v3/api/bluetoothkey/anchor/point/params/simplify"
        /// 上传蓝牙钥匙使用记录
        static let bleKeyRecords  = "/v3/api/bluetoothkey/uploadRecords"
        /// 上传自动标定参数（`LMVBlueToothCalibrationModel` 用）
        static let bleKeyCalib    = "/v3/api/bluetoothkey/uploadAutonomyCalibrateParams"
    }

    /// `/v3/api/...` 这几个路径在二进制里**不带服务名前缀**，前缀是运行时拼的。
    ///
    /// 已知的反例可以反推：字符串表里是 `/v3/api/vehicleinfo/commonConfig`，
    /// 而实测全路径是 `/carownerservice/v3/api/vehicleinfo/commonConfig` ——
    /// 所以 `carownerservice` 是首选前缀。
    /// 但车控接口用的是 `/app/app-control-service` 前缀，CCC 那三个
    /// （pairingcode / poll / delKey）语义上更像车控，也可能挂在那里。
    /// 干脆三个都试，把「哪个前缀 200」这个事实本身当成探测结果。
    static let pathPrefixes: [String] = [
        "/carownerservice",
        "/app/app-control-service",
        "",
    ]

    /// 把一个裸路径按候选前缀展开成全路径（诊断页展示用）
    static func fullPaths(_ bare: String) -> [String] {
        pathPrefixes.map { $0 + bare }
    }

    // MARK: - 车控命令

    /// 一个车控动作
    struct Command {
        let cmdid: Int
        let state: [String: Any]
        let title: String
        let systemImage: String
        /// 分组（UI 用）
        let group: Group
        /// 危险等级：动车门/后备箱的属于「会动物理世界」，UI 里给更强的二次确认文案
        let risk: Risk

        enum Group: String, CaseIterable {
            case lock    = "门锁 / 后备箱"
            case climate = "空调"
            case light   = "灯光"
            case power   = "电源"
        }

        enum Risk: Equatable {
            /// 只改状态，不会夹到人
            case low
            /// 会开合车门/后备箱/启动上电 —— 必须提示「周围安全」
            case physical
        }
    }

    /// cmdid 表（实测）
    ///   110 车门锁   {"value":"lock"|"unlock"}     ✅ 确认
    ///   120 后备箱   {"value":"true"}              🟡 观察（早期抓包注释里也写过「寻车」）
    ///   170 大灯     {"operate":"off"|"auto"}      🟡 观察
    ///   230 空调     {"value":"0"|"2"|"5"}         🟡 观察
    ///   400 上电     {"operation":"on"}            ✅ 确认
    ///
    /// ⚠️ 已知但**故意不放进 UI** 的：`130 {"value":"true"|"false"}`。
    ///    它在抓包里出现过，但没有任何证据说明它开关的是什么 ——
    ///    对一台真车下发「不知道干什么」的指令是不负责任的。
    ///    要试的话去「设置 → 诊断 → 未验证 cmdid 探测」，那里有手输 + 二次确认。
    static let commands: [String: Command] = [
        "lock":       Command(cmdid: 110, state: ["value": "lock"],   title: "锁车",
                              systemImage: "lock.fill",               group: .lock, risk: .physical),
        "unlock":     Command(cmdid: 110, state: ["value": "unlock"], title: "解锁",
                              systemImage: "lock.open.fill",          group: .lock, risk: .physical),
        "trunk":      Command(cmdid: 120, state: ["value": "true"],   title: "后备箱",
                              systemImage: "car.rear.and.tire.marks", group: .lock, risk: .physical),
        "light_off":  Command(cmdid: 170, state: ["operate": "off"],  title: "大灯关",
                              systemImage: "lightbulb.slash",         group: .light, risk: .low),
        "light_auto": Command(cmdid: 170, state: ["operate": "auto"], title: "大灯自动",
                              systemImage: "lightbulb",               group: .light, risk: .low),
        "hvac_off":   Command(cmdid: 230, state: ["value": "0"],      title: "空调关",
                              systemImage: "fanblades.slash",         group: .climate, risk: .low),
        "hvac_low":   Command(cmdid: 230, state: ["value": "2"],      title: "空调低",
                              systemImage: "fanblades",               group: .climate, risk: .low),
        "hvac_high":  Command(cmdid: 230, state: ["value": "5"],      title: "空调高",
                              systemImage: "fanblades.fill",          group: .climate, risk: .low),
        "hello":      Command(cmdid: 400, state: ["operation": "on"], title: "上电",
                              systemImage: "power",                   group: .power, risk: .physical),
    ]

    /// 首页展示的动作（顺序即 UI 顺序）
    static let quickActions: [String] = [
        "lock", "unlock", "trunk", "hvac_off", "hvac_low", "hvac_high",
        "light_off", "light_auto", "hello",
    ]

    /// 首页「常用」那一排（只放最高频的四个）
    static let primaryActions: [String] = ["lock", "unlock", "trunk", "hvac_low"]

    /// 按分组返回动作 key（保持 commands 的声明顺序）
    static func actions(in group: Command.Group) -> [String] {
        quickActions.filter { commands[$0]?.group == group }
    }

    /// 记录在案但语义未确认的 cmdid —— **只给诊断页的探测工具用**
    ///
    /// ★ 用结构体而不是元组数组：`ForEach(_, id:)` 需要 key path，
    ///   而 Swift 的 key path 不能指向元组成员（`\.cmdid` 直接编译不过）。
    ///   同一个 cmdid 可能有多条 state，所以 id 用 "cmdid-state" 拼。
    struct UnverifiedCmd: Identifiable {
        let cmdid: Int
        let state: String
        let note: String
        var id: String { "\(cmdid)-\(state)" }
    }

    static let unverifiedCmds: [UnverifiedCmd] = [
        UnverifiedCmd(cmdid: 130, state: #"{"value":"true"}"#,
                      note: "开关类，但开关的是什么完全未知"),
        UnverifiedCmd(cmdid: 130, state: #"{"value":"false"}"#,
                      note: "同上，反向"),
    ]
}
