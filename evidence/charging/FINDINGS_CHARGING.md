# 充电中心 —— 逆向记录

日期：2026-10-09
目标：官方 `leapmotorCarOwner` 主二进制（arm64，204,405,920 B，未加密）
产物：`ios/LeapmotorLite/LeapmotorLite/API/LMEndpoints.swift` 的 `ChargeCmdid`、
      `API/LMClient.swift` 的 5 个方法、`Views/ChargeView.swift` 的四张可写卡片
可复现脚本：`client/ios_charge_cmdid.py`

---

## 0. 为什么要做这件事

改造前 `ChargeView` 是**纯只读**展示页。用户要求：

> 帮我把充电中心功能给开启，能直接在 APP 设置预约充电，健康充电，立即充电，结束充电

四个动作都必须真的下发到车端，所以必须拿到官方用的 cmdid 和 state 字段。

---

## 1. 抓包这条路走不通（这是关键前提）

把三份 HAR 全过了一遍，`POST /carownerservice/v3/api/appremotectl` 的
`cmdid` 只出现过这 6 个值：

```
110  120  130  170  230  400
```

—— 全是已实现的车控（锁车 / 寻车 / 车窗 / 空调 / 后备箱 / 备车）。
**充电四个 cmdid 一个样本都没有**，因为抓包期间没人点过官方 App 的充电页。

> 踩过的坑：一开始用 `r'"cmdid"\s*:\s*"?(\d+)"?'` 扫请求体，**一条都没匹配到**。
> 原因是请求体是 **form-urlencoded**（`carvin=…&cmdid=400&oppwd=…&state=%7B…%7D`），
> 不是 JSON。改成 `re.search(r"cmdid=(\d+)", txt)` 才成功。

结论：**只能靠反汇编主二进制。**

另外确认了充电页是**原生页面**：从官方 IPA 里提出 `Payload/leapmotorCarOwner.app/index.jsbundle`
（3,044,225 B）后只扫到 **11 条真实接口路径** —— 9 条 AI 中心
（`/appaicenter/v3/api/bigmodelapp/*`）+ 2 条协议（`/carownerservice/agreement/*`），
**一条充电相关都没有**。

> 早期记录写的「13 条全是 AI 中心」是**错的**：那 13 条里有 2 条是误报
> （`/baseMinusT`、`/baseMinusTMin` 是压缩后的 JS 局部变量名），
> 且 `agreement` 那 2 条也不是 AI 中心。完整清单见
> `evidence/charging/rn_index_apipaths.txt`。

→ 充电中心是原生页，逆向只能从主二进制下手。

---

## 2. 定位方法（链路 + 三个坑）

```
① selector 字符串 vmaddr        ← __objc_methname
② selector 槽位（selref）        ← LC_DYLD_CHAINED_FIXUPS 解码
③ selector 的 stub 地址          ← __objc_stubs（adrp x1,p + ldr x1,[x1,#o]）
④ `bl <stub>` 调用点             ← __text 里 (insn & 0xFC000000) == 0x94000000
⑤ 调用点所在分支体 → 对应的 cmdid ← 往前找 `cmp xN, #imm` + 分支
```

### 坑 ①：`__objc_selrefs` 磁盘上全是 0

`__objc_selrefs` 在 `__DATA` 段，指针是 **chained-fixups 未 rebase** 状态。
直接按 8 字节读出来是 `0x0000000000000000`，搜 selector vmaddr **一条都不命中**。

必须解析 `LC_DYLD_CHAINED_FIXUPS`（本二进制 fileoff `0xBB5C000`，size `0x2FBF8`）：

```
dyld_chained_fixups_header { fixups_version=0, starts_offset=0x20,
                             imports_offset=0x4DC, symbols_offset=0x50D8,
                             imports_count=4863, imports_format=1, symbols_format=0 }
