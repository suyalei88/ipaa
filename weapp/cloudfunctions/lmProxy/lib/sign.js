'use strict';
/**
 * 零跑车控 —— 请求签名（与 ios/.../Crypto/LMSigner.swift 逐行对齐）
 * ==================================================================
 *
 * ★ 签名是**双模式**的（原生 `formatHeaderForHTTPRequestHeaders:...` 里按 bit0 分叉）：
 *
 *     ┌ 登录前：sign = SHA256(valueStr).hex()            ← 无密钥
 *     └ 登录后：sign = HMAC_SHA256(valueStr, signKey).hex()
 *
 *   这解释了为什么登录请求用 HMAC 会得到 `302002002 签名信息校验失败`。
 *
 *   valueStr = merge(signBody, signHeaders)
 *              → 去掉 null / undefined / ""（★ false 和 0 要保留）
 *              → key 升序（JS 默认字符串比较 = UTF-16 code unit）
 *              → 只取 value，无分隔符 join("")
 *
 *   signHeaders 固定 8 个 key：
 *       acceptLanguage / channel / deviceId / deviceType /
 *       nonce / source / timestamp / version
 *
 *   signBody 的取法（★ 最容易错的地方）：
 *       Content-Type: application/json        → 解析后的对象
 *       Content-Type: x-www-form-urlencoded   → **URL 解码后**的表单字典
 *       无 body                                → {}
 *       GET 的 query 参数一并 merge 进来
 */

const { sha256Hex, hmacSha256Hex } = require('./crypto');

/**
 * 对齐 JS `String(value)` / Python `_js_str()`。
 *   null/undefined → ""     true/false → "true"/"false"
 *   数字           → 整数不带 ".0"
 *   数组           → 元素 join(",")；含对象时按 `{k=v, k2=v2}` 形式（与 Python/JS 参考实现一致）
 */
function jsString(v) {
  if (v === null || v === undefined) return '';
  if (v === true) return 'true';
  if (v === false) return 'false';
  if (typeof v === 'number') {
    if (Number.isFinite(v) && Number.isInteger(v)) return String(v);
    return String(v);
  }
  if (Array.isArray(v)) {
    const hasObject = v.some((item) => item !== null && typeof item === 'object');
    if (!hasObject) return v.map(jsString).join(',');
    return v
      .map((item) => {
        if (item === null || typeof item !== 'object') return jsString(item);
        const inner = Object.keys(item)
          .filter((k) => item[k] !== null && item[k] !== undefined && item[k] !== '')
          .map((k) => `${k}=${jsString(item[k])}`)
          .join(', ');
        return `{${inner}}`;
      })
      .join(',');
  }
  if (typeof v === 'object') return '[object Object]';
  return String(v);
}

/** 完全对齐 JS buildSignValueString() */
function buildSignValueString(body, signHeaders) {
  const merged = {};
  if (body) {
    Object.keys(body).forEach((k) => { merged[k] = body[k]; });
  }
  if (signHeaders) {
    Object.keys(signHeaders).forEach((k) => { merged[k] = signHeaders[k]; });
  }
  // 只剔除 null / undefined / 空串；false 与 0 保留
  const keys = Object.keys(merged).filter((k) => {
    const v = merged[k];
    return v !== null && v !== undefined && v !== '';
  });
  // JS 默认字符串比较 = UTF-16 code unit 升序（与 Python 的 str 排序对 ASCII key 等价）
  keys.sort();
  return keys.map((k) => jsString(merged[k])).join('');
}

/** 登录前签名：SHA256(valueStr)，无密钥 */
function signPreLogin(body, signHeaders) {
  return sha256Hex(buildSignValueString(body, signHeaders));
}

/** 登录后签名：HMAC_SHA256(valueStr, signKeyHex)；signKey 为空 → null */
function sign(body, signHeaders, signKeyHex) {
  if (!signKeyHex) return null;
  return hmacSha256Hex(buildSignValueString(body, signHeaders), signKeyHex);
}

/** 生成 signHeaders 的 8 个固定键（timestamp 毫秒、nonce 0..2147483646） */
function makeSignHeaders(cfg) {
  return {
    acceptLanguage: cfg.acceptLanguage,
    channel: cfg.channel,
    deviceId: cfg.deviceId,
    deviceType: cfg.deviceType,
    nonce: String(Math.floor(Math.random() * 2147483647)),
    source: cfg.source,
    timestamp: String(Date.now()),
    version: cfg.version,
  };
}

module.exports = {
  jsString,
  buildSignValueString,
  signPreLogin,
  sign,
  makeSignHeaders,
};
