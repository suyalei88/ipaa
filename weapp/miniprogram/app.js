const cfg = require('./config.js');

App({
  globalData: {
    /** 云函数返回的命令表 / 分组（启动时拉一次，避免两边各写一份） */
    meta: null,
  },

  onLaunch() {
    if (!wx.cloud) {
      wx.showModal({
        title: '基础库版本过低',
        content: '云开发需要微信基础库 2.2.3 以上，请升级微信后重试。',
        showCancel: false,
      });
      return;
    }
    wx.cloud.init({
      env: cfg.cloudEnv || wx.cloud.DYNAMIC_CURRENT_ENV,
      traceUser: true,
    });
  },
});
