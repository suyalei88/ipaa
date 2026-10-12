'use strict';
/**
 * 零跑车控 —— API 客户端（云函数侧）
 * ==================================================================
 * 与 client/leapmotor_client.py / ios .../API/LMClient.swift 行为对齐。
 *
 * 只用 node 内置 `https`，不引第三方 HTTP 库 —— 云函数零依赖、冷启动快。
 *
 * 请求头有三套，用错会得到 302002002（签名校验失败）或 1019（参数不能为空）：
 *   ① userHostHeaders     → appuser 网关（发码 / 用码换外层 token），无签名
 *   ② buildPreLoginHeaders→ account 网关（外层 token 换 JWT），sign = SHA256(valueStr)
 *   ③ buildHeaders        → 已登录接口（车况 / 车控 / 续期），sign = HMAC(valueStr, signKey)
 */

const https = require('https');
const { URL } = require('url');

const { HOSTS, PATHS, CTRL_COMMANDS } = require('./endpoints');
const { rsaEncryptPhone, encryptOppwd, deriveKeys } = require('./crypto');
const { sign, signPreLogin, makeSignHeaders } = require('./sign');

// ----------------------------------------------------------------------
// 默认配置（全部是官方 iOS 1.22.68 抓包 / 二进制里的实测值）
// ----------------------------------------------------------------------
const DEFAULT_CONFIG = {
  /** 设备标识。官方抓包里的那个 —— 服务端认过，避免新设备读不到带设备维度的状态 */
  deviceId: 'ios_ee45b9d830bb126d431e998943a7797a',
  /** 短信网关的 SM4 设备指纹（国密）。逆向自原生，登录链路必需 */
  smDeviceId:
    'B1rFqR82E2Z7do2KhMDKziLEuIcoEt4wY8QTy7/43ImlKMu591xoe/c8kgMPsTk4' +
    'P/nPH8eAUxQCnmA3GjTZODg==',
  deviceType: 'iOS',
  acceptLanguage: 'zh-Hans-CN;q=1, en-CN;q=0.9',
  source: 'leapmotor',
  version: '1.22.68',
  channel: '1',
  subversion: '3.22.2-3',
  userAgent: 'leapmotorCarOwner/1.22.68 (iPhone; iOS 26.4.1; Scale/3.00)',
  timeout: 20000,
};

// ----------------------------------------------------------------------
// 工具
// ----------------------------------------------------------------------

/**
 * 严格百分号编码（RFC3986 unreserved 之外全部转义）。
 *
 * ⚠️ 绝不能用 `encodeURIComponent` 的默认行为 —— 它不转义 `!'()*`；
 *    更重要的是**不能**用会把 `+` 当空格的编码方式：
 *    RSA / AES 密文的 base64 里经常出现 `+`，一旦被服务端按 form 规则解成空格，
 *    密文就坏了，表现为业务错误 `1019 参数不能为空`（实测：裸 `+` → 1019，`%2B` → 200）。
 */
