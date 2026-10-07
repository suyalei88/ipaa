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
| 登录提示 `1019 参数不能为空` | `check_login_with_phone` 必须发 form-urlencoded（代码里已经是，别改成 JSON） |
| 登录提示 `302002002 签名信息校验失败` | 登录前签名必须是 **SHA256(valueStr)**，不是 HMAC |
| 登录提示 `302010202 第三方TOKEN失效` | 短信验证码/外层 token 过期了，重新获取验证码 |

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
