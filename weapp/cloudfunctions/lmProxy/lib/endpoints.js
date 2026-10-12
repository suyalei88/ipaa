'use strict';
/**
 * 零跑车控 —— 端点表（全部来自抓包 / IPA 字符串表，与 ios/.../API/LMEndpoints.swift 对齐）
 *
 * ⚠️ 前缀有两套，别搞混：
 *     /app/app-control-service/v3/api/...   ← 车控 POST/查询
 *     /carownerservice/v3/api/...           ← 其它杂项（同名 cmdid 的 getappointment 也在这里）
 */

const HOSTS = {
  /** 主网关（车况信号 / 车控） */
  gateway: 'https://appgateway.leapmotor.com',
  /** 账号 / 登录 / 车辆列表 / 续期 */
  account: 'https://app-gw-global-master.leapmotor.com',
  /** 短信验证码网关 */
  user: 'https://appuser.leapmotor.cn',
};

const PATHS = {
  // ---- 登录三步 ----
  sendSMS: '/app-user/applogin/compliance/sendmessagecode',      // GET  user（phoneNo=RSA）
  checkLoginWithPhone: '/app-user/applogin/check_login_with_phone', // POST user（form）
  login: '/base/base-user/account/v1/login',                      // POST account（SHA256 签名）
  refreshToken: '/base/base-user/token/v1/refresh',               // POST account（HMAC 签名 + token 头）
  logout: '/base/base-user/account/v1/logout',

  // ---- 车辆 ----
  vehicleList: '/app/app-global-service/v1/vehicle/list',         // GET  account
  carRoute: '/app/app-global-service/v1/vehicle/getCarRoute',     // GET  account

  // ---- 车况 / 里程 / 配置 ----
  signalQuery: '/app/app-signal-service/signal/info/query',       // POST gateway（JSON body）
  signalDistributed: '/carownerservice/signal/info/query/distributed',
  mileage: '/carownerservice/v3/api/drivingrecord/mileage/energy/detail', // GET ?vin=
  commonConfig: '/carownerservice/v3/api/vehicleinfo/commonConfig',       // GET ?vin=

  // ---- 车控 ----
  remoteCtl: '/app/app-control-service/v3/api/appremotectl',           // POST form-urlencoded
  remoteCtlQuery: '/app/app-control-service/v3/api/appremotectl/query', // GET ?msgID=
  appointment: '/carownerservice/v3/api/appremotectl/getappointment',   // GET（只读探测，cmdid 161）

  /**
   * 逆地理编码（经纬度 → 地址）。
   *
   * ⚠️ 路径来自 IPA 字符串表，**没有抓包样本**，参数形状是猜的。
   *    所以调用方要按多种参数形状依次试，返回什么就是什么，不做加工。
   *    App 里正规的做法是 Apple CLGeocoder / 高德，这个只在「定位」页做探测。
   */
  regeo: '/carownerservice/v3/geocode/regeo',
};

/**
 * 车控命令表。
 *
 * ★★ 2026-10-09 全面校正 —— 旧表多处 cmdid 语义是错的：
 *      120 不是「后备箱/寻车」、170 不是「大灯」、230 不是「空调」、400 不是「上电」。
 *    现按**反汇编官方主二进制的 cmdid 分派器** + 抓包双向验证的结果：
 *
 *      110 车门锁     {"value":"lock"|"unlock"}    [抓包双向验证]
 *      120 鸣笛寻车   {"value":"true"}             [抓包验证]
 *      130 后备箱     {"value":"true"|"false"}     [抓包双向验证]
 *      131 前备箱     {"value":"true"|"false"}     [同族推断，**无样本**]
 *      170 空调       {"operate":"off"|"auto"}     [抓包验证]
 *      230 车窗       {"value":"0"|"2"|"5"}        [抓包验证]  0=关 2=微开 5=半开
 *      400 哨兵模式   {"operation":"on"}           [抓包验证]  ← 不是上电
 *
 *    ⚠️ 410 才是真正的上电（`requestForOpenOn3`），但它**没有 payload 样本**，故意不接。
 *    ⚠️ 空调的风量/温度（windlevel / temperature）**键名有证据、组合无样本**，
 *       所以放在诊断页由用户自己试，不进主网格。
 */
const CTRL_COMMANDS = {
  lock: { cmdid: 110, state: { value: 'lock' }, title: '上锁', risk: 'physical' },
  unlock: { cmdid: 110, state: { value: 'unlock' }, title: '解锁', risk: 'physical' },
  horn: { cmdid: 120, state: { value: 'true' }, title: '鸣笛寻车', risk: 'low' },
  trunk_open: { cmdid: 130, state: { value: 'true' }, title: '打开后备箱', risk: 'physical' },
  trunk_close: { cmdid: 130, state: { value: 'false' }, title: '关闭后备箱', risk: 'physical' },
  frunk_open: { cmdid: 131, state: { value: 'true' }, title: '打开前备箱', risk: 'physical' },
  frunk_close: { cmdid: 131, state: { value: 'false' }, title: '关闭前备箱', risk: 'physical' },
  ac_on: { cmdid: 170, state: { operate: 'auto' }, title: '打开空调', risk: 'low' },
  ac_off: { cmdid: 170, state: { operate: 'off' }, title: '关闭空调', risk: 'low' },
  window_close: { cmdid: 230, state: { value: '0' }, title: '车窗关闭', risk: 'physical' },
  window_micro: { cmdid: 230, state: { value: '2' }, title: '车窗微开', risk: 'physical' },
  window_half: { cmdid: 230, state: { value: '5' }, title: '车窗半开', risk: 'physical' },
  sentinel: { cmdid: 400, state: { operation: 'on' }, title: '哨兵模式', risk: 'low' },
};

/** UI 分组（顺序即展示顺序） */
const CTRL_GROUPS = [
  { key: 'lock', name: '门锁', actions: ['lock', 'unlock'] },
  { key: 'trunk', name: '后备箱 / 前备箱 / 寻车', actions: ['trunk_open', 'trunk_close', 'frunk_open', 'frunk_close', 'horn'] },
  { key: 'window', name: '车窗', actions: ['window_close', 'window_micro', 'window_half'] },
  { key: 'climate', name: '空调', actions: ['ac_on', 'ac_off'] },
  { key: 'power', name: '电源 / 哨兵', actions: ['sentinel'] },
];

/** 首页快捷车控 */
const QUICK_ACTIONS = ['lock', 'unlock', 'horn', 'ac_on'];

/** 需要「周围安全」二次确认的物理动作 */
const PHYSICAL_RISK = ['lock', 'unlock', 'trunk_open', 'trunk_close', 'frunk_open', 'frunk_close',
  'window_close', 'window_micro', 'window_half'];

/** 诊断页可试的未验证 payload（键名有证据、组合无样本） */
const UNVERIFIED_PAYLOADS = [
  { cmdid: 170, state: { operate: 'manual', windlevel: '3', temperature: '24' }, note: '空调手动：风量 3 档 / 24 ℃（键名有证据，组合无样本）' },
  { cmdid: 170, state: { operate: 'manual', windlevel: '9', temperature: '32' }, note: '空调手动：风量 9 档 / 32 ℃（范围来自 funcConfig.HVAC）' },
  { cmdid: 410, state: { operation: 'on' }, note: '上电（410 = requestForOpenOn3，payload 无样本）' },
];

module.exports = {
  HOSTS,
  PATHS,
  CTRL_COMMANDS,
  CTRL_GROUPS,
  QUICK_ACTIONS,
  PHYSICAL_RISK,
  UNVERIFIED_PAYLOADS,
};