function encodeStrict(s) {
  return encodeURIComponent(String(s)).replace(
    /[!'()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

/** 拼 URL（query 用严格编码；排序只为输出确定，服务端不依赖顺序） */
function buildURL(host, path, params) {
  let s = host + path;
  if (params && Object.keys(params).length) {
    const q = Object.keys(params)
      .sort()
      .map((k) => `${encodeStrict(k)}=${encodeStrict(params[k])}`)
      .join('&');
    s += `?${q}`;
  }
  return s;
}

/** 极简 https 请求（Promise 化） */
function httpRequest({ method, url, headers, body, timeout }) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      {
        method,
        hostname: u.hostname,
        port: u.port || 443,
        path: u.pathname + u.search,
        headers: Object.assign({}, headers),
        timeout: timeout || DEFAULT_CONFIG.timeout,
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') });
        });
      }
    );
    req.on('timeout', () => req.destroy(new Error('请求超时')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function parseJSON(text) {
  try {
    return JSON.parse(text);
  } catch (e) {
    return { _raw: text };
  }
}

function isOkCode(code) {
  return code === 0 || code === 200;
}

/** 业务错误：抛出去，让 index.js 统一成 {ok:false, code, message} */
function businessError(dict) {
  const code = dict && typeof dict.code === 'number' ? dict.code : -1;
  const msg = (dict && (dict.message || dict.msg)) || '接口返回失败';
  const err = new Error(msg);
  err.code = code;
  err.payload = dict;
  return err;
}

/** 递归找第一个非空 key（对齐 Python find_key / Swift findValue） */
function findValue(obj, key) {
  if (obj === null || obj === undefined) return undefined;
  if (Array.isArray(obj)) {
    for (const v of obj) {
      const r = findValue(v, key);
      if (r !== undefined) return r;
    }
    return undefined;
  }
  if (typeof obj === 'object') {
    const v = obj[key];
    if (v !== null && v !== undefined) {
      if (typeof v === 'string') {
        if (v !== '') return v;
      } else {
        return v;
      }
    }
    for (const k of Object.keys(obj)) {
      const r = findValue(obj[k], key);
      if (r !== undefined) return r;
    }
  }
  return undefined;
}

// ----------------------------------------------------------------------
// 请求头三套
// ----------------------------------------------------------------------

/** ① appuser 网关（发码 / 用码换外层 token）：无 sign、无 token */
function userHostHeaders(cfg, contentType) {
  return {
    APPImei: cfg.deviceId,
    APPVersion: cfg.version,
    APPPlatform: 'iOS',
    'C-VERSIONS': 'APP',
    'XFX-CDN-VRS': 'v4',
    'User-Agent': cfg.userAgent,
    Accept: '*/*',
    'Accept-Language': cfg.acceptLanguage,
    'Content-Type': contentType,
  };
}

/** ③ 已登录接口：sign = HMAC(valueStr, signKey)，并带 token / userId / carvin / cartype */
function buildHeaders(ctx, signBody, contentType) {
  const cfg = ctx.config;
  const session = ctx.session || {};
  const signHeaders = makeSignHeaders(cfg);
  const headers = { 'Content-Type': contentType };

  const sg = sign(signBody, signHeaders, session.signKeyHex);
  if (sg) headers.sign = sg;

  Object.keys(signHeaders).forEach((k) => { headers[k] = signHeaders[k]; });
  headers['x-subversion'] = cfg.subversion;
  headers['x-canary-version'] = '';
  headers['x-api-signature-version'] = '2.0';
  headers['x-region'] = 'CN';
  headers.userId = session.userId || '';
  headers.token = session.accessToken || '';
  headers.carvin = ctx.vin || '';
  headers.cartype = ctx.carType || '';
  headers['User-Agent'] = cfg.userAgent;
  headers['Accept-Language'] = 'zh-Hans-CN;q=1, en-CN;q=0.9';
  return headers;
}

/** ② account 网关的「登录前」请求：sign = SHA256(valueStr)，无密钥 */
function buildPreLoginHeaders(ctx, signBody) {
  const cfg = ctx.config;
  const signHeaders = makeSignHeaders(cfg);
  // 注意：参与签名的是驼峰 key（deviceId/deviceType），实际发送的 header 名用小写
  const headers = {
    userid: ctx.accountId || '',
    source: cfg.source,
    'x-api-signature-version': '2.0',
    'x-region': 'CN',
    'x-canary-version': '',
    devicetype: cfg.deviceType,
    channel: cfg.channel,
    cartype: ctx.carType || 'D19',
    'x-subversion': cfg.subversion,
    version: cfg.version,
    deviceid: cfg.deviceId,
    acceptLanguage: cfg.acceptLanguage,
    timestamp: signHeaders.timestamp,
    nonce: signHeaders.nonce,
    sign: signPreLogin(signBody, signHeaders),
    'Content-Type': 'application/json',
    'User-Agent': cfg.userAgent,
  };
  return headers;
}

// ----------------------------------------------------------------------
// 客户端
// ----------------------------------------------------------------------

class LMClient {
  constructor(config, session) {
    this.config = Object.assign({}, DEFAULT_CONFIG, config || {});
    this.session = session || null;
  }

  /** 通用请求 */
  async request(method, host, path, opts) {
    const o = opts || {};
    const url = buildURL(host, path, o.params);

    // ★ 参与签名的 body：form 要 URL 解码后的字典，JSON 用原对象，GET 的 query 一并并入
    let signBody = {};
    if (o.form) signBody = Object.assign({}, o.form);
    else if (o.body) signBody = Object.assign({}, o.body);
    if (o.params) signBody = Object.assign(signBody, o.params);

    let headers;
    if (o.userHost) headers = userHostHeaders(this.config, o.contentType || 'application/json');
    else if (o.preLogin) headers = buildPreLoginHeaders({ config: this.config, accountId: o.accountId, carType: o.carType }, signBody);
    else headers = buildHeaders({ config: this.config, session: this.session, vin: o.vin, carType: o.carType }, signBody, o.contentType || 'application/json');

    let body;
    if (o.form) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      body = Object.keys(o.form)
        .map((k) => `${encodeStrict(k)}=${encodeStrict(o.form[k])}`)
        .join('&');
    } else if (o.body) {
      body = JSON.stringify(o.body);
    }

    const res = await httpRequest({ method, url, headers, body, timeout: this.config.timeout });
    const dict = parseJSON(res.text);
    if (dict && typeof dict === 'object' && dict._raw === undefined) dict._status = res.status;
    return dict;
  }

  // ---------------- 登录三步 ----------------

  /** 第 1 步：发短信验证码（phoneNo = RSA 密文；无签名） */
  async sendSMS(phone) {
    const enc = rsaEncryptPhone(phone);
    const res = await this.request('GET', HOSTS.user, PATHS.sendSMS, {
      userHost: true,
      params: { phoneNo: enc, smDeviceId: this.config.smDeviceId },
    });
    if (!isOkCode(res.code)) throw businessError(res);
    return res;
  }

  /**
   * 第 2 步：验证码 → 外层 token（SDK login token，还不是 JWT）
   * ★ 必须是 form-urlencoded；用 JSON 会得到 1019「参数不能为空」
   */
  async fetchOuterToken(phone, code) {
    const enc = rsaEncryptPhone(phone);
    const form = {
      os: 'ios',
      smDeviceId: this.config.smDeviceId,
      phoneNoCiphertext: enc,
      phoneNumber: phone,
      smsCode: code,
      deviceID: this.config.deviceId,
      pageUrl: '',
    };
    const res = await this.request('POST', HOSTS.user, PATHS.checkLoginWithPhone, {
      userHost: true,
      contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
      form,
    });
    if (!isOkCode(res.code)) throw businessError(res);
    const token = findValue(res, 'token');
    if (!token || typeof token !== 'string') {
      const e = new Error('响应里没有 appLoginVO.token');
      e.payload = res;
      throw e;
    }
    const accountId = findValue(res, 'accountId');
    const nickname = findValue(res, 'nickname');
    return {
      outerToken: token,
      accountId: accountId === undefined ? '' : String(accountId),
      nickname: typeof nickname === 'string' ? nickname : '',
    };
  }

  /**
   * 第 3 步：外层 token 兑换 JWT（★ SHA256 签名，无密钥）
   * → data = { accessToken, refreshToken, signParam{r2,r3}, encryptParam{r2,r3}, ... }
   */
  async exchangeOuterToken(outerToken, accountId) {
    const body = { identifier: accountId, identifierType: '1', security: outerToken };
    const res = await this.request('POST', HOSTS.account, PATHS.login, {
      preLogin: true,
      accountId,
      carType: 'D19',
      body,
    });
    if (typeof res.code === 'number' && res.code !== 0) throw businessError(res);
    const inner = res.data && typeof res.data === 'object' ? res.data : res;
    return this.buildSession(inner, accountId);
  }

  /** 从登录/续期响应构造会话对象（容忍扁平键与点路径两种形态） */
  buildSession(inner, fallbackAccountId) {
    const accessToken = inner.accessToken || '';
    if (!accessToken) throw new Error('登录响应里没有 accessToken');
    const signParam = inner.signParam || null;
    const encryptParam = inner.encryptParam || null;
    const keys = deriveKeys(accessToken, signParam, encryptParam);
    if (!keys.signKeyHex) throw new Error('signKey 派生失败（signParam.r2/r3 缺失）');
    const accountId = inner.accountId !== undefined && inner.accountId !== null && inner.accountId !== ''
      ? String(inner.accountId)
      : (fallbackAccountId || '');
    return {
      accessToken,
      refreshToken: inner.refreshToken || '',
      signKeyHex: keys.signKeyHex,
      encryptKeyHex: keys.encryptKeyHex,
      userId: accountId,
      accountId,
      nickname: typeof inner.nickname === 'string' ? inner.nickname : '',
      deviceId: this.config.deviceId,
    };
  }

  /** 一步到位：短信验证码 → 会话 */
  async loginWithSMSCode(phone, code) {
    const r = await this.fetchOuterToken(phone, code);
    const ident = r.accountId || phone;
    const session = await this.exchangeOuterToken(r.outerToken, ident);
    if (!session.nickname && r.nickname) session.nickname = r.nickname;
    return session;
  }

  /**
   * 续期：POST /base/base-user/token/v1/refresh  body = {"refreshToken": "..."}
   *
   * ★ 必须走 HMAC 签名（用**当前** signKey）+ 带 token 头 —— 实测无密钥 SHA256 会得到
   *   「签名信息校验失败」。响应会同时返回**新的 refreshToken**（TTL ≈ 7 天，滑动续期）。
   */
  async refreshSession() {
    if (!this.session || !this.session.refreshToken) throw new Error('没有 refreshToken，无法续期');
    const rt = this.session.refreshToken;
    const res = await this.request('POST', HOSTS.account, PATHS.refreshToken, { body: { refreshToken: rt } });
    if (typeof res.code === 'number' && res.code !== 0) throw businessError(res);
    const inner = res.data && typeof res.data === 'object' ? res.data : res;
    if (inner.accountId === undefined || inner.accountId === null || inner.accountId === '') {
      if (this.session.accountId) inner.accountId = this.session.accountId;
    }
    if (inner.nickname === undefined || inner.nickname === null) {
      if (this.session.nickname) inner.nickname = this.session.nickname;
    }
    const s = this.buildSession(inner, this.session.accountId);
    // 续期响应可能不带 refreshToken → 沿用旧的
    if (!s.refreshToken) s.refreshToken = this.session.refreshToken;
    return s;
  }

  // ---------------- 车辆 / 车况 ----------------

  async vehicleList() {
    const res = await this.request('GET', HOSTS.account, PATHS.vehicleList);
    if (typeof res.code === 'number' && res.code !== 0) throw businessError(res);
    return res;
  }

  /** 车况信号（约 130 个 signalId） */
  async status(vin) {
    const body = {
      appVersion: this.config.version,
      isMainApp: '1',
      osType: this.config.deviceType,
      vin,
    };
    const res = await this.request('POST', HOSTS.gateway, PATHS.signalQuery, { body, vin });
    if (typeof res.code === 'number' && res.code !== 0) throw businessError(res);
    return res;
  }

  async mileage(vin) {
    const res = await this.request('GET', HOSTS.gateway, PATHS.mileage, { params: { vin }, vin });
    if (typeof res.code === 'number' && res.code !== 0) throw businessError(res);
    return res;
  }

  async commonConfig(vin) {
    const res = await this.request('GET', HOSTS.gateway, PATHS.commonConfig, { params: { vin }, vin });
    if (typeof res.code === 'number' && res.code !== 0) throw businessError(res);
    return res;
  }

  // ---------------- 车控 ----------------

  /**
   * 下发车控。
   *   POST /app/app-control-service/v3/api/appremotectl
   *   Content-Type: application/x-www-form-urlencoded
   *   body: carvin=..&cmdid=..&oppwd=..&state=<urlencoded json>
   *
   * ★ 签名用的是 **URL 解码后**的表单字典（state 是 JSON 原文），不是 raw body 字符串。
   */
  async remoteCtl(vin, cmdid, state, oppwd) {
    const stateJson = JSON.stringify(state);
    const form = {
      carvin: vin,
      cmdid: String(cmdid),
      oppwd: oppwd || '',
      state: stateJson,
    };
    const res = await this.request('POST', HOSTS.gateway, PATHS.remoteCtl, { form, vin });
    return res;
  }

  /** 轮询车控结果：data = 1 → 成功；0 → 进行中/失败 */
  async ctlQuery(msgId) {
    const res = await this.request('GET', HOSTS.gateway, PATHS.remoteCtlQuery, { params: { msgID: msgId } });
    return res;
  }

  /** 只读探测：远程预约查询（cmdid 161 只以查询形式出现过，从没以「下发」出现过） */
  async appointment(vin, cmdid) {
    const res = await this.request('GET', HOSTS.gateway, PATHS.appointment, {
      params: { carvin: vin, cmdid: String(cmdid || 161) },
      vin,
    });
    return res;
  }

  /**
   * 逆地理编码探测 —— 依次试几种参数形状，返回第一个「code 0 且 data 非空」的结果。
   * 全部失败时把每次尝试都带回去，方便用户照着改。
   *
   * ⚠️ 这个端点在 IPA 里有路径但没有抓包样本，**参数名是猜的**，不保证能用。
   */
  async regeo(lat, lng, vin) {
    const la = String(lat);
    const ln = String(lng);
    const shapes = [
      { latitude: la, longitude: ln },
      { lat: la, lng: ln },
      { lat: la, lon: ln },
      { latitude: la, longitude: ln, vin: vin || '' },
      { longitude: ln, latitude: la, vin: vin || '' },
    ];
    const tried = [];
    for (let i = 0; i < shapes.length; i += 1) {
      const params = shapes[i];
      try {
        const res = await this.request('GET', HOSTS.gateway, PATHS.regeo, { params, vin });
        tried.push({ params, res });
        const data = res && res.data;
        const nonEmpty = data !== undefined && data !== null && data !== '' &&
          !(typeof data === 'object' && Object.keys(data).length === 0);
        if (res && isOkCode(res.code) && nonEmpty) {
          return { ok: true, params, res, tried };
        }
      } catch (e) {
        tried.push({ params, error: e.message });
      }
    }
    return { ok: false, tried };
  }
}

module.exports = {
  DEFAULT_CONFIG,
  LMClient,
  CTRL_COMMANDS,
  encodeStrict,
  buildURL,
  httpRequest,
  findValue,
  isOkCode,
  businessError,
  encryptOppwd,
};
