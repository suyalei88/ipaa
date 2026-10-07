# 零跑 APP 逆向分析报告

- **目标**: `106_1667fc4240bafd21427eb90d2a335e9d.apk`
- **包名**: `com.dahua.leapmotor`（大华代工零跑）
- **SHA-256**: `aa833f326138f8151e396383905106cf352dee016961b09c615eea1726fefa24`
- **大小**: 286,898,812 bytes / 10,627 files
- **签名**: `META-INF/LEAPMOTO.RSA`
- **加固**: **360 加固（jiagu VIP）** — `Lcom/stub/StubApp;`、`assets/libjiagu_vip*.so`、`libjgdtc.so`
- **UI 框架**: React Native（Hermes）+ 原生

---

## 1. 关键突破：RN bundle 是明文 JS

jiagu 只加密 `classes.dex`，**不碰 `assets/rn/index.android.bundle`**。

```
assets/rn/index.android.bundle  3,050,414 bytes  ← 明文 Metro JS
```

这一条把"脱壳"绕过去了：HTTP 层、签名算法、配置全在这里。

---

## 2. 域名清单

| 域名 | 用途 |
|---|---|
| `api.leapmotor.com` | **业务 API 主入口**（envConfig.apiBaseUrl） |
| `appgateway.leapmotor.com` | 网关 / APP 更新介绍 / 远程解锁 H5 |
| `apptec.leapmotor.com` | H5 容器（我的能量/权益/救援等） |
| `apptec-{dev,test,pre,ue}.leapmotor.com` | 各环境 H5 |
| `mall / lpmall / bbcmall.leapmotor.cn` | 商城 |
| `lptestdrive.leapmotor.com` | 试驾 |

RN 里确认的配置：
```js
envConfig = { envName:"production", apiBaseUrl:"https://api.leapmotor.com", ... }
```

---

## 3. 请求签名算法（★ 已完整还原并验证）

位置：`index.android.bundle` 模块 542 / 543。

### 3.1 签名头构造
```js
var headerInfo = getAuthProvider().getRequestInfo(NORMAL);   // ← native 下发
var signHeaders = {
  acceptLanguage, deviceType, source, version,
  channel, deviceId, timestamp, nonce
};
if (headerInfo.signKey) {
  var valueStr = buildSignValueString(body, signHeaders);
  var sign = generateHmacSha256(valueStr, headerInfo.signKey);
  headers.sign = sign;
}
```

### 3.2 待签名串（关键：只拼 value、按 key 升序、无分隔符）
```js
function buildSignValueString(body, signHeaders) {
  var signObj = {};
  Object.entries(body).forEach(([k,v]) => signObj[k] = v);
  Object.entries(signHeaders).forEach(([k,v]) => signObj[k] = v);
  return Object.entries(signObj)
    .filter(([k,v]) => v != null && v !== undefined && v !== "")
    .sort(([a],[b]) => a<b ? -1 : a>b ? 1 : 0)
    .map(([k,v]) => formatSignValue(v))   // ← 只有 value
    .join("");                            // ← 无分隔符
}
```

### 3.3 取值格式
- 数组无对象 → `value.toString()`（逗号连接）
- 数组含对象 → 每项 `{k=v, k=v}`，逗号连接
- 其它 → `String(value)`

### 3.4 HMAC key 解析
```js
parseKeyString(key): 全 hex 字符 → hex 解码成字节；否则 UTF-8 编码
```

### 3.5 算法结论
```
sign = HMAC_SHA256( valueStr , signKey ).hex()      // 64 位小写 hex
```

### 3.6 验证（Node 原始 JS vs Python 复现，逐字节一致）
| 输入 | valueStr | sign |
|---|---|---|
| 简单 | `zh-CNlockofficialabc123android123456app17280000000001.0.0TESTVIN0000000000` | `7ddfe7aa67f376a1e7db8ce463d028c80897f460f1e5b4c3de9f0462a22a7f39` |
| 边界(数组/布尔/对象) | `1,2,3true0{x=1},{x=2}21` | — |

> 复现器：`client/leapmotor_client.py`（Python）、`client/verify_sign.js`（JS 基准）

---

## 4. 完整请求头集合

| Header | 值 |
|---|---|
| `Content-Type` | `application/json` |
| `sign` | HMAC-SHA256 签名 |
| `acceptLanguage` | 如 `zh-CN` |
| `deviceType` | `android` |
| `source` | `app` |
| `version` | APP 版本 |
| `channel` | 渠道 |
| `deviceId` | 设备号 |
| `timestamp` | 毫秒时间戳 |
| `nonce` | randomInt32 |
| `x-subversion` / `x-canary-version` | 灰度 |
| `x-api-signature-version` | **`2.0`** |
| `x-region` | `CN` |
| `userId` | 用户 ID |
| `token` | 登录 token |
| `carvin` / `cartype` | **车辆 VIN / 车型（车控必需）** |

---

## 5. 未静态获取的部分（需运行时）

