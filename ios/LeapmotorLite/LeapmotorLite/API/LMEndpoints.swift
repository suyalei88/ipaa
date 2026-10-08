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

    // ★ 2026-10-08 抓包审计补上：下面两个 host 在抓包里都真实出现过，
    //   而且 `request(host:)` 本来就支持任意 host，所以接进来零成本。

    /// 技术支撑网关。实测只有一个接口：手机侧 IP 归属地。
    ///
    /// ★ 这个接口对排查「车在淮南、App 显示合肥」有直接价值：
    ///   它返回的是**服务端认为手机在哪**，跟车端坐标是两个独立来源。
    ///   实测 `{"province":"安徽","city":"淮南"}` —— 手机侧是对的，
    ///   问题因此可以确定在车端 / 车端坐标，而不是我们的请求。
    static let tecHost      = "https://apptec.leapmotor.cn"

    /// 消息中心（未读数）。
    ///
    /// ⚠️ 注意它的响应**只有 `result` 没有 `code`**，跟主网关不一样。
    static let msgCenterHost = "https://msgcenter.leapmotor.cn"

    // ⚠️ 已发现但**没有接进来**的 host（记录在此，避免以后重复挖）：
    //   · `mqtt-center.leapmotor.cn`  `GET /mqtt/token/applyToken`
    //       → 返回 MQTT 长连接 token（`expireTimeConfig: 86400000`）。
    //         要用它得先实现一个 MQTT 客户端，属于「推送通道」而不是「车控功能」，
    //         本轮不做。车况刷新仍然走 HTTP 轮询。
    //   · `iov-api.leapmotor.com`  `POST /file/1.0/vehicle/pointData?dataName=…`
    //       → 这是**官方 App 自己往上报遥测日志**（protobuf → base64），
    //         不是给客户端用的读接口，无法反向当数据源。
    //   · `app-gw-global-master.leapmotor.com` 的
    //       `commoninfo/transparent/conf`、`bluetoothkey/anchor/point/params/simplify`
    //       → 后者已在 BLE 探测组里。

    // MARK: - Paths

    enum Path {
        // 登录
        static let sendSMS            = "/app-user/applogin/compliance/sendmessagecode"
        static let checkLoginWithPhone = "/app-user/applogin/check_login_with_phone"   // POST_Form
        static let login              = "/base/base-user/account/v1/login"             // 外层token换JWT
        static let logout             = "/base/base-user/account/v1/logout"

        /// 登录态续期。**这是官方 App「验证码登录一次就一直不退出」的关键接口。**
        ///
        /// ★ 2026-10-08 逆向自官方主二进制，不是猜的：
        ///   · 主二进制 `__TEXT,__cstring` 里路径表只有裸的 `/token/v1/refresh`（@0xAA33226），
        ///     服务名前缀是运行时拼的 —— 同一张表里就是 `@"/base/base-user"`（@0xAA33D8E）
        ///     与 `@"/account/v1/login"`（@0xAA33E05）相邻，所以前缀同 login。
        ///   · 调用点：函数 @0x106E8115C
        ///       add x3, x3, #0x9c0  ; @"/token/v1/refresh"
        ///       add x3, x3, #0x8c0  ; @"refreshToken"  → setObject:forKey:
        ///       add x4, x4, #0x960  ; @"POST_Json"     → JSON POST，超时 20s
        ///   · host 与 login 同源 = app-gw-global-master.leapmotor.com
        static let refreshToken       = "/base/base-user/token/v1/refresh"

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

        /// 停车位置查询。
        ///
        /// ⚠️ 从 IPA 字符串表挖出来的（`evidence/ios_endpoints.txt:258`），
        ///    路径前缀 `/carownerservice` 是照 `commonConfig` 的实测全路径推的
        ///    （字符串表里只有 `/v3/api/vehicleinfo/parking/query`，
        ///      服务名前缀是运行时拼的）。**没有抓包样本，响应结构未知。**
        ///    所以调用方必须容忍失败：坐标优先用 signalMap 的 2190/2191。
        static let parking        = "/carownerservice/v3/api/vehicleinfo/parking/query"

        /// 车辆底盘图（3D 车图 / 底盘照片）。
        ///
        /// ★★ 2026-10-08 **已用真实抓包证实，它不是定位接口**：
        ///    `appgateway.leapmotor.com_2026_10_07_13_25_47.har` 里有一次真实调用 ——
        ///      GET /carownerservice/v3/api/chassis/query?vin=LFZ63AA15TH035113
        ///    响应只有：
        ///      {"code":0,"result":0,"message":"请求成功","data":{
        ///         "fileUrl":"http://lp-carnet.oss-cn-hangzhou.aliyuncs.com/ChassisPicture/prod/<VIN>?...",
        ///         "uploadTime":1791344811823}}
        ///    即返回一张 OSS 上的**底盘图片**。之前「官方『车辆位置』页疑似用它」的猜测**被证伪**。
        static let chassis        = "/carownerservice/v3/api/chassis/query"

        /// 官方逆地理编码（经纬度 → 地址）。
        ///
        /// ⚠️ 同样只有字符串表里的 `/v3/geocode/regeo`，**参数与响应都未验证**。
        ///    App 里默认走 Apple 的 CLGeocoder，这个只在「诊断」页做探测用。
        static let regeo         = "/carownerservice/v3/geocode/regeo"

        // MARK: 车辆档案 / 杂项（★ 2026-10-08 抓包审计补上）
        //
        // 下面这一组**全部有真实抓包样本**（`appgateway…13_25_47.har` /
        // `…15_30_32.har`），路径、参数、响应结构都已在 LMModels.swift 里
        // 按实测字段建好类型。跟上面那组「只有路径没样本」的探测接口不同，
        // 这些是可以放心调用的。

        /// 3D 车模钥匙。
        ///
        /// 实测：`GET ?osVersion=26.4.1&vin=…`（`osVersion` 是必带参数）
        /// → 返回 `modelParam.carTypeCode`（精确版型 "720智尊版 六座"）
        ///   和 `shareBindUrl`（官方 3D 分享页）。
        static let car3dKey       = "/carownerservice/v3/api/carpicture/3d/key"

        /// 车机固件版本 + 最近一次 OTA 的完整更新日志。
        /// 实测：`GET ?vin=…` → `{versionNo, logContent, updateTime}`
        static let fotaVersion    = "/carownerservice/v3/api/fota/getCurrentVersion"

        /// 模块示意图（胎压 / 直进直出 / 辅助泊车 …），返回 OSS 图片 URL。
        /// 实测：`GET ?vin=…`
        static let appImage       = "/carownerservice/v3/api/appImage/getAppImage"

        /// 服务端下发的功能开关表（无感蓝牙、雷达、3D 主题 …）。
        /// 实测：`GET ?manufacture=…&osType=iOS&osVersion=…&sdkVersion=…&vin=…`
        static let bgConf         = "/carownerservice/v3/api/commoninfo/getBgConf"

        /// 健康充电推送开关查询。
        /// 实测：`POST`（form: `carvin` + `deviceId`）→ `{"data":{"isPush":false}}`
        static let healthyChargingPush = "/carownerservice/v3/api/healthyCharging/queryPushState"

        /// 远程预约查询。
        ///
        /// ⚠️ 注意前缀是 `/carownerservice/v3/api/`，**不是**车控 POST 用的
        ///    `/app/app-control-service/v3/api/` —— 同一个 `appremotectl` 名字，
        ///    两套前缀，别搞混。
        /// 实测：`GET ?carvin=…&cmdid=161` → `{"result":0,"code":0,"data":""}`
        ///    （`data` 是空串，说明这台车当前没有预约项。响应结构因此未知。）
        static let appointment    = "/carownerservice/v3/api/appremotectl/getappointment"

        /// 车辆分享列表（谁被授权用这台车、能用哪些 cmdid）。
        /// 实测：`GET ?vin=…` → `carShareInfoList[].rightList`（29 个 cmdid）
        static let shareList      = "/carownerservice/v3/api/sharecar/getShareVehicleListByVin"

        /// 手机侧 IP 归属地（挂在 `tecHost` 上）。
        ///
        /// 实测：`GET`（无参数）→ `{"data":{"country":"中国","province":"安徽","city":"淮南"}}`
        /// ⚠️ 响应字段是 `errorCode` 而**不是** `code`。
        static let ipAddress      = "/ipAnalysis/getAddressByIp"

        /// 消息未读数（挂在 `msgCenterHost` 上）。
        /// 实测：`GET ?begintime=…&endtime=…` → `{total, unread, alreadyread, usertotal, devicetotal}`
        static let noticeCount    = "/msgcenter/v1/noticemsg/selectmsgcount"

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
            case lock    = "门锁"
            case trunk   = "后备箱 / 寻车"
            case window  = "车窗"
            case climate = "空调"
            case power   = "电源"
        }

        enum Risk: Equatable {
            /// 只改状态，不会夹到人
            case low
            /// 会开合车门/后备箱/启动上电 —— 必须提示「周围安全」
            case physical
        }
    }

    /// cmdid 表（★ 2026-10-08 第二次修正，之前那张表是错的）
    ///
    /// ── 修正前的错误（务必记住这个教训）──────────────────────────
    ///   旧表把 `170` 当「大灯」、`230` 当「空调」，还按 `{"value":"0"|"2"|"5"}`
    ///   做了一张「空调风量 1~9 档」卡。**全是错的**：
    ///   往 230 发 `{"value":"3"}` 实际会去开车窗，不是调风量。
    ///
    /// ── 修正依据（三重证据，互相印证）────────────────────────────
    ///   ① 官方 RN bundle `index.jsbundle` 明文常量：
    ///        quickActions   = [{unlock:110},{trunk:130},{horn:120},{ac:170},{windows:230}]
    ///        signalMappings = {unlock:1298, trunk:1281, windows:1693, ac:1938}
    ///   ② 抓包双向验证（111 个信号快照）：
    ///        cmdid 110 {"value":"lock"}   → 1298 0→1        （门锁翻转）
    ///        cmdid 230 {"value":"2"}      → 1693~1696 0→2   （★ 四个车窗一起动）
    ///        cmdid 230 {"value":"0"}      → 1693~1696 2→0
    ///        cmdid 170 {"operate":"auto"} → 1938 0→1        （空调翻转）
    ///   ③ 官方 IPA 主二进制（204MB 未加密 Mach-O）的字段表：
    ///        `cmdid carvin oppwd controlSource` + `operate` `manual` `temperature`
    ///        `windlevel` `operation` `off` `hotcold` `nohotcold` `circle`
    ///      → 空调（170）的 payload 键就是 `temperature` / `windlevel` / `operate`
    ///
    /// ── 最终表 ───────────────────────────────────────────────────
    ///   110 车门锁   {"value":"lock"|"unlock"}                  ✅ 抓包双向
    ///   120 鸣笛寻车 {"value":"true"}                           ✅ bundle + 抓包
    ///   130 后备箱   {"value":"true"|"false"}                   ✅ 抓包双向
    ///   170 空调     {"operate":"auto"|"off"}                   ✅ 抓包双向
    ///                {"operate":"manual","windlevel":N,"temperature":T}  🟡 键有证据、组合无样本
    ///   230 车窗     {"value":"0"|"2"|"5"}                       ✅ 抓包（0=关，2/5=两个开度）
    ///   400 上电     {"operation":"on"}                          ✅ 抓包
    ///
    /// ⚠️ 已知但**故意不放进 UI** 的：`cmdid 130` 之外的兄弟码无 payload 证据，
    ///    对一台真车下发「不知道干什么」的指令是不负责任的。
    static let commands: [String: Command] = [
        "lock":         Command(cmdid: 110, state: ["value": "lock"],   title: "上锁",
                                systemImage: "lock.fill",               group: .lock, risk: .physical),
        "unlock":       Command(cmdid: 110, state: ["value": "unlock"], title: "解锁",
                                systemImage: "lock.open.fill",          group: .lock, risk: .physical),

        "trunk_open":   Command(cmdid: 130, state: ["value": "true"],   title: "打开后备箱",
                                systemImage: "shippingbox.fill",        group: .trunk, risk: .physical),
        "trunk_close":  Command(cmdid: 130, state: ["value": "false"],  title: "关闭后备箱",
                                systemImage: "shippingbox",             group: .trunk, risk: .physical),
        "horn":         Command(cmdid: 120, state: ["value": "true"],   title: "鸣笛寻车",
                                systemImage: "speaker.wave.2.fill",     group: .trunk, risk: .low),

        "window_micro": Command(cmdid: 230, state: ["value": "2"],      title: "微开",
                                systemImage: "window.vertical.open",    group: .window, risk: .physical),
        "window_half":  Command(cmdid: 230, state: ["value": "5"],      title: "半开",
                                systemImage: "window.vertical.open",    group: .window, risk: .physical),
        "window_close": Command(cmdid: 230, state: ["value": "0"],      title: "关闭",
                                systemImage: "window.vertical.closed",  group: .window, risk: .physical),

        "ac_on":        Command(cmdid: 170, state: ["operate": "auto"], title: "打开空调",
                                systemImage: "fanblades.fill",          group: .climate, risk: .low),
        "ac_off":       Command(cmdid: 170, state: ["operate": "off"],  title: "关闭空调",
                                systemImage: "fanblades.slash",         group: .climate, risk: .low),

        "hello":        Command(cmdid: 400, state: ["operation": "on"], title: "上电",
                                systemImage: "power",                   group: .power, risk: .physical),
    ]

    /// 首页展示的动作（顺序即 UI 顺序）
    ///
    /// ⚠️ 这里**故意不包含** `window_micro` / `window_half` / `window_close`：
    ///   车控页有一张专门的「车窗」卡（关闭 / 微开 / 半开 三个开度 + 当前上报
    ///   状态 + 二次确认），把同样三个动作再摆进网格就是同一件事两套 UI。
    ///   所以网格里 `.window` 分组会自然为空、不渲染。
    ///
    ///   空调不一样：网格里只放**开 / 关**（两个互斥动作），
    ///   风量 / 温度是另一张卡 —— 两者是不同维度的控制，不算重复。
    static let quickActions: [String] = [
        "lock", "unlock", "trunk_open", "trunk_close", "horn",
        "ac_on", "ac_off", "hello",
    ]

    /// 首页「常用」那一排（只放最高频的四个）
    static let primaryActions: [String] = ["lock", "unlock", "horn", "ac_on"]

    /// 按分组返回动作 key（保持 commands 的声明顺序）
    static func actions(in group: Command.Group) -> [String] {
        quickActions.filter { commands[$0]?.group == group }
    }

    // MARK: - 空调（cmdid 170）

    /// 空调的 cmdid。★ 不是 230 —— 230 是车窗，这是本次修正的核心。
    static let hvacCmdid = 170

    /// 风量档位范围（来自 `funcConfig.HVAC.fan` 的 min/max，实测 1~9）
    static let hvacFanFallback = Array(1...9)
    /// 温度范围（来自 `funcConfig.HVAC.temperature`，实测 16~32 ℃）
    static let hvacTempFallback = Array(16...32)

    /// 手动模式：一次带上风量 + 温度。
    ///
    /// ── 字段名的证据（不是猜的）──────────────────────────────────
    ///   官方 IPA 主二进制里，车控相关的字符串常量是连在一起的一段：
    ///       operation / off / manual / operate / 26 / out / hotcold /
    ///       nohotcold / temperature / windlevel / circle
    ///   其中 `temperature` 与 `windlevel` 就是空调请求的两个键，
    ///   `manual` 是 `operate` 的第三个取值（另两个是已实测的 `auto` / `off`）。
    ///
    /// ⚠️ 边界（必须说清）：**键有证据，组合没有样本**。
    ///    抓包只录到过 `{"operate":"auto"}` 和 `{"operate":"off"}` ——
    ///    用户在车上从没调过风量/温度，所以 `manual + windlevel + temperature`
    ///    这个组合**没有被抓包证实过**。
    ///    值域（1~9 档 / 16~32 ℃）来自车辆自己上报的 `funcConfig`，是权威的。
    ///
    /// 所以车控页把「开关」放在已验证区，把「风量/温度」放在明确标注的
    /// 未验证卡里，让用户知道自己是在试。
    static func hvacManualState(gear: Int, temperature: Int) -> [String: Any] {
        ["operate": "manual",
         "windlevel": String(gear),
         "temperature": String(temperature)]
    }

    // MARK: - 车窗（cmdid 230）

    /// 车窗的 cmdid
    static let windowCmdid = 230

    /// 车窗开度。
    ///
    /// ★ 铁证：抓包里 `cmdid 230 {"value":"2"}` 让 **1693 / 1694 / 1695 / 1696
    ///   四个信号同时 0→2** —— 四个信号就是四个车窗的位置，
    ///   所以 230 是「四个车窗一起动」，`{"value":"0"}` 是「全关」。
    ///
    /// ⚠️ 2 与 5 谁是「半开」谁是「微开」**没有直接证据**。
    ///    抓包里两个值都出现过，但没人记录当时按的是哪个按钮。
    ///    这里的排序依据是「数值越大开得越大」这个最朴素的假设：
    ///      2 = 微开（小开度）
    ///      5 = 半开（大开度）
    ///    如果实测发现反了，改下面两行的 rawValue 即可，别的地方不用动。
    enum WindowOpening: Int {
        case close = 0
        case micro = 2
        case half  = 5

        var title: String {
            switch self {
            case .close: return "关闭"
            case .micro: return "微开"
            case .half:  return "半开"
            }
        }
    }

    static func windowState(_ opening: WindowOpening) -> [String: Any] {
        ["value": String(opening.rawValue)]
    }

    // MARK: - cmdid 全集（来自 `sharecar` 的 `rightList`）

    /// 本 App **已实现**（有抓包确认 payload）的 cmdid。
    ///
    /// 从 `commands` 表反推，不手工维护 —— 加了新命令这里自动跟着变。
    static var implementedCmdids: Set<Int> {
        Set(commands.values.map { $0.cmdid })
    }

    /// 目前拿到的**最全 cmdid 枚举**（29 个）。
    ///
    /// ★ 来源：`sharecar/getShareVehicleListByVin` 的 `rightList`
    ///   （实测 `"190,192,170,193,171,150,370,470,130,131,230,110,430,410,160,161,480,360,240,361,120,340,440,220,320,420,421,301,500"`）。
    ///
    /// ⚠️ 这个字段本身的语义是「**这一条分享授权**允许对方用哪些指令」，
    ///    不是「这台车支持的全部指令」。但它是我们手上最全的编号空间清单，
    ///    所以拿来当「还差哪些没做」的路线图。
    ///
    /// ⚠️ 注意 `400`（上电，本 App 已实现）**不在**这个列表里 ——
    ///    它走的是响应里的另一个字段 `moduleRights: "100,200,400"`（模块级权限）。
    ///    所以「已实现 5 个 cmdid」里只有 4 个能在 rightList 里对上。
    static let allKnownCmdids: [Int] = [
        110, 120, 130, 131, 150, 160, 161, 170, 171, 190, 192, 193,
        220, 230, 240, 301, 320, 340, 360, 361, 370, 410, 420, 421,
        430, 440, 470, 480, 500,
    ]

    /// `moduleRights` 里的模块级权限（实测 "100,200,400"）。
    /// `400` 对应「上电」，是唯一一个不在 `allKnownCmdids` 里的已实现 cmdid。
    static let knownModuleRights: [Int] = [100, 200, 400]

    // MARK: - 未验证 cmdid（诊断页探测用）

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
        // ★ 2026-10-08 修正：原来这里挂的是 cmdid 230 的「风量 3 档 / 温度 24 ℃」——
        //   那两条**挂错 cmdid 了**。230 是车窗，发过去只会动车窗，
        //   根本调不到风量和温度。已删除，空调的正确入口见车控页的「空调」卡。
        UnverifiedCmd(cmdid: 230, state: #"{"value":"1"}"#,
                      note: "车窗开度 1 —— 抓包只见过 0/2/5，1 是否存在未知"),
    ]
}
