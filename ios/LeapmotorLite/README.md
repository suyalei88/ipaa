# 零跑轻控 · LeapmotorLite（iOS）

第三方 **无广告、纯功能** 的零跑车控客户端。
仅用于控制 **本人账号下的本人车辆**。

- 平台：iOS 17+
- 语言：Swift / UIKit（v1.1.3 起全部页面为原生 UIKit，零 SwiftUI）
- 视觉：**纯深色「碳黑霓虹」**（v1.1.4，见 §1.10）—— 近黑底 + 发丝描边 +
  等宽大数字 + 单一薄荷霓虹点缀；由 `window.overrideUserInterfaceStyle = .dark` 锁定
- 依赖：**零第三方库**（CryptoKit + CommonCrypto，系统自带）
- 网络：URLSession，全部接口走 HTTPS
  （唯一例外：「3D 看车」由 App 自己在 `127.0.0.1` 起一个只服务内置资源的本地 HTTP 服务，
   原因是官方 H5 查看器必须在 Web Worker 里解析 FBX，见 §1.6）

| 能力 | 状态 |
|---|---|
| **爱车页**（官方爱车页完整复刻） | ✅ 2026-10-09，9 个模块全部还原，3D 车模直接内嵌可拖动（§1.7） |
| 车况 / 定位 / 充电 / 车控 / 信号浏览器 | ✅ |
| 登录态自动续期（`refreshToken`） | ✅ 2026-10-08，签名方式已用真实凭据实测确认（§1.5） |
| **3D 看车**（官方车模，可全方位旋转） | ✅ 2026-10-08，离线内置官方查看器 + D19 FBX（§1.6） |

---

## 1. 已还原并验证的协议

签名与加密全部从 iOS 官方 App（`com.leapmotor.developer` v1.22.68）
的主二进制 + Metro JS bundle 逆向得到，并用真实抓包做回归：

| 项目 | 结果 |
|---|---|
| `har_appgw.har` 105 个带 `sign` 的请求 | **101 MATCH** |
| 车控链路（`appremotectl` / `appremotectl/query` / `signal/info/query` / `vehicle/list` / `commonConfig` / `query/distributed`） | **100%** |
| `signKey` 派生 | ✅ 与抓包完全一致 |
| `oppwd` 加密 | ✅ 明文 `4211` → `uHTigfMDS5zIuZX4Gq4NVQ==` 完全一致 |

### 1.1 请求签名（★ 双模式）

原生实现位于
`+[LMVHttpV3InterfaceTool formatHeaderForHTTPRequestHeaders:paras:deviceid:encryption:error:]`
@ `0x106e6ee9c`，在 `0x106e6f2dc: tbz w8, #0, 0x106e6f364` 按标志位分叉：

```
登录前（bit0 == 0）：sign = SHA256(valueStr).hex()          ← 无密钥
                        0x106e6f370: objc_msgSend(sha256String:)
登录后（bit0 == 1）：sign = HMAC_SHA256(valueStr, signKey).hex()
                        0x106e6f334: objc_msgSend(HMacHashWithKey:plaintext:)
```

> 这解释了此前所有 `302002002 签名信息校验失败` —— 登录请求被错误地 HMAC 签名了。
> 换 token 的 `/base/base-user/account/v1/login` 必须用 **SHA256 无密钥** 签名。

两种模式的 `valueStr` 构造完全相同：

```
valueStr  = merge(signBody, signHeaders)
            → 去掉 null / undefined / "" 
            → key 升序（JS 默认字符串序 = UTF-16 code unit）
            → 只取 value，无分隔符 join("")
```

固定 8 个参与签名的 header：

```
acceptLanguage / channel / deviceId / deviceType / nonce / source / timestamp / version
```

`signBody` 规则（抓包实测）：

| Content-Type | signBody |
|---|---|
| `application/json` | `JSON.parse(body)`，非 JSON 则 `{}` |
| `application/x-www-form-urlencoded` | **URL 解码后的表单字典** |
| 无 body | `{}` |
| 任意 GET | query params 一并 merge 进来 |

### 1.2 signKey 派生（不需要 Frida）

原生实现位于 `-[LMVLocalLoginModel modelCustomTransformFromDictionary:]`：

```
d1      = b64decode( base64url→base64( accessToken.split(".")[2] ) )   // JWT 签名段
signKey = UPPER( hex( XOR3( d1, b64decode(signParam.r2), b64decode(signParam.r3) ) ) )
```

`XOR3` 零填充到三者最长，逐字节异或。
服务端保证 `signParam.r2^r3 == encryptParam.r2^r3`，所以 **`signKey == encryptKey`**。

### 1.3 oppwd（操作密码）

原生实现位于 `-[LMVOperatePwInteractor requestSignParamsWithPassword:]`：

```
key   = md5hex(accessToken[0..32])[8..24]      // 16 个 ASCII 字符
iv    = md5hex(accessToken[32..64])[8..24]     // 16 个 ASCII 字符
oppwd = base64( AES-128-CBC-PKCS7( 操作密码明文, key, iv ) )
```

### 1.4 车控协议

```
POST /app/app-control-service/v3/api/appremotectl
Content-Type: application/x-www-form-urlencoded

carvin=<vin>&cmdid=<n>&oppwd=<b64>&state=<urlencoded json>
```

返回 `{"result":0,"code":0,"data":"<msgID>"}`，再轮询：

```
GET /app/app-control-service/v3/api/appremotectl/query?msgID=<msgID>
    data == 1 → 成功
```

cmdid 表：

| cmdid | state | 功能 |
|---|---|---|
| 110 | `{"value":"lock"}` / `{"value":"unlock"}` | 车门锁 |
| 120 | `{"value":"true"}` | 后备箱 |
| 170 | `{"operate":"off"}` / `{"operate":"auto"}` | 大灯 |
| 230 | `{"value":"0"}` / `"2"` / `"5"` | 空调 |
| 400 | `{"operation":"on"}` | 上电 |

### 1.5 登录链路（短信验证码 · 全链路已实测打通）

```
① GET  appuser.leapmotor.cn/app-user/applogin/compliance/sendmessagecode
        ?phoneNo=<base64(RSA_PKCS1v15(手机号))>&smDeviceId=<SM4>
        · 无 sign、无 token
        · 原生 EncodeForStrV1: == base64(RSA_PKCS1v15(phone, AccountIDKey))

② POST appuser.leapmotor.cn/app-user/applogin/check_login_with_phone
        Content-Type: application/x-www-form-urlencoded      ← ★ 必须 form，JSON 会得 1019
        os=ios & smDeviceId=<SM4> & phoneNoCiphertext=<同上 RSA>
        & phoneNumber=<明文> & smsCode=<验证码>
        & deviceID=<phoneID> & pageUrl=
        → data.appLoginVO.token        （外层 SDK token，还不是 JWT）

③ POST app-gw-global-master.leapmotor.com/base/base-user/account/v1/login
        {"identifier": accountId, "identifierType": "1", "security": <②的 token>}
        sign = SHA256(valueStr)        ← ★ 无密钥
        → data = { accessToken(JWT), refreshToken, signParam{r2,r3}, encryptParam{r2,r3} }

④ signKey = UPPER( hex( XOR3( b64url(jwt[2]), b64(r2), b64(r3) ) ) )
```

关键点：

- `security` **就是** ② 返回的 `appLoginVO.token`，不是密码哈希；且非一次性、非短时效
- ② 的响应字段是 `data.appLoginVO.{token,refreshToken,accountId,nickname,tokenExpired}`
- `os` 字面量是小写 `"ios"`（`-[LPMBaseLoginCheckRequestParams init]` @ `0x104f0b00c`）
- 手机号加密公钥是 **RSA-1024 SPKI**，需先剥成 PKCS#1（1024-bit → **140 字节** DER）
  再交给 `SecKeyCreateWithData`（见 `Crypto/LMRSA.swift`）。
  注意 BIT STRING 长度是长格式 `03 81 8d 00`，别只读一个字节。

---

### 续期接口（`/base/base-user/token/v1/refresh`）

> ⚠️ **本地三份 HAR 里都没有这条请求**，以下全部来自官方 1.22.68 主二进制逆向。
> 定位手段：`ios/tools/macho_xref_cfstring.py` —— 先扫 `__DATA_CONST,__cfstring`
> 解码 chained fixup 找到字面量条目，再按 `adrp + add` 找引用它的代码。
>
> 踩过的坑（别再犯）：这个 Mach-O 用 `DYLD_CHAINED_PTR_64`（**非** `_64_OFFSET`），
> ptr 的低 36 位就是 vmaddr，高位还塞着 `next` 链字段 → 判等必须
> `(v & 0xFFFFFFFFF) == vmaddr`，拿 `vmaddr - imageBase` 去比会一条都命中不了。
> 另外 `md.detail = True` 必须开，否则 `ins.operands` 抛错被 `except` 吞掉，
> 表现为「明明有引用却扫不到」。

```
POST app-gw-global-master.leapmotor.com/base/base-user/token/v1/refresh
     {"refreshToken": "<登录响应里的 refreshToken>"}
     sign = HMAC_SHA256(valueStr, 旧 signKey)   ← ★ 必须带 token 头，属登录后接口
     → data = { accessToken, refreshToken, tokenExpireTime, refreshTokenExpireTime,
                signParam{r2,r3} | signR2/signR3,
                encryptParam{r2,r3} | encryptR2/encryptR3, accountId, nickname }
```

逆向证据（主二进制偏移）：

