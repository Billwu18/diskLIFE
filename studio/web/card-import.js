/* DiscPersona Studio · 角色卡导入
   ------------------------------------------------------------
   支持两类文件：
     · Character Card V2/V3 的 .png —— 数据藏在 PNG 的 tEXt/iTXt 块里，
       keyword 是 chara（V2，base64 的 JSON）或 ccv3（V3，同样 base64）
     · 直接给 .json（V1 平铺字段 / V2/V3 的 {spec, data} 都认）

   导入是「填充」，不是「覆盖」：只写有值的字段，其余保留你当前编辑的内容。
   导入后会记下原卡里 Studio 模板没有对应字段的东西（世界书、备选开场、
   原 system_prompt），导出时原样带回去，不丢信息。
   ------------------------------------------------------------ */

(function () {
  'use strict';

  const MAX_TEXT = 200000;

  /* ---------- PNG 文本块 ---------- */

  function u32(bytes, off) {
    return ((bytes[off] << 24) | (bytes[off + 1] << 16) | (bytes[off + 2] << 8) | bytes[off + 3]) >>> 0;
  }

  function latin1(bytes, start, end) {
    let s = '';
    for (let i = start; i < end; i++) s += String.fromCharCode(bytes[i]);
    return s;
  }

  function utf8(bytes, start, end) {
    try {
      return new TextDecoder('utf-8', { fatal: false }).decode(bytes.subarray(start, end));
    } catch (e) {
      return latin1(bytes, start, end);
    }
  }

  function readChunks(bytes) {
    const sig = [137, 80, 78, 71, 13, 10, 26, 10];
    for (let i = 0; i < 8; i++) if (bytes[i] !== sig[i]) throw new Error('这不是 PNG 文件。');
    const out = [];
    let off = 8;
    while (off + 12 <= bytes.length) {
      const len = u32(bytes, off);
      const type = latin1(bytes, off + 4, off + 8);
      const dataStart = off + 8;
      const dataEnd = dataStart + len;
      if (dataEnd + 4 > bytes.length) break;
      out.push({ type: type, start: dataStart, end: dataEnd });
      off = dataEnd + 4;
      if (type === 'IEND') break;
    }
    return out;
  }

  function decodeBase64(text) {
    const clean = text.replace(/[\s\r\n]+/g, '');
    const bin = atob(clean);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }

  function readTextKeyword(bytes, chunk) {
    // keyword\0 ...：tEXt 是 keyword\0text；iTXt 是 keyword\0 flag method lang\0 trans\0 text
    let i = chunk.start;
    while (i < chunk.end && bytes[i] !== 0) i++;
    if (i >= chunk.end) return null;
    const keyword = latin1(bytes, chunk.start, i).toLowerCase();
    let p = i + 1;
    if (chunk.type === 'iTXt') {
      const flag = bytes[p]; p += 2;
      while (p < chunk.end && bytes[p] !== 0) p++;  // language tag
      p++;
      while (p < chunk.end && bytes[p] !== 0) p++;  // translated keyword
      p++;
      if (flag === 1) return { keyword: keyword, text: '', compressed: true };
      return { keyword: keyword, text: utf8(bytes, p, chunk.end), compressed: false };
    }
    return { keyword: keyword, text: latin1(bytes, p, chunk.end), compressed: false };
  }

  function cardJsonFromPng(bytes) {
    const chunks = readChunks(bytes);
    const found = {};
    chunks.forEach((c) => {
      if (c.type !== 'tEXt' && c.type !== 'iTXt' && c.type !== 'zTXt') return;
      const kv = readTextKeyword(bytes, c);
      if (!kv) return;
      if (kv.compressed) return;                        // 压缩文本极少见，跳过并提示
      if (kv.keyword === 'ccv3' || kv.keyword === 'chara') found[kv.keyword] = kv.text;
    });
    const raw = found.ccv3 || found.chara;
    if (!raw) throw new Error('这张 PNG 里没有角色卡数据（找不到 chara / ccv3 文本块）。');
    const bytesJson = decodeBase64(raw);
    const text = utf8(bytesJson, 0, bytesJson.length).replace(/^\uFEFF/, '').trim();
    if (!text) throw new Error('角色卡数据是空的。');
    return JSON.parse(text);
  }

  /* ---------- 归一化 ---------- */

  // V2/V3: { spec, spec_version, data:{...} }；V1: 字段直接平铺
  function normalizeCard(obj) {
    if (!obj || typeof obj !== 'object') throw new Error('角色卡不是合法的 JSON 对象。');
    const isV2 = obj.data && typeof obj.data === 'object' && (obj.spec === 'chara_card_v2' || obj.spec === 'chara_card_v3' || obj.data.name);
    const d = isV2 ? obj.data : obj;
    if (!d.name && !d.description) throw new Error('角色卡里没有 name / description，认不出来。');
    return {
      spec: obj.spec || 'chara_card_v1',
      data: d,
      book: d.character_book || null,
      alt: Array.isArray(d.alternate_greetings) ? d.alternate_greetings.filter((s) => typeof s === 'string' && s.trim()) : []
    };
  }

  // CCv2 的世界书条目 → DiscPersona lorebook.json 的条目
  function toLorebook(card, fallbackName) {
    if (!card.book || !Array.isArray(card.book.entries)) return null;
    const entries = card.book.entries.map((e, idx) => ({
      id: idx + 1,
      keys: Array.isArray(e.keys) ? e.keys.filter(Boolean) : [],
      comment: e.comment || e.name || ('条目 ' + (idx + 1)),
      content: String(e.content || '').trim(),
      constant: !!e.constant,
      insertion_order: Number(e.insertion_order != null ? e.insertion_order : e.order != null ? e.order : 100)
    })).filter((e) => e.content);
    if (!entries.length) return null;
    return {
      name: (card.book.name || fallbackName || '世界书'),
      description: card.book.description || '从角色卡导入的世界书。DiscPersona 原生模式会把 constant 条目拼进 system prompt 附录。',
      entries: entries
    };
  }

  function oneLine(s) {
    return String(s || '').replace(/\s+/g, ' ').trim();
  }

  function slugify(name) {
    const s = String(name || '').toLowerCase()
      .replace(/[^a-z0-9\u4e00-\u9fa5\-_\s]/g, ' ')
      .trim().replace(/\s+/g, '-').replace(/-+/g, '-');
    const ascii = s.replace(/[^a-z0-9\-_]/g, '');
    if (ascii) return ascii.slice(0, 40);
    // 纯中文名：用名字的稳定散列兜底，同一个名字每次导入得到同一个 slug
    let h = 2166136261;
    for (const ch of String(name || '')) {
      h ^= ch.codePointAt(0);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return 'persona-' + h.toString(36).slice(0, 6);
  }

  function bulletsFrom(text) {
    const arr = String(text || '')
      .split(/\r?\n/)
      .map((s) => s.replace(/^[-*•]\s*/, '').trim())
      .filter(Boolean);
    return arr.join('\n');
  }

  /* ---------- 应用 ---------- */

  function applyCard(card, fileName) {
    const d = card.data;
    const applied = [];

    function put(field, value, label) {
      const v = typeof value === 'string' ? value : '';
      if (!v.trim()) return;
      if (v.length > MAX_TEXT) return;
      state[field] = v;
      applied.push(label || field);
    }

    put('name', oneLine(d.name), '名字');
    if (!state.slug) state.slug = slugify(d.name);
    // 卡里的 character_version 不再映射到界面字段：人设版本固定为 1.0.0，
    // 原值保留在导出的 card.json 里（见 app.js 的 cardJson）
    if (d.creator && !state.source) state.source = oneLine(d.creator);

    const desc = String(d.description || '').trim();
    if (desc) {
      // CC 的 description 通常混着外貌/背景/性格，整体放进「你是谁」，不猜着切碎
      state.identity = desc;
      applied.push('「你是谁」（来自 description）');
    }
    put('traits', bulletsFrom(d.personality), '性格（来自 personality）');
    put('relations', String(d.scenario || '').trim(), '关系（来自 scenario）');
    put('greetingFirst', String(d.first_mes || '').trim(), '首句台词（来自 first_mes）');

    if (d.mes_example) {
      const ex = String(d.mes_example).trim();
      if (ex) {
        state.styleNotes = (state.styleNotes ? state.styleNotes.replace(/\s+$/, '') + '\n' : '') +
          '示例对话（来自角色卡，照这个语气说话）：\n' + ex;
        applied.push('说话风格（并入 mes_example）');
      }
    }
    if (d.post_history_instructions) {
      const phi = String(d.post_history_instructions).trim();
      if (phi) {
        state.boundaries = (state.boundaries ? state.boundaries.replace(/\s+$/, '') + '\n' : '') + phi;
        applied.push('底线（并入 post_history_instructions）');
      }
    }
    if (d.system_prompt && String(d.system_prompt).trim() && String(d.system_prompt).trim() !== desc) {
      // 原卡的 system_prompt 和我们的模板不是一回事：留着，导出时写回 card.json
      state.cardSystemPrompt = String(d.system_prompt).trim();
      applied.push('原 system_prompt（存起来，导出时写回 card.json）');
    }

    if (card.alt.length) { state.altGreetings = card.alt.slice(0, 20); applied.push('备选开场 ×' + state.altGreetings.length); }

    const book = toLorebook(card, d.name);
    if (book) { state.lorebook = book; applied.push('世界书 ×' + book.entries.length); }

    if (d.extensions && typeof d.extensions === 'object') {
      const dp = d.extensions.discpersona;
      if (dp && typeof dp === 'object') {
        if (dp.org) put('org', oneLine(dp.org), '组织');
        if (dp.role) put('role', oneLine(dp.role), '职务');
        if (dp.accent) { state.accent = dp.accent; state.accentSoft = mix(state.accent, '#ffffff', .55); state.background = mix(state.accent, '#050a10', .86); }
      }
    }

    return applied;
  }

  /* ---------- 文件入口 ---------- */

  async function importFile(file) {
    if (!file) return;
    const box = document.getElementById('import-result');
    box.hidden = false;
    box.className = 'import-result';
    box.textContent = '正在读 ' + file.name + ' …';
    try {
      const buf = await file.arrayBuffer();
      let card;
      if (/\.png$/i.test(file.name)) {
        card = normalizeCard(cardJsonFromPng(new Uint8Array(buf)));
      } else {
        const text = new TextDecoder('utf-8', { fatal: false }).decode(buf).replace(/^\uFEFF/, '');
        card = normalizeCard(JSON.parse(text));
      }

      const applied = applyCard(card, file.name);

      // 卡片图当头像（PNG 导入时原图就是立绘）
      if (/\.png$/i.test(file.name)) {
        state.avatar = 'data:image/png;base64,' + bytesToBase64(new Uint8Array(buf));
      }

      fillForm();
      fillColors();
      applyTheme();
      render();
      save();

      const missing = [];
      if (!state.worldview.trim()) missing.push('世界观（原卡没有这个字段，建议补一句）');
      if (!state.styleNotes.trim()) missing.push('说话风格（原卡没写，建议至少两条）');
      if (!state.greetingReturn.trim()) missing.push('「之后每次启动」的台词');
      if (!state.seedBirth.trim()) missing.push('初始记忆（留空会按身份自动生成）');

      box.className = 'import-result ok';
      box.innerHTML =
        '<b>已导入：' + escapeHtml(card.data.name || file.name) + '</b>' +
        '<span class="import-meta">' + escapeHtml(String(card.spec)) + ' · ' + applied.length + ' 项</span>' +
        '<ul>' + applied.map((a) => '<li>' + escapeHtml(a) + '</li>').join('') + '</ul>' +
        (missing.length ? '<p class="import-todo">还要补：' + missing.map(escapeHtml).join('、') + '</p>' : '') +
        '<p class="import-todo">导入只是填充，不会覆盖你已经写好的字段；确认无误再点「导出人设包」。</p>';
      setLog('角色卡已导入：' + (card.data.name || file.name) + '（' + applied.length + ' 项）。', 'ok');
    } catch (e) {
      box.className = 'import-result bad';
      box.textContent = '导入失败：' + (e && e.message ? e.message : e) +
        '。V1 卡请先导出成 V2；加密或压缩过的 PNG 文本块暂不支持。';
      setLog('角色卡导入失败：' + (e && e.message ? e.message : e), 'bad');
    }
  }

  function bytesToBase64(bytes) {
    let bin = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(bin);
  }

  function escapeHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }

  /* ---------- 让导出带上导入的东西 ---------- */

  function installExportPatch() {
    const base = exportFiles;

    exportFiles = function () {
      const files = base();

      // 头像：导入过角色卡就用原图，否则仍是 canvas 占位图
      if (state.avatar && /^data:image\//.test(state.avatar)) {
        const at = files.findIndex((f) => f.path === 'avatar.png');
        const b64 = state.avatar.split(',')[1] || '';
        if (at >= 0 && b64) files[at] = { path: 'avatar.png', base64: b64 };
      }

      // 世界书：引擎会把 constant 条目拼进 system prompt 附录
      if (state.lorebook && Array.isArray(state.lorebook.entries) && state.lorebook.entries.length) {
        files.push({ path: 'lorebook.json', text: JSON.stringify(state.lorebook, null, 2) + '\n' });
      }

      // card.json 补回导入时的世界书 / 备选开场 / 原 system_prompt
      const ci = files.findIndex((f) => f.path === 'card.json');
      if (ci >= 0) {
        try {
          const card = JSON.parse(files[ci].text);
          if (state.altGreetings && state.altGreetings.length) card.data.alternate_greetings = state.altGreetings.slice();
          if (state.lorebook && state.lorebook.entries.length) {
            card.data.character_book = {
              name: state.lorebook.name,
              description: state.lorebook.description,
              entries: state.lorebook.entries.map((e, i) => ({
                id: i,
                keys: e.keys || [],
                secondary_keys: [],
                comment: e.comment || '',
                content: e.content,
                constant: !!e.constant,
                selective: !e.constant,
                insertion_order: Number(e.insertion_order || 100),
                enabled: true,
                position: 'before_char'
              }))
            };
          }
          if (state.cardSystemPrompt) card.data.system_prompt = state.cardSystemPrompt;
          files[ci] = { path: 'card.json', text: JSON.stringify(card, null, 2) + '\n' };
        } catch (e) { /* card.json 解析不了就原样留着 */ }
      }
      return files;
    };
  }

  function bind() {
    const btn = document.getElementById('btn-import-card');
    const input = document.getElementById('f-card');
    if (btn && input) {
      btn.addEventListener('click', () => input.click());
      input.addEventListener('change', (e) => {
        const f = e.target.files && e.target.files[0];
        importFile(f);
        e.target.value = '';
      });
    }
    // 拖拽到第一步面板也能导入
    const panel = document.querySelector('.panel[data-panel="1"]');
    if (panel) {
      panel.addEventListener('dragover', (e) => { e.preventDefault(); panel.classList.add('is-drag'); });
      panel.addEventListener('dragleave', () => panel.classList.remove('is-drag'));
      panel.addEventListener('drop', (e) => {
        e.preventDefault();
        panel.classList.remove('is-drag');
        const f = e.dataTransfer.files && e.dataTransfer.files[0];
        if (f) importFile(f);
      });
    }
  }

  // 暴露给自动化测试
  window.DiscPersonaCard = { importFile: importFile, cardJsonFromPng: cardJsonFromPng, normalizeCard: normalizeCard };

  installExportPatch();
  bind();
})();
