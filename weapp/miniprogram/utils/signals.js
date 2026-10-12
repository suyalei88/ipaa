/**
 * signalMap 的 id → 语义 知识库 + 派生值。
 *
 * ★ 这里每一条都必须有证据（抓包双向验证 / 与用户截图逐字对上），
 *   禁止「看着像就写」。与 ios/.../API/LMSignalCatalog.swift 同源。
 *
 * 证据等级：
 *   confirmed —— 多快照线性回归 / 官方接口交叉印证 / 与截图逐字对上
 *   observed  —— 抓包里有稳定值且量纲自洽，但只有一份证据
 *   unknown   —— 只知道「这个 id 存在、会变」，语义未定
 */

const CONF = { CONFIRMED: 'confirmed', OBSERVED: 'observed', UNKNOWN: 'unknown' };

const CATEGORIES = {
  battery: '电池 / 充电',
  range: '续航',
  location: '定位',
  body: '车身状态',
  climate: '温度 / 空调',
  meta: '时间 / 元数据',
};

/**
 * 已确认 / 已观察的信号。
 * note 里保留「为什么这么认定」，方便以后复查 —— 别删。
 */
const CATALOG = {
  // ---- 电池 / 充电 ----
  '100003': { name: '电池 SOC', unit: '%', cat: 'battery', conf: CONF.CONFIRMED, note: 'BMS 上报，带 1 位小数，最准。首页主用这个。' },
  '1204': { name: '电池 SOC（取整）', unit: '%', cat: 'battery', conf: CONF.CONFIRMED, note: '逐帧等于 round(100003)。' },
  '1200': { name: '预计充至目标电量时间', unit: 'min', cat: 'battery', conf: CONF.CONFIRMED, note: '≈ round(11.33 × (目标电量 − SOC))。★ 是纯 SOC 投影，与是否在充电无关，不能当充电状态位。' },
  '2183': { name: '电池温度', unit: '℃', cat: 'battery', conf: CONF.OBSERVED, note: '实测恒为 23.0。' },
  '1177': { name: '电池包电压', unit: 'V', cat: 'battery', conf: CONF.OBSERVED, note: '随 SOC 单调抬升：33.0%→736.7 / 41.4%→732.7 / 82.9%→827.0，所以是电池包电压而非充电机输出。' },
  '1178': { name: '充电电流', unit: 'A', cat: 'battery', conf: CONF.CONFIRMED, note: '★ 唯一带物理意义的充电证据，也是充电判据的唯一依据。熄火 0.0 / 通电 0.2~0.3 / 真充电 −8.3。' },

  // ---- 高压系统激活标志位（★ 不是「充电中」）----
  '100004': { name: '高压系统激活位', unit: '', cat: 'battery', conf: CONF.OBSERVED, note: '充电 / 车辆通电 / 哨兵模式下都是 1，熄火停放时 0。不代表在充电。' },
  '1149': { name: '高压系统激活位 1149', unit: '', cat: 'battery', conf: CONF.OBSERVED, note: '与 100004 同步翻转。' },
  '1257': { name: '高压系统激活位 1257', unit: '', cat: 'battery', conf: CONF.OBSERVED, note: '与 100004 同步翻转。' },
  '3636': { name: '高压系统激活位 3636', unit: '', cat: 'battery', conf: CONF.OBSERVED, note: '与 100004 同步翻转。' },
  '3722': { name: '高压系统激活位 3722', unit: '', cat: 'battery', conf: CONF.OBSERVED, note: '与 100004 同步翻转。' },

  // ---- 续航 ----
  '3257': { name: '剩余续航（标准 A）', unit: 'km', cat: 'range', conf: CONF.CONFIRMED, note: '3257/100003 = 7.17 严格线性 → 满电约 717 km。首页主显示。' },
  '3260': { name: '剩余续航（标准 B）', unit: 'km', cat: 'range', conf: CONF.CONFIRMED, note: '满电约 577 km，另一套工况标准。' },
  '2188': { name: '剩余续航（冗余副本）', unit: 'km', cat: 'range', conf: CONF.CONFIRMED, note: '逐帧等于 3260。' },

  // ---- 定位（★ 非实时）----
  '2190': { name: '纬度', unit: '°', cat: 'location', conf: CONF.CONFIRMED, note: '★ 非实时：车机存下来的一份位置，可长时间完全不变。' },
  '2191': { name: '经度', unit: '°', cat: 'location', conf: CONF.CONFIRMED, note: '★ 非实时，同 2190。' },
  '3725': { name: '纬度（高精度）', unit: '°', cat: 'location', conf: CONF.CONFIRMED, note: '与 2190 差在末位小数，互为校验。' },
  '3724': { name: '经度（高精度）', unit: '°', cat: 'location', conf: CONF.CONFIRMED, note: '★ 注意 3724/3725 是「经度在前」，别跟 2190/2191 记混。' },

  // ---- 车身状态 ----
  '1298': { name: '车门锁', unit: '', cat: 'body', conf: CONF.CONFIRMED, note: '1 = 已上锁，0 = 未上锁。与 3262 冗余。' },
  '3262': { name: '车门锁（冗余）', unit: '', cat: 'body', conf: CONF.CONFIRMED, note: '与 1298 同步。两个都读不到才显示「锁态未知」。' },
  '1281': { name: '后备箱', unit: '', cat: 'body', conf: CONF.CONFIRMED, note: '1 = 开，0 = 关。★ 与 cmdid 130 双向对上。' },
  '1693': { name: '车窗位置 1', unit: '', cat: 'body', conf: CONF.CONFIRMED, note: '实测只取过 0 / 2。★ 与 cmdid 230 双向对上：四个同时动，说明 230 是「四窗一起动」。' },
  '1694': { name: '车窗位置 2', unit: '', cat: 'body', conf: CONF.CONFIRMED, note: '见 1693。' },
  '1695': { name: '车窗位置 3', unit: '', cat: 'body', conf: CONF.CONFIRMED, note: '见 1693。' },
  '1696': { name: '车窗位置 4', unit: '', cat: 'body', conf: CONF.CONFIRMED, note: '见 1693。' },
  '1318': { name: '总里程', unit: 'km', cat: 'body', conf: CONF.CONFIRMED, note: '实测 1909，与用户截图逐字一致。' },
  '47': { name: '状态位 47', unit: '', cat: 'body', conf: CONF.UNKNOWN, note: '47/48/49/50 实测 1,1,0,0，疑似四门或四窗开合。' },
  '48': { name: '状态位 48', unit: '', cat: 'body', conf: CONF.UNKNOWN, note: '见 47。' },
  '49': { name: '状态位 49', unit: '', cat: 'body', conf: CONF.UNKNOWN, note: '见 47。' },
  '50': { name: '状态位 50', unit: '', cat: 'body', conf: CONF.UNKNOWN, note: '见 47。' },

  // ---- 温度 / 空调 ----
  '1349': { name: '车内温度', unit: '℃', cat: 'climate', conf: CONF.CONFIRMED, note: '实测 29.5。' },
  '1938': { name: '空调开关', unit: '', cat: 'climate', conf: CONF.CONFIRMED, note: '1 = 开，0 = 关。★ 与 cmdid 170 双向对上。' },
  '1943': { name: '空调伴随位 1943', unit: '', cat: 'climate', conf: CONF.OBSERVED, note: '与 1938 反相，语义未定。' },
  '1941': { name: '空调档位候选 1941', unit: '', cat: 'climate', conf: CONF.UNKNOWN, note: '只有一个样本，证据不足以当风量用。' },
  '10707': { name: '疑似设定温度', unit: '℃', cat: 'climate', conf: CONF.UNKNOWN, note: '实测 −6，负数不像环境温度。' },

  // ---- 时间 / 元数据 ----
  '1': { name: '采集时间戳', unit: 'ms', cat: 'meta', conf: CONF.CONFIRMED, note: '13 位毫秒。用它算「车况是几分钟前采集的」。' },
  sts: { name: '服务端时间戳', unit: 'ms', cat: 'meta', conf: CONF.CONFIRMED, note: '13 位毫秒，比 1 略晚几十到几百毫秒。' },
};

