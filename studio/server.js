#!/usr/bin/env node
/*
 * DiscPersona Studio —— 本地「人设创建上位机」的服务端（Linux / Node.js 版）。
 *
 * 只监听 127.0.0.1，把 studio/web 里的静态页面发给浏览器，并提供几个本地 API：
 *   GET  /api/env       环境：dsh 版本、光驱、已有的人设、payload 状态
 *   POST /api/export    把前端渲染好的人设文件写到 persona/<slug>/
 *   POST /api/build     调 tools/new-disc.js 打成光盘目录
 *   POST /api/iso       调 tools/new-iso.js 生成 ISO
 *   POST /api/burn      调 tools/burn-iso.js 刻录
 *   POST /api/draft     可选：调 DeepSeek 起草人设（默认关闭，前端开关控制）
 *   POST /api/open      在文件管理器里打开目录
 *   GET  /api/personas  列出已有的人设包
 *
 * 服务端不信任前端：所有写入都被限制在工作区与 DiscPersona 数据目录之下。
 * 这是 studio/server.ps1 的 Linux 移植；只用 Node 内置模块，无 npm 依赖。
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const net = require('net');
const crypto = require('crypto');
const { spawn, spawnSync } = require('child_process');

const STUDIO_DIR = __dirname;
const WORKSPACE_ROOT = path.dirname(STUDIO_DIR);
const WEB_DIR = path.join(STUDIO_DIR, 'web');
const PERSONA_ROOT_DEFAULT = path.join(WORKSPACE_ROOT, 'persona');

const HOME_DIR = os.homedir();
const XDG_DATA_HOME = process.env.XDG_DATA_HOME || path.join(HOME_DIR, '.local', 'share');
const DISC_PERSONA_ROOT = path.join(XDG_DATA_HOME, 'DiscPersona');
const DISC_PERSONA_PERSONAS = path.join(DISC_PERSONA_ROOT, 'personas');

const XDG_CONFIG_HOME = process.env.XDG_CONFIG_HOME || path.join(HOME_DIR, '.config');
const XDG_STATE_HOME = process.env.XDG_STATE_HOME || path.join(HOME_DIR, '.local', 'state');
const AUTOSTART_FILE = path.join(XDG_CONFIG_HOME, 'autostart', 'disklife-disc-watch.desktop');
const WATCHER_LOCK = path.join(XDG_STATE_HOME, 'disklife', 'disc-watch.pid');
const WATCHER_LOG = path.join(XDG_STATE_HOME, 'disklife', 'disc-watch.log');
const WATCHER_SCRIPT = path.join(WORKSPACE_ROOT, 'engine', 'tools', 'disc-watch.js');

const BODY_LIMIT = 12582912; // 12 MB

let actualPort = 0;

// ---------------------------------------------------------------- 输出
function writeStudio(message) {
  if (message === '') { process.stdout.write('\n'); return; }
  process.stdout.write('  ' + message + '\n');
}

function writeStderr(message) {
  process.stderr.write(message + '\n');
}

function usage() {
  return [
    'DiscPersona Studio (Linux)',
    '',
    '用法 / Usage:',
    '  node studio/server.js [--port <n>] [--no-browser]',
    '  ./start-studio.sh     [--port <n>] [--no-browser]',
    '',
    '  --port <n>     端口，默认 4791；0 = 自动挑一个空闲端口。',
    '  --no-browser   不自动打开浏览器。',
    '  --help         打印这段说明。',
    '',
  ].join('\n');
}

// ---------------------------------------------------------------- 参数
function parseArgs(argv) {
  const opts = { port: 4791, noBrowser: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const raw = argv[i];
    let name = raw;
    let inlineValue = null;
    const eq = raw.indexOf('=');
    if (raw.startsWith('--') && eq > 2) {
      name = raw.slice(0, eq);
      inlineValue = raw.slice(eq + 1);
    }
    const lower = name.toLowerCase();
    if (lower === '--port' || lower === '-port') {
      let value = inlineValue;
      if (value === null) {
        if (i + 1 >= argv.length) return { error: '缺少 --port 的数值。' };
        value = argv[++i];
      }
      if (!/^\d+$/.test(String(value).trim())) return { error: '--port 必须是 0 或正整数。' };
      opts.port = Number(String(value).trim());
      if (!Number.isSafeInteger(opts.port)) return { error: '--port 必须是 0 或正整数。' };
    } else if (lower === '--no-browser' || lower === '-nobrowser') {
      opts.noBrowser = true;
    } else if (lower === '--help' || lower === '-h' || lower === '-help') {
      opts.help = true;
    } else {
      return { error: '不认识的参数：' + raw };
    }
  }
  return { opts };
}

// ---------------------------------------------------------------- JSON
function sendJson(res, object, statusCode) {
  if (res.writableEnded) return;
  const json = JSON.stringify(object);
  const bytes = Buffer.from(json, 'utf8');
  res.writeHead(statusCode || 200, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': bytes.length,
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(bytes);
}

function sendFail(res, message, code, statusCode) {
  sendJson(res, { ok: false, code: code || 'S01', error: message }, statusCode || 200);
}

// ---------------------------------------------------------------- 路径
function fullPath(p) {
  return path.resolve(String(p));
}

// 与 PS 的 Test-UnderRoot 等价：Path 必须严格位于某个根之下。
function isUnderRoot(target, roots) {
  const full = fullPath(target);
  for (const root of roots) {
    if (!root) continue;
    let rootFull = fullPath(root);
    if (rootFull.endsWith(path.sep)) rootFull = rootFull.slice(0, -1);
    if (full === rootFull) return true;
    if (full.startsWith(rootFull + path.sep)) return true;
  }
  return false;
}

function readTextUtf8(file) {
  const text = fs.readFileSync(file, 'utf8');
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function safeJsonParse(text) {
  try { return JSON.parse(text); } catch (e) { return null; }
}

// ---------------------------------------------------------------- 静态文件
const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.md': 'text/markdown; charset=utf-8',
};

function sendFile(res, filePath) {
  const full = fullPath(filePath);
  let stat;
  try { stat = fs.statSync(full); } catch (e) { stat = null; }
  if (!stat || !stat.isFile()) {
    if (!res.writableEnded) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-cache' });
      res.end('Not found');
    }
    return;
  }
  const ct = CONTENT_TYPES[path.extname(full).toLowerCase()] || 'application/octet-stream';
  const bytes = fs.readFileSync(full);
  res.writeHead(200, {
    'Content-Type': ct,
    'Cache-Control': 'no-cache',
    'Content-Length': bytes.length,
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(bytes);
}

// ---------------------------------------------------------------- 请求体
function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > BODY_LIMIT) {
        if (!settled) {
          settled = true;
          const err = new Error('请求体太大（上限 12 MB）。');
          err.code = 'S92';
          reject(err);
        }
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (settled) return;
      settled = true;
      const text = Buffer.concat(chunks).toString('utf8').replace(/^\uFEFF/, '');
      if (!text || text.trim() === '') { resolve(null); return; }
      try { resolve(JSON.parse(text)); } catch (e) { resolve({ __invalidJson: true }); }
    });
    req.on('error', (err) => {
      if (settled) return;
      settled = true;
      reject(err);
    });
  });
}

// ---------------------------------------------------------------- 环境信息
function getApiKey() {
  if (process.env.DSH_STUDIO_KEY) return process.env.DSH_STUDIO_KEY;
  const sourceHome = process.env.DISCPERSONA_SOURCE_HOME || process.env.DSH_HOME || path.join(HOME_DIR, '.dsh');
  const cred = path.join(sourceHome, '.credentials.yaml');
  let text;
  try { text = readTextUtf8(cred); } catch (e) { return null; }
  const m = /DEEPSEEK_API_KEY:\s*["']?(sk-[A-Za-z0-9_-]+)/.exec(text);
  return m ? m[1] : null;
}

function getDshVersion() {
  try {
    const r = spawnSync('dsh', ['--version'], { encoding: 'utf8', timeout: 5000 });
    if (!r || r.error) return '';
    const text = (r.stdout || '').split(/\r?\n/)[0] || '';
    return text.trim();
  } catch (e) {
    return '';
  }
}

function readSysFile(file) {
  try { return fs.readFileSync(file, 'utf8').trim(); } catch (e) { return ''; }
}

function getDriveList() {
  const items = [];
  let names = [];
  try { names = fs.readdirSync('/dev'); } catch (e) { names = []; }
  const devices = names.filter((n) => /^sr\d+$/.test(n)).sort((a, b) => {
    const na = Number(a.replace(/\D/g, ''));
    const nb = Number(b.replace(/\D/g, ''));
    return na - nb;
  });
  for (const dev of devices) {
    const model = readSysFile('/sys/block/' + dev + '/device/model')
      || readSysFile('/sys/block/' + dev + '/device/vendor')
      || '';
    let size = 0;
    const sectors = Number(readSysFile('/sys/block/' + dev + '/size'));
    if (Number.isFinite(sectors) && sectors > 0) size = sectors * 512;
    items.push({
      letter: '/dev/' + dev,      // 前端把它直接传给 /api/burn；burn-iso.js 接受 /dev/sr0、sr0 或 0
      device: '/dev/' + dev,
      model,
      media: '',
      volume: '',
      size,
    });
  }
  return items;
}

function walkFiles(dir) {
  const out = [];
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return out; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    let lst;
    try { lst = fs.lstatSync(full); } catch (e) { continue; }
    if (lst.isSymbolicLink()) {
      let st;
      try { st = fs.statSync(full); } catch (e) { continue; }
      if (st.isDirectory()) continue; // 不跟着目录符号链接跑，避免环路
      out.push({ path: full, size: st.size });
    } else if (lst.isDirectory()) {
      out.push.apply(out, walkFiles(full));
    } else if (lst.isFile()) {
      out.push({ path: full, size: lst.size });
    }
  }
  return out;
}

const PAYLOAD_LABELS = {
  comfort: {
    label: '对话舒适包',
    label_en: 'Comfort pack',
    desc: '人设卡 + 文件式记忆 + 人设库，三档作用域、免重启切换。',
    desc_en: 'Persona card + file-based memory + a persona library with three scopes and no-restart switching.',
  },
  token: {
    label: '省 token 包',
    label_en: 'Token saver',
    desc: '软压缩历史、后台预备摘要、图片进上下文前先压小。聊得久也不容易顶到上限。',
    desc_en: 'Soft-compresses history, pre-writes summaries in the background, shrinks images before they enter context.',
  },
  full: {
    label: '全套',
    label_en: 'Everything',
    desc: '舒适包 + 省 token 包，插件最多，首次启动稍慢一点。',
    desc_en: 'Comfort pack plus token saver. Most plugins, slightly slower first boot.',
  },
};

function getPayloadPresetList() {
  const result = [];
  result.push({
    preset: 'none',
    label: '不带插件',
    label_en: 'No plugins',
    desc: '最快最干净，人格 DSH 只带人设。适合只要「插盘就聊天」的人。',
    desc_en: 'Fastest and cleanest: the persona instance ships with nothing but the persona.',
    ok: true,
    sizeBytes: 0,
    plugins: [],
    __builtAt: '',
  });
  for (const preset of ['comfort', 'token', 'full']) {
    let dir = path.join(WORKSPACE_ROOT, 'payload', preset, 'profile-web');
    if (!fs.existsSync(path.join(dir, 'payload.json'))) {
      dir = path.join(WORKSPACE_ROOT, 'build', 'payload', preset, 'profile-web');
    }
    const payloadFile = path.join(dir, 'payload.json');
    const ok = fs.existsSync(payloadFile);
    const plugins = [];
    let sizeBytes = 0;
    let builtAt = '';
    if (ok) {
      const pj = safeJsonParse(readTextUtf8(payloadFile));
      if (pj) {
        const list = Array.isArray(pj.plugins) ? pj.plugins : [];
        for (const pl of list) {
          if (!pl) continue;
          plugins.push(String(pl.name == null ? '' : pl.name) + ' ' + String(pl.version == null ? '' : pl.version));
        }
        if (pj.builtAt) builtAt = String(pj.builtAt);
      }
      try {
        for (const f of walkFiles(dir)) sizeBytes += f.size;
      } catch (e) { /* 忽略体积统计失败 */ }
    }
    const labels = PAYLOAD_LABELS[preset];
    result.push({
      preset,
      label: labels.label,
      label_en: labels.label_en,
      desc: labels.desc,
      desc_en: labels.desc_en,
      ok,
      sizeBytes,
      plugins,
      __builtAt: builtAt,
    });
  }
  return result;
}