| 项 | 证据 |
|---|---|
| 调用点 | 函数 `@0x106E8115C`；`0x106E811B4 add x3,x3,#0x9c0 ; @"/token/v1/refresh"` |
| body 键 | `0x106E81240 add x3,x3,#0x8c0 ; @"refreshToken"` → `setObject:forKey:` |
| 方法 | `0x106E81354 add x4,x4,#0x960 ; @"POST_Json"`（JSON POST，超时 20s） |
| 路径前缀 | 裸路径 `@0xAA33226`，前缀常量 `@0xAA33D8E "/base/base-user"`（与 `@0xAA33E05 "/account/v1/login"` 同表相邻，运行时拼） |
| 响应键 | 函数 `@0x106E82B34`，每个字段成对出现：`data.signParam.r2` / `signR2` … |
| 主动续期 | ivar `_tokenAliveSec`(double) + `_tokenRefreshedFlagTime` + `_refreshTokenQueue`（串行队列）；通知 `com.tokenServer.login` / `com.tokenServer.refreshToken` |
| 请求头 | `XFX-CDN-CROSS-NODE` / `XFX-CDN-CROSS-REFRESH-NODE`（SDK 通用头，logout 同款） |

#### ★ 签名方式：**实测**推翻过一次（别再改回去）

逆向阶段只能看出「这是个 JSON POST + 20s 超时」，**签名方式在二进制里看不出来**，
当时的推断是「accessToken 已失效 → 用不了由它派生的 signKey → 必然是登录那条
无密钥 SHA256」。2026-10-08 拿到真实凭据后直接打了两发，结论是反的：

| 签名方式 | 服务端响应 | 判定 |
|---|---|---|
| 无密钥 `SHA256(valueStr)` | `{"code":302002002,"message":"签名信息校验失败"}` | ✗ |
| **`HMAC_SHA256(valueStr, 旧 signKey)`** | `{"code":0,"message":"SUCCESS", data:{…}}` | ✓ |
| HMAC 但**去掉 token 头** | `{"code":302002002,…}` | ✗（token 头参与校验） |

→ 它属于**登录后接口**，走 `buildHeaders` 那一套（signKey + token + carvin/cartype）。
App 侧为此专门加了 `signedPost(...)`：与 `request(...)` 同款签名，但**不挂续期钩子**
（否则续期会撞上 `request` 里的主动续期判断，无限递归）。

#### TTL 与「为什么能一直不掉线」

实测续期响应里 `tokenExpireTime = 7200`、`refreshTokenExpireTime = 604799`
（都是**秒数**，不是绝对时间戳），并且**每次续期都会下发新的 refreshToken** ——
即 refreshToken 是**滑动续期**的。只要每 7 天内成功续过一次，会话就能一直延长，
这才是官方「验证码登录一次再也不退出」的机制本体。

App 侧策略（`API/LMClient.swift`）：

- **主动**：`request(...)` 发请求前，token 剩余寿命 < 300s 就先续
- **被动**：命中 401/403 或 token 类业务码 → 续一次 → 原请求重放一次
- **去重**：`refreshTask` 保证并发请求只打一次续期接口（对齐官方 `_refreshTokenQueue`）
- 过期时刻优先取 **JWT 的 `exp`**，退化到 `tokenExpireTime + 落地时间`
- 契约测试 `client/test_refresh_contract.py` 已挂进 CI，钉住端点前缀、
  `LMSession` 新字段的 Optional 性、**必须走 HMAC 而不是 SHA256**、两条触发路径、
  响应双形状兼容，以及 3D 车模离线包的完整性（见下）

---

### 3D 车模（官方「3D 看车」）

**结论先说：官方 3D 车模不是原生 3D，而是一个服务端下发的离线 H5 包（three.js）+
FBX 模型，跑在 WKWebView 里。**

三条独立证据：

1. **IPA 内 0 个 3D 资源** —— 5266 个条目里 `.usdz/.scn/.dae/.obj/.glb/.gltf/.fbx/.reality/.usdc` 全零命中
2. **官方 Android APK 里也没有**（10625 条目，只有导航/TTS 的 `.bin`）→ 两端同一个 H5 方案
3. 主二进制字符串表挖出完整路径模板与选择器：
   ```
   %@/3DCarModel/%@        %@/%@/3DHoleCarImage/        %@/%@/.%@.zip → %@index.html
   react · DayOrNight · OriginalView · modelParam
   LMVCar3DModelService / LMVCarImage3DView / LMV3DCarModeVM
   fecth3DCarModelRootPath / isHave3DResouce / LMVZipArchiveDelegate(unzippedFiles)
   getCacheDownloadModelByHttpUrl: / configureWithPlateNumber:showPlate:showInHomeModel:is3DCarModel:
   ```

#### 取包接口（**直接返回 zip 字节流，不是 JSON**）

```
GET /carownerservice/v3/api/carpicture/3d/key?osVersion=…&vin=…
    → h5Key / srcKey / h5Whole / srcWhole / modelParam{carType,year,carTypeCode,colorCode,roofColor}

GET /carownerservice/v3/api/carpicture/key/package?key=<h5Key>   → 3 953 803 B  package.zip（查看器）
GET /carownerservice/v3/api/carpicture/key/package?key=<srcKey>  → 10 634 536 B package.zip（模型）
```

⚠️ 两个坑：参数名必须是 `key`（用 `h5Key`/`srcKey` 当参数名会回
`Required String parameter 'key' is not present`）；它是**登录后接口**，必须带 token + HMAC 签名。

两个 zip 解开后：

| 包 | 内容 |
|---|---|
| `key=h5Key` | `index.html`(458 B) + `index.js`(1.6 MB three.js 打包产物) + `FBX.worker.js`(388 KB) + `models/`(7) + `textures/`(36) |
| `key=srcKey` | `D19_2026/D19_2026_full_car.fbx`(5.9 MB) + `_starter_car.fbx`(4.2 MB) + 贴图 + `CarPaintConfig.csv` / `CarRoofConfig.csv` + 7 个版型 CSV |

#### 官方查看器的驱动契约（从 `index.js` 里读出来的）

```js
window.onIOSWebview();                       // 打开开关 → 首帧完成后走 window.prompt("onFirstFrame")
window.newInit(serverJson, appJson);         // serverJson/appJson 都是 **JSON 字符串**
//   serverJson ← 就是 3d/key 的 modelParam（parseServerJson 直接吃 carType/year/
//                carTypeCode/colorCode/roofColor/rudder/seat/…）
//   appJson    ← {width, height, energy, inland}
```

「全方位移动」= `index.js` 内置的 OrbitControls（`rotateSpeed` / `enableDamping` /
`autoRotate` / `touchAction`），单指拖动旋转、双指缩放，没有额外实现。

#### 本 App 怎么接的

- 两个包**离线内置**在 `LeapmotorLite/Car3D/`（17 MB / 63 文件），看车不依赖网络；
  只有「车型 / 颜色」参数走一次 `3d/key`（拿不到就用 D19 2026 六座兜底）
- 工程里必须用 **Xcode 蓝色文件夹引用**（`lastKnownFileType = folder`）整目录拷进
  bundle —— 官方 H5 里模型路径是写死的 `./D19_2026/D19_2026_full_car.fbx`，
  逐文件加会打平目录结构。`gen_xcodeproj.py` 为此加了 `RESOURCE_DIRS = ["Car3D"]`
- **不能**用 `loadFileURL`：`index.js` 用 `new Worker("./FBX.worker.js")` 在 Worker 里解析
  FBX，WKWebView 对 `file://` 页面按唯一不透明源处理，Worker 与 XHR 都会被拦。
  改由 `Support/Car3DServer.swift` 在 `127.0.0.1` 起一个**只服务 bundle 内 `Car3D/`**
  的极简 HTTP 服务（只实现 GET 静态文件、分块发送、目录穿越防护），
  官方 `index.html` / `index.js` / `FBX.worker.js` 一个字节都不用改
- `Info.plist` 加 `NSAllowsLocalNetworking`（只放开回环，不放开任意明文 HTTP）
- 本地验证工具：`ios/tools/car3d_webtest.mjs`
  （起静态服务 + headless Chromium 跑官方查看器 → 截图 + 控制台日志），
  已实测能完整渲染出 D19 并触发 `onFirstFrame`

入口：爱车页内嵌车模（可直接拖动）+ 右上角「全屏」按钮进 `Car3DView`。

---

### 1.7 爱车页（官方「爱车」Tab 的完整复刻）

官方「爱车」页有**两个状态**，按账号下有没有绑车切换：

| 状态 | 内容 | 数据来源 |
|---|---|---|
| 未绑车态 | 营销页（在售车型、预约试驾、在线客服、金融方案） | OSS 上 3 个配置 txt |
| **已绑车态** | 控制页（本 App 复刻的对象） | 车况信号 + `3d/key` + `commonConfig` + `remotectl` |

已绑车态的 **9 个模块**（顺序即官方截图顺序）与数据源：

| # | 模块 | 数据源 |
|---|---|---|
| 1 | 顶部车辆栏（车名 / 状态更新时间 / ♡ / ⚙️） | `vehicle/list` + 车况采集时间 |
| 2 | 续航主数字 + SOC 进度条 + 车门锁态 | signal `3257` / `100003` / `1298` |
| 3 | 充电中心入口 | → 充电页 |
| 4 | **3D 车模（内嵌，可拖动）** | §1.6 那套离线包，`Car3DWebView` 直接放进本页 |
| 5 | 快捷操作（分页 4+4） | cmdid `110` / `130` / `230` / `120` / `170` / `400` |
| 6 | 预约充电横幅 | `commonConfig` 的 `config["3"]` |
| 7 | 车内温度 / 空调 | signal `1349` + `1938`；风扇按钮下发 cmdid `170` |
| 8 | 地图卡（**位置 + 鸣笛寻车 + 打开地图**） | **IP 归属地**（`ipAnalysis/getAddressByIp`，与官方同源）；车机 signal `2190`/`2191` 降级为附注 + cmdid `120` |
| 9 | 蓝牙钥匙 | `commonConfig` 的 `config["4"]` |

