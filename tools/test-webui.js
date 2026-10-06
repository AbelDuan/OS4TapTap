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
const need = (cond, msg) => { if (!cond) fail.push(msg); };
setTimeout(() => {
  // 1) 解析默认配置后重建，必须与原文一致（含动作码、阈值、锁屏开关）
  const rebuilt = els['cfg'].textContent;
  for (const line of DEFAULT_CFG.trim().split('\n')) {
    const key = line.split(' ')[0];
    const got = rebuilt.split('\n').find(l => l.startsWith(key + ' '));
    need(got !== undefined && got.trim() === line.trim(), `rebuild mismatch: want「${line.trim()}」 got「${got && got.trim()}」`);
  }
  // 2) 改参数 + 换动作为「打开应用」，保存后检查真正写出的 base64 内容
  els['holdMs'].value = '2000';
  els['maxHoldMs'].value = '3500';
  els['doubleMs'].value = '350';
  els['save'].onclick();
  setTimeout(() => {
    need(writes.length === 1, 'save did not write config (' + writes.length + ')');
    if (writes.length) {
      const b64 = writes[0].split(' ')[1];
      const txt = Buffer.from(b64, 'base64').toString('utf8');
      const get = k => (txt.split('\n').find(l => l.startsWith(k + ' ')) || '').slice(k.length + 1);
      need(get('HOLD_MS') === '2000', 'HOLD_MS not saved: ' + get('HOLD_MS'));
      need(get('MAX_HOLD_MS') === '3500', 'MAX_HOLD_MS not saved: ' + get('MAX_HOLD_MS'));
      need(get('DOUBLE_MS') === '350', 'DOUBLE_MS not saved: ' + get('DOUBLE_MS'));
      need(get('TAP_CMD') === 'input keyevent 120', 'TAP_CMD lost: ' + get('TAP_CMD'));
      need(get('HOLD_CMD').startsWith('b=$(cat /sys/class/leds'), 'HOLD_CMD lost: ' + get('HOLD_CMD'));
      need(get('DOUBLE_LOCKED') === '1', 'DOUBLE_LOCKED lost: ' + get('DOUBLE_LOCKED'));
      need(get('NATIVE_DOUBLE') === 'torch', 'NATIVE_DOUBLE should stay torch when double=none');
    }
    console.log(fail.length ? 'FAIL\n' + fail.join('\n') : 'webui selftest: ok (parse/rebuild/save all consistent)');
    process.exit(fail.length ? 1 : 0);
  }, 50);
}, 50);