function getPersonaList() {
  const list = [];
  let entries;
  try { entries = fs.readdirSync(PERSONA_ROOT_DEFAULT, { withFileTypes: true }); } catch (e) { return list; }
  entries.sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const dir = path.join(PERSONA_ROOT_DEFAULT, entry.name);
    let name = entry.name;
    let version = '';
    const metaPath = path.join(dir, 'meta.json');
    if (fs.existsSync(metaPath)) {
      const m = safeJsonParse(readTextUtf8(metaPath));
      if (m) {
        if (m.name) name = String(m.name);
        if (m.version != null) version = String(m.version);
      }
    }
    list.push({ slug: entry.name, name, version, path: dir });
  }
  return list;
}

// ---------------------------------------------------------------- Linux desktop integration
function whichBin(name) {
  const paths = (process.env.PATH || '').split(path.delimiter);
  for (const dir of paths) {
    if (!dir) continue;
    try {
      fs.accessSync(path.join(dir, name), fs.constants.X_OK);
      return path.join(dir, name);
    } catch (e) { /* keep looking */ }
  }
  return '';
}

function readOsRelease() {
  const result = {};
  let text = '';
  try { text = fs.readFileSync('/etc/os-release', 'utf8'); } catch (e) { return result; }
  for (const line of text.split(/\r?\n/)) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line);
    if (!m) continue;
    let value = m[2].trim();
    if (/^".*"$/.test(value)) value = value.slice(1, -1).replace(/\\"/g, '"');
    result[m[1]] = value;
  }
  return result;
}

