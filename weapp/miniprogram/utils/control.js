/**
 * 车控的 UI 层封装：操作密码提示 + 物理动作二次确认 + 下发并轮询。
 * 让各个页面调一行就能完成「确认 → 输入密码 → 下发 → 等结果」。
 */

const api = require('./api.js');
const store = require('./store.js');

/** 拿操作密码：优先用本地存的，没有就弹框问（4~8 位数字） */
function ensureOpPassword() {
  return new Promise((resolve, reject) => {
    const saved = store.getOpPassword();
    if (saved && /^\d{4,8}$/.test(saved)) {
      resolve(saved);
      return;
    }
    wx.showModal({
      title: '车控操作密码',
      editable: true,
      placeholderText: '请输入车控操作密码',
      confirmText: '确定',
      success(res) {
        if (!res.confirm) {
          reject(new Error('已取消'));
          return;
        }
        const v = String(res.content || '').trim();
        if (!/^\d{4,8}$/.test(v)) {
          reject(new Error('操作密码格式不对（应为 4~8 位数字）'));
          return;
        }
        if (store.getRememberOpPwd()) store.setOpPassword(v);
        resolve(v);
      },
      fail() {
        reject(new Error('已取消'));
      },
    });
  });
}

/** 物理动作的二次确认（会开车门/后备箱/车窗，必须提醒周围安全） */
function confirmPhysical(label) {
  return new Promise((resolve) => {
    wx.showModal({
      title: '确认执行',
      content: `${label}\n\n这会改变车辆物理状态。请确认车辆周围安全、你能直接看到车。`,
      confirmText: '执行',
      confirmColor: '#FF6B6B',
      success(r) {
        resolve(!!r.confirm);
      },
      fail() {
        resolve(false);
      },
    });
  });
}

/**
 * 执行一条车控。
 *
 * @param {object} p
 *   vin       车辆 VIN（必填）
 *   name      命令 key（commands 里的键）
 *   label     显示名
 *   risk      'physical' | 'low'
 *   cmdid     诊断页用：直接指定 cmdid
 *   state     诊断页用：直接指定 state
 *   silent    为 true 时不做二次确认（内部用）
 * @returns {Promise<{ok:boolean, timedOut:boolean, samples:number}>}
 */
async function run(p) {
  const risk = p.risk || 'low';
  if (risk === 'physical' && !p.silent) {
    const yes = await confirmPhysical(p.label || '执行该操作');
    if (!yes) return { ok: false, cancelled: true, samples: 0 };
  }

  const opPassword = await ensureOpPassword();

  wx.showLoading({ title: '下发中…', mask: true });
  try {
    const result = await api.controlAndWait({
      vin: p.vin,
      name: p.name,
      cmdid: p.cmdid,
      state: p.state,
      label: p.label,
      opPassword,
    });
    wx.hideLoading();

    if (result.ok) {
      wx.showToast({ title: '执行成功', icon: 'success' });
    } else if (result.timedOut) {
      wx.showToast({ title: '已下发，但没等到确认', icon: 'none' });
    } else {
      wx.showToast({ title: '下发失败', icon: 'none' });
    }
    return result;
  } catch (e) {
    wx.hideLoading();
    wx.showToast({ title: e.message || '下发失败', icon: 'none' });
    return { ok: false, error: e.message, samples: 0 };
  }
}

module.exports = {
  ensureOpPassword,
  confirmPhysical,
  run,
};