/** 充电判据的电流门槛（A）—— 熄火 0.0 / 通电 0.2~0.3 / 真充电 ~8.3，取 1.0 两头留余量 */
const CHARGE_CURRENT_THRESHOLD = 1.0;

/** 高压系统激活标志位 */
const HV_FLAGS = ['100004', '1149', '1257', '3636', '3722'];

function num(map, id) {
  if (!map) return null;
  const v = map[id];
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function raw(map, id) {
  if (!map) return null;
  const v = map[id];
  return v === undefined ? null : v;
}

/** 布尔化：非 0 视为 true；读不到返回 null */
function bool(map, id) {
  const n = num(map, id);
  return n === null ? null : n !== 0;
}

/** 车窗值 → 文案 */
function windowLabel(v) {
  if (v === null || v === undefined) return '未知';
  if (v === 0) return '关闭';
  if (v === 2) return '微开';
  if (v === 5) return '半开';
  return `位置 ${v}`;
}

/**
 * 从 signalMap 派生所有 UI 需要的量。
 * 读不到的字段一律 null —— 宁可显示「未知」也不猜。
 */
function derive(map) {
  const m = map || {};
  const chargeCurrent = num(m, '1178');
  const chargeVoltage = num(m, '1177');

  let chargeState = 'unknown';
  if (chargeCurrent !== null) {
    chargeState = Math.abs(chargeCurrent) >= CHARGE_CURRENT_THRESHOLD ? 'charging' : 'idle';
  }

  const hvVotes = HV_FLAGS.map((id) => num(m, id)).filter((v) => v !== null);
  const hvActive = hvVotes.length > 0 && hvVotes.some((v) => v !== 0);

  const lockA = num(m, '1298');
  const lockB = num(m, '3262');
  const lockRaw = lockA !== null ? lockA : lockB;

  const windows = ['1693', '1694', '1695', '1696'].map((id) => num(m, id));
  const winKnown = windows.filter((v) => v !== null);
  let windowSummary = null;
  if (winKnown.length) {
    const allSame = winKnown.every((v) => v === winKnown[0]);
    windowSummary = allSame ? windowLabel(winKnown[0]) : '不一致';
  }

  return {
    soc: num(m, '100003'),
    socInt: num(m, '1204'),
    rangeA: num(m, '3257'),
    rangeB: num(m, '3260'),
    rangeB2: num(m, '2188'),
    minutesToTarget: num(m, '1200'),
    battTemp: num(m, '2183'),
    cabinTemp: num(m, '1349'),
    chargeVoltage,
    chargeCurrent,
    chargeState,
    chargePowerKW:
      chargeVoltage !== null && chargeCurrent !== null
        ? Math.abs(chargeVoltage * chargeCurrent) / 1000
        : null,
    hvActive,
    locked: lockRaw === null ? null : lockRaw !== 0,
    trunkOpen: bool(m, '1281'),
    windows,
    windowSummary,
    odometer: num(m, '1318'),
    acOn: bool(m, '1938'),
    lat: num(m, '2190'),
    lng: num(m, '2191'),
    latHi: num(m, '3725'),
    lngHi: num(m, '3724'),
    collectedAt: num(m, '1'),
    serverTime: num(m, 'sts'),
  };
}

/** 把 signalMap 整理成「分类 → 有名字的信号」列表，给「全部信号」页用 */
function group(map) {
  const out = [];
  Object.keys(CATEGORIES).forEach((cat) => {
    const items = Object.keys(CATALOG)
      .filter((id) => CATALOG[id].cat === cat)
      .map((id) => {
        const def = CATALOG[id];
        const v = raw(map, id);
        return {
          id,
          name: def.name,
          unit: def.unit,
          conf: def.conf,
          note: def.note,
          value: v === null || v === undefined ? '—' : v,
          known: CATALOG[id] !== undefined,
        };
      })
      .filter((it) => it.known)
      .sort((a, b) => {
        const ai = Number(a.id);
        const bi = Number(b.id);
        if (Number.isFinite(ai) && Number.isFinite(bi)) return ai - bi;
        return String(a.id).localeCompare(String(b.id));
      });
    if (items.length) out.push({ cat, title: CATEGORIES[cat], items });
  });
  return out;
}

/** signalMap 里有、但知识库里没有的 id（给诊断页看） */
function unknownIds(map) {
  if (!map) return [];
  return Object.keys(map)
    .filter((id) => !CATALOG[id])
    .sort((a, b) => {
      const ai = Number(a);
      const bi = Number(b);
      if (Number.isFinite(ai) && Number.isFinite(bi)) return ai - bi;
      return String(a).localeCompare(String(b));
    });
}

module.exports = {
  CONF,
  CATEGORIES,
  CATALOG,
  CHARGE_CURRENT_THRESHOLD,
  HV_FLAGS,
  num,
  raw,
  bool,
  windowLabel,
  derive,
  group,
  unknownIds,
};