function detectDistro() {
  const osr = readOsRelease();
  const id = String(osr.ID || '').toLowerCase();
  const like = String(osr.ID_LIKE || '').toLowerCase().split(/\s+/).filter(Boolean);
  const families = [id].concat(like);
  let family = 'generic';
  if (families.some((v) => v === 'arch' || v === 'archlinux' || v === 'manjaro' || v === 'endeavouros')) family = 'arch';
  else if (families.some((v) => v === 'debian' || v === 'ubuntu' || v === 'linuxmint' || v === 'pop' || v === 'kali')) family = 'debian';
  else if (families.some((v) => v === 'fedora' || v === 'rhel' || v === 'centos' || v === 'rocky' || v === 'almalinux')) family = 'fedora';
  else if (families.some((v) => v === 'opensuse' || v === 'suse' || v === 'sles')) family = 'suse';
  else if (families.some((v) => v === 'alpine')) family = 'alpine';
  else if (families.some((v) => v === 'nixos')) family = 'nixos';

  const packageManagers = [
    ['pacman', 'pacman', 'sudo pacman -S --needed udisks2 glib2 zenity xdg-utils'],
    ['apt-get', 'apt', 'sudo apt install udisks2 libglib2.0-bin zenity xdg-utils'],
    ['dnf', 'dnf', 'sudo dnf install udisks2 glib2 zenity xdg-utils'],
    ['zypper', 'zypper', 'sudo zypper install udisks2 glib2-tools zenity xdg-utils'],
    ['apk', 'apk', 'sudo apk add udisks2 glib zenity xdg-utils'],
    ['xbps-install', 'xbps', 'sudo xbps-install udisks2 glib zenity xdg-utils'],
    ['nix-env', 'nix', 'nix-shell -p udisks2 glib zenity xdg-utils'],
  ];
  for (const item of packageManagers) {
    if (whichBin(item[0])) {
      return {
        id: id || 'linux',
        name: osr.NAME || id || 'Linux',
        pretty: osr.PRETTY_NAME || osr.NAME || 'Linux',
        version: osr.VERSION_ID || '',
        family,
        packageManager: item[1],
        installCommand: item[2],
      };
    }
  }
  const familyHint = {
    arch: 'sudo pacman -S --needed udisks2 glib2 zenity xdg-utils',
    debian: 'sudo apt install udisks2 libglib2.0-bin zenity xdg-utils',
    fedora: 'sudo dnf install udisks2 glib2 zenity xdg-utils',
    suse: 'sudo zypper install udisks2 glib2-tools zenity xdg-utils',
    alpine: 'sudo apk add udisks2 glib zenity xdg-utils',
    nixos: 'nix-shell -p udisks2 glib zenity xdg-utils',
  };
  return {
    id: id || 'linux',
    name: osr.NAME || id || 'Linux',
    pretty: osr.PRETTY_NAME || osr.NAME || 'Linux',
    version: osr.VERSION_ID || '',
    family,
    packageManager: '',
    installCommand: familyHint[family] || '',
  };
}

function readWatcherPid() {
  try {
    const pid = parseInt(fs.readFileSync(WATCHER_LOCK, 'utf8').trim(), 10);
    if (!pid) return 0;
    try { process.kill(pid, 0); return pid; } catch (e) { return e.code === 'EPERM' ? pid : 0; }
  } catch (e) {
    return 0;
  }
}

function linuxIntegrationInfo() {
  const distro = detectDistro();
  const tools = {
    udisks2: Boolean(whichBin('udisksctl')),
    glib: Boolean(whichBin('gdbus')),
    busctl: Boolean(whichBin('busctl')),
    zenity: Boolean(whichBin('zenity')),
    kdialog: Boolean(whichBin('kdialog')),
    notifySend: Boolean(whichBin('notify-send')),
    xdgOpen: Boolean(whichBin('xdg-open')),
  };
  const missing = [];
  if (!tools.udisks2) missing.push('udisks2');
  if (!tools.glib && !tools.busctl) missing.push('glib2 (gdbus)');
  if (!tools.zenity && !tools.kdialog && !tools.notifySend) missing.push('zenity');
  if (!tools.xdgOpen) missing.push('xdg-utils');
  return {
    ok: true,
    platform: process.platform,
    distro,
    desktop: {
      current: process.env.XDG_CURRENT_DESKTOP || '',
      sessionType: process.env.XDG_SESSION_TYPE || '',
      display: Boolean(process.env.DISPLAY || process.env.WAYLAND_DISPLAY),
    },
    tools,
    missing,
    installCommand: missing.length > 0 ? distro.installCommand : '',
    eventSource: tools.glib ? 'udisks2-dbus (gdbus)' : (tools.busctl ? 'udisks2-busctl' : 'polling fallback'),
    autostart: {
      path: AUTOSTART_FILE,
      installed: fs.existsSync(AUTOSTART_FILE),
      running: readWatcherPid(),
      log: WATCHER_LOG,
    },
    watcherScript: WATCHER_SCRIPT,
  };
}

