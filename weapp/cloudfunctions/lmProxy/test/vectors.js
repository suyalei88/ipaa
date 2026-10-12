'use strict';
/**
 * 云函数自测 —— 与 Python 参考实现逐条对拍
 * ==================================================================
 * 运行： node test/vectors.js        （或 npm test）
 *
 * 所有期望值都来自 client/leapmotor_client.py 的 __main__ 自测与真实抓包，
 * **不是**我手算的。任何一条挂掉都说明云函数的签名/加密与 iOS 版不一致，
 * 上线后会得到 302002002（签名校验失败）或 1019（参数不能为空）。
 */

const assert = require('assert');
const crypto = require('crypto');

const C = require('../lib/crypto');
const S = require('../lib/sign');
const { encodeStrict, buildURL, findValue } = require('../lib/client');
const { CTRL_COMMANDS } = require('../lib/endpoints');

let pass = 0;
let fail = 0;
function check(name, fn) {
  try {
    fn();
    pass += 1;
    console.log(`  [OK ] ${name}`);
  } catch (e) {
    fail += 1;
    console.log(`  [!! ] ${name}\n         ${e.message}`);
  }
}

// ----------------------------------------------------------------------
// 测试向量（与 client/leapmotor_client.py 的 __main__ 完全同源）
// ----------------------------------------------------------------------

// ⚠️ 这是一份**已过期的抓包向量**，同样原样存在于 client/leapmotor_client.py 里，
//    只用于证明算法一致；不是可用凭据。
const DEMO_ACCESS_TOKEN =
  'eyJub25jZSI6ImEyNzEwYjZkNDgwNDQ2ZTlhMjExOGI2YjIzZmQ3MDU3IiwiYWxnIjoiSFMyNTYiLCJ0eXAiOiJKV1QifQ'
  + '.eyJ1c2VyX25hbWUiOiJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2LDEsZGV2aWNlSWQ6aW9zX2VlNDViOWQ4MzBi'
  + 'YjEyNmQ0MzFlOTk4OTQzYTc3OTdhLHBhc3N3b3JkOiIsInNjb3BlIjpbInJlYWQiXSwiZXhwIjoxNzkxMzU3ODExLCJhdXRo'
  + 'b3JpdGllcyI6WyJhY2NvdW50SWQ6NjcyOTU1MTc5MjI5NzgyMDE2Il0sImp0aSI6IjJlZDE3MjcyLTBmOTktNDcwNy04MTE3'
  + 'LTU3OGYxMTAyYWI1NiIsInNpZ25fdGltZSI6MTc5MTM1MDYxMSwiY2xpZW50X2lkIjoiSHpUbWNzQmcifQ'
  + '.y9ncviOjBWW1YSTbjf0RRJVB4_cWJIOAufJ-ZU7Ci1I';

const DEMO_SIGN_PARAM = {
  r2: '6zoreHkMT7yoe9zi5p5H5Kfc9woIPTOdMtBQYpl/vfo=',
  r3: 'XM/iTva8QdJ5z7GQQD6Ry/pnSK4ZrAl/xo+CVu03884=',
};
const DEMO_ENCRYPT_PARAM = {
  r2: 'cYPovbbtY3Bxv+9m0+0+2v7CRs/s1FWbotOguVLySys=',
  r3: 'xnYhizldbR6gC4IUdU3o9aN5+Wv9RW95VoxyjSa6BR8=',
};

const EXPECT_VALUE_STR =
  'zh-CN1.22.681ios_ee45b9d830bb126d431e998943a7797aiOS12020738377iOSleapmotor17913507165061.22.68LFZ63AA15TH035113';
const EXPECT_SIGN_KEY_HEX = '7C2C1588AC130B0B64D549A92B5DC76BC8FA5C5307B5B9624DADAC513A8AC566';
const EXPECT_HMAC = '36cb2797d808a7cdedd49b98703155fa25cc49ee70e8bacd193801a65edbfac4';
const EXPECT_SHA256 = 'ad7a094cb485dcd09b6d9e5a1a7e65174681965be731a413e4e98e4cfebd5bd6';
const EXPECT_OPPWD_4211 = 'uHTigfMDS5zIuZX4Gq4NVQ==';

