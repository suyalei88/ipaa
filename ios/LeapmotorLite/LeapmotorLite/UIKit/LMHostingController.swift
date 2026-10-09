//
//  LMHostingController.swift
//  LeapmotorLite
//
//  迁移过渡期的桥：把**还没迁成 UIKit** 的 SwiftUI 页面包成一个 UIViewController。
//
//  ★ 为什么需要它（2026-10-09，UI 从 SwiftUI 迁到 UIKit）：
//    入口已经从 SwiftUI 的 `App` 换成 `LMAppDelegate`。如果要求「所有页面
//    一次性全改成 UIKit」，那在全部改完之前 App 根本编译不过、更没法验证，
//    一次要动的量是 7,514 行视图代码 —— 中间任何一步出错都只能整体回滚。
//
//    用 `UIHostingController` 把旧页面托住，就能**一页一页换**：
//    换完一页 App 都还能跑、还能出包、还能装机验证。
//
//  ★ 迁移全部完成（`Views/` 下的页面都变成 `LMBaseViewController` 子类）后，
//    这个文件可以整体删掉。
//
import SwiftUI
import UIKit

/// 把一个 SwiftUI 视图包成 UIViewController，并注入全局 `LMClient`。
final class LMHostingController<Content: View>: UIHostingController<AnyView> {

    /// - Parameters:
    ///   - client: 全局数据源，注入成 `environmentObject`。这样被托住的
    ///             SwiftUI 页里 `@EnvironmentObject var client` 照旧能拿到，
    ///             **那些页面的代码一行都不用改**。
    ///   - title: Tab 标题 / 导航标题。
    ///   - tabImage: SF Symbol 名。传 `nil` 表示这不是一个 Tab（例如登录页）。
    init(client: LMClient,
         title: String,
         tabImage: String? = nil,
         @ViewBuilder content: () -> Content) {
        // ★ `.tint(Color.lmAccent)` 必须在这里补上：
        //   原来它挂在 `LeapmotorLiteApp` 的 Scene 上，对整个 App 生效。
        //   入口换成 UIKit 之后那层环境没了，不补的话所有 SwiftUI 控件会退回
        //   系统默认蓝，跟 UIKit 侧的 `UIColor.lmAccent` 不是同一个蓝，
        //   迁移期间两套页面放在一起会明显看出色差。
        super.init(rootView: AnyView(
            content()
                .environmentObject(client)
                .tint(Color.lmAccent)
        ))
        self.title = title
        if let tabImage {
            tabBarItem = UITabBarItem(title: title,
                                      image: UIImage(systemName: tabImage),
                                      selectedImage: nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("LMHostingController 只能代码创建")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        // 被托管的 SwiftUI 页自带 `NavigationStack`，不要再叠一层导航栏
        navigationItem.largeTitleDisplayMode = .never
    }
}
