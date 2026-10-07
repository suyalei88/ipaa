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
    }

    // MARK: - 车控命令

    /// 一个车控动作
    struct Command {
        let cmdid: Int
        let state: [String: Any]
        let title: String
        let systemImage: String
    }

    /// cmdid 表（实测）
    ///   110 车门锁   {"value":"lock"|"unlock"}
    ///   120 后备箱   {"value":"true"}
    ///   170 大灯     {"operate":"off"|"auto"}
    ///   230 空调     {"value":"0"|"2"|"5"}
    ///   400 上电     {"operation":"on"}
    static let commands: [String: Command] = [
        "lock":      Command(cmdid: 110, state: ["value": "lock"],        title: "锁车",     systemImage: "lock.fill"),
        "unlock":    Command(cmdid: 110, state: ["value": "unlock"],      title: "解锁",     systemImage: "lock.open.fill"),
        "trunk":     Command(cmdid: 120, state: ["value": "true"],        title: "后备箱",   systemImage: "car.rear.and.tire.marks"),
        "light_off": Command(cmdid: 170, state: ["operate": "off"],       title: "大灯关",   systemImage: "lightbulb.slash"),
        "light_auto":Command(cmdid: 170, state: ["operate": "auto"],      title: "大灯自动", systemImage: "lightbulb"),
        "hvac_off":  Command(cmdid: 230, state: ["value": "0"],           title: "空调关",   systemImage: "fanblades.slash"),
        "hvac_low":  Command(cmdid: 230, state: ["value": "2"],           title: "空调低",   systemImage: "fanblades"),
        "hvac_high": Command(cmdid: 230, state: ["value": "5"],           title: "空调高",   systemImage: "fanblades.fill"),
        "hello":     Command(cmdid: 400, state: ["operation": "on"],      title: "上电",     systemImage: "power"),
    ]

    /// 首页展示的动作（顺序即 UI 顺序）
    static let quickActions: [String] = [
        "lock", "unlock", "trunk", "hvac_off", "hvac_low", "hvac_high",
        "light_off", "light_auto", "hello",
    ]
}
