'use strict';
/**
 * 小程序静态资产检查 —— 抓「只能到真机才暴露」的低级错误。
 * ==================================================================
 * 运行： node weapp/tools/check_assets.js
 *
 * 检查四件事：
 *   1. app.json 里登记的每个页面，4 个文件（js/json/wxml/wxss）都在
 *      —— 少一个，微信开发者工具会报「未找到 xxx.json」并且整个页面白屏。
 *   2. tabBar 里引用的 pagePath 都在 app.json 的 pages 里注册过
 *      —— 漏注册的话 tabBar 直接不显示，很难查。
 *   3. 每个 .js 里 require('相对路径') 的目标文件真实存在
 *      —— 打错一个字母，真机才报「module not found」。
 *   4. 云函数 cloudfunctionRoot 下确实有目录，且每个都有 index.js 和 package.json。
 */

const fs = require('fs');
const path = require('path');

const weappRoot = path.join(__dirname, '..');
const mpRoot = path.join(weappRoot, 'miniprogram');
const problems = [];

function rel(p) {
  return path.relative(weappRoot, p).replace(/\\/g, '/');
}

// ---------------- 1 & 2：页面与 tabBar ----------------

const appJsonPath = path.join(mpRoot, 'app.json');
if (!fs.existsSync(appJsonPath)) {
  console.error('✗ 找不到 miniprogram/app.json');
  process.exit(1);
}
const app = JSON.parse(fs.readFileSync(appJsonPath, 'utf8'));
const pages = app.pages || [];

const EXTS = ['js', 'json', 'wxml', 'wxss'];
for (const page of pages) {
  for (const ext of EXTS) {
    const p = path.join(mpRoot, `${page}.${ext}`);
    if (!fs.existsSync(p)) problems.push(`缺文件： ${rel(p)}`);
  }
}

const tabList = (app.tabBar && app.tabBar.list) || [];
for (const item of tabList) {
  if (pages.indexOf(item.pagePath) < 0) {
    problems.push(`tabBar 引用了未注册页面： ${item.pagePath}`);
  }
  if (!item.text) problems.push(`tabBar 项缺 text： ${item.pagePath}`);
}

// ---------------- 3：require 的相对路径 ----------------

const REQUIRE_RE = /require\(\s*['"]([^'"]+)['"]\s*\)/g;

function walkJs(dir, out) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) {
      if (name === 'node_modules') continue;
      walkJs(p, out);
    } else if (name.endsWith('.js')) {
      out.push(p);
    }
  }
  return out;
}

for (const file of walkJs(weappRoot, [])) {
  const src = fs.readFileSync(file, 'utf8');
  let m;
  REQUIRE_RE.lastIndex = 0;
  while ((m = REQUIRE_RE.exec(src)) !== null) {
    const spec = m[1];
    if (!spec.startsWith('.')) continue; // 内置模块 / npm 包，跳过
    const base = path.resolve(path.dirname(file), spec);
    const ok = [base, `${base}.js`, `${base}.json`, path.join(base, 'index.js')]
      .some((c) => fs.existsSync(c) && fs.statSync(c).isFile());
    if (!ok) problems.push(`require 目标不存在： ${spec}  （在 ${rel(file)}）`);
  }
}

// ---------------- 4：云函数目录 ----------------

const cfRoot = path.join(weappRoot, 'cloudfunctions');
if (!fs.existsSync(cfRoot)) {
  problems.push('缺目录： cloudfunctions/（project.config.json 的 cloudfunctionRoot 指向它）');
} else {
  const dirs = fs.readdirSync(cfRoot).filter((n) => fs.statSync(path.join(cfRoot, n)).isDirectory());
  if (!dirs.length) problems.push('cloudfunctions/ 下没有任何云函数目录');
  for (const d of dirs) {
    for (const f of ['index.js', 'package.json']) {
      const p = path.join(cfRoot, d, f);
      if (!fs.existsSync(p)) problems.push(`云函数 ${d} 缺 ${f}`);
    }
  }
}

// ---------------- 结果 ----------------

if (problems.length) {
  console.error(`✗ 小程序资产检查失败，${problems.length} 个问题：\n - ${problems.join('\n - ')}`);
  process.exit(1);
}

console.log(
  `OK：${pages.length} 个页面 × ${EXTS.length} 个文件齐全；` +
  `tabBar ${tabList.length} 项都已注册；` +
  `require 相对路径全部存在；云函数目录结构正常`
);
