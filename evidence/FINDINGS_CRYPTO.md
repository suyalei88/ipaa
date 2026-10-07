# 零跑 iOS 车控 API —— 加密/签名体系完整还原

> 目标产物：第三方无广告、纯功能 iOS 车控客户端（仅控制本人车辆 / 本人账号）
> 样本：`evidence/leapmotor.ipa`（v1.22.68, build 20260918135504, `com.leapmotor.developer`）
> 回归：`evidence/har_appgw.har` 105 个带 sign 的请求 → **101 MATCH**，车控链路 **100%**

---

## 0. TL;DR —— 只需要一个登录响应，其余全部可算

```
登录响应 data:
    accessToken   (JWT, 3 段)
    signParam     { r2, r3 }      # 32B base64
    encryptParam  { r2, r3 }      # 32B base64

→ signKey     = UPPER(HEX( XOR3( b64dec(b64url2b64(tok[2])), b64dec(r2), b64dec(r3) ) ))
→ encryptKey  = 同上，用 encryptParam（实测 signKey == encryptKey）
→ oppwd       = base64( AES-128-CBC-PKCS7( 操作密码明文, key, iv ) )
                 key = md5hex(accessToken[0:32])[8:24]
                 iv  = md5hex(accessToken[32:64])[8:24]

→ 每个请求:
    sign = HMAC_SHA256( valueStr, signKey ).hex()
    valueStr = merge(signBody, signHeaders)
               去空值 → key ASCII 升序 → 只取 value, join("")
```

实测明文操作密码 = `4211`（har_appgw 会话）。

---

## 1. signKey 派生链（原生 ObjC）

### 1.1 调用链

```
RN: AIRequestInfoPlugin.getRequestInfo(0)
      ↓ TurboModule (RCTAIRequestInfoPlugin)
ObjC: -[AIRequestInfoPlugin getRequestInfo:resolve:reject:]        @0x1069c009c
        code==0(NORMAL) → -[AIRequestInfoPlugin getRequestHeaderWithResolve:reject:]  @0x1069bfc18
        code∈{3,39,302002004} → refreshToken…
      ↓
    headers = [LMVHttpV3InterfaceTool formatHeaderForHTTPRequestHeaders:paras:deviceid:encryption:error:]
    [headers removeObjectForKey:@"sign"]
    [headers setObject:scheme://host forKeyedSubscript:@"baseURL"]
      ↓
    svc = [[LMVMiddleWare shareMiddleWare] serviceByProtocol:@protocol(LMVLocalLoginServiceProtocol) singleton:1]
    signKey = [svc HKDFDeriveKey]
    [headers setObject:signKey forKeyedSubscript:@"signKey"]
    resolve(headers)                    ← 交给 JS，由 JS 做 HMAC
```

### 1.2 真正算 key 的地方

```
-[LMVLocalLoginService  HKDFDeriveKey]  @0x106e84138   → 转发
-[LMVLocalLoginManager  HKDFDeriveKey]  @0x106e82860   → [infoManager.localLocalInfo HKDFDeriveKey]
-[LMVLocalLoginModel    HKDFDeriveKey]  @0x106e832dc   → return *(id*)(self+0x28)   ← 纯 getter
```

赋值点在 **YYModel 字典转换钩子**里：

```
-[LMVLocalLoginModel modelCustomTransformFromDictionary:]  @0x106e82c30
```

反编译：

```objc
parts = [self.accessToken componentsSeparatedByString:@"."];
if (self.HKDFDeriveKey && self.HKDFEncryptKey) return YES;   // 已派生则跳过

// ---- signKey ----
if (self.signR2 && self.signR3 && parts.count >= 3) {
    NSData *d1 = [NSData dataWithBase64EncodedString_lmv:
                    [NSData base64URLToBase64: parts[2]]];
    NSData *d2 = [NSData dataWithBase64EncodedString_lmv: self.signR2];
    NSData *d3 = [NSData dataWithBase64EncodedString_lmv: self.signR3];
    NSData *x  = [LMVLocalLoginModel xorThreeData:d1 data2:d2 data3:d3];
    self.HKDFDeriveKey = [[x convertDataToHexStr_lmv] uppercaseString];
}

// ---- encryptKey ----
if (self.encryptR2 && self.encryptR3 && parts.count >= 3) {
    ... 同上，用 encryptR2 / encryptR3 ...
    self.HKDFEncryptKey = [[x convertDataToHexStr_lmv] uppercaseString];
}
```

`signR2/signR3/encryptR2/encryptR3` 就是登录响应里的 `signParam.r2/r3`、`encryptParam.r2/r3`。

### 1.3 XOR3

```
+[LMVLocalLoginModel xorThreeData:data2:data3:]  @0x106e830fc
```

```objc
+ (NSData *)xorThreeData:(NSData *)d1 data2:(NSData *)d2 data3:(NSData *)d3 {
    if (!d1 || !d2 || !d3) return nil;
    NSUInteger n = MAX(d1.length, MAX(d2.length, d3.length));
    NSMutableData *out = [NSMutableData dataWithLength:n];
    uint8_t *o = out.mutableBytes;
    const uint8_t *p1 = d1.bytes, *p2 = d2.bytes, *p3 = d3.bytes;
    for (NSUInteger i = 0; i < n; i++) {
        uint8_t a = (i < d1.length) ? p1[i] : 0;
        uint8_t b = (i < d2.length) ? p2[i] : 0;
        uint8_t c = (i < d3.length) ? p3[i] : 0;
        o[i] = a ^ b ^ c;
    }
    return out;
}
```

### 1.4 关键推论

服务端对每个会话生成目标 key `K`，然后随机 `r2` 并令 `r3 = K ^ d1 ^ r2`，
所以 **`signKey == encryptKey`**（实测两组 r2^r3 完全相同，见 `client/derive_signkey.py --har`）。
即：**signKey 完全由登录响应可算，不需要 Frida。**

---

## 2. 请求签名（JS 层）