#### ⚠️ 定位数据源：车辆位置 = IP 归属地，不是车机坐标

**2026-10-09 修正。** 用户报「官方 App 定位到车在淮南，本 App 显示合肥」。

排查结论（全部来自抓包实测）：

| 来源 | 实测值 | 结论 |
|---|---|---|
| `GET apptec.leapmotor.cn/ipAnalysis/getAddressByIp` | `{"province":"安徽","city":"淮南"}` | ✅ **与官方界面一致** —— 官方「车辆位置」用的就是它 |
| 车机 signalMap `2190`/`2191` | `31.801201` / `117.342718`（指向合肥） | ❌ **60 个快照里一个数字都没变** —— 静态值，不是实时位置 |

`signal/info/query/distributed` 的 signalMap 里**只有** `2190/2191` 与 `3725/3724` 两组坐标，
且都长期不变；其余落在坐标范围的 signal（`1204` = 33/37/41、`1349` = 29.5、`100003` = SOC）
都不是位置。**车机侧没有可用的实时定位。**

因此「车辆位置」主显示改用 IP 归属地（`LMClient.ipAddress`），车机坐标降为下面一行的附注，
「打开地图」也改为按城市名搜（拿静态坐标导航会导到错误城市）。
副作用：IP 归属地只精确到城市，且取决于手机当前网络 —— 手机和车不在同一城市时它也会不准，
这是**官方同样的限制**，不是本 App 引入的。

> 官方那个卡片（驻车照片 + 定位 + 鸣笛寻车）里的**驻车照片**仍未复刻：
> 抓包里没有任何接口返回驻车照片或停车点（`getAppImage` 是胎压等示意图、
> `chassis/query` 是底盘图、`commonConfig` 的 `config` 只有 `"3"` 预约充电与 `"4"` 蓝牙钥匙）。
> 该功能可能走 MQTT 推送，需在打开该卡片时重新抓包才能确认。

#### 三个刻意的实现决定

1. **3D 车模是内嵌的，不是跳页**。官方爱车页的车模就在页面上，单指拖动即旋转。
   本 App 用 `GeometryReader` 量真实宽度喂给 `appJSON`（官方查看器要求画布尺寸与视图一致，
   否则车会被裁切），而不是用 `UIScreen.main.bounds` —— 后者分屏 / 旋转后会算错。

2. **进全屏时主动拆掉内嵌的那个 WebView**。`NavigationStack` 推入下一页时本页不会被销毁，
   而官方查看器要在 Worker 里解析 5.9 MB 的 FBX，一个实例常驻上百 MB。
   不拆的话真机上会同时存在两个解析完整车模型的 WebView，内存直接翻倍。
   代价是返回时重新解析一次（页面里有 loading 态兜着）。

3. **不伪造「驻车照片」**。官方地图卡里那张驻车照片，取图接口在 IPA 字符串表里扫不到、
   四份抓包里也没有样本，`vehicleinfo/parking/query` 只是纯路径猜测。
   与其放张假图，不如把已确认的坐标 + 鸣笛寻车 + 一键跳地图做扎实。
   契约测试里有**反向断言**盯着这条（防止后人「顺手补上」）。

同理，空调卡大号数字放的是**已确认的车内温度**（`1349`），
不是官方那个设定温度 —— `10707` 实测 −6、`644/645/865/866` 在 0 与 21 之间跳，
四个都只是「疑似」，不拿它冒充。

> 完整的逆向记录（含未绑车态三个配置源、Lottie 误判、cmdid 对照）
> 见 `evidence/lovecar/FINDINGS_LOVECAR.md`。

#### 3D 车模的位置与尺寸（2026-10-09 调整）

用户反馈「把 3D 车模放大调到上面跟背景一起」，据此改了三点：

| 项 | 改前 | 改后 | 理由 |
|---|---|---|---|
| 页面位置 | 续航条之后 | **紧跟顶部车辆栏** | 官方爱车页车模就是最先看到的内容 |
| 高度 | 230 pt | **330 pt** | 约 40% 屏高，接近官方车模区占比；宽高比 361:330 ≈ 1.09，官方查看器在这个比例下不裁车头/车尾 |
| 底色 | `secondarySystemBackground` + 圆角裁剪 | **无底色、无裁剪** | 车模直接浮在页面背景上，与官方一致 |

去底色是安全的：`Car3DWebView` 里的 `WKWebView` 已设 `isOpaque = false`
+ `backgroundColor = .clear`，本身透明，不会露白块。契约测试 [11] 盯着这三条，
并**反向断言**了「不能再出现 `secondarySystemBackground` / `clipShape`」。

---

### 1.8 充电中心（可写 · 四个 cmdid 全部来自反汇编）

**2026-10-09 新增。** 用户要求「能直接在 App 设置预约充电 / 健康充电 / 立即充电 / 结束充电」。
改造前 `ChargeView` 是纯只读展示页；现在四个动作都能真正下发。

#### 为什么必须靠反汇编，而不能靠抓包

抓包里 `POST /carownerservice/v3/api/appremotectl` 的 cmdid **只有**
`110 / 120 / 130 / 170 / 230 / 400`（即已实现的 6 个车控），
**充电四个 cmdid 一个样本都没有** —— 因为抓包期间用户没在官方 App 里点过充电。
所以结论只能从官方主二进制里挖。

#### 定位方法（可复用）

```
__objc_methname 取 selector 字符串 vmaddr
        ↓
__objc_selrefs 找引用 —— ⚠️ 磁盘上全是 0，
        指针是 chained-fixups 未 rebase 状态，
        必须解析 LC_DYLD_CHAINED_FIXUPS（fileoff 0xbb5c000）还原
        ↓
__objc_stubs 里找 selector stub（adrp + ldr 配对）
        ↓
__text 里找 bl <stub> 调用点（(insn & 0xFC000000) == 0x94000000）
        ↓
反汇编调用点所在的大 switch = cmdid 分派表
```

#### 结论：四个 cmdid（每条都有指令地址作证）

分派函数起始 `0x106c5ee00`，形如 `cmp x23, #<cmdid>` + `b.eq`：

| cmdid | Hex | 官方 selector | 语义 | 调用点 |
|---|---|---|---|---|
| **190** | `0xBE` | `requestForChargingSetContent:` | 充电上限设置 | `0x106c5f09c` |
| **193** | `0xC1` | `requestForBeginOrEndChargingWithContent:` | 立即 / 结束充电 | `0x106c5f250` |
| **480** | `0x1E0` | `requestForChargingHealthControl:` | 健康充电开关 | `0x106c5ef38` |
| **161** | `0xA1` | `requestForAppointmentContrlCmdID:content:` | 预约充电 | `0x106c5ef54` |

stub 地址：`AppointmentContrl @0x10a4d4d40` / `BeginOrEndCharging @0x10a4d4d80`
/ `ChargingHealthControl @0x10a4d4e00` / `ChargingSetContent @0x10a4d4e20`。

> **可复现**：`python client/ios_charge_cmdid.py evidence/leapmotor_main`
> 会把四个 cmdid、四个 stub、四个调用点全部重算一遍并断言与代码常量一致
> （脚本自带纯 stdlib 的 chained-fixups 解码，不依赖 lief）。
> 官方换版本时它会报红 —— 比人肉核对可靠。

⚠️ **预约充电那一格是「多对一」**：161 / 171 / 361 / 392 四个 cmdid 都落到
同一个分支体（`0x106C5EF48`）。所以「161 = 预约充电」成立，但反过来说
「预约充电只有 161」不成立。本 App 只用 161（它也在 `rightList` 里）。

**交叉验证**：`sharecar/getShareVehicleListByVin` 返回的
`rightList = "190,192,170,193,171,150,370,470,130,131,230,110,430,410,160,161,480,360,240,361,120,340,440,220,320,420,421,301,500"`
里 **190 排第一位**，且 193 / 161 / 480 都在 —— 与反汇编解出的结果完全吻合。

#### state 字段：分级证据，不混为一谈

分派器只传 `cmdid + content`，**content 的字段名在调用方构造，反汇编这段拿不到**。
所以每个字段单独标来源：

| 动作 | state 字段 | 证据等级 |
|---|---|---|
| 预约充电 | `beginTime` / `endTime` / `percent` / `isEnable` / `cycles` / `circulation` / `recharge` | **最高** —— 服务端 `config["3"]` 实测回来的原名，「读什么写什么」 |
| 健康充电 | `isPush` | **高** —— 只读查询 `healthyCharging/queryPushState` 实测返回 `{"isPush":false}` |
| 充电上限 | `percent`（+ 冗余 `chargesoc`） | **中高** —— `percent` 是 `config["3"]` 实测名；`chargesoc` 来自主二进制字段串 |
| 立即 / 结束充电 | `Begin_Charge` + 冗余 `recharge` | **中** —— 字段名有据（主二进制字符串表 `…circulation.Begin_Charge`），**取值类型无样本**，所以两个键都带、都按 1/0 |

