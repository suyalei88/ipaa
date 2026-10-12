/**
 * 云函数调用封装。
 *
 * 小程序 **不直连** 零跑域名 —— 那条路在体验版/正式版必然失败（域名白名单 + 备案）。
 * 所有请求都走 `wx.cloud.callFunction`，由云函数在服务端发起。
 */

const cfg = require('../config.js');
const store = require('./store.js');

const FN = cfg.cloudFunctionName;

/** accessToken 的 TTL 是 7200 秒；提前 10 分钟续期，避免边界上刚好过期 */
const REFRESH_AFTER_MS = 110 * 60 * 1000;

let refreshing = null; // 并发去重：多个请求同时发现过期，只续一次

/**
 * 调云函数。
 * @returns {Promise<any>} 成功时 resolve 云函数的 data；失败 reject Error（带 code / payload）
 */
function call(action, data) {
  return new Promise((resolve, reject) => {
    wx.cloud.callFunction({
      name: FN,
      data: Object.assign({ action }, data || {}),
      success(res) {
        const r = (res && res.result) || {};
        if (r.ok) {
          resolve(r.data);
          return;
        }
        const err = new Error(r.error || '云函数返回失败');
        err.code = r.code;
        err.payload = r.payload;
        reject(err);
      },
      fail(e) {
        const err = new Error(
          '调用云函数失败：' + ((e && (e.errMsg || e.message)) || e) +
          '\n（检查：云函数 lmProxy 是否已部署？config.js 里的 cloudEnv 是否正确？）'
        );
        err.code = 'CALL_FAIL';
        reject(err);
      },
    });
  });
}

/** 带登录态的调用（自动带上 session / deviceId） */
function callAuthed(action, data) {
  const session = store.getSession();
  return call(action, Object.assign({
    session,
    deviceId: store.getDeviceId(),
  }, data || {}));
}

/* ---------------- 登录 ---------------- */

function sendSms(phone) {
  return call('sendSms', { phone });
}

async function login(phone, code) {
  const r = await call('login', { phone, code, deviceId: store.getDeviceId() });
  const session = r.session;
  session._issuedAt = Date.now();
  store.setSession(session);
  return session;
}

function logout() {
  store.clearSession();
  store.setVehicle(null);
}

/* ---------------- 续期 ---------------- */

/** 会话是不是该续期了（按本地记录的签发时刻算） */
function sessionNeedsRefresh() {
  const s = store.getSession();
  if (!s || !s.refreshToken) return false;
  const at = s._issuedAt || 0;
  if (!at) return true; // 老版本存的会话没有签发时刻，续一次补上
  return Date.now() - at > REFRESH_AFTER_MS;
}

/** 真打续期接口；并发调用复用同一个 Promise */
function refreshSession() {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    try {
      const s = store.getSession();
      const r = await call('refresh', { session: s, deviceId: store.getDeviceId() });
      const session = r.session;
      session._issuedAt = Date.now();
      store.setSession(session);
      return session;
    } finally {
      refreshing = null;
    }
  })();
  return refreshing;
}

/** 需要的话先续期（不抛错 —— 续期失败不该让业务请求也失败） */
async function ensureFreshSession() {
  if (!store.isLoggedIn()) return false;
  if (!sessionNeedsRefresh()) return true;
  try {
    await refreshSession();
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * 带自动续期的受保护调用：
 *   ① 主动：token 快到期时先续
 *   ② 被动：服务端仍判失效（业务码 401 / 提示 token）时续一次再重放
 */
async function authed(action, data) {
  await ensureFreshSession();
  try {
    return await callAuthed(action, data);
  } catch (e) {
    const msg = String(e && e.message || '');
    const looksLikeTokenError =
      e && (e.code === 401 || e.code === 401001 || e.code === 302002002) ||
      /token|登录|失效|未登录|重新登录/i.test(msg);
    if (!looksLikeTokenError || !store.getSession() || !store.getSession().refreshToken) throw e;
    await refreshSession();
    return await callAuthed(action, data);
  }
}

/* ---------------- 业务封装 ---------------- */

function getMeta() {
  return call('meta');
}

function vehicles() {
  return authed('vehicles');
}

function status(vin) {
  return authed('status', { vin });
}

function mileage(vin) {
  return authed('mileage', { vin });
}

function commonConfig(vin) {
  return authed('commonConfig', { vin });
}

/**
 * 下发车控。
 * @param {object} p { vin, name? , cmdid?, state?, opPassword?, oppwd? }
 */
function control(p) {
  return authed('control', p);
}

function ctlQuery(msgId) {
  return authed('ctlQuery', { msgId });
}

function appointment(vin, cmdid) {
  return authed('appointment', { vin, cmdid });
}

/** 逆地理编码探测（返回 {found, text}；text 是原样字符串，不做加工） */
function regeo(lat, lng) {
  const v = store.getVehicle() || {};
  return authed('regeo', { lat, lng, vin: v.vin || '' });
}

/**
 * 下发后轮询直到成功或超时。
 * @returns {Promise<{ok:boolean, timedOut:boolean, samples:number}>}
 */
async function controlAndWait(p, timeoutMs) {
  const limit = timeoutMs || 22000;
  const sent = await control(p);
  if (!sent || !sent.msgId) {
    return { ok: false, timedOut: false, samples: 0, sent };
  }
  const deadline = Date.now() + limit;
  let samples = 0;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 1500));
    samples += 1;
    try {
      const q = await ctlQuery(sent.msgId);
      if (q && q.done) return { ok: true, timedOut: false, samples, sent };
    } catch (e) {
      // 单次查询失败不算数，继续轮
    }
  }
  return { ok: false, timedOut: true, samples, sent };
}

module.exports = {
  call,
  callAuthed,
  authed,
  sendSms,
  login,
  logout,
  refreshSession,
  sessionNeedsRefresh,
  ensureFreshSession,
  getMeta,
  vehicles,
  status,
  mileage,
  commonConfig,
  control,
  ctlQuery,
  controlAndWait,
  appointment,
  regeo,
};
