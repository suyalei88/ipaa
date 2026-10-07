# 零跑轻控 · 第三方干净客户端（iOS）

> 无广告、纯功能、本地直连的零跑车控 App。
> 核心 = **协议逆向**（签名/加密算法已完整还原并回归验证）+ **干净原生前端**（自己写的 SwiftUI）。
>
> ⚠️ 只用**你自己账号**控制**你自己名下的车**。车控是安全敏感接口，
> 别做越权 / 批量 / 代控 / 分享账号的事。逆向仅用于互操作（自用），请自行评估官方用户协议。

**交付物 → [`ios/LeapmotorLite/`](ios/LeapmotorLite/)**（Swift / SwiftUI，iOS 17+，零第三方依赖）

---

## 一、已还原的协议（全部用真实抓包验证过）

| 项目 | 结论 | 状态 |
|---|---|---|
| 请求签名（★双模式） | **登录前** `sign = SHA256(valueStr)`（无密钥）；**登录后** `sign = HMAC_SHA256(valueStr, signKey)` | ✅ |
| `valueStr` | `merge(signBody, signHeaders)` → 剔空 → key 升序（JS 字符串序）→ **只拼 value，无分隔符** | ✅ |
| 参与签名的 8 个 header | `acceptLanguage / channel / deviceId / deviceType / nonce / source / timestamp / version` | ✅ |
| `signBody` | `application/json` → `JSON.parse`；`x-www-form-urlencoded` → **URL 解码后的表单字典**；无 body → `{}`；GET 合并 query | ✅ |
| `signKey` 派生 | `UPPER(hex(XOR3(b64(jwt[2]), b64(signParam.r2), b64(signParam.r3))))` — **不需要 Frida** | ✅ |
| `signKey == encryptKey` | 服务端保证 `signParam.r2^r3 == encryptParam.r2^r3` | ✅ |
| `oppwd`（操作密码） | `base64(AES-128-CBC-PKCS7(pw, md5hex(tok[0:32])[8:24], md5hex(tok[32:64])[8:24]))` | ✅ 明文 `4211` 逐字节一致 |
| **短信验证码登录（4 步全链路）** | 发码(RSA) → `check_login_with_phone`(**form**) → `account/v1/login`(**SHA256**) → 派生 signKey | ✅ 实测打通 |
| 手机号 RSA 加密 | `base64(RSA_PKCS1v15(phone, AccountIDKey))`，SPKI→PKCS#1 剥壳 | ✅ |
| 车控链路 | `appremotectl` → 轮询 `appremotectl/query` | ✅ 100% 命中 |

**回归结果**：`har_appgw.har` 里 105 个带 `sign` 的请求 → **101 MATCH**。
未命中的 4 条全部是车控链之外的边缘接口（文件服务 / 设备注册 / 登录请求本身），
详见 [`evidence/FINDINGS_CRYPTO.md`](evidence/FINDINGS_CRYPTO.md) §10–§12。

> **关键坑**：`/base/base-user/account/v1/login`（换 token）必须用 **SHA256 无密钥**签名；
> 用 HMAC 会一直得到 `302002002 签名信息校验失败`。
> `check_login_with_phone` 必须是 **form-urlencoded**，用 JSON 会得到 `1019 参数不能为空`。

完整算法与端点表 → **[`ios/LeapmotorLite/README.md`](ios/LeapmotorLite/README.md)** 与 **[`evidence/FINDINGS_CRYPTO.md`](evidence/FINDINGS_CRYPTO.md)**。

---

## 二、目标平台：iOS（已完成）

逆向目标：官方 iOS App `com.leapmotor.developer` **v1.22.68**（已解密 IPA）。

> Android 包 `com.dahua.leapmotor` 是 **360 加固**（`classes.dex` 是壳，
> 登录/签名相关字符串 0 命中），逆向成本极高 —— **已放弃 Android 路线**。
> iOS 主二进制 + Metro JS bundle 是明文的，算法直接可读。

| 目录 | 作用 |
|---|---|
| **`ios/LeapmotorLite/`** | **最终交付：SwiftUI 干净车控 App（签名/加密全实现 + 内置自检）** |
| `client/` | Python 参考实现（签名/派生/回归校验）+ Mach-O 逆向工具 |
| `evidence/` | iOS 原始 IPA、抓包 HAR、扫描结果、**FINDINGS_CRYPTO.md 分析报告**（安卓 APK 与解包产物已于 2026-10-07 清理，结论保留在报告里） |
| `capture/` | mitmproxy 抓包插件 + **CAPTURE_SOP_IOS.md 抓包 SOP** |
| `frida/` | `ios_ssl_bypass.js` / `ios_hook_request.js`（越狱机辅助） |
| `app/` | 早期 FastAPI + 网页版（历史产物，已被 iOS 版取代） |

