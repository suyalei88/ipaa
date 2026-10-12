const api = require('../../utils/api.js');
const store = require('../../utils/store.js');
const signals = require('../../utils/signals.js');
const fmt = require('../../utils/format.js');
const ctl = require('../../utils/control.js');

const app = getApp();

Page({
  data: {
    vehicle: null,
    vinText: '',
    d: null,
    tiles: [],
    ringStyle: '',
    socText: '--',
    rangeText: '--',
    lockText: '锁态未知',
    lockClass: 'dim',
    chargeText: '待确认',
    chargeClass: 'dim',
    collectedAgo: '--',
    coordNote: '',
    loading: false,
    error: '',
    quick: [],
  },

  onShow() {
    if (!store.isLoggedIn()) {
      wx.reLaunch({ url: '/pages/login/login' });
      return;
    }
    this.setData({ vehicle: store.getVehicle(), vinText: (store.getVehicle() || {}).vin || '' });
    this.loadMeta().then(() => this.refresh());
  },

  onPullDownRefresh() {
    this.refresh().finally(() => wx.stopPullDownRefresh());
  },

  /** 命令表由云函数下发，避免两边各写一份导致漂移 */
  async loadMeta() {
    if (app.globalData.meta) {
      this.applyMeta(app.globalData.meta);
      return;
    }
    try {
      const meta = await api.getMeta();
      app.globalData.meta = meta;
      this.applyMeta(meta);
    } catch (e) {
      // 拿不到 meta 不该挡住车况刷新；车控页会再试一次
    }
  },

  applyMeta(meta) {
    const quick = (meta.quickActions || []).map((key) => {
      const def = (meta.commands || {})[key] || {};
      return { key, label: def.title || key, cmdid: def.cmdid, risk: def.risk || 'low' };
    });
    this.setData({ quick });
  },

  async ensureVehicle() {
    let v = store.getVehicle();
    if (v && v.vin) return v;
    const res = await api.vehicles();
    const data = (res && res.data) || {};
    const list = [].concat(data.bindcars || [], data.sharedcars || []);
    if (!list.length) throw new Error('这个账号下没有车辆');
    v = list[0];
    store.setVehicle(v);
    this.setData({ vehicle: v, vinText: v.vin });
    return v;
  },

  async refresh() {
    if (this.data.loading) return;
    this.setData({ loading: true, error: '' });
    try {
      const v = await this.ensureVehicle();
      const res = await api.status(v.vin);
      const map = (res && res.data && res.data.signalMap) || {};
      this.render(map);
      try {
        await api.mileage(v.vin);
      } catch (e) {
        // 里程接口挂了不影响主流程
      }
    } catch (e) {
      this.setData({ error: e.message || String(e) });
    } finally {
      this.setData({ loading: false });
    }
  },

  render(map) {
    const d = signals.derive(map);

    // 记录「坐标值本身多久没变」——而不是整包车况的采集时间（那个永远是「刚刚」）
    const lat = d.lat !== null ? d.lat : d.latHi;
    const lng = d.lng !== null ? d.lng : d.lngHi;
    const unchanged = store.noteCoordinate(lat, lng);

    const soc = d.soc !== null ? d.soc : d.socInt;
    const deg = soc === null ? 0 : Math.max(0, Math.min(100, soc)) * 3.6;
    const ringStyle = soc === null
      ? 'background:#1E252F'
      : `background:conic-gradient(#3DF5C8 0deg, #3DF5C8 ${deg}deg, #1E252F ${deg}deg, #1E252F 360deg)`;

    let lockText = '锁态未知';
    let lockClass = 'dim';
    if (d.locked === true) { lockText = '已上锁'; lockClass = 'good'; }
    else if (d.locked === false) { lockText = '未上锁'; lockClass = 'warn'; }

    let chargeText = '待确认';
    let chargeClass = 'dim';
    if (d.chargeState === 'charging') { chargeText = '充电中'; chargeClass = 'good'; }
    else if (d.chargeState === 'idle') {
      chargeText = d.hvActive ? '未充电（高压已激活）' : '未充电';
      chargeClass = 'dim';
    }

    const tiles = [
      { label: '车内温度', value: fmt.withUnit(d.cabinTemp, ' ℃'), cls: '' },
      { label: '电池温度', value: fmt.withUnit(d.battTemp, ' ℃'), cls: '' },
      { label: '总里程', value: d.odometer === null ? '--' : `${fmt.int(d.odometer)} km`, cls: '' },
      { label: '续航（标准B）', value: d.rangeB === null ? '--' : `${fmt.int(d.rangeB)} km`, cls: '' },
      { label: '充电电流', value: fmt.withUnit(d.chargeCurrent, ' A', 2), cls: d.chargeState === 'charging' ? 'good' : '' },
      { label: '电池包电压', value: fmt.withUnit(d.chargeVoltage, ' V'), cls: '' },
      { label: '充电功率', value: d.chargePowerKW === null ? '--' : `${fmt.num(d.chargePowerKW, 2)} kW`, cls: d.chargeState === 'charging' ? 'good' : '' },
      { label: '后备箱', value: d.trunkOpen === null ? '未知' : (d.trunkOpen ? '已打开' : '已关闭'), cls: d.trunkOpen ? 'warn' : '' },
      { label: '车窗', value: d.windowSummary || '未知', cls: d.windowSummary && d.windowSummary !== '关闭' ? 'warn' : '' },
      { label: '空调', value: d.acOn === null ? '未知' : (d.acOn ? '已开启' : '已关闭'), cls: d.acOn ? 'good' : '' },
    ];

    this.setData({
      d,
      tiles,
      socText: soc === null ? '--' : fmt.num(soc, 1),
      rangeText: d.rangeA !== null ? fmt.int(d.rangeA) : (d.rangeB !== null ? fmt.int(d.rangeB) : '--'),
      ringStyle,
      lockText,
      lockClass,
      chargeText,
      chargeClass,
      collectedAgo: d.collectedAt ? fmt.ago(d.collectedAt) : '--',
      coordNote: (unchanged === null || unchanged === undefined)
        ? ''
        : `坐标未变化：${fmt.clock(Date.now() - unchanged)} 起（${fmt.duration(unchanged)}）`,
    });
  },

  async onQuick(e) {
    const key = e.currentTarget.dataset.key;
    const v = this.data.vehicle;
    if (!v || !v.vin) {
      wx.showToast({ title: '还没有车辆', icon: 'none' });
      return;
    }
    const item = this.data.quick.find((q) => q.key === key) || {};
    await ctl.run({
      vin: v.vin,
      name: key,
      label: item.label || key,
      risk: item.risk || 'low',
    });
    setTimeout(() => this.refresh(), 2000);
  },

  goControl() {
    wx.switchTab({ url: '/pages/control/control' });
  },

  goLocation() {
    wx.switchTab({ url: '/pages/location/location' });
  },
});