`index.jsbundle` module 462 (bootstrap) → 605 → 606 → 607 `AIRequestInfoPlugin` TurboModule。

```js
function buildAuthHeaders(body, skipAuth, skipHmac) {
  var info = yield getAuthProvider().getRequestInfo(TokenExpiryCode.NORMAL);
  var signHeaders = { acceptLanguage, channel, deviceId, deviceType,
                      nonce: randomInt32().toString(),
                      source, timestamp: Date.now().toString(), version };
  if (info.signKey && !skipHmac) {
    headers.sign = HMAC_SHA256(buildSignValueString(body, signHeaders), info.signKey).hex();
  }
  ...
}

function buildSignValueString(body, signHeaders) {
  var o = {...body, ...signHeaders};
  return Object.entries(o)
    .filter(([k,v]) => v != null && v !== undefined && v !== "")
    .sort(([a],[b]) => a<b ? -1 : a>b ? 1 : 0)     // ASCII 升序
    .map(([k,v]) => formatSignValue(v))
    .join("");                                      // ★ 无分隔符
}
```

`parseKeyString(signKey)`：全 hex 字符串 → hex 解码成字节；否则 UTF-8。
（signKey 是 64 位大写 hex → **HMAC key = XOR3 的 32 个原始字节**。）

### 2.1 signBody 规则（HAR 实测修正）

| Content-Type | signBody |
|---|---|
| `application/json` | `JSON.parse(body)`，非 JSON → `{}` |
| `application/x-www-form-urlencoded` | **`parse_qsl(body)` URL 解码后的表单字典** ★ |
| 无 body | `{}` |

GET 的 query params 一并 merge 进 signBody。

> 之前以为 form body 不参与签名（`tryParseJson` 会失败），实测**错误**：
> 15/16 个 form 请求只有在把 URL 解码后的表单字典算进去才匹配。

---

## 3. oppwd（操作密码）

```
-[LMVOperatePwManager  signParamsWithPassword:]      @0x106c446bc  → 转发
-[LMVOperatePwInteractor requestSignParamsWithPassword:]  @0x106c4433c
```

```objc
- (NSString *)requestSignParamsWithPassword:(NSString *)password {
    NSString *token = [LMVLocalLoginService shareInstance].token;
    if (token.length < 0x40) return @"<default>";
    NSString *k = [LMVMD5Util MD5ForLower16Bate:[token substringToIndex:0x20]];              // token[0:32]
    NSString *v = [LMVMD5Util MD5ForLower16Bate:[token substringWithRange:{0x20, 0x20}]];    // token[32:64]
    NSData *pw  = [password dataUsingEncoding:NSUTF8StringEncoding];
    NSData *enc = [LMVAESUtil AESEncryptData:pw key:k iv:v];      // 返回 base64 的 UTF8 bytes
    return [[NSString alloc] initWithData:enc encoding:NSUTF8StringEncoding];
}
```

辅助函数：

```
+[LMVMD5Util MD5ForLower16Bate:]  @0x106e966e0
      = [MD5ForLower32Bate:(s) substringWithRange:{8, 16}]     // md5hex(s)[8:24]

+[LMVAESUtil AESEncryptData:key:iv:]  @0x106df4288
      = base64( AES128Operation(0 /*encrypt*/, data, key, iv) ) 以 UTF8 字节返回

+[LMVAESUtil AES128Operation:data:key:iv:]  @0x106df43c4
      CCCrypt(op, kCCAlgorithmAES /*0*/, kCCOptionPKCS7Padding /*1*/,   // → CBC + PKCS7
              keyCStr, 16, ivCStr, dataIn, dataInLen, out, outLen, &moved)
      key/iv 通过 getCString:maxLength:17 encoding:UTF8 取 → 各 16 字节 ASCII
```

**Round-trip 验证（真实抓包）：**
```
token = har_appgw accessToken, password = "4211"
key = b9ac766228277fa8   iv = a1175f49e3f59752
→ "uHTigfMDS5zIuZX4Gq4NVQ=="   与抓包完全一致 ✅
```
解密抓包密文 → 明文 `b'4211'`，PKCS7 padding 完整。

oppwd **每会话不同**（key/iv 由 token 派生），三个 HAR 分别是
`uHTigfMDS5zIuZX4Gq4NVQ==` / `bDFCVHQ5RP9gFopnNoffTw==` / `PdHKYkftTgsCbLyjVomQJw==`。

---

## 4. 车控协议

```
POST https://appgateway.leapmotor.com/app/app-control-service/v3/api/appremotectl
Content-Type: application/x-www-form-urlencoded

carvin=<vin>&cmdid=<n>&oppwd=<b64>&state=<urlencoded json>
```

结果轮询：
```
GET /app/app-control-service/v3/api/appremotectl/query?msgID=<msgID>
    data == 1 → 成功
```

### cmdid 表（实测）

| cmdid | state | 功能 |
|---|---|---|
| 110 | `{"value":"lock"}` / `{"value":"unlock"}` | 车门锁 |
| 120 | `{"value":"true"}` | 后备箱 / 寻车 |
| 170 | `{"operate":"off"}` / `{"operate":"auto"}` | 大灯 |
| 230 | `{"value":"0"}` / `"2"` / `"5"` | 空调 |
| 400 | `{"operation":"on"}` | 上电 / hello |

### 其他常用端点

| 方法 | host + path | 说明 |
|---|---|---|
| GET | `app-gw-global-master.leapmotor.com/base/base-user/account/v1/login` | 登录 |
| GET | `appuser.leapmotor.cn/app-user/applogin/compliance/sendmessagecode?phoneNo=` | 短信 |
| GET | `app-gw-global-master.leapmotor.com/app/app-global-service/v1/vehicle/list` | 车辆列表 |
| POST | `appgateway.leapmotor.com/app/app-signal-service/signal/info/query` | 车况（JSON） |
| POST | `appgateway.leapmotor.com/carownerservice/signal/info/query/distributed` | 车况（分布式） |
| GET | `appgateway.leapmotor.com/carownerservice/v3/api/vehicleinfo/commonConfig` | 车辆配置 |
| GET | `appgateway.leapmotor.com/carownerservice/v3/api/drivingrecord/mileage/energy/detail` | 里程/能耗 |

