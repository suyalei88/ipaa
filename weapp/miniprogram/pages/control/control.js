const api = require('../../utils/api.js');
const store = require('../../utils/store.js');
const ctl = require('../../utils/control.js');

const app = getApp();

/** 物理动作给红色边框，视觉上和「只改状态」的动作区分开 */
const RISK_CLASS = { physical: 'btn-danger', low: '' };

Page({
  data: {
    vin: '',
    sections: [],
    log: '',
    error: '',
    busy: false,
  },

  onShow() {
    if (!store.isLoggedIn()) {
      wx.reLaunch({ url: '/pages/login/login' });
      return;
    }
    const v = store.getVehicle();
    this.setData({ vin: (v && v.vin) || '' });
    this.loadMeta();
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
      const commands = meta.commands || {};
      const sections = (meta.groups || []).map((g) => ({
        key: g.key,
        name: g.name,
        items: (g.actions || []).map((key) => {
          const def = commands[key] || {};
          return {
            key,
            label: def.title || key,
            cmdid: def.cmdid,
            risk: def.risk || 'low',
            cls: RISK_CLASS[def.risk] || '',
          };
        }),
      }));
      this.setData({ sections, error: '' });
    } catch (e) {
      this.setData({ error: `拉取命令表失败：${e.message}` });
    }
  },

  async onTap(e) {
    if (this.data.busy) return;
    const key = e.currentTarget.dataset.key;
    const v = store.getVehicle();
    if (!v || !v.vin) {
      wx.showToast({ title: '还没有车辆', icon: 'none' });
      return;
    }
    let item = null;
    this.data.sections.forEach((s) => {
      s.items.forEach((it) => { if (it.key === key) item = it; });
    });
    if (!item) return;

    this.setData({ busy: true });
    this.appendLog(`→ ${item.label}（cmdid ${item.cmdid}）`);
    const r = await ctl.run({
      vin: v.vin,
      name: key,
      label: item.label,
      risk: item.risk,
    });
    if (r && r.cancelled) this.appendLog('  已取消');
    else if (r && r.ok) this.appendLog(`✓ ${item.label} 成功（${r.samples} 次轮询）`);
    else if (r && r.timedOut) this.appendLog('⚠ 已下发，但 22 秒内没等到确认');
    else this.appendLog(`✗ ${(r && r.error) || '失败'}`);
    this.setData({ busy: false });
  },

  clearLog() {
    this.setData({ log: '' });
  },
});
