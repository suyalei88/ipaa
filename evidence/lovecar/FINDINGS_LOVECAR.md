# 官方「爱车」页 —— 结构与数据源逆向

> 目标：把官方 App 底部「爱车」Tab 的**全部功能**在第三方客户端里复刻出来。
>
> 证据来源：
> - 用户截图（已绑车态，见 `clipboard-2026-10-08T03-37-48-432Z-70bfcca7.jpg`）
> - 三份真实抓包：`Stream-2026-10-07 13_30_45.har`、`appgateway…13_25_47.har`、
>   `appgateway…14_05_58.har`、`appgateway…15_30_32.har`
> - 官方 iOS IPA（`com.leapmotor.developer` v1.22.68）主二进制字符串表
> - 官方 Android APK 内的静态资源

---

## 1. ★ 先纠一个容易搞错的认知：爱车页有两个状态

官方「爱车」页**不是一个固定页面**，它按「这台账号下有没有绑车」分成两套完全不同的内容：

| 状态 | 内容 | 数据来源 |
|---|---|---|
| **未绑车态** | 营销页：在售车型卡、预约试驾 / 立即预定、在线客服、金融方案、版型对比 | OSS 上的 3 个配置 txt（见 §2） |
| **已绑车态** | 控制页：车况摘要 + 3D 车模 + 快捷操作 + 预约充电 + 空调 + 地图 + 蓝牙钥匙 | `signal/info/query` + `3d/key` + `commonConfig` + `remotectl` |

**用户给的那张截图是「已绑车态」**，也是本次复刻的对象。

⚠️ 注意：`evidence/car3d/apk/lovecar.json` 与 `home-lovecar.json` **不是**页面配置，
它们是 Lottie（After Effects Bodymovin）动画，内容是「车灯亮起」的动效，
只是文件名里带 lovecar 而已 —— 这个坑值得记一笔。

---

## 2. 未绑车态的三个配置源（已抓到实物）

| URL | 内容 |
|---|---|
| `ueapp.oss-cn-hangzhou.aliyuncs.com/nativeApp/loveCar/love_car_default_header.txt` | 在售车型数组：`carName` / `carBackImageURL` / `advantages` / `actionButtons`（预约试驾、立即预定） |
| `…/nativeApp/loveCar/love_car_information_dev_default_<车型>.txt` | 车型详情模块：在线客服（`tel` / `avatarImage`）、预约体验、金融方案、版型列表（`price` / `buttonJumpUrl`） |
| `…/nativeApp/loveCar/loveCarSwitchConfig-official.txt` | 页面右上角切换入口：「我的订单」「去看车」「我的配置」「返回爱车」 |

响应体已原样存进 `evidence/lovecar/`。

> 本 App 不做营销页 —— 它需要跳转一堆官方 H5，与「纯车控」的定位无关。

---

## 3. 已绑车态：模块清单与数据源

按官方截图的**从上到下顺序**：

| # | 模块 | 官方 UI | 数据源（已实测） |
|---|---|---|---|
| 1 | 顶部车辆栏 | 「D19」+「状态更新 今天 11:27」+ ♡ + ⚙️ | `vehicle/list`（车名）+ 车况采集时间 |
| 2 | 续航主数字 | 大号「224km」 | signal `3257`（标准 A）/ `3260`（标准 B） |
| 3 | SOC 进度条 | 绿色进度条 | signal `100003`（BMS SOC，带 1 位小数） |
| 4 | 车门锁态 | 「🔒 车门已锁」 | signal `1298`（冗余 `3262`） |
| 5 | 充电中心入口 | 胶囊按钮 | → 充电页 |
| 6 | **3D 车模** | 可全方位拖动的车图 | `carpicture/3d/key` 的 `modelParam` + 离线 H5/FBX 包（见 `evidence/car3d/FINDINGS_CAR3D.md`） |
| 7 | 快捷操作（可翻页） | 第 1 页：解锁/上锁/后备箱/车窗 | cmdid `110` / `110` / `130` / `230` |
| 8 | 预约充电横幅 | 「已预约充电，请及时插枪」+ 时段 | `vehicleinfo/commonConfig` 的 `config["3"]`（`beginTime` / `endTime` / `percent` / `cycles`） |
| 9 | 车内温度 / 空调 | 大号温度 + 风扇按钮 | signal `1349`（车内温度）+ `1938`（空调开关）；风扇按钮下发 cmdid `170` |
| 10 | 地图卡 | 车辆位置 + 鸣笛寻车 | signal `2190`/`2191`（坐标）+ cmdid `120`（鸣笛） |
| 11 | 蓝牙钥匙 | 「蓝牙钥匙」 | `commonConfig` 的 `config["4"]`（`mac` / `version`） |

