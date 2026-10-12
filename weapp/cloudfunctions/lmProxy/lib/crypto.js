'use strict';
/**
 * 零跑车控 —— 纯 Node 内置 crypto 实现（零第三方依赖）
 * ==================================================================
 * 与 client/leapmotor_client.py / ios .../Crypto/LMSigner.swift 逐行对齐。
 *
 * 只依赖 node 内置 `crypto`，所以云函数**不需要 npm install**，冷启动更快。
 *
 * 覆盖四件事：
 *   1. 哈希        md5Hex / md5Lower16 / sha256Hex / hmacSha256Hex
 *   2. signKey 派生 XOR3(b64dec(jwt[2]), b64dec(r2), b64dec(r3))
 *   3. oppwd 加密   base64(AES-128-CBC-PKCS7(密码, md5(tok[0:32])[8:24], md5(tok[32:64])[8:24]))
 *   4. 手机号 RSA   base64(RSA_PKCS1v15(手机号, AccountIDKey))
 */

const crypto = require('crypto');

// ----------------------------------------------------------------------
// 账号服务 RSA 公钥（SPKI DER, base64）
// 来源：iOS 主二进制 AccountIDKey；与 ios/.../Crypto/LMRSA.swift 同一串
// ----------------------------------------------------------------------
const ACCOUNT_ID_KEY_SPKI_B64 =
  'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHUIQKhkwNqJFTZPe98mC1lmpbY9r/+7PEWZg8' +
  'ebqYXT3sumKRaQ0zcoTx42x0iybmCRXy4CcZrgGAbwKzwqwNw0rFquJ6c7mgQA6k3lZU3p96qBlzK' +
  '7DSkoFR6mO9pjcd2hlJ8wH+IwI5b8IWWZhwVN/4cM7npG0S0zeRn3soEwIDAQAB';

// ----------------------------------------------------------------------
// 1. 哈希
// ----------------------------------------------------------------------

function md5Hex(s) {
  return crypto.createHash('md5').update(String(s), 'utf8').digest('hex');
}

/** 对齐 +[LMVMD5Util MD5ForLower16Bate:]：md5 hex 的第 8..24 个字符（16 个 ASCII） */
function md5Lower16(s) {
  return md5Hex(s).slice(8, 24);
}

function sha256Hex(s) {
  return crypto.createHash('sha256').update(String(s), 'utf8').digest('hex');
}

/**
 * 对齐 JS parseKeyString() / Python parse_key()：
 *   - Buffer            → 直接用
 *   - 全 hex 的字符串    → hex 解码
 *   - 其它字符串         → UTF-8 字节
 *
 * ⚠️ 「是不是 hex」的判断必须和 JS 一致：把字符串里所有非 hex 字符删掉，
 *    如果长度没变（说明本来就全是 hex 字符），才按 hex 解。
 *    否则像 "leapmotor" 这种含 'a'~'f' 的普通串会被误判 —— 长度变了，所以走 UTF-8。
 */
function parseKey(keyInput) {
  if (Buffer.isBuffer(keyInput)) return keyInput;
  const s = String(keyInput === null || keyInput === undefined ? '' : keyInput);
  const cleaned = s.replace(/[^0-9A-Fa-f]/g, '');
  const stripped = s.replace(/[ \t]/g, '');
  if (cleaned.length > 0 && cleaned.length === stripped.length) {
    if (cleaned.length % 2 !== 0) throw new Error('hex signKey 长度必须是偶数');
    return Buffer.from(cleaned, 'hex');
  }
  return Buffer.from(s, 'utf8');
}

/**
 * HMAC-SHA256。
 * 语义对齐 Python generate_hmac_sha256：message 为空 或 key 为 null/undefined → null。
 * （注意：空字符串 key 是**合法**的，HMAC 支持空 key，所以不能把 '' 当成 null。）
 */
function hmacSha256Hex(message, keyInput) {
  if (!message || keyInput === null || keyInput === undefined) return null;
  return crypto.createHmac('sha256', parseKey(keyInput))
    .update(String(message), 'utf8')
    .digest('hex');
}

// ----------------------------------------------------------------------
// 2. base64 / XOR3 / signKey 派生
// ----------------------------------------------------------------------

function b64urlToB64(s) {
  const t = String(s || '').replace(/-/g, '+').replace(/_/g, '/');
  return t + '='.repeat((4 - (t.length % 4)) % 4);
}

/** 宽松 base64 解码（容忍缺 padding 与非法字符，和 Python base64.b64decode 一致） */
function b64decodeLoose(s) {
  let t = String(s === null || s === undefined ? '' : s).trim();
  t += '='.repeat((4 - (t.length % 4)) % 4);
  return Buffer.from(t, 'base64');
}

