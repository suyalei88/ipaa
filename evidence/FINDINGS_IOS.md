# 零跑 iOS APP 逆向分析报告

- **文件**: `零跑-1.22.68.ipa`
- **Bundle ID**: `com.leapmotor.developer`
- **版本**: 1.22.68 (build `20260918135504`)
- **SHA-256**: `b38a654935e5d97cf39368bc4922540b7d587ea3cf636ff3e633b8201f233955`
- **大小**: 184,032,863 bytes / 5,266 files
- **主二进制**: `leapmotorCarOwner` — **204MB, thin arm64, 未加密 ✅（已脱壳）**
- **框架**: React Native（`index.jsbundle` 明文 JS）+ 原生 Swift/ObjC

---

## 1. 关键突破

| 发现 | 说明 |
|---|---|
| **二进制未加密** | 直接可挖字符串，无需 IDA 也能拿端点 |
| **RN bundle 明文** | `index.jsbundle` 3MB，签名算法全在里面 |
| **iOS 与 Android 同一套 RN 代码** | 签名算法一致 |

---

## 2. 网关与环境

| 环境 | 网关 |
|---|---|
| **生产** | `https://appgateway.leapmotor.com` |
| 生产(全球) | `https://app-gw-global-master.leapmotor.com` / `-slave` |
| 预发 | `https://pre-app-gw-global-master.leapmotor.com` |
| 测试 | `https://test-app-gw-global-master.leapmotor.com` |
| 开发 | `https://dev-app-gw-global-master.leapmotor.com` |
| 业务 API | `https://api.leapmotor.com`（RN envConfig.apiBaseUrl） |

**服务前缀**（挂在网关上）：
```
/base/base-user          账号
/app/app-control-service 车控
/app/app-signal-service  车况信号
/app/app-global-service  全局
/carownerservice         车主服务
/appaicenter             AI
/account/v1              v1 账号
```

---

## 3. 登录流程端点

| 端点 | 用途 |
|---|---|
| `/app-user/applogin/compliance/sendmessagecode` | 发短信验证码 |
| `/app-user/applogin/check_login_with_phone` | 手机号+验证码登录 |
| `/app-user/applogin/check_one_login` | 一键登录 |
| `/app-user/applogin/tokenExist` | token 是否存在 |
| `/app-user/appuseroperate/getnewtokentoios` | 换取 iOS token |
| `/account/v1/login` | 账号登录 |
| `/account/v1/logout` | 登出 |
| `/token/v1/refresh` | 刷新 token |
| `/token/applyToken` | 申请 token |

**登录响应关键字段**（从二进制字符串确认）：
```
data.accountId
data.accessToken
data.refreshToken
data.tokenExpireTime
data.signParam.r2        ← 签名密钥（★）
data.signParam.r3        ← 签名密钥（★）
data.encryptParam.r2     ← 加密密钥
data.encryptParam.r3     ← 加密密钥
```
> **`signParam.r2/r3` 就是后续请求签名用的 signKey**，登录时下发。

---

## 4. 车控端点

| 端点 | 用途 |
|---|---|
| `/v3/api/appremotectl` | **远程控制（主入口）** |
| `/v3/api/appremotectl/query` | 车控状态查询 |
| `/v3/api/appremotectl/appointment` | 预约 |
| `/v3/api/appremotectl/getappointment` | 取预约 |
| `/v1/vehicle/list` | 车辆列表 |
| `/v1/vehicle/getCarRoute` | 行车路线 |
| `/carownerservice/v3/api/appoperate/carinfo` | 车辆信息 |
| `/v3/api/chassis/query` | 底盘数据 |
| `/v3/api/vehicleinfo/commonConfig` | 通用配置 |
| `/v3/api/vehicleinfo/parking/query` | 泊车 |
| `/v3/api/carPlate/plateNumber` | 车牌 |
| `/app/app-signal-service` | 车况信号流 |
| `/v3/api/fota/getCurrentVersion` | OTA 版本 |
| `/v3/api/ccc/pairingcode` / `poll` / `delKey` | 数字钥匙(CCC) |
| `/v3/api/bluetoothkey/combine/syncBluetoothKeys` | 蓝牙钥匙 |
| `/owner/bindCar/checkBind` | 绑车校验 |

---

## 5. 车控请求模型（★ 核心）

类：**`LMVRemoteControlRequestModel`** / `LMVRemoteControlRequestModelProtocol`

