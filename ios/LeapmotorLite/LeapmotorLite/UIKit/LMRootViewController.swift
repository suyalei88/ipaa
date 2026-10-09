//
//  LMRootViewController.swift
//  LeapmotorLite
//
//  根容器：未登录显示登录页，已登录显示主 Tab。
//  对应原来 `RootView` 里的 `if client.session?.isValid == true`。
//
import UIKit
import Combine
import SwiftUI

final class LMRootViewController: UIViewController {

    private let client: LMClient
    private var cancellables = Set<AnyCancellable>()
    private var child: UIViewController?
    private var showingMain = false

    init(client: LMClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LMRootViewController 只能代码创建")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        client.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // 跟 `LMBaseViewController` 同一个道理：`objectWillChange`
                // 在新值写入**之前**触发，必须等一轮再读，否则拿到的是旧登录态。
                Task { @MainActor in
                    self?.syncChild()
                }
            }
            .store(in: &cancellables)

        syncChild()
    }

    /// 按登录态换根页面。
    ///
    /// ★ 状态没变时什么都不做：否则每一次 `objectWillChange`
    ///   （切后台、拉车况、任何一处 @Published 变化）都会把整个 Tab
    ///   重建一遍 —— 用户正在操作的页面会被重置到顶部、输入框被清空。
    private func syncChild() {
        let wantMain = client.session?.isValid == true
        guard child == nil || wantMain != showingMain else { return }
        showingMain = wantMain

        let next: UIViewController
        if wantMain {
            next = LMMainTabBarController(client: client)
        } else {
            next = LMHostingController(client: client, title: "登录") { LoginView() }
        }

        if let old = child {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }

        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        next.didMove(toParent: self)
        child = next
    }
}
