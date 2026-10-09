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

        // ★ 每个 Tab 里保留 `NavigationStack`：
        //   这些 SwiftUI 页内部有 `NavigationLink`（设置页跳诊断页等），
        //   拿掉 NavigationStack 会让那些跳转静默失效。
        //   所以这一层**不要**再套 `UINavigationController`，否则会出现双导航栏。
        viewControllers = [
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
            LMHostingController(client: client, title: "设置", tabImage: "gearshape.fill") {
                NavigationStack { SettingsView() }
            },
        ]

        tabBar.tintColor = .lmAccent

        // 原来挂在 `MainTabView` 上的
        // `.task { if client.vehicles.isEmpty { await client.refreshAll() } }`
        // 换到这里：Tab 建好之后拉一次数据。
        if client.vehicles.isEmpty {
            Task { @MainActor [weak self] in
                await self?.client.refreshAll()
            }
        }
    }
}
