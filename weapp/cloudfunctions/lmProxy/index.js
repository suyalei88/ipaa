'use strict';
/**
 * 零跑车控 —— 云函数入口（微信云开发）
 * ==================================================================
 *
 * 为什么要有这个云函数？
 *   微信小程序的 `wx.request` **只能**请求「在小程序后台配置过、且已 ICP 备案」的域名。
 *   `appgateway.leapmotor.com` 是零跑的域名，我们既不能给它备案、也不能把它加进白名单，
 *   所以**小程序直连在体验版/正式版必挂**。
 *   云函数跑在腾讯云服务端，发起的是普通 HTTPS 请求，**不受小程序域名白名单限制**，
 *   因此「小程序 → 云函数 → 零跑」这条路不需要备案域名。
 *
 * 设计原则：
 *   1. **签名与加密全部留在这边**，小程序端不接触 signKey / oppwd。
 *   2. **无状态** —— 会话由小程序端保存并每次带上，云函数不存任何凭据。
 *      （想更安全可以改成把会话存云开发数据库、按 openid 取，见 weapp/README.md。）
 *   3. **零 npm 依赖** —— 只用 node 内置 crypto/https，冷启动快、不用 install。
 *
 * 调用约定：`wx.cloud.callFunction({ name: 'lmProxy', data: { action, ... } })`
 *   成功 → `{ ok: true, data: ... }`
 *   失败 → `{ ok: false, code?, error, payload? }`
 */

const { LMClient, DEFAULT_CONFIG } = require('./lib/client');
const { CTRL_COMMANDS, CTRL_GROUPS, QUICK_ACTIONS, PHYSICAL_RISK, UNVERIFIED_PAYLOADS } = require('./lib/endpoints');
const { encryptOppwd } = require('./lib/crypto');

const BUILD = 'weapp-1.0.0';

/** 需要登录态才能做的 action */
const NEEDS_SESSION = new Set([
  'refresh', 'vehicles', 'status', 'mileage', 'commonConfig',
  'control', 'ctlQuery', 'appointment', 'regeo',
]);

function makeClient(event) {
  const cfg = Object.assign({}, DEFAULT_CONFIG);
  // 允许小程序端覆盖 deviceId（同一台手机应固定一个，见 README）
  if (event && event.deviceId) cfg.deviceId = String(event.deviceId);
  if (event && event.config) Object.assign(cfg, event.config);
  return new LMClient(cfg, event && event.session ? event.session : null);
}

/** 统一错误响应 */
function fail(err) {
  const out = { ok: false, error: (err && err.message) || String(err) };
  if (err && err.code !== undefined) out.code = err.code;
  if (err && err.payload !== undefined) out.payload = err.payload;
  return out;
}

exports.main = async (event) => {
  const action = (event && event.action) || '';
  try {
    if (NEEDS_SESSION.has(action) && !(event && event.session && event.session.accessToken)) {
      const e = new Error('未登录：缺少 session');
      e.code = 'NO_SESSION';
      throw e;
    }

    switch (action) {
      // ---------------- 自检 ----------------
      case 'ping':
        return { ok: true, data: { build: BUILD, actions: Object.keys(CTRL_COMMANDS).length } };

      /** 把命令表 / 分组交给小程序端，避免两边各写一份导致漂移 */
      case 'meta':
        return {
          ok: true,
          data: {
            build: BUILD,
            groups: CTRL_GROUPS,
            commands: CTRL_COMMANDS,
            quickActions: QUICK_ACTIONS,
            physicalRisk: PHYSICAL_RISK,
            unverifiedPayloads: UNVERIFIED_PAYLOADS,
            deviceId: DEFAULT_CONFIG.deviceId,
          },
        };

      // ---------------- 登录 ----------------
      case 'sendSms': {
        const cli = makeClient(event);
        const res = await cli.sendSMS(String(event.phone || ''));
        return { ok: true, data: { message: (res && (res.message || res.msg)) || '验证码已发送' } };
      }

      case 'login': {
        const cli = makeClient(event);
        const session = await cli.loginWithSMSCode(String(event.phone || ''), String(event.code || ''));
        return { ok: true, data: { session } };
      }

      case 'refresh': {
        const cli = makeClient(event);
        const session = await cli.refreshSession();
        return { ok: true, data: { session } };
      }

      // ---------------- 车辆 / 车况 ----------------
      case 'vehicles': {
        const cli = makeClient(event);
        return { ok: true, data: await cli.vehicleList() };
      }

      case 'status': {
        const cli = makeClient(event);
        return { ok: true, data: await cli.status(String(event.vin || '')) };
      }

      case 'mileage': {
        const cli = makeClient(event);
        return { ok: true, data: await cli.mileage(String(event.vin || '')) };
      }

      case 'commonConfig': {
        const cli = makeClient(event);
        return { ok: true, data: await cli.commonConfig(String(event.vin || '')) };
      }

      // ---------------- 车控 ----------------
      case 'control': {
        const cli = makeClient(event);
        const vin = String(event.vin || '');

        // 解析 cmdid / state：优先用显式的（诊断页），否则查命令表
        let cmdid = event.cmdid;
        let state = event.state;
        let label = event.label || '';
        if (cmdid === undefined || cmdid === null) {
          const def = CTRL_COMMANDS[event.name];
          if (!def) throw new Error(`未知车控动作: ${event.name}`);
          cmdid = def.cmdid;
          state = def.state;
          label = def.title;
        }
        if (typeof state === 'string') {
          try { state = JSON.parse(state); } catch (e) { throw new Error('state 不是合法 JSON'); }
        }

        // oppwd：优先用显式传入的密文，否则用明文现场派生（key/iv 只跟 accessToken 有关）
        let oppwd = event.oppwd || '';
        if (!oppwd && event.opPassword) {
          oppwd = encryptOppwd(cli.session.accessToken, String(event.opPassword));
        }

        const raw = await cli.remoteCtl(vin, Number(cmdid), state || {}, oppwd);
        const msgId = raw && typeof raw.data === 'string' && /^\d+$/.test(raw.data) ? raw.data : null;
        return {
          ok: true,
          data: {
            label,
            cmdid: Number(cmdid),
            msgId,
            timeout: raw && raw.timeout,
            raw,
          },
        };
      }

      case 'ctlQuery': {
        const cli = makeClient(event);
        const raw = await cli.ctlQuery(String(event.msgId || ''));
        return { ok: true, data: { done: raw && raw.data === 1, raw } };
      }

      /** 只读探测：远程预约查询（cmdid 161） */
      case 'appointment': {
        const cli = makeClient(event);
        return { ok: true, data: await cli.appointment(String(event.vin || ''), event.cmdid || 161) };
      }

      /** 逆地理编码探测（路径有、样本无，参数靠试） */
      case 'regeo': {
        const cli = makeClient(event);
        const r = await cli.regeo(event.lat, event.lng, String(event.vin || ''));
        return {
          ok: true,
          data: {
            found: r.ok,
            text: r.ok
              ? JSON.stringify(r.res)
              : '五种参数形状都没拿到有效结果。以下是每次尝试的原始响应：\n' + JSON.stringify(r.tried, null, 2),
          },
        };
      }

      default:
        throw new Error(`未知 action: "${action}"`);
    }
  } catch (err) {
    return fail(err);
  }
};