> ⚠️ 「立即/结束充电」的 state 是最弱的一环，**必须真机验证**。
> 多带一个未知键通常会被车端忽略，比押注单一键名安全。

#### 三个实现决定

1. **健康充电不做乐观更新**。下发成功后立刻重新查一次 `queryPushState`，
   用服务端回值校准开关。否则会出现「界面显示已开、车端没收到」的错觉。
2. **`healthyChargingPush` 是 `Bool?` 而不是 `Bool`**。`nil` = 还没读到，
   界面显示「读取开关状态」按钮；`false` = 确认关闭。用 `Bool` 会把「未知」
   显示成「已关闭」，是**主动误导**。
3. **预约回填只在服务端有值时才覆盖**（`syncAppointmentFromServer` 里跳过
   `--:--` 占位）。服务端没配过预约时保留占位默认值，而不是把「未设置」
   写成一堆 `00:00` 骗用户。

#### 官方限制（已复刻到文案）

官方本地化表 `LMVLocalizedBundle.bundle/zh-Hans.lproj/Localizable.strings`（669 条）里
与充电相关的原文：

| key | 文案 |
|---|---|
| `ChargingCenter_Title` | 充电中心 |
| `ChargingCenter_SubTitle` | 插枪后会根据设定时间充电，仅支持慢充 |
| `ChargingCenter_SelectAppointmentTime` | 预约充电 |
| `ChargingCenter_ChargeHealth` | 健康充电 |
| `ChargingCenter_ChargeHealthSocAlert` | 为保持电池健康状态，无法调节至90%以上，请关闭健康充电后重调。 |
| `ChargingCenter_OptimalLimit` / `…OptimalLimit80` | 最佳限值90% / 最佳限值80% |
| `ChargingCenter_ChargingTimeTips` | 设置时间需在当前时间\n5分钟后 |
| `ChargingCenter_ChargingCurrentTimeTips` | 设置时间需在当前时间后\n12小时内 |
| `ChargingCenter_SameTimeTips` | 开始、结束时间相同，请重新选择 |
| `ChargingCenter_CurrentSocTips` | 充电的电量不能小于当前电量 |
| `ChargingCenter_ChargeHealthCloseAlertTip` | 确定关闭健康充电吗？ |
| `LMV_Charge_startCharge` / `LMV_Charge_endCharge` | 开始充电 / 结束充电 |

#### 顺带确认的两件事

- **充电页是原生页面，不是 RN**。从官方 IPA 里提出 `index.jsbundle`
  （3,044,225 B）后只扫到 **11 条真实接口路径**（9 条 AI 中心 `bigmodelapp`
  + 2 条 `agreement`），**一条充电相关都没有** —— 而主二进制里充电路径齐全。
  > 早期记录里写的「13 条」含 2 条噪声（`/baseMinusT`、`/baseMinusTMin`
  > 是压缩后的 JS 变量名，不是接口），已更正。
  > 清单见 `evidence/charging/rn_index_apipaths.txt`。
- **没有独立的「立即充电」HTTP 接口**。主二进制里 71 条 `v3/api/` 路径全列出来过，
  充电相关只有 `appremotectl` / `appremotectl/appointment` / `appremotectl/getappointment`
  / `appremotectl/query` / `healthyCharging/control` / `healthyCharging/queryPushState`
  —— 立即/结束充电只能走 `appremotectl` + cmdid 193。

> 完整逆向记录见 `evidence/charging/FINDINGS_CHARGING.md`。

---

### 1.9 UI 框架迁移：SwiftUI → UIKit（✅ 已完成，v1.1.3）

**起因**：要求「换个 UI，不使用 SwiftUI」。

**做法不是一次性重写**。先把壳换成 UIKit，未迁移的页面用
`UIHostingController` 托住 —— 每一步 App 都能编译、能出包、能装机，
不存在「改到一半整个工程不可用」的中间状态。到 v1.1.3 全部页面迁完，
`LMHostingController` 与 `Views/` 目录已整体删除，**全项目零 `import SwiftUI`**。

代码分界（实测行数）：

| 层 | 文件 | 行数 | 迁移时 |
|---|---|---|---|
| 入口 + 视图层 | `UIKit/`（迁移前是 `UIKit/` + `Views/`） | 迁移前 15 个文件 / 约 7,600 行 | **已全部重写**（v1.1.3） |
| 协议 + 加密 + 蓝牙 + 存储 | `API/` `Crypto/` `BLE/` `Store/` | 17 个文件 / 6,790 行 | **一行没动**（纯 Foundation） |

也就是说 `LMClient`（`ObservableObject` + 29 个 `@Published`）**完全不用改**，
UIKit 侧订阅 `objectWillChange` 就够了。

**Phase 0（已完成，v1.1.0）**：只换壳，页面行为与上一版完全一致。

- `UIKit/LMAppDelegate.swift` —— `@main` + `UIWindow`。
  `Info.plist` 里没有 `UIApplicationSceneManifest`，所以走传统生命周期，
  **不需要 SceneDelegate**（⚠️ 以后要加 Scene 清单必须同时补 SceneDelegate，否则白屏）。
- `UIKit/LMUIKitTheme.swift` —— `UIColor.lm*` 与 UIKit 版卡片 / 磁贴 / 胶囊 / 导航，
  颜色值与原 `Views/Theme.swift` **逐位对齐**（v1.1.3 迁完后 `LMRadius` 也搬到了这里，
  旧 `Theme.swift` 随 `Views/` 一起删除，现在只有一处定义）。
- `UIKit/LMBaseViewController.swift` —— 页面基类。订阅 `client.objectWillChange`
  驱动 `render()`，并提供滚动容器、下拉刷新、提示框。
- ~~`UIKit/LMHostingController.swift`~~ —— 过渡桥，把未迁移的 SwiftUI 页包成 VC。
  **v1.1.3 已删除**：所有页面迁完后它就没有使用者了。
- `UIKit/LMRootViewController.swift` / `LMMainTabBarController.swift` —— 根容器与 5 个 Tab。

**Phase 1（已完成，v1.1.1）**：登录页 `LoginView`（285 行）迁成原生
`UIKit/LMLoginViewController.swift`，这是整条迁移路线的**样板**。

- 页面继承 `LMBaseViewController`，只覆盖两个钩子：`buildUI()` 搭一次视图树，
  `render()` 做幂等刷新（登录页的 `render()` 只调 `refreshControls()`，
  从不 `addSubview`）。
- 页内状态（手机号 / 验证码 / 倒计时 / 导入文本 / 提示语）**不进 `LMClient`** ——
  它们是纯 UI 状态，跟车端无关，留在 VC 里更简单。
- 倒计时用 **`target/selector` 版 `Timer`** 而不是 block 版：
  block 版收的是 `@Sendable` 闭包，不继承 `@MainActor` 隔离，改 `countdown`
  会直接编译报 actor 隔离错误；并且必须加进 `RunLoop` 的 `.common` 模式，
  否则用户一拖动 ScrollView 计时器就停走。
- `viewDidDisappear` 里 `invalidate()` 停表，避免 Timer 一直持有 self。
- 三条业务链路原样保留：`sendSMSCode` / `loginWithSMSCode` + `refreshAll` /
  `adoptLoginResponse`。
- `LMRootViewController` 的登录分支已从 `LMHostingController { LoginView() }`
  换成 `LMNavigationController(rootViewController: LMLoginViewController(...))`，
  该文件不再需要 `import SwiftUI`。

**Phase 2（已完成，v1.1.2）**：设置页 `SettingsView`（423 行 SwiftUI `Form`）迁成
`UIKit/LMSettingsViewController.swift`。这是第一页「带表单 + 带子页跳转」的页面，
多解决了一个**架构问题**：

- **表单语义**：`Form` 换成一列 `LMCardView` 卡片；条件行（密码位数警告 / oppwd
  预览 / 保存结果）用 `UIStackView` 的 `isHidden` 折叠，**不重建视图** ——
  这是 `render()` 幂等约定在表单页的落地方式。
- **只有两块内容例外**：车辆列表和续期日志的行数是动态的，用「内容指纹」
  （`rebuildIfNeeded` + `ObjectIdentifier`）判断，指纹没变就整块跳过；
  这两块里没有输入控件，重建不会打断用户输入。
- ★★ **「UIKit 页 push SwiftUI 页」的导航栏冲突**（本轮新暴露的问题）：
  设置页要 push 的 7 个页面还是 SwiftUI，其中 `BLEKeyView`（4 处）、
  `DiagnosticsView`（1 处）内部有 `NavigationLink` —— 它**必须有
  `NavigationStack` 祖先**才能工作。
  - 直接 push 进 UIKit 导航栈 → 那些内部跳转**静默失效**（点了没反应，不报错）
  - 给它们套 `NavigationStack` 再 push → **两根导航栏叠在一起**
  解法：给 `LMHostingController` 加 `ownsNavigationBar` 开关 —— 内容外面套
  `NavigationStack`，同时藏掉外层 UIKit 导航栏（`viewWillAppear` 藏、
  `viewWillDisappear` 恢复），并在 SwiftUI 那根栏里补一个「返回」按钮
  （`NavigationStack` 作为栈底本来没有返回键，不补用户进去就出不来）。
- **爱车页右上角的齿轮**原来是 `NavigationLink { SettingsView() }`。设置页迁成
  UIKit 之后这条路走不通（见上），改成发 `Notification.Name.lmSelectSettingsTab`
  切到设置 Tab —— 设置本来就是独立 Tab，切 Tab 比 push 更自然。
