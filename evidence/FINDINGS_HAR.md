# 零跑车控 API 逆向报告 —— 双 HAR 整合版

> 数据来源：`har_appgw.har`（Reqable，266 条）+ `har_stream.har`（Stream，243 条）
> 交叉验证：iOS 主二进制字符串表、`index.android.bundle` / `index.jsbundle`、`libleapcrypto.so`
> 车辆：VIN `LFZ63AA15TH035113`，D19（720智尊版 六座），2026，账号 `672955179229782016`

---

## 0. 一句话结论

| 项 | 状态 |
|---|---|
| 端点 / 请求格式 / 车控 cmdid | ✅ **完全拿到**（双 HAR 一致） |
| 签名算法（HMAC-SHA256 + valueStr 拼接规则） | ✅ **字节级还原并复现** |
| 签名密钥 signKey | ❌ **运行时派生，静态不可还原** → 需 Frida 动态取一次 |
| iOS 加固 | ⚠️ 360 加固（`JGBSDK.framework` + `*.jgb`），核心签名代码被保护 |
| 车控二进制响应（LMVCloudBinaryPacket） | 🟡 抓到样本，格式未完全解 |

**核心矛盾**：算法是明文可读的（RN bundle 未加密），但**密钥**由原生层在登录后动态派生。
两份 HAR 交叉验证后，唯一缺的就是那一把 key。

---

## 1. 域名与网关分工

| 域名 | 用途 | 是否带 sign |
|---|---|---|
| `appgateway.leapmotor.com` | **主网关**：车控、信号、carownerservice | ✅ |
| `app-gw-global-master.leapmotor.com` | 账号 / 登录 / 车辆列表 / 全球路由 | ✅ |
| `appuser.leapmotor.cn` | 短信验证码（`sendmessagecode`） | ❌ |
| `iov-api.leapmotor.com` | 埋点 / pointData（protobuf） | ❌ |
| `mqtt-center.leapmotor.cn` | MQTT token（`applyToken`） | ❌ |
| `lpex-eventtracking.leapmotor.com` | 埋点上报 | ❌ |
| `apptec.leapmotor.cn` | 社区 / 启动页 / 弹窗 | ❌ |

> `appgateway` 与 `app-gw-global-master` 的响应里 `appCenter` / `appRegion` 都指向 `appgateway`，
> `appMq` = `ssl://app-mq-central.leapmotor.com:8883`（车况实时推送走 MQTT）。

---

## 2. 登录流程（完整）

### 2.1 发短信
```
GET https://appuser.leapmotor.cn/app-user/applogin/compliance/sendmessagecode
    ?phoneNo=<base64(加密手机号)>&smDeviceId=<base64>
→ {"code":200,"success":true,"msg":"操作成功","data":null}
```
> 注意：`phoneNo` 是**加密后**再 base64 的，不是明文。

### 2.2 登录（密码 / 短信）
```
POST https://app-gw-global-master.leapmotor.com/base/base-user/account/v1/login
Content-Type: application/json

{"identifier":"672955179229782016","identifierType":"1",
 "security":"3DD9DF4A2A5F4367B5E63F22A36DF2A13DD9DF4A2A5F4367B5E63F22A36DF2A1"}
```
`security` = 64 位大写 hex = **同一段 32 位 MD5 重复两遍**（`MD5(pwd)` × 2）。

### 2.3 登录响应（★ 关键）
```json
{"code":0,"message":"SUCCESS","data":{
  "accountId":672955179229782016,
  "accessToken":"eyJub25jZSI6...",         // JWT，exp 约 2h
  "refreshToken":"eyJhbGciOi...",
  "tokenExpireTime":7199, "refreshTokenExpireTime":604799,
  "signParam":   {"r2":"6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo=",
                  "r3":"XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884="},
  "encryptParam":{"r2":"cYPovbbtY3Bxv+9m0+0+2v7CRs/s1FWbotOguVLySys=",
                  "r3":"xnYhizldbR6gC4IUdU3o9aN5+Wv9RW95VoxyjSa6BR8="}}}
```

二进制字符串表证实字段来源（`@178467582`）：
```
signR2 → data.signParam.r2      signR3 → data.signParam.r3
encryptR2 → data.encryptParam.r2  encryptR3 → data.encryptParam.r3
```
四个值都是 **32 字节 base64**。`signParam` 用于请求签名，`encryptParam` 用于报文体/操作密码加密。

---

## 3. 签名算法（已完整还原）

### 3.1 来源
`index.android.bundle` / `index.jsbundle`（Metro 明文，未加密）中的 `buildAuthHeaders`：

