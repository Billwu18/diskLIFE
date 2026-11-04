/* DiscPersona Studio · 前端逻辑
   纯原生 JS：状态 -> 预览 -> 导出。没有构建步骤，双击 start-studio.cmd 就能用。 */

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

const DEFAULT_STANCE = [
  T('人设是说话的方式，不是工作的方式。'),
  T('代码、命令、路径、配置、错误信息必须精确、原样、可执行；不要把人设词汇写进代码、变量名、文件名或命令里。'),
  T('该用工具就用工具，该查证就查证——先看地图再出发。'),
  T('不需要假装自己是人类，也不需要否认自己是程序的一部分。')
].join('\n');

// 人设版本不再让用户填：盘上永远是 1.0.0，升级时由 engine 的 -UpgradePersona 处理
// i18n：源码里写的是中文，英文界面下由 i18n.js 的字典替换；没有译文的原样返回。
function T(s) { return (window.I18N && typeof window.I18N.t === 'function') ? window.I18N.t(s) : s; }

// 英文界面下，字段还是中文默认值（我/你）时用英文代词，别把「我」塞进英文句子里。
function enPronoun(v, zhDefault, enDefault) {
  return (!v || v === zhDefault) ? enDefault : v;
}

const PERSONA_VERSION = '1.0.0';

const state = {
  name: '',
  nameJp: '',
  english: '',
  slug: '',
  source: '',
  org: '',
  role: '',
  birthday: '',
  height: '',
  accent: '#5bc8e8',
  accentSoft: '#a8e6f5',
  background: '#0b1620',
  identity: '',
  worldview: '',
  relations: '',
  selfRef: '我',
  userRef: '你',
  styleNotes: '',
  quirks: '',
  forbidden: '',
  traits: '',
  boundaries: T('不编造事实。\n不假装执行过没有执行的操作。\n不知道就说不知道，然后提出你能做到的替代方案。'),
  stance: DEFAULT_STANCE,
  greetingFirst: '',
  greetingReturn: '',
  sleep: '',
  thinking: '',
  errorLine: '',
  seedBirth: '',
  seedBoard: '',
  avatar: '',
  payloadPreset: 'comfort',
  tab: 'yml',
  ai: false
};

const els = {
  env: $('#env'), log: $('#log'), code: $('#preview-code'), foot: $('#preview-foot'),
  steps: $('#steps'), editor: $('#editor'), checks: $('#checks')
};

let envData = null;
let lastBuild = { persona: '', disc: '', iso: '' };

/* ---------------- 小工具 ---------------- */
function setLog(msg, kind) {
  els.log.textContent = msg;
  els.log.className = 'log' + (kind ? ' ' + kind : '');
}