- 操作密码的输入语义逐条保留：`.password`（**不是** `.oneTimeCode`，那会静默替换
  用户输入）、只滤数字不截断、位数提示、可临时明文查看（切 `isSecureTextEntry`
  后**必须重赋 `text`**，否则 UIKit 会在下一次输入时清空）。
- Tab 容器里设置那一行从 `LMHostingController { NavigationStack { SettingsView() } }`
  换成 `LMNavigationController(rootViewController: LMSettingsViewController(...))` ——
  原生页需要 `UINavigationController` 才能 push 子页。

#### ★ 两个必须记住的坑

**① `objectWillChange` 在「赋值之前」触发。**
`@Published` 在 `willSet` 里发通知，所以回调里读 `client.xxx` 拿到的是**旧值** ——
表现为「界面永远慢一拍，最后一次变化永远看不到」。必须推到下一轮主 actor。
代码里用 `Task { @MainActor in }` 而**不是** `DispatchQueue.main.async`：
后者收的是 `@Sendable` 闭包，**不继承**外层的 `@MainActor` 隔离，
调用主 actor 隔离方法可能直接编译报错。

**② 一次请求会连着触发十几次刷新。**
一个接口回来会连写十几个 `@Published`（vehicles / signals / lastUpdate / isBusy…），
`objectWillChange` 就触发十几次。基类用 `renderPending` 把同一轮内的多次合并成一次；
并且 `render()` 必须**幂等** —— 只改已有控件的属性，不要在里面 `addSubview`，
否则每来一次数据就叠一层控件。

#### Phase 3~6（已完成，v1.1.3）：剩余 11 页一次性迁完

原计划按体量从小到大分 6 批（Phase 3~8），实际按「谁依赖谁」重排成 4 批、
**一次性迁完** —— 因为逐批做会让「UIKit 页 push SwiftUI 页」的过渡桥
（`LMHostingController` + `ownsNavigationBar`）在每一批里都要维护一遍，
而它本身就是最别扭的部分，早一天删掉早一天省心。

| 阶段 | 页面 | 迁移前 | 状态 |
|---|---|---|---|
| Phase 0 | 换壳（AppDelegate + window + 宿主桥） | — | ✅ v1.1.0 |
| Phase 1 | `LoginView` | 285 行 | ✅ v1.1.1 |
| Phase 2 | `SettingsView` | 423 行 | ✅ v1.1.2 |
| Phase 3 | 诊断类 5 页：`SelfTestView` / `SignalExplorerView` / `BLEKeyView` / `BLEDebugView` / `DiagnosticsView`（另拆出 `BLEProtocolStatus` / `BLEKeySelfCheck` 两个小页） | 约 2,100 行 | ✅ v1.1.3 |
| Phase 4 | `VehicleProfileView` / `ControlPanelView` | 1,208 行 | ✅ v1.1.3 |
| Phase 5 | `LocationView` / `ChargeView` | 1,647 行 | ✅ v1.1.3 |
| Phase 6 | `Car3DView` / `LoveCarView`（`Car3DConfig` + `Car3DWebView` 合并成 `LMCar3DWebView`） | 约 1,600 行 | ✅ v1.1.3 |

**收尾时一并做掉的事：**

- 11 处 `pushSwiftUIPage(...) { XxxView() }` 全部改成
  `navigationController?.pushViewController(LMXxxViewController(client: client), animated: true)`。
- 4 个还在托管里的 Tab 换成 `makeTab(LMXxxViewController(client: client), title:image:)`
  —— 每个 Tab 都套 `LMNavigationController`，因为 5 个页面内部都有 push 目标。
- 删除 `Views/` 目录（12 个 SwiftUI 文件）与 `UIKit/LMHostingController.swift`。
- `gen_xcodeproj.py` 的 `DIR_ORDER` 去掉 `"Views"`；重跑后 pbxproj 从 51 → 38 个源文件。
- `Views/Theme.swift` 的 `enum LMRadius` 在 Phase 2 就搬进了 `LMUIKitTheme.swift`，
  旧文件删除后只剩一处定义。

**踩到的两个新坑：**

- **`Car3DConfig` 重名**：旧 `Views/Car3DView.swift` 与新 `UIKit/LMCar3DWebView.swift`
  都定义了 `enum Car3DConfig`，两个文件同时存在会直接编译失败
  （invalid redeclaration），所以「新文件落地」与「旧文件删除」必须**在同一次提交里**
  完成。契约测试 `[14]` 现在钉死「`Car3DConfig` 只有一处定义」。
- **`UIViewController.title` 与 `tabBarItem.title` 是两回事**：原
  `LMHostingController(title:tabImage:)` 一次设了两个；改成原生页后，
  `title` 由页面自己在 `buildUI()` 里设，`tabBarItem` 由 `makeTab(...)` 设，
  两边都要给，否则要么导航栏没标题、要么 Tab 没名字。

#### 契约测试随迁移更新的三处

1. `[11]`（骨架）原来断言「4 个托管 Tab 各自保留 `NavigationStack`」，
   v1.1.3 后改成「5 个 Tab 全是原生 UIKit 页，`LMHostingController(` 与
   `NavigationStack {` 的计数都是 0」。
2. `[3c]` / `[9]` / `[10]` / `[11]` 里读 `Views/XxxView.swift` 的断言全部改读
   `UIKit/LMXxxViewController.swift`，并把**断言锚点**从 SwiftUI 写法换成 UIKit 等价物：
   `private var rangeHero` → `private let rangeHero`、`GeometryReader` → 容器实际宽度、
   `.lmClock(until:)` → target/selector 版 `Timer` + `.common` 模式。
3. 新增 `[14]`：钉整体不变量 —— `Views/` 目录已删、全项目零 `import SwiftUI`、
   没有 `pushSwiftUIPage` 的**定义**、13 个新 VC 都继承 `LMBaseViewController`、
   跨页跳转全部指向新 VC、`Car3DConfig` 只有一处定义、磁盘源文件数 == 工程源文件数。

> ⚠️ 写断言的老规矩（本项目已踩过三次）：**盯被测对象，不要盯「某字符串有没有
> 出现在某文件里」**。这一轮又踩了一次 —— `[13]` 里写了
> `"pushSwiftUIPage" not in vc`，而文件头注释为了说明「过渡方法已删」必然写出
> 这个词，于是断言自己把自己判失败。改成匹配真实声明形态
> （`re.search(r"func\s+pushSwiftUIPage", vc) is None`）才对。

---

### 1.10 视觉重设计「碳黑霓虹」（✅ 已完成，v1.1.4）

**起因**：UIKit 迁移做完后用户反馈「换了框架但界面没变」—— 那本身是认知差
（换框架 ≠ 换外观），但接下来明确要求「开始做视觉重设计」。
先出了 3 版 HTML 样张（`design/lovecar-dark-mockup.html`：
极夜玻璃 / 深海蓝调 / 碳黑霓虹），用户选定 **碳黑霓虹**。

**设计语言（6 条）**：

| 元素 | 取值 | 为什么 |
|---|---|---|
| 页面底 | `#0A0A0C` 近黑 + 顶部极淡薄荷径向光晕 | 纯黑在 OLED 上和卡片糊在一起；光晕给纵深 |
| 卡片 | `#131316` 实心 + `#26262C` 1pt 发丝描边 | 近黑底上光靠明度差不够，描边才有分层 |
| 主色 | 薄荷 `#00E39A`（**唯一**强调色） | 只做点缀不铺面 —— 铺面它就变成「主色」而不是点缀了 |
| 数字 | `LMFont.mono`（SF Mono 等宽） | 续航 / 电量 / 温度会跳动，等宽才不会左右抖 |
| 圆角 | card 14 / tile 12 / hero 16 | 比原来（18 / 14 / 22）收方一档，配描边得到硬朗感 |
| 文字 | `lmText` / `lmText2`(46%) / `lmText3`(28%) 三档 | 显式给出，不依赖系统语义色漂移 |

**为什么锁定深色**：这套设计没有浅色版本。`LMAppDelegate` 里
`window.overrideUserInterfaceStyle = .dark` 一刀锁死。
好处是 `.label` / `.secondaryLabel` 这些系统语义色恒为「浅色文字」，可以直接用；
代价是想放开浅色模式，必须先把 `LMUIKitTheme` 里的 `lm*` 常量改成动态色。

**杠杆在哪**：改 `LMUIKitTheme.swift` **一个文件**，13 个页面一起换肤 ——
`lmAccent` 被引用 93 处、`lmCard` 11 处、`LMRadius` 12 处。
所以这一版**全部页面**都已经变成深色薄荷风，只是爱车页额外做了逐模块的专属调整。

**爱车页的专属改动**：

| 模块 | 改动 |
|---|---|
| 顶部车辆栏 | 车辆名纯白 22pt；更新时间压到 `lmText3`；圆形按钮加描边，齿轮降为 `lmText2`（薄荷只留给主操作） |
| 3D 车模 | 车底加一团薄荷辉光（`LMCar3DPedestalView`），车「落」在光上；全屏入口从 32pt 纯图标圆钮改成「图标 + 全屏看车」文字胶囊 |
| 续航 Hero | 大面积蓝渐变 → 实心卡 + 薄荷洗色；大数字 42 → **54pt 等宽**；新增「剩余续航」小标题行，锁态胶囊移到右上 |
| SOC 条 | 单色实心 → 主色→青色横向渐变 + 辉光（7 → 8pt 高） |
| 快捷操作 | 圆 56pt → **圆角方形**（半径 17）。这套语言里「圆」表示状态，「圆角方」表示可点操作 |
| 空调 / 地图 | 温度、坐标改等宽；标签统一 `lmText2` / `lmText3` |
| toast | 「薄荷底 + 白字」→「薄荷底 + **近黑字**」（白字对比度只有约 1.5:1） |
| Tab 栏 | 刷成 `lmCanvas` + 去掉投影线 + 未选中项压到 `lmText3` |

