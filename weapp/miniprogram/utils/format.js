/** 格式化工具（纯函数，无副作用） */

function pad2(n) {
  return n < 10 ? `0${n}` : String(n);
}

/** 数值格式化；null/undefined → '--' */
function num(v, digits) {
  if (v === null || v === undefined || v === '') return '--';
  const n = Number(v);
  if (!Number.isFinite(n)) return '--';
  const d = digits === undefined ? 1 : digits;
  return n.toFixed(d);
}

/** 整数显示 */
function int(v) {
  if (v === null || v === undefined || v === '') return '--';
  const n = Number(v);
  if (!Number.isFinite(n)) return '--';
  return String(Math.round(n));
}

/** 带单位的数值，值缺失时显示 '--'（不带单位） */
function withUnit(v, unit, digits) {
  if (v === null || v === undefined || v === '') return '--';
  return `${num(v, digits)}${unit || ''}`;
}

/** 毫秒时间戳 → 'MM-dd HH:mm' */
function clock(ts) {
  if (!ts) return '--';
  const d = new Date(Number(ts));
  if (Number.isNaN(d.getTime())) return '--';
  return `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** 毫秒时间戳 → 'HH:mm:ss' */
function hms(ts) {
  const d = new Date(Number(ts) || Date.now());
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

/** 距今多久：'刚刚' / 'N 分钟前' / 'N 小时前' / 'N 天前' */
function ago(ts) {
  if (!ts) return '--';
  const diff = Date.now() - Number(ts);
  if (!Number.isFinite(diff)) return '--';
  if (diff < 0) return '刚刚';
  const min = Math.floor(diff / 60000);
  if (min < 1) return '刚刚';
  if (min < 60) return `${min} 分钟前`;
  const h = Math.floor(min / 60);
  if (h < 24) return `${h} 小时前`;
  const d = Math.floor(h / 24);
  return `${d} 天前`;
}

/** 毫秒时长 → 'N 小时 M 分' / 'M 分钟' */
function duration(ms) {
  if (ms === null || ms === undefined || !Number.isFinite(Number(ms))) return '--';
  const total = Math.max(0, Math.floor(Number(ms) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  if (h > 0) return `${h} 小时 ${m} 分`;
  if (m > 0) return `${m} 分钟`;
  return '不到 1 分钟';
}

/** 分钟数 → '约 N 小时 M 分' */
function minutes(min) {
  if (min === null || min === undefined) return '--';
  const n = Number(min);
  if (!Number.isFinite(n)) return '--';
  const h = Math.floor(n / 60);
  const m = Math.round(n % 60);
  if (h > 0) return `约 ${h} 小时 ${m} 分`;
  return `约 ${m} 分钟`;
}

/** 两点球面距离（km），Haversine */
function distanceKm(lat1, lng1, lat2, lng2) {
  const vals = [lat1, lng1, lat2, lng2].map(Number);
  if (vals.some((v) => !Number.isFinite(v))) return null;
  const R = 6371;
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(lat2 - lat1);
  const dLng = rad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
  return 2 * R * Math.asin(Math.sqrt(a));
}

/** 距离文案 */
function distanceText(km) {
  if (km === null || !Number.isFinite(km)) return '--';
  if (km < 1) return `${Math.round(km * 1000)} m`;
  if (km < 10) return `${km.toFixed(2)} km`;
  return `${km.toFixed(1)} km`;
}

/** 安全 JSON 字符串化（日志用） */
function pretty(obj, maxLen) {
  let s;
  try {
    s = JSON.stringify(obj, null, 2);
  } catch (e) {
    s = String(obj);
  }
  const limit = maxLen || 2000;
  if (s && s.length > limit) return `${s.slice(0, limit)}\n…（已截断，共 ${s.length} 字符）`;
  return s;
}

module.exports = {
  pad2,
  num,
  int,
  withUnit,
  clock,
  hms,
  ago,
  duration,
  minutes,
  distanceKm,
  distanceText,
  pretty,
};
