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
| `evidence/` | IPA、抓包 HAR、扫描结果、**FINDINGS_CRYPTO.md 分析报告** |
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
再到 `设置 → 操作密码` 填 6 位车控密码，然后就能在「车控」页点按钮了。

---

## 四、Python 参考实现 / 回归校验

```bash
python client/leapmotor_client.py         # 自测：signKey 派生 + oppwd 加密
python client/test_sign_regression.py     # HAR 回归 → 101/105
python client/test_swift_vectors.py       # ★ 校验 Swift 自测里的全部向量（无需 Xcode）
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
| 短信验证码登录（全 4 步） | ✅ 已实测打通（收到短信 → 换 JWT → signKey → 车控成功） |
| 手机号 RSA 加密 | ✅ 已还原（SPKI→PKCS#1，1024-bit → 140 字节 DER） |
| `smDeviceId`（SM4 国密设备指纹） | ⚠️ 复用抓包值；未还原派生算法（不影响自用） |
| 账号密码登录（`security` 字段） | ⚠️ 已弃用 —— `security` 实为外层 token，改走短信登录 |
| 车控二进制响应（`LMVCloudBinaryPacket`） | ⚠️ 未解析（当前接口都返回 JSON） |
| 登录态自动续期（refreshToken） | 未实现；token 约 2h 过期，重新登录即可 |

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
- `ios/LeapmotorLite/` — SwiftUI 车控 App（15 个 Swift 文件 + Info.plist + Assets.xcassets）
- `ios/LeapmotorLite/README.md` — 编译 / 使用 / 协议文档

**逆向与分析**
- `evidence/FINDINGS_CRYPTO.md` — **完整协议分析报告（签名 / signKey / oppwd / 登录链路）**
- `client/leapmotor_client.py` — Python 参考实现（签名已还原）
- `client/leapmotor_chain.py` — ★ 完整登录链路（发码 / 登录 / 兑换 / 派生）
- `client/test_sign_regression.py` — HAR 签名回归
- `client/test_swift_vectors.py` — Swift 自测向量回归（无需 Xcode）
- `client/ios_clsmeth.py` / `ios_scan_login.py` / `ios_cfref.py` — Mach-O / ObjC 逆向工具（元类方法表 / CFF 扫描 / CFString 交叉引用）
- `client/objc_parse.py` / `macho_util.py` — Mach-O / ObjC 基础解析

**抓包辅助**
- `capture/CAPTURE_SOP_IOS.md` — iOS 抓包 SOP
- `frida/ios_ssl_bypass.js` — 绕 SSL Pinning（越狱机）
- `app/` — 早期网页版（历史产物，已停用）