/** 对齐 +[LMVLocalLoginModel xorThreeData:data2:data3:]：零填充到最长 */
function xor3(d1, d2, d3) {
  const n = Math.max(d1.length, d2.length, d3.length);
  const out = Buffer.alloc(n);
  for (let i = 0; i < n; i += 1) {
    const a = i < d1.length ? d1[i] : 0;
    const b = i < d2.length ? d2[i] : 0;
    const c = i < d3.length ? d3[i] : 0;
    out[i] = a ^ b ^ c;
  }
  return out;
}

/**
 * signKey = XOR3( b64dec(b64url2b64(accessToken.split('.')[2])), b64dec(r2), b64dec(r3) )
 * @returns {Buffer}
 */
function deriveKey(accessToken, r2, r3) {
  const parts = String(accessToken || '').split('.');
  if (parts.length < 3) throw new Error('accessToken 不是 >=3 段的 JWT');
  const d1 = b64decodeLoose(b64urlToB64(parts[2]));
  return xor3(d1, b64decodeLoose(r2), b64decodeLoose(r3));
}

/**
 * 一次性派生 signKey / encryptKey。
 * 服务端保证 signParam 与 encryptParam 两组的 r2^r3 相同 ⇒ 两者相等。
 * @returns {{signKeyHex: string, encryptKeyHex: string, signKey: Buffer|null, encryptKey: Buffer|null}}
 */
function deriveKeys(accessToken, signParam, encryptParam) {
  const out = { signKeyHex: '', encryptKeyHex: '', signKey: null, encryptKey: null };
  const sp = signParam || {};
  const ep = encryptParam || {};
  if (sp.r2 && sp.r3) {
    out.signKey = deriveKey(accessToken, sp.r2, sp.r3);
    out.signKeyHex = out.signKey.toString('hex').toUpperCase();
  }
  if (ep.r2 && ep.r3) {
    out.encryptKey = deriveKey(accessToken, ep.r2, ep.r3);
    out.encryptKeyHex = out.encryptKey.toString('hex').toUpperCase();
  }
  return out;
}

// ----------------------------------------------------------------------
// 3. oppwd（操作密码）
// ----------------------------------------------------------------------

/**
 * oppwd = base64( AES-128-CBC-PKCS7( 密码, key, iv ) )
 *   key = md5hex(accessToken[0:32])[8:24]   （16 个 ASCII 字符）
 *   iv  = md5hex(accessToken[32:64])[8:24]
 *
 * Node 的 createCipheriv('aes-128-cbc') 默认就带 PKCS#7 padding，与 pycryptodome 的 pad() 一致。
 *
 * 已用真实抓包 round-trip 验证（同 Python 自测）：
 *   token = har_appgw 的 accessToken, password = "4211" → "uHTigfMDS5zIuZX4Gq4NVQ=="
 */
function encryptOppwd(accessToken, password) {
  const tok = String(accessToken || '');
  if (tok.length < 64) throw new Error('accessToken 长度需 >= 64');
  const key = Buffer.from(md5Lower16(tok.slice(0, 32)), 'ascii');
  const iv = Buffer.from(md5Lower16(tok.slice(32, 64)), 'ascii');
  const cipher = crypto.createCipheriv('aes-128-cbc', key, iv);
  const ct = Buffer.concat([cipher.update(Buffer.from(String(password), 'utf8')), cipher.final()]);
  return ct.toString('base64');
}

// ----------------------------------------------------------------------
// 4. 手机号 RSA
// ----------------------------------------------------------------------

/**
 * phoneNo = base64( RSA_PKCS1v15( 手机号, AccountIDKey ) )，1024 位 → 128 字节
 *
 * 对应原生 `EncodeForStrV1:`；服务端拿私钥解出手机号。
 * ⚠️ 必须显式给 padding —— Node 18 起默认 padding 在部分版本会报错。
 */
function rsaEncryptPhone(phone, spkiBase64) {
  const der = Buffer.from(spkiBase64 || ACCOUNT_ID_KEY_SPKI_B64, 'base64');
  const enc = crypto.publicEncrypt(
    {
      key: der,
      format: 'der',
      type: 'spki',
      padding: crypto.constants.RSA_PKCS1_PADDING,
    },
    Buffer.from(String(phone), 'utf8')
  );
  return enc.toString('base64');
}

module.exports = {
  ACCOUNT_ID_KEY_SPKI_B64,
  md5Hex,
  md5Lower16,
  sha256Hex,
  parseKey,
  hmacSha256Hex,
  b64urlToB64,
  b64decodeLoose,
  xor3,
  deriveKey,
  deriveKeys,
  encryptOppwd,
  rsaEncryptPhone,
};
