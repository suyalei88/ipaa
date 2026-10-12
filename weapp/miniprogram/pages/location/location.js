const api = require('../../utils/api.js');
const store = require('../../utils/store.js');
const signals = require('../../utils/signals.js');
const fmt = require('../../utils/format.js');
const coord = require('../../utils/coord.js');

Page({
  data: {
    rawLat: null,
    rawLng: null,
    mode: 'gcj02',        // 'gcj02' = 直接用；'wgs84' = 先做 WGS→GCJ 换算
    dispLat: null,
    dispLng: null,
    markers: [],
    address: '',
    addressLoading: false,
    distanceText: '',
    unchangedText: '',
    collectedText: '',
    error: '',
    loading: false,
  },

  onShow() {
    if (!store.isLoggedIn()) {
      wx.reLaunch({ url: '/pages/login/login' });
      return;
    }
    this.setData({ mode: store.getCoordSystem('gcj02') });
    this.refresh();
  },

  onPullDownRefresh() {
    this.refresh().finally(() => wx.stopPullDownRefresh());
  },

  async refresh() {
    if (this.data.loading) return;
    this.setData({ loading: true, error: '' });
    try {
      const v = store.getVehicle();
      if (!v || !v.vin) throw new Error('还没有选择车辆');
      const res = await api.status(v.vin);
      const map = (res && res.data && res.data.signalMap) || {};
      const d = signals.derive(map);

      const lat = d.lat !== null ? d.lat : d.latHi;
      const lng = d.lng !== null ? d.lng : d.lngHi;
      if (lat === null || lng === null) throw new Error('车端没上报坐标（2190/2191 都读不到）');

      const unchanged = store.noteCoordinate(lat, lng);
      this.setData({
        rawLat: lat,
        rawLng: lng,
        collectedText: d.collectedAt ? fmt.ago(d.collectedAt) : '--',
        unchangedText: (unchanged === null || unchanged === undefined)
          ? '这是第一次记录这个坐标'
          : `${fmt.clock(Date.now() - unchanged)} 起没变过（${fmt.duration(unchanged)}）`,
      });
      this.applyMode(lat, lng, this.data.mode);
    } catch (e) {
      this.setData({ error: e.message || String(e) });
    } finally {
      this.setData({ loading: false });
    }
  },

  /** 按当前假设算出用于显示的坐标 */
  applyMode(lat, lng, mode) {
    const disp = mode === 'wgs84' ? coord.wgs84ToGcj02(lat, lng) : { lat, lng };
    this.setData({
      mode,
      dispLat: disp.lat,
      dispLng: disp.lng,
      markers: [{
        id: 1,
        latitude: disp.lat,
        longitude: disp.lng,
        width: 30,
        height: 30,
        callout: { content: '车辆位置', display: 'ALWAYS', padding: 6, borderRadius: 6, fontSize: 12 },
      }],
      distanceText: '',
    });
  },

  onModeChange(e) {
    const mode = e.currentTarget.dataset.mode;
    store.setCoordSystem(mode);
    this.applyMode(this.data.rawLat, this.data.rawLng, mode);
  },

  /** 用官方逆地理编码反查地址（探测性 —— 这个端点在 IPA 里有路径但没有抓包样本） */
  async onRegeo() {
    if (this.data.dispLat === null) return;
    this.setData({ addressLoading: true });
    try {
      const r = await api.regeo(this.data.dispLat, this.data.dispLng);
      const text = r && r.text ? r.text : fmt.pretty(r, 800);
      this.setData({ address: text });
    } catch (e) {
      this.setData({ address: `✗ ${e.message}` });
    } finally {
      this.setData({ addressLoading: false });
    }
  },

  /** 打开系统地图（可在里面导航） */
  onOpenMap() {
    if (this.data.dispLat === null) return;
    wx.openLocation({
      latitude: this.data.dispLat,
      longitude: this.data.dispLng,
      name: '车辆位置',
      address: '',
      scale: 17,
      fail: (e) => wx.showToast({ title: '打开地图失败', icon: 'none' }),
    });
  },

  /** 算「距我多远」—— 需要定位授权，失败就安静跳过 */
  onDistance() {
    if (this.data.dispLat === null) return;
    wx.getLocation({
      type: 'gcj02',
      success: (loc) => {
        const km = fmt.distanceKm(loc.latitude, loc.longitude, this.data.dispLat, this.data.dispLng);
        this.setData({ distanceText: fmt.distanceText(km) });
      },
      fail: () => {
        wx.showToast({ title: '拿不到手机定位（未授权或未配置）', icon: 'none' });
      },
    });
  },

  copyCoord() {
    if (this.data.dispLat === null) return;
    const s = `${this.data.dispLat},${this.data.dispLng}`;
    wx.setClipboardData({
      data: s,
      success: () => wx.showToast({ title: '已复制坐标', icon: 'none' }),
    });
  },
});