**踩到的三个坑**：

- **`masksToBounds` 会裁掉阴影**：SOC 条想同时要「圆角渐变」和「辉光」，
  同一层做不到 —— 开了裁剪，阴影就没了。拆成两层：`fill` 只负责
  `shadowPath`（不裁），`fillGradient` 负责圆角裁剪。
- **白字在薄荷上不可读**：原来全 App 的实心按钮都是「蓝底白字」，
  主色换成薄荷后对比度掉到约 1.5:1。全量改成 `.lmCanvas` 近黑字（约 12:1），
  并加 **lint `R18`** 防止回退。
- **系统语义背景色的「两种黑」**：`.systemBackground`（纯黑）与 `lmCanvas`
  （`#0A0A0C`）不是一个值，混用会出现「同一屏两种黑」。
  全部换成 `lmCanvas` / `lmCard`，并加 **lint `R19`**。

**新增的两条 lint**：

| 规则 | 拦什么 |
|---|---|
| `R18` | `baseForegroundColor = .white`（薄荷底上不可读）。**只查这一处** —— `textColor` / `tintColor` 在深色蒙层上写白字是正当用法，一刀切会误报 |
| `R19` | `.systemBackground` / `.secondarySystemGroupedBackground` 等系统语义背景色（放开浅色模式会白底白字） |

两条都做了正反样本验证，含「注释里提到系统色不该命中」这种反样本
（`blank_comments_and_strings` 会先剥注释再匹配）。

**契约测试**：新增 `[15]`，钉住调色板逐位取值、三档圆角、等宽字体存在且
用在磁贴主值上、深色锁定、辉光底在最底层且不吃手势、爱车页 7 处标志性改动、
以及 `R18` / `R19` 已注册。

---

### 1.11 定位与驻车照片（✅ 已完成，v1.1.5）

这一节记两件事，都是用户直接提的：
① 定位页撤掉「当前位置（IP 归属地）」，改成**本机 GPS** + **车辆位置**并列；
② 找出并接上**驻车照片**。另外附带修了健康充电显示错误、补了车控感叹号的图例。

#### 为什么撤掉 IP 归属地

| 时间 | 结论 |
|---|---|
| 2026-10-08 | 用户报「官方显示淮南、本 App 显示合肥」→ 当时把主位置**改成 IP 归属地**（`GET apptec.leapmotor.cn/ipAnalysis/getAddressByIp`），依据是车机 signalMap 的 `2190/2191` 在 60 个抓包样本里一个数字都没变过 |
| **2026-10-09** | 用户**要求撤掉**：「把当前位置取消掉 改回之前的」+「把车辆定位内部加入本机 GPS 位置和车辆位置同时加入」 |

撤掉的理由（这次想清楚了）：

- IP 归属地是「服务端认为**手机连的网**在哪」—— **不是**手机 GPS，**更不是**车的位置；
- 只精确到城市；WiFi 走专线、开代理、用热点都会把它指到别的城市；
- 它出现在「车辆定位」页**最上面**，很容易被当成「车在哪」。

现在的规则：

| 位置 | 来源 | 精度 |
|---|---|---|
| **我的位置（本机 GPS）** | `CLLocationManager`（`Store/LMLocationProvider.swift`） | 米级 |
| **车辆位置** | 车机 signalMap `2190/2191`（`3725/3724` 交叉校验） | 车机上报值，可能长期不变 |

改动清单：

- `UIKit/LMLocationViewController.swift`：删 `ipHeader` / `ipCard` / `buildIPCard()` / `renderIP()` / `probeIPTapped()` 与全部 ip 控件；新增「我的位置（本机 GPS）」卡（`mePosCard` / `renderMePosition()`）；
- `UIKit/LMLoveCarViewController.swift`：地图卡主位置改回**车机坐标**，删 `ipSourceNote`，`openInMaps()` 改回按坐标导航；
- `API/LMClient.swift`：**删掉**轮询版 `refreshIPAddress()`（UI 不再显示，没必要每次刷新都发请求）；诊断用的 `probeIpAddress()` 保留；
- 把「车端已关闭位置数据分享，无法获取车辆实时位置」这条提示从 IP 卡挪到**车辆位置**卡上 —— 它本来就是车辆位置的问题。

> ⚠️ 断言纪律：契约测试里**不能**写 `"ipSourceNote" not in love` 这种。
> 解释「为什么撤掉」时注释里必然会写出这个名字，会变成假阳性。
> 一律匹配**真实代码形态**，例如 `re.search(r"private let ipSourceNote", love) is None`。

#### 驻车照片 = `chassis/query`

★★ 这次**更正了一个旧结论**。以前 `probeChassis()` 的注释写的是
「`chassis/query` 返回的是 OSS 上的 `ChassisPicture/prod/<VIN>` —— 一张**底盘图片**，跟定位无关」。
**那半句是错的**：它确实是 `ChassisPicture/prod/<VIN>`，但那张图是
**地下停车场的俯视哨兵照**（画面里能看到车位号、通道箭头、消防管道）。

证据（用户自己的抓包 `evidence/har_appgw.har` 第 42 / 38 条）：

```
GET /carownerservice/v3/api/chassis/query?vin=LFZ63AA15TH035113
→ 200 {"code":0,"result":0,"message":"请求成功","data":{
      "fileUrl":"http://lp-carnet.oss-cn-hangzhou.aliyuncs.com/ChassisPicture/prod/LFZ63AA15TH035113?Expires=...&OSSAccessKeyId=...&Signature=...",
      "uploadTime":1791344811823}}
→ 下载 fileUrl 得到 74,088 字节 JPEG（856×1296）
```

那张 JPEG 已存盘：**`evidence/car3d/chassis.jpg`**（车位号 067，黑色车）。

旁证（官方主二进制）—— 整条「驻车快照」链路都在：

| 符号 | 作用 |
|---|---|
| `LMVMapParkingSnapService` | 快照服务（`_snapService`） |
| `queryParkSnapComleteBlock:` | 取快照（官方拼写就是 `Comlete`） |
| `LMVMapParkingSnapView` | 快照视图（`_snapView` / `_aiPhotoView`） |
| `LMVParkPhotoBrowserView` | 照片浏览器（点击看大图） |
| `LMVParkBusinessModel` | 模型（`parkingTs` / `parkingEnv` / `parkingType` / `parkingPriceSummary` / `parkingSnapSwitch`） |
| `LMVParkInfoModel` / `queryAIParkInfoComleteBlock:` | AI 泊车信息 |
| `/v3/api/vehicleinfo/parking/query` | 另一条停车查询接口（**无抓包样本**，未接） |

还有一条旁证来自 RN bundle：`leapmotor://NativePage:CarMap` 的 label 就是
**「驻车拍照」**（`description: 跳转地图页（包含驻车拍照）`）——
官方**没有**独立的驻车照片页，它是地图页内部的一块。

落地：

| 文件 | 内容 |
|---|---|
| `API/LMModels.swift` | `LMParkingSnap`（`fileUrl` + `uploadTime` 毫秒时间戳 → `Date`）、`LMParkingSnapData` |
| `API/LMClient.swift` | `parkingSnap` / `parkingSnapLoading` / `parkingSnapError` / `parkingSnapImageData` + `refreshParkingSnap()` + `downloadParkingSnapImage()` |
| `UIKit/LMLocationViewController.swift` | 「驻车照片」卡：缩略图（点开全屏）+ 上传时间 + **驻车位置**（车机坐标）+ 重新获取 |

三个实现细节（都是踩过的）：

1. **图片高度约束必须跟 `isHidden` 联动**。`UIStackView` 里 hidden 的 arrangedSubview
   只是不参与布局，**它自己的约束还在** —— 直接 `isHidden = true` 会留一块 260pt 空白。
   所以高度约束先 `isActive = false`，有图了再开（`snapHeightConstraint`）。
2. **`LMClient` 不下载图片**。它只依赖 Foundation，不想为了一个 `UIImage` 引入 UIKit。
   下载在 VC 层做（`URLSession.shared.data(from:)`），结果缓存在 `parkingSnapImageData`。
3. **OSS 直链带签名会过期**，所以每次都是现拉 `fileUrl`，不做长期缓存；
   直链变了（换了新图）要丢掉旧的图片缓存。

#### 健康充电显示错误 —— 根因是 `deviceId`

用户报：「健康充电官方 App 是开启状态，这个显示关闭」。

查到的东西：

- `healthyCharging/queryPushState`（`POST`，form: `carvin` + `deviceId`）
  实测返回 `{"isPush":false}`；
- 抓包里**官方自己**调这个接口也是 `false`（`har_appgw.har` #29 / #161）；
- 官方 selector 是 `requestForChargingHealthControl:`（cmdid **480**），写走车控通道。

★★ 根因在 `LMConfig.deviceId`：

```swift
// 改之前 —— 每次启动都换一个
var deviceId: String = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
```

这个接口是拿 `carvin + deviceId` 查「**这台设备**的状态」的。
`deviceId` 每次启动都变，服务端就永远把本机当成一台**没绑定过的新设备**，
凡是有设备维度的状态一律回默认值（`false` / `0`）—— 健康充电开关正是这么被读成「已关闭」的。

