// 官方 3D 车模 H5 查看器 —— 本地实测脚本
//
// 用法:
//   node car3d_webtest.mjs <web_root> <out_png> [--w 420] [--h 760]
//
// 作用:
//   1. 起一个静态 HTTP 服务（模拟 App 内嵌服务，保证 Worker/ESM 正常）
//   2. 用 headless Chromium 打开官方 index.html
//   3. 调 window.onIOSWebview() + window.newInit(serverJson, appJson)
//   4. 等首帧 / canvas 出现非空白像素
//   5. 截图 + 输出控制台日志，用于验证契约
//
// 依赖: playwright（含 chromium）

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const WS = 'C:/Users/litong/.workbuddy-ai/binaries/node/workspace/node_modules';
let chromium;
try {
  ({ chromium } = require(path.join(WS, 'playwright')));
} catch (e) {
  ({ chromium } = require('playwright'));
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8',
  '.fbx': 'application/octet-stream',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.wasm': 'application/wasm',
};

function serve(root) {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      let p = decodeURIComponent(req.url.split('?')[0]);
      if (p === '/' || p === '') p = '/index.html';
      const fp = path.join(root, p);
      if (!fp.startsWith(root)) { res.writeHead(403); res.end('forbidden'); return; }
      fs.readFile(fp, (err, buf) => {
        if (err) { res.writeHead(404, { 'content-type': 'text/plain' }); res.end('404 ' + p); return; }
        res.writeHead(200, {
          'content-type': MIME[path.extname(fp).toLowerCase()] || 'application/octet-stream',
          'cache-control': 'no-store',
        });
        res.end(buf);
      });
    });
    srv.listen(0, '127.0.0.1', () => resolve(srv));
  });
}

function argOf(name, dflt) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : dflt;
}

const webRoot = path.resolve(process.argv[2] || '.');
const outPng = path.resolve(process.argv[3] || 'car3d_render.png');
const W = parseInt(argOf('--w', '420'), 10);
const H = parseInt(argOf('--h', '760'), 10);

// 官方 3d/key 接口返回的 modelParam 原样喂进去
const serverJson = {
  carType: 'D19',
  year: 2026,
  carTypeCode: '720智尊版 六座',
  colorCode: 0,
  roofColor: '0',
  rudder: 0,
  seat: '0',
  sdkVersion: '3.24.2',
  licenseNumber: '',
};
const appJson = { width: W, height: H, energy: 0, inland: 0 };

const srv = await serve(webRoot);
const port = srv.address().port;
const url = `http://127.0.0.1:${port}/index.html`;
console.log('[srv] root =', webRoot);
console.log('[srv] url  =', url);

const browser = await chromium.launch({
  args: [
    '--enable-unsafe-swiftshader',
    '--use-gl=angle',
    '--use-angle=swiftshader',
    '--ignore-gpu-blocklist',
    '--enable-webgl',
    '--disable-web-security',
  ],
});
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });

const logs = [];
page.on('console', (m) => logs.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', (e) => logs.push(`[pageerror] ${e.message}`));
page.on('requestfailed', (r) => logs.push(`[reqfail] ${r.url()} :: ${r.failure()?.errorText}`));

await page.goto(url, { waitUntil: 'load', timeout: 60000 });
await page.waitForTimeout(2500);

const hasApi = await page.evaluate(() => ({
  newInit: typeof window.newInit,
  init: typeof window.init,
  onIOSWebview: typeof window.onIOSWebview,
  viewer: typeof window.viewer,
}));
console.log('[api]', JSON.stringify(hasApi));

// 触发初始化
await page.evaluate(([sj, aj]) => {
  window.__ff = false;
  window.onFirstFrame = () => { window.__ff = true; };
  if (window.onIOSWebview) window.onIOSWebview();
  return window.newInit(JSON.stringify(sj), JSON.stringify(aj));
}, [serverJson, appJson]);

// 等首帧或 canvas 出现
let ff = false;
for (let i = 0; i < 60; i++) {
  await page.waitForTimeout(1000);
  ff = await page.evaluate(() => !!window.__ff);
  const canv = await page.evaluate(() => document.querySelectorAll('canvas').length);
  if (i % 5 === 0) console.log(`[wait] ${i}s  firstFrame=${ff}  canvas=${canv}`);
  if (ff) break;
}

const stat = await page.evaluate(() => {
  const c = document.querySelector('canvas');
  return {
    canvasCount: document.querySelectorAll('canvas').length,
    cw: c ? c.width : 0,
    ch: c ? c.height : 0,
    firstFrame: !!window.__ff,
    carReady: !!(window.car || window.viewer),
  };
});
console.log('[stat]', JSON.stringify(stat));

await page.screenshot({ path: outPng });
console.log('[out]', outPng);

console.log('---- console 日志（尾 40 条）----');
for (const l of logs.slice(-40)) console.log(l);

await browser.close();
srv.close();
process.exit(ff ? 0 : 3);