---

## 5. 回归结果

```
$ python client/test_sign_regression.py
=== har_appgw.har   signKey=7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566
    101/105

按端点：
OK  30/ 30  carownerservice/v3/api/vehicleinfo/commonConfig
OK  26/ 26  app/app-signal-service/signal/info/query
OK  16/ 16  app/app-control-service/v3/api/appremotectl/query
OK   8/  8  app/app-control-service/v3/api/appremotectl          ← 车控
OK   4/  4  carownerservice/signal/info/query/distributed
OK   1/  1  app-global-service/v1/vehicle/list
... （其余单次请求全部 OK）

!!   0/  2  iov-api.leapmotor.com/file/1.0/vehicle/pointData    ← 文件下载，非车控
!!   0/  1  carownerservice/v3/api/appdevice/updateDeviceInfo    ← 设备注册，非车控
!!   0/  1  base/base-user/account/v1/login                       ← 登录本身（用登录前 key）
```

剩余 4 例均为**车控无关**的边缘情况（登录前的 key / 另一台 host 的文件服务），
车控 + 车况 + 车辆列表链路 **100% 命中**。

---

## 6. 工具

| 文件 | 用途 |
|---|---|
| `client/leapmotor_client.py` | 完整客户端：signKey/oppwd 派生 + 全部端点 |
| `client/derive_signkey.py` | 从登录响应派生 key 并验证（`--har X --verify`） |
| `client/test_sign_regression.py` | 用 client 本体对 HAR 全量回归 |
| `client/verify_against_har.py` | 单 key 验证器（valueStr 构造参考实现） |
| `client/metro_extract.py` | Metro RN bundle 模块提取（`--chain 605`） |
| `client/objc_parse.py` | 自研 Mach-O ObjC 解析（class/instance methods，`--dump-classes`） |
| `client/ios_sel.py` | 按 selector 反查 method（穿透 metaclass / category） |
| `client/ios_sym.py` | chained-fixups imports 表 + `__stubs`/`__objc_stubs` 蹦床解析 |
| `client/ios_scan.py` | numpy 向量化 `bl` 交叉引用扫描 |
| `client/ios_dis.py` | 带注释反汇编（自动解析 stub 符号 / 字符串 / 类名） |
| `client/macho_util.py` | Mach-O 基础（vm↔off、指针解引用、capstone） |

### 技术要点备忘

* 二进制用 **`DYLD_CHAINED_PTR_64`**：指针槽低 36 位 = **绝对 vmaddr**，bit63 = bind。
* `__objc_methlist`（`__TEXT`）是 **relative method list**：
  `name` 字段 = `selref_addr - field_addr`，需再解一层指针才是字符串；
  `types` 字段则直接指向 cstring；`imp = imp_field_addr + imp_off`。
* 类方法（metaclass）与 category 方法不在 `class_ro_t.baseMethods` 里，
  用 `ios_sel.py` 的「反查相对偏移」可直接定位。
* 免费版 `lief` wheel **不含 ObjC 解析与反汇编**，需自研（见 `objc_parse.py`）。

---

## 7. 构建第三方 iOS 客户端的可行路线

1. **纯 API 客户端**（推荐，最快）：
   `client/leapmotor_client.py` 已可完整工作 —— 登录 → 车况 → 车控。
   用 Swift + URLSession 复刻同样 4 个算法（HMAC-SHA256 / XOR3 / AES-128-CBC / MD5-16）。
2. **注入式插件**：保留官方 App，Frida/Theos hook 掉广告与埋点，复用其登录态。
3. **签名校验点**：`x-api-signature-version: 2.0`；`sign` 头必须存在，否则 401/业务码错误。

需要注意的客户端固定参数（抓包值，可直接复用）：
```
deviceId   = ios_ee45b9d830bb126d431e998943a7797a   (每设备不同，可自行生成 ios_<32hex>)
deviceType = iOS
source     = leapmotor
channel    = 1
version    = 1.22.68
acceptLanguage = zh-CN
x-subversion   = 3.22.2-3
x-region       = CN
```

---

## 8. 登录链路（已定位，`security` 未完全还原）

> 结论：**签名/加密已 100% 解决，登录的 `security` 字段卡在混淆的原生插件层。**
> 因此第三方客户端采用「导入登录态」建立会话（见 `ios/LeapmotorLite/README.md`）。

### 8.1 登录请求

```
POST https://app-gw-global-master.leapmotor.com/base/base-user/account/v1/login
Content-Type: application/json

{"identifier":"672955179229782016","identifierType":"1",
 "security":"3DD9DF4A2A5F4367B5E63F22A36DF2A13DD9DF4A2A5F4367B5E63F22A36DF2A1"}
```

响应 `data` 里就是 `accessToken` / `refreshToken` / `signParam` / `encryptParam`
（即 `signKey` 派生所需的全部输入）。

### 8.2 构造点

```
-[LMVLocalLoginHttpTools startSDKLogin:accound:attempts:]   @0x106e8034c
```

反编译：

```objc
- (void)startSDKLogin:(NSString *)security accound:(NSString *)account attempts:(NSUInteger)n {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"security"]       = security;      // ← 参数 1
    dict[@"identifierType"] = @"1";          // ← 硬编码
    dict[@"identifier"]     = account;       // ← 参数 2
    [[LMVLocalLoginService shareInstance].infoManager saveLocalLoginInfo:...];
    [LMVHttpV3InterfaceTool requestWithURLStr:@"/account/v1/login"
                                   parameters:dict
                                         type:@"POST_Json"
                                      timeout:20.0
                                   encryption:?
                          handleTokenInvalid:0
                                      twoWay:0
                        limitReqFrequencyTime:0
                            completionHandler:...];
}
```

### 8.3 `security` 的来源