seg_count = 6
seg_info  = [0x0, 0x0, 0x20, 0x1B0, 0x0, 0x0]
            └ 只有 __DATA_CONST(idx2) 与 __DATA(idx3) 有 fixups
__DATA_CONST: page_size=0x4000  ptr_fmt=2(PTR_64)  seg_off=0xB28C000  pages=186
__DATA      : page_size=0x4000  ptr_fmt=2(PTR_64)  seg_off=0xB574000  pages=378
```

解码后共 **583,924** 个 rebase 指针。

**两个容易写错的细节（都踩过）：**

1. **段结构体不是连续排列的。** 必须先读
   `dyld_chained_starts_in_image { uint32 seg_count; uint32 seg_info_offset[]; }`，
   再按 `seg_info_offset[i]` 跳到
   `dyld_chained_starts_in_segment`。按顺序连续读会解出
   `size=0 / ptr_fmt=394 / seg_off=0xC000000240000000` 这种垃圾。
2. **`dyld_chained_starts_in_segment` 是 22 字节，不是 26。**
   `uint32 size; uint16 page_size; uint16 pointer_format; uint64 segment_offset;
    uint32 max_valid_pointer; uint16 page_count;`
   写成 `"<IIQIIH"`（26）会把 `page_size` 和 `pointer_format` 挤成一个整数。

### 坑 ②：`__text` 里扫不到 selref 的 `adrp+ldr`

筛出 466 条指向 selref 页的 `adrp`，配 `ldr (0xFFC00000)==0xF9400000` → **0 命中**；
放宽到 8 条指令窗口、加 `add` 分支 → 仍 0 命中。

原因：**Objective-C 方法调用走 `__objc_stubs` 跳板**，`__text` 里不会直接 load selref。
改扫 `__objc_stubs`（`0x10A41D7A0`，size `0x14BC60`）→ 4 个 stub 全部找到。

### 坑 ③：分派体不是连续的 —— 有「跳转式」和「落空式」两种

编译器混用两种分发：

```
① 跳转式：  cmp  x23, #0xc1
            b.eq #0x106c5f248     ← 相等则跳到分支体

② 落空式：  cmp  x23, #0xbe
            b.ne #0x106c5ef64     ← 不相等则去统一退出
            mov  x0, x21          ← 相等则顺序「落」进分支体
            bl   0x10a4d4e20
```

**190 和 480 都是落空式。** 只认 `b.eq` 会漏掉一半。

还有一点：**一个分支体可能被多个 cmdid 共用** —— 见下面预约充电那一格。

---

## 3. 结论：cmdid 分派表（反汇编实证）

分派函数起始 `0x106C5EE00`，是 `cmp x23, #imm` + `b.gt/b.le/b.eq` 构成的二分查找树。

| cmdid | Hex | 官方 selector | 语义 | stub | 调用点 | 分支体起点 |
|---|---|---|---|---|---|---|
| **190** | `0xBE` | `requestForChargingSetContent:` | 充电上限设置 | `0x10A4D4E20` | `0x106C5F09C` | `0x106C5F094` |
| **193** | `0xC1` | `requestForBeginOrEndChargingWithContent:` | 立即 / 结束充电 | `0x10A4D4D80` | `0x106C5F250` | `0x106C5F248` |
| **480** | `0x1E0` | `requestForChargingHealthControl:` | 健康充电开关 | `0x10A4D4E00` | `0x106C5EF38` | `0x106C5EF30` |
| **161** | `0xA1` | `requestForAppointmentContrlCmdID:content:` | 预约充电 | `0x10A4D4D40` | `0x106C5EF54` | `0x106C5EF48` |

### ⚠️ 预约充电是「多对一」

`0x106C5EF48` 这个分支体被 **四个** cmdid 共用：

| cmp 地址 | cmdid | 分支 |
|---|---|---|
| `0x106C5EE88` | `0xA1` = **161** | `b.eq 0x106C5EF48` |
| `0x106C5EE98` | `0xAB` = 171 | `b.eq 0x106C5EF48` |
| `0x106C5EE50` | `0x169` = 361 | `b.eq 0x106C5EF48` |
| `0x106C5EEAC` | `0x188` = 392 | `b.eq 0x106C5EF48` |