function runWatcherCommand(args) {
  if (!fs.existsSync(WATCHER_SCRIPT)) {
    return { exitCode: -1, output: '找不到 engine/tools/disc-watch.js' };
  }
  const r = spawnSync(process.execPath, [WATCHER_SCRIPT].concat(args), {
    cwd: WORKSPACE_ROOT,
    encoding: 'utf8',
    timeout: 30000,
    env: process.env,
  });
  const text = ((r.stdout || '') + '\n' + (r.stderr || '')).trim();
  const exitCode = r.status === null || r.status === undefined ? -1 : r.status;
  return { exitCode, output: text };
}

function sleepMs(ms) {
  const buf = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(buf, 0, 0, ms);
}

function startWatcherNow() {
  if (readWatcherPid()) return { exitCode: 0, output: 'Watcher is already running.' };
  if (!fs.existsSync(WATCHER_SCRIPT)) return { exitCode: -1, output: '找不到 engine/tools/disc-watch.js' };
  try {
    fs.mkdirSync(path.dirname(WATCHER_LOG), { recursive: true });
    const fd = fs.openSync(WATCHER_LOG, 'a');
    let child;
    try {
      child = spawn(process.execPath, [WATCHER_SCRIPT, '--prompt'], {
        cwd: WORKSPACE_ROOT,
        detached: true,
        stdio: ['ignore', fd, fd],
        env: process.env,
      });
    } finally {
      try { fs.closeSync(fd); } catch (e) { /* ignore */ }
    }
    child.unref();
    sleepMs(400); // give it time to write its lock file
    return { exitCode: 0, output: 'Started watcher (PID ' + child.pid + ').' };
  } catch (e) {
    return { exitCode: -1, output: 'Cannot start watcher: ' + ((e && e.message) || String(e)) };
  }
}

function stopWatcherNow() {
  const pid = readWatcherPid();
  if (!pid) return { exitCode: 0, output: 'Watcher is not running.' };
  try {
    process.kill(pid, 'SIGTERM');
    for (let i = 0; i < 20; i++) {
      sleepMs(100);
      if (!readWatcherPid()) break;
    }
    return { exitCode: 0, output: 'Stopped watcher (PID ' + pid + ').' };
  } catch (e) {
    return { exitCode: -1, output: 'Cannot stop watcher: ' + ((e && e.message) || String(e)) };
  }
}

// ---------------------------------------------------------------- 子进程
function toolsScript(name) {
  return path.join(WORKSPACE_ROOT, 'tools', name);
}

function runNodeTool(script, args) {
  if (!fs.existsSync(script)) {
    return {
      exitCode: -1,
      output: '找不到 ' + path.relative(WORKSPACE_ROOT, script) + '（Linux 移植版工具还没生成？）',
    };
  }
  const r = spawnSync(process.execPath, [script].concat(args), {
    cwd: WORKSPACE_ROOT,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
  });
  const outParts = [];
  if (r.stdout) outParts.push(String(r.stdout));
  if (r.stderr) outParts.push(String(r.stderr));
  let exitCode = r.status;
  if (r.error && (exitCode === null || exitCode === undefined)) exitCode = -1;
  if (exitCode === null || exitCode === undefined) exitCode = r.signal ? -1 : 0;
  return { exitCode, output: outParts.join('\n').trim() };
}

// ---------------------------------------------------------------- 异步任务
const studioJobs = new Map();
const studioJobRoot = path.join(os.tmpdir(), 'discpersona-studio-jobs');
let jobSequence = 0;

function newJobId() {
  jobSequence += 1;
  const rand = crypto.randomBytes(4).toString('hex');
  return rand + jobSequence.toString(16).padStart(2, '0');
}

function startStudioJob(script, args) {
  try { fs.mkdirSync(studioJobRoot, { recursive: true }); } catch (e) { /* ignore */ }
  const id = newJobId();
  const outFile = path.join(studioJobRoot, id + '.out.txt');
  const errFile = path.join(studioJobRoot, id + '.err.txt');
  let outFd = null;
  let errFd = null;
  const job = { id, script, outFile, errFile, child: null, startedAt: Date.now(), exitCode: null, done: false };
  if (!fs.existsSync(script)) {
    try {
      fs.writeFileSync(outFile, '找不到 ' + path.relative(WORKSPACE_ROOT, script) + '（Linux 移植版工具还没生成？）\n', 'utf8');
      fs.writeFileSync(errFile, '', 'utf8');
    } catch (e) { /* ignore */ }
    job.exitCode = -1;
    job.done = true;
    studioJobs.set(id, job);
    return id;
  }
  try {
    outFd = fs.openSync(outFile, 'w');
    errFd = fs.openSync(errFile, 'w');
    const child = spawn(process.execPath, [script].concat(args), {
      cwd: WORKSPACE_ROOT,
      detached: false,
      stdio: ['ignore', outFd, errFd],
      windowsHide: true,
    });
    job.child = child;
    child.on('exit', (code, signal) => {
      job.exitCode = (code === null) ? (signal ? -1 : -1) : code;
      job.done = true;
    });
    child.on('error', () => {
      job.exitCode = -1;
      job.done = true;
    });
  } catch (e) {
    job.exitCode = -1;
    job.done = true;
  } finally {
    if (outFd !== null) { try { fs.closeSync(outFd); } catch (e) { } }
    if (errFd !== null) { try { fs.closeSync(errFd); } catch (e) { } }
  }
  studioJobs.set(id, job);
  // 只留最近 40 个任务，防止长时间运行累积
  if (studioJobs.size > 40) {
    const ids = Array.from(studioJobs.keys());
    for (let i = 0; i < ids.length - 40; i++) studioJobs.delete(ids[i]);
  }
  return id;
}

function readJobText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch (e) { return ''; }
}

