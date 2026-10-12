const api = require('../../utils/api.js');
const store = require('../../utils/store.js');
const signals = require('../../utils/signals.js');
const fmt = require('../../utils/format.js');
const ctl = require('../../utils/control.js');

const app = getApp();

Page({
  data: {
    build: '',
    accountId: '',
    nickname: '',
    hasRefreshToken: false,
    vin: '',
    vehicleLabel: '',
    vehicles: [],
    vehicleIndex: 0,
    remember: true,
    hasOpPassword: false,
    coordSystem: 'gcj02',
    showSignals: false,
    signalGroups: [],
    unknownIds: '',
    log: '',
    unverified: [],
    busy: false,
  },

  onShow() {
    if (!store.isLoggedIn()) {
      wx.reLaunch({ url: '/pages/login/login' });
      return;
    }
    const s = store.getSession() || {};
    const v = store.getVehicle() || {};
    this.setData({
      accountId: s.accountId || s.userId || '',
      nickname: s.nickname || '',
      hasRefreshToken: !!s.refreshToken,
      vin: v.vin || '',
      vehicleLabel: v.carAlias || v.vinNickname || v.vin || '',
      remember: store.getRememberOpPwd(),
      hasOpPassword: !!store.getOpPassword(),
      coordSystem: store.getCoordSystem('gcj02'),
    });
    this.loadMeta();
    this.loadVehicles();
  },

  appendLog(line) {
    const t = new Date();
    const p = (n) => (n < 10 ? `0${n}` : String(n));
    const stamp = `${p(t.getHours())}:${p(t.getMinutes())}:${p(t.getSeconds())}`;
    this.setData({ log: `[${stamp}] ${line}\n${this.data.log}`.slice(0, 5000) });
  },

  async loadMeta() {
    try {
      let meta = app.globalData.meta;
      if (!meta) {
        meta = await api.getMeta();
        app.globalData.meta = meta;
      }
      this.setData({ build: meta.build || '', unverified: meta.unverifiedPayloads || [] });
    } catch (e) {
      this.appendLog(`✗ 拉取 meta 失败：${e.message}`);
    }
  },

  async loadVehicles() {
    try {
      const res = await api.vehicles();
      const data = (res && res.data) || {};
      const list = [].concat(data.bindcars || [], data.sharedcars || []);
      const cur = store.getVehicle() || {};
      let idx = list.findIndex((x) => x.vin === cur.vin);
      if (idx < 0) idx = 0;
      this.setData({ vehicles: list, vehicleIndex: idx });
      if (list.length && !cur.vin) {
        store.setVehicle(list[0]);
        this.setData({ vin: list[0].vin, vehicleLabel: list[0].carAlias || list[0].vin });
      }
    } catch (e) {
      this.appendLog(`✗ 车辆列表失败：${e.message}`);
    }
  },

  onPickVehicle(e) {
    const idx = Number(e.detail.value);
    const v = this.data.vehicles[idx];
    if (!v) return;
    store.setVehicle(v);
    this.setData({
      vehicleIndex: idx,
      vin: v.vin,
      vehicleLabel: v.carAlias || v.vinNickname || v.vin,
    });
    this.appendLog(`✓ 已切换到 ${v.vin}`);
  },

  onToggleRemember(e) {
    const val = e.detail.value;
    store.setRememberOpPwd(val);
    this.setData({ remember: val, hasOpPassword: !!store.getOpPassword() });
    if (!val) this.appendLog('已关闭「记住操作密码」，并清除了本地保存的那一份');
  },

  async onSetOpPassword() {
    store.setOpPassword('');
    this.setData({ hasOpPassword: false });
    try {
      const pwd = await ctl.ensureOpPassword();
      this.setData({ hasOpPassword: !!store.getOpPassword() });
      this.appendLog(`✓ 操作密码已录入（${pwd.length} 位）`);
    } catch (e) {
      this.appendLog(`已取消录入操作密码`);
    }
  },

  async onRefreshSession() {
    this.setData({ busy: true });
    this.appendLog('→ 手动续期 refreshToken');
    try {
      await api.refreshSession();
      this.appendLog('✓ 续期成功，accessToken 与 refreshToken 都已更新');
      this.setData({ hasRefreshToken: !!((store.getSession() || {}).refreshToken) });
    } catch (e) {
      this.appendLog(`✗ 续期失败：${e.message}`);
    } finally {
      this.setData({ busy: false });
    }
  },

  onCoordChange(e) {
    const v = e.currentTarget.dataset.v;
    store.setCoordSystem(v);
    this.setData({ coordSystem: v });
  },

  /* ---------------- 信号浏览 ---------------- */

  async onToggleSignals() {
    if (this.data.showSignals) {
      this.setData({ showSignals: false });
      return;
    }
    this.setData({ busy: true });
    try {
      const v = store.getVehicle();
      const res = await api.status(v.vin);
      const map = (res && res.data && res.data.signalMap) || {};
      const groups = signals.group(map);
      const unknown = signals.unknownIds(map);
      this.setData({
        showSignals: true,
        signalGroups: groups,
        unknownIds: unknown.length ? unknown.join(', ') : '（无）',
      });
    } catch (e) {
      this.appendLog(`✗ 拉取车况失败：${e.message}`);
    } finally {
      this.setData({ busy: false });
    }
  },

  /* ---------------- 诊断：未验证 payload ---------------- */

  async onUnverified(e) {
    const idx = Number(e.currentTarget.dataset.idx);
    const item = this.data.unverified[idx];
    if (!item) return;
    const v = store.getVehicle();
    if (!v || !v.vin) {
      wx.showToast({ title: '还没有车辆', icon: 'none' });
      return;
    }
    const ok = await ctl.confirmPhysical(`诊断：向 cmdid ${item.cmdid} 下发\n${JSON.stringify(item.state)}`);
    if (!ok) return;
    this.appendLog(`→ 诊断下发 cmdid ${item.cmdid} state=${JSON.stringify(item.state)}`);
    try {
      const r = await api.control({
        vin: v.vin,
        cmdid: item.cmdid,
        state: item.state,
        label: `诊断 ${item.cmdid}`,
        opPassword: await ctl.ensureOpPassword(),
      });
      this.appendLog(`✓ 已下发，msgId=${r.msgId || '(无)'}`);
      if (r.msgId) {
        const q = await api.controlAndWait({
          vin: v.vin,
          cmdid: item.cmdid,
          state: item.state,
          opPassword: await ctl.ensureOpPassword(),
        });
        this.appendLog(q.ok ? '✓ 车端确认执行成功' : '⚠ 没等到确认');
      }
    } catch (err) {
      this.appendLog(`✗ ${err.message}`);
    }
  },

  /* ---------------- 诊断：cmdid 161 只读探测 ---------------- */

  async onProbeAppointment() {
    const v = store.getVehicle();
    if (!v || !v.vin) return;
    this.appendLog('→ 只读探测 getappointment（cmdid 161）');
    try {
      const r = await api.appointment(v.vin, 161);
      this.appendLog(`✓ ${fmt.pretty(r, 600)}`);
    } catch (e) {
      this.appendLog(`✗ ${e.message}`);
    }
  },

  /* ---------------- 会话 ---------------- */

  onLogout() {
    wx.showModal({
      title: '退出登录',
      content: '会清除本地保存的会话（accessToken / refreshToken / 操作密码）。确定吗？',
      confirmText: '退出',
      confirmColor: '#FF6B6B',
      success: (r) => {
        if (!r.confirm) return;
        api.logout();
        wx.reLaunch({ url: '/pages/login/login' });
      },
    });
  },

  clearLog() {
    this.setData({ log: '' });
  },
});