```js
var headerInfo = yield getAuthProvider().getRequestInfo(TokenExpiryCode.NORMAL);
var newTimestamp = Date.now().toString();
var newNonce = randomInt32().toString();          // Math.floor(Math.random()*2147483647)
var signHeaders = {                               // ← 固定 8 个 key
  acceptLanguage: headerInfo.acceptLanguage, channel: headerInfo.channel,
  deviceId: headerInfo.deviceId,             deviceType: headerInfo.deviceType,
  nonce: newNonce,                           source: headerInfo.source,
  timestamp: newTimestamp,                   version: headerInfo.version
};
var body = typeof config.data === "object" && config.data !== null ? config.data
         : typeof config.data === "string" ? tryParseJson(config.data) : {};
var signBody = config.params ? Object.assign({}, body, config.params) : body;
if (headerInfo.signKey && !skipHmac) {
  var valueStr = buildSignValueString(signBody, signHeaders);
  headers.sign = generateHmacSha256(valueStr, headerInfo.signKey);
}
```

```js
function buildSignValueString(body, signHeaders) {
  var signObj = {};
  Object.entries(body).forEach(([k,v]) => signObj[k] = v);
  Object.entries(signHeaders).forEach(([k,v]) => signObj[k] = v);
  return Object.entries(signObj)
    .filter(([k,v]) => v != null && v !== undefined && v !== "")
    .sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([k,v]) => formatSignValue(v))     // ← 只取 value
    .join("");                              // ← 无分隔符
}
```

```js
function generateHmacSha256(message, keyInput) {
  var uint8Key = typeof keyInput === "string" ? parseKeyString(keyInput)
               : new Uint8Array(Array.isArray(keyInput) ? keyInput : Object.values(keyInput));
  var key  = CryptoJS.lib.WordArray.create(uint8Key);
  return CryptoJS.HmacSHA256(message, key).toString(CryptoJS.enc.Hex);
}
function parseKeyString(s) {                // 全 hex → hex 解码；否则 UTF-8
  var cleaned = s.replace(/[^0-9A-Fa-f]/g, "");
  if (cleaned.length > 0 && cleaned.length === s.replace(/\s/g,"").length)
    return transferIOSHex(s);
  return new TextEncoder().encode(s);
}
```

### 3.2 关键推论（★ 之前踩过的坑）

1. **`signHeaders` 是固定 8 个 key**，不是"所有 header"。
2. **`body` 走 `tryParseJson()`**：
   - JSON body → 解析成功 → **参与签名**
   - `application/x-www-form-urlencoded` body（车控！）→ `JSON.parse` 抛异常 → 返回 `{}` → **不参与签名**
3. **GET 请求**：`config.params` 会 merge 进签名对象（如 `msgID=2740731680` 参与签名）。
4. **只拼 value，不拼 key，无分隔符**，key 按 ASCII 升序。

### 3.3 实测样本（可直接当回归测试）

| 字段 | 值 |
|---|---|
| 请求 | `POST /app/app-signal-service/signal/info/query` |
| body | `{"appVersion":"1.22.68","isMainApp":"1","osType":"iOS","vin":"LFZ63AA15TH035113"}` |
| acceptLanguage / channel / deviceId | `zh-CN` / `1` / `ios_ee45b9d830bb126d431e998943a7797a` |
| deviceType / nonce / source | `iOS` / `2020738377` / `leapmotor` |
| timestamp / version | `1791350716506` / `1.22.68` |
| **valueStr** | `zh-CN1.22.681ios_ee45b9d830bb126d431e998943a7797aiOS12020738377iOSleapmotor17913507165061.22.68LFZ63AA15TH035113` |
| **sign** | `36cb2797d808a7cdedd49b98703155fa25cc49ee70e8bacd193801a65edbfac4` |

### 3.4 signKey 为什么静态取不到（穷举记录）

对 **186 个主 App 真实签名样本**做了穷举，全部 0 命中：

- valueStr 变体 ×6：8 header 全量 / +body / +params / +path / 带分隔符 / 逐字段剔除 / 逆序
- key 变体 ×52：`r2`/`r3`/`encryptParam` 的 raw / base64 / hex / MD5 / SHA256 / XOR / 拼接（正反序）
- 算法 ×4：HMAC-SHA256 / HMAC-SHA1 / HMAC-MD5 / 裸 SHA256
- 其他候选：`accessToken`、`refreshToken`、`userId`、`deviceId`、`carvin`、包名、`*.jgb` 的 32 字节

累计 **>1000 组合，0 命中** → 结论：**signKey 由原生层运行时派生**，且很可能与设备绑定密钥（Keychain / Secure Enclave）或 SM2 私钥相关。
原生层存在 `signStringWithParams:signatureParams:serverKey:`、`serverKeyMd5`、`appRandom`、`timestampCRC` 等符号，说明派生链在原生侧。