---

## 三、怎么用（三步）

### 1. 打包 IPA

**没有 Mac？** → GitHub Actions：推到 GitHub → Actions → **Build IPA** → Run → 在 Artifacts 里下 IPA。

**有 Mac？** → 一条命令：

```bash
bash ios/build_ipa.sh
# → dist/LeapmotorLite-unsigned.ipa
```

然后用 **Sideloadly / AltStore / TrollStore** 用你自己的 Apple ID 重签安装。
完整步骤 + 常见报错 → **[`IPA_BUILD.md`](IPA_BUILD.md)**。

> 说明：iOS 应用只能用 Xcode 工具链编译，Windows / Linux 上做不了。
> 所以本项目提供「云端 macOS runner」和「Mac 一键脚本」两条路，都能产出真正可安装的 `.ipa`。
> 工程文件由 `ios/tools/gen_xcodeproj.py` 用纯 Python 生成，**不依赖 XcodeGen**。

### 2. 装完先跑「算法自检」

`设置 → 诊断 → 算法自检`。会用真实抓包 + 真实链路向量验证
`HMAC-SHA256 / SHA256 / XOR3 / AES-128-CBC / MD5-16 / RSA`：

```
signKey = 7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566
oppwd("4211") = uHTigfMDS5zIuZX4Gq4NVQ==
登录前 SHA256(valueStr) = 066fda165156e717a624dc4c53c7036ecb38a4c0cbd39d4fcb3d6e82c5df0863
```

全绿 = 与官方 App 逐字节一致。（没装 Xcode 也能验：`python client/test_swift_vectors.py`）

### 3. 登录 → 车控

**短信验证码登录（推荐，已实测打通）**：首页输手机号 → 获取验证码 → 填码 → 登录。
App 自动完成「发码 → 换外层 token → 换 JWT → 派生 signKey」四步。

**备用：导入登录态**（100% 可靠，适合调试）：

1. 电脑开抓包工具（Reqable / Proxyman / mitmproxy），手机装证书并信任；
2. 手机打开**官方零跑 App** 完成一次登录；
3. 找到 `POST https://app-gw-global-master.leapmotor.com/base/base-user/account/v1/login` 的**响应体**（含 `accessToken` / `signParam` / `encryptParam`）；
4. 整段复制，粘进 App 的「导入登录态」框 → 点导入。

两条路径都只在本地派生 `signKey`，只把 token + 派生结果存本机 Keychain（不上传）。
再到 `设置 → 操作密码` 填**官方 App 车控时输入的那个操作密码**（4~6 位数字），
然后就能在「车控」页点按钮了。

> 填完密码那一页会立刻显示 `oppwd` 和「本地回解」；回解结果必须等于你输入的密码。
> 车控出问题先看 `设置 → 诊断 → 车控体检`（token 头尾 / 派生 key/iv / oppwd / 上次请求）。
> ⚠️ 操作密码填错 3 次，服务端会锁 5 分钟（`业务错误 70`），App 会自动倒计时禁用按钮。

### 4. 车况信号对照（实测反推）

| 信号 | 含义 |
|---|---|
| `100003` | 剩余电量 %（BMS 原始值，1 位小数）← **电量显示用这个** |
| `1204` | 剩余电量 %（整数，= `round(100003)`） |
| `3257` | 剩余续航 km（主显示） |
| `3260` | 剩余续航 km（另一标准，与 3257 严格成比例 ≈ 1.245） |
| `1318` | 总里程 km |
| `1349` | 车内温度 ℃ |
| `1298` / `3262` | 车门锁状态 |

判定依据（5 个快照线性回归）见 `IPA_BUILD.md` 的「车况信号对照表」。
**注意 `3260` 不是百分比** —— 早期把它当电量读，界面上就出现 `239%`。

---

## 四、Python 参考实现 / 回归校验

```bash
python client/leapmotor_client.py         # 自测：signKey 派生 + oppwd 加密
python client/test_sign_regression.py     # HAR 回归 → 101/105
python client/test_swift_vectors.py       # ★ 校验 Swift 自测里的全部向量（无需 Xcode）
python client/test_coord_vectors.py       # ★ 坐标系换算（WGS-84 ↔ GCJ-02）→ 15/15
python client/derive_signkey.py           # 从登录响应 HAR 现场派生 signKey

# ★ 完整登录链路（会真的发短信）
python client/leapmotor_chain.py send 13800000000        # 第 1 步：发验证码
python client/leapmotor_chain.py run  13800000000 123456 # 第 2~4 步：登录+兑换+派生
```

