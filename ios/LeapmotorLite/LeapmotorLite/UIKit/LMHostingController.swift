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
///
/// 两种用法：
///
/// 1. **当 Tab 用**（`ownsNavigationBar = false`，默认）
///    调用方自己在内容里套 `NavigationStack { ... }`，本类不碰导航栏。
///
/// 2. **从 UIKit 页 push 进去用**（`ownsNavigationBar = true`）
///    见下面 `ownsNavigationBar` 的注释 —— 这是 2026-10-09 迁移 Phase 2
///    新增的模式。
final class LMHostingController<Content: View>: UIHostingController<AnyView> {

    /// ★★ 为什么需要这个开关（迁移 Phase 2 踩出来的架构问题）：
    ///
    /// 设置页迁成 UIKit 之后，它要 push 的 7 个页面**还是 SwiftUI**
    /// （`VehicleProfileView` / `BLEKeyView` / `DiagnosticsView` …）。
    ///
    /// 而这些页面里 `BLEKeyView` 有 4 处、`DiagnosticsView` 有 1 处
    /// `NavigationLink` —— `NavigationLink` **必须有 `NavigationStack` 祖先**
    /// 才能工作。如果直接把它们 push 进 UIKit 的导航栈：
    ///
    ///   · 那些内部跳转**静默失效**（点了没反应，不报错）；
    ///   · 但给它们套一层 `NavigationStack`，又会变成**两根导航栏叠在一起**
    ///     （上面 UIKit 的、下面 SwiftUI 的）。
    ///
    /// 解法就是把这个开关打开：
    ///   · 内容外面套一层 `NavigationStack`（让内部 `NavigationLink` 能用）；
    ///   · 把**外层 UIKit 导航栏藏掉**（`viewWillAppear` 里做）；
    ///   · 再在 SwiftUI 那根栏里补一个「返回」按钮
    ///     （`NavigationStack` 作为栈底时本来没有返回键，不补用户就出不去）。
    ///
    /// 等这些页面也迁成 UIKit 之后，这个开关和 `onBack` 就可以一起删掉。
    private let ownsNavigationBar: Bool

    /// - Parameters:
    ///   - client: 全局数据源，注入成 `environmentObject`。这样被托住的
    ///             SwiftUI 页里 `@EnvironmentObject var client` 照旧能拿到，
    ///             **那些页面的代码一行都不用改**。
    ///   - title: Tab 标题 / 导航标题。
    ///   - tabImage: SF Symbol 名。传 `nil` 表示这不是一个 Tab（例如登录页）。
    ///   - ownsNavigationBar: `true` = 内容自带 `NavigationStack`，本类负责
    ///             藏掉外层 UIKit 导航栏并补返回键。仅用于「从 UIKit 页 push
    ///             进来的 SwiftUI 页」。见上面属性注释。
    ///   - onBack: 返回按钮的动作。`ownsNavigationBar == true` 时**必须传**，
    ///             否则用户进去之后出不来。
    init(client: LMClient,
         title: String,
         tabImage: String? = nil,
         ownsNavigationBar: Bool = false,
         onBack: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.ownsNavigationBar = ownsNavigationBar

        // ★ `.tint(Color.lmAccent)` 必须在这里补上：
        //   原来它挂在 `LeapmotorLiteApp` 的 Scene 上，对整个 App 生效。
        //   入口换成 UIKit 之后那层环境没了，不补的话所有 SwiftUI 控件会退回
        //   系统默认蓝，跟 UIKit 侧的 `UIColor.lmAccent` 不是同一个蓝，
        //   迁移期间两套页面放在一起会明显看出色差。
        let inner = content()
            .environmentObject(client)
            .tint(Color.lmAccent)

        if ownsNavigationBar {
            super.init(rootView: AnyView(
                NavigationStack {
                    inner.toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if let onBack {
                                Button(action: onBack) {
                                    Image(systemName: "chevron.left")
                                }
                                .accessibilityLabel("返回")
                            }
                        }
                    }
                }
            ))
        } else {
            super.init(rootView: AnyView(inner))
        }

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

    // MARK: - 自带导航栏模式：进出时隐藏/恢复外层 UIKit 导航栏

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if ownsNavigationBar {
            navigationController?.setNavigationBarHidden(true, animated: animated)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if ownsNavigationBar {
            // ★ 必须恢复：不然返回设置页之后设置页自己的导航栏也消失了
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }
}