function getStudioJobState(id) {
  const job = studioJobs.get(id);
  if (!job) return null;
  if (!job.done && job.child && job.child.exitCode !== null) {
    job.exitCode = job.child.exitCode;
    job.done = true;
  }
  let out = readJobText(job.outFile);
  const err = readJobText(job.errFile);
  if (err) out += '\n' + err;
  return {
    id: job.id,
    done: job.done,
    exitCode: job.done ? job.exitCode : null,
    output: out,
  };
}

// ---------------------------------------------------------------- 端口 / 浏览器
function openBrowser(url) {
  try {
    const child = spawn('xdg-open', [url], { detached: true, stdio: 'ignore' });
    child.on('error', () => { });
    child.unref();
  } catch (e) { /* 打不开浏览器不影响服务 */ }
}

function testStudioPortBusy(portToTest) {
  return new Promise((resolve) => {
    let settled = false;
    const socket = net.connect({ host: '127.0.0.1', port: portToTest });
    const finish = (busy) => {
      if (settled) return;
      settled = true;
      try { socket.destroy(); } catch (e) { }
      resolve(busy);
    };
    socket.setTimeout(400, () => finish(false));
    socket.on('connect', () => finish(true));
    socket.on('error', () => finish(false));
  });
}

function getExistingStudio(portToTest) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    let req;
    try {
      req = http.get({
        host: '127.0.0.1',
        port: portToTest,
        path: '/api/env',
        timeout: 3000,
        headers: { Accept: 'application/json' },
      }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          if (res.statusCode !== 200) { finish(null); return; }
          const obj = safeJsonParse(Buffer.concat(chunks).toString('utf8'));
          if (!obj || !obj.ok || !obj.url) { finish(null); return; }
          finish({ url: String(obj.url), workspace: obj.workspace == null ? '' : String(obj.workspace) });
        });
        res.on('error', () => finish(null));
      });
      req.on('timeout', () => { try { req.destroy(); } catch (e) { } finish(null); });
      req.on('error', () => finish(null));
    } catch (e) {
      finish(null);
    }
  });
}

async function pickFreePort(startPort, endPort) {
  for (let p = startPort; p <= endPort; p++) {
    if (!(await testStudioPortBusy(p))) return p;
  }
  return 0;
}

// ---------------------------------------------------------------- HTTP 处理
const HOST_OK_SUFFIXES = ['127.0.0.1', 'localhost'];

function hostHeaderOk(hostHeader) {
  // 与 PS 一致：127.0.0.1 / localhost，可带自己的端口
  const host = String(hostHeader || '').toLowerCase().trim();
  if (!host) return false;
  for (const base of HOST_OK_SUFFIXES) {
    if (host === base) return true;
    if (host === base + ':' + actualPort) return true;
    if (base === '127.0.0.1' && host === '127.0.0.1:' + actualPort) return true;
  }
  return false;
}

function originOk(originHeader) {
  const origin = String(originHeader || '').toLowerCase().trim().replace(/\/+$/, '');
  if (!origin) return true;
  return origin === 'http://127.0.0.1:' + actualPort || origin === 'http://localhost:' + actualPort;
}

async function handleRequest(req, res) {
  const method = String(req.method || 'GET').toUpperCase();
  let parsed;
  try {
    parsed = new URL(req.url, 'http://127.0.0.1');
  } catch (e) {
    sendFail(res, '无法解析的请求地址。', 'S01', 400);
    return;
  }
  let requestPath;
  try {
    requestPath = decodeURIComponent(parsed.pathname);
  } catch (e) {
    requestPath = parsed.pathname;
  }

  // 只服务本机页面：挡 DNS rebinding 与跨站请求（本地端口也是攻击面）
  if (!hostHeaderOk(req.headers.host)) {
    sendFail(res, '只接受本机访问。', 'S90', 403);
    return;
  }
  if (!originOk(req.headers.origin)) {
    sendFail(res, '拒绝来自其他网页的请求。', 'S91', 403);
    return;
  }
  const fetchSite = String(req.headers['sec-fetch-site'] || '').toLowerCase();
  if (fetchSite && fetchSite !== 'same-origin' && fetchSite !== 'none') {
    sendFail(res, '拒绝跨站请求。', 'S91', 403);
    return;
  }
  if (method === 'POST') {
    const len = req.headers['content-length'];
    if (len === undefined || len === '' || Number(len) < 0 || Number(len) > BODY_LIMIT) {
      sendFail(res, '请求体太大（上限 12 MB）。', 'S92', 413);
      return;
    }
  }

  if ((method === 'GET' || method === 'HEAD') && (requestPath === '/' || requestPath === '/index.html')) {
    sendFile(res, path.join(WEB_DIR, 'index.html'));
    return;
  }

  if (requestPath.startsWith('/api/')) {
    await handleApi(req, res, method, requestPath, parsed);
    return;
  }

  if (method !== 'GET' && method !== 'HEAD') {
    sendFail(res, '未知接口：' + requestPath, 'S99', 404);
    return;
  }

  // 静态文件
  let rel = requestPath.replace(/^\/+/, '');
  if (rel === '') rel = 'index.html';
  const candidate = path.resolve(WEB_DIR, rel);
  if (!isUnderRoot(candidate, [WEB_DIR])) {
    if (!res.writableEnded) {
      res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-cache' });
      res.end('Forbidden');
    }
    return;
  }
  sendFile(res, candidate);
}

