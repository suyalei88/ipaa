# 打包 IPA 指南

> **先说清楚**：iOS 应用只能用 Apple 的 Xcode 工具链编译，**Windows / Linux 上不存在可用的 Swift-iOS 编译器**。
> 所以「在这台 Windows 上直接吐出一个 .ipa」是做不到的。
> 但下面两条路都能让你拿到**真正可安装的 .ipa**，其中方案 A 连 Mac 都不用。

---

## 方案 A：GitHub Actions（不需要 Mac）★ 推荐

云端有一台 macOS runner 替你编译，你只需要一个 GitHub 账号。

### 步骤

1. **建仓库**
   ```bash
   cd leapmotor-thirdparty
   git init -b main
   git add .
   git commit -m "LeapmotorLite: third-party car control client"
   ```
   > `.gitignore` 已经排除了 270MB 的 APK / 175MB 的 IPA / 抓包 HAR 和 `session.json`，
   > 所以仓库很小，能正常推送。

2. **推到 GitHub**（网页建一个空仓库，别勾 README）
   ```bash
   git remote add origin https://github.com/<你的用户名>/leapmotor-lite.git
   git push -u origin main
   ```

3. **触发构建**
   仓库页 → **Actions** → 左侧 **Build IPA** → 右上 **Run workflow** → Run

4. **下载产物**
   跑完（约 3–6 分钟）点进这次 run，页面底部 **Artifacts**：
   - `LeapmotorLite-unsigned-ipa` ← **要的就是这个**（里面有 `dist/LeapmotorLite-unsigned.ipa`）
   - `LeapmotorLite-app-bundle` ← 备用（.app 目录，便于检查结构）

### 流水线做了什么

```
job 1  vectors (ubuntu)      算法向量回归 + 图标生成 + 工程自检   ← 秒级，先挡掉低级错误
job 2  build   (macos-14)    make_icon → gen_xcodeproj → xcodebuild → zip 成 .ipa
```

---

## 方案 B：本地 Mac，一条命令

任何一台装了 Xcode 的 Mac 都行（自己的、公司的、借的）。

```bash
cd leapmotor-thirdparty
bash ios/build_ipa.sh
```

产物：`dist/LeapmotorLite-unsigned.ipa`

脚本会自动：生成图标 → 生成 `.xcodeproj`（**不需要 XcodeGen**）→ `xcodebuild` 编译 → 打包成 `Payload/*.app` 的 zip。

### 想要直接签名版

如果你有 Apple 开发者账号且证书已装进钥匙串：

```bash
DEVELOPMENT_TEAM=你的TeamID bash ios/build_ipa.sh
```

产物变成 `dist/LeapmotorLite-signed.ipa`，可以直接用 Apple Configurator / Xcode Devices 装。

---

## 装到 iPhone 上

未签名的 IPA 本身装不上，需要用工具**用你自己的 Apple ID 重签**：

### Sideloadly（Windows / macOS，最省事）