唯一调用者是 `-[LMVLocalLoginHttpTools localSdkLoginCompletionHandler:force:]`（`0x106e7fe34`），
其 block 里：

```objc
x20 = captured.outServerToken       // → security
x19 = captured.outServerAccountID   // → account
[self startSDKLogin:x20 accound:x19 attempts:[self loginRetryCount]];
```

而 `outServerToken` 只是转发：

```objc
-[LMVLocalLoginService outServerToken]  @0x106e84250
    return [[self outLoginService] token];
```

`outLoginService` 由全局 builder 注册表注入：

```objc
// -[LPMCarSDKBridgeForMainAPP applicationDidFinishLaunchingWithOptions:andRegisterGlobalBuilders:]
id svc = builders[@"LMVGlobalBuilderKey_LoginService"];
if (svc && [svc conformsToProtocol:@protocol(LMVLocalLoginServiceProtocol)]) {
    [[LMVLocalLoginService shareInstance] registerOuterLoginService:svc];
    [[LMVMiddleWare shareMiddleWare] registerService:svc forServiceProtocol:...];
}
```

写入方是 `-[LPMCarSDKBridgeForMainAPP LoginSuccessWhenStart:]`（把 `self` 写进 3~4 个 key）。

**而 `LPMCarSDKBridge` / `LPMCarSDKBridgeForMainAPP` / `LMLoginToolsManager` /
`LMLoginDataServiceManager` 的这些方法全部是控制流平坦化（CFF）混淆的**
（大量 `movk` 常量 + `cmp/b.gt/b.eq` 派发 + 永不成立的 opaque predicate），
静态还原成本很高。

### 8.4 关键推论

* `security` **不是**密码的直接哈希，而是「外部登录服务」下发的一个**会话 token**
  （形状为 64 位 hex = 32 字节）。
* 应用里还有一套独立的 `appuser` 登录体系：
  * `GET  /app-user/applogin/compliance/sendmessagecode?phoneNo=<RSA密文>&smDeviceId=<密文>`（短信）
  * `POST /app-user/applogin/check_login_with_phone`
  * `POST /app-user/applogin/check_one_login`（一键登录，Geetest OnePass）
  * `POST /app-user/appuseroperate/getnewtokentoios`
  * 抓包里 index 198~200 出现 `fp-it.fengkongcloud.com/deviceprofile/v4`（风控设备指纹）
    与 `onepass.geetest.com/token_record`（一键登录 token 记录）。
* `phoneNo` 密文长度 128 字节 → **RSA-1024**，公钥内嵌在 App 里（未提取）。

### 8.5 工程结论

| 方案 | 可行性 |
|---|---|
| 导入登录态（accessToken + signParam/encryptParam） | ✅ 100% 可靠，已实现 |
| 账号密码直登 | ⚠️ 需要 `security`；已在 Swift 端做 best-effort（`UPPER(md5hex(pwd))×2`） |
| 短信验证码登录 | ⚠️ 需要 RSA 公钥 + 风控参数 |
| 一键登录 | ⚠️ 依赖运营商 SDK |
| Frida hook `-[LMVLocalLoginService outServerToken]` 取 `security` | ✅ 可行（越狱设备），用于**一次性**分析确认算法 |

> 如果后续要彻底打通登录，最短路径是：**越狱设备 + Frida**，
> hook `-[LPMCarSDKBridge token]` / `-[LMVLocalLoginService outServerToken]`，
> 输入已知密码，看 `security` 与密码的关系（一次即可确定是否为哈希）。

---

# 9. 【2026-10-07】全链路实盘打通 + 短信验证码打通

## 9.1 端到端实盘验证 ✅

抓包 `har_appgw.har` 里的 accessToken 在当天尚未过期（`exp=1791357811`），
用 `client/leapmotor_client.py` 直接实盘跑通：

```
signKey 自派生 = 7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566
GET  /app/app-global-service/v1/vehicle/list       → code:0  D19 / LFZ63AA15TH035113 / carId 22129535
POST /app/app-signal-service/signal/info/query     → code:0  130 个实时信号
POST /app/app-control-service/v3/api/appremotectl  → cmdid=400 {"operation":"on"}
       {"result":0,"data":"2741251310","message":"请求成功"}
GET  .../appremotectl/query?msgID=2741251310       → 12s 后 {"data":1}  ✅ 成功
现场派生 oppwd("4211") = uHTigfMDS5zIuZX4Gq4NVQ==  与抓包逐字节一致
```

**签名/加密实现 100% 正确，车控真实生效。**

### 车控 cmdid 全表（抓包实证）

| cmdid | state | 功能 |
|---|---|---|
| 110 | `{"value":"lock"}` / `{"value":"unlock"}` | 车门锁 |
| 120 | `{"value":"true"}` | 后备箱 |
| 130 | `{"value":"true"}` / `{"value":"false"}` | 开关（新发现） |
| 170 | `{"operate":"off"}` / `{"operate":"auto"}` | 大灯 |
| 230 | `{"value":"0"}` / `"2"` / `"5"` | 空调 |
| 400 | `{"operation":"on"}` | 上电/hello |

## 9.2 ★ 短信验证码发送：已打通 ✅

**`AccountIDKey`（二进制 file offset `0xa9b6471`）就是手机号的 RSA-1024 公钥：**

```
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB
-----END PUBLIC KEY-----
```

```
phoneNo = base64( RSA_PKCS1v15( 手机号, AccountIDKey ) )      # 128 字节
GET https://appuser.leapmotor.cn/app-user/applogin/compliance/sendmessagecode
      ?phoneNo=<phoneNo>&smDeviceId=<smDeviceId>
```

* **不需要 sign、不需要 token**（裸 GET，只带 device 头）
* 实测手机号 `17621058873` → `{"code":200,"success":true,"msg":"操作成功","data":null}`
* 其余 6 把 RSA 公钥全部失败（`1019 参数不能为空` = 解出乱码 / `1023 高风险`）
* `smDeviceId` 是 65 字节、**SM4 国密**加密、每次变化（抓包值可直接复用试）

