# 零跑轻控 · LeapmotorLite（iOS）

第三方 **无广告、纯功能** 的零跑车控客户端。
仅用于控制 **本人账号下的本人车辆**。

- 平台：iOS 17+
- 语言：Swift / SwiftUI
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
| 8 | 地图卡（坐标 + 鸣笛寻车 + 打开地图） | signal `2190`/`2191` + cmdid `120` |
| 9 | 蓝牙钥匙 | `commonConfig` 的 `config["4"]` |

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
        ├── LeapmotorLiteApp.swift       # App 入口 + RootView + MainTabView
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
        ├── Views/
        │   ├── Theme.swift              # 配色 + 复用组件（卡片 / 磁贴 / 电量环 / .lmClock）
        │   ├── LoginView.swift          # 短信验证码登录 / 导入登录态
        │   ├── LoveCarView.swift        # ★ 爱车页（官方爱车页完整复刻：内嵌 3D 车模 + 快捷分页 + 预约充电 + 空调/地图/蓝牙钥匙）
        │   ├── LocationView.swift       # 车辆定位（地图 / 地址 / 导航 / 坐标校正）
        │   ├── ChargeView.swift         # 充电信息（距目标电量还需多久 / 充电判据证据 / 预约充电）
        │   ├── ControlPanelView.swift   # 车控
        │   ├── BLEKeyView.swift         # 蓝牙钥匙（钥匙记录 / 开关 / 接口探测 / 协议进度）
        │   ├── BLEDebugView.swift       # BLE 调试台（扫描 / GATT / 订阅抓帧 / 发字节）
        │   ├── SignalExplorerView.swift # 信号浏览器 + 快照 A/B 对比
        │   ├── DiagnosticsView.swift    # 车控体检 + 官方接口探测
        │   ├── Car3DView.swift          # 3D 看车（WKWebView 驱动官方查看器）
        │   ├── SettingsView.swift       # 设置
        │   └── SelfTestView.swift       # 算法自检
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
