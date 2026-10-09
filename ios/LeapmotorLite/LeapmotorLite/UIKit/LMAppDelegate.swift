//
//  LMAppDelegate.swift
//  LeapmotorLite
//
//  App 入口。
//
//  ★ 2026-10-09：从 SwiftUI 的 `@main struct LeapmotorLiteApp: App`
//    换成经典的 `UIApplicationDelegate` + `window`。
//
//  ★ 为什么不用 SceneDelegate：`Support/Info.plist` 里**没有**
//    `UIApplicationSceneManifest` 这一节，iOS 因此走的是传统生命周期，
//    直接在 `didFinishLaunching` 里建 window 就够，不需要 Scene 那一套。
//    ⚠️ 如果以后要加 `UIApplicationSceneManifest`，必须同时补 SceneDelegate，
//       否则 window 永远不会显示（表现为启动后白屏）。
//
//  ★ 全局唯一的 `LMClient` 在这里创建，然后一路传给
//    `LMRootViewController` → `LMMainTabBarController` → 各个页面。
//    任何页面都不要自己 `LMClient()` —— 那样会各持一份登录态。
//
import UIKit

@main
final class LMAppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let client = LMClient()

        // 无 Scene 清单时的标准做法。`UIScreen.main` 在 iOS 16+ 标了弃用，
        // 但传统生命周期下没有别的办法拿到全屏尺寸，这里只是警告不影响构建。
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = LMRootViewController(client: client)
        // 全局 tint：UIKit 侧按钮 / 开关 / 导航栏的默认着色
        window.tintColor = .lmAccent
        window.makeKeyAndVisible()
        self.window = window

        return true
    }
}