**结论：发码链路 = RSA(AccountIDKey) + 抓包 smDeviceId，已可用。**

## 9.3 新发现的二进制情报

| 项 | 内容 |
|---|---|
| RSA-1024 公钥 | 共 **7 把**（`e=65537`）：AccountIDKey(手机号)、电信一键登录、Geetest OnePass ×2 等 |
| 加密工具方法 | `encryptPhone:` / `encryptPreGetTokenParams:key:` / `encryptSM2OrRsa_LLZX:key:ifGM:` / `encryptSM4OrAes_LLZX:key:iv:ifGM:` / `encryptUseDES:key:` |
| smDeviceId | 65B，SM4（`sm4iv` / `sm4CbcEncryptData:iv:withCipherKey:` / `sm4DecryptWithString:key:`），动态 |
| 短信登录接口 | `/app-user/applogin/check_login_with_phone`（host `appuser.leapmotor.cn`），涉及 `Des` / `smsCode` / `risk_type` / `appLoginVO` |
| token 刷新 | `/base/base-user/token/v1/refresh`（host `app-gw-global-master`），**存在且校验签名**；用登录后 signKey 报 `302002002 签名信息校验失败` → 登录前另有 key |
| 路径前缀常量 | file offset `0xaa33d94`：`/base/base-user` `/app/app-global-service` `/app/app-control-service` `/app/app-signal-service` `/carownerservice` |
| iOS RN bundle | `ai.bundle/index.jsbundle`（3 MB **明文 JS**）：印证 `buildAuthHeaders`；登录/security/phoneNo 逻辑不在 JS，全在原生 |

## 9.4 登录态可行性（更新）

| 方式 | 状态 |
|---|---|
| 导入登录态（抓包 token） | ✅ 已验证，100% 可用 |
| **短信验证码发码** | ✅ **已打通**（AccountIDKey + RSA-PKCS1v15 + 抓包 smDeviceId） |
| 短信验证码登录 | ⚠️ `check_login_with_phone` 请求格式未定（原生 + CFF 混淆） |
| 账号密码登录（`security`） | ⚠️ 动态值；同账号两次抓包 `security` 不同 → 非静态哈希 |
| token 自动续期 | ⚠️ 路径已定位，需要登录前那把 signKey |

## 9.5 用户/车辆信息（实测）

```
手机号      17621058873
accountId   672955179229782016      昵称「笑」   实名 苏胡
车型        D19     VIN LFZ63AA15TH035113     carId 22129535
总里程      1909 km     交付 51 天
操作密码    4211   →  oppwd = uHTigfMDS5zIuZX4Gq4NVQ==
```

---

# 10. 短信验证码登录 —— 完全打通（2026-10-07 深夜）

## 10.1 决定性突破：`check_login_with_phone` 用的是 `POST_Form`

`LMLoginDataServiceManager` 巨型 CFF 登录处理器内（`0x104e9004c`–`0x104ea5f98`）：

```
0x104e959b0:  add  x4, x4, #0x380  ; @10b47e380 "POST_Form"
0x104e959b8:  bl   objc_msgSend(instanceWithURLStr:parameters:type:completionHandler:)
```

> 对比：`check_one_login` 用 `"POST_Json"`（`0x104ea1bc4`），`check_login_with_phone` 用 **`"POST_Form"`**。

**这解释了之前所有 probe 的 `{"code":1019,"msg":"参数不能为空"}`** —— 我发的是 JSON，
服务端按 form-urlencoded 解析 → 所有参数为空。

## 10.2 SMS 登录体构造（`0x104e977c0`–`0x104e97884`）

```asm
; x20 = LPMSMSLoginRequest 实例
0x104e977c4:  ldr  x21, [x8, #0x630]      ; classref -> LMLoginToolsManager
0x104e977cc:  bl   objc_msgSend(phoneNumber)          ; x24 = request.phoneNumber
0x104e977dc:  mov  x0, x21                            ; x0 = LMLoginToolsManager (class)
0x104e977e0:  mov  x2, x24                            ; arg1 = phone
0x104e977e4:  mov  x3, #0                             ; arg2 = NULL error
0x104e977e8:  bl   objc_msgSend(EncodeForStrV1:error:)  ; +[LMLoginToolsManager EncodeForStrV1:error:]
0x104e9780c:  bl   objc_msgSend(setPhoneNoCiphertext:)  ; request.phoneNoCiphertext = 上一步结果
0x104e97814:  ldr  x0, [x8, #0x298]      ; classref -> LMIdentifierKit
0x104e97818:  bl   objc_msgSend(getPhoneID)           ; +[LMIdentifierKit getPhoneID]
0x104e97830:  bl   objc_msgSend(setDeviceID:)         ; request.deviceID = getPhoneID
0x104e97840:  ldr  x0, [x8, #0xd48]      ; classref -> LPMLoginPathProvider
0x104e97844:  bl   objc_msgSend(shareInstance)
0x104e97854:  bl   objc_msgSend(getLoginPageMarksOrActionCode)
0x104e9787c:  bl   objc_msgSend(setPageUrl:)          ; request.pageUrl
0x104e97884:  bl   objc_msgSend(yy_modelToJSONObject) ; -> form body
```

**关键等式：`phoneNoCiphertext = EncodeForStrV1(phoneNumber)` —— 与 `sendmessagecode` 的
`phoneNo` 是同一个编码器**（`+[LMLoginToolsManager EncodeForStrV1:error:]`）。
因为发码链路已实测成功，所以该编码器 == `base64(RSA_PKCS1v15(phone, AccountIDKey))`，**已被端到端证实**。

## 10.3 `os = "ios"`（小写）

`-[LPMBaseLoginCheckRequestParams init]`：

```
0x104f0b00c:  add  x2, x2, #0x8c0  ; @10b4b78c0 "ios"   -> setOs:
0x104f0b044:  add  x2, x2, #0x8c0  ; @10b4b78c0 "ios"
```