---

## 五、已知边界

| 项 | 状态 |
|---|---|
| 签名（双模式）/ signKey / oppwd | ✅ 完全还原并验证 |
| 车况 / 车辆列表 / 车控 | ✅ 100% 命中 |
| 电量 / 续航 / 里程 / 温度 / 锁态 | ✅ 信号 id 已用多快照线性回归确认（见上表） |
| 车辆定位（经纬度 + 地图 + 导航） | ✅ `2190/2191`，`3725/3724` 做交叉校验 |
| ↳ 这个坐标**是不是实时**的 | ❌ **不是**。63 个样本（13:25 / 14:04 / 18:02 + 40 分钟连续轮询）里 `2190/2191` **逐字节相同**，而车况其它信号在秒级刷新。signalMap 里**没有第二个 GPS 精度信号**；主二进制里所有 `/v3/api/` 路径中也没有别的定位接口（`chassis/query` 已证实是**底盘图**、`vehicleinfo/parking/query` 是**驻车拍照**）。**所以官方 App 显示的是同一个值 —— 问题在车端。** 页面改为显示「坐标未变化：MM-dd HH:mm 起（N 小时）」 |
| ↳ 车机坐标的**坐标系** | ⚠️ **方向未定** —— 官方 App 两个方向的换算都实现了，静态定不下来。已做成三选一校正（默认 `WGS-84 → GCJ-02`，正好复现「偏 574 米」），站车边上 10 秒可自证。见 `API/LMCoordinate.swift`。★ 注意这只解释**几百米**的偏移，解释不了「跨城市」 |
| 充电信息（距目标电量还要多久） | ✅ `1200` —— 是**纯 SOC 投影** `round(11.33 × (目标 − SOC))`，最小二乘自由拟合出的目标是 **89.8%**，独立对上配置里的 `90`。★ 它**与是否在充电无关**，未充电时也是正数（实测 550） |
| 是否正在充电 | ✅ 已找到 —— 5 个状态位 `100004/1149/1257/3636/3722` 投票 + 充电电流 `1178`。判据来自「充电 vs 未充电」逐信号 diff |
| 充电电流 | ✅ `1178`（充电时 −8.3 A，未充电 0.0） |
| 电池/母线电压（疑似） | ⚠️ `1177` —— **不是功率**（功率未充电时必须为 0，而它是 732.7）。是电压量级的数，具体含义待定，界面已降级标注 |
| `1255` / `1480` / `3638` | ❌ 与充电状态**无区分度**（两个快照都是 2 / 1 / 1），已从候选里剔除 |
| 预约充电配置（时段 / 目标电量 / 重复） | ✅ `commonConfig.config["3"]`（只读，不改车） |
| 电池温度 | ✅ `2183` |
| `parking/query` / `geocode/regeo` 两个端点 | ⚠️ 只有 IPA 字符串表里的路径，参数与响应未验证（诊断页可探测） |
| 短信验证码登录（全 4 步） | ✅ 已实测打通（收到短信 → 换 JWT → signKey → 车控成功） |
| 手机号 RSA 加密 | ✅ 已还原（SPKI→PKCS#1，1024-bit → 140 字节 DER） |
| `smDeviceId`（SM4 国密设备指纹） | ⚠️ 复用抓包值；未还原派生算法（不影响自用） |
| 账号密码登录（`security` 字段） | ⚠️ 已弃用 —— `security` 实为外层 token，改走短信登录 |
| 车控二进制响应（`LMVCloudBinaryPacket`） | ⚠️ 未解析（当前接口都返回 JSON） |
| `cmdid 130`（开关类，语义未知） | ⚠️ 故意不进 UI；只在「设置 → 诊断」里手输下发 |
| `cmdid 161`（只在**查询**里出现过） | ⚠️ 只接了只读的 `appremotectl/getappointment` 探测；从没以「下发」出现过，所以**不进**下发列表 |
| 登录态自动续期（refreshToken） | 未实现；token 约 2h 过期，重新登录即可 |

### 2026-10-08 抓包审计补上的（v1.0.3）

把 5 份 HAR（175 个唯一 `host+path+method`）全部过了一遍，把「**有真实样本、但一直没接**」的东西全接上：

