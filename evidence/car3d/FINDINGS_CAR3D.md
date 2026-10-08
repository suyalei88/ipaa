# 零跑官方 App「3D 车模」逆向报告

> 目标：把官方 App 爱车页那个「可全方位拖拽旋转」的车模挖出来自用。
> 结论：**它不是原生 3D 模型，而是一个服务端下发的离线 H5 包（zip）+ WKWebView 渲染**。
> 日期：2026-10-08　样本：`零跑-1.22.68.ipa`（184MB）+ 4 份 HAR + `LPQC_323026.apk`（287MB）

---

## 1. 结论速览

| 问题 | 答案 |
|---|---|
| IPA 里有 3D 模型文件吗？ | **没有**。扫描 5266 个条目，`.usdz/.scn/.dae/.obj/.glb/.gltf/.fbx/.reality/.usdc` 全部 0 命中 |
| APK 里有吗？ | **没有**。10625 条目里仅导航/TTS 的 `.bin`；无任何模型文件 |
| 那 3D 车模在哪？ | **服务端 OSS**，通过 `carpicture/key/package` 拿 zip 地址后下载 |
| 渲染方式 | 离线 H5（React）→ `Car3DWebView`（WKWebView）→ 本地 `index.html` |
| 需要鉴权吗？ | **需要**。无 token 调 `carpicture/3d/key` 返回 `302002003 TOKEN校验失败` |

---

## 2. 完整链路（逆向自主二进制 cstring 表 @0xAA1D1C0–0xAA1D560）

```
① GET  /carownerservice/v3/api/carpicture/3d/key?osVersion=&vin=
     → data.h5Key     "3D-616d34c0-33b8-4a05-a6af-284490d82608"    H5 包 key
       data.srcKey    "3D-8444a1b9-f975-4efb-9025-515e8197e938"    源包 key
       data.h5Whole   "w58wdL6R6Dnv3lOzXhYT1Q=="                    16B → MD5 校验
       data.srcWhole  "+idvVcToKuoG3gRrmhmUXw=="                    16B → MD5 校验
       data.modelType 3
       data.modelParam{carType,year,carTypeCode,colorCode,roofColor}
       data.shareBindUrl  → 长期签名 URL（Expires=4943496040 ≈ 2126 年）返回一张 PNG

② GET  /carownerservice/v3/api/carpicture/key/package
     → 返回 zip 下载地址（**HAR 中无样本**，抓包时未进 3D 页）

③ 下载 zip → 解压 → %@/index.html  ← WKWebView 加载
     本地缓存根：%@/3DCarModel/%@
     资源目录：  %@/%@/3DHoleCarImage/   ← 多角度图序列
                %@/%@/%@.png
     包文件：    %@/%@/.%@.zip
```

### 关键字符串原文（cstring 表，逐条独立）

```
%@/3DCarModel/%@          ← 车模本地根目录
%@/%@/3DHoleCarImage/     ← 多角度图目录
%@/%@/%@.png
%@/%@/.%@.zip
%@index.html              ← H5 入口
react                     ← H5 是 React 应用
DayOrNight / OriginalView / modelParam / newData   ← 视角状态键
v3/api/carpicture/3d/key
v3/api/carpicture/key/package
LMVLNoti_Car3DWebViewDidTerminate
LMVLNoti_CarImageNetTypeChange
carIdChanged / NoCarId
```

### 关键 ObjC 选择器（`__objc_methname` @0xA70027C）

```
LMVCar3DModelService / LMVCar3DModelServiceDelegate
LMVCarImage3DView / LMVCarImage3DViewDelegate
LMV3DCarModeVM
fecth3DCarModelRootPath                     ← 取本地根路径（注意官方拼写 fecth）
resourcePath3D / resourcePath3DWithDirName:
isHave3DResouce / localSuccessWith3D
LMVZipArchiveDelegate / unzippedFiles / OOMZipPath        ← 解压
getCacheDownloadModelByHttpUrl: / setPackageType:
initWithViewSource:carLayout:seat3DView:postionString:carModelHeight:topMargin:
configureWithPlateNumber:showPlate:showInHomeModel:is3DCarModel:
jump3DAirCondi
is3DCarModel / setIs3DCarModel: / is3DPage / setIs3DPage:
```

---

## 3. 已下载到的资源（真实产物）