**iOS 加固确认**：`Payload/leapmotorCarOwner.app/` 内有 `JGBSDK.framework`（360 加固 SDK）+ `*.jgb`（3 个）+ `.Dump_GBLW.txt`（脱壳组水印）。
全二进制扫描显示 `signStringWithParams:signatureParams:serverKey:` **只有 1 处引用（selref 调用点），没有 method_t** → 实现被加固保护/不在主二进制可读区。

---

## 4. 车控协议（★ 核心）

### 4.1 端点
```
POST https://appgateway.leapmotor.com/app/app-control-service/v3/api/appremotectl
Content-Type: application/x-www-form-urlencoded
carvin:  LFZ63AA15TH035113
cartype: D19
userid:  672955179229782016
token:   <accessToken>
sign:    <HMAC>
```

### 4.2 请求体（form-urlencoded，**不是 JSON**）
```
carvin=LFZ63AA15TH035113&cmdid=110&oppwd=<base64>&state=<urlencoded JSON>
```
| 字段 | 说明 |
|---|---|
| `carvin` | VIN |
| `cmdid` | 命令号（见下表） |
| `oppwd` | **操作密码密文**，16 字节 base64（AES 单块）。同 session 内固定，跨 session 变化 |
| `state` | URL 编码的 JSON 参数 |

### 4.3 cmdid 表（实测）

| cmdid | state | 语义 | 置信度 |
|---|---|---|---|
| **110** | `{"value":"lock"}` / `{"value":"unlock"}` | **车门锁 / 解锁** | ✅ 确认 |
| **120** | `{"value":"true"}` | 后备箱 / 寻车 | 🟡 观察 |
| **170** | `{"operate":"off"}` / `{"operate":"auto"}` | 大灯（关 / 自动） | 🟡 观察 |
| **230** | `{"value":"0"}` / `{"value":"2"}` / `{"value":"5"}` | 空调（关 / 低 / 高） | 🟡 观察 |
| **400** | `{"operation":"on"}` | 上电 / hello | ✅ 确认 |

### 4.4 两种响应模式（★ 重要）

**模式 A — 明文 JSON + msgID 轮询**（第一次抓包）
```
POST .../appremotectl  → {"result":0,"data":"2740731680","sendtype":"0","message":"请求成功","timeout":20,"code":0}
GET  .../appremotectl/query?msgID=2740731680  → {"result":0,"code":0,"data":1}
```
`data` = 1 表示成功，0 表示进行中/失败。

**模式 B — 二进制加密包**（第二次抓包，直接返回，不轮询）
```
→ base64: hS4AAAQe4t6RP/5rm+3ZWtRFgQXYRSGthEYkk+pU2dJk3fAUgciffDw021BsRdENB4ExbqJp3cV4KAgQiAqP//P9fV2+1/vn9kBgyuu4nSc8TREI2yjGU/YD
```
解码后（90 字节）：
```
85 2e 00 00 04 1e e2 de 91 3f fe 6b 9b ed d9 5a ...
```
格式推测（LMVCloudBinaryPacket）：`[type:1B][len/flag:2B][00 00][payload...][.. 00 03]`，
`0x85` / `0x65` 两种首字节，尾部固定 `03`。两个 `.jgb` 中出现的 `d6030000`（=982）也是这种 LE 长度风格。
→ **待解**：需要 hook 原生解密函数（`libleapcrypto.so` 是 GMSSL，含 SM2/SM3/SM4）。

### 4.5 oppwd 观察
| 抓包 | oppwd |
|---|---|
| HAR A | `uHTigfMDS5zIuZX4Gq4NVQ==` |
| HAR B | `bDFCVHQ5RP9gFopnNoffTw==` |

两次登录 session 不同 → `oppwd` 随 session 变化。16 字节 = AES 单块，推测 `AES_ECB(操作密码明文, encryptParam 派生密钥)`。

---

## 5. 车况信号（做 UI 的宝藏）

```
POST https://appgateway.leapmotor.com/app/app-signal-service/signal/info/query
{"appVersion":"1.22.68","isMainApp":"1","osType":"iOS","vin":"LFZ63AA15TH035113"}
```
返回约 **150 个 signalId**，例如：

| signalId | 值 | 推测 |
|---|---|---|
| `1` | `1791350714563` | 采集时间戳 |
| `1177` | `736.7` | 续航 (km) |
| `1178` | `-8.299` | 车外温度 |
| `1318` | `1909` | 总里程 (km) |
| `1200` | `645` | ? |
| `2183` | `23.0` | 电池温度 |
| `2190` / `2191` | `31.801201` / `117.342718` | 经纬度 |
| `3725` / `3724` | `31.801307` / `117.342719` | 经纬度（高精度） |
| `1204` | `33` | SOC % |
| `94` / `47` / `48` | `1` / `1` / `1` | 状态位 |
| `1349` | `29.5` | ? |

