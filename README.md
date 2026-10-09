# 零跑轻控 · 第三方干净客户端（iOS）

> 无广告、纯功能、本地直连的零跑车控 App。
> 核心 = **协议逆向**（签名/加密算法已完整还原并回归验证）+ **干净原生前端**（自己写的 UIKit）。
>
> ⚠️ 只用**你自己账号**控制**你自己名下的车**。车控是安全敏感接口，
> 别做越权 / 批量 / 代控 / 分享账号的事。逆向仅用于互操作（自用），请自行评估官方用户协议。

**交付物 → [`ios/LeapmotorLite/`](ios/LeapmotorLite/)**（Swift / UIKit，iOS 17+，零第三方依赖）

**当前版本：`1.1.9 (20)`** · 最近更新 2026-10-09 —— **充电判据再加一道硬门槛**：上一版把「车辆通电 / 开哨兵模式时错误显示充电中」的判据从「5 路标志位投票」改成「只看充电电流 `1178`」，但用户补的抓包证明**通电（未插枪）时 `1178` 是 `0.2~0.3 A` 而不是 0**（高压系统漏电流），「非零」这个门槛**照样误报** —— 现在新增 `chargeCurrentThreshold = 1.0 A` 的量级门槛（熄火 `0.0` / 通电·哨兵 `0.2~0.3` / 真充电 `8.3`，两头留余量），电流显示与功率计算一并套门槛，不再出现 `0.20 A` 的假功率。预约充电 payload 的键名修复沿用上一版（`chargesoc` / `chargeEnable` 两套都带）（[版本历史](#六版本历史)）

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
| **登录态自动续期** | `POST /base/base-user/token/v1/refresh`，**签名叫 HMAC**（不是登录那种 SHA256） | ✅ 实测 token 不再 2h 掉线 |
| **充电四个 cmdid** | `190` 上限 / `193` 立即·结束 / `480` 健康充电 / `161` 预约 —— **全部从官方主二进制反汇编解出** | ✅ 指令地址可查（[见下](#充电-cmdid反汇编实证)） |

**回归结果**：`har_appgw.har` 里 105 个带 `sign` 的请求 → **101 MATCH**。
未命中的 4 条全部是车控链之外的边缘接口（`pointData` 是 protobuf 二进制体 /
`updateDeviceInfo` 设备注册 / `login` 请求本身用另一套签名），
详见 [`evidence/FINDINGS_CRYPTO.md`](evidence/FINDINGS_CRYPTO.md) §10–§12。

> **关键坑**：`/base/base-user/account/v1/login`（换 token）必须用 **SHA256 无密钥**签名；
> 用 HMAC 会一直得到 `302002002 签名信息校验失败`。
> `check_login_with_phone` 必须是 **form-urlencoded**，用 JSON 会得到 `1019 参数不能为空`。

完整算法与端点表 → **[`ios/LeapmotorLite/README.md`](ios/LeapmotorLite/README.md)** 与 **[`evidence/FINDINGS_CRYPTO.md`](evidence/FINDINGS_CRYPTO.md)**。

### 充电 cmdid（反汇编实证）

抓包里 `POST /carownerservice/v3/api/appremotectl` 的 cmdid **只有** 110/120/130/170/230/400
（充电四个一个样本都没有 —— 抓包期间没人点过充电页），所以只能反汇编官方主二进制：

| cmdid | 官方 selector | 语义 | 调用点 |
|---|---|---|---|
| **190** | `requestForChargingSetContent:` | 充电上限 | `0x106C5F09C` |
| **193** | `requestForBeginOrEndChargingWithContent:` | 立即 / 结束充电 | `0x106C5F250` |
| **480** | `requestForChargingHealthControl:` | 健康充电开关 | `0x106C5EF38` |
| **161** | `requestForAppointmentContrlCmdID:content:` | 预约充电 | `0x106C5EF54` |

交叉验证：`sharecar/getShareVehicleListByVin` 的 `rightList` 里 **190 排第一位**，
193/161/480 都在 —— 与反汇编完全吻合。

> ⚠️ 预约充电是「多对一」：**161 / 171 / 361 / 392** 四个 cmdid 共用同一分支体
> `0x106C5EF48`。本 App 只用 161。

**可复现**：`python client/ios_charge_cmdid.py evidence/leapmotor_main`
会把四个 cmdid + 四个 stub + 四个调用点全部重算并断言一致（脚本自带纯 stdlib 的
chained-fixups 解码，不依赖 lief）。官方换版本时它会报红。

完整记录 → [`evidence/charging/FINDINGS_CHARGING.md`](evidence/charging/FINDINGS_CHARGING.md)

### ★ cmdid 全表（42 个，反汇编实证）

官方主二进制 `leapmotorCarOwner`（204 MB、arm64、未加密）里有一个 **cmdid 分派函数**
（`0x106C5EE00` 起），形态是 `cmp x23, #imm` + 分支构成的二分查找树；每个分支体里调一个
`objc_msgSend$requestForXxx:` stub。把 stub 反解成 selector 名、再往前回溯出那个 `imm`，
就得到完整的 cmdid → selector 映射：

```bash
python client/ios_all_cmdids.py evidence/leapmotor_main    # 16 秒，解出 42 个
```

**为什么这张表比 `rightList` 权威**：`rightList` 是服务端下发的**分享授权清单**（29 个），
少了 15 个（111 / 180 / 240 / 270 / 280 / 300 / 350 / 380 / 390 / 391 / 400 / 501 / 600 / 700 / 710 / 720）。
本表是从**客户端代码**里解出来的，是「App 能发什么」的完整集合。

| cmdid | 官方 selector | 语义 | 有 state 样本 |
|---|---|---|---|
| 110 | `requestForCarLockControl:` | 车门锁 | ✅ |
| 120 | `requestForCarTracking` | 鸣笛寻车 | ✅ |
| 130 | `requestForTrunkControl:` | 后备箱 | ✅ |
| 170 | `requestForAirConditionControl:content:` | 空调 | ✅ |
| 230 | `requestForWindowControl:` | 车窗 | ✅ |
| 400 | `requestForCarSentineMode:` | **哨兵模式**（不是上电） | ✅ |
| 111 | `requestForSlideDoorControl:content:` | 侧滑门 | ❌ |
| 131 | `requestForFrunkControl:` | **前备箱**（v1.1.7 已接） | ❌ |
| 150 | `requestForOpenOn3ForAutoPark` | 泊车辅助上电 | ❌ |
| 160 | `requestForStartPTC` | 电池预热 | ❌ |
| 161 / 171 / 361 / 392 | `requestForAppointmentContrlCmdID:content:` | 预约充电（四值共用分支体） | ❌ |
| 180 | `requestForSynPathContent:` | 同步导航路径 | ❌ |
| 190 | `requestForChargingSetContent:` | 充电上限 | ❌ |
| 192 | `requestForUnlockChargingGun` | 解锁充电枪 | ❌ |
| 193 | `requestForBeginOrEndChargingWithContent:` | 立即 / 结束充电 | ❌ |
| 240 | `requestForSunShadeControl:` | 遮阳帘 | ❌ |
| 270 | `requestForMusicContent:` | 音乐 | ❌ |
| 280 | `requestForSeatAdjustCtrlContent:` | 座椅调节 | ❌ |
| 300 | `requestForSunroofControl:content:` | 天窗 | ❌ |
| 301 | `requestForSeatHeatingContent:` | 座椅加热 | ❌ |
| 320 | `requestForSteeringWheelHeatControl:` | 方向盘加热 | ❌ |
| 350 | `requestForAutoParkProcessControl:` | 泊车辅助 | ❌ |
| 360 | `requestForOneKeyPrepareCarContent:` | 一键备车 | ❌ |
| 370 | `requestForSeatWindContent:` | 座椅通风 | ❌ |
| 380 | `requestForFuelHeatControl:` | 燃油加热器 | ❌ |
| 390 / 391 | `requestForDownloadFOTA:` / `requestForInstallFOTA:` | FOTA 下载 / 安装 | ❌ |
| **410** | `requestForOpenOn3` | **上电**（无样本，故意不接） | ❌ |
| 421 | `requestForLineCall` | 直进直出 | ❌ |
| 430 | `requestResetBLEController` | 重置蓝牙钥匙 | ❌ |
| 440 | `requestForMirrorHeatingControl:` | 后视镜加热 | ❌ |
| 470 | `requestFor6SeatControl:` | 六座座椅控制 | ❌ |
| 480 | `requestForChargingHealthControl:` | 健康充电 | ❌ |
| 500 / 501 | `requestForFridgeControl:content:` / `…setCmdID:` | 车载冰箱（501 带子指令） | ❌ |
| 600 | `requestForChildControl:content:` | 儿童锁 | ❌ |
| 700 | `requestForOxygenControl:` | 森野氧舱 | ❌ |
| 710 | `requestForWakeUpCarControl` | 唤醒车辆 | ❌ |
| 720 | `requestForWelcomeControl:` | 上车迎宾 | ❌ |

> ⚠️ **语义清楚 ≠ 可以直接下发**。`state` 的字段形状没有样本的，一律只进
> App 内「设置 → 诊断 → 官方 cmdid 全集」（可点击预填 + payload 候选字段名提示），
> 不放到车控页当正常按钮。

### 官方本地化表（挖关键词的入口）

官方 `leapmotorCarOwner.app/LMVLocalizedBundle.bundle/zh-Hans.lproj/Localizable.strings`
是**二进制 plist**，669 条。它是「官方有哪些功能」最直接的一份清单：

| 前缀 | 条数 | 内容 |
|---|---|---|
| `CarHome_*` | 101 | 爱车页全部功能名（`SentinelMode`=哨兵模式 / `CarStandby`=一键备车 / `Welcome`=上车迎宾 / `LineCall`=直进直出 / `Frunk`=前备箱 / `SkyLight`=天窗 / `Sunshade`=遮阳帘 / `Slide`=侧滑门 / `Oxygen`=森野氧舱 / `BatteryPreheate`=电池预热 / `CarPhoto`=驻车照片） |
| `RemoteControl_*` | 54 | **全是「车辆行驶中/已启动，XX 无法操作」的前置校验文案** —— 反推出官方支持的全部远程功能 |
| `ChargingCenter_*` | 41 | `Voltage`=电压 / `Current`=电流 / `Power`=功率 / `BindPile`=绑桩 / `OptimalLimit90` / `UnlockGun`=解锁充电枪 |
| `LMV_AC_*` | — | `circleIn`=内循环 / `circleOut`=外循环 / `cold` / `hot` / `soonCold`=极速降温 / `soonHot`=极速升温 / `autoWind`=快速除味 / `timingACOut`=定时空调 |

已提取为可读 JSON：`evidence/official/LMV_zh-Hans.json`。

---

## 二、目标平台：iOS（已完成）

逆向目标：官方 iOS App `com.leapmotor.developer` **v1.22.68**（已解密 IPA）。

> Android 包 `com.dahua.leapmotor` 是 **360 加固**（`classes.dex` 是壳，
> 登录/签名相关字符串 0 命中），逆向成本极高 —— **已放弃 Android 路线**。
> iOS 主二进制 + Metro JS bundle 是明文的，算法直接可读。

| 目录 | 作用 |
|---|---|
| **`ios/LeapmotorLite/`** | **最终交付：UIKit 干净车控 App（签名/加密全实现 + 内置自检）** |
| `client/` | Python 参考实现（签名/派生/回归校验）+ Mach-O 逆向工具 |
| `evidence/` | 原始 IPA、抓包 HAR、扫描结果、**各模块 FINDINGS_*.md 分析报告** |
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

同一页还有「构建版本」自检 —— 会显示当前 `1.0.9 (10)` + 构建 tag + git 提交号，
用来回答「我装的到底是哪一版」。

### 3. 登录 → 车控

**短信验证码登录（推荐，已实测打通）**：首页输手机号 → 获取验证码 → 填码 → 登录。
App 自动完成「发码 → 换外层 token → 换 JWT → 派生 signKey」四步。
token 会自动续期，**登录一次不用再登**（对齐官方 App 行为）。

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
python client/test_sign_regression.py     # HAR 回归 → 101/105（4 条偏差是已知边缘接口）
python client/test_swift_vectors.py       # ★ 校验 Swift 自测里的全部向量（无需 Xcode）→ 11/11
python client/test_coord_vectors.py       # ★ 坐标系换算（WGS-84 ↔ GCJ-02）→ 15/15
python client/test_refresh_contract.py    # ★ 契约测试：续期 / 3D 车模 / 爱车页 / 定位 / 充电中心
python client/ios_charge_cmdid.py evidence/leapmotor_main   # ★ 重算充电四个 cmdid 并断言一致
python client/derive_signkey.py           # 从登录响应 HAR 现场派生 signKey

# ★ 完整登录链路（会真的发短信）
python client/leapmotor_chain.py send 13800000000        # 第 1 步：发验证码
python client/leapmotor_chain.py run  13800000000 123456 # 第 2~4 步：登录+兑换+派生
```

`test_refresh_contract.py` 是**唯一能挡住「静默失效」的一层** ——
它盯的是那些**编译器抓不到**的改动，例如：有人觉得 `/base/base-user` 前缀多余顺手删掉
（续期静默失效）、给 `LMSession` 加一个非 Optional 字段（升级即掉登录）、
把充电 cmdid 改错一个数字（指令发出去但车端按另一个语义执行）。

---

## 五、已知边界

| 项 | 状态 |
|---|---|
| 签名（双模式）/ signKey / oppwd | ✅ 完全还原并验证 |
| 车况 / 车辆列表 / 车控 | ✅ 100% 命中 |
| 电量 / 续航 / 里程 / 温度 / 锁态 | ✅ 信号 id 已用多快照线性回归确认（见上表） |
| **车辆定位** | ✅ 主显示改用 **IP 归属地**（`ipAnalysis/getAddressByIp`，与官方 App 同源）；车机坐标 `2190/2191` 降为附注 |
| ↳ 车机坐标 `2190/2191` | ❌ **不是实时位置**。5 份 HAR 里 **60 个含 signalMap 的快照全部包含这对坐标，值逐字节相同**（`31.801201/117.342718`，指向合肥），而车况其它信号在秒级刷新。signalMap 里没有第二个 GPS 精度信号；主二进制里 71 条 `v3/api/` 路径中也没有别的定位接口 |
| ↳ 为什么以前显示错城市 | 早期把车机静态坐标当位置 → 显示合肥。官方显示的是**手机 IP 归属地**（实测淮南）。已修正，并把车机坐标降级为附注 |
| ↳ 坐标**坐标系**方向 | ⚠️ 未定 —— 官方 App 两个方向的换算都实现了，静态定不下来。已做成三选一校正（默认 `WGS-84 → GCJ-02`，正好复现「偏 574 米」）。★ 这只解释**几百米**偏移，解释不了「跨城市」 |
| 充电信息（距目标电量还要多久） | ✅ `1200` —— 是**纯 SOC 投影** `round(11.33 × (目标 − SOC))`，最小二乘自由拟合出的目标是 **89.8%**，独立对上配置里的 `90`。★ 它**与是否在充电无关**，未充电时也是正数（实测 550） |
| 是否正在充电 | ✅ 5 个状态位 `100004/1149/1257/3636/3722` 投票 + 充电电流 `1178`。判据来自「充电 vs 未充电」逐信号 diff |
| 充电电流 | ✅ `1178`（充电时 −8.3 A，未充电 0.0） |
| **充电中心（可写）** | ✅ 立即/结束充电（193）、健康充电（480）、充电上限（190）、预约充电（161）全部可下发。cmdid 来自反汇编，state 字段按证据分级（见下） |
| ↳ 立即充电的 `Begin_Charge` 取值类型 | ⚠️ **无样本** —— 字段名有据（主二进制字符串表），但车端要 `1/0` 还是 `true/false` 未知。同时带了 `Begin_Charge` + `recharge` 两个键兜底，**待真机验证** |
| ↳ 充电上限 `percent` vs `chargesoc` | ⚠️ 两个都发，哪个真被车端读未验证 |
| ↳ 预约充电保存后车端是否照做 | ⚠️ `appremotectl/getappointment` 返回的 `data` 是**空串**，只能间接从 `commonConfig.config["3"]` 观察是否回写 |
| 预约充电配置（只读回填） | ✅ `commonConfig.config["3"]`（`beginTime`/`endTime`/`percent`/`isEnable`/`cycles`/`circulation`/`recharge`，写回时用同一套原名） |
| 健康充电开关初值 | ✅ `healthyCharging/queryPushState` → `{"isPush":false}` |
| 电池温度 | ✅ `2183` |
| 电池/母线电压（疑似） | ⚠️ `1177` —— **不是功率**（功率未充电时必须为 0，而它是 732.7）。是电压量级的数，具体含义待定，界面已降级标注 |
| `1255` / `1480` / `3638` | ❌ 与充电状态**无区分度**（两个快照都是 2 / 1 / 1），已从候选里剔除 |
| `parking/query` / `geocode/regeo` | ⚠️ 只有 IPA 字符串表里的路径，参数与响应未验证（诊断页可探测） |
| 驻车照片（官方地图卡里的那张） | ❌ **未复刻**。抓包里没有任何接口返回驻车照片或停车点（`getAppImage` 是胎压示意图、`chassis/query` 是底盘图）。可能走 MQTT，需打开该卡片时重新抓包 |
| 短信验证码登录（全 4 步） | ✅ 已实测打通（收到短信 → 换 JWT → signKey → 车控成功） |
| 手机号 RSA 加密 | ✅ 已还原（SPKI→PKCS#1，1024-bit → 140 字节 DER） |
| 登录态自动续期 | ✅ 已实现（HMAC 签名，与登录的 SHA256 不同） |
| `smDeviceId`（SM4 国密设备指纹） | ⚠️ 复用抓包值；未还原派生算法（不影响自用） |
| 车控二进制响应（`LMVCloudBinaryPacket`） | ⚠️ 未解析（当前接口都返回 JSON） |
| `cmdid 130`（后备箱） | ✅ **已实现**（车控页「打开/关闭后备箱」）。语义靠**双向实测**确认：发 `{"value":"true"}` → signal `1281` 0→1；发 `false` → 1→0 |
| `cmdid 171` / `361` / `392`（预约族另三个码） | ⚠️ 反汇编确认它们与 161 共用分支体，但**没接** —— 用 161 就够了，多接只会增加不确定性 |
| `cmdid 131` / `150` / `160` / `192` / `220` / `240` / `301` / `320` / `340` / `360` / `370` / `410` / `420` / `421` / `430` / `440` / `470` / `500` | ⚠️ 在 `rightList` 里（29 个），但**没有 payload 样本**，故意不接。车辆档案页把它们列成路线图（绿=已实现、灰=故意未做）。**例外：131（前备箱）v1.1.7 已接** —— 见下 |

### 本 App 已实现的 cmdid（11 个）

| cmdid | 功能 | 证据来源 |
|---|---|---|
| 110 | 门锁（开/锁） | 抓包双向（signal `1298`） |
| 120 | 鸣笛寻车 | 抓包 |
| 130 | 后备箱（开/关） | 抓包双向（signal `1281`） |
| 131 | 前备箱（开/关） | ⚠️ **反汇编 + 同族推断**（`requestForFrunkControl:`，与 130 形态一致），**无 payload 样本** |
| 170 | 空调（开/关/auto） | 抓包双向（signal `1938`） |
| 230 | 车窗（开度 0/2/5） | 抓包双向（signal `1693~1696` 四窗同动） |
| 400 | **哨兵模式**（★ 原写「上电」，v1.1.7 纠正） | 抓包（`{"operation":"on"}`）+ 反汇编 `requestForCarSentineMode:` |
| **190** | **充电上限** | **反汇编**（无抓包样本） |
| **193** | **立即 / 结束充电** | **反汇编**（无抓包样本） |
| **480** | **健康充电开关** | **反汇编** + 查询接口实测 |
| **161** | **预约充电** | **反汇编** + `config["3"]` 字段名实测 |

> ★ **上电是 410**（`requestForOpenOn3`），不是 400。410 没有 payload 样本，
> 故意不接 —— 上电会真的让车「活过来」，猜错代价太大。
> 400 与 410 的区分来自 v1.1.7 对官方主二进制 cmdid 分派器的**全量反汇编**
> （`client/ios_all_cmdids.py`，一次解出 **42 个** cmdid → selector）。

### state 字段的分级证据（不混为一谈）

分派器只传 `cmdid + content`，**content 的字段名在调用方构造，反汇编这一段拿不到**。
所以每个字段单独标来源：

| 动作 | 字段 | 证据等级 |
|---|---|---|
| 预约充电 | `beginTime` `endTime` `percent` `isEnable` `cycles` `circulation` `recharge` | **最高** —— 服务端 `config["3"]` 实测原名，读什么写什么 |
| 健康充电 | `isPush` | **高** —— 查询接口实测返回 |
| 充电上限 | `percent` + 冗余 `chargesoc` | **中高** —— `percent` 是实测名 |
| 立即 / 结束 | `Begin_Charge` + 冗余 `recharge` | **中** —— 字段名有据、取值类型无样本 |

### 2026-10-08 抓包审计补上的（v1.0.3）

把 5 份 HAR（**808 个请求条目 / 187 个唯一 `host+path+method`**）全部过了一遍，
把「**有真实样本、但一直没接**」的东西全接上：

| 项 | 内容 |
|---|---|
| ★ **空调不是三档** | `vehicle/list` 的 `funcConfig.HVAC` 写着 `fan: min=1 max=9 unit=gear`、`temperature: 16~32 °C`。而抓包里 `cmdid 230` 只有 `{"value":"0"\|"2"\|"5"}` —— 所以之前一直以为空调就三档，**实际风量是 1~9 档**。车控页因此新增「空调风量档位（未验证）」卡片（1~9 档可选可下发，明确标注「范围有依据、payload 无样本」），0/2/5 仍留在已验证区 |
| 车辆档案页（新） | 设置 → 功能 → 车辆档案：精确版型 / 66 个能力位 / 固件版本 + OTA 日志 / 功能开关表 / 分享记录 / cmdid 全集 / 模块图 / 3D 车模 / 消息未读 |
| 精确版型 | `carpicture/3d/key` 的 `modelParam.carTypeCode` = `720智尊版 六座`。`vehicle/list` 的 `carConfigEdition` 实测是**空串**，拿不到版型文字 |
| 车机固件 + OTA 日志 | `fota/getCurrentVersion` → `versionNo 4.2614.020`、`updateTime 2026.08.10` + 完整中文更新日志（11 条） |
| 功能开关表 | `commoninfo/getBgConf` → 无感蓝牙钥匙 / 雷达 / 3D 主题 / 挂起恢复 …。**只读**。它直接解释「为什么某些功能在我这台车上没有」（例：`preWakeupByBle=false` = 无感蓝牙没开） |
| 分享记录 + cmdid 全集 | `sharecar/getShareVehicleListByVin` 的 `rightList` 给出 **29 个 cmdid**，档案页把它们列成路线图，绿=已实现、灰=故意未做 |
| 消息未读 | `msgcenter.leapmotor.cn` 的 `selectmsgcount`（⚠️ 响应只有 `result` 没有 `code`） |
| 手机 IP 归属地 | `apptec.leapmotor.cn` 的 `ipAnalysis/getAddressByIp`。★ 诊断价值大于功能价值：它返回的是**服务端认为手机在哪**，和车端坐标是两个独立来源 —— 实测手机侧 = 淮南（对），车端 = 合肥，一对照就把「定位不对」的责任范围缩到了车端。**现在它已经是「车辆位置」的主显示源** |
| 记录但**未接入** | `mqtt-center.leapmotor.cn`（MQTT token，要用得先实现 MQTT 客户端）；`iov-api.leapmotor.com` 的 `pointData`（那是官方 App **自己**上报遥测，不是读接口） |

---

## 六、版本历史

每次出包都会同时改 `LMBuildInfo.swift` 的 `tag` 和 `Info.plist` 的版本号，
`设置 → 设备 → 本 App 构建` 里能看到「版本号 + 这一版干了什么 + git 提交号」。

| 版本 | tag | 内容 |
|---|---|---|
| **1.1.9 (20)** | `2026-10-09.13` | **充电判据再加一道硬门槛（上一版没修透）**。「车辆通电 / 开哨兵模式时错误显示充电中」这个 bug，上一版（1.1.8）把判据从「5 路标志位多数票 ≥ 3」换成「只看充电电流 `1178`」，但用户随后补的抓包（`appgateway.leapmotor.com_2026_10_09_23_54_14.har`）证明：**车辆通电、未插枪时 `1178` 并不是 0，而是 `0.2 ~ 0.3 A`**（高压系统工作时的漏电流 / 采样偏置）—— 所以「电流非零」这个门槛**照样会误报**。同一份抓包还把误报机制钉死了：通电时那 5 路标志位恰好是 `100004=1 1149=0 1257=1 3636=0 3722=1`（**恰好 3 票**），加上 `1178 = 0.2`（非零），老判据的两个条件**同时**被满足。现在判据升级为「**电流达到充电量级**」—— 新增 `chargeCurrentThreshold = 1.0 A`（同一台车三个实测量级：熄火停放 `0.0` / 通电·哨兵 `0.2~0.3` / 7 kW 慢充 `−8.299`；阈值比噪声高 3.3 倍、比真充电低 8 倍），`chargeCurrentA` 与 `chargePowerKW` 一并套门槛，不再把 `0.20 A` 显示成 `0.17 kW` 的假功率。顺带：`1177` 新增 `827.0 V @ SOC 82.9%` 实测点，**坐实它是「电池包电压」**（随 SOC 单调抬升：33.0%→736.7 / 41.4%→732.7 / 82.9%→827.0）。预约充电 payload 的键名修复沿用 1.1.8（`chargesoc` / `chargeEnable` 两套键名都带），仍标注为**推断**（手上没有官方保存预约充电的抓包），诊断页三条候选供真机试。 |
| **1.1.8 (19)** | `2026-10-09.12` | **修两个用户报的 bug**（都在充电中心）。①「**车辆通电使用 / 开启哨兵模式时错误显示充电中**」—— 根因是**判据选错了**：老代码拿 `100004 / 1149 / 1257 / 3636 / 3722` 五路信号投票（`≥ 3` 即判「充电中」），但那五路其实是「**高压系统激活**」位（车辆 READY / 哨兵 / 充电都会点亮）—— 当初的对照样本只有「熄火停放 vs 插枪充电」两种工况，**没有「通电 / 哨兵」这一组**，才把「高压系统在工作」误读成「在充电」。现在判据换成**充电电流 `1178` 单条硬门槛**（没电流就一定没有电进电池；`1178` 缺失时返回「待确认」而不是猜）；那五路降级为 `highVoltageActive`，只用来提示「高压系统在工作」。②「**保存预约充电报下发失败**」—— 根因是 **payload 键名用错了一套**：官方写接口的键名是 `chargesoc` / `chargeEnable`（来自主二进制字符串池 `LMVChargingAppointment.chargesoc.chargeEnable.recharge.cycles.circulation.Begin_Charge`），而老 payload 只带了 `config["3"]` 的**读取**键名（`percent` / `isEnable`）—— 恰好缺的就是那两个。现在**两套键名都带**。另外：车控失败时**把服务端原始响应写进错误提示**（以前只有「下发失败」四个字，看不到 code / message）；诊断页新增**「预约充电 payload 候选」一键预填**（三种有依据的形状，点一下填进探测框，哪种返回 msgID 哪种就对）。 |
| **1.1.7 (18)** | `2026-10-09.11` | **反汇编解出官方 cmdid 全表（42 个）**：把主二进制里那个 `cmp x23, #imm` 二分派发器整段扫完，反解 `__objc_stubs` 得到 cmdid → 官方 selector 映射（`client/ios_all_cmdids.py`，16 秒跑完，原始输出落盘 `evidence/official/cmdid_table.txt`）。**据此修一个语义错误**：`400` 是**哨兵模式**（`requestForCarSentineMode:`），不是「上电」——原代码 `"hello": Command(cmdid: 400, title: "上电")` 是错的，改成 `sentinel` / 「哨兵模式」/ `risk: .low`；**上电是 410**（`requestForOpenOn3`），无 payload 样本故不接。新增**前备箱 131 开/关**（`requestForFrunkControl:`，payload 按 130 同族推断）。新增**充电功率**显示 —— 依据是官方本地化表里充电中心的 `ChargingCnter_Voltage / _Current / _Power` 三键；`packVoltageGuessV` 改名 `chargeVoltageV`，新增派生值 `chargePowerKW = 1177 × 1178 / 1000`（≈6.19 kW，与 7 kW 交流慢充吻合）。诊断页新增**「官方 cmdid 全集」卡**（42 行可点击预填 + payload 候选字段名提示）。顺带校正 Python 侦察端的 `CTRL_COMMANDS`（原来 120 标后备箱、170 标大灯、230 标空调、400 标上电，全错）与 `app/index.html` 的按钮。 |
| **1.1.6 (17)** | `2026-10-09.10` | **修两个用户报的 bug**：①「驻车照片获取报下载失败」—— 车端返回的 OSS 直链**是明文 `http://`**，而 `NSAllowsArbitraryLoads=false` 时 ATS 会直接掐掉这条请求；修法是给 `aliyuncs.com` 开一条**窄口径**明文例外 + 代码优先把 scheme 换成 https 再试（OSS 支持 https，且 scheme 不参与签名），失败回退原地址，并把真实原因显示出来。②「健康充电读取开关状态没反应」—— `refreshHealthyCharging()` 把异常整个吞掉（`catch { return nil }`），且成功时值没变界面也不会动，点下去毫无反馈；现在把「读取中 / 服务端原始值 + 读取时间 / 出错原因」都写进卡片，并在动作前后各显式 `render()` 一次。
| **1.1.5 (16)** | `2026-10-09.9` | **定位与驻车照片**：定位页撤掉「当前位置（IP 归属地）」卡，改成**本机 GPS 位置**与**车辆位置**并列显示；新增**驻车照片**（`chassis/query` → `data.fileUrl`，地下停车场俯视哨兵照，点缩略图可全屏看车位号）；修**健康充电显示错误**（根因是 `deviceId` 每次启动都随机生成，而 `queryPushState` 按 `carvin + deviceId` 查设备状态 —— 服务端把本机当陌生设备，一律回 `false`）；车控页补上右上角感叹号的图例说明 |
| **1.1.4 (15)** | `2026-10-09.8` | **视觉重设计「碳黑霓虹」**：近黑底 + 实心深灰卡 + 发丝描边 + 等宽大数字 + 单一薄荷霓虹点缀；全 App **锁定深色外观**；爱车页完整落地（等宽大数字 / 圆角方形快捷钮 / SOC 渐变辉光 / 车底辉光），其余页随主题层自动换肤；新增 lint `R18`/`R19` |
| 1.1.3 (14) | `2026-10-09.7` | **UIKit 迁移 Phase 3~6（收尾）**：剩余 11 页（爱车 / 定位 / 充电 / 车控 / 车辆档案 / 蓝牙钥匙 / 车控体检 / 信号浏览器 / 算法自检 / BLE 调试台 / 3D 看车）全部换成原生 UIKit，**SwiftUI 页面清零**；过渡桥 `LMHostingController` 与 `Views/` 目录整体删除 |
| 1.1.2 (13) | `2026-10-09.6` | UIKit 迁移 Phase 2：设置页换成原生 UIKit；解决「UIKit 页 push SwiftUI 页」的导航栏冲突（`ownsNavigationBar`） |
| 1.1.1 (12) | `2026-10-09.5` | UIKit 迁移 Phase 1：登录页换成原生 UIKit（`LMLoginViewController`），确立「继承 `LMBaseViewController` + 只覆盖 `buildUI()`/`render()`」的迁移样板 |
| 1.1.0 (11) | `2026-10-09.4` | UI 框架从 SwiftUI 换成 UIKit（Phase 0 换壳）：入口改成 `AppDelegate` + `window`，未迁移的页面暂由 `UIHostingController` 托住，行为与上一版一致 |
| **1.0.9 (10)** | `2026-10-09.3` | **充电中心可写**（立即/结束 193、健康充电 480、上限 190、预约 161，cmdid 全部反汇编实证）+ **3D 车模放大上移**（230→330，去卡片底色与页面背景融合） |
| 1.0.8 (9) | `2026-10-09.2` | **定位改用 IP 归属地**（与官方 App 同源），车机坐标降级为附注；复刻官方「车端已关闭位置数据分享」提示 |
| 1.0.7 (8) | `2026-10-09.1` | **爱车页完整复刻**（官方「爱车」Tab 的 9 个模块）；`Car3DConfig.serverJSON` 补 `@MainActor` 修 CI |
| 1.0.6 (7) | `2026-10-08.5` | **3D 看车**：内置官方车模离线包（three.js + FBX，17 MB / 63 文件），内嵌爱车页可全方位旋转；续期签名改 HMAC |
| 1.0.5 (6) | `2026-10-08.4` | **refreshToken 自动续期** —— token 不再 2 小时就掉线 |
| 1.0.4 (5) | `2026-10-08.3` | 修正 `cmdid 170/230` 语义（170=空调、230=车窗）；空调风量 1~9 档 / 温度 16~32 ℃；车窗微开/半开 |
| 1.0.3 (4) | `2026-10-08.2` | 抓包审计补齐：车辆档案页 / 空调档位 / 一批漏掉的接口 |
| 1.0.2 (3) | `2026-10-08.1` | 查清 `2190/2191` 不是实时坐标，页面改为按「坐标多久没变」判断新鲜度 |
| 1.0.1 (2) | `2026-10-07.2` | 让「装的是哪一版」可查：构建标识 + git 提交号注入 + CI 闸门；同时修掉「假充电」误报与定位偏移 |
| 1.0.0 (1) | — | 首个可安装版本：协议还原 + 车控 + 定位/充电/续航页 |

> tag 格式是 `日期.当日序号`，**手工维护**，故意不用「自动取当前时间」——
> 那样每次编译都会变，反而没法回答「我手上这个包是哪一次构建的」。
> 另有一层兜底：`build_ipa.sh` 会把 git 提交号与构建时刻注进 `Info.plist`，
> 就算哪天忘了改版本号，只要提交号不同，两版包依然能一眼分辨。

---

## 七、五个页面

| Tab | 内容 |
|---|---|
| **爱车** | 官方「爱车」Tab 的完整复刻（9 个模块）：顶部车辆栏 → **3D 车模（内嵌可拖动，330 pt，无卡片底色）** → 续航主数字 + SOC 进度条 + 车门锁态 → 充电中心入口 → 快捷操作分页（4+4）→ 预约充电横幅 → 车内温度/空调 → 地图卡（**IP 归属地位置** + 鸣笛寻车 + 打开地图）→ 蓝牙钥匙 |
| 定位 | MapKit 地图打点 / CLGeocoder 中文地址 / **IP 归属地卡片** / 坐标（含两组交叉校验）/ 「坐标未变化」新鲜度提示 / 坐标校正（三选一 + 现场自证）/ 一键跳高德与 Apple 地图 / 距我多远 |
| 充电 | 电量环 + 目标电量 / **充电控制（立即·结束）** / **健康充电开关** / **充电上限滑杆** / **预约充电编辑器** / 距目标电量还需多久 + 预计时刻 / 充电判据证据卡（谁投的票） / 电池温度 / 两套续航与满电估算 / 疑似项专区 |
| 车控 | 按「门锁·后备箱 / 空调 / 灯光 / 电源」分组，会动物理世界的动作带警示标 + 更重的确认文案；另有**空调风量档位（未验证）**卡片 |
| 设置 | 会话 / 操作密码（含 oppwd 现场预览）/ 车辆 / 功能入口（**车辆档案** · 定位 · 充电 · 蓝牙钥匙 · 信号浏览器）/ 诊断 |

**信号浏览器**（设置 → 诊断，或爱车页底部）：signalMap 里 **130 个 signalId** 可搜索，
其中 **54 条**有语义标注（带置信度与判定依据）；
内置**快照 A/B 对比** —— 做动作前后各抓一次，只列出变了的 id。这是识别剩余未知信号的唯一办法。

**充电中心的几个实现决定**（都是刻意的）：

1. **健康充电不做乐观更新** —— 下发成功后立刻重查 `queryPushState`，用服务端回值校准开关。
   否则会出现「界面显示已开、车端没收到」的错觉。
2. **`healthyChargingPush` 是 `Bool?` 而不是 `Bool`** —— `nil` = 还没读到（显示「读取开关状态」按钮），
   `false` = 确认关闭。用 `Bool` 会把「未知」显示成「已关闭」，是**主动误导**。
3. **预约回填只在服务端有值时才覆盖**（跳过 `--:--` 占位）—— 服务端没配过预约时保留占位默认值，
   而不是把「未设置」写成一堆 `00:00` 骗用户。
4. **「立即充电」按钮的文案跟随实测充电状态**（`isCharging`：**只看充电电流 `1178`**），
   不跟随本地按钮状态 —— 否则会出现「点了没生效但按钮已经变了」的错觉。
   ★ v1.1.9 改判据（两层）：先是从「5 路标志位多数票 ≥ 3」改成「只看电流 `1178`」，
   再发现**通电（未插枪）时 `1178` 是 `0.2~0.3 A` 而非 0**（高压系统漏电流），
   于是加了 `chargeCurrentThreshold = 1.0 A` 的**量级门槛** —— 那 5 路其实是
   **高压系统激活**位（车辆通电 / 哨兵模式同样会点亮），用户实测在通电 / 哨兵时被误报成「充电中」。

---

## 文件清单

**打包 / 交付**
- `IPA_BUILD.md` — **打包 IPA 完整指南（GitHub Actions / 本地 Mac / 安装方法）**
- `ios/build_ipa.sh` — 一键打包脚本
- `ios/tools/gen_xcodeproj.py` — 纯 Python 生成 Xcode 工程（不依赖 XcodeGen）
- `ios/tools/make_icon.py` — 生成 App 图标
- `ios/tools/pack_source.py` — 打包源码 zip（传到 Mac / 推 GitHub）
- `.github/workflows/build-ipa.yml` — 云端打包流水线（先跑 Python 算法回归，再编译）

**iOS 交付**（38 个 Swift 文件，零第三方依赖）
- `ios/LeapmotorLite/` — UIKit 车控 App
- `UIKit/LMAppDelegate.swift` + `UIKit/LMRootViewController.swift` — 入口（`AppDelegate` + `window`）与根容器（按登录态换根）
- `UIKit/LMBaseViewController.swift` — ★★ 所有页面的基类：订阅 `client.objectWillChange` 驱动**幂等** `render()`
- `UIKit/LMUIKitTheme.swift` — 统一配色 + 复用组件（卡片 / 磁贴 / 状态胶囊 / 导航控制器 / 圆角常量）
- `UIKit/LMMainTabBarController.swift` — 5 个 Tab（**全部**是原生 UIKit 页，各自套 `LMNavigationController`）
- `LMBuildInfo.swift` — ★ 构建标识（版本号 + 构建 tag + git 提交号），解决「分不清装的是哪一版」
- `UIKit/LMLoveCarViewController.swift` — ★ 爱车页（官方「爱车」Tab 复刻，含内嵌 3D 车模）
- `UIKit/LMCar3DWebView.swift` + `UIKit/LMCar3DViewController.swift` + `Support/Car3DServer.swift` — ★ 3D 看车（WKWebView + 回环 HTTP 服务跑官方查看器）
- `UIKit/LMChargeViewController.swift` — ★ 充电中心（**可写**：立即/结束、健康充电、上限、预约 + 证据卡 + 疑似项专区）
- `API/LMCoordinate.swift` — ★ 坐标系换算（WGS-84 ↔ GCJ-02）+ 三选一校正策略 + 4 项自检
- `API/LMEndpoints.swift` — 端点表 + **充电 cmdid 常量（含反汇编证据表）** + 空调/车窗档位范围
- `API/LMSignalCatalog.swift` — ★ 信号 id → 语义知识库（带置信度与判定依据）
- `UIKit/LMLocationViewController.swift` — 车辆定位（MapKit + CLGeocoder + IP 归属地卡 + 坐标校正）
- `UIKit/LMVehicleProfileViewController.swift` — 车辆档案（66 能力位 / 固件 OTA / 功能开关 / cmdid 路线图）
- `UIKit/LMSignalExplorerViewController.swift` — 信号浏览器 + 快照 A/B 对比
- `UIKit/LMBLEKeyViewController.swift` — ★ 蓝牙钥匙（云端钥匙记录 / 行为开关 / 接口探测 / 协议进度）
- `UIKit/LMBLEDebugViewController.swift` — ★ BLE 调试台（扫描 / GATT 树 / 订阅抓帧 / 发原始字节）
- `BLE/LMBLEProtocol.swift` — ★★ BLE 协议知识库（UUID / ECDH 字段 / 帧模板 / 逆向证据全记录）
- `BLE/LMBLECentral.swift` — CoreBluetooth 封装（queue: nil 保主线程）
- `BLE/LMBLEKeyModels.swift` — 钥匙记录 / 行为开关 / 探测结果 / 帧自检
- `UIKit/LMDiagnosticsViewController.swift` — 车控体检（oppwd / token / 上次请求 / 接口探测 / 未验证 cmdid）
- `Store/LMLocationProvider.swift` — 本机定位（只用于「距我多远」）
- `ios/tools/lint_swift.py` — ★ Swift 陷阱静态检查（R1~R20，CI 里会跑）
- `ios/LeapmotorLite/README.md` — 编译 / 使用 / 协议文档（含 §1.8 充电中心）

**逆向与分析**
- `evidence/FINDINGS_CRYPTO.md` — **完整协议分析报告（签名 / signKey / oppwd / 登录链路）**
- `evidence/charging/FINDINGS_CHARGING.md` — ★ 充电四个 cmdid 的反汇编记录（含 chained-fixups 三个坑）
- `evidence/charging/rn_index_apipaths.txt` — 证明「充电页是原生页、不是 RN」
- `evidence/lovecar/FINDINGS_LOVECAR.md` — 爱车页逆向记录（未绑车态配置源 / Lottie 误判 / cmdid 对照）
- `evidence/car3d/FINDINGS_CAR3D.md` — 3D 车模逆向记录（取包接口 / 查看器契约 / 回环服务方案）
- `client/leapmotor_client.py` — Python 参考实现（签名已还原）
- `client/leapmotor_chain.py` — ★ 完整登录链路（发码 / 登录 / 兑换 / 派生）
- `client/test_sign_regression.py` — HAR 签名回归
- `client/test_swift_vectors.py` — Swift 自测向量回归（无需 Xcode）
- `client/test_coord_vectors.py` — ★ 坐标系换算回归（独立实现比对 + 回头读 Swift 源码文本）
- `client/test_refresh_contract.py` — ★ 契约测试（续期 / 3D / 爱车页 / 定位 / 充电中心）
- `client/ios_charge_cmdid.py` — ★ 充电 cmdid 可复现脚本（纯 stdlib 解 chained fixups）
- `client/ios_all_cmdids.py` — ★ v1.1.7：**全量** cmdid 反汇编脚本（一次解出 42 个 cmdid → selector，16 秒）
- `evidence/official/cmdid_table.txt` — 42 个 cmdid 的原始反汇编输出
- `evidence/official/LMV_zh-Hans.json` — 官方 669 条中文本地化表（挖关键词的入口）
- `client/ios_sym.py` / `ios_cfref.py` / `ios_clsmeth.py` / `ios_scan_login.py` — Mach-O / ObjC 逆向工具
- `client/objc_parse.py` / `macho_util.py` / `macho.py` — Mach-O / ObjC 基础解析
- `ios/tools/macho_xref.py` / `macho_xref_cfstring.py` — 字符串交叉引用查找

**抓包辅助**
- `capture/CAPTURE_SOP_IOS.md` — iOS 抓包 SOP
- `frida/ios_ssl_bypass.js` — 绕 SSL Pinning（越狱机）
- `app/` — 早期网页版（历史产物，已停用）