| 项 | 位置 | 获取方式 |
|---|---|---|
| `signKey` | native `AIRequestInfoPlugin.getRequestInfo()` | Frida hook（见下） |
| 车控端点路径 | native（jiagu dex 内） | OkHttp hook / mitmproxy 抓包 |
| `token` | 登录后由 native 下发 | 抓包 |

### Native 插件清单（RN 侧可见）
`AIRequestInfoPlugin`(鉴权/签名) · `AICarInfoPlugin`(车况) · `AICoordinatePlugin` ·
`AIDeeplinkPlugin` · `AILifeCyclePlugin` · `AILogPlugin` · `AIOpenWebViewPlugin` ·
`AIPhoneNetPlugin` · `AIRecordPlugin`

RN 侧只负责 AI 助手（`/appaicenter/v3/api/bigmodelapp/v2/*`）+ HTTP 基础设施；**车控在 native**。

---

## 6. 附带泄露（非车控）

讯飞语音 ASR 密钥硬编码在 JS（模块 605）：
```
appId:     5bf501be
apiKey:    4f45f25ef23d6b52ad652b8bd370aa46
apiSecret: 5bf4623118f39b9f34ad101b402915bf
hostUrl:   wss://iat.xf-yun.com/v1
```
> 这是语音识别服务的密钥，与车控无关，但属于硬编码凭据问题。

---

## 7. 下一步（运行时闭环）

```bash
# 1. 设备需 root + Magisk 隐藏（jiagu 有反 Frida）
# 2. 抓 signKey + 真实车控请求
frida -U -f com.dahua.leapmotor -l frida/hook_leapmotor.js --no-pause

# 3. 同时抓包（SSL unpinning 见 hook_ssl_bypass.js）
mitmdump -s capture/mitm_capture.py -p 8080
```
拿到 `signKey` + 车控端点后：
1. 填 `client/leapmotor_client.py` 的 `Config.sign_key`
2. 用抓到的请求验证签名一致 → 即可用 Python 直接发车控指令
3. 接入 `app/server.py` 前端

---

## 8. 抓包分析（login.har）

`sniffmaster-proxy-1791164793602.har`（8 条，**iOS 端**）：

| 主机 | 条数 | 说明 |
|---|---|---|
| `lpex-eventtracking.leapmotor.com` | 3 | 埋点，**加密** |
| `ueapp.oss-cn-hangzhou.aliyuncs.com` | 3 | OSS 图片 |
| `223.6.6.6` | 2 | 阿里 HTTPDNS |

**未抓到 `api.leapmotor.com`** → 判断为 SSL Pinning 拦截。抓包 SOP 见 `capture/CAPTURE_SOP.md`。

### 可复用情报
| 项 | 值 |
|---|---|
| iOS UA | `leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)` |
| 设备号 | `did=C7v9qvPIb1ce` |
| HTTPDNS | `223.6.6.6`（阿里云），`ak=17890_31177745471003648`，`uid=17890`，`pf=ios`，`sv=2.2.1` |
| HTTPDNS key | `e10e0814b5beb7b9e6f8dae5bf1eb865719f5aba8f02eb50c76000811d42122a` |
| WAF Cookie | `acw_tc=...`（阿里 WAF） |

### 埋点加密特征（`Decrypt-Version: v1.0.0`）
- 密文 = base64，熵 **7.89~7.97 / 8**，无 ECB 块重复
- 长度非 16 倍数（余 8/1/3）→ 非裸 AES-CBC/ECB，疑似 **AES-CTR/GCM 或先压缩再流加密**
- Android 包里**搜不到** `lpex`/`eventtracking` → 该埋点 SDK 是 iOS 端专用

### 分析工具
```bash
python client/har_analyze.py <har>              # 解析 + 主机分布
python client/har_analyze.py <har> --sign-key K # 自动验签
```

---

## 9. 证据文件

> **2026-10-07 清理说明**：本仓库最终交付的是 **iOS 版**，安卓侧的原始包与解包产物
> （`leapmotor.apk` 274M、`unpack/` 47M）已删除以省空间。它们的分析结论全部保留在
> 本文档与 `FINDINGS_CRYPTO.md` 里，哈希见上文「原始素材」。需要重跑安卓侧扫描时，
> 自己放一份官方 APK 到 `evidence/leapmotor.apk` 即可（`scan_apk.py` 默认路径就是这个）。
> `evidence/unpack/` 可用 `unzip` / `apktool` 从该 APK 重新解出。

| 文件 | 说明 |
|---|---|
| `evidence/leapmotor.ipa` | iOS 原始包（★ 保留，API 真值来源） |
| `evidence/leapmotor.apk` | 安卓原始包（**已删**，哈希见上） |
| `evidence/scan_urls.txt` | 全包 URL/域名/关键词扫描 |
| `evidence/unpack/classes.dex` | 壳 dex（**已删**，可从 APK 重解） |
| `evidence/unpack/assets/rn/index.android.bundle` | 明文 JS（签名逻辑）（**已删**，可从 APK 重解） |
| `evidence/unpack/lib/arm64-v8a/libleapcrypto.so` | 打包 OpenSSL/BoringSSL（**已删**，可从 APK 重解） |
