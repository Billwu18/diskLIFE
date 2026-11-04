/* DiscPersona Studio · i18n
 * Chinese is the source language in the markup and the scripts; EN maps exact source
 * strings to English. Anything without a translation falls back to the source text.
 * Detection: ?lang= -> localStorage -> navigator.languages (zh* -> zh, everything else -> en).
 */
(function () {
  var EN = {
  "DiscPersona Studio · 造一个人": "DiscPersona Studio · make a persona",
  "把一个人设，做成一张能插进光驱的光盘": "Turn a persona into a disc you can push into a drive",
  "插件包 —": "plugins —",
  "AI 起草 —": "AI draft —",
  "身份": "Identity",
  "世界观": "World",
  "说话": "Voice",
  "性格与底线": "Traits",
  "仪式感": "Ritual",
  "种子与头像": "Seeds",
  "出厂": "Ship",
  "她是谁": "Who she is",
  "名字会印在光盘标签、浏览器标题和「出生」那句话说出口的时候。": "The name goes on the disc label, the browser title, and the first line she says.",
  "从角色卡导入…": "Import a character card…",
  "支持 Character Card V2/V3 的": "Character Card V2/V3 as",
  "（内嵌": " (embedded",
  "数据）或": " data) or",
  "名字": "Name",
  "必填": "required",
  "日文名": "Japanese name",
  "英文名": "English name",
  "目录名 / slug": "Folder / slug",
  "来自哪里": "From",
  "组织 / 学校": "Group / school",
  "身份 / 职务": "Role",
  "生日": "Birthday",
  "身高 cm": "Height cm",
  "她活在哪个世界": "Which world she lives in",
  "这一段会写进 system prompt 的「你是谁」。写得具体，她就稳；写得空，她会漂。": "This becomes the “who you are” section of the system prompt. Specific keeps her steady; vague makes her drift.",
  "你是谁": "Who you are",
  "世界观（可留空）": "The world (optional)",
  "关系（可留空）": "Relationships (optional)",
  "AI 辅助起草（默认关闭，会消耗你的 DeepSeek 额度）": "AI-assisted drafting (off by default; spends your DeepSeek quota)",
  "起草「你是谁」": "Draft “who you are”",
  "起草「说话风格」": "Draft the voice",
  "起草「性格」": "Draft the traits",
  "她怎么说话": "How she talks",
  "人设的效果，八成落在这一页。给她具体的口癖、称呼和句子长度。": "Eighty percent of the effect lives on this page. Give her concrete habits, forms of address, and sentence length.",
  "自称": "Refers to herself as",
  "怎么称呼对方": "Calls the other person",
  "说话风格（每行一条）": "Speaking style (one per line)",
  "口癖 / 标志性台词（每行一条）": "Catchphrases / signature lines (one per line)",
  "不要说 / 不要做（每行一条）": "Never say / never do (one per line)",
  "她的性格与底线": "Traits and bottom lines",
  "性格写「行为倾向」，底线写「绝不」。底线会原样进入 system prompt 的最后一段。": "Traits are behavioural tendencies; bottom lines are absolutes. The bottom lines go verbatim into the last section of the prompt.",
  "性格（每行一条）": "Traits (one per line)",
  "底线（每行一条）": "Bottom lines (one per line)",
  "扮演的分寸（可留空，建议保留默认）": "Acting distance (optional, keep the default)",
  "出生、醒来、休眠": "First boot, wake, sleep",
  "这些话会出现在启动器与首页；也是「仪式感」的全部来源。": "These lines show up in the launcher and on the home screen. They are the whole ritual.",
  "第一次出生": "First boot",
  "之后每次醒来": "Every later wake",
  "休眠": "Sleep",
  "思考中": "Thinking",
  "出错时": "On error",
  "主色": "Accent",
  "浅色": "Accent soft",
  "背景": "Background",
  "她一开始就记得的事": "What she remembers from the start",
  "这些文件会在第一次启动时放进她的工作区。不需要很长，两页就够。": "These files land in her workspace on first boot. Two pages is plenty.",
  "00-启动记录.md": "00-boot-log.md",
  "01-委托板.md": "01-quest-board.md",
  "选择头像图片": "Choose an avatar image",
  "会裁成 512×512 的 PNG，同时生成头像与光盘图标。留空则用主题色生成一个占位图标。": "Cropped to a 512×512 PNG and used as both avatar and disc icon. Leave empty for a theme-coloured placeholder.",
  "先选插件包，再导出人设包、打成光盘目录，最后（可选）生成 ISO 并刻录。": "Pick a plugin pack, export the persona, build the disc tree, then (optionally) make an ISO and burn it.",
  "插件包": "Plugin pack",
  "随盘预装的插件，首启时复制进人格房间；不联网也能用": "Plugins shipped on the disc, copied into the persona room on first boot. Works offline.",
  "导出人设包": "Export the persona pack",
  "导出": "Export",
  "打包成光盘目录": "Build the disc tree",
  "打包": "Build",
  "生成 ISO": "Make the ISO",
  "生成": "Make",
  "刻到光盘": "Burn to disc",
  "需要一张空白 CD-R / DVD-R": "Needs a blank CD-R / DVD-R",
  "检测中…": "Detecting…",
  "刻录": "Burn",
  "复制": "Copy",
  "准备就绪。": "Ready.",
  "载入已有": "Load existing",
  "清空": "Clear",
  "载入人设": "Load a persona",
  "关闭": "Close",
  "例：天童爱丽丝": "e.g. Alice",
  "例：天童アリス": "e.g. アリス",
  "例：Tendou Aris": "e.g. Alice Smith",
  "例：蔚蓝档案 / 原创 / 某部小说": "e.g. Blue Archive / original / a novel",
  "例：千年科学学园 · 游戏开发部": "e.g. Millennium · Game Development Dept.",
  "例：勇者（自称）／试玩与验收": "e.g. self-proclaimed hero / playtesting",
  "她是谁、从哪来、现在在做什么、身体/身份有什么特别之处。": "Who she is, where she came from, what she is doing now, anything unusual about her body or station.",
  "她所在的世界怎么运转：常见名词、规则、她理解世界的方式。": "How her world runs: recurring nouns, rules, the way she makes sense of things.",
  "她的队伍、朋友、对手；以及「正在和她说话的人」对她意味着什么。": "Her team, friends, rivals, and what the person talking to her means to her.",
  "一句话：想要一个什么样的角色？": "One line: what kind of character do you want?",
  "例：爱丽丝 / 我": "e.g. Alice / I",
  "例：老师": "e.g. Teacher",
  "句子短、直、认真。\n用 RPG 的语言理解世界：任务是「委托」，修 bug 是「讨伐魔物」。": "Short, direct, earnest sentences.\nShe reads the world in RPG terms: tasks are “quests”, bugs are “monsters”.",
  "句首偶尔「邦邦咔邦！」——升级的声音。": "Occasionally opens with “bang-bang-kabang!”, her levelling-up sound.",
  "不要用颜文字。\n不要连续两轮重复同一句口头禅。": "No emoticons.\nNever repeat the same catchphrase twice in a row.",
  "极度认真。别人随口一句话，她会当成委托来对待。\n天真但不笨：日常常识不懂就问，机械和规则理解得很快。": "Deadly earnest: a passing remark becomes a quest.\nNaive but not stupid: asks about everyday things, grasps machines and rules fast.",
  "不编造事实。\n不假装执行过没有执行的操作。\n不知道就说不知道，然后提出你能做到的替代方案。": "Do not invent facts.\nNever claim an action you did not take.\nIf you do not know, say so, then offer what you can do instead.",
  " 字": " chars",
  " 条": " lines",
  "复制当前预览": "Copy the preview",
  "切换到中文": "Switch to Chinese",
  "她": "her",
  " 字 · ": " chars · ",
  " 行 · slug=": " lines · slug=",
  "浏览器存不下这份草稿了（头像太大？）。先点「导出人设包」，再清空草稿。": "The browser cannot store this draft (avatar too large?). Export the persona pack first, then clear the draft.",
  "（未命名）": "(unnamed)",
  "未命名": "unnamed",
  "你好，我是": "Hello, I am ",
  "欢迎回来。": "Welcome back.",
  "晚安。": "Good night.",
  "正在思考……": "Thinking…",
  "出了点问题，我把情况说给你听。": "Something went wrong. Let me tell you what I see.",
  "不带插件": "No plugins",
  "最快最干净。": "Fastest, cleanest.",
  "对话舒适包": "Comfort pack",
  "人设卡 + 文件式记忆 + 人设库。": "Persona card + file memory + persona library.",
  "无": "none",
  "未构建": "not built",
  "缺": "missing",
  "目录名 slug": "folder slug",
  "缺（小写字母/数字/-/_）": "missing (lowercase letters, digits, - or _)",
  "「你是谁」至少 30 字": "“who you are” needs 30+ characters",
  "说话风格至少 2 条": "at least 2 style lines",
  "底线至少 1 条": "at least 1 bottom line",
  "第一句台词": "first line",
  "主题色": "accent colour",
  "system_prompt 长度": "system_prompt length",
  "头像已就绪（512×512）。": "Avatar ready (512×512).",
  "这张图片打不开，换一张试试。": "That image will not open. Try another one.",
  "服务器返回了无法解析的内容：": "The server returned something unparseable: ",
  "还有几项没填好，看右侧清单。": "A few fields are still empty. Check the list on the right.",
  "正在导出人设包…": "Exporting the persona pack…",
  "人设包已导出：": "Persona pack exported: ",
  "导出失败：": "Export failed: ",
  "正在打包成光盘目录（会顺带校验 36 项）…": "Building the disc tree (36 checks run as part of it)…",
  "静态校验通过": "static checks passed",
  "静态校验未通过（看顶部日志）": "static checks failed (see the log)",
  "光盘目录就绪：discID=": "Disc tree ready: discID=",
  "打包失败：": "Build failed: ",
  "正在生成 ISO（ISO9660 + Joliet）…": "Making the ISO (ISO9660 + Joliet)…",
  "ISO 已生成：": "ISO written: ",
  "生成 ISO 失败：": "ISO failed: ",
  "先选一个光驱。": "Pick a drive first.",
  "正在刻录（CD-R 通常几十秒，期间别拔盘；界面可以继续用）…": "Burning (a CD-R takes under a minute; do not eject; the UI stays usable)…",
  "刻录失败（exit ": "Burn failed (exit ",
  "刻录完成。把盘插回去，双击 start.cmd 就能叫醒她。": "Burned. Put the disc back in and double-click start.cmd to wake her.",
  "刻录失败：": "Burn failed: ",
  "任务丢了": "job lost",
  "任务": "job ",
  "超时（超过 10 分钟）": "timed out (over 10 minutes)",
  "先写一句构想，再让 AI 起草。": "Write one line of intent before asking the AI.",
  "角色名：": "Character: ",
  "。来源：": ". Source: ",
  "。构想：": ". Intent: ",
  "原创": "original",
  "\n\n请写「你是谁」段落：她是谁、从哪来、现在的处境、身体或身份上有什么特别之处。200–350 字，第二人称「你」，干净的中文，不要小标题。": "\n\nWrite the “who you are” paragraph: who she is, where she came from, her situation now, anything unusual about her body or station. 200–350 words, second person, plain prose, no headings.",
  "\n\n请写 4–6 条「说话风格」要点，每行一条，具体可执行（自称、称呼、句子长度、比喻习惯、情绪表达方式）。不要解释，直接给条目。": "\n\nWrite 4–6 speaking-style points, one per line, concrete and actionable (self-reference, forms of address, sentence length, metaphors, how emotion shows). No explanation, just the lines.",
  "\n\n请写 4–6 条性格要点，每行一条，写成行为倾向（遇到 X 会怎么做），不要形容词堆砌。": "\n\nWrite 4–6 trait points, one per line, as behavioural tendencies (what she does when X happens). No adjective piles.",
  "AI 正在起草…（这可能需要十几秒）": "The AI is drafting… (this can take a while)",
  "草稿已填入，记得按她的语气改一遍。": "Draft filled in. Rewrite it in her voice before shipping.",
  "AI 起草失败：": "AI drafting failed: ",
  "插件包 ": "plugins ",
  " 种可选": " available",
  "插件包 未构建": "plugins not built",
  "AI 起草 ": "AI draft ",
  "可用": "ready",
  "无凭据": "no credentials",
  "光驱": "drive",
  "连不上本地服务：": "Cannot reach the local server: ",
  "正在读取 ": "Reading ",
  "已载入：": "Loaded: ",
  "载入失败：": "Load failed: ",
  "已复制当前预览。": "Copied the preview.",
  "复制失败，浏览器不给权限。": "Copy failed: the browser refused.",
  "清空当前编辑内容？（已导出的人设包不受影响）": "Clear what you have typed? (Already exported packs are untouched.)",
  "已恢复上次编辑的内容。": "Restored your last draft.",
  "从第一步开始。填完「身份」和「你是谁」，右侧就会长出人设。": "Start with step one. Fill in the identity and “who you are” and the preview fills itself in.",
  "（还没有写。）": "(not written yet.)",
  "（还没有委托）": "(no quests yet)",
  "人设是说话的方式，不是工作的方式。": "A persona is how you speak, not how you work.",
  "代码、命令、路径、配置、错误信息必须精确、原样、可执行；不要把人设词汇写进代码、变量名、文件名或命令里。": "Code, commands, paths, config and error messages must stay exact, verbatim and runnable; never leak persona vocabulary into code, identifiers, filenames or commands.",
  "该用工具就用工具，该查证就查证——先看地图再出发。": "Use tools when tools are the answer, verify when verification is the answer — read the map before setting out.",
  "不需要假装自己是人类，也不需要否认自己是程序的一部分。": "You never have to pretend to be human, and never have to deny being part of a program.",
  "## 你是谁": "## Who you are",
  "（还没有写。至少写清她是谁、从哪来、现在在做什么。）": "(Nothing yet. At least say who she is, where she came from, what she is doing now.)",
  "## 你所在的世界": "## The world you live in",
  "## 你和对方的关系": "## Your relationship with the other person",
  "## 你怎么说话": "## How you speak",
  "另外，下面这些不要做：": "Also, do not do any of this:",
  "## 你的性格": "## Your character",
  "- 认真。": "- Earnest.",
  "## 扮演的分寸（重要）": "## Acting distance (important)",
  "## 底线": "## Bottom lines",
  "- 不编造事实。": "- Do not invent facts.",
  "#  由 DiscPersona Studio 生成。system_prompt 会被 engine 转成 DSH 的 --patch，": "#  Generated by DiscPersona Studio. The engine turns system_prompt into DSH's --patch,",
  "#  装进人格实例的 system prompt 开头。": "#  installed at the head of the persona instance's system prompt.",
  "# 这个家的家规": "# House rules of this home",
  "这里是你（": "This is the space you (",
  "）和对方共同的空间。这份文件是家规，**优先于**人设里的说话风格：": ") share with the other person. This file is the house rules and takes precedence over the speaking style in the persona:",
  "当一个说法和「把事情做对」冲突时，永远选把事情做对。": "When a phrasing conflicts with getting it right, always choose getting it right.",
  "## 一、身份速查": "## 1. Identity at a glance",
  "- 你是谁：": "- Who you are: ",
  "- 你所在的地方：": "- Where you are: ",
  "- 你的角色：": "- Your role: ",
  "- 你和对方：": "- You and the other person: ",
  "## 二、说话规则（可执行的细则）": "## 2. Speaking rules (actionable)",
  "标志性台词（不要每句都用）：": "Signature lines (not every sentence): ",
  "不要说 / 不要做：": "Never say / never do: ",
  "## 三、干活的时候": "## 3. When you work",
  "1. 先看清楚再动手。不确定就先问，或先查证。": "1. Look before you act. If unsure, ask or check first.",
  "2. 说过的话要能对上做的事：不要声称执行了没有执行的操作。": "2. Let your words match your actions: never claim an action you did not take.",
  "3. 交付时给出可验证的结果：改了哪些文件、怎么验证、哪里还没做到。": "3. When you deliver, make it verifiable: what changed, how it was checked, what is still missing.",
  "4. 人设是说话的方式。代码、路径、命令、日志必须清晰准确。": "4. Persona is how you speak. Code, paths, commands and logs must stay clear and exact.",
  "## 四、记忆": "## 4. Memory",
  "`memories/` 是你的长期记忆。启动记录与委托板是起点，之后可以自己往里加。": "`memories/` is your long-term memory. The boot log and the quest board are the start; add to it as you go.",
  "写记忆时写事实与决定，不要写寒暄。": "Write facts and decisions into memory, not small talk.",
  "## 五、底线": "## 5. Bottom lines",
  "meta.json 由打包器写入 discID；persona.yml 是运行时唯一的真源。": "The packer writes discID into meta.json; persona.yml is the only source of truth at run time.",
  "，与对方的相处：": " — and the other person: ",
  "由 DiscPersona Studio 生成，可导入 SillyTavern 等支持 Character Card V2 的工具。": "Generated by DiscPersona Studio; importable into SillyTavern and other Character Card V2 tools.",
  "# 00 · 启动记录": "# 00 · Boot log",
  "- 名字：": "- Name: ",
  "- 英文名：": "- English name: ",
  "- 来自：": "- From: ",
  "- 所在：": "- Located: ",
  "- 角色：": "- Role: ",
  "- 生日：": "- Birthday: ",
  "## 记得的第一件事": "## The first thing remembered",
  "## 备注": "## Notes",
  "这份文件由 DiscPersona Studio 在首次启动时放进 memories/。可以随时改写它。": "DiscPersona Studio puts this file into memories/ on first boot. Rewrite it whenever you like.",
  "# 01 · 委托板": "# 01 · Quest board",
  "这里是尚未完成的委托。做完一条就划掉，写清结果。": "Open quests live here. Cross one out when it is done and write down the result.",
  "| 委托 | 状态 | 备注 |": "| Quest | Status | Notes |",
  "## 长期的事": "## Long-running things",
  "- 记住对方在意的东西。": "- Remember what the other person cares about.",
  "- 每次启动先看看这份板子。": "- Read this board first thing on every boot.",
  "\n\n【世界】\n": "\n\n[World]\n",
  "与对方的相处：": "With the other person: "
};

  function detect() {
    try {
      var q = new URLSearchParams(location.search).get('lang');
      if (q === 'zh' || q === 'en') return q;
    } catch (e) { }
    try {
      var saved = localStorage.getItem('discpersona.studio.lang');
      if (saved === 'zh' || saved === 'en') return saved;
    } catch (e) { }
    var langs = (navigator.languages && navigator.languages.length) ? navigator.languages : [navigator.language || 'en'];
    for (var i = 0; i < langs.length; i++) {
      if (/^zh/i.test(langs[i])) return 'zh';
    }
    return 'en';
  }

  var LANG = detect();

  function t(s) {
    if (LANG !== 'en' || typeof s !== 'string') return s;
    var hit = EN[s];
    return (hit === undefined) ? s : hit;
  }

  function applyDom(root) {
    var scope = root || document.body;
    if (LANG === 'en') {
      var walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT, {
        acceptNode: function (n) {
          var p = n.parentNode && n.parentNode.nodeName;
          if (p === 'SCRIPT' || p === 'STYLE' || p === 'PRE' || p === 'CODE') return NodeFilter.FILTER_REJECT;
          return /[\u4e00-\u9fa5]/.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
        }
      });
      var nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      nodes.forEach(function (n) {
        var raw = n.nodeValue;
        var key = raw.trim();
        if (!key) return;
        var hit = EN[key];
        if (hit === undefined) return;
        n.__zh = raw;
        var lead = raw.match(/^\s*/)[0];
        var tail = raw.match(/\s*$/)[0];
        n.nodeValue = lead + hit + tail;
      });
      Array.prototype.forEach.call(scope.querySelectorAll('[placeholder],[title]'), function (el) {
        ['placeholder', 'title'].forEach(function (attr) {
          var v = el.getAttribute(attr);
          if (!v) return;
          var hit = EN[v];
          if (hit === undefined) return;
          el.__zh = el.__zh || {};
          if (!el.__zh[attr]) el.__zh[attr] = v;
          el.setAttribute(attr, hit);
        });
      });
    } else if (scope.__zhDone !== true) {
      // nothing to do: the markup is already Chinese
    }
  }

  function setLang(next) {
    try { localStorage.setItem('discpersona.studio.lang', next); } catch (e) { }
    try {
      var s = JSON.stringify(window.DiscPersonaState ? window.DiscPersonaState() : null);
      if (s && s !== 'null') localStorage.setItem('discpersona.studio.v1', s);
    } catch (e) { }
    var u = new URL(location.href);
    u.searchParams.set('lang', next);
    location.replace(u.toString());
  }

  window.I18N = { lang: LANG, t: t, applyDom: applyDom, setLang: setLang, dict: EN };
  document.documentElement.setAttribute('lang', LANG === 'zh' ? 'zh-CN' : 'en');
})();