所以「161 = 预约充电」成立，但**「预约充电只有 161」不成立**。
本 App 只用 161（它也在 `rightList` 里）。

### 交叉验证：`rightList`

```
GET sharecar/getShareVehicleListByVin
→ rightList = "190,192,170,193,171,150,370,470,130,131,230,110,430,410,160,161,
               480,360,240,361,120,340,440,220,320,420,421,301,500"
```

- **190 排第一位** —— 与反汇编一致
- 193 / 161 / 480 都在
- 171 / 361 也在（预约族的兄弟码）

---

## 4. state 字段：分级证据

**分派器只传 `cmdid` + `content`，字段名在调用方构造 —— 反汇编这一段拿不到。**
所以每个字段单独标来源，不混为一谈：

| 动作 | state 字段 | 证据等级 | 来源 |
|---|---|---|---|
| 预约充电 | `beginTime` `endTime` `percent` `isEnable` `cycles` `circulation` `recharge` | **最高** | 服务端 `config["3"]` 实测回来的**原名**，读什么写什么 |
| 健康充电 | `isPush` | **高** | 只读查询 `healthyCharging/queryPushState` 实测 `{"isPush":false}` |
| 充电上限 | `percent`（+ 冗余 `chargesoc`） | **中高** | `percent` 是 `config["3"]` 实测名；`chargesoc` 来自主二进制字段串 |
| 立即 / 结束充电 | `Begin_Charge` + 冗余 `recharge` | **中** | 字段名有据、**取值类型无样本**，所以两个键都带、都按 1/0 |

### 字段串出处

主二进制 `@178375193` 处有一整串：

```
LMVChargingAppointment.chargesoc.chargeEnable.recharge.cycles.circulation.Begin_Charge
```

`@178378399` 起：

```
v3/api/healthyCharging/control . v3/api/healthyCharging/queryPushState . isPush
lp_chargingCenter_car . chargingBattery . lp_chargingCenter_lizi_%.2d
ChargingCenter_UnlockGun . ChargingCenter_ChargeHealth . ChargingCenter_chargingHealthSubTitle
ChargingCenter_PowerLimit . ChargingCenter_OptimalLimit80 . ChargingCenter_Title
LMVChargingHealthControl . LMVChargingControl
```

类族：`LMVChargingCenterVC` / `LMVChargingCenterModel` / `LMVChargingCenterRouter` /
`LMVChargingAppointmentInterface` / `LMVChargingCenterSoclimitCell` /
`LMVChargingPileService` / `LMVChargeCardProgressView` /
`LMVCarHomeChargeCardCellVM` / `LMVCarHomeChargeCenterCellVM` / `LMVCarHomeChargingCardModel`

### 没有独立的「立即充电」HTTP 接口

主二进制里 **71 条 `v3/api/` 路径**全部列出来过，充电相关的只有：

```
v3/api/appremotectl                      ← 车控通道（带 cmdid）
v3/api/appremotectl/appointment          ← 预约设置
v3/api/appremotectl/getappointment       ← 预约查询
v3/api/appremotectl/query
v3/api/healthyCharging/control           ← 健康充电写
v3/api/healthyCharging/queryPushState    ← 健康充电读
```

→ **立即 / 结束充电只能走 `appremotectl` + cmdid 193。**

★ **2026-10-09 补充（重要）**：上表里 `appremotectl/appointment` 与
`healthyCharging/control` 这两条**本 App 没有使用** —— 预约充电走 cmdid 161、
健康充电走 cmdid 480，两条都在 `appremotectl` 车控通道上。
它们只作为**逆向记录 + 备用通道**保留在 `LMEndpoints.Path` 里，
并在注释里明确标注了「当前未启用」。

