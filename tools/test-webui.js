#!/usr/bin/env node
/* 用假 DOM + 假 KSU 桥跑 WebUI 的真实脚本，验证：解析配置 → 重建 → 保存写出的内容 */
const fs = require('fs');
const html = fs.readFileSync(__dirname + '/module/webroot/index.html', 'utf8');
const js = html.split('<script>')[1].split('</script>')[0];

const DEFAULT_CFG = fs.readFileSync(__dirname + '/module/config.default', 'utf8');
const els = {};
const el = id => els[id] || (els[id] = { id, style: {}, textContent: '', innerHTML: '', value: '', checked: false,
  className: '', dataset: {}, addEventListener() {}, querySelector: () => ({ placeholder: '' }), onclick: null });
global.document = { getElementById: el, querySelectorAll: () => [], body: { insertAdjacentHTML() {} } };
global.window = {};
global.btoa = s => Buffer.from(s, 'binary').toString('base64');
global.unescape = s => s;

const CONF_RE = /^cat \/data\/adb\/fpgesture\/config 2>\/dev\/null$/;
const writes = [];
global.ksu = {
  exec(cmd, opts, cb) {
    let out = '';
    if (CONF_RE.test(cmd.trim())) out = DEFAULT_CFG;
    else if (/^echo [A-Za-z0-9+/=]+ \| base64 -d > /.test(cmd.trim())) writes.push(cmd.trim());
    window[cb](0, out, '');
  },
};

eval(js);

const fail = [];

// 守卫：ACTIONS 列表与 PRESETS 实现必须一一对应（v1.1 就是因为少了这一步把选项漏掉）
const actionsSrc = js.match(/const ACTIONS = \[([\s\S]*?)\];/);
const presetsSrc = js.match(/const PRESETS = \{([\s\S]*?)\n\};/);
const actKeys = [...(actionsSrc ? actionsSrc[1] : '').matchAll(/\['([a-z_]+)'/g)].map(m => m[1]);
const preKeys = [...(presetsSrc ? presetsSrc[1] : '').matchAll(/^\s{2}([a-z_]+):/gm)].map(m => m[1]);
for (const k of actKeys) if (!preKeys.includes(k)) fail.push('ACTIONS 里的「' + k + '」没有 PRESETS 实现');
for (const k of preKeys) if (!actKeys.includes(k)) fail.push('PRESETS 里的「' + k + '」没出现在下拉菜单（用户选不到）');
if (!actKeys.length || !preKeys.length) fail.push('守卫未能解析出动作列表/实现表');

const need = (cond, msg) => { if (!cond) fail.push(msg); };
setTimeout(() => {
  // 1) 解析默认配置后重建，必须与原文一致（含动作码、阈值、锁屏开关）
  const rebuilt = els['cfg'].textContent;
  for (const line of DEFAULT_CFG.trim().split('\n')) {
    const key = line.split(' ')[0];
    const got = rebuilt.split('\n').find(l => l.startsWith(key + ' '));
    need(got !== undefined && got.trim() === line.trim(), `rebuild mismatch: want「${line.trim()}」 got「${got && got.trim()}」`);
  }
  need((rebuilt.split('\n').find(l => l.startsWith('TAP_MAX_MS ')) || '').trim() === 'TAP_MAX_MS 800',
       'rebuild 缺 TAP_MAX_MS 800: ' + rebuilt.split('\n').find(l => l.startsWith('TAP_MAX_MS ')));
  // 2) 改参数 + 换动作为「打开应用」，保存后检查真正写出的 base64 内容
  els['tapMaxMs'].value = '700';
  els['holdMs'].value = '1500';
  els['maxHoldMs'].value = '3500';
  els['doubleMs'].value = '350';
  els['save'].onclick();
  setTimeout(() => {
    need(writes.length === 1, 'save did not write config (' + writes.length + ')');
    if (writes.length) {
      const b64 = writes[0].split(' ')[1];
      const txt = Buffer.from(b64, 'base64').toString('utf8');
      const get = k => (txt.split('\n').find(l => l.startsWith(k + ' ')) || '').slice(k.length + 1);
      need(get('HOLD_MS') === '1500', 'HOLD_MS not saved: ' + get('HOLD_MS'));
      need(get('TAP_MAX_MS') === '700', 'TAP_MAX_MS not saved: ' + get('TAP_MAX_MS'));
      need(get('MAX_HOLD_MS') === '3500', 'MAX_HOLD_MS not saved: ' + get('MAX_HOLD_MS'));
      need(get('DOUBLE_MS') === '350', 'DOUBLE_MS not saved: ' + get('DOUBLE_MS'));
      need(get('TAP_CMD') === 'input keyevent 120', 'TAP_CMD lost: ' + get('TAP_CMD'));
      need(get('HOLD_CMD').startsWith('am start-foreground-service'), 'HOLD_CMD lost: ' + get('HOLD_CMD'));
      need(get('DOUBLE_LOCKED') === '1', 'DOUBLE_LOCKED lost: ' + get('DOUBLE_LOCKED'));
      need(get('NATIVE_DOUBLE') === 'torch', 'NATIVE_DOUBLE should stay torch when double=none');
    }
    console.log(fail.length ? 'FAIL\n' + fail.join('\n') : 'webui selftest: ok (parse/rebuild/save all consistent)');
    process.exit(fail.length ? 1 : 0);
  }, 50);
}, 50);