async function handleApi(req, res, method, requestPath, parsed) {
  // ------------------------------------------------------------ GET /api/env
  if (requestPath === '/api/env') {
    const payloadPresets = getPayloadPresetList();
    let payloadInfo = null;
    for (const pp of payloadPresets) {
      if (pp.preset === 'comfort' && pp.ok) { payloadInfo = pp; break; }
    }
    if (!payloadInfo) {
      for (const pp of payloadPresets) { if (pp.ok) { payloadInfo = pp; break; } }
    }
    const payload = payloadInfo
      ? { ok: true, preset: String(payloadInfo.preset), plugins: payloadInfo.plugins.slice(), builtAt: String(payloadInfo.__builtAt || '') }
      : { ok: false };
    // __builtAt 只是内部字段，不发给浏览器
    const presetsForClient = payloadPresets.map((pp) => {
      const copy = Object.assign({}, pp);
      delete copy.__builtAt;
      return copy;
    });
    sendJson(res, {
      ok: true,
      url: 'http://127.0.0.1:' + actualPort + '/',
      workspace: WORKSPACE_ROOT,
      dshVersion: getDshVersion(),
      drives: getDriveList(),
      personas: getPersonaList(),
      payload,
      payloadPresets: presetsForClient,
      hasKey: !!getApiKey(),
      platform: process.platform,
    });
    return;
  }

  // ------------------------------------------------------------ GET /api/linux/integration
  if (requestPath === '/api/linux/integration') {
    if (process.platform !== 'linux') {
      sendJson(res, { ok: true, platform: process.platform, supported: false });
      return;
    }
    sendJson(res, linuxIntegrationInfo());
    return;
  }

  // ------------------------------------------------------------ GET /api/personas
  if (requestPath === '/api/personas') {
    sendJson(res, { ok: true, items: getPersonaList() });
    return;
  }

  // ------------------------------------------------------------ GET /api/job
  if (requestPath === '/api/job') {
    const id = parsed.searchParams.get('id') || '';
    if (!id) { sendFail(res, '缺少 id。', 'S61'); return; }
    const st = getStudioJobState(id);
    if (!st) { sendFail(res, '找不到这个任务：' + id, 'S62'); return; }
    sendJson(res, { ok: true, id: st.id, done: st.done, exitCode: st.exitCode, output: st.output });
    return;
  }

  if (method !== 'POST') {
    sendFail(res, '未知接口：' + requestPath, 'S99', 404);
    return;
  }

  // ------------------------------------------------------------ POST /api/export
  if (requestPath === '/api/export') {
    const body = await readJsonBody(req);
    if (!body || body.__invalidJson || !body.slug) { sendFail(res, '缺少 slug。', 'S11'); return; }
    const slug = String(body.slug);
    if (!/^[a-z0-9][a-z0-9\-_]{1,40}$/.test(slug)) {
      sendFail(res, 'slug 只能是小写字母、数字、- 和 _（2–41 位）。', 'S12');
      return;
    }
    let targetDir = path.join(PERSONA_ROOT_DEFAULT, slug);
    if (body.dir) {
      targetDir = fullPath(String(body.dir));
      const expectA = fullPath(path.join(PERSONA_ROOT_DEFAULT, slug));
      const expectB = fullPath(path.join(DISC_PERSONA_PERSONAS, slug));
      if (targetDir !== expectA && targetDir !== expectB) {
        sendFail(res, '只允许导出到人设目录（persona/' + slug + '）：' + targetDir, 'S13');
        return;
      }
    }
    let targetExists = false;
    try { targetExists = fs.existsSync(targetDir); } catch (e) { targetExists = false; }
    if (targetExists && !body.overwrite) {
      sendFail(res, '人设目录已存在：' + targetDir, 'S14');
      return;
    }
    fs.mkdirSync(targetDir, { recursive: true });
    let written = 0;
    const files = Array.isArray(body.files) ? body.files : [];
    for (const f of files) {
      if (!f || !f.path) continue;
      const rel = String(f.path).replace(/\\/g, '/');
      const dest = fullPath(path.join(targetDir, rel));
      if (!isUnderRoot(dest, [targetDir])) {
        sendFail(res, '非法路径：' + rel, 'S15');
        return;
      }
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      if (f.base64) {
        fs.writeFileSync(dest, Buffer.from(String(f.base64), 'base64'));
      } else {
        // 与 PS 一致：文本统一成 CRLF，UTF-8 无 BOM
        const text = String(f.text == null ? '' : f.text).replace(/\r\n/g, '\n').replace(/\n/g, '\r\n');
        fs.writeFileSync(dest, text, 'utf8');
      }
      written += 1;
    }
    sendJson(res, { ok: true, dir: targetDir, files: written });
    return;
  }

  // ------------------------------------------------------------ POST /api/load
  if (requestPath === '/api/load') {
    const body = await readJsonBody(req);
    if (!body || body.__invalidJson || !body.dir) { sendFail(res, '缺少 dir。', 'S16'); return; }
    let dir = String(body.dir);
    if (!path.isAbsolute(dir)) dir = path.join(WORKSPACE_ROOT, dir);
    dir = fullPath(dir);
    if (!isUnderRoot(dir, [WORKSPACE_ROOT, DISC_PERSONA_ROOT])) {
      sendFail(res, '只能读工作区或人格房间里的路径。', 'S17');
      return;
    }
    let stat = null;
    try { stat = fs.statSync(dir); } catch (e) { stat = null; }
    if (!stat || !stat.isDirectory()) {
      sendFail(res, '目录不存在：' + dir, 'S18');
      return;
    }
    const ymlPath = path.join(dir, 'persona.yml');
    if (!fs.existsSync(ymlPath)) {
      sendFail(res, '这个目录里没有 persona.yml。', 'S19');
      return;
    }
    const ymlText = readTextUtf8(ymlPath);
    // 从 persona.yml 里抠出 system_prompt 的块内容（缩进两格）
    const lines = ymlText.split(/\r?\n/);
    let inBlock = false;
    const buf = [];
    for (const line of lines) {
      if (!inBlock) {
        if (/^system_prompt:\s*[|>]/.test(line)) inBlock = true;
        continue;
      }
      if (/^\s{2,}/.test(line)) buf.push(line.slice(2));
      else if (line.trim() === '') buf.push('');
      else break;
    }
    const prompt = buf.join('\n').trim();
    let metaObj = null;
    const metaPath = path.join(dir, 'meta.json');
    if (fs.existsSync(metaPath)) {
      metaObj = safeJsonParse(readTextUtf8(metaPath));
    }
    let avatarB64 = null;
    const avatarPath = path.join(dir, 'avatar.png');
    if (fs.existsSync(avatarPath)) {
      try { avatarB64 = fs.readFileSync(avatarPath).toString('base64'); } catch (e) { avatarB64 = null; }
    }
    sendJson(res, {
      ok: true,
      slug: path.basename(dir),
      dir,
      yml: ymlText,
      prompt,
      meta: metaObj,
      avatar: avatarB64,
    });
    return;
  }

  // ------------------------------------------------------------ POST /api/build
  if (requestPath === '/api/build') {
    const body = await readJsonBody(req);
    const rawPersona = (body && !body.__invalidJson && body.persona) ? String(body.persona) : '';
    if (!rawPersona) { sendFail(res, '缺少 persona。', 'S21'); return; }
    let personaDir = rawPersona;
    if (!path.isAbsolute(personaDir)) personaDir = path.join(WORKSPACE_ROOT, personaDir);
    personaDir = fullPath(personaDir);
    let outDir = (body && body.out) ? String(body.out) : path.join(WORKSPACE_ROOT, 'build', path.basename(personaDir));
    if (!path.isAbsolute(outDir)) outDir = path.join(WORKSPACE_ROOT, outDir);
    outDir = fullPath(outDir);
    if (!isUnderRoot(outDir, [WORKSPACE_ROOT])) {
      sendFail(res, '输出目录必须在本工作区内。', 'S22');
      return;
    }
    const preset = (body && body.payload) ? String(body.payload) : 'comfort';
    if (['none', 'comfort', 'token', 'full'].indexOf(preset) < 0) {
      sendFail(res, '不认识的插件包预设：' + preset, 'S23');
      return;
    }
    const script = toolsScript('new-disc.js');
    const toolArgs = ['--persona', personaDir, '--out', outDir, '--payload-preset', preset];
    if (body.reusePad) toolArgs.push('--reuse-pad');
    if (body.force) toolArgs.push('--force');
    const r = runNodeTool(script, toolArgs);
    let discID = '';
    const m = /DISC_OK\s+discID=([0-9a-f]+)/.exec(r.output);
    if (m) discID = m[1];
    // 打包完顺手跑一遍静态校验，别让界面上那句「会顺带校验」变成空话
    let testOk = false;
    let testOut = '';
    if (r.exitCode === 0) {
      const testScript = toolsScript('test-disc.js');
      if (fs.existsSync(testScript)) {
        const tr = runNodeTool(testScript, ['--disc', outDir]);
        testOk = (tr.exitCode === 0);
        testOut = tr.output;
      }
    }
    sendJson(res, {
      ok: r.exitCode === 0,
      code: 'BUILD',
      exitCode: r.exitCode,
      discID,
      outDir,
      output: r.output,
      payloadPreset: preset,
      testOk,
      testOutput: testOut,
    });
    return;
  }

  // ------------------------------------------------------------ POST /api/iso
  if (requestPath === '/api/iso') {
    const body = await readJsonBody(req);
    if (!body || body.__invalidJson || !body.disc) { sendFail(res, '缺少 disc。', 'S31'); return; }
    let disc = String(body.disc);
    if (!path.isAbsolute(disc)) disc = path.join(WORKSPACE_ROOT, disc);
    disc = fullPath(disc);
    let iso = (body.iso) ? String(body.iso) : path.join(WORKSPACE_ROOT, 'build', path.basename(disc) + '.iso');
    if (!path.isAbsolute(iso)) iso = path.join(WORKSPACE_ROOT, iso);
    iso = fullPath(iso);
    if (!isUnderRoot(disc, [WORKSPACE_ROOT, DISC_PERSONA_ROOT])) {
      sendFail(res, '光盘目录必须在本工作区或 DiscPersona 数据目录内。', 'S32');
      return;
    }
    if (!isUnderRoot(iso, [WORKSPACE_ROOT])) {
      sendFail(res, 'ISO 输出路径必须在本工作区内。', 'S33');
      return;
    }
    if (path.extname(iso) !== '.iso') {
      sendFail(res, 'ISO 输出文件必须以 .iso 结尾。', 'S34');
      return;
    }
    const r = runNodeTool(toolsScript('new-iso.js'), ['--source', disc, '--out', iso, '--force']);
    sendJson(res, { ok: r.exitCode === 0, code: 'ISO', exitCode: r.exitCode, iso, output: r.output });
    return;
  }

  // ------------------------------------------------------------ POST /api/burn
  if (requestPath === '/api/burn') {
    const body = await readJsonBody(req);
    if (!body || body.__invalidJson || !body.iso || !body.drive) { sendFail(res, '缺少 iso 或 drive。', 'S41'); return; }
    let iso = String(body.iso);
    if (!path.isAbsolute(iso)) iso = path.join(WORKSPACE_ROOT, iso);
    iso = fullPath(iso);
    const drive = String(body.drive);
    const script = toolsScript('burn-iso.js');
    const burnArgs = ['--iso', iso, '--drive', drive];
    if (body.async === true) {
      const jobId = startStudioJob(script, burnArgs);
      sendJson(res, { ok: true, code: 'BURN', jobId });
      return;
    }
    const r = runNodeTool(script, burnArgs);
    sendJson(res, { ok: r.exitCode === 0, code: 'BURN', exitCode: r.exitCode, output: r.output });
    return;
  }

  // ------------------------------------------------------------ POST /api/open
  if (requestPath === '/api/open') {
    const body = await readJsonBody(req);
    const targetRaw = (body && !body.__invalidJson) ? body.path : '';
    if (!targetRaw) { sendFail(res, '缺少 path。', 'S51'); return; }
    let target = String(targetRaw);
    if (!path.isAbsolute(target)) target = path.join(WORKSPACE_ROOT, target);
    target = fullPath(target);
    if (!isUnderRoot(target, [WORKSPACE_ROOT, DISC_PERSONA_ROOT])) {
      sendFail(res, '只能打开工作区或人格房间里的路径。', 'S52');
      return;
    }
    if (fs.existsSync(target)) {
      try {
        const child = spawn('xdg-open', [target], { detached: true, stdio: 'ignore' });
        child.on('error', () => { });
        child.unref();
      } catch (e) { /* 打不开不影响响应 */ }
    }
    sendJson(res, { ok: true });
    return;
  }

  // ------------------------------------------------------------ POST /api/linux/autostart
  if (requestPath === '/api/linux/autostart') {
    if (process.platform !== 'linux') {
      sendFail(res, '这组接口只在 Linux 上可用。', 'S70');
      return;
    }
    const body = await readJsonBody(req);
    const action = body && body.action ? String(body.action) : '';
    let result;
    if (action === 'install') result = runWatcherCommand(['--install']);
    else if (action === 'uninstall') result = runWatcherCommand(['--uninstall']);
    else if (action === 'start') result = startWatcherNow();
    else if (action === 'stop') result = stopWatcherNow();
    else if (action === 'status') result = { exitCode: 0, output: '' };
    else {
      sendFail(res, '不认识的 action：' + action + '（install / uninstall / start / stop / status）', 'S71');
      return;
    }
    sendJson(res, {
      ok: result.exitCode === 0,
      action,
      exitCode: result.exitCode,
      output: result.output,
      info: linuxIntegrationInfo(),
    });
    return;
  }

  // ------------------------------------------------------------ POST /api/draft
  if (requestPath === '/api/draft') {
    const body = await readJsonBody(req);
    const key = getApiKey();
    if (!key) {
      sendFail(res, '这台电脑上没有可用的 DeepSeek 凭据，AI 起草不可用（可以纯手填）。', 'S61');
      return;
    }
    const prompt = (body && !body.__invalidJson) ? String(body.prompt || '') : '';
    if (!prompt) { sendFail(res, '缺少 prompt。', 'S62'); return; }
    const payload = {
      model: 'deepseek-chat',
      temperature: 0.9,
      messages: [
        { role: 'system', content: '你是人物设定编辑。根据用户的简短设定，写出可用于角色扮演系统提示词的中文段落。只输出正文，不要解释、不要 markdown 标题以外的多余内容。' },
        { role: 'user', content: prompt },
      ],
    };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 120000);
    try {
      const resp = await fetch('https://api.deepseek.com/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer ' + key,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      if (!resp.ok) {
        let detail = '';
        try { detail = await resp.text(); } catch (e) { detail = ''; }
        sendFail(res, '调用 DeepSeek 失败：HTTP ' + resp.status + (detail ? ' ' + detail.slice(0, 300) : ''), 'S63');
        return;
      }
      const data = await resp.json();
      const content = data && data.choices && data.choices[0] && data.choices[0].message
        ? String(data.choices[0].message.content == null ? '' : data.choices[0].message.content)
        : '';
      sendJson(res, { ok: true, text: content });
    } catch (e) {
      const reason = e && e.name === 'AbortError' ? '请求超时（120 秒）' : ((e && e.message) || String(e));
      sendFail(res, '调用 DeepSeek 失败：' + reason, 'S63');
    } finally {
      clearTimeout(timer);
    }
    return;
  }

  sendFail(res, '未知接口：' + requestPath, 'S99', 404);
}