### 3.1 快捷操作第 2 页是什么

官方 RN bundle 里的明文常量：

```js
quickActions = [{unlock:110}, {trunk:130}, {horn:120}, {ac:170}, {windows:230}]
signalMappings = {unlock:1298, trunk:1281, windows:1693, ac:1938}
```

即官方一共 6 个：解锁 / 上锁 / 后备箱 / 鸣笛寻车 / 空调 / 车窗。
按 4 列网格分页就是 `4 + 2`。本 App 第 2 页补满了 4 个：
鸣笛寻车 / 空调开 / 空调关 / 上电（cmdid `400`，已实测）。

### 3.2 车窗为什么是一个按钮而不是三个

官方爱车页的快捷区只有**一个「车窗」按钮**，点开才选开度。
本 App 照做：按钮 → `confirmationDialog` 弹「关闭 / 微开 / 半开」，
三者都走同一个 cmdid `230`，只是 `{"value": 0|2|5}` 不同。

⚠️ 沿用 `LMEndpoints.WindowOpening` 里记录的那个**已知未定项**：
`2` 与 `5` 谁是「半开」谁是「微开」没有直接证据（抓包里两个值都出现过，
但没人记录当时按的是哪个按钮）。当前按「数值越大开得越大」假设排：
`2 = 微开`、`5 = 半开`。实测发现反了的话，改 `WindowOpening` 的 rawValue 即可。

---

## 4. ★ 明确**没有**复刻的部分（以及为什么）

### 4.1 驻车照片

官方地图卡里有一张「驻车照片」（车停稳时拍的图，存服务端再按停车点回放）。
**本 App 不做**，三条理由：

1. 主二进制字符串表里扫不到任何像「取驻车照片」的路径；
2. 四份 HAR 里没有任何一次请求像在取这张图；
3. `vehicleinfo/parking/query` 是**纯路径猜测**（只有字符串表里那一段，
   服务名前缀是推的），实测响应里没有图片字段。

与其放一张假图，不如把已确认的东西做扎实。契约测试里有一条**反向断言**
（`test_lovecar_page` → 「没有把『驻车照片』做成 UI 元素」），
防止后人「顺手补上」时糊一张假图进去。

### 4.2 空调设定温度

官方左侧大号数字是**设定温度**（截图里 23℃）。
但我们没有可靠的设定温度信号：

| signalId | 实测值 | 判定 |
|---|---|---|
| `10707` | −6 | 负数不像环境温度，更像偏移量 |
| `644` / `645` / `865` / `866` | 在 0 与 21 之间跳 | 四路同时跳，标「疑似」 |

所以本 App 那个位置放的是**已确认的车内温度**（`1349`），
并在卡片里注明「车内温度」。真正的风量 / 温度下发在「车控」页的空调卡里
（`LMEndpoints.hvacManualState(gear:temperature:)`，键有证据、组合无样本，那里有明确标注）。

### 4.3 未绑车态的营销内容

见 §2，属于官方 H5 导流，与车控无关。

---

## 5. 顺带确认的两件事

- **`appImage/getAppImage`**：返回模块示意图（胎压 / 直进直出 / 辅助泊车…）的 OSS 图片 URL。
  已在 `LMEndpoints.Path.appImage` 记录，本轮未接入 UI。
- **`chassis/query`**：返回的是一张**底盘图片**（`ChassisPicture/prod/<VIN>`），
  **不是**定位接口。之前「官方定位页可能用它」的猜测已被抓包证伪，
  坐标只可能来自 signalMap 的 `2190`/`2191`。
