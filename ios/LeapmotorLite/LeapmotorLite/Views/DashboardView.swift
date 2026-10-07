//
//  DashboardView.swift
//  LeapmotorLite
//
//  车况总览
//
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var client: LMClient

    var body: some View {
        List {
            if let v = client.selectedVehicle {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(v.displayName).font(.title2.weight(.semibold))
                        Text(v.vin).font(.caption).foregroundStyle(.secondary)
                        if let plate = v.plateNumber, !plate.isEmpty {
                            Text(plate).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("关键状态") {
                    metric("电量", value: client.batteryPercent.map { "\(Int($0))%" } ?? "--",
                           icon: "battery.100", tint: .green)
                    metric("续航", value: client.rangeKm.map { "\(Int($0)) km" } ?? "--",
                           icon: "road.lanes", tint: .blue)
                    metric("车锁", value: lockText, icon: lockIcon, tint: lockTint)
                    metric("车内温度", value: client.interiorTemp.map { String(format: "%.1f ℃", $0) } ?? "--",
                           icon: "thermometer", tint: .orange)
                    if let m = client.mileage?.totalmileage {
                        metric("总里程", value: "\(Int(m)) km", icon: "gauge.with.dots.needle.67percent", tint: .purple)
                    }
                }

                Section("全部信号") {
                    let keys = client.signals.keys.sorted {
                        (Int($0) ?? Int.max) < (Int($1) ?? Int.max)
                    }
                    ForEach(keys, id: \.self) { k in
                        HStack {
                            Text(k).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(client.signals[k]?.displayText ?? "--")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView("还没有车辆",
                                           systemImage: "car",
                                           description: Text("下拉刷新，或到「设置」检查登录态"))
                }
            }
        }
        .navigationTitle("车况")
        .refreshable { await client.refreshAll() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if client.isBusy { ProgressView() }
            }
        }
        .overlay(alignment: .bottom) {
            if let err = client.lastError {
                Text(err)
                    .font(.footnote)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
    }

    // MARK: - 小组件

    private func metric(_ title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value).font(.body.weight(.medium)).monospacedDigit()
        }
    }

    private var lockText: String {
        guard let locked = client.isLocked else { return "--" }
        return locked ? "已上锁" : "未上锁"
    }
    private var lockIcon: String { client.isLocked == true ? "lock.fill" : "lock.open.fill" }
    private var lockTint: Color { client.isLocked == true ? .green : .orange }
}
