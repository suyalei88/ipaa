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

    // MARK: - 空调档位（cmdid 230）

    /// 空调 / 风量的 cmdid
    static let hvacCmdid = 230

    /// 风量档位的 state payload。`0` = 关。
    ///
    /// ★ 背景：抓包里 cmdid 230 **只出现过** `{"value":"0"|"2"|"5"}`，
    ///   很容易以为空调就三档。但 `vehicle/list` 的 `funcConfig.HVAC.fan`
    ///   明确写着 `min=1 max=9 unit=gear` —— 说明**风量是 1~9 档**，
    ///   抓包那三次只是碰巧只按了「低 / 高」。
    ///
    /// ⚠️ 边界：这只证明**车支持**这些档位，**没有**证明
    ///    `{"value":"3"}` 这种 payload 服务端一定接受。
    ///    所以车控页把 1~9 档单独放在「未验证」卡片里，
    ///    0 / 2 / 5 三个有抓包证据的仍然放在已验证区。
    static func hvacState(gear: Int) -> [String: Any] { ["value": String(gear)] }

    /// 温度设定的 state payload —— ⚠️⚠️ **纯猜测，没有样本**。
    ///
    /// 抓包里 cmdid 230 只有 `{"value":"…"}` 一个字段，**没有任何温度字段的样本**。
    /// 这里的 `temperature` 字段名是照 `funcConfig.HVAC.temperature` 反推的，
    /// 值域 16~32 °C 同样来自那个字段 —— 但服务端到底认不认这个 key，
    /// 我们**不知道**。
    ///
    /// 所以它只作为「诊断 → 未验证 cmdid 探测」里的**预填值**，
    /// 让用户自己决定要不要试一次；**绝不**接进车控页当正式功能。
    static func hvacTemperatureGuess(celsius: Int, gear: Int = 2) -> String {
        #"{"value":"\#(gear)","temperature":"\#(celsius)"}"#
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
        // ★ 2026-10-08 新增两条。都是「有范围依据、但 payload 没样本」的：
        UnverifiedCmd(cmdid: 230, state: #"{"value":"3"}"#,
                      note: "风量 3 档 —— 范围来自 funcConfig(fan 1~9)，payload 未验证"),
        UnverifiedCmd(cmdid: 230, state: hvacTemperatureGuess(celsius: 24),
                      note: "温度 24 °C —— 字段名 temperature 是按 funcConfig 反推的，未验证"),
    ]
}