抓包交叉验证：官方自己调同一个接口，用的是**固定不变**的
`ios_ee45b9d830bb126d431e998943a7797a`。

修法：

```swift
var deviceId: String = LMConfig.stableDeviceId

static let stableDeviceId: String = {
    let key = "lm.deviceId"
    if let saved = UserDefaults.standard.string(forKey: key),
       saved.hasPrefix("ios_"), saved.count > 8 { return saved }
    UserDefaults.standard.set(capturedDeviceId, forKey: key)   // 默认取官方抓包那个
    return capturedDeviceId
}()
```

> 存 `UserDefaults` 而不是 Keychain：这不是凭据，丢了也只是重新认一次设备。

配套的 UI 改进（`UIKit/LMChargeViewController.swift`）：

- 卡里**写明状态来源**（`healthSourceLabel`）—— 以前只有一个「已关闭」，用户对着官方的
  「已开启」完全没辙，既不知道值从哪来，也没有重读入口；
- 「读取开关状态」按钮**不再隐藏** —— 以前读到一次就藏起来，想重读都没得点；
- 开/关用颜色区分（`.lmGood` / `.lmText2`），扫一眼能分清。

> ⚠️ 诚实标注：`deviceId` 是**能查到的最可能根因**，不是 100% 确证 ——
> 抓包里官方自己调也是 `false`，所以 `isPush` 是否就是健康充电开关本身仍有不确定性。
> 但「每次启动换 UUID」无论从哪个角度看都是 bug，先修掉。
> 如果修完还是显示「已关闭」，说明 `isPush` 确实是另一个东西（比如推送提醒开关），
> 那就要去 signalMap 找健康充电信号（官方有个 `chargeHealth` 属性是 `NSNumber`，
> 且带 `chargeHealthChangeWithValue:`，像信号驱动）。**需要真机验证。**

#### 车控按钮右上角的感叹号

用户问「车控的按钮右上角有个感叹号是什么意思」。

那是自己加的**物理动作警示**（`LMControlActionTile.warnView`，
`exclamationmark.triangle.fill`、`.lmWarn`、9pt、右上角 top6/trailing6）：

```swift
warnView.isHidden = (cmd.risk != .physical)
```

`Risk` 定义在 `API/LMEndpoints.swift`：

| 值 | 含义 | 感叹号 |
|---|---|---|
| `.low` | 只改状态，不会夹到人（空调、车窗、充电上限…） | ❌ |
| `.physical` | **会开合车门 / 后备箱 / 启动上电** | ✅ |

含义之前只写在代码注释里，界面上没有任何解释 —— 等于只有开发者看得懂。
这次在车控页页脚（`footnoteText`）补了一句图例。

#### 本节相关的门禁

| 检查 | 内容 |
|---|---|
| `client/test_refresh_contract.py` → `[9]` | 定位数据源（40+ 条）：撤 IP 卡 / 本机 GPS / 驻车照片 / 代码里不读 `ipAddress` |
| 同上 → `[10]` | 新增 6 条：`deviceId` 稳定性 + 健康充电 UI |
| `ios/tools/lint_swift.py` | `R1~R20` 全过（★ 本轮新增 **R20**：可选链后紧跟 `flatMap` / `compactMap` —— 详见下方「踩坑」） |

#### ★★ 踩坑：可选链会把 `.成员.方法` 整段吞进链内（烧掉一轮 CI）

第一版 `downloadParkingSnapImage()` 写的是：

```swift
guard let url = parkingSnap?.fileUrl.flatMap(URL.init(string:)) else { return nil }
```

CI 直接编译失败：

```
error: cannot convert value of type '(__shared String) -> URL?'
       to expected argument type '(String.Element) throws -> URL?'
       (aka '(Character) throws -> Optional<URL>')
```

**原因**：可选链 `?.` 不是「只作用于 `fileUrl`」，而是把后面的
`.fileUrl.flatMap(...)` **整段纳入链内**。链内的基类型是**已解包**的
`LMParkingSnap`（非可选），于是 `fileUrl` 是 `String` 而不是 `String?` ——
这个 `.flatMap` 于是被解析成 **`Sequence.flatMap`**
（要求 `(Character) -> SegmentOfResult`），而不是
**`Optional.flatMap`**（要求 `(String) -> URL?`）。类型对不上，编译失败。

**正确写法**：拆成两句 `guard let`（可选链的基类型回到 `LMParkingSnap?`，
结果才是 `String?`）：

```swift
guard let fileUrl = parkingSnap?.fileUrl,
      let url = URL(string: fileUrl) else { return nil }
```

**已固化为 lint R20**。只拦 `flatMap` / `compactMap` —— 这两个「压平」方法在
`Optional` 与 `Sequence` 上**语义完全不同**，撞上必错；
`map` / `filter` / `count` 不拦，因为 `a?.items.map { ... }`（返回 `[U]?`）
是正当且常见的写法。正反样本在 `dist/_lint_selftest.py`。

> 教训：本机是 Windows、**没有 `swiftc`**，所有 UIKit / Swift 类型推断错误
> 都只能在 CI 发现。这类「可选链吞掉成员访问」的坑纯文本闸门看不出来，
> 所以一旦烧过一次就立刻固化成 lint 规则。

---

## 2. 编译 / 打包 IPA

### 方式 A：一键打包（推荐）

在任意一台装了 Xcode 的 Mac 上：

```bash
cd leapmotor-thirdparty
bash ios/build_ipa.sh
```

产物：`dist/LeapmotorLite-unsigned.ipa`（用 Sideloadly / AltStore / TrollStore 装）

脚本会自动完成：生成图标 → 生成 `.xcodeproj` → `xcodebuild` → 打包成 `Payload/*.app` 的 zip。
**不需要 XcodeGen。**

要签名版：

```bash
DEVELOPMENT_TEAM=你的TeamID bash ios/build_ipa.sh
```

### 方式 B：没有 Mac → GitHub Actions

把仓库推到 GitHub → Actions → **Build IPA** → Run workflow → 在 Artifacts 里下载 IPA。

完整说明（含安装步骤、常见报错）见 **[`../../IPA_BUILD.md`](../../IPA_BUILD.md)**。

### 方式 C：Xcode 里手动跑

```bash
python3 ios/tools/gen_xcodeproj.py          # 生成工程（纯 Python，无需 XcodeGen）
open ios/LeapmotorLite/LeapmotorLite.xcodeproj
```

选中 `LeapmotorLite` target → Signing & Capabilities → 选自己的 Team → 连上 iPhone 直接 Run。

> 也可以改用 XcodeGen：`brew install xcodegen && cd ios/LeapmotorLite && xcodegen generate`
> （`project.yml` 仍在，两条路等价）

### 工程是怎么生成的

`ios/tools/gen_xcodeproj.py` 直接产出 `project.pbxproj` + 共享 scheme：

- 只用标准库，macOS 自带 Python 3 就能跑
- UUID 用文件名 md5 派生 → **确定性**，重复生成不会产生 diff
- 自带结构自检（括号平衡 + 所有引用的 UUID 都有定义）：`python3 ios/tools/gen_xcodeproj.py --check`

---

## 3. 首次使用

### 3.1 装完先跑「算法自检」

`设置 → 诊断 → 算法自检`。

会用真实抓包向量验证 `HMAC-SHA256 / SHA256 / XOR3 / AES-128-CBC / MD5-16 / RSA`：

```
signKey = 7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566
oppwd("4211") = uHTigfMDS5zIuZX4Gq4NVQ==
登录前签名 SHA256(valueStr) = 066fda165156e717a624dc4c53c7036ecb38a4c0cbd39d4fcb3d6e82c5df0863
```

最后一组是**坐标换算**（不属于加解密，但同样属于「算错了整页数据就不对」的纯算法）：
`WGS-84 → GCJ-02` 的参考向量、往返残差 < 1 mm、境外坐标原样返回、三个校正选项的语义一致性。

再往后是**构建标识**自检：版本号有没有忘改、构建 tag 是否为空、
git 提交号有没有真的被 `build_ipa.sh` 注进 Info.plist。
（页面顶部也会显示同一个标识 —— 这是「我装的是哪一版」的最快判据，见 `IPA_BUILD.md`。）

**全部通过**才说明实现与官方 App 逐字节一致。（没装 Xcode 也能验：
`python client/test_swift_vectors.py` 与 `python client/test_coord_vectors.py`）

### 3.2 登录（短信验证码，推荐）

1. 首页输入手机号 → 点「获取验证码」
2. 收到短信后填入验证码 → 点「登录」
3. App 自动完成 ①→②→③→④ 四步，派生 `signKey` 并存入本机 Keychain

全程与官方 App 的请求逐字段一致（手机号 RSA 加密后才外发，明文密码/验证码不落地）。

> 备用方式：**导入登录态**。把官方 App `/base/base-user/account/v1/login`
> 响应里的整个 `data` 对象粘进输入框即可（见 §3.2 旧流程，仍是 100% 可靠）。
> 冷启动那条 `vehicle/list` 的响应里没有 `signParam`，务必用登录接口的响应。

### 3.3 设置操作密码

`设置 → 操作密码`，填 6 位数字（就是官方 App 里车控时要求输入的那个）。

密码只存在本机 Keychain，每次车控时用 `accessToken` 派生的 key/iv 现场加密成 `oppwd`，
**明文不会外发**。

### 3.4 车控

`车控` 页点按钮即可。指令下发后会自动轮询结果，成功/失败会有提示。