请求字段（`POST /v3/api/appremotectl`）：
```json
{
  "cmdid": "<命令ID>",
  "carvin": "<VIN>",
  "oppwd": "<操作密码>",
  "controlSource": "...",
  "operation": "...",
  "msgID": "..."
}
```
附加业务字段：`temperature` / `windlevel` / `hotcold` / `nohotcold` / `circle` / `on` / `off` / `unlock` / `manual` / `operate`

**控制命令名**（二进制里直接可见）：
```
lockCtrl              锁车
trunklockCtrl         后备箱
cartracking           寻车
regCtrl               车窗
setSteeringWheelHeatCtrl / steeringWheelHeatCtrl  方向盘加热
app_hello             握手
autopark_enter / autopark_exit / autopark_stop     自动泊车
space_index / space_type / space_range / space_direction / space_num  泊车位
ctlcode / ctltime     控制码 / 控制时间（BLE 通道）
```

UI 侧还确认了这些能力：`unlock` / 空调(`temperature`/`windlevel`) / 车窗 / 天窗(`sunroof`) / 遮阳帘(`sunshade`) / 座椅加热通风(`seatHeat`/`seatWind`) / 迎宾 / 前备箱(`Frunk`) / 哨兵模式(`SentinelMode`)

---

## 6. 请求签名

### 6.1 算法（RN bundle，与 Android 完全一致）
```js
sign = HMAC_SHA256( valueStr , signKey ).hex()
// valueStr = 合并(body + signHeaders) 剔除空值 → 按 key 升序 → 只拼 value、无分隔符
// signHeaders = acceptLanguage/deviceType/source/version/channel/deviceId/timestamp/nonce
```
复现器：`client/leapmotor_client.py`（已通过 Node 逐字节验证）

### 6.2 请求头
`sign` · `token` · `userId` · `carvin` · `cartype` · `x-api-signature-version: 2.0` · `x-region: CN` · `acceptLanguage` · `deviceType` · `source` · `version` · `channel` · `deviceId` · `timestamp` · `nonce` · `x-subversion` · `x-canary-version`

### 6.3 原生签名方法
```
signParamsWithPassword:      用密码签名
signStringWithParams         按参数签名
signWithAppID
signSM2WithData              SM2 签名（国密）
hmacSha256WithKey:text:      HMAC-SHA256
signatureWithKey / signvalueWithData / signwithdigest
```

### 6.4 加密体系
- **HTTP 层**：HMAC-SHA256（CommonCrypto）
- **BLE 数字钥匙**：**国密 SM2/SM3/SM4**
  ```
  LeapSecAppBle_GenSM2KeyPair / GenSM2ShareKey / SM4Encrype / SM4Decrypt / SM3Digest
  ```
- **埋点**：AES 类强加密（`Decrypt-Version: v1.0.0`，熵 7.9/8）

---

## 7. 其它

- **HTTPDNS**：阿里云 `223.6.6.6`（`ak=17890_31177745471003648`）
- **推送**：`v3/api/appdevice/updateDeviceInfo`、APNS
- **消息中心**：`/msgcenter/v3/noticemsg/*`
- **完整端点清单**：`evidence/ios_endpoints.txt`（317 条）

---

## 8. 下一步

现在端点、签名算法、请求模型都有了，只差**真实请求体 + signKey 值**：

```bash
# 过 pinning 抓一次登录 + 车控
frida -U -f com.leapmotor.developer -l frida/ios_ssl_bypass.js --no-pause
mitmdump -s capture/mitm_capture.py -p 8080
# 退出登录 → 重新登录 → 车控各点一遍

# 抓完自检
python client/har_analyze.py <你的.har>
```

拿到后：
1. `signParam.r2/r3` → 填 `Config.sign_key`
2. `cmdid` 映射 → 补车控命令表
3. 验签通过 → 打通

---

## 9. 证据文件

| 文件 | 说明 |
|---|---|
| `evidence/leapmotor.ipa` | 原始 IPA（哈希见上） |
| `evidence/ios_endpoints.txt` | 317 条端点 |
| `evidence/scan_ipa.txt` | 域名/URL 全量扫描 |
| `evidence/unpack_ios/.../index.jsbundle` | RN 明文 JS（签名算法） |
| `evidence/unpack_ios/.../leapmotorCarOwner` | 主二进制（204MB，未加密） |
