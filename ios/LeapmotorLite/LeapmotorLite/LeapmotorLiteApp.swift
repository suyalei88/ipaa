//
//  LeapmotorLiteApp.swift
//  LeapmotorLite
//
//  第三方零跑车控 · 无广告 · 只有功能
//  仅用于控制本人车辆 / 本人账号
//
import SwiftUI

@main
struct LeapmotorLiteApp: App {
    @StateObject private var client = LMClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .tint(.lmAccent)
        }
    }
}

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var client: LMClient

    var body: some View {
        Group {
            if client.session?.isValid == true {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .animation(.default, value: client.session?.isValid)
    }
}

// MARK: - 主 Tab

struct MainTabView: View {
    @EnvironmentObject var client: LMClient

    var body: some View {
        TabView {
            NavigationStack { DashboardView() }
                .tabItem { Label("车况", systemImage: "car.fill") }

            NavigationStack { ControlPanelView() }
                .tabItem { Label("车控", systemImage: "slider.horizontal.3") }

            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .task {
            if client.vehicles.isEmpty { await client.refreshAll() }
        }
    }
}

// MARK: - 配色

extension Color {
    static let lmAccent = Color(red: 0.11, green: 0.45, blue: 0.94)   // 零跑蓝
    static let lmCard   = Color(.secondarySystemGroupedBackground)
}
