/**
 * 坐标系转换（WGS-84 ↔ GCJ-02，即「火星坐标」）。
 *
 * ⚠️ 为什么需要这个：
 *   零跑下发的 2190/2191 **没有证据**能确定属于哪个坐标系 ——
 *   官方 App 里两个方向的换算都实现了（`wgs84ToGcj02:` / `gcj02ToWgs84:`），
 *   而它用的地图是高德（GCJ-02）。
 *   合肥实测点按 WGS→GCJ 换算偏移约 574 米 —— 正是「偏到隔壁小区」的量级。
 *   所以别猜：在「设置 → 坐标系」里三选一，站到车旁一眼就能定下来。
 *
 * 算法就是业界通用的 GCJ-02 偏移公式（高德/腾讯地图 SDK 内部同款）。
 * 只在中国大陆范围内生效；境外原样返回。
 */

const PI = Math.PI;
const A = 6378245.0;              // GCJ 长半轴
const EE = 0.00669342162296594323; // GCJ 偏心率平方

function outOfChina(lat, lng) {
  return !(lng > 73.66 && lng < 135.05 && lat > 3.86 && lat < 53.55);
}

function transformLat(x, y) {
  let ret =
    -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
  ret += ((20.0 * Math.sin(6.0 * x * PI) + 20.0 * Math.sin(2.0 * x * PI)) * 2.0) / 3.0;
  ret += ((20.0 * Math.sin(y * PI) + 40.0 * Math.sin((y / 3.0) * PI)) * 2.0) / 3.0;
  ret += ((160.0 * Math.sin((y / 12.0) * PI) + 320 * Math.sin((y * PI) / 30.0)) * 2.0) / 3.0;
  return ret;
}

function transformLng(x, y) {
  let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
  ret += ((20.0 * Math.sin(6.0 * x * PI) + 20.0 * Math.sin(2.0 * x * PI)) * 2.0) / 3.0;
  ret += ((20.0 * Math.sin(x * PI) + 40.0 * Math.sin((x / 3.0) * PI)) * 2.0) / 3.0;
  ret += ((150.0 * Math.sin((x / 12.0) * PI) + 300.0 * Math.sin((x / 30.0) * PI)) * 2.0) / 3.0;
  return ret;
}

/** WGS-84 → GCJ-02 */
function wgs84ToGcj02(lat, lng) {
  const la = Number(lat);
  const ln = Number(lng);
  if (!Number.isFinite(la) || !Number.isFinite(ln)) return { lat: la, lng: ln };
  if (outOfChina(la, ln)) return { lat: la, lng: ln };
  let dLat = transformLat(ln - 105.0, la - 35.0);
  let dLng = transformLng(ln - 105.0, la - 35.0);
  const radLat = (la / 180.0) * PI;
  let magic = Math.sin(radLat);
  magic = 1 - EE * magic * magic;
  const sqrtMagic = Math.sqrt(magic);
  dLat = (dLat * 180.0) / (((A * (1 - EE)) / (magic * sqrtMagic)) * PI);
  dLng = (dLng * 180.0) / ((A / sqrtMagic) * Math.cos(radLat) * PI);
  return { lat: la + dLat, lng: ln + dLng };
}

/** GCJ-02 → WGS-84（用一次正向偏移迭代逼近，误差 < 1e-6 度） */
function gcj02ToWgs84(lat, lng) {
  const la = Number(lat);
  const ln = Number(lng);
  if (!Number.isFinite(la) || !Number.isFinite(ln)) return { lat: la, lng: ln };
  if (outOfChina(la, ln)) return { lat: la, lng: ln };
  const g = wgs84ToGcj02(la, ln);
  return { lat: la * 2 - g.lat, lng: ln * 2 - g.lng };
}

/**
 * 把「车端下发的坐标」转成「目标坐标系」。
 *
 * @param {number} lat 原始纬度
 * @param {number} lng 原始经度
 * @param {'wgs84'|'gcj02'} source 原始坐标系
 * @param {'wgs84'|'gcj02'} target 目标坐标系
 */
function convert(lat, lng, source, target) {
  if (source === target) return { lat, lng };
  if (source === 'wgs84' && target === 'gcj02') return wgs84ToGcj02(lat, lng);
  if (source === 'gcj02' && target === 'wgs84') return gcj02ToWgs84(lat, lng);
  return { lat, lng };
}

module.exports = {
  outOfChina,
  wgs84ToGcj02,
  gcj02ToWgs84,
  convert,
};
