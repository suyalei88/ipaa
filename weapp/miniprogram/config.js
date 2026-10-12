/**
 * 小程序运行时配置 —— 改这里就够了，别去翻别的文件。
 */
module.exports = {
  /**
   * 云开发环境 ID。
   *
   * 留空 = 用「当前默认环境」（`wx.cloud.DYNAMIC_CURRENT_ENV`）。
   * 只有一个环境时留空最省事；如果你建了多个环境（比如 dev/prod），
   * 就把环境 ID 填进来，形如 'leapmotor-3g9xxxxxxxxxxxx'。
   */
  cloudEnv: '',

  /** 云函数名（要和 cloudfunctions/ 下的目录名一致） */
  cloudFunctionName: 'lmProxy',

  /**
   * 车辆坐标的坐标系。
   *
   * ⚠️ 零跑下发的 2190/2191 **没有证据**能确定是 WGS-84 还是 GCJ-02。
   *    官方 App 两个方向的换算都实现了，地图用的是高德（GCJ-02）。
   *    默认按 'gcj02' 显示（和官方一致）；如果发现地图上偏了 500 多米，
   *    在「设置 → 坐标系」里切成 'wgs84' 试试。
   */
  coordSystem: 'gcj02',
};