⚠️ 由此带来一个排查陷阱：**无人引用的常量，Swift 会把整个字符串字面量
优化掉**，所以在最终 IPA 的二进制里搜不到这两个路径是**正常现象**，
不是漏编译。上一轮曾把这种现象误判成「Swift 小字符串优化」——
但这两条路径分别有 46 / 47 字节，远超小字符串 15 字节的阈值，
真实原因是**死代码消除**。

（真正会被小字符串优化的是 ≤15 字节的字面量，例如 `Begin_Charge`(12)、
`chargesoc`(9)、`isPush`(6) —— 这类确实进不了 `__cstring`。）

### 抓包里的充电接口实测

```
POST /carownerservice/v3/api/healthyCharging/queryPushState
     form: carvin=…&deviceId=ios_ee45b9d830bb126d431e998943a7797a
     → {"code":0,"result":0,"data":{"isPush":false}}          （13 次）

GET  /carownerservice/v3/api/appremotectl/getappointment?carvin=…&cmdid=161
     → {"result":0,"code":0,"data":""}                        （1 次，data 是空串）
```

⚠️ `getappointment` 的 `data` 是**空串**，所以**响应结构未知** ——
预约充电的当前值只能从 `commonConfig` 的 `config["3"]` 读。

---

## 5. 官方本地化表（文案来源）

`LMVLocalizedBundle.bundle/zh-Hans.lproj/Localizable.strings`，669 条（plist 格式）。
充电相关的：

| key | 文案 |
|---|---|
| `ChargingCenter_Title` | 充电中心 |
| `ChargingCenter_SubTitle` | 插枪后会根据设定时间充电，仅支持慢充 |
| `ChargingCenter_SelectAppointmentTime` | 预约充电 |
| `ChargingCenter_ChargeHealth` | 健康充电 |
| `ChargingCenter_ChargeHealthSocAlert` | 为保持电池健康状态，无法调节至90%以上，请关闭健康充电后重调。 |
| `ChargingCenter_OptimalLimit` | 最佳限值90% |
| `ChargingCenter_OptimalLimit80` | 最佳限值80% |
| `ChargingCenter_ChargingTimeTips` | 设置时间需在当前时间\n5分钟后 |
| `ChargingCenter_ChargingCurrentTimeTips` | 设置时间需在当前时间后\n12小时内 |
| `ChargingCenter_SameTimeTips` | 开始、结束时间相同，请重新选择 |
| `ChargingCenter_PowerPriority` | 到停止时间未达到充电上限，将继续充电 |
| `ChargingCenter_CurrentSocTips` | 充电的电量不能小于当前电量 |
| `ChargingCnter_Charging10tips` | 为保护爱车，电量需先充至10%，之后恢复定时预约 |
| `ChargingCenter_ChargeHealthCloseAlertTip` | 确定关闭健康充电吗？ |
| `ChargingCenter_AppointPtcTip` | 寒冷天气时开启电池预热会提升电池的性能… |
| `LMV_Charge_startCharge` | 开始充电 |
| `LMV_Charge_endCharge` | 结束充电 |
| `LMV_ChargeCard_Charging_Reserved` | 已预约充电，请及时插枪 |
| `ChargingCenter_UnlockGun` | 解锁充电枪 |
| `ChargingCenter_BindPile` | 绑桩 |

官方 selector 全集（`__objc_methname` 里搜出的充电相关）：

```
requestForBeginOrEndChargingWithContent:
requestForChargingHealthControl:
requestForChargingSetContent:
requestForAppointmentContrlCmdID:content:
requestForUnlockChargingGun
setChargingStartTime:endTime:chargingSoc:isEnable:recharge:      ← 预约参数顺序
setChargingAppointmentSetting:completeBlock:
setChargingAppointmentSetting:isEnd:
saveAppointmentSettings:operate:toServerCompletionBlock:
saveAppointmentSettings:toServerCompletionBlock:
dicForAppointmentRemoteContrl / dicForFullRemoteContrl / dicForImmediatelyRemoteContrl
queryAppointmentSettingsFromServerCompletionBl…
fetchAppointmentSettingInfo
```

