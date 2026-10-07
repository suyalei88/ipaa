# 抓包 SOP — 必须抓到 `api.leapmotor.com`

## 现状诊断

你给的 `sniffmaster-proxy-*.har`：
- 只有 **8 条**请求，来自 **iOS**（UA `leapmotorCarOwner/1.22.68`）
- 抓到：埋点 `lpex-eventtracking`、阿里 HTTPDNS `223.6.6.6`、OSS 图片
- **没抓到**：`api.leapmotor.com` 的登录/车控

**原因判断**：`api.leapmotor.com` 有 **SSL Pinning**，代理解不开；埋点域名没 pin 所以能抓。
（埋点 body 是加密的：熵 7.9/8，长度非 16 倍数，`Decrypt-Version: v1.0.0`）

→ 结论：**必须过 SSL Pinning**，否则永远抓不到登录。

---

## 方案 A（推荐）：抓 Android 端

我们已有 Android APK 的完整分析，签名算法已还原，抓 Android 最省事。

### 环境
- Root 安卓机（真机/模拟器均可）+ Magisk
- `frida-server`（改个名，Zygisk + DenyList 隐藏 root）
- PC 跑 mitmproxy

### 步骤
```bash
# 1. PC 起代理
mitmdump -s capture/mitm_capture.py -p 8080

# 2. 手机装 mitm 证书到系统区（Android 7+ 必须）
#    /system/etc/security/cacerts/<hash>.0

# 3. 过 pinning + 抓 signKey（同时跑）
frida -U -f com.dahua.leapmotor -l frida/hook_leapmotor.js --no-pause

# 4. APP 里：退出登录 → 重新登录（短信验证码）→ 操作一遍车控
#    （锁车/解锁/寻车/空调/车窗/后备箱/充电）
```

### 抓完要看到
```
evidence/flow_*.json   里出现 api.leapmotor.com 的 POST
  - 登录请求（含 phone/code）
  - 车控请求（含 vin）
```

---

## 方案 B：抓 iOS 端

iOS 上抓需要越狱环境。

- **越狱机**：装 `SSL Kill Switch 3` 或 `Frida` + `frida-ios-dump`
- **未越狱**：用已注入 unpinning 的 IPA（如 `objection` patch 过的包）
- 代理用 **Stream / Charles / mitmproxy**（sniffmaster 支持 pinning bypass 的版本）

关键：**必须让 `api.leapmotor.com` 走代理并解密成功**。

---

## 抓完自检（一条命令）

```bash
python client/har_analyze.py <你的.har>
```

看输出：
- 主机分布里**必须出现 `api.leapmotor.com`**
- 请求里有 `POST /...login...`、`sign:` 头

如果出现了登录请求，直接：
```bash
python client/har_analyze.py <你的.har> --host api.leapmotor.com
```
把结果发我 → 我立刻补全端点表 + 验证签名。

---

## 抓包时必看清单

| 项 | 说明 |
|---|---|
| ✅ 退出登录再登录 | 否则登录请求不会重新发 |
| ✅ 短信验证码流程走完 | 可能有多步（发码 → 校验 → 换 token） |
| ✅ 每个车控动作都点一遍 | 拿全端点 |
| ✅ 保留请求头 | `sign`/`token`/`carvin`/`cartype`/`deviceId` 是关键 |
| ✅ 保留请求体 | 车控参数格式 |
| ⚠️ 别用"只抓 APP"模式漏掉主域名 | 检查主机分布 |