| 文件 | 大小 | 尺寸 | 说明 |
|---|---|---|---|
| `model3d.png` | 244,636 B | **1125×552** | `shareBindUrl` 返回的官方渲染图（D19 白色 3/4 前视，纯白背景，车牌位 "D19"） |
| `chassis.jpg` | 55,565 B | 856×1296 | `chassis/query` → `ChassisPicture/prod/<VIN>`，停车场俯视照片（哨兵照） |
| `3dPosition.json` | 629 B | — | APK 内车模热点坐标（1080×1440 坐标系） |
| `lovecar.json` | 14,685 B | — | APK 内爱车页 Lottie 动画（车灯） |

### `3dPosition.json` 全文（部件热点表）

```json
{"air_conditioners":[{"x":294.5059,"y":380.62527},{"x":540.375,"y":472.89792},
                     {"x":786.2441,"y":380.62527},{"x":540.375,"y":765.53375}],
 "l_Rearview_Mirror":{"x":147.09244,"y":426.4392},
 "lf_Wheel":{"x":212.29256,"y":193.48163},
 "lr_Wheel":{"x":212.29243,"y":1233.7773},
 "r_Rearview_Mirror":{"x":933.6576,"y":426.4392},
 "rf_Wheel":{"x":868.45746,"y":193.48163},
 "rr_Wheel":{"x":868.4576,"y":1233.7773},
 "screen":{"x":540.375,"y":452.49924},
 "seates":[{"x":397.06363,"y":641.42633},{"x":683.6864,"y":641.42633},
           {"x":397.0636,"y":982.275},{"x":540.375,"y":982.275},{"x":683.6864,"y":982.275}],
 "steering_wheel":{"x":390.9217,"y":523.34644}}
```
中心 x=540.375=1080/2，四轮+五座+四出风口 → **俯视整车图**，用于车图上叠加可点热点。

---

## 4. 卡点：凭据失效

| 凭据 | 值 | 状态 |
|---|---|---|
| accessToken exp | 1791368047 | 2026-10-07 18:14 **已过期** |
| refreshToken exp | 1791965647 | 2026-10-14 16:14 未过期，但服务端返回 **「登陆过期」** |

**实测续期接口**（`POST /base/base-user/token/v1/refresh`，host `app-gw-global-master.leapmotor.com`）：

| 签名方式 | 服务端响应 | 判定 |
|---|---|---|
| 无密钥 `SHA256(valueStr)` | `{"code":302002002,"message":"签名信息校验失败"}` | ✗ **不成立** |
| `HMAC_SHA256(valueStr, 旧 signKey)` | `{"code":302010219,"message":"登陆过期"}` | ✓ **签名通过** |
| HMAC 但不带 token 头 | `{"code":302002002,"message":"签名信息校验失败"}` | token 头参与校验 |

**结论（重要）**：
1. ✅ 路径 `/base/base-user/token/v1/refresh` 正确（服务端返回业务码，非 404）
2. ✅ **续期签名 = HMAC(旧 signKey)**，不是无密钥 SHA256 —— 这修正了上一版 Swift 实现的假设
3. ❌ 本 session.json 的 refreshToken 已被服务端作废（很可能是 10-07 抓包后又发生新登录，触发 session 轮换）

---

## 5. 无凭据路径已穷尽（全部失败）

| 尝试 | 结果 |
|---|---|
| 无 token 调 `3d/key` | `302002003 TOKEN校验失败` |
| OSS 直连 `carModel3D/<h5Key\|srcKey\|shareKey>`（无签名） | `403 AccessDenied` |
| OSS bucket 匿名列举 | `403 Anonymous user has no right to access this bucket` |
| 公开 OSS 配置（`nativeApp/htmlConfig/htmlUrlStr`、`nativeApp/loveCar/*`） | 下载成功但**不含任何 3D 车模地址** |
| IPA / APK 包内资源 | 均无模型文件 |

---

## 6. 下一步（需凭据）

拿到有效 token 后执行：

```
python client/car3d_probe.py --step all
```

脚本已就绪（`client/car3d_probe.py`），会依次：
1. 续期拿新 accessToken
2. 调 `carpicture/3d/key` 拿 h5Key/srcKey
3. 调 `carpicture/key/package` 拿 zip 地址（脚本内已内置 5 组候选参数名待试）
4. 下载 zip → 解出 `index.html` + `3DHoleCarImage/*.png` 多角度序列

**取凭据的两种方式**：
- **A（推荐）**：官方 App 打开「3D 看车」页时重新抓包 → 一次性拿到 token + `key/package` 请求与响应（含长期签名 zip URL）
- **B**：提供手机号 → 触发短信验证码 → 用码登录换新 token


---

## 7. ★ 已打通（2026-10-08 收尾）

上面的「卡点」已解决：用短信验证码换到了新会话，两个 zip 都拿到了。