---

## 4. 目录结构

```
ios/
├── build_ipa.sh                     # ★ 一键打包 IPA（Mac）
├── tools/
│   ├── gen_xcodeproj.py             # 纯 Python 生成 .xcodeproj + 共享 scheme
│   ├── make_icon.py                 # 生成 1024 图标 + Assets.xcassets
│   └── pack_source.py               # 打包「源码 zip」方便传到 Mac / 推 GitHub
└── LeapmotorLite/
    ├── project.yml                  # XcodeGen 工程描述（备用路线）
    ├── README.md
    ├── LeapmotorLite.xcodeproj/     # 由 gen_xcodeproj.py 生成
    └── LeapmotorLite/
        ├── LMBuildInfo.swift            # ★ 构建标识（版本 + tag + git 提交号）
        ├── Assets.xcassets/             # App 图标（make_icon.py 生成）
        ├── Crypto/
        │   ├── LMHash.swift             # MD5 / MD5-16 / SHA256 / HMAC-SHA256 / XOR3 / Data 工具
        │   ├── LMAES.swift              # AES-128-CBC + PKCS7（CommonCrypto）
        │   ├── LMRSA.swift              # RSA-1024 PKCS#1v1.5 公钥加密（手机号）
        │   ├── LMSigner.swift           # valueStr / 双模式 sign / signKey 派生 / oppwd
        │   └── LMSelfTest.swift         # 内置抓包 + 真实链路测试向量
        ├── API/
        │   ├── LMEndpoints.swift        # host / path / cmdid 表（含蓝牙钥匙 7 个接口）
        │   ├── LMModels.swift           # 响应模型
        │   ├── LMSignalCatalog.swift    # 信号 id → 语义知识库（带置信度 + 判定依据）
        │   ├── LMCoordinate.swift       # ★ WGS-84 ↔ GCJ-02 换算 + 三选一坐标校正 + 自检
        │   └── LMClient.swift           # 请求构造 + 签名 + 短信登录 + 全部业务方法
        ├── BLE/                         # 蓝牙钥匙（见 IPA_BUILD.md「蓝牙钥匙逆向进展」）
        │   ├── LMBLEProtocol.swift      # ★★ UUID / ECDH 字段 / 分号帧模板 / 逆向证据全记录
        │   ├── LMBLECentral.swift       # CoreBluetooth 封装（queue: nil 保主线程）
        │   └── LMBLEKeyModels.swift     # 钥匙记录 / 行为开关 / 探测结果 / 帧自检
        ├── Store/
        │   ├── LMSessionStore.swift     # Keychain 会话持久化
        │   └── LMLocationProvider.swift # 本机定位（只用于「距我多远」）
        ├── UIKit/                       # ★ 2026-10-09 UI 全部换成原生 UIKit（迁移已完成，v1.1.3）
        │   ├── LMAppDelegate.swift      # App 入口（@main + window；Info.plist 无 Scene 清单）
        │   ├── LMUIKitTheme.swift       # ★★ 设计系统「碳黑霓虹」（v1.1.4，见 §1.10）：
        │   │                            #   调色板(lmCanvas/lmCard/薄荷 lmAccent…) + LMRadius(14/12/16)
        │   │                            #   + LMFont.mono 等宽数字 + 卡片/磁贴/胶囊/辉光底/导航/控件工厂
        │   ├── LMBaseViewController.swift # ★★ 页面基类：订阅 objectWillChange → 幂等 render()
        │   ├── LMRootViewController.swift # 根容器：登录页 ↔ 主 Tab
        │   ├── LMMainTabBarController.swift # 5 个 Tab（全部原生 UIKit 页，各自套 LMNavigationController）
        │   ├── LMLoginViewController.swift  # ★ Phase 1：登录页（短信验证码 / 导入登录态）
        │   ├── LMSettingsViewController.swift # ★ Phase 2：设置页（会话 / 操作密码 / 车辆 / 诊断 / 设备）
        │   ├── LMLoveCarViewController.swift  # ★ Phase 6：爱车页（内嵌 3D 车模 + 快捷分页 + 预约充电 + 空调/地图/蓝牙钥匙）
        │   ├── LMCar3DWebView.swift     # ★ Phase 6：3D 容器（WKWebView）+ Car3DConfig
        │   ├── LMCar3DViewController.swift # ★ Phase 6：全屏 3D 看车
        │   ├── LMLocationViewController.swift # ★ Phase 5：车辆定位（地图 / 地址 / 导航 / 坐标校正）
        │   ├── LMChargeViewController.swift   # ★ Phase 5：充电中心（可写：立即/结束 · 健康 · 上限 · 预约）
        │   ├── LMControlPanelViewController.swift # ★ Phase 4：车控
        │   ├── LMVehicleProfileViewController.swift # ★ Phase 4：车辆档案
        │   ├── LMBLEKeyViewController.swift     # ★ Phase 3：蓝牙钥匙（钥匙记录 / 开关 / 接口探测 / 协议进度）
        │   ├── LMBLEDebugViewController.swift   # ★ Phase 3：BLE 调试台（扫描 / GATT / 订阅抓帧 / 发字节）
        │   ├── LMBLEProtocolStatusViewController.swift # ★ Phase 3：协议进度
        │   ├── LMBLEKeySelfCheckViewController.swift   # ★ Phase 3：协议自检
        │   ├── LMDiagnosticsViewController.swift # ★ Phase 3：车控体检 + 官方接口探测
        │   ├── LMSignalExplorerViewController.swift # ★ Phase 3：信号浏览器 + 快照 A/B 对比
        │   └── LMSelfTestViewController.swift   # ★ Phase 3：算法自检
        ├── Car3D/                       # ★ 官方 3D 车模离线包（folder 引用，17 MB / 63 文件）
        │   ├── index.html               #   官方查看器入口（未改动）
        │   ├── index.js                 #   three.js 打包产物 1.6 MB（未改动）
        │   ├── FBX.worker.js            #   Worker 里解析 FBX（未改动）
        │   ├── models/ textures/        #   充电枪 / 天空球 / 车道线 + 贴图
        │   └── D19_2026/                #   D19_2026_full_car.fbx(5.9 MB) + 贴图 + 配色 CSV
        └── Support/
            ├── Info.plist
            └── Car3DServer.swift        # 127.0.0.1 回环静态服务（供 Worker/XHR 用）
```

---

## 5. 已知边界

| 项 | 状态 |
|---|---|
| 签名（双模式）/ signKey / oppwd | ✅ 完全还原并验证 |
| 车况 / 车辆列表 / 车控 | ✅ 100% 命中 |
| 短信验证码登录（全 4 步） | ✅ 已实测打通（收到短信 → 换 JWT → signKey → 车控成功） |
| 手机号 RSA 加密 | ✅ 已还原（SPKI→PKCS#1，见 `LMRSA.swift`） |
| `smDeviceId`（SM4 国密设备指纹） | ⚠️ 复用抓包值；未还原派生算法（不影响使用） |
| 账号密码登录（`security` 字段） | ⚠️ 已弃用 —— `security` 实为外层 token，改走短信登录 |
| 车控二进制响应（`LMVCloudBinaryPacket`） | ⚠️ 未解析（当前接口返回的都是 JSON） |
| 车辆坐标的**坐标系** | ⚠️ **方向未定** —— 官方 App 里 `wgs84ToGcj02` 和 `gcj02ToWgs84` 两个方向都实现了，静态分析定不下来。已做成三选一校正（默认 `WGS-84 → GCJ-02`），在定位页换选项、站车边上 10 秒即可自证 |
| 充电状态判定 | ✅ 5 个状态位 `100004/1149/1257/3636/3722` 投票 + 充电电流 `1178`，判据来自「充电 vs 未充电」逐信号 diff |
| `1200` 的语义 | ✅ **不是剩余充电时间**，是纯 SOC 投影 `round(11.33 × (目标 − SOC))`，未充电时也是正数 |
| 登录态自动续期（refreshToken） | ✅ 已实现（2026-10-08）。**本地三份 HAR 里没有任何续期样本**，整条链路逆向自主二进制 —— 见下节「续期接口」 |
| **蓝牙钥匙（BLE）** | ⚠️ **协议未打通**。已从官方 IPA 静态逆向出 UUID / 握手字段 / 分号帧模板（见 `BLE/LMBLEProtocol.swift`），但缺 `passwordCard`、帧语义、cmdId 表。App 里给的是**调试台 + 协议进度**，不是能解锁的钥匙。补齐办法见 `IPA_BUILD.md` |

### 客户端固定参数（可直接复用抓包值）

```
deviceId       = ios_ee45b9d830bb126d431e998943a7797a   （每设备不同，也可自行生成 ios_<32hex>）
deviceType     = iOS
source         = leapmotor
channel        = 1
version        = 1.22.68
acceptLanguage = zh-Hans-CN;q=1, en-CN;q=0.9
x-subversion   = 3.22.2-3
x-region       = CN
x-api-signature-version = 2.0
smDeviceId     = B1rFqR82E2Z7do2KhMDKziLEuIcoEt4wY8QTy7/43ImlKMu591xoe/c8kgMPsTk4P/nPH8eAUxQCnmA3GjTZODg==
```

---

## 6. 免责声明

- 本项目为**个人学习 / 个人车辆控制**用途，仅供控制你自己账号下的你自己车辆。
- 请勿用于批量、代控他人车辆或任何商业用途。
- 抓包与逆向仅针对你本人设备上的官方客户端；请遵守当地法律与官方服务条款。
