//
//  VehicleProfileView.swift
//  LeapmotorLite
//
//  「车辆档案」页 —— 把抓包审计里发现的、官方 App 藏得比较深的信息集中展示。
//
//  ★ 数据来源（全部有**真实抓包样本**，路径与响应结构见 LMEndpoints.Path 的注释）：
//    · vehicle/list                      → 车系 / 年款 / 配置代号 / 66 个能力位 / funcConfig
//    · carpicture/3d/key                 → **精确版型**（"720智尊版 六座"）+ 官方 3D 分享页
//    · fota/getCurrentVersion            → 车机固件版本 + 最近一次 OTA 的完整更新日志
//    · commoninfo/getBgConf              → 服务端下发的功能开关表（无感蓝牙 / 雷达 / 3D 主题…）
//    · sharecar/getShareVehicleListByVin → 分享记录 + rightList（29 个 cmdid）
//    · appImage/getAppImage              → 模块示意图
//    · msgcenter/…/selectmsgcount        → 消息未读数
//
//  ⚠️ 这一页**纯只读**，没有任何下发按钮 —— 所有车控都在「车控」页。
//     这是刻意的：档案页的价值是「看清楚这台车是什么、支持什么」，
//     不是又一个下发入口。
//
import SwiftUI
import Foundation

struct VehicleProfileView: View {
    @EnvironmentObject var client: LMClient
    @Environment(\.openURL) private var openURL

    @State private var loading = false