> `setChargingStartTime:endTime:chargingSoc:isEnable:recharge:` 这个签名值得记一笔 ——
> 它的**参数顺序**与我们的 `beginTime/endTime/percent/isEnable/recharge` 对得上，
> 是 state 字段命名的一个旁证。

---

## 6. 代码里的落地位置

| 文件 | 内容 |
|---|---|
| `API/LMEndpoints.swift` | `enum ChargeCmdid`（190/193/480/161）+ `chargeSocRange = 50...100` + 2 条 Path |
| `API/LMClient.swift` | `setChargingActive` / `setChargeLimit` / `setHealthyCharging` / `saveAppointmentCharge` / `refreshHealthyCharging` |
| `Views/ChargeView.swift` | `controlCard` / `healthCard` / `socLimitCard` / `appointmentEditor` + 4 个 `run*` 动作 |
| `client/ios_charge_cmdid.py` | 可复现脚本（重算 cmdid 并断言一致） |
| `client/test_refresh_contract.py` | [10] 节，51 条断言把这些数字钉死 |

---

## 7. 尚未验证的部分（诚实标注）

1. **`Begin_Charge` 的取值类型**。字段名有据，但没有任何样本能证明车端要 `1/0`、
   `true/false` 还是字符串。所以 `setChargingActive` 同时带 `Begin_Charge` 和
   `recharge` 两个键、都按 1/0 —— 多带一个未知键通常被忽略，比押注单一键名安全。
   **必须真机验证。**
2. **`chargesoc` 与 `percent` 谁是车端真读的**。两个都发了，但哪个生效未验证。
3. **预约充电保存后车端是否真的按时间充**。`getappointment` 的 `data` 是空串，
   只能间接从 `commonConfig.config["3"]` 观察是否回写成功。
4. **健康充电的 `isPush` 语义是否与 `queryPushState` 完全对称**。
   查询返回 `isPush`，下发也用 `isPush` —— 对称性合理，但没有下发样本。
5. **控制锁定期**（`oppwd` 之后的一段时间）对充电指令是否同样适用。目前沿用
   车控的锁定逻辑（`controlLockRemaining`）。

---

## 8. 复现命令

```bash
# 需要 capstone（纯 stdlib 解析 Mach-O，不依赖 lief）
python client/ios_charge_cmdid.py evidence/leapmotor_main

# 期望输出（结尾）
# ✅ 四个 cmdid + 四个 stub 地址全部与代码里的常量一致

# 契约测试
python client/test_refresh_contract.py
```

`evidence/leapmotor_main` = 官方主二进制，204,405,920 B，
`magic 0xfeedfacf`（arm64 thin），`cputype 16777228`。

段表：

| 段 | vmaddr | vmsize | fileoff | filesize |
|---|---|---|---|---|
| `__PAGEZERO` | `0x0` | `0x100000000` | `0x0` | `0x0` |
| `__TEXT` | `0x100000000` | `0xB28C000` | `0x0` | `0xB28C000` |
| `__DATA_CONST` | `0x10B28C000` | `0x2E8000` | `0xB28C000` | `0x2E8000` |
| `__DATA` | `0x10B574000` | `0xDD4000` | `0xB574000` | `0x5E8000` |
| `__RESTRICT` | `0x10C348000` | `0x0` | `0xBB5C000` | `0x0` |
| `__LINKEDIT` | `0x10C348000` | `0x794000` | `0xBB5C000` | `0x793CA0` |

`__TEXT` 段内 sections：`__text`（`0x100004200`，size `0xA4115BC`）、
`__objc_methname`（`0x10A70027C`，size `0x217267`）、`__objc_stubs`（`0x10A41D7A0`）。
