//
//  LMBuildInfo.swift
//  LeapmotorLite
//
//  ★★ 这个文件的唯一职责：让「我装的到底是哪一版」一眼可查。
//
//  为什么必须有它：
//    2026-10-07 那次交付踩过 —— 修完「假充电」和「定位偏移」两个 bug 后出了新 IPA，
//    但 `Info.plist` 里的 `CFBundleShortVersionString` / `CFBundleVersion`
//    忘了跟着改，两版都是 `1.0.0 (1)`、bundle id 也相同。
//    结果用户装完新包说「跟上个版本一样」，而我们**无法证明他装的是哪一版** ——
//    只能事后把两个 IPA 产物都下载下来比对二进制字符串才确认。
//    那种排查方式太笨了，所以现在把构建标识直接做进 App 里。
//
//  规矩（每次交付新包都必须做，两步）：
//    1. 改下面 `tag`，写清这一版干了什么。
//    2. 改 `Support/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`。
//    两处都改，`versionText` 会自动反映出来。
//
//  另外还有一层兜底：`ios/build_ipa.sh` 打包时会把 **git 提交号 + 构建时刻**
//  注进 Info.plist（`LMGitSHA` / `LMBuildTime`），`fingerprint` 会读出来显示。
//  所以就算哪天又忘了改版本号，只要提交号不同，两版包依然能一眼分辨 ——
//  这正是手工纪律靠不住时该有的第二道防线。
//
//  在哪看：
//    · 设置 → 设备 → 「本 App 构建」（第一行）
//    · 设置 → 诊断 → 算法自检（页脚）
//

import Foundation

enum LMBuildInfo {

    // MARK: - 手工维护的构建标识

    /// ★ 每次出包改这一行。格式：`日期.当日序号 · 这一版干了什么`。
    ///
    /// 不要用「自动取当前时间」之类的方式生成 —— 那样每次编译都会变，
    /// 反而没法回答「我手上这个包是哪一次构建的」。
    /// 手工维护一个显式的字符串，才能和「某次交付」一一对应。
    static let tag = "2026-10-09.9 · 定位页撤掉 IP 归属地卡、改成「我的位置（本机 GPS）」与「车辆位置」并列；新增驻车照片（chassis/query → 停车场俯视哨兵照，可点开全屏）；修健康充电显示错误（deviceId 由每次随机改成持久化稳定值）；车控页补感叹号图例"

    // MARK: - 从 Bundle 读出的版本

    /// `CFBundleShortVersionString`，例如 `1.0.1`。
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// `CFBundleVersion`，例如 `2`。
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// 一行式版本串，例如 `1.0.1 (2)`。
    static var versionText: String {
        "\(shortVersion) (\(buildNumber))"
    }

    // MARK: - 构建指纹（由 ios/build_ipa.sh 注入）

    /// 从 Info.plist 读一个字符串键；返回 nil 表示「没注入」。
    ///
    /// ★ 关键判断：走 Xcode 直接编译（没经过 build_ipa.sh）时，
    /// `$(LM_GIT_SHA)` 不会被替换，读出来就是字面量 `$(LM_GIT_SHA)`。
    /// 那不是有效值，必须当成「未注入」而不是当真显示给用户。
    private static func injected(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("$(") { return nil }
        return t
    }

    /// git 提交号，例如 `19d71c9`；本地直编时为 nil。
    static var gitSHA: String? { injected("LMGitSHA") }

    /// 构建时刻（UTC），例如 `2026-10-07 15:03Z`；本地直编时为 nil。
    static var buildTime: String? { injected("LMBuildTime") }

    /// 构建指纹，例如 `19d71c9 @ 2026-10-07 15:03Z`；未注入时给一句人话。
    static var fingerprint: String {
        switch (gitSHA, buildTime) {
        case let (sha?, time?): return "\(sha) @ \(time)"
        case let (sha?, nil):   return sha
        case let (nil, time?):  return time
        default:                return "本地构建（未经 build_ipa.sh，无提交号）"
        }
    }

    /// 界面上显示的完整标识：版本号 + 构建 tag + 指纹。
    static var displayText: String {
        "\(versionText) · \(tag)\n\(fingerprint)"
    }

    // MARK: - 自检

    struct Check: Identifiable {
        public let id = UUID()
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    /// 三件必须成立的事：
    ///   ① 版本号不能还是初始的 `1.0.0 (1)` —— 那说明忘了改 Info.plist；
    ///   ② `tag` 不能是空的；
    ///   ③ 构建指纹（git 提交号）必须已注入 —— 说明这个包是 build_ipa.sh 打的。
    ///
    /// 第 ① 条是**真的会抓到问题**的：忘了改版本号，用户就分不清新旧包，
    /// 正是 2026-10-07 那次踩的坑。所以宁可在这里报一条红的。
    static func selfCheck() -> [Check] {
        var out: [Check] = []

        let versionBumped = !(shortVersion == "1.0.0" && buildNumber == "1")
        out.append(Check(
            name: "构建版本号已更新",
            passed: versionBumped,
            detail: versionBumped
                ? "当前 \(versionText)"
                : "仍是初始的 1.0.0 (1) —— 说明 Support/Info.plist 忘了改版本号，"
                + "用户将无法分辨新旧包"
        ))

        let tagOK = !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        out.append(Check(
            name: "构建标识非空",
            passed: tagOK,
            detail: tagOK ? tag : "LMBuildInfo.tag 是空的，改成这一版做了什么"
        ))

        let hasFP = gitSHA != nil
        out.append(Check(
            name: "构建指纹已注入",
            passed: hasFP,
            detail: hasFP
                ? fingerprint
                : "没读到 git 提交号 —— 这个包不是 build_ipa.sh 打的"
                + "（Xcode 直接 Run 属于正常情况）"
        ))

        return out
    }
}