| 项 | 内容 |
|---|---|
| ★ **空调不是三档** | `vehicle/list` 的 `funcConfig.HVAC` 写着 `fan: min=1 max=9 unit=gear`、`temperature: 16~32 °C`。而抓包里 `cmdid 230` 只有 `{"value":"0"\|"2"\|"5"}` —— 所以之前一直以为空调就三档，**实际风量是 1~9 档**。车控页因此新增「空调风量档位（未验证）」卡片（1~9 档可选可下发，明确标注「范围有依据、payload 无样本」），0/2/5 仍留在已验证区 |
| 车辆档案页（新） | 设置 → 功能 → 车辆档案：精确版型 / 66 个能力位 / 固件版本 + OTA 日志 / 功能开关表 / 分享记录 / cmdid 全集 / 模块图 / 3D 车模 / 消息未读 |
| 精确版型 | `carpicture/3d/key` 的 `modelParam.carTypeCode` = `720智尊版 六座`。`vehicle/list` 的 `carConfigEdition` 实测是**空串**，拿不到版型文字 |
| 车机固件 + OTA 日志 | `fota/getCurrentVersion` → `versionNo 4.2614.020`、`updateTime 2026.08.10` + 完整中文更新日志（11 条） |
| 功能开关表 | `commoninfo/getBgConf` → 无感蓝牙钥匙 / 雷达 / 3D 主题 / 挂起恢复 …。**只读**。它直接解释「为什么某些功能在我这台车上没有」（例：`preWakeupByBle=false` = 无感蓝牙没开） |
| 分享记录 + cmdid 全集 | `sharecar/getShareVehicleListByVin` 的 `rightList` 给出 **29 个 cmdid**（本 App 只实现 5 个：110/120/170/230/400，其中 400 属 `moduleRights` 不在 `rightList` 里）。档案页把它们列成路线图，绿=已实现、灰=故意未做 |
| 消息未读 | `msgcenter/leapmotor.cn` 的 `selectmsgcount`（⚠️ 响应只有 `result` 没有 `code`） |
| 手机 IP 归属地 | `apptec.leapmotor.cn` 的 `ipAnalysis/getAddressByIp`。★ 诊断价值大于功能价值：它返回的是**服务端认为手机在哪**，和车端坐标是两个独立来源 —— 实测手机侧 = 淮南（对），车端 = 合肥，一对照就把「定位不对」的责任范围缩到了车端 |
| 记录但**未接入** | `mqtt-center.leapmotor.cn`（MQTT token，要用得先实现 MQTT 客户端）；`iov-api.leapmotor.com` 的 `pointData`（那是官方 App **自己**上报遥测，不是读接口） |

### 五个页面

| Tab | 内容 |
|---|---|
| 车况 | 车辆卡 / 电量环 / 续航·车内温度·总里程 / 状态芯片 / 定位卡 / 充电卡 / 8 个指标磁贴 / 快捷车控 / 全部信号 |
| 定位 | MapKit 地图打点 / CLGeocoder 中文地址 / 坐标（含两组交叉校验）/ **「坐标未变化」新鲜度提示** / **坐标校正（三选一 + 现场自证）** / 一键跳高德与 Apple 地图 / 距我多远 |
| 充电 | 电量环 + 目标电量 / 距目标电量还需多久 + 预计时刻 / **充电判据证据卡（谁投的票）** / 预约充电配置 / 电池温度 / 两套续航与满电估算 / 疑似项专区 |
| 车控 | 按「门锁·后备箱 / 空调 / 灯光 / 电源」分组，会动物理世界的动作带警示标 + 更重的确认文案；另有**空调风量档位（未验证）**卡片 |
| 设置 | 会话 / 操作密码（含 oppwd 现场预览）/ 车辆 / 功能入口（**车辆档案** · 定位 · 充电 · 蓝牙钥匙 · 信号浏览器）/ 诊断 |

**信号浏览器**（设置 → 诊断，或车况页底部）：130 个 signalId 可搜索、带置信度标注与判定依据；
内置**快照 A/B 对比** —— 做动作前后各抓一次，只列出变了的 id。这是识别剩余未知信号的唯一办法。

---

## 文件清单

**打包 / 交付**
- `IPA_BUILD.md` — **打包 IPA 完整指南（GitHub Actions / 本地 Mac / 安装方法）**
- `ios/build_ipa.sh` — 一键打包脚本
- `ios/tools/gen_xcodeproj.py` — 纯 Python 生成 Xcode 工程（不依赖 XcodeGen）
- `ios/tools/make_icon.py` — 生成 App 图标
- `ios/tools/pack_source.py` — 打包源码 zip（传到 Mac / 推 GitHub）
- `.github/workflows/build-ipa.yml` — 云端打包流水线

