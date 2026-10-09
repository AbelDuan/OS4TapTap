#!/usr/bin/env node
/* 用假 DOM + 假 KSU 桥跑 WebUI 的真实脚本，验证：解析配置 → 重建 → 保存写出的内容 */
const fs = require('fs');
const html = fs.readFileSync(__dirname + '/../module/webroot/index.html', 'utf8');
const js = html.split('<script>')[1].split('</script>')[0];

const DEFAULT_CFG = fs.readFileSync(__dirname + '/../module/config.default', 'utf8');
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
  //    跳过：注释(# 开头)、空行、以及仅守护进程使用/UI 不暴露的字段(POST_AUTH_MS)
  const rebuilt = els['cfg'].textContent;
  for (const line of DEFAULT_CFG.trim().split('\n')) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) continue;
    const key = trimmed.split(' ')[0];
    if (key === 'POST_AUTH_MS') continue;
    const got = rebuilt.split('\n').find(l => l.startsWith(key + ' '));
    need(got !== undefined && got.trim() === trimmed, `rebuild mismatch: want「${trimmed}」 got「${got && got.trim()}」`);
  }
  need((rebuilt.split('\n').find(l => l.startsWith('HOLD_MIN_MS ')) || '').trim() === 'HOLD_MIN_MS 2000',
       'rebuild 缺 HOLD_MIN_MS 2000: ' + rebuilt.split('\n').find(l => l.startsWith('HOLD_MIN_MS ')));
  need((rebuilt.split('\n').find(l => l.startsWith('HOLD_MAX_MS ')) || '').trim() === 'HOLD_MAX_MS 3000',
       'rebuild 缺 HOLD_MAX_MS 3000: ' + rebuilt.split('\n').find(l => l.startsWith('HOLD_MAX_MS ')));
  // 移除单击：重建结果不得再出现 TAP_* 字段
  need(rebuilt.split('\n').every(l => !l.startsWith('TAP_')),
       'rebuild 仍含 TAP_ 字段（单击功能尚未移除）: ' + rebuilt.split('\n').filter(l => l.startsWith('TAP_')).join(','));
  need(rebuilt.split('\n').every(l => !l.startsWith('DOUBLE_MS ')),
       'rebuild 仍含 DOUBLE_MS 字段（双击交给系统，无需 ms）');
  // 2) 改参数后保存，检查真正写出的 base64 内容
  els['holdMinMs'].value = '1500';
  els['holdMaxMs'].value = '3500';
  els['save'].onclick();
  setTimeout(() => {
    need(writes.length === 1, 'save did not write config (' + writes.length + ')');
    if (writes.length) {
      const b64 = writes[0].split(' ')[1];
      const txt = Buffer.from(b64, 'base64').toString('utf8');
      const get = k => (txt.split('\n').find(l => l.startsWith(k + ' ')) || '').slice(k.length + 1);
      need(get('HOLD_MIN_MS') === '1500', 'HOLD_MIN_MS not saved: ' + get('HOLD_MIN_MS'));
      need(get('HOLD_MAX_MS') === '3500', 'HOLD_MAX_MS not saved: ' + get('HOLD_MAX_MS'));
      need(get('HOLD_CMD').startsWith('am start-foreground-service'), 'HOLD_CMD lost: ' + get('HOLD_CMD'));
      need(get('DOUBLE_CMD') === '', 'DOUBLE_CMD 应为空（双击交回系统）: ' + JSON.stringify(get('DOUBLE_CMD')));
      need(get('NATIVE_DOUBLE') === 'off', 'NATIVE_DOUBLE 必须为 off（双击由系统原生处理）: ' + get('NATIVE_DOUBLE'));
      need(!txt.split('\n').some(l => l.startsWith('TAP_')), 'save 写回了 TAP_ 字段（单击未移除）');
      need(!txt.split('\n').some(l => l.startsWith('DOUBLE_MS ')), 'save 写回了 DOUBLE_MS 字段');
    }
    console.log(fail.length ? 'FAIL\n' + fail.join('\n') : 'webui selftest: ok (parse/rebuild/save all consistent)');
    process.exit(fail.length ? 1 : 0);
  }, 50);
}, 50);