    /// cmdid 小方块用的自适应网格
    private let chipColumns = [GridItem(.adaptive(minimum: 52), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loading && client.profileLoadLog.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text("正在读取车辆档案…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }

                if let v = client.selectedVehicle {
                    identityCard(v)
                    hvacCard(v)
                }
                fotaCard
                bgConfCard
                shareCard
                cmdidRoadmapCard
                appImageCard
                threeDCard
                noticeCard
                loadLogCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("车辆档案")
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        await client.refreshVehicleProfile()
        try? await client.refreshNoticeCount()
        loading = false
    }

    // MARK: - 车辆身份

    private func identityCard(_ v: LMVehicle) -> some View {
        VStack(spacing: 10) {
            SectionHeader(text: "车辆身份")
            LMCard(padding: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.lmAccent)
                        Text(v.displayName).font(.headline)
                        Spacer(minLength: 0)
                    }
                    infoRow("VIN", v.vin)
                    infoRow("车系 / 车型", nonEmpty(v.carType) ?? "--")
                    infoRow("年款", v.yearText)
                    // ★ 精确版型只有 3D 接口才有 —— vehicle/list 的
                    //   carConfigEdition 实测是**空串**，拿不到版型文字。
                    infoRow("版型", trimText ?? nonEmpty(v.carConfigEdition) ?? "接口未提供")
                    infoRow("车漆颜色", nonEmpty(v.outColor) ?? "--")
                    infoRow("车顶颜色代号", nonEmpty(v.roofColor) ?? "--")
                    infoRow("配置代号", v.allocationCode.map { String($0) } ?? "--")
                    infoRow("carId", v.carId.map { String($0) } ?? "--")
                    infoRow("CCC 数字钥匙", nonEmpty(v.cccVehicleId) ?? "未绑定（null）")
                    infoRow("座椅布局代码", v.seatLayout.map { String($0) } ?? "--")
                    infoRow("车牌号", nonEmpty(v.plateNumber) ?? "--")
                }
            }
            if let a = v.abilities, !a.isEmpty {
                LMCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("能力位（\(a.count) 个）")
                            .font(.caption.weight(.semibold))
                        Text(v.abilitiesSortedText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("⚠️ 这些码的含义官方没有公开，我们也没有样本能把码位和功能对应起来。"
                             + "这里只按原样排序展示，用途是「换车 / 换版本后对比这串码变没变」。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - 空调能力范围

    private func hvacCard(_ v: LMVehicle) -> some View {
        VStack(spacing: 10) {
            SectionHeader(text: "空调能力范围")
            LMCard(padding: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    if let f = v.hvacFanRange { infoRow("风量", f.rangeText) }
                    if let t = v.hvacTempRange { infoRow("温度", t.rangeText) }
                    if v.funcConfig == nil {
                        Text("这台车的 vehicle/list 没有返回 funcConfig，无法确定档位范围。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("★ 这是「空调到底有几档」的唯一权威来源。\n"
                         + "抓包里 cmdid 230 只出现过 {\"value\":\"0\"|\"2\"|\"5\"}，"
                         + "很容易让人以为空调就三档；实际上风量是 1~9 档、温度是 16~32 °C。\n"
                         + "⚠️ 这只证明**车支持**这些档位，没有证明 {\"value\":\"3\"} 这种 payload "
                         + "服务端一定接受 —— 所以车控页把 1~9 档单独放在「未验证」卡片里。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 车机固件 / OTA

    @ViewBuilder
    private var fotaCard: some View {
        if let f = client.fotaVersion {
            VStack(spacing: 10) {
                SectionHeader(text: "车机固件 / 最近一次 OTA")
                LMCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        infoRow("当前版本", nonEmpty(f.versionNo) ?? "--")
                        infoRow("升级时间", nonEmpty(f.updateTime) ?? "--")
                    }
                }
                if !f.logLines.isEmpty {
                    logLinesCard(f.logLines)
                }
            }
        }
    }

    private func logLinesCard(_ lines: [String]) -> some View {
        LMCard(padding: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("更新日志（\(lines.count) 行）")
                    .font(.caption.weight(.semibold))
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - 功能开关

    @ViewBuilder
    private var bgConfCard: some View {
        if let b = client.bgConf, !b.flags.isEmpty {
            VStack(spacing: 10) {
                SectionHeader(text: "功能开关（服务端下发）")
                LMCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(b.flags) { f in
                            HStack(spacing: 8) {
                                Image(systemName: f.on ? "checkmark.circle.fill" : "xmark.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(f.on ? Color.lmGood : Color.secondary)
                                Text(f.name)
                                    .font(.caption)
                                Spacer(minLength: 0)
                                Text(f.on ? "开" : "关")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(f.on ? Color.lmGood : Color.secondary)
                            }
                        }
                    }
                }
                Text("⚠️ 这些开关由服务端 / 车端决定，本 App **只读不改**。"
                     + "中文名是按字段名直译的，不是官方文档。"
                     + "比如「无感蓝牙钥匙」是关的，就解释了为什么靠不靠近都不会自动解锁。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - 车辆分享

    @ViewBuilder
    private var shareCard: some View {
        if let s = client.shareList {
            let list = s.carShareInfoList ?? []
            VStack(spacing: 10) {
                SectionHeader(text: "车辆分享")
                if list.isEmpty {
                    LMCard(padding: 14) {
                        Text("没有分享记录 —— 这台车没有授权给其他账号。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(list) { info in
                        shareInfoCard(info)
                    }
                }
                Text("最多可分享给 \(nonEmpty(s.shareMaxCount) ?? "?") 个账号。\n"
                     + "「模块权限」是模块级授权（100/200/400）；下面那串 cmdid 是"
                     + "**这一条分享**允许对方使用的指令。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func shareInfoCard(_ info: LMShareInfo) -> some View {
        LMCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.lmPurple)
                    Text(nonEmpty(info.nickName) ?? "未命名")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    Text(info.durationText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                infoRow("手机号", nonEmpty(info.mobileNumber) ?? "--")
                infoRow("分享时间", info.shareTimeText)
                infoRow("模块权限", nonEmpty(info.moduleRights) ?? "--")
                if !info.rights.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("可用指令 cmdid（\(info.rights.count) 个）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: chipColumns, spacing: 6) {
                            ForEach(info.rights, id: \.self) { id in
                                cmdChip(id)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - cmdid 路线图

    private var cmdidRoadmapCard: some View {
        VStack(spacing: 10) {
            SectionHeader(text: "车控指令全集（路线图）")
            LMCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("已实现 \(LMEndpoints.implementedCmdids.count) 个")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.lmGood)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("已知 \(LMEndpoints.allKnownCmdids.count) 个")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: chipColumns, spacing: 6) {
                        ForEach(LMEndpoints.allKnownCmdids, id: \.self) { id in
                            cmdChip(id)
                        }
                    }
                    ForEach(LMEndpoints.knownModuleRights, id: \.self) { id in
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.lmTeal)
                            Text("模块权限 \(id)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if id == 400 {
                                Text("= 上电，本 App 已实现")
                                    .font(.caption2)
                                    .foregroundStyle(Color.lmGood)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Divider()
                    Text("绿色 = 本 App 已实现（有抓包确认的 payload）。\n"
                         + "灰色 = 已知编号但语义未确认，没有可靠 payload，**故意不做** —— "
                         + "对一台真车下发「不知道干什么」的指令是不负责任的。\n"
                         + "这 \(LMEndpoints.allKnownCmdids.count) 个编号来自 "
                         + "sharecar 接口的 rightList（见上方「车辆分享」）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// cmdid 小方块：已实现的用绿色，其余灰色。
    ///
    /// 局部变量名**不能**叫 `tint` —— 会和外层的 `Color` 静态成员写法混，
    /// 这里叫 `tone` 更稳（项目里已经踩过一次同名遮蔽）。
    private func cmdChip(_ id: Int) -> some View {
        let done = LMEndpoints.implementedCmdids.contains(id)
        let tone: Color = done ? Color.lmGood : Color.secondary
        return Text("\(id)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(tone)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(tone.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - 模块示意图

    @ViewBuilder
    private var appImageCard: some View {
        if !client.appImages.isEmpty {
            VStack(spacing: 10) {
                SectionHeader(text: "模块示意图")
                ForEach(client.appImages) { m in
                    appImageModuleCard(m)
                }
            }
        }
    }

    private func appImageModuleCard(_ m: LMAppImageModule) -> some View {
        let subs = m.subModule ?? []
        return LMCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(nonEmpty(m.moduleName) ?? "模块 \(m.moduleId ?? -1)")
                    .font(.subheadline.weight(.medium))
                ForEach(subs.indices, id: \.self) { i in
                    let urlText = subs[i].image ?? ""
                    VStack(alignment: .leading, spacing: 4) {
                        Text(nonEmpty(subs[i].subModuleName) ?? "示意图")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let u = URL(string: urlText), !urlText.isEmpty {
                            Button {
                                openURL(u)
                            } label: {
                                Label("打开示意图", systemImage: "photo")
                                    .font(.caption)
                            }
                        } else {
                            Text("没有图片地址")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 3D 车模

    @ViewBuilder
    private var threeDCard: some View {
        if let k = client.car3DKey {
            VStack(spacing: 10) {
                SectionHeader(text: "3D 车模")
                LMCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        infoRow("h5Key", nonEmpty(k.h5Key) ?? "--")
                        infoRow("srcKey", nonEmpty(k.srcKey) ?? "--")
                        infoRow("modelType", k.modelType.map { String($0) } ?? "--")
                        if let p = k.modelParam {
                            infoRow("版型", nonEmpty(p.carTypeCode) ?? "--")
                            infoRow("颜色代号", p.colorCode.map { String($0) } ?? "--")
                        }
                        if let u = k.shareBindUrl, let url = URL(string: u) {
                            Button {
                                openURL(url)
                            } label: {
                                Label("打开官方 3D 车模分享页", systemImage: "safari")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 消息

    @ViewBuilder
    private var noticeCard: some View {
        if let n = client.noticeCount {
            VStack(spacing: 10) {
                SectionHeader(text: "消息")
                LMCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        infoRow("未读", String(n.unread ?? 0))
                        infoRow("总数", String(n.total ?? 0))
                        infoRow("已读", String(n.alreadyread ?? 0))
                        infoRow("用户消息", String(n.usertotal ?? 0))
                        infoRow("车辆消息", String(n.devicetotal ?? 0))
                    }
                }
            }
        }
    }

    // MARK: - 加载情况

    @ViewBuilder
    private var loadLogCard: some View {
        if !client.profileLoadLog.isEmpty {
            VStack(spacing: 10) {
                SectionHeader(text: "本次加载情况")
                LMCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(client.profileLoadLog.indices, id: \.self) { i in
                            Text(client.profileLoadLog[i])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("某个接口失败不影响其它内容显示 —— 每个接口都单独兜错了。下拉可重新加载。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - 小工具

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(v)
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 去掉 nil 和「只有空白」的字符串
    private func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// 精确版型（只有 `carpicture/3d/key` 才有）
    private var trimText: String? {
        nonEmpty(client.car3DKey?.modelParam?.carTypeCode)
    }
}