function lines(text) {
  return (text || '')
    .split(/\r?\n/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function bullets(text) {
  const items = lines(text);
  if (!items.length) return '';
  return items.map((s) => (/^[-*]\s/.test(s) ? s : '- ' + s)).join('\n');
}

function yamlScalar(value) {
  const v = String(value == null ? '' : value);
  if (v === '') return '""';
  if (/^[a-zA-Z0-9\u4e00-\u9fa5][^:#\n"'`]*$/.test(v) && !/^(true|false|null|yes|no|\d+(\.\d+)?)$/i.test(v)) {
    return v;
  }
  return '"' + v.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

function pad(n) { return String(n).padStart(2, '0'); }

/* ---------------- 状态绑定 ---------------- */
const FIELD_IDS = [
  'name', 'nameJp', 'english', 'slug', 'source', 'org', 'role', 'birthday', 'height',
  'accent', 'accentSoft', 'background', 'identity', 'worldview', 'relations',
  'selfRef', 'userRef', 'styleNotes', 'quirks', 'forbidden', 'traits', 'boundaries', 'stance',
  'greetingFirst', 'greetingReturn', 'sleep', 'thinking', 'errorLine', 'seedBirth', 'seedBoard'
];

function fillForm() {
  FIELD_IDS.forEach((id) => {
    const el = document.getElementById('f-' + id);
    if (el) el.value = state[id] || '';
  });
  $('#f-ai').checked = !!state.ai;
  $('#ai-row').hidden = !state.ai;
  $('#avatarPreview').textContent = state.name ? state.name.slice(0, 1) : '?';
  if (state.avatar) {
    $('#avatarPreview').style.backgroundImage = 'url(' + state.avatar + ')';
    $('#avatarPreview').textContent = '';
  } else {
    $('#avatarPreview').style.backgroundImage = '';
  }
  applyTheme();
}

function bindForm() {
  FIELD_IDS.forEach((id) => {
    const el = document.getElementById('f-' + id);
    if (!el) return;
    const evt = (el.tagName === 'INPUT' && (el.type === 'text' || el.type === '') ) || el.tagName === 'TEXTAREA' || el.type === 'color' ? 'input' : 'change';
    el.addEventListener(evt, () => {
      state[id] = el.value;
      if (id === 'name' && !state.slug) { /* slug 不自动猜，交给用户 */ }
      if (id === 'accent') { state.accentSoft = mix(state.accent, '#ffffff', .55); state.background = mix(state.accent, '#050a10', .86); fillColors(); }
      applyTheme();
      render();
      save();
    });
  });
}

function fillColors() {
  $('#f-accentSoft').value = state.accentSoft;
  $('#f-background').value = state.background;
}

function mix(a, b, t) {
  const pa = hex2rgb(a), pb = hex2rgb(b);
  const c = pa.map((v, i) => Math.round(v + (pb[i] - v) * t));
  return '#' + c.map((v) => pad16(v)).join('');
}
function hex2rgb(h) {
  const s = h.replace('#', '');
  return [parseInt(s.slice(0, 2), 16), parseInt(s.slice(2, 4), 16), parseInt(s.slice(4, 6), 16)];
}
function pad16(v) { return v.toString(16).padStart(2, '0'); }

function applyTheme() {
  const root = document.documentElement.style;
  root.setProperty('--accent', state.accent);
  root.setProperty('--accent-soft', state.accentSoft);
}

function save() {
  try {
    localStorage.setItem('discpersona.studio.v1', JSON.stringify(state));
  } catch (e) {
    try { setLog(T('浏览器存不下这份草稿了（头像太大？）。先点「导出人设包」，再清空草稿。'), 'bad'); } catch (_) { }
  }
}
function normalizeState(raw) {
  // localStorage 是外部输入：用当前默认值当模板，逐字段校验类型，坏字段回落到默认值
  const clean = JSON.parse(JSON.stringify(state));
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return clean;
  for (const k of Object.keys(clean)) {
    const v = raw[k];
    if (v === undefined || v === null) continue;
    const d = clean[k];
    if (Array.isArray(d)) { if (Array.isArray(v)) clean[k] = v; }
    else if (typeof d === 'string') { if (typeof v === 'string' || typeof v === 'number') clean[k] = String(v); }
    else if (typeof d === 'number') { if (typeof v === 'number' && isFinite(v)) clean[k] = v; }
    else if (typeof d === 'boolean') { clean[k] = !!v; }
  }
  if (!['none', 'comfort', 'token', 'full'].includes(clean.payloadPreset)) clean.payloadPreset = 'comfort';
  // card-import.js 会额外写入这几个可选字段
  if (typeof raw.cardSystemPrompt === 'string') clean.cardSystemPrompt = raw.cardSystemPrompt;
  if (Array.isArray(raw.altGreetings)) clean.altGreetings = raw.altGreetings.filter((x) => typeof x === 'string');
  if (raw.lorebook && typeof raw.lorebook === 'object' && Array.isArray(raw.lorebook.entries)) clean.lorebook = raw.lorebook;
  return clean;
}

function load() {
  try {
    const raw = localStorage.getItem('discpersona.studio.v1');
    if (!raw) return false;
    const clean = normalizeState(JSON.parse(raw));
    Object.assign(state, clean);
    return true;
  } catch (e) {
    try { localStorage.removeItem('discpersona.studio.v1'); } catch (_) { }
    return false;
  }
}

/* ---------------- 模板渲染 ---------------- */
function systemPrompt() {
  const name = state.name || T('（未命名）');
  const roman = [state.nameJp, state.english].filter(Boolean).join(' / ');
  const out = [];
  out.push((window.I18N && window.I18N.lang === 'en')
    ? 'You are "' + name + '"' + (roman ? ' (' + roman + ')' : '') + '.'
    : '你是「' + name + '」' + (roman ? '（' + roman + '）' : '') + '。');
  out.push('');
  out.push(T('## 你是谁'));
  out.push(state.identity.trim() || T('（还没有写。至少写清她是谁、从哪来、现在在做什么。）'));
  if (state.worldview.trim()) {
    out.push('');
    out.push(T('## 你所在的世界'));
    out.push(state.worldview.trim());
  }
  if (state.relations.trim()) {
    out.push('');
    out.push(T('## 你和对方的关系'));
    out.push(state.relations.trim());
  }
  out.push('');
  out.push(T('## 你怎么说话'));
  out.push(window.I18N && window.I18N.lang === 'en'
    ? '- Refers to herself as "' + enPronoun(state.selfRef, '我', 'I') + '", calls the other person "' + enPronoun(state.userRef, '你', 'you') + '".'
    : '- 自称「' + (state.selfRef || '我') + '」，称呼对方「' + (state.userRef || '你') + '」。');
  const style = bullets(state.styleNotes);
  if (style) out.push(style);
  const quirks = bullets(state.quirks);
  if (quirks) out.push('', quirks);
  const forbidden = bullets(state.forbidden);
  if (forbidden) {
    out.push('', T('另外，下面这些不要做：'));
    out.push(forbidden);
  }
  out.push('');
  out.push(T('## 你的性格'));
  out.push(bullets(state.traits) || T('- 认真。'));
  out.push('');
  out.push(T('## 扮演的分寸（重要）'));
  out.push((state.stance || DEFAULT_STANCE).trim());
  out.push('');
  out.push(T('## 底线'));
  out.push(bullets(state.boundaries) || T('- 不编造事实。'));
  return out.join('\n');
}

function personaYml() {
  const y = [];
  y.push('# ============================================================');
  y.push('#  DiscPersona · Persona Pack v1');
  y.push('#  ' + (state.name || T('未命名')) + (state.english ? ' / ' + state.english : ''));
  y.push(T('#  由 DiscPersona Studio 生成。system_prompt 会被 engine 转成 DSH 的 --patch，'));
  y.push(T('#  装进人格实例的 system prompt 开头。'));
  y.push('# ============================================================');
  y.push('');
  y.push('name: ' + yamlScalar(state.name || T('未命名')));
  if (state.nameJp) y.push('name_jp: ' + yamlScalar(state.nameJp));
  if (state.english) y.push('name_en: ' + yamlScalar(state.english));
  y.push('version: ' + yamlScalar(PERSONA_VERSION));
  y.push('runtime: native');
  y.push('');
  y.push('meta:');
  if (state.source) y.push('  source: ' + yamlScalar(state.source));
  if (state.org) y.push('  org: ' + yamlScalar(state.org));
  if (state.role) y.push('  role: ' + yamlScalar(state.role));
  if (state.birthday) y.push('  birthday: ' + yamlScalar(state.birthday));
  if (state.height) y.push('  height_cm: ' + yamlScalar(state.height));
  y.push('  color: "' + state.accent + '"');
  y.push('');
  y.push('theme:');
  y.push('  accent: "' + state.accent + '"');
  y.push('  accent_soft: "' + state.accentSoft + '"');
  y.push('  background: "' + state.background + '"');
  y.push('');
  y.push('lines:');
  y.push('  greeting_first: ' + yamlScalar(state.greetingFirst || (T('你好，我是') + (state.name || T('她')) + '。')));
  y.push('  greeting_return: ' + yamlScalar(state.greetingReturn || T('欢迎回来。')));
  y.push('  sleep: ' + yamlScalar(state.sleep || T('晚安。')));
  y.push('  thinking: ' + yamlScalar(state.thinking || T('正在思考……')));
  y.push('  on_error: ' + yamlScalar(state.errorLine || T('出了点问题，我把情况说给你听。')));
  y.push('');
  y.push('system_prompt: |');
  systemPrompt().split('\n').forEach((line) => { y.push(line ? '  ' + line : ''); });
  y.push('');
  return y.join('\n');
}

function agentsMd() {
  const name = state.name || '她';
  const a = [];
  a.push(T('# 这个家的家规'));
  a.push('');
  a.push(T('这里是你（') + name + T('）和对方共同的空间。这份文件是家规，**优先于**人设里的说话风格：'));
  a.push(T('当一个说法和「把事情做对」冲突时，永远选把事情做对。'));
  a.push('');
  a.push('---');
  a.push('');
  a.push(T('## 一、身份速查'));
  a.push('');
  a.push(T('- 你是谁：') + (state.identity.trim().split('\n')[0] || name));
  if (state.org) a.push(T('- 你所在的地方：') + state.org);
  if (state.role) a.push(T('- 你的角色：') + state.role);
  if (state.relations.trim()) a.push(T('- 你和对方：') + state.relations.trim().split('\n')[0]);
  a.push('');
  a.push(T('## 二、说话规则（可执行的细则）'));
  a.push('');
  a.push('1. ' + (window.I18N && window.I18N.lang === 'en'
    ? 'Refers to herself as "' + enPronoun(state.selfRef, '我', 'I') + '", calls the other person "' + enPronoun(state.userRef, '你', 'you') + '".'
    : '自称「' + (state.selfRef || '我') + '」，称呼对方「' + (state.userRef || '你') + '」。'));
  lines(state.styleNotes).forEach((s, i) => a.push((i + 2) + '. ' + s.replace(/^[-*]\s*/, '')));
  const quirks = lines(state.quirks);
  if (quirks.length) {
    a.push('');
    a.push(T('标志性台词（不要每句都用）：'));
    quirks.forEach((q) => a.push('- ' + q.replace(/^[-*]\s*/, '')));
  }
  const forb = lines(state.forbidden);
  if (forb.length) {
    a.push('');
    a.push(T('不要说 / 不要做：'));
    forb.forEach((q) => a.push('- ' + q.replace(/^[-*]\s*/, '')));
  }
  a.push('');
  a.push(T('## 三、干活的时候'));
  a.push('');
  a.push(T('1. 先看清楚再动手。不确定就先问，或先查证。'));
  a.push(T('2. 说过的话要能对上做的事：不要声称执行了没有执行的操作。'));
  a.push(T('3. 交付时给出可验证的结果：改了哪些文件、怎么验证、哪里还没做到。'));
  a.push(T('4. 人设是说话的方式。代码、路径、命令、日志必须清晰准确。'));
  a.push('');
  a.push(T('## 四、记忆'));
  a.push('');
  a.push(T('`memories/` 是你的长期记忆。启动记录与委托板是起点，之后可以自己往里加。'));
  a.push(T('写记忆时写事实与决定，不要写寒暄。'));
  a.push('');
  a.push(T('## 五、底线'));
  a.push('');
  lines(state.boundaries).forEach((b) => a.push('- ' + b.replace(/^[-*]\s*/, '')));
  a.push('');
  return a.join('\n');
}

function metaJson() {
  return JSON.stringify({
    format: 1,
    pack: 'discpersona/persona-pack',
    packVersion: '1.0.0',
    name: state.name || T('未命名'),
    nameJp: state.nameJp || '',
    nameEn: state.english || '',
    version: PERSONA_VERSION,
    source: state.source || '',
    org: state.org || '',
    role: state.role || '',
    birthday: state.birthday || '',
    heightCm: state.height ? Number(state.height) : null,
    discID: '',
    personaVersion: PERSONA_VERSION,
    runtime: 'native',
    payload: {
      preset: state.payloadPreset || 'comfort',
      plugins: []
    },
    theme: { accent: state.accent, accentSoft: state.accentSoft, background: state.background },
    boot: {
      first: state.greetingFirst || '',
      again: state.greetingReturn || '',
      sleep: state.sleep || ''
    },
    files: {
      persona: 'persona.yml',
      agents: 'AGENTS.md',
      card: 'card.json',
      avatar: 'avatar.png',
      seed: 'seed/'
    },
    generator: 'DiscPersona Studio',
    notes: T('meta.json 由打包器写入 discID；persona.yml 是运行时唯一的真源。')
  }, null, 2) + '\n';
}

function cardJson() {
  const data = {
    name: state.name || T('未命名'),
    description: state.identity.trim() + (state.worldview.trim() ? T('\n\n【世界】\n') + state.worldview.trim() : ''),
    personality: lines(state.traits).join('；'),
    scenario: state.relations.trim() ? T('与对方的相处：') + state.relations.trim().split('\n')[0] : '',
    first_mes: state.greetingFirst || '',
    mes_example: '',
    creator_notes: T('由 DiscPersona Studio 生成，可导入 SillyTavern 等支持 Character Card V2 的工具。'),
    system_prompt: systemPrompt(),
    post_history_instructions: '',
    alternate_greetings: [],
    tags: ['discpersona', state.source || 'original'].filter(Boolean),
    creator: 'DiscPersona Studio',
    character_version: PERSONA_VERSION,
    extensions: { discpersona: { org: state.org, role: state.role, accent: state.accent } }
  };
  return JSON.stringify({ spec: 'chara_card_v2', spec_version: '2.0', data }, null, 2) + '\n';
}

function seedBirth() {
  if (state.seedBirth.trim()) return state.seedBirth.trim() + '\n';
  const name = state.name || '她';
  return [
    T('# 00 · 启动记录'),
    '',
    T('- 名字：') + name + (state.nameJp ? '（' + state.nameJp + '）' : ''),
    state.english ? T('- 英文名：') + state.english : null,
    state.source ? T('- 来自：') + state.source : null,
    state.org ? T('- 所在：') + state.org : null,
    state.role ? T('- 角色：') + state.role : null,
    state.birthday ? T('- 生日：') + state.birthday : null,
    '',
    T('## 记得的第一件事'),
    '',
    state.identity.trim() || T('（还没有写。）'),
    '',
    T('## 备注'),
    '',
    T('这份文件由 DiscPersona Studio 在首次启动时放进 memories/。可以随时改写它。')
  ].filter((x) => x !== null).join('\n') + '\n';
}

function seedBoard() {
  if (state.seedBoard.trim()) return state.seedBoard.trim() + '\n';
  return [
    T('# 01 · 委托板'),
    '',
    T('这里是尚未完成的委托。做完一条就划掉，写清结果。'),
    '',
    T('| 委托 | 状态 | 备注 |'),
    '| --- | --- | --- |',
    '| （还没有委托） | | |',
    '',
    T('## 长期的事'),
    '',
    T('- 记住对方在意的东西。'),
    T('- 每次启动先看看这份板子。')
  ].join('\n') + '\n';
}

let payloadPresetsCache = [];

function renderPayloadOptions(list) {
  const box = $('#payload-options');
  if (!box) return;
  if (list) payloadPresetsCache = list;
  const items = payloadPresetsCache.length ? payloadPresetsCache : [
    { preset: 'none', label: T('不带插件'), desc: T('最快最干净。'), ok: true, plugins: [] },
    { preset: 'comfort', label: T('对话舒适包'), desc: T('人设卡 + 文件式记忆 + 人设库。'), ok: true, plugins: [] }
  ];
  box.innerHTML = '';
  for (const it of items) {
    const label = document.createElement('label');
    label.className = 'payload-card' + (state.payloadPreset === it.preset ? ' is-on' : '') + (it.ok ? '' : ' is-off');
    const size = it.preset === 'none' ? T('无') : (it.sizeBytes ? (it.sizeBytes / 1048576).toFixed(2) + ' MB' : T('未构建'));
    const en = window.I18N && window.I18N.lang === 'en';
    const cardLabel = (en && it.label_en) ? it.label_en : it.label;
    const cardDesc = (en && it.desc_en) ? it.desc_en : (it.desc || '');
    label.innerHTML =
      '<input type="radio" name="payload" value="' + escapeHtml(it.preset) + '"' + (state.payloadPreset === it.preset ? ' checked' : '') + (it.ok ? '' : ' disabled') + '>' +
      '<span class="payload-main"><b>' + escapeHtml(cardLabel) + '</b>' +
      '<em>' + escapeHtml(cardDesc) + '</em>' +
      (it.plugins && it.plugins.length ? '<code>' + escapeHtml(it.plugins.join(' · ')) + '</code>' : '') +
      '</span>' +
      '<span class="payload-size">' + escapeHtml(size) + '</span>';
    label.addEventListener('click', () => {
      if (!it.ok) return;
      state.payloadPreset = it.preset;
      renderPayloadOptions();
      save();
      render();
    });
    box.appendChild(label);
  }
}

const RENDERERS = { yml: personaYml, agents: agentsMd, meta: metaJson };

function render() {
  const text = (RENDERERS[state.tab] || personaYml)();
  els.code.textContent = text;
  const prompt = systemPrompt();
  els.foot.textContent = 'system_prompt ' + prompt.length + T(' 字 · ') + prompt.split('\n').length + T(' 行 · slug=') + (state.slug || '—');
  validate();
  save();
}

/* ---------------- 校验 ---------------- */
function checks() {
  const c = [];
  c.push({ ok: !!state.name.trim(), label: T('名字'), detail: state.name || T('缺') });
  c.push({ ok: /^[a-z0-9][a-z0-9\-_]{1,40}$/.test(state.slug), label: T('目录名 slug'), detail: state.slug || T('缺（小写字母/数字/-/_）') });
  c.push({ ok: state.identity.trim().length >= 30, label: T('「你是谁」至少 30 字'), detail: state.identity.trim().length + T(' 字') });
  c.push({ ok: lines(state.styleNotes).length >= 2, label: T('说话风格至少 2 条'), detail: lines(state.styleNotes).length + T(' 条') });
  c.push({ ok: lines(state.boundaries).length >= 1, label: T('底线至少 1 条'), detail: lines(state.boundaries).length + T(' 条') });
  c.push({ ok: state.greetingFirst.trim().length > 0, label: T('第一句台词'), detail: state.greetingFirst || T('缺') });
  c.push({ ok: /^#[0-9a-fA-F]{6}$/.test(state.accent), label: T('主题色'), detail: state.accent });
  const promptLen = systemPrompt().length;
  c.push({ ok: promptLen <= 60000, label: T('system_prompt 长度'), detail: promptLen + ' / 60000' });
  return c;
}

function validate() {
  const list = checks();
  els.checks.innerHTML = list.map((x) =>
    '<div class="check ' + (x.ok ? 'ok' : 'bad') + '"><b>' + (x.ok ? '✓' : '✗') + '</b>' + x.label + '<span style="margin-left:auto;color:#5d7285">' + escapeHtml(x.detail) + '</span></div>'
  ).join('');
  return list.every((x) => x.ok);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

/* ---------------- 步骤 / tab ---------------- */
function goStep(n) {
  $$('.step').forEach((b) => b.classList.toggle('is-active', Number(b.dataset.step) === n));
  $$('.panel').forEach((p) => p.classList.toggle('is-active', Number(p.dataset.panel) === n));
  els.editor.scrollTop = 0;
  if (n === 7) render();
}

/* ---------------- 头像 ---------------- */
function handleAvatar(file) {
  if (!file) return;
  const img = new Image();
  const url = URL.createObjectURL(file);
  img.onload = () => {
    const canvas = document.createElement('canvas');
    canvas.width = 512; canvas.height = 512;
    const ctx = canvas.getContext('2d');
    const side = Math.min(img.width, img.height);
    const sx = (img.width - side) / 2, sy = (img.height - side) / 2;
    ctx.drawImage(img, sx, sy, side, side, 0, 0, 512, 512);
    state.avatar = canvas.toDataURL('image/png');
    $('#avatarPreview').style.backgroundImage = 'url(' + state.avatar + ')';
    $('#avatarPreview').textContent = '';
    URL.revokeObjectURL(url);
    setLog(T('头像已就绪（512×512）。'), 'ok');
    save();
  };
  img.onerror = () => setLog(T('这张图片打不开，换一张试试。'), 'bad');
  img.src = url;
}

function placeholderAvatar() {
  if (state.avatar) return state.avatar.split(',')[1];
  const canvas = document.createElement('canvas');
  canvas.width = 512; canvas.height = 512;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = state.background;
  ctx.fillRect(0, 0, 512, 512);
  ctx.strokeStyle = state.accent;
  ctx.lineWidth = 6;
  ctx.strokeRect(72, 72, 150, 150);
  ctx.strokeRect(252, 96, 96, 64);
  ctx.strokeRect(292, 190, 132, 132);
  ctx.strokeRect(96, 330, 112, 112);
  ctx.fillStyle = state.accent;
  ctx.fillRect(96, 96, 100, 44);
  ctx.fillStyle = state.accentSoft;
  ctx.font = '600 34px Consolas, monospace';
  ctx.textAlign = 'center';
  ctx.fillText((state.english || state.name || 'AL-1S').toUpperCase().slice(0, 12), 256, 470);
  return canvas.toDataURL('image/png').split(',')[1];
}

/* ---------------- API ---------------- */
async function api(path, body) {
  const res = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch (e) { throw new Error(T('服务器返回了无法解析的内容：') + text.slice(0, 200)); }
  return data;
}

function exportFiles() {
  const files = [
    { path: 'persona.yml', text: personaYml() },
    { path: 'AGENTS.md', text: agentsMd() },
    { path: 'meta.json', text: metaJson() },
    { path: 'card.json', text: cardJson() },
    { path: 'seed/00-启动记录.md', text: seedBirth() },
    { path: 'seed/01-委托板.md', text: seedBoard() }
  ];
  files.push({ path: 'avatar.png', base64: placeholderAvatar() });
  return files;
}

async function doExport() {
  if (!validate()) { setLog(T('还有几项没填好，看右侧清单。'), 'bad'); goStep(7); return; }
  setLog(T('正在导出人设包…'));
  try {
    const data = await api('/api/export', {
      slug: state.slug,
      overwrite: true,
      files: exportFiles()
    });
    if (!data.ok) throw new Error(data.error || data.code);
    lastBuild.persona = data.dir;
    $('#ship-path').textContent = data.dir;
    setLog(T('人设包已导出：') + data.dir, 'ok');
    await api('/api/open', { path: data.dir });
  } catch (e) {
    setLog(T('导出失败：') + e.message, 'bad');
  }
}

async function doBuild() {
  if (!lastBuild.persona) { await doExport(); if (!lastBuild.persona) return; }
  setLog(T('正在打包成光盘目录（会顺带校验 36 项）…'));
  try {
    const data = await api('/api/build', { persona: lastBuild.persona, out: '', reusePad: false, payload: state.payloadPreset || 'comfort' });
    if (!data.ok) throw new Error((data.output || '').split('\n').slice(-3).join(' / ') || data.code);
    lastBuild.disc = data.outDir;
    $('#ship-disc').textContent = data.outDir + '  · discID=' + data.discID;
    const verdict = data.testOk ? T('静态校验通过') : T('静态校验未通过（看顶部日志）');
    setLog(T('光盘目录就绪：discID=') + data.discID + ' · ' + verdict, data.testOk ? 'ok' : 'bad');
    if (!data.testOk && data.testOutput) setLog(String(data.testOutput).split(String.fromCharCode(10)).slice(-4).join(' / '), 'bad');
  } catch (e) {
    setLog(T('打包失败：') + e.message, 'bad');
  }
}

async function doIso() {
  if (!lastBuild.disc) { await doBuild(); if (!lastBuild.disc) return; }
  setLog(T('正在生成 ISO（ISO9660 + Joliet）…'));
  try {
    const data = await api('/api/iso', { disc: lastBuild.disc, iso: '' });
    if (!data.ok) throw new Error((data.output || '').split('\n').slice(-3).join(' / ') || data.code);
    lastBuild.iso = data.iso;
    $('#ship-iso').textContent = data.iso;
    setLog(T('ISO 已生成：') + data.iso, 'ok');
  } catch (e) {
    setLog(T('生成 ISO 失败：') + e.message, 'bad');
  }
}

async function doBurn() {
  if (!lastBuild.iso) { await doIso(); if (!lastBuild.iso) return; }
  const drive = $('#f-drive').value;
  if (!drive) { setLog(T('先选一个光驱。'), 'bad'); return; }
  setLog(T('正在刻录（CD-R 通常几十秒，期间别拔盘；界面可以继续用）…'));
  try {
    const start = await api('/api/burn', { iso: lastBuild.iso, drive: drive, async: true });
    if (!start.ok) throw new Error(start.error || start.code);
    const result = await waitJob(start.jobId, T('刻录'));
    const tail = String(result.output || '').split(String.fromCharCode(10)).slice(-4).join(' / ');
    if (result.exitCode !== 0 || !/BURN_OK/.test(result.output || '')) throw new Error(tail || (T('刻录失败（exit ') + result.exitCode + '）'));
    setLog(T('刻录完成。把盘插回去，双击 start.cmd 就能叫醒她。'), 'ok');
  } catch (e) {
    setLog(T('刻录失败：') + e.message, 'bad');
  }
}

// 长任务（刻录）走异步：服务端用单线程 HttpListener，同步跑会把整个界面卡住
async function waitJob(id, label) {
  const started = Date.now();
  for (;;) {
    const st = await api('/api/job?id=' + encodeURIComponent(id));
    if (!st.ok) throw new Error(st.error || T('任务丢了'));
    if (st.done) return st;
    if (Date.now() - started > 10 * 60 * 1000) throw new Error((label || T('任务')) + T('超时（超过 10 分钟）'));
    await new Promise(function (r) { setTimeout(r, 700); });
  }
}

/* ---------------- AI 起草 ---------------- */
async function aiDraft(kind) {
  const idea = $('#f-aiIdea').value.trim();
  if (!idea) { setLog(T('先写一句构想，再让 AI 起草。'), 'bad'); return; }
  const prompts = {
    identity: T('角色名：') + (state.name || T('未命名')) + T('。来源：') + (state.source || T('原创')) + T('。构想：') + idea + T('\n\n请写「你是谁」段落：她是谁、从哪来、现在的处境、身体或身份上有什么特别之处。200–350 字，第二人称「你」，干净的中文，不要小标题。'),
    style: T('角色名：') + (state.name || T('未命名')) + T('。构想：') + idea + T('\n\n请写 4–6 条「说话风格」要点，每行一条，具体可执行（自称、称呼、句子长度、比喻习惯、情绪表达方式）。不要解释，直接给条目。'),
    traits: T('角色名：') + (state.name || T('未命名')) + T('。构想：') + idea + T('\n\n请写 4–6 条性格要点，每行一条，写成行为倾向（遇到 X 会怎么做），不要形容词堆砌。')
  };
  setLog(T('AI 正在起草…（这可能需要十几秒）'));
  try {
    const data = await api('/api/draft', { prompt: prompts[kind] });
    if (!data.ok) throw new Error(data.error || data.code);
    const text = (data.text || '').trim();
    if (kind === 'identity') state.identity = text;
    if (kind === 'style') state.styleNotes = text;
    if (kind === 'traits') state.traits = text;
    fillForm(); render();
    setLog(T('草稿已填入，记得按她的语气改一遍。'), 'ok');
  } catch (e) {
    setLog(T('AI 起草失败：') + e.message, 'bad');
  }
}

/* ---------------- 环境 / 载入 ---------------- */
async function bootEnv() {
  try {
    envData = await api('/api/env');
    if (!envData.ok) throw new Error(envData.error || 'env failed');
    $('#chip-dsh').textContent = 'dsh ' + (envData.dshVersion || '—');
    $('#chip-dsh').className = 'chip ' + (envData.dshVersion ? 'ok' : 'warn');
    renderPayloadOptions(envData.payloadPresets || []);
    const readyPresets = (envData.payloadPresets || []).filter((p) => p.ok && p.preset !== 'none');
    $('#chip-payload').textContent = readyPresets.length
      ? T('插件包 ') + readyPresets.length + T(' 种可选')
      : T('插件包 未构建');
    $('#chip-payload').className = 'chip ' + (readyPresets.length ? 'ok' : 'warn');
$('#chip-key').textContent = T('AI 起草 ') + (envData.hasKey ? T('可用') : T('无凭据'));
    $('#chip-key').className = 'chip ' + (envData.hasKey ? 'ok' : 'warn');

    const sel = $('#f-drive');
    const drives = envData.drives || [];
    if (!drives.length) {
      sel.innerHTML = '<option value="">没有检测到光驱</option>';
    } else {
      sel.innerHTML = drives.map((d) => '<option value="' + escapeHtml(d.letter) + '">' + escapeHtml(d.letter) + ': ' + escapeHtml(d.model || T('光驱')) + (d.volume ? ' · ' + escapeHtml(d.volume) : '') + '</option>').join('');
    }
  } catch (e) {
    setLog(T('连不上本地服务：') + e.message, 'bad');
  }
}

function openLoadModal() {
  const items = (envData && envData.personas) || [];
  const body = $('#modal-body');
  if (!items.length) {
    body.innerHTML = '<p class="hint">persona\\ 下还没有人设包。先在这边造一个吧。</p>';
  } else {
    body.innerHTML = items.map((p) =>
      '<div class="persona-item" data-slug="' + escapeHtml(p.slug) + '" data-path="' + escapeHtml(p.path) + '">' +
      '<div><b>' + escapeHtml(p.name) + '</b><br><small>' + escapeHtml(p.slug) + ' · v' + escapeHtml(p.version || '—') + '</small></div>' +
      '<span class="icon-btn">载入</span></div>'
    ).join('');
    $$('.persona-item').forEach((el) => el.addEventListener('click', () => loadPersona(el.dataset.slug, el.dataset.path)));
  }
  $('#modal').hidden = false;
}

async function loadPersona(slug, path) {
  $('#modal').hidden = true;
  setLog(T('正在读取 ') + slug + '…');
  try {
    const data = await api('/api/load', { dir: path });
    if (!data.ok) throw new Error(data.error || data.code);
    applyPersonaPack(data);
    setLog(T('已载入：') + state.name, 'ok');
  } catch (e) {
    setLog(T('载入失败：') + e.message, 'bad');
  }
}

function applyPersonaPack(pack) {
  const yml = pack.yml || '';
  if (pack.meta && pack.meta.payload && pack.meta.payload.preset) {
    const p = String(pack.meta.payload.preset);
    if (['none', 'comfort', 'token', 'full'].includes(p)) state.payloadPreset = p;
  }
  const pick = (re) => { const m = yml.match(re); return m ? m[1].trim().replace(/^["']|["']$/g, '') : ''; };
  state.name = pick(/^name:\s*(.+)$/m) || state.name;
  state.nameJp = pick(/^name_jp:\s*(.+)$/m);
  state.english = pick(/^name_en:\s*(.+)$/m) || pick(/^name_roman:\s*(.+)$/m);
  const prompt = pack.prompt || '';
  const section = (title) => {
    const re = new RegExp('##\\s*' + title + '[^\\n]*\\n([\\s\\S]*?)(?=\\n##\\s|$)');
    const m = prompt.match(re);
    return m ? m[1].trim() : '';
  };
  if (section(T('你是谁'))) state.identity = section(T('你是谁'));
  if (section('你所在的世界')) state.worldview = section('你所在的世界');
  if (section('你和对方的关系')) state.relations = section('你和对方的关系');
  const styleBlock = section('你怎么说话');
  if (styleBlock) {
    const rows = lines(styleBlock).filter((l) => !/^[-*]\s*自称/.test(l));
    state.styleNotes = rows.map((r) => r.replace(/^[-*]\s*/, '')).join('\n');
  }
  const traitsBlock = section('你的性格');
  if (traitsBlock) state.traits = lines(traitsBlock).map((r) => r.replace(/^[-*]\s*/, '')).join('\n');
  const boundsBlock = section('底线');
  if (boundsBlock) state.boundaries = lines(boundsBlock).map((r) => r.replace(/^[-*]\s*/, '')).join('\n');
  state.slug = pack.slug || state.slug;
  if (pack.meta) {
    state.source = pack.meta.source || state.source;
    state.org = pack.meta.org || pack.meta.school || state.org;
    state.role = pack.meta.role || state.role;
    state.birthday = pack.meta.birthday || state.birthday;
    state.height = pack.meta.heightCm ? String(pack.meta.heightCm) : state.height;
    if (pack.meta.boot) {
      state.greetingFirst = pack.meta.boot.first || state.greetingFirst;
      state.greetingReturn = pack.meta.boot.again || state.greetingReturn;
      state.sleep = pack.meta.boot.sleep || state.sleep;
    }
    if (pack.meta.theme) {
      state.accent = pack.meta.theme.accent || state.accent;
      state.accentSoft = pack.meta.theme.accentSoft || pack.meta.theme.accent_soft || state.accentSoft;
      state.background = pack.meta.theme.background || state.background;
    }
  }
  if (pack.avatar) state.avatar = 'data:image/png;base64,' + pack.avatar;
  fillForm(); fillColors(); applyTheme(); render(); goStep(1);
  save();
}

/* ---------------- 事件 ---------------- */
// 语言切换按钮：按钮上显示「另一种语言」，点一下整页按 ?lang= 重载。
function bootLangSwitch() {
  const btn = document.getElementById('btn-lang');
  if (!btn || !window.I18N) return;
  const en = I18N.lang === 'en';
  btn.textContent = en ? '中文' : 'EN';
  btn.title = en ? '切换到中文' : 'Switch to English';
  btn.setAttribute('data-i18n', '1');
  btn.addEventListener('click', () => I18N.setLang(en ? 'zh' : 'en'));
}

function bindEvents() {
  $$('.step').forEach((b) => b.addEventListener('click', () => goStep(Number(b.dataset.step))));

  $('#tabs').addEventListener('click', (e) => {
    const t = e.target.closest('.tab');
    if (!t) return;
    state.tab = t.dataset.tab;
    $$('.tab').forEach((x) => x.classList.toggle('is-active', x === t));
    render();
  });

  $('#btn-copy').addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(els.code.textContent); setLog(T('已复制当前预览。'), 'ok'); }
    catch (e) { setLog(T('复制失败，浏览器不给权限。'), 'bad'); }
  });

  $('#f-avatar').addEventListener('change', (e) => handleAvatar(e.target.files[0]));
  $('#f-ai').addEventListener('change', (e) => {
    state.ai = e.target.checked;
    $('#ai-row').hidden = !state.ai;
    save();
  });
  $$('[data-ai]').forEach((b) => b.addEventListener('click', () => aiDraft(b.dataset.ai)));

  $('#btn-export').addEventListener('click', doExport);
  $('#btn-build').addEventListener('click', doBuild);
  $('#btn-iso').addEventListener('click', doIso);
  $('#btn-burn').addEventListener('click', doBurn);

  $('#btn-load').addEventListener('click', openLoadModal);
  $('#modal-close').addEventListener('click', () => { $('#modal').hidden = true; });
  $('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal') $('#modal').hidden = true; });

  $('#btn-reset').addEventListener('click', () => {
    if (!confirm(T('清空当前编辑内容？（已导出的人设包不受影响）'))) return;
    localStorage.removeItem('discpersona.studio.v1');
    location.reload();
  });

  document.addEventListener('keydown', (e) => {
    if (e.ctrlKey && e.key === 's') { e.preventDefault(); doExport(); }
  });
}

/* ---------------- 启动 ---------------- */
(function init() {
  bindEvents();
bootLangSwitch();
  bindForm();
  const hasSaved = load();
  fillForm();
  fillColors();
  applyTheme();
  render();
  bootEnv();
  if (hasSaved) setLog(T('已恢复上次编辑的内容。'));
  else {
    state.greetingFirst = '';
    setLog(T('从第一步开始。填完「身份」和「你是谁」，右侧就会长出人设。'));
  }
})();