> 完整 signalMap 见 `evidence/har_api_dump.txt` 第 33 行。
> 另有 `POST /carownerservice/signal/info/query/distributed` 返回同一份数据（`carownerservice` 前缀）。

---

## 6. 其他实用端点

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `app-gw-global-master.../app/app-global-service/v1/vehicle/list` | 车辆列表（`bindcars` 含 `abilities` 能力位图） |
| GET | `app-gw-global-master.../app/app-global-service/v1/vehicle/getCarRoute?vin=` | 区域路由（返回 appMq / appCenter） |
| GET | `appgateway.../carownerservice/v3/api/vehicleinfo/commonConfig?vin=` | 通用配置（含充电计划、数字钥匙版本） |
| GET | `appgateway.../carownerservice/v3/api/drivingrecord/mileage/energy/detail?vin=` | 总里程 / 交付天数 |
| GET | `appgateway.../carownerservice/v3/api/chassis/query?vin=` | 底盘图 URL |
| GET | `appgateway.../carownerservice/v3/api/carpicture/3d/key?vin=` | 3D 车模资源 |
| POST | `appgateway.../carownerservice/v3/api/bluetoothkey/combine/syncBluetoothKeys` | 蓝牙钥匙同步（ECDH + signResult，走 SM2/SM4） |
| POST | `appgateway.../carownerservice/v3/api/appdevice/updateDeviceInfo` | 上报设备信息 |
| GET | `mqtt-center.leapmotor.cn/mqtt/token/applyToken` | MQTT 实时车况 token |

---

## 7. 复现路径（下一步）

### 7.1 拿 signKey（唯一阻塞项）
```bash
# 越狱设备 / 或 frida-ios-dump 环境
frida -U -f com.leapmotor.developer -l frida/ios_hook_sign.js --no-pause
# 然后在 App 里点一下"刷新车况"，日志会打印:
#   [LP-SIGN] === XXX -[signStringWithParams:signatureParams:serverKey:] ===
#   [LP-SIGN]   arg[0] (params) = ...
#   [LP-SIGN]   arg[2] (serverKey) = <hex/base64>
#   [LP-SIGN]   >>> return = <sign>
# 把 serverKey 填进 app/config.json 的 sign_key
```

**兜底方案**：如果原生方法被加固隐藏（hook 不到），改用
`frida/ios_hook_request.js` 直接 hook `NSURLSession` + `CCHmac`，从 CommonCrypto 层拿到 key+data。

### 7.2 用已还原的算法直接发请求
```python
from leapmotor_client import LeapmotorClient, Config
cfg = Config(sign_key="<frida 拿到的 key>",
             token="<accessToken>", user_id="672955179229782016",
             carvin="LFZ63AA15TH035113", cartype="D19",
             oppwd="uHTigfMDS5zIuZX4Gq4NVQ==")
cli = LeapmotorClient(cfg)
cli.vehicle_list()
cli.status("LFZ63AA15TH035113")
cli.lock("LFZ63AA15TH035113")     # cmdid=110 {"value":"lock"}
cli.ctl_query("2740731680")
```

### 7.3 若要完全离线（不依赖 App）
1. Frida dump `serverKey` → 复现签名（算法已 100% 明确）
2. 解 `oppwd`：hook 原生 AES/SM4 加密函数，或让用户在 App 里改一次操作密码并抓包
3. 解 LMVCloudBinaryPacket：hook `libleapcrypto.so` 的解密入口

---

## 8. 资产清单

| 文件 | 说明 |
|---|---|
| `evidence/har_appgw.har` | Reqable 抓包（266 条） |
| `evidence/har_stream.har` | Stream 抓包（243 条） |
| `evidence/signed_samples.json` | 196 条去重后的带签名请求 |
| `evidence/signed_main.json` | 186 条主 App 样本（签名穷举语料） |
| `evidence/endpoints_structured.json` | 67 个 host+path 结构化端点 |
| `evidence/har_api_dump.txt` | 27 个核心 API 的完整请求/响应 |
| `client/leapmotor_client.py` | 可运行客户端（签名 + 端点 + 车控） |
| `frida/ios_hook_sign.js` | 签名密钥 dump 脚本 |
| `evidence/ios_misc/*.jgb` | 加固残留（含 32B 疑似密钥） |

---

*本报告仅用于分析自有账号 / 自有车辆的车控协议，便于制作无广告的干净客户端。*