// ---------------------------------------------------------------- 启动
async function main() {
  const parsedArgs = parseArgs(process.argv.slice(2));
  if (parsedArgs.error) {
    writeStderr(usage());
    writeStderr('  ' + parsedArgs.error);
    process.exit(2);
  }
  const opts = parsedArgs.opts;
  if (opts.help) {
    process.stdout.write(usage());
    process.exit(0);
  }

  let port = opts.port;

  if (port > 0) {
    // 双击两次 start-studio.sh 时这里会撞端口。
    // 先看是不是「另一个 Studio 已经在跑」——那就直接把浏览器指过去，不再起第二个。
    const existing = await getExistingStudio(port);
    if (existing) {
      writeStudio('');
      writeStudio('DiscPersona Studio 已经在运行了。');
      writeStudio('地址：' + existing.url);
      if (existing.workspace && existing.workspace.replace(/[\\/]+$/, '') !== WORKSPACE_ROOT.replace(/[\\/]+$/, '')) {
        writeStudio('注意：它服务的是另一个工作区：' + existing.workspace);
      }
      writeStudio('要重启就先把它那个窗口关掉（Ctrl+C）。');
      if (!opts.noBrowser) openBrowser(existing.url);
      return;
    }
    // 端口被别的程序占了 → 往后找一个能用的（4791–4811）
    if (await testStudioPortBusy(port)) {
      const picked = await pickFreePort(port + 1, port + 20);
      if (!picked) {
        writeStderr('  端口 ' + port + ' 到 ' + (port + 20) + ' 都被占用了。');
        process.exit(1);
      }
      writeStudio('');
      writeStudio('端口 ' + port + ' 已被别的程序占用，改用 ' + picked + '。');
      port = picked;
    }
  }

  const server = http.createServer((req, res) => {
    handleRequest(req, res).catch((err) => {
      try {
        if (err && err.code === 'S92') sendFail(res, '请求体太大（上限 12 MB）。', 'S92', 413);
        else sendFail(res, '服务器内部错误：' + ((err && err.message) || String(err)), 'S00', 500);
      } catch (e) { /* 连接已断开 */ }
    });
  });

  // 绑定；占用时自动顺延（等价于 PS 的 HttpListener 重试循环）
  let bound = false;
  let lastBindError = null;
  for (let attempt = 0; attempt <= 20; attempt++) {
    try {
      await new Promise((resolve, reject) => {
        const onError = (err) => { server.removeListener('listening', onListening); reject(err); };
        const onListening = () => { server.removeListener('error', onError); resolve(); };
        server.once('error', onError);
        server.once('listening', onListening);
        server.listen(port, '127.0.0.1');
      });
      bound = true;
      break;
    } catch (err) {
      lastBindError = err;
      if (attempt === 20) break;
      if (port === 0) break; // 让系统挑端口都失败：不再顺延
      const next = await pickFreePort(port + 1, port + 21);
      if (!next) break;
      writeStudio('端口 ' + port + ' 绑定失败，改用 ' + next + '。');
      port = next;
    }
  }
  if (!bound) {
    writeStderr('');
    writeStderr('  Studio 启动失败：无法绑定任何端口。');
    if (lastBindError) writeStderr('  最后一次错误：' + ((lastBindError && lastBindError.message) || String(lastBindError)));
    writeStderr('  常见原因：端口被占 / 需要权限（换到 1024 以上一般就行）。');
    process.exit(1);
  }

  const address = server.address();
  actualPort = (address && typeof address === 'object') ? address.port : port;
  const url = 'http://127.0.0.1:' + actualPort + '/';

  server.on('error', (err) => {
    writeStderr('  服务器错误：' + ((err && err.message) || String(err)));
  });

  writeStudio('');
  writeStudio('DiscPersona Studio');
  writeStudio('工作区：' + WORKSPACE_ROOT);
  writeStudio('地址：' + url);
  writeStudio('按 Ctrl+C 结束。');
  writeStudio('');

  if (!opts.noBrowser) openBrowser(url);

  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    try { server.close(); } catch (e) { }
    writeStudio('Studio 已停止。');
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

main().catch((err) => {
  writeStderr('  Studio 启动失败：' + ((err && err.stack) || String(err)));
  process.exit(1);
});