（注意：另一处 `setOs:` @ `0x10995d294` 属支付宝风控 SDK，`os=ios` 同值，但 `setApdid:`/`setUmidToken:` 是那家的字段。）

## 10.4 完整字段表

| 类 | 字段 |
|---|---|
| `LPMBaseLoginCheckRequestParams` | `os`, `smDeviceId`, `captchaOutput`, `genTime`, `lotNumber`, `passToken`, `requestId` |
| `LPMSMSLoginRequest`（: 基类） | `phoneNoCiphertext`, `phoneNumber`, `smsCode`, `deviceID`, `pageUrl` |
| `LPMOneLoginRequest`（: 基类） | `processId`, `token`, `authCode`, `phone`, `pageUrl`, `deviceId`, `source` |

序列化：`yy_modelToJSONObject` → **JSON key == property 名**。

## 10.5 实测结果（2026-10-07）

```
A  form {os,smDeviceId,phoneNoCiphertext,phoneNumber,smsCode}
   -> {"code":1019,"success":false,"msg":"参数不能为空"}
B  form A + {deviceID, pageUrl}
   -> {"code":100116,"success":false,"msg":"验证码已过期，请重新获取"}   ★ 格式正确
C  form B + {requestId, genTime}
   -> {"code":1021,"success":false,"msg":"参数值错误"}                    ★ Geetest 字段不可乱填
```

**`100116 验证码已过期` = 服务端完整解析了全部参数并进入验证码校验分支 ⇒ 请求格式确认无误。**

最终可用 body（`Content-Type: application/x-www-form-urlencoded`）：

```
os=ios
smDeviceId=<SM4 65B b64>
phoneNoCiphertext=<base64(RSA_PKCS1v15(phone, AccountIDKey))>
phoneNumber=<明文手机号>
smsCode=<6 位验证码>
deviceID=ios_ee45b9d830bb126d431e998943a7797a
pageUrl=
```

## 10.6 登录响应 → signKey

`check_login_with_phone` 成功时返回**完整登录态**（无需再走 `/account/v1/login` 的 `security` 交换）：

```
{ risk_type, tokenExpired,
  appLoginVO: { accessToken, refreshToken,
                signParam:{r2,r3}, encryptParam:{r2,r3} } }
```

`signKey = UPPER(hex( XOR3( b64(jwt[2]), b64(signParam.r2), b64(signParam.r3) ) ))`
—— 已用 HAR1 真实登录响应验证（客户端 `--selftest` 断言 `7C2C1588…A8AC566`）。

HAR3(15:30) 登录 → `signKey = 2A86428A628BF2E428D6D76AE9B15ACEEB42EB82B206E334B01E7F575A3A3576`
（HAR3 头部被导出工具匿名化为 `name: value`，无法独立验签；算法与 HAR1 相同）。

## 10.7 交付脚本

| 脚本 | 用途 |
|---|---|
| `client/leapmotor_login_full.py send  <phone>` | 发码 |
| `client/leapmotor_login_full.py login <phone> <code>` | 用码登录 → 落 `evidence/session.json`（含 signKeyHex） |
| `client/leapmotor_sms_probe.py` | 格式探测（保留作回归） |
| `client/ios_scan_login.py` | CFF 段字符串/选择器标注扫描器 |
| `client/verify_har3_signkey.py` | 任意 HAR 的 signKey 推导 + 签名回归 |

## 10.8 新增工具类名（本次解析）

| classref | 类名 | 用途 |
|---|---|---|
| `0x10b927630` | `LMLoginToolsManager` | `+EncodeForStrV1:error:`、`phoneEncodeCache` |
| `0x10b927298` | `LMIdentifierKit` | `+getPhoneID` |
| `0x10b927d48` | `LPMLoginPathProvider` | `-getLoginPageMarksOrActionCode` |
| `0x10b92af28` | `LMSMSTools` | SMS 分支相关 |
| `0x10b927018` | — | `getService:` 接收者 |

---

# 11. ★★★ 登录完全打通（2026-10-07 16:20）★★★

## 11.1 最终根因：登录前签名 = 纯 SHA256(valueStr)，无密钥

原生签名器：`+[LMVHttpV3InterfaceTool formatHeaderForHTTPRequestHeaders:paras:deviceid:encryption:error:]`
@ **`0x106e6ee9c`**（类方法，存在元类里）。

```asm
0x106e6f2d8:  ldr  w8, [sp, #0x38]
0x106e6f2dc:  tbz  w8, #0, #0x106e6f364        ; ★ 模式开关

; ---- 分支 A (flag bit0 == 1)：登录后 ----
0x106e6f2e4:  ldr  x23, [x8, #0xd48]           ; HMAC 工具类
0x106e6f318:  bl   objc_msgSend(HKDFDeriveKey) ; key
0x106e6f32c:  mov  x2, x28                     ; arg1 = key
0x106e6f330:  ldr  x3, [sp, #0x58]             ; arg2 = valueStr
0x106e6f334:  bl   objc_msgSend(HMacHashWithKey:plaintext:)
0x106e6f360:  b    #0x106e6f380

; ---- 分支 B (flag bit0 == 0)：登录前 ----
0x106e6f364:  adrp x8, #0x10b92d000
0x106e6f368:  ldr  x0, [x8, #0xe88]            ; SHA256 工具类
0x106e6f36c:  ldr  x2, [sp, #0x58]             ; valueStr
0x106e6f370:  bl   objc_msgSend(sha256String:) ; ★ sign = sha256(valueStr)

; ---- 汇合 ----
0x106e6f380:  adrp x3, #0x10b4ae000
0x106e6f384:  add  x3, x3, #0x480  ; "sign"
0x106e6f394:  bl   objc_msgSend(setObject:forKey:)
0x106e6f3f4:  setValue:forKey:  "userId" = [service accountID]
```

**结论：**

| 阶段 | sign 算法 | 密钥 |
|---|---|---|
| **登录前**（`/account/v1/login`） | `SHA256(valueStr)` | **无** |
| **登录后**（车况 / 车控 / 全部网关） | `HMAC-SHA256(valueStr, HKDFDeriveKey)` | 登录响应派生 |