**iOS 交付**
- `ios/LeapmotorLite/` — SwiftUI 车控 App（29 个 Swift 文件 + Info.plist + Assets.xcassets）
- `ios/LeapmotorLite/LeapmotorLite/LMBuildInfo.swift` — ★ 构建标识（版本号 + 构建 tag + git 提交号），解决「分不清装的是哪一版」
- `ios/LeapmotorLite/LeapmotorLite/Views/Theme.swift` — 统一配色 + 复用组件（卡片 / 磁贴 / 电量环 / 充电状态胶囊 / 秒级时钟）
- `ios/LeapmotorLite/LeapmotorLite/API/LMCoordinate.swift` — ★ 坐标系换算（WGS-84 ↔ GCJ-02）+ 三选一校正策略 + 4 项自检
- `ios/LeapmotorLite/LeapmotorLite/Views/LocationView.swift` — 车辆定位（MapKit + CLGeocoder + 导航 + 坐标校正卡）
- `ios/LeapmotorLite/LeapmotorLite/Views/ChargeView.swift` — 充电信息（距目标电量还需多久 / 充电判据证据卡 / 预约充电 / 疑似项专区）
- `ios/LeapmotorLite/LeapmotorLite/Views/SignalExplorerView.swift` — 信号浏览器 + 快照 A/B 对比
- `ios/LeapmotorLite/LeapmotorLite/Views/BLEKeyView.swift` — ★ 蓝牙钥匙（云端钥匙记录 / 行为开关 / 接口探测 / 协议进度）
- `ios/LeapmotorLite/LeapmotorLite/Views/BLEDebugView.swift` — ★ BLE 调试台（扫描 / GATT 树 / 订阅抓帧 / 发原始字节）
- `ios/LeapmotorLite/LeapmotorLite/BLE/LMBLEProtocol.swift` — ★★ BLE 协议知识库（UUID / ECDH 字段 / 帧模板 / 逆向证据全记录）
- `ios/LeapmotorLite/LeapmotorLite/BLE/LMBLECentral.swift` — CoreBluetooth 封装（queue: nil 保主线程）
- `ios/LeapmotorLite/LeapmotorLite/BLE/LMBLEKeyModels.swift` — 钥匙记录 / 行为开关 / 探测结果 / 帧自检
- `ios/LeapmotorLite/LeapmotorLite/API/LMSignalCatalog.swift` — ★ 信号 id → 语义知识库（带置信度与判定依据）
- `ios/LeapmotorLite/LeapmotorLite/Store/LMLocationProvider.swift` — 本机定位（只用于「距我多远」）
- `ios/LeapmotorLite/LeapmotorLite/Views/DiagnosticsView.swift` — 车控体检（oppwd / token / 上次请求 / 接口探测 / 蓝牙钥匙接口 / 未验证 cmdid）
- `ios/tools/lint_swift.py` — ★ Swift 陷阱静态检查（R1~R11，CI 里会跑）
- `ios/LeapmotorLite/README.md` — 编译 / 使用 / 协议文档

**逆向与分析**
- `evidence/FINDINGS_CRYPTO.md` — **完整协议分析报告（签名 / signKey / oppwd / 登录链路）**
- `client/leapmotor_client.py` — Python 参考实现（签名已还原）
- `client/leapmotor_chain.py` — ★ 完整登录链路（发码 / 登录 / 兑换 / 派生）
- `client/test_sign_regression.py` — HAR 签名回归
- `client/test_swift_vectors.py` — Swift 自测向量回归（无需 Xcode）
- `client/test_coord_vectors.py` — ★ 坐标系换算回归（独立实现比对 + 回头读 Swift 源码文本，钉住「默认校正不是 .none」）
- `client/ios_clsmeth.py` / `ios_scan_login.py` / `ios_cfref.py` — Mach-O / ObjC 逆向工具（元类方法表 / CFF 扫描 / CFString 交叉引用）
- `client/objc_parse.py` / `macho_util.py` — Mach-O / ObjC 基础解析

**抓包辅助**
- `capture/CAPTURE_SOP_IOS.md` — iOS 抓包 SOP
- `frida/ios_ssl_bypass.js` — 绕 SSL Pinning（越狱机）
- `app/` — 早期网页版（历史产物，已停用）