const SIGN_BODY = { appVersion: '1.22.68', isMainApp: '1', osType: 'iOS', vin: 'LFZ63AA15TH035113' };
const SIGN_HEADERS = {
  acceptLanguage: 'zh-CN',
  channel: '1',
  deviceId: 'ios_ee45b9d830bb126d431e998943a7797a',
  deviceType: 'iOS',
  nonce: '2020738377',
  source: 'leapmotor',
  timestamp: '1791350716506',
  version: '1.22.68',
};

console.log('\n=== 1. valueStr 构造（对齐 JS buildSignValueString）===');
check('valueStr 与抓包样本逐字一致', () => {
  assert.strictEqual(S.buildSignValueString(SIGN_BODY, SIGN_HEADERS), EXPECT_VALUE_STR);
});
check('false / 0 不会被当成空值剔除', () => {
  const vs = S.buildSignValueString({ a: false, b: 0, c: '' }, {});
  // a → "false"，b → "0"，c 被剔除；按 key 升序 a,b
  assert.strictEqual(vs, 'false0');
});
check('null / undefined 被剔除', () => {
  assert.strictEqual(S.buildSignValueString({ a: null, b: undefined, c: 'x' }, {}), 'x');
});

console.log('\n=== 2. 签名（双模式）===');
check('HMAC-SHA256 与 Python 一致', () => {
  assert.strictEqual(S.sign(SIGN_BODY, SIGN_HEADERS, EXPECT_SIGN_KEY_HEX), EXPECT_HMAC);
});
check('登录前 SHA256（无密钥）与 Python 一致', () => {
  assert.strictEqual(S.signPreLogin(SIGN_BODY, SIGN_HEADERS), EXPECT_SHA256);
});
check('signKey 为空时 HMAC 返回 null', () => {
  assert.strictEqual(S.sign(SIGN_BODY, SIGN_HEADERS, ''), null);
});

console.log('\n=== 3. signKey / encryptKey 派生（真实抓包）===');
check('signKey == encryptKey == 抓包值', () => {
  const k = C.deriveKeys(DEMO_ACCESS_TOKEN, DEMO_SIGN_PARAM, DEMO_ENCRYPT_PARAM);
  assert.strictEqual(k.signKeyHex, EXPECT_SIGN_KEY_HEX);
  assert.strictEqual(k.encryptKeyHex, EXPECT_SIGN_KEY_HEX);
});
check('JWT 段数不足时抛错', () => {
  assert.throws(() => C.deriveKey('a.b', 'x', 'y'), />=3 段/);
});

console.log('\n=== 4. oppwd（操作密码）===');
check("encryptOppwd(token, '4211') == 抓包密文", () => {
  assert.strictEqual(C.encryptOppwd(DEMO_ACCESS_TOKEN, '4211'), EXPECT_OPPWD_4211);
});
check('accessToken 太短时抛错', () => {
  assert.throws(() => C.encryptOppwd('short', '4211'), />= 64/);
});
check('AES 输出可被 node 原生解回明文（round-trip）', () => {
  const token = DEMO_ACCESS_TOKEN;
  const key = Buffer.from(C.md5Lower16(token.slice(0, 32)), 'ascii');
  const iv = Buffer.from(C.md5Lower16(token.slice(32, 64)), 'ascii');
  const ct = Buffer.from(EXPECT_OPPWD_4211, 'base64');
  const d = crypto.createDecipheriv('aes-128-cbc', key, iv);
  const pt = Buffer.concat([d.update(ct), d.final()]).toString('utf8');
  assert.strictEqual(pt, '4211');
});