`valueStr` 两阶段完全一致：`merge(headers, paras)` → 过滤 null/空串 → key ASCII 升序 → **只拼 value，无分隔符**。

这解释了此前所有 `302002002 签名信息校验失败` —— 我一直在用 HMAC 签登录请求。

## 11.2 签名器调用的完整 header 集合（`0x106e6ef04`–`0x106e6f0b0`）

```
headers["acceptLanguage"] = [LMVRunEnvDefine appLanguageForServer]
headers["deviceType"]     = "iOS"
headers["source"]         = "leapmotor"
headers["version"]        = [getShortVersionStr]         ; "1.22.68"
headers["channel"]        = "1"
headers["timestamp"]      = [NSString stringWithFormat:@"%li", (long)(now*1000)]
headers["nonce"]          = [NSString stringWithFormat:@"%i",  arc4random()]
headers["deviceId"]       = <deviceid 参数>              ; [LMVRunEnvDefine phoneID]
→ 与 paras 合并、过滤、排序、拼 valueStr
→ sign
headers["userId"]         = [service accountID]
```

RN 侧同源：`AIRequestInfoPlugin -[getRequestHeaderWithResolve:reject:]` @ `0x1069bfc18`
把 `HKDFDeriveKey` 以 `"signKey"` 塞给 JS，并 `removeObjectForKey:@"sign"`（JS 自己重算）。

## 11.3 完整登录链路（已实测跑通）

```
1) GET  appuser.leapmotor.cn/app-user/applogin/compliance/sendmessagecode
        ?phoneNo=<base64(RSA_PKCS1v15(phone, AccountIDKey))>&smDeviceId=<SM4>
        -> {"code":200,"success":true}

2) POST appuser.leapmotor.cn/app-user/applogin/check_login_with_phone
        Content-Type: application/x-www-form-urlencoded
        os=ios & smDeviceId=<SM4> & phoneNoCiphertext=<同上RSA>
        & phoneNumber=<明文> & smsCode=<6位> & deviceID=ios_ee45.. & pageUrl=
        -> {"code":200,"data":{"appLoginVO":{"token":"<32hex×2>","refreshToken":...,"accountId":...}}}

3) POST app-gw-global-master.leapmotor.com/base/base-user/account/v1/login
        sign = SHA256(valueStr)          ★ 无密钥
        body {"identifier":<accountId>,"identifierType":"1","security":<上一步 token>}
        -> {"code":0,"data":{"accessToken":"eyJ...","refreshToken":"eyJ...",
                             "signParam":{"r2","r3"},"encryptParam":{"r2","r3"}}}

4) signKey = UPPER(hex(XOR3(b64url(jwt[2]), b64(r2), b64(r3))))
```

## 11.4 实测证据（2026-10-07 16:20）

```
[1] SMS login  -> 操作成功
[2] exchange   -> {"code":0,"message":"SUCCESS"}
    valueStr = zh-Hans-CN;q=1, en-CN;q=0.91ios_ee45b9d830bb126d431e998943a7797aiOS
               67295517922978201611522423368455A42EADA446B8A9FA3F6CCAE4E180
               8455A42EADA446B8A9FA3F6CCAE4E180leapmotor17913608251531.22.68
    sign(sha256) = 066fda165156e717a624dc4c53c7036ecb38a4c0cbd39d4fcb3d6e82c5df0863
    accessToken  = eyJub25jZSI6ImNhMWFkZjg3Y2I3NDRmNzI4OGMwNWU3YWJlNDg4Yzg0Iiwi...
    signParam.r2 = wBbEdn0V3TTk3ya6Q0nKeBb2VZdnEtYJwUXDxtt3EV0=
    signParam.r3 = ikOjONBvSZCiDco4mjDclfRQMbxq5TttGlb0CePhpF0=
    signKeyHex   = AF3BEE60AB13670D443BA6C0EE234613658A74388BF01BAF1E76D5AB0CE29721

[3] vehicle_list -> {"code":0,"data":{"bindcars":[{"carAlias":"D19","carId":22129535,
                     "plateNumber":"LFZ63AA15TH035113","year":2026,"outColor":"black",...}]}}
[4] car_route    -> {"code":0,"data":{"regionCode":"central-origin",
                     "appCenter":"https://appgateway.leapmotor.com","appMq":"ssl://app-mq-central.leapmotor.cn:8883"}}
[5] status       -> {"code":0,"data":{"collectTime":1791360876871,
                     "signalMap":{"1177":732.7,"1298":1,"10707":-6,"1349":29.5,"1182":26,...}}}
[6] hello (车控)  -> {"code":0,"result":0,"data":"2741626002","timeout":20}
    poll[8]      -> {"code":0,"data":1}      ✅ 车辆实际执行成功
```

## 11.5 新增/修正的工具

| 文件 | 用途 |
|---|---|
| `client/leapmotor_chain.py` | ★ 完整链路：发码 / 登录 / 兑换 / 派生 / 查车况 |
| `client/leapmotor_login_full.py` | 短信登录 + 落 `evidence/session.json` |
| `client/leapmotor_e2e.py` | 登录→立刻兑换（诊断用） |
| `client/leapmotor_sms_probe.py` | `check_login_with_phone` 格式探测 |
| `client/ios_scan_login.py` | CFF 段字符串/选择器标注扫描器 |
| `client/ios_clsmeth.py` | ObjC 类 + 元类方法表遍历（类方法必需） |
| `client/ios_cfref.py` | CFString-aware 交叉引用 |
| `evidence/session.json` | 当前有效登录态（含 signKeyHex） |

## 11.6 关键类名索引（本次解析）

