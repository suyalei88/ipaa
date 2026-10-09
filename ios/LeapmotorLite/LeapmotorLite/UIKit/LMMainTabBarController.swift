//
//  LMMainTabBarController.swift
//  LeapmotorLite
//
//  主界面：5 个 Tab。对应原来 SwiftUI 的 `MainTabView`。
//
//  ★ 迁移进度（2026-10-09 · Phase 0）：
//    5 个 Tab **全部**还是 SwiftUI 页，由 `LMHostingController` 托住，
//    行为与迁移前完全一致 —— 这一步只换壳，不动任何页面。
//
//  ★ 之后每迁完一页，就把对应那一行换成原生 VC，例如：
//        LMNavigationController(rootViewController: LoveCarViewController(client: client))
//    其余行不动。所以任何一次迁移之后 App 都还能跑、还能出包。
//
import UIKit
import SwiftUI

final class LMMainTabBarController: UITabBarController {

    private let client: LMClient

    init(client: LMClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LMMainTabBarController 只能代码创建")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // ★ 还没迁移的 Tab 里保留 `NavigationStack`：
        //   这些 SwiftUI 页内部有 `NavigationLink`（车控页跳诊断页等），
        //   拿掉 NavigationStack 会让那些跳转静默失效。
        //   所以这些行**不要**再套 `UINavigationController`，否则会出现双导航栏。
        //
        // ★ 已经迁成 UIKit 的页面（如设置页）反过来：必须由
        //   `LMNavigationController` 提供导航栏，否则它没法 push 子页面。
        let settingsTab = LMNavigationController(
            rootViewController: LMSettingsViewController(client: client))
        settingsTab.tabBarItem = UITabBarItem(title: "设置",
                                              image: UIImage(systemName: "gearshape.fill"),
                                              selectedImage: nil)

        let tabs: [UIViewController] = [
            LMHostingController(client: client, title: "爱车", tabImage: "car.fill") {
                NavigationStack { LoveCarView() }
            },
            LMHostingController(client: client, title: "定位", tabImage: "location.fill") {
                NavigationStack { LocationView() }
            },
            LMHostingController(client: client, title: "充电", tabImage: "bolt.fill") {
                NavigationStack { ChargeView() }
            },
            LMHostingController(client: client, title: "车控", tabImage: "slider.horizontal.3") {
                NavigationStack { ControlPanelView() }
            },
            settingsTab,
        ]
        viewControllers = tabs

        tabBar.tintColor = .lmAccent

        // 原来挂在 `MainTabView` 上的
        // `.task { if client.vehicles.isEmpty { await client.refreshAll() } }`
        // 换到这里：Tab 建好之后拉一次数据。
        if client.vehicles.isEmpty {
            Task { @MainActor [weak self] in
                await self?.client.refreshAll()
            }
        }

        // 爱车页右上角的齿轮现在发这个通知来切到设置 Tab（见 LoveCarView）。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(selectSettingsTab),
                                               name: .lmSelectSettingsTab,
                                               object: nil)
    }

    @objc private func selectSettingsTab() {
        guard let tabs = viewControllers,
              let idx = tabs.firstIndex(where: { $0.tabBarItem.title == "设置" })
        else { return }
        selectedIndex = idx
    }
}

// MARK: - 跨页面切 Tab

extension Notification.Name {
    /// 让 SwiftUI 页面也能切到「设置」Tab。
    ///
    /// ★ 为什么需要它：设置页迁成 UIKit 之后，爱车页那个齿轮不能再
    ///   `NavigationLink { SettingsView() }` —— UIKit 页需要
    ///   `UINavigationController` 才能 push 子页（设置页要 push 7 个页面），
    ///   塞进 SwiftUI 的 `NavigationStack` 会变成「双导航栏 + 子页打不开」。
    ///   设置本来就是独立 Tab，改成切 Tab 更自然。
    ///
    /// 等爱车页也迁成 UIKit 之后，这里可以直接换成
    /// `tabBarController?.selectedIndex = …`，通知就可以删掉。
    static let lmSelectSettingsTab = Notification.Name("LMSelectSettingsTab")
}