### 7.1 登录：`identifierType=3` + accountId + 验证码

`check_login_with_phone` **根本不需要调**。HAR 里那次真实登录的序列是：

```
GET  /app-user/applogin/compliance/sendmessagecode?phoneNo=…    ← 发码
POST /base/base-user/account/v1/login                            ← 28 秒后直接登录成功
```

`POST .../account/v1/login` 的 body：

```json
{"identifier":"<accountId>","identifierType":"3","security":"<6 位验证码>"}
```

签名 = **无密钥 `SHA256(valueStr)`**（这一条已用 HAR 里那次登录的 body + 8 个签名头
离线复算，与抓包里的 `sign` **逐字符一致**：`ed5cccd2…d1647`）。

枚举 `identifierType` 的实测结果（这一步是关键）：

| identifierType | 结果 |
|---|---|
| `1` | `302010202 第三方TOKEN失效` ← HAR 里用的就是这个（极验一键登录的 token） |
| `2` + 手机号 | `302010102 账号不存在` |
| `2` + accountId | `302010108 用户名密码错误` |
| **`3`** + accountId + 验证码 | **`code:0 SUCCESS`** ← 验证码直登 |

### 7.2 取包：`key` 是唯一参数名，响应是裸 zip

```
GET /carownerservice/v3/api/carpicture/key/package?key=<h5Key>   → 3 953 803 B  package.zip
GET /carownerservice/v3/api/carpicture/key/package?key=<srcKey>  → 10 634 536 B package.zip
```

- 响应头 `content-type: application/octet-stream`、`content-disposition: attachment; filename=package.zip`
- magic `PK`，**不是 JSON**
- 参数名写错会回 `Required String parameter 'key' is not present`（这个报错直接指明了参数名）
- 用 `h5Key` / `srcKey` / `whole` / `vin` 当参数名全部无效

### 7.3 包里到底是什么（**不是多角度图序列**）

之前根据 `3DHoleCarImage` 猜「多角度渲染图帧切换」，**猜错了**。实际是：

| 包 | 内容 |
|---|---|
| `key=h5Key` | `index.html`(458 B) + `index.js`(1 617 585 B，three.js webpack 产物) + `FBX.worker.js`(387 978 B) + `models/`(7 个 fbx：充电枪/天空球/车道线/阴影) + `textures/`(36 张) |
| `key=srcKey` | `D19_2026/D19_2026_full_car.fbx`(**5 898 336 B**) + `_starter_car.fbx`(4 164 688 B) + 轮胎/阴影/雾灯/环绕灯贴图 + `CarPaintConfig.csv` + `CarRoofConfig.csv` + 7 个版型 CSV |

即：**真·FBX 三维模型 + three.js 渲染器**，不是图片序列。

### 7.4 查看器驱动契约（从 `index.js` 读出来的，已本地实测跑通）

```js
window.onIOSWebview();                 // 打开开关 → 首帧完成后走 window.prompt("onFirstFrame")
window.newInit(serverJson, appJson);   // 两个参数都是 JSON **字符串**（内部 JSON.parse）
window.setRect(w, h);                  // 旋转/分屏后重设画布
window.switchCar / window.newSwitchCar // 换车
window.setDampFactor(v)                // 阻尼
```

- `serverJson` ← 就是 `3d/key` 返回的 `modelParam`（`parseServerJson` 直接吃
  `carType`/`year`/`carTypeCode`/`colorCode`/`roofColor`/`rudder`/`seat`/…）
- `appJson` ← `{width, height, energy, inland}`
- 模型路径写死在 `index.js` 里：`./{cartype}_{caryear}/{cartype}_{caryear}_full_car.fbx`
- `index.js` **零 import/export**（纯 IIFE webpack 包），但用 `new Worker("./FBX.worker.js")`
  在 Worker 里解析 FBX → WKWebView 里**不能**用 `loadFileURL`（file:// 唯一源会拦 Worker/XHR）

### 7.5 本地实测（`ios/tools/car3d_webtest.mjs`）

用 headless Chromium 起静态服务跑官方查看器，日志确认：

```
onStarterCarLoadedCallback执行
从模型获取实际车辆尺寸:{"length":5.23,"width":2.24,"height":1.81}
自动计算结果: offset=0.4056, radius=23.315
[DBG-ONFIRSTFRAME] postMessage to worker (full_car)
worker onmessage(code=0) -> firing onFullCarLoadedCallbacks
onFirstFrame
```

→ 渲染截图见 `render_test.png`（黑色 D19 六座，可旋转）。