| 地址 | 名称 | 说明 |
|---|---|---|
| `0x106e6ee9c` | `+[LMVHttpV3InterfaceTool formatHeaderForHTTPRequestHeaders:paras:deviceid:encryption:error:]` | ★ 原生签名器（SHA256 / HMAC 双模式） |
| `0x1069bfc18` | `-[AIRequestInfoPlugin getRequestHeaderWithResolve:reject:]` | RN 桥，提供 `signKey` |
| `0x1069c009c` | `-[AIRequestInfoPlugin getRequestInfo:resolve:reject:]` | RN 桥入口 |
| `0x106e8034c` | `-[LMVLocalLoginHttpTools startSDKLogin:accound:attempts:]` | `/account/v1/login` 唯一调用点 |
| `0x104f0ae10` | `-[LPMBaseLoginCheckRequestParams init]` | `os = "ios"` |
| `0x104f217dc` | `-[LPMSMSLoginRequest phoneNoCiphertext]` | SMS 登录体字段 |
| — | `LMVHttpV3InterfaceTool` / `LMVRunEnvDefine` / `LMLoginToolsManager` / `LMIdentifierKit` / `LPMLoginPathProvider` / `LMSMSTools` | 相关类 |

---

# 12. iOS Swift 客户端对齐 + 两条关键补充（2026-10-07 晚）

Python 侧全链路已通；本节把 `ios/LeapmotorLite/` 更新到同一水平，并补两个实测结论。

## 12.1 改动清单（Swift）

| 文件 | 改动 |
|---|---|
| `Crypto/LMHash.swift` | 新增 `sha256Hex(_:)`（String / Data 两个重载） |
| `Crypto/LMRSA.swift` | **新增**。RSA-1024 PKCS#1v1.5 公钥加密；含 SPKI→PKCS#1 剥壳（`SecKeyCreateWithData` 只吃 PKCS#1，1024-bit → 140 字节 DER） |
| `Crypto/LMSigner.swift` | 新增 `signPreLogin(body:signHeaders:)` = `SHA256(valueStr)`；`sign(...)` 保留为 HMAC 登录后模式 |
| `Crypto/LMSelfTest.swift` | 新增 3 条断言：登录前 valueStr、登录前 SHA256、RSA SPKI→PKCS#1(140B) |
| `API/LMEndpoints.swift` | 新增 `checkLoginWithPhone` |
| `API/LMClient.swift` | 抽出低层 `send()`；新增 `userHostHeaders()`、`preLoginRequest()`、`sendSMSCode`、`fetchOuterToken`、`exchangeOuterToken`、`loginWithSMSCode`、`findValue`；`Config` 增 `smsDeviceId`，`acceptLanguage` 改为实测值 |
| `Views/LoginView.swift` | 改为「短信验证码（三步）/ 导入登录态」两种模式，含 60s 倒计时 |
| `README.md` | 更新 §1.1 双模式签名、§1.5 登录链路、§3.2 短信登录、§5 边界 |

Swift 侧算法实现全部由 `LMSelfTest` 用同一批实测向量约束：

```
signKey(XOR3)              = 7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566
oppwd("4211")              = uHTigfMDS5zIuZX4Gq4NVQ==
HMAC valueStr              = zh-CN1.22.68...LFZ63AA15TH035113
登录前 SHA256(valueStr)     = 066fda165156e717a624dc4c53c7036ecb38a4c0cbd39d4fcb3d6e82c5df0863
RSA SPKI→PKCS#1            = 140 bytes（30 81 89 02 81 81 00 … 02 03 01 00 01）
```

## 12.2 补充结论 A：外层 token（`appLoginVO.token`）有短 TTL，但不是一次性

用同一枚外层 token `8455A42E...E180`（`evidence/session.json` 里的 `outerToken`）
在稍后重放 `/account/v1/login`：

```
code = 302010202
message = 第三方TOKEN失效
```

→ 服务端**先校验签名、再校验 token**。返回 `302010202`（token 失效）而不是
`302002002`（签名信息校验失败），**反证 SHA256 签名路径逐字节正确**。

结论修正：外层 token **不是一次性**，而是**有时效**（实测数分钟内有效）。
因此客户端必须 ②→③ 背靠背执行 —— Swift `loginWithSMSCode` 正是这样串的。

## 12.3 补充结论 B：`userId` 请求头必须 = `accountId`，否则 account host 报签名失败

在 `app-gw-global-master.leapmotor.com` 上（`vehicle/list`、`car_route`），
若 `userId` 头为空，服务端返回：

```
{"code":302010205,"result":302010205,"message":"签名信息校验失败"}
{"code":302002002,"message":"签名信息校验失败"}
```

补上 `userId = 672955179229782016`（= `accountId`）后立刻 `code:0`。
同 host 的 `mileage`、以及 `appgateway` 的 `signal/info/query` 即使 `userId` 为空也能通 ——
所以这条是 **account host 专属**的隐性要求。

> Swift 侧对应：`adoptLoginResponse` 用 `accountId` 填 `LMSession.userId`，
> `buildHeaders` 写 `headers["userId"]`；`exchangeOuterToken` 在响应缺 `accountId` 时
> 用短信步骤拿到的值补齐。

## 12.4 实时复验（2026-10-07 晚，`evidence/session.json`）

```
vehicle/list  -> {"code":0,"data":{"bindcars":[{"carAlias":"D19","carId":22129535,
                                     "plateNumber":"LFZ63AA15TH035113","year":2026,...}]}}
car_route     -> {"code":0,"data":{"regionCode":"central-origin","appCenter":"https://appgateway.leapmotor.com",...}}
signal/query  -> {"code":0,"data":{"collectTime":1791361347306,"signalMap":{"1177":732.7,"1298":1,"1182":26,...}}}
mileage       -> {"code":0,"data":{"totalmileage":1909,"deliveryDays":51}}
JWT exp       = 1791368047（now 1791361304，仍有效 ~112 min）
```

## 12.5 Swift 侧未做（不影响使用）

| 项 | 说明 |
|---|---|
| `smDeviceId` 派生 | SM4 国密，现复用抓包值；换设备需重新抓 |
| `LMVCloudBinaryPacket` | `appuser` host 的加密二进制响应，未解析 |
| refreshToken 自动续期 | JWT 到期（2h）后重新短信登录即可 |
