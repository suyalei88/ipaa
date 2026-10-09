//
//  LMMainTabBarController.swift
//  LeapmotorLite
//
//  主界面：5 个 Tab。对应原来 SwiftUI 的 `MainTabView`。
//
//  ★ 迁移进度（2026-10-09 · Phase 3~6）：5 个 Tab **全部**已是原生
//    `LMBaseViewController` 子类，由 `LMNavigationController` 承载。
//    `LMHostingController` 与 `import SwiftUI` 都已从这里删除。
//
import UIKit

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

        // ★ 每个 Tab 都套一层 `LMNavigationController`：
        //   5 个页面内部都有 push 目标（爱车 → 3D 看车 / 充电中心，
        //   车控 → 蓝牙钥匙，设置 → 7 个子页……），没有导航控制器就推不动。
        let tabs: [UIViewController] = [
            makeTab(LMLoveCarViewController(client: client),
                    title: "爱车", image: "car.fill"),
            makeTab(LMLocationViewController(client: client),
                    title: "定位", image: "location.fill"),
            makeTab(LMChargeViewController(client: client),
                    title: "充电", image: "bolt.fill"),
            makeTab(LMControlPanelViewController(client: client),
                    title: "车控", image: "slider.horizontal.3"),
            makeTab(LMSettingsViewController(client: client),
                    title: "设置", image: "gearshape.fill"),
        ]
        viewControllers = tabs

        // ★ 视觉重设计：Tab 栏刷成与页面同色的近黑，并去掉顶部投影线 ——
        //   否则 Tab 栏和内容之间会有一道突兀的横线。
        //   未选中项压到 lmText3（最弱一档），让选中的薄荷色自己「跳」出来。
        let tabAp = UITabBarAppearance()
        tabAp.configureWithOpaqueBackground()
        tabAp.backgroundColor = .lmCanvas
        tabAp.shadowColor = .clear
        for layout in [tabAp.stackedLayoutAppearance,
                       tabAp.inlineLayoutAppearance,
                       tabAp.compactInlineLayoutAppearance] {
            layout.normal.iconColor = .lmText3
            layout.normal.titleTextAttributes = [.foregroundColor: UIColor.lmText3]
            layout.selected.iconColor = .lmAccent
            layout.selected.titleTextAttributes = [.foregroundColor: UIColor.lmAccent]
        }
        tabBar.standardAppearance = tabAp
        tabBar.scrollEdgeAppearance = tabAp
        tabBar.tintColor = .lmAccent
        tabBar.unselectedItemTintColor = .lmText3

        // 原来挂在 `MainTabView` 上的
        // `.task { if client.vehicles.isEmpty { await client.refreshAll() } }`
        // 换到这里：Tab 建好之后拉一次数据。
        if client.vehicles.isEmpty {
            Task { @MainActor [weak self] in
                await self?.client.refreshAll()
            }
        }

        // 爱车页右上角的齿轮现在发这个通知来切到设置 Tab（见 LMLoveCarViewController）。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(selectSettingsTab),
                                               name: .lmSelectSettingsTab,
                                               object: nil)
    }

    /// 把一个页面包成带导航栏、带 tabBarItem 的 Tab。
    private func makeTab(_ root: UIViewController,
                         title: String,
                         image: String) -> UIViewController {
        let nav = LMNavigationController(rootViewController: root)
        nav.tabBarItem = UITabBarItem(title: title,
                                      image: UIImage(systemName: image),
                                      selectedImage: nil)
        return nav
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
    /// 让爱车页的齿轮切到「设置」Tab。
    ///
    /// ★ 为什么用通知而不是直接 `tabBarController?.selectedIndex`：
    ///   设置 Tab 的下标是 `viewDidLoad` 里动态算出来的，页面侧硬编码下标
    ///   一旦 Tab 顺序变了就会切错页。通知由本控制器解析下标，页面只管发。
    static let lmSelectSettingsTab = Notification.Name("LMSelectSettingsTab")
}
