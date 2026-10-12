/**
 * 本地存储封装。
 *
 * ⚠️ 关于「明文存操作密码」：
 *    零跑的车控操作密码是 6 位数字，服务端要的是用 accessToken 派生的 oppwd 密文，
 *    而 oppwd **每个会话都不一样**（key/iv 来自 accessToken 的前 64 个字符），
 *    所以没法只存密文。iOS 版同样把明文存本地（UserDefaults）。
 *    小程序的 wx.setStorageSync 存在应用沙箱里，不上云、别的 App 读不到。
 *    如果你介意，可以在设置页里关掉「记住操作密码」，每次车控手输。
 */

const KEY_SESSION = 'lm.session';
const KEY_VEHICLE = 'lm.vehicle';
const KEY_OP_PWD = 'lm.opPassword';
const KEY_REMEMBER = 'lm.rememberOpPwd';
const KEY_DEVICE = 'lm.deviceId';
const KEY_COORD = 'lm.coordSystem';
const KEY_LAST_COORD = 'lm.lastCoord';
const KEY_LAST_COORD_AT = 'lm.lastCoordAt';

function get(key, dflt) {
  try {
    const v = wx.getStorageSync(key);
    if (v === '' || v === undefined || v === null) return dflt;
    return v;
  } catch (e) {
    return dflt;
  }
}

function set(key, val) {
  try {
    wx.setStorageSync(key, val);
  } catch (e) {
    /* 存储失败不该让业务挂掉 */
  }
}

function remove(key) {
  try {
    wx.removeStorageSync(key);
  } catch (e) { /* ignore */ }
}

/* ---------------- 会话 ---------------- */

function getSession() {
  return get(KEY_SESSION, null);
}

function setSession(s) {
  set(KEY_SESSION, s);
}

function isLoggedIn() {
  const s = getSession();
  return !!(s && s.accessToken && s.signKeyHex);
}

function clearSession() {
  remove(KEY_SESSION);
}

/* ---------------- 车辆 ---------------- */

function getVehicle() {
  return get(KEY_VEHICLE, null);
}

function setVehicle(v) {
  set(KEY_VEHICLE, v);
}

/* ---------------- 操作密码 ---------------- */

function getOpPassword() {
  return get(KEY_OP_PWD, '');
}

function setOpPassword(p) {
  if (p) set(KEY_OP_PWD, p);
  else remove(KEY_OP_PWD);
}

function getRememberOpPwd() {
  return get(KEY_REMEMBER, true);
}

function setRememberOpPwd(v) {
  set(KEY_REMEMBER, !!v);
  if (!v) remove(KEY_OP_PWD);
}

/* ---------------- 设备标识 ---------------- */

/**
 * 稳定的 deviceId —— 首次生成后**永远复用**。
 *
 * ⚠️ 不能每次启动都随机生成：部分接口（如健康充电推送状态）是按
 *    `carvin + deviceId` 查「**这台设备**」的状态的。deviceId 每次变，
 *    服务端就把本机当成新设备，凡是有设备维度的状态一律回默认值。
 *    默认取官方抓包里的那个（服务端认过），避免新设备读不到真实状态。
 */
function getDeviceId() {
  const saved = get(KEY_DEVICE, '');
  if (saved && saved.indexOf('ios_') === 0 && saved.length > 8) return saved;
  const fallback = 'ios_ee45b9d830bb126d431e998943a7797a';
  set(KEY_DEVICE, fallback);
  return fallback;
}

/* ---------------- 坐标系 ---------------- */

function getCoordSystem(dflt) {
  return get(KEY_COORD, dflt || 'gcj02');
}

function setCoordSystem(v) {
  set(KEY_COORD, v);
}

/* ---------------- 坐标新鲜度追踪 ---------------- */

/**
 * 记录「坐标值最后一次变化」的时刻。
 *
 * ⚠️ 为什么需要这个：2190/2191 **不是实时 GPS**，而是车机存下来的一份位置。
 *    车停着时它本来就不该变，所以「定位新不新」**不能**看整包车况的采集时间
 *    （那个永远是「刚刚」），要看**这个坐标值本身多久没变过**。
 */
function noteCoordinate(lat, lng) {
  if (lat === null || lng === null || lat === undefined || lng === undefined) return null;
  const cur = `${Number(lat).toFixed(6)},${Number(lng).toFixed(6)}`;
  const last = get(KEY_LAST_COORD, '');
  if (cur !== last) {
    set(KEY_LAST_COORD, cur);
    set(KEY_LAST_COORD_AT, Date.now());
    return 0;
  }
  return Date.now() - get(KEY_LAST_COORD_AT, Date.now());
}

/** 坐标已经多久没变了（毫秒）；没有记录时返回 null */
function coordinateUnchangedFor() {
  if (!get(KEY_LAST_COORD, '')) return null;
  return Date.now() - get(KEY_LAST_COORD_AT, Date.now());
}

module.exports = {
  get,
  set,
  remove,
  getSession,
  setSession,
  isLoggedIn,
  clearSession,
  getVehicle,
  setVehicle,
  getOpPassword,
  setOpPassword,
  getRememberOpPwd,
  setRememberOpPwd,
  getDeviceId,
  getCoordSystem,
  setCoordSystem,
  noteCoordinate,
  coordinateUnchangedFor,
};