console.log('\n=== 5. parseKey（hex 判定）===');
check('全 hex 串按 hex 解码', () => {
  assert.deepStrictEqual(C.parseKey('deadbeef'), Buffer.from('deadbeef', 'hex'));
});
check('含非 hex 字符的串按 UTF-8（"leapmotor" 里有 a/e）', () => {
  assert.deepStrictEqual(C.parseKey('leapmotor'), Buffer.from('leapmotor', 'utf8'));
});
check('奇数长度 hex 抛错', () => {
  assert.throws(() => C.parseKey('abc'), /偶数/);
});

console.log('\n=== 6. 手机号 RSA（PKCS#1 v1.5，1024 位）===');
check('密文 128 字节 / base64 172 字符', () => {
  const enc = C.rsaEncryptPhone('17621058873');
  assert.strictEqual(Buffer.from(enc, 'base64').length, 128);
  assert.strictEqual(enc.length, 172);
});
check('每次加密结果不同（PKCS#1 v1.5 随机填充）', () => {
  assert.notStrictEqual(C.rsaEncryptPhone('17621058873'), C.rsaEncryptPhone('17621058873'));
});

console.log('\n=== 7. 严格百分号编码（base64 里的 + 必须变 %2B）===');
check("'+' → '%2B'", () => assert.strictEqual(encodeStrict('a+b'), 'a%2Bb'));
check("'/' → '%2F'，'=' → '%3D'", () => {
  assert.strictEqual(encodeStrict('a/b='), 'a%2Fb%3D');
});
check("!'()* 也被转义（encodeURIComponent 默认不转）", () => {
  assert.strictEqual(encodeStrict("!'()*"), '%21%27%28%29%2A');
});
check('buildURL 的 query 严格编码且按 key 排序', () => {
  assert.strictEqual(
    buildURL('https://h', '/p', { b: 'x+y', a: '1' }),
    'https://h/p?a=1&b=x%2By'
  );
});

console.log('\n=== 8. 车控命令表（反汇编校正后的版本）===');
check('关键 cmdid 映射与 iOS 版一致', () => {
  assert.strictEqual(CTRL_COMMANDS.lock.cmdid, 110);
  assert.strictEqual(CTRL_COMMANDS.horn.cmdid, 120);
  assert.strictEqual(CTRL_COMMANDS.trunk_open.cmdid, 130);
  assert.strictEqual(CTRL_COMMANDS.frunk_open.cmdid, 131);
  assert.strictEqual(CTRL_COMMANDS.ac_on.cmdid, 170);
  assert.strictEqual(CTRL_COMMANDS.window_half.cmdid, 230);
  assert.strictEqual(CTRL_COMMANDS.sentinel.cmdid, 400);
});
check('400 是哨兵模式而不是上电（旧表把这条写错过）', () => {
  assert.deepStrictEqual(CTRL_COMMANDS.sentinel.state, { operation: 'on' });
  assert.strictEqual(CTRL_COMMANDS.hello, undefined);
});
check('230 是车窗（0=关 / 2=微开 / 5=半开）', () => {
  assert.deepStrictEqual(CTRL_COMMANDS.window_close.state, { value: '0' });
  assert.deepStrictEqual(CTRL_COMMANDS.window_micro.state, { value: '2' });
  assert.deepStrictEqual(CTRL_COMMANDS.window_half.state, { value: '5' });
});

console.log('\n=== 9. findValue（递归找第一个非空 key）===');
check('能在嵌套结构里找到 token', () => {
  assert.strictEqual(findValue({ data: { appLoginVO: { token: 'abc' } } }, 'token'), 'abc');
});
check('空字符串会被跳过', () => {
  assert.strictEqual(findValue({ a: '', b: 'x' }, 'a'), undefined);
});

// ----------------------------------------------------------------------
console.log(`\n${'='.repeat(60)}`);
console.log(`结果： ${pass} 通过 / ${fail} 失败`);
if (fail > 0) process.exit(1);
console.log('云函数算法与 Python 参考实现一致 ✅');
