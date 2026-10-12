'use strict';
/**
 * 云函数路由冒烟测试（不发任何真实网络请求）
 * ==================================================================
 * 运行： node test/smoke.js
 *
 * 覆盖：meta / ping / 未登录拦截 / 未知 action / 参数校验。
 * 网络类 action（sendSms/login/status/control）不在这里测 —— 那些要真实账号，
 * 由真机联调验证。
 */

const assert = require('assert');
const { main } = require('../index');

let pass = 0;
let fail = 0;
async function check(name, fn) {
  try {
    await fn();
    pass += 1;
    console.log(`  [OK ] ${name}`);
  } catch (e) {
    fail += 1;
    console.log(`  [!! ] ${name}\n         ${e.message}`);
  }
}

(async () => {
  console.log('\n=== 云函数路由 ===');

  await check('ping 返回构建标识与命令数', async () => {
    const r = await main({ action: 'ping' });
    assert.strictEqual(r.ok, true);
    assert.ok(r.data.build);
    assert.ok(r.data.actions > 0);
  });

  await check('meta 返回分组 / 命令表 / 快捷动作 / 未验证 payload', async () => {
    const r = await main({ action: 'meta' });
    assert.strictEqual(r.ok, true);
    const d = r.data;
    assert.ok(Array.isArray(d.groups) && d.groups.length === 5, '应有 5 个分组');
    assert.strictEqual(d.commands.lock.cmdid, 110);
    assert.strictEqual(d.commands.sentinel.cmdid, 400);
    assert.deepStrictEqual(d.quickActions, ['lock', 'unlock', 'horn', 'ac_on']);
    assert.ok(d.physicalRisk.indexOf('trunk_open') >= 0);
    assert.ok(Array.isArray(d.unverifiedPayloads) && d.unverifiedPayloads.length > 0);
    assert.ok(d.deviceId.startsWith('ios_'));
  });

  await check('分组里引用的每个 action 都在命令表里（防漂移）', async () => {
    const r = await main({ action: 'meta' });
    const { groups, commands } = r.data;
    groups.forEach((g) => {
      g.actions.forEach((k) => {
        assert.ok(commands[k], `分组 ${g.key} 引用了不存在的命令 ${k}`);
      });
    });
  });

  await check('未登录时受保护 action 被拦住（返回 NO_SESSION）', async () => {
    const r = await main({ action: 'status', vin: 'LFZTEST' });
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.code, 'NO_SESSION');
  });

  await check('未登录时 control 同样被拦住', async () => {
    const r = await main({ action: 'control', name: 'lock', vin: 'X' });
    assert.strictEqual(r.ok, false);
    assert.strictEqual(r.code, 'NO_SESSION');
  });

  await check('未知 action 明确报错而不是静默成功', async () => {
    const r = await main({ action: 'definitelyNotAnAction' });
    assert.strictEqual(r.ok, false);
    assert.ok(/未知 action/.test(r.error));
  });

  await check('空 event 不崩', async () => {
    const r = await main(undefined);
    assert.strictEqual(r.ok, false);
  });

  await check('sendSms 手机号不合法时不会发出请求（RSA 之前先抛）', async () => {
    // 用超长字符串让 RSA 加密必然失败（PKCS#1 v1.5 上限 117 字节）
    const r = await main({ action: 'sendSms', phone: 'x'.repeat(300) });
    assert.strictEqual(r.ok, false);
  });

  console.log(`\n${'='.repeat(60)}`);
  console.log(`结果： ${pass} 通过 / ${fail} 失败`);
  if (fail > 0) process.exit(1);
  console.log('云函数路由正常 ✅');
})();