1. Windows 上装 [iTunes](https://www.apple.com/itunes/)（提供 Apple 驱动）；macOS 不用
2. 下载 [Sideloadly](https://sideloadly.io/)
3. iPhone 用数据线连电脑，信任此电脑
4. Sideloadly 里：
   - `IPA` 选 `LeapmotorLite-unsigned.ipa`
   - `Apple ID` 填你自己的
   - 点 **Start**，输密码（会走 Apple 服务器，密码不落地）
5. 手机上：**设置 → 通用 → VPN与设备管理 → 开发者App** → 信任你的 Apple ID

> ⚠️ 免费 Apple ID 签的 App **7 天后失效**，到期用 Sideloadly 重签一次即可（数据不丢，登录态在 Keychain 里）。
> 付费开发者账号（$99/年）是 1 年。

### AltStore / SideStore（手机上自签，需常驻）

装一次 AltStore，之后可以在手机上无线重签，不用连电脑。同样 7 天周期（AltStore 会自动续）。

### TrollStore（装了可永久免签）

只支持特定 iOS 版本（大致 iOS 14.0 – 17.0 的部分版本）。装好后可以直接安装任意未签名 IPA，
**永久有效、不掉签**。查你的版本能不能用：TrollStore 的兼容性表。

---

## 首次使用 App

1. 打开 → **设置 → 诊断 → 算法自检** → 应全部 ✅（说明签名/加密实现与官方 App 逐字节一致）
2. 首页 → 输手机号 → **获取验证码** → 填 6 位验证码 → **登录**
3. **设置 → 操作密码** → 填 6 位（官方 App 车控时要求输入的那个）
4. **车控** 页点按钮

> 登录态只存本机 Keychain，不上传任何服务器。
> JWT 约 2 小时过期，过期后重新短信登录一次。

---

## 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| `xcodebuild: error: The project does not contain a scheme named "LeapmotorLite"` | `.xcodeproj` 没生成好。跑 `python3 ios/tools/gen_xcodeproj.py` 重生成 |
| 编译报 `No such module 'CommonCrypto'` / `'CryptoKit'` | Xcode 版本太老。需要 Xcode 15+（iOS 17 SDK）。`xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| Sideloadly 报 `Provision.cpp:150` / 无法安装 | 换根 USB 线或用原装线；先在 iTunes 里确认能识别设备 |
| 手机上 App 图标是白的 | 图标没生成。跑 `python3 ios/tools/make_icon.py`（需要 `pip install pillow`）后重新打包 |
| 打开就闪退 | 先确认是 iOS 17+；再看 Xcode Devices 里的崩溃日志。大概率是 Sideloadly 签名时 bundle id 冲突，换个 Apple ID 或删掉旧的重装 |
| 自检里 `signKey 派生` 失败 | 说明代码被改坏了。`git diff` 看 `Crypto/` 目录 |
| 登录提示 `1019 参数不能为空`（**获取验证码**时报） | `phoneNo` 是 base64 密文，里面的 `+` 必须转义成 `%2B`。**别用 `URLComponents.queryItems`** —— `+` 属于 `CharacterSet.urlQueryAllowed`，它不会转义，服务端按 form 规则把 `+` 解成空格 → 密文损坏。用 `LMClient.makeURL(host:path:params:)`。实测：裸 `+` → 1019，`%2B` → code 200 |
| 登录提示 `1019 参数不能为空`（**提交验证码**时报） | `check_login_with_phone` 必须发 form-urlencoded（代码里已经是，别改成 JSON） |
| 登录提示 `302002002 签名信息校验失败` | 登录前签名必须是 **SHA256(valueStr)**，不是 HMAC |
| 登录提示 `302010202 第三方TOKEN失效` | 短信验证码/外层 token 过期了，重新获取验证码 |

---

## 改 Swift 代码前必看：已踩过的坑

这些是首次真机编译（Xcode 15.4 / iPhoneOS 17.5 SDK）+ 首次真机运行暴露出来的，
静态审查几乎看不出来。**改完代码先跑一遍自动检查，能省好几轮 CI（每轮约 2.5 分钟）：**

```bash
python3 ios/tools/lint_swift.py     # CI 里也会跑，命中直接 fail
```

它覆盖下面 R1–R5 五条。R6 靠真机跑自检 + 实际请求验证。

### R1（★ 最容易中，会导致线上请求失败）拼 URL 不要用 `URLComponents`

```swift
// ✗ 业务错误 1019：参数不能为空
var comps = URLComponents(string: host + path)!
comps.queryItems = [URLQueryItem(name: "phoneNo", value: enc)]   // enc 是 base64

// ✓
let url = makeURL(host: host, path: path, params: ["phoneNo": enc])
```

`+` 属于 `CharacterSet.urlQueryAllowed`，`URLComponents.queryItems` **不会**把它转义成 `%2B`。
而 RSA / AES 密文的 base64 里 `+` 很常见，服务端按 form 规则解码时把它当成空格，
密文随之损坏。实测对比：

```
phoneNo=<裸 + 的密文>     → {"code":1019,"success":false,"msg":"参数不能为空"}
phoneNo=<+ 转成 %2B>      → {"code":200,"success":true,"msg":"操作成功"}
```

（Python 端的 `requests` 会自动转义，所以同一份逻辑 Python 能跑通、Swift 跑不通。）

### R2 自定义颜色不能写前导点简写

```swift
// ✗ error: type 'ShapeStyle' has no member 'lmAccent'
Image(systemName: "car.fill").foregroundStyle(.lmAccent)

// ✓
Image(systemName: "car.fill").foregroundStyle(Color.lmAccent)
```

`foregroundStyle` 收的是泛型 `ShapeStyle`，前导点简写推不出**自定义** Color 成员。
SwiftUI 只给标准色声明了 `extension ShapeStyle where Self == Color`，所以 `.green` / `.red`
这类能用，`.lmAccent` 不行。

注意 `.tint(.lmAccent)` 是**可以**的 —— `tint` 收的是具体 `Color`，不是泛型。

### R3 三元运算符两分支必须同类型

```swift
// ✗ .red → Color，.secondary → HierarchicalShapeStyle，两者不同类型
.foregroundStyle(isError ? .red : .secondary)

// ✓
.foregroundStyle(isError ? Color.red : Color.secondary)
```

### R4 `withUnsafe*` 闭包里别访问外层变量

```swift
// ✗ error: overlapping accesses to 'out', but modification requires exclusive access
out.withUnsafeMutableBytes { outBuf in
    CCCrypt(..., inBuf.baseAddress, data.count,
            outBuf.baseAddress, out.count, &moved)
}

// ✓ 容量先在闭包外取好
let outCapacity = out.count
let inLength = data.count
out.withUnsafeMutableBytes { outBuf in
    CCCrypt(..., inBuf.baseAddress, inLength,
            outBuf.baseAddress, outCapacity, &moved)
}
```

`withUnsafeMutableBytes` 是对变量的**修改**访问，闭包内再读它的属性（哪怕只是 `.count`）
就会触发 Swift 的独占访问检查。

### R5 Keychain 属性字典的键类型

```swift
// ✗ error: cannot convert value of type 'String' to expected dictionary key type 'CFString'
let attrs: [CFString: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
]

// ✓
let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
]
```

### R6 `ForEach` 的类型推断级联（只能靠读错误日志判断）

`ForEach(xs) { ... }` 报出这类**看起来毫不相关**的错误时：

```
cannot convert value of type '[LMVehicle]' to expected argument type 'Binding<C>'
generic parameter 'C' could not be inferred
initializer 'init(_:)' requires that 'Binding<Subject>' conform to 'StringProtocol'
```

八成不是 `ForEach` 本身的问题，而是**闭包体里别处有类型错误**（比如 R2 那种），
导致编译器回退去试 `Binding<C>` 重载。先把闭包内的错误修掉；
想彻底消除歧义就显式给 id：

```swift
ForEach(client.vehicles, id: \.vin) { v in ... }
```

---

## CI 依赖相关的坑

### `build` 和 `vectors` 是两个独立 runner

`vectors` job 里 `pip install` 的东西**不会**带到 `build` job。
所以 `build` job 里不要调用任何需要第三方库的 Python 脚本 ——
图标是随仓库提交的，`build` 只需 `test -f` 确认存在即可。

### 本地能跑 ≠ CI 能跑

本地 Python 环境通常装了一堆包，会**掩盖**依赖缺失。
CI 只装 `requirements.txt` 里的东西。想本地复刻 CI 环境：

```bash
python -m venv /tmp/ci_venv
/tmp/ci_venv/bin/pip install -r requirements.txt
/tmp/ci_venv/bin/python client/test_swift_vectors.py
```

**不要**把 `requirements-recon.txt`（capstone / lief / numpy / gmssl）装进 CI ——
那些只给逆向侦察脚本用，CI 不跑。

---

## 仓库结构（和打包相关的部分）

```
leapmotor-thirdparty/
├── .github/workflows/build-ipa.yml   # 方案 A：云端打包
├── .gitignore                        # 已排除 270MB APK / 175MB IPA / session.json
├── IPA_BUILD.md                      # ← 本文
├── ios/
│   ├── build_ipa.sh                  # 方案 B：Mac 一键打包
│   ├── tools/
│   │   ├── gen_xcodeproj.py          # 纯 Python 生成 .xcodeproj（不依赖 XcodeGen）
│   │   └── make_icon.py              # 生成 1024 图标 + Assets.xcassets
│   └── LeapmotorLite/
│       ├── LeapmotorLite.xcodeproj/  # 由 gen_xcodeproj.py 生成
│       └── LeapmotorLite/            # 15 个 Swift 文件 + Info.plist + Assets.xcassets
└── client/test_swift_vectors.py      # 算法向量回归（无需 Xcode）
```

---

## 为什么不直接用官方 App 的 IPA 改包

技术上可行（`evidence/leapmotor.ipa` 就是解密后的），但：

- 它是**加密 + 混淆**的 Release 包，改动风险高、体积大（175MB）
- 我们已经有**自己写的干净 SwiftUI 前端**（2271 行，零第三方依赖）
- 从源码编译出来的包**不含任何官方代码**，权属清晰

所以本项目走「自己编译」路线。
