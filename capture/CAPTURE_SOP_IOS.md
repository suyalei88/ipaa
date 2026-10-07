# iOS 抓包 SOP — 零跑 (leapmotorCarOwner)

iOS 比 Android 多三道坎：**FairPlay 加密**、**SSL Pinning**、**证书信任开关**。
按顺序来。

---

## 0. 先确认 Bundle ID

```bash
# 越狱机 / 已连 Frida
frida-ps -Uai | grep -i leap
# 或看 UA: leapmotorCarOwner  →  常见 com.leapmotor.carowner / com.dahua.leapmotor
```
下面用 `<BID>` 代指，例如 `com.leapmotor.carowner`。

---

## 1. 拿解密 IPA（静态分析用）

App Store 的 IPA 二进制是 FairPlay 加密的，直接反汇编看不到代码。**必须先脱壳**。

### 方式 A：越狱机 + frida-ios-dump（推荐）
```bash
pip install frida-tools
git clone https://github.com/AloneMonkey/frida-ios-dump
cd frida-ios-dump
python3 dump.py <BID>          # 输出 <AppName>.ipa（已解密）
```
> 需要 App 正在运行。脱壳原理：从内存 dump 已解密的 Mach-O。

### 方式 B：CrackerXI+ / bagbak
- CrackerXI+（越狱机 App Store 装）：勾选要脱壳的 App → 一键出 IPA
- `bagbak <BID>`（npm 包，越狱机）

### 方式 C：无越狱
- 云真机平台（带 Frida / 脱壳能力）
- 或找现成解密 IPA（来源不可控，谨慎）

**拿到解密 IPA 后发我** → 我做静态分析（找签名算法 + 端点），和 Android 那套一样。

---

## 2. 越狱 + Frida

| 芯片 | iOS | 越狱工具 |
|---|---|---|
| A11 及以下 (checkm8) | 任意 | palera1n / checkra1n |
| A12~A16 | 15.0~16.6 | Dopamine (TrollStore 方案) |
| A12+ | 16.7+ | palera1n（部分）/ 等新工具 |

装 Frida（Sileo/Cydia 添加源）：
```
https://build.frida.re
```
装完验证：`frida-ps -U` 能列出进程。

---

## 3. 过 SSL Pinning（关键）

两条路，**任选**：

### 3A. Frida 脚本（本仓库自带）
```bash
frida -U -f <BID> -l frida/ios_ssl_bypass.js --no-pause
# 另开一个窗口 dump 请求（可选）
frida -U -f <BID> -l frida/ios_hook_request.js --no-pause
```

### 3B. SSL Kill Switch 3
- Cydia/Sileo 装 `SSL Kill Switch 3`
- 设置里对目标 App 开启

---

## 4. mitmproxy + 证书信任

```bash
# PC 端
mitmdump -s capture/mitm_capture.py -p 8080
```

iPhone 端：
1. WiFi → 配置代理 → 手动 → `<PC_IP>:8080`
2. Safari 打开 `http://mitm.it` → 下载 **iOS** 证书 → 安装描述文件
3. **⚠️ 最容易漏的一步**：设置 → 通用 → 关于本机 → **证书信任设置** → 打开 mitmproxy 的完全信任

---

## 5. 抓取操作

1. APP 里 **退出登录**
2. 重新登录（走完短信验证码）
3. 每个车控动作点一遍（锁车/解锁/寻车/空调/车窗/后备箱/充电）
4. 停止抓包

---

## 6. 自检（必须看到 api.leapmotor.com）

```bash
python client/har_analyze.py <你的.har 或 mitm dump>
```
主机分布里**必须出现 `api.leapmotor.com`**，且能看到 `sign:` 头。
看到了就把结果发我 → 补端点表 + 验签。

---

## 7. 如果还是抓不到 api.leapmotor.com

按可能性排查：

| 现象 | 原因 | 处理 |
|---|---|---|
| 埋点能抓、API 不能 | API 单独做了 pinning | 确认 Frida 脚本对 `api.leapmotor.com` 生效；加 hook `SSL_CTX_set_custom_verify` |
| 全部抓不到 | 证书没信任 | 检查「证书信任设置」开关 |
| 全部抓不到 | 走了 HTTPDNS 直连 IP + 自有 TLS 栈 | hook `getaddrinfo` + 强制走代理；或改用 Frida dump 请求 |
| 部分加密 body | 业务层加密 | 正常，头里 `sign` 仍是明文 |

**兜底**：直接用 `frida/ios_hook_request.js` dump `NSURLSession` 请求，不依赖代理解密。

---

## 8. 交付给我什么

任选其一即可，我都能接着干：

1. **解密后的 IPA** → 我静态分析（最优）
2. **抓到 api.leapmotor.com 的 HAR** → 我补端点 + 验签
3. **Frida dump 的请求日志** → 同上
