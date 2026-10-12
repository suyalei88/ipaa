const api = require('../../utils/api.js');
const store = require('../../utils/store.js');

Page({
  data: {
    phone: '',
    code: '',
    sending: false,
    countdown: 0,
    logging: false,
    log: '',
  },

  onLoad() {
    // 已登录直接进爱车页（reLaunch 才能跳到 tabBar 页面）
    if (store.isLoggedIn()) {
      wx.reLaunch({ url: '/pages/home/home' });
    }
  },

  onUnload() {
    if (this._timer) clearInterval(this._timer);
  },

  appendLog(line) {
    const t = new Date();
    const p = (n) => (n < 10 ? `0${n}` : String(n));
    const stamp = `${p(t.getHours())}:${p(t.getMinutes())}:${p(t.getSeconds())}`;
    this.setData({ log: `[${stamp}] ${line}\n${this.data.log}`.slice(0, 4000) });
  },

  onPhone(e) {
    this.setData({ phone: e.detail.value });
  },

  onCode(e) {
    this.setData({ code: e.detail.value });
  },

  startCountdown() {
    this.setData({ countdown: 60 });
    if (this._timer) clearInterval(this._timer);
    this._timer = setInterval(() => {
      const n = this.data.countdown - 1;
      if (n <= 0) {
        clearInterval(this._timer);
        this._timer = null;
        this.setData({ countdown: 0 });
      } else {
        this.setData({ countdown: n });
      }
    }, 1000);
  },

  async onSend() {
    const phone = String(this.data.phone || '').trim();
    if (!/^1\d{10}$/.test(phone)) {
      wx.showToast({ title: '手机号格式不对', icon: 'none' });
      return;
    }
    this.setData({ sending: true });
    this.appendLog(`→ 发送验证码到 ${phone.slice(0, 3)}****${phone.slice(7)}`);
    try {
      const r = await api.sendSms(phone);
      this.appendLog(`✓ ${(r && r.message) || '验证码已发送'}`);
      wx.showToast({ title: '验证码已发送', icon: 'none' });
      this.startCountdown();
    } catch (e) {
      this.appendLog(`✗ ${e.message}`);
      wx.showToast({ title: e.message, icon: 'none' });
    } finally {
      this.setData({ sending: false });
    }
  },

  async onLogin() {
    const phone = String(this.data.phone || '').trim();
    const code = String(this.data.code || '').trim();
    if (!/^1\d{10}$/.test(phone)) {
      wx.showToast({ title: '手机号格式不对', icon: 'none' });
      return;
    }
    if (!code) {
      wx.showToast({ title: '请填验证码', icon: 'none' });
      return;
    }
    this.setData({ logging: true });
    this.appendLog('→ 用验证码登录（换外层 token → 换 JWT）');
    try {
      const session = await api.login(phone, code);
      this.appendLog(`✓ 登录成功，accountId=${session.accountId || '?'}`);
      this.appendLog(`  signKey=${String(session.signKeyHex).slice(0, 16)}…`);
      wx.reLaunch({ url: '/pages/home/home' });
    } catch (e) {
      this.appendLog(`✗ ${e.message}`);
      wx.showToast({ title: e.message, icon: 'none' });
    } finally {
      this.setData({ logging: false });
    }
  },
});
