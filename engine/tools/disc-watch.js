#!/usr/bin/env node
/*
 * DiscPersona · disc watcher (Linux / Node.js)
 *
 * Insert a disc, wake the persona: polls /proc/mounts for ISO9660/UDF mounts, and when a
 * mount root carries pad.bin + persona/persona.yml it starts that disc's launcher.
 *
 * Usage:
 *   node engine/tools/disc-watch.js                  # foreground, Ctrl+C to quit
 *   node engine/tools/disc-watch.js --install        # XDG autostart entry (~/.config/autostart)
 *   node engine/tools/disc-watch.js --uninstall      # remove that autostart entry
 *   node engine/tools/disc-watch.js --test-root build/linux-disc --dry-run
 *   node engine/tools/disc-watch.js --once --dry-run # one poll, then exit
 */
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const HOME_DIR = os.homedir();
const XDG_CONFIG_HOME = process.env.XDG_CONFIG_HOME || path.join(HOME_DIR, '.config');
const XDG_STATE_HOME = process.env.XDG_STATE_HOME || path.join(HOME_DIR, '.local', 'state');
const AUTOSTART_DIR = path.join(XDG_CONFIG_HOME, 'autostart');
const AUTOSTART_FILE = path.join(AUTOSTART_DIR, 'disklife-disc-watch.desktop');
const DEFAULT_LOG_FILE = path.join(XDG_STATE_HOME, 'disklife', 'disc-watch.log');
const POLL_INTERVAL_MS = 3000;
const DUPLICATE_WINDOW_MS = 15000;

const opts = {
  install: false,
  uninstall: false,
  dryRun: false,
  testRoot: '',
  noBrowser: false,
  logPath: '',
  once: false,
  help: false,
};

let logFile = '';
let lastRoot = '';
let lastTick = 0;
let mountWarned = false;
let timer = null;
const missingLauncherReported = new Set();

// ---------------------------------------------------------------- 输出 / 日志
function timestamp() {
  const d = new Date();
  const pad2 = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) +
    ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

function writeLog(message, level) {
  const line = timestamp() + ' [' + (level || 'info') + '] ' + message;
  process.stdout.write(line + '\n');
  try {
    fs.mkdirSync(path.dirname(logFile), { recursive: true });
    fs.appendFileSync(logFile, line + '\n');
  } catch (e) { /* 日志写不进去不影响守望 */ }
}

// ---------------------------------------------------------------- 参数
function usage() {
  return [
    'DiscPersona disc watcher (Linux)',
    '',
    'Usage:',
    '  node engine/tools/disc-watch.js [options]',
    '',
    'Options:',
    '  --install             Install an XDG autostart entry (runs this script with --no-browser).',
    '  --uninstall           Remove that autostart entry.',
    '  --dry-run             Detect and log, but start nothing.',
    '  --test-root <dir>     One-shot check of one directory; exit 0 if it looks like a disc, 1 otherwise.',
    '  --no-browser          Tell the launcher not to open a browser.',
    '  --log <path>          Log file (default: $XDG_STATE_HOME/disklife/disc-watch.log).',
    '  --once                Run one poll, then exit.',
    '  --help                Print this help.',
    '',
  ].join('\n');
}

function expandHome(p) {
  if (p === '~') return HOME_DIR;
  if (p.startsWith('~/')) return path.join(HOME_DIR, p.slice(2));
  return p;
}

function parseArgs(argv) {
  for (let i = 0; i < argv.length; i++) {
    const raw = argv[i];
    let name = raw;
    let inline = null;
    const eq = raw.indexOf('=');
    if (raw.startsWith('--') && eq > 2) {
      name = raw.slice(0, eq);
      inline = raw.slice(eq + 1);
    }
    const lower = name.toLowerCase();
    const takeValue = () => {
      if (inline !== null) return inline;
      if (i + 1 >= argv.length) return null;
      i += 1;
      return argv[i];
    };
    if (lower === '--install' || lower === '-install') opts.install = true;
    else if (lower === '--uninstall' || lower === '-uninstall') opts.uninstall = true;
    else if (lower === '--dry-run' || lower === '-dryrun') opts.dryRun = true;
    else if (lower === '--no-browser' || lower === '-nobrowser') opts.noBrowser = true;
    else if (lower === '--once' || lower === '-once') opts.once = true;
    else if (lower === '--help' || lower === '-h' || lower === '-help') opts.help = true;
    else if (lower === '--test-root' || lower === '-testdriveroot' || lower === '-test-root') {
      const v = takeValue();
      if (v === null) return 'Missing directory for --test-root.';
      opts.testRoot = v;
    } else if (lower === '--log' || lower === '-logpath' || lower === '-log') {
      const v = takeValue();
      if (v === null) return 'Missing path for --log.';
      opts.logPath = v;
    } else {
      return 'Unknown option: ' + raw;
    }
  }
  return null;
}

// ---------------------------------------------------------------- 盘识别
function isFile(p) {
  try { return fs.statSync(p).isFile(); } catch (e) { return false; }
}

function isDiscPersonaRoot(root) {
  if (!root) return false;
  const root2 = String(root).replace(/\/+$/, '') || '/';
  return isFile(path.join(root2, 'pad.bin')) && isFile(path.join(root2, 'persona', 'persona.yml'));
}

function decodeMountField(text) {
  return String(text).replace(/\\([0-7]{3})/g, (m, oct) => String.fromCharCode(parseInt(oct, 8)));
}

function readMounts() {
  let text;
  try {
    text = fs.readFileSync('/proc/mounts', 'utf8');
  } catch (e) {
    return { error: e.message, discs: [], mountpoints: new Set() };
  }
  const discs = [];
  const mountpoints = new Set();
  for (const line of text.split(/\r?\n/)) {
    if (!line) continue;
    const parts = line.split(' ');
    if (parts.length < 3) continue;
    const mountpoint = decodeMountField(parts[1]);
    const fsType = parts[2].toLowerCase();
    mountpoints.add(mountpoint);
    if (fsType === 'iso9660' || fsType === 'udf') discs.push(mountpoint);
  }
  return { error: null, discs, mountpoints };
}

// ---------------------------------------------------------------- 启动
function startLauncher(root, launchScript) {
  const args = [launchScript, '--disc-root', root, '--no-wait'];
  if (opts.noBrowser) args.push('--no-browser');
  try {
    const fd = fs.openSync(logFile, 'a');
    let child;
    try {
      child = spawn(process.execPath, args, {
        cwd: root,
        detached: true,
        stdio: ['ignore', fd, fd],
      });
    } finally {
      try { fs.closeSync(fd); } catch (e) { /* ignore */ }
    }
    child.on('error', (err) => {
      writeLog('Launcher failed after start: ' + ((err && err.message) || String(err)), 'error');
    });
    child.unref();
    return true;
  } catch (e) {
    writeLog('Failed to start the launcher: ' + ((e && e.message) || String(e)), 'error');
    return false;
  }
}

// 返回 true = 这个目录看起来是 DiscPersona 盘（--test-root 用它决定退出码）
function inspectRoot(root, dryRun) {
  if (!isDiscPersonaRoot(root)) {
    writeLog('Not a DiscPersona disc, ignoring: ' + root, 'skip');
    return false;
  }

  const now = Date.now();
  if (root === lastRoot) {
    // 同一个挂载点在轮询里会一直出现：只在这个窗口里提示一次，别刷屏
    if (now - lastTick < DUPLICATE_WINDOW_MS) {
      writeLog('Same disc fired twice within 15s, skipping: ' + root, 'dup');
    }
    return true;
  }

  const launchScript = path.join(root, 'engine', 'launch.js');
  if (!dryRun && !isFile(launchScript)) {
    if (!missingLauncherReported.has(root)) {
      writeLog('No engine/launch.js on the disc: ' + root, 'error');
      missingLauncherReported.add(root);
    }
    return false;
  }

  writeLog('Disc inserted, waking up: ' + root + ' (entry: engine/launch.js)', 'wake');

  if (dryRun) {
    lastRoot = root;
    lastTick = now;
    writeLog('(--dry-run: detection only, nothing is started)', 'dry-run');
    return true;
  }

  if (!startLauncher(root, launchScript)) return false;

  writeLog('Launcher started (it reports the result in its own log).', 'ok');
  lastRoot = root;
  lastTick = Date.now();
  return true;
}

// ---------------------------------------------------------------- 轮询
function tick() {
  const mounts = readMounts();
  if (mounts.error) {
    if (!mountWarned) {
      writeLog('Cannot read /proc/mounts (will retry): ' + mounts.error, 'warn');
      mountWarned = true;
    }
    return;
  }
  mountWarned = false;

  // 盘拔掉后清掉去重状态，重新插回来可以立刻再唤醒
  if (lastRoot && !mounts.mountpoints.has(lastRoot)) {
    const gone = lastRoot;
    writeLog('Mount disappeared: ' + gone, 'event');
    lastRoot = '';
    lastTick = 0;
    missingLauncherReported.delete(gone);
  }

  for (const root of mounts.discs) {
    if (isDiscPersonaRoot(root)) inspectRoot(root, opts.dryRun);
  }
}

// ---------------------------------------------------------------- 安装
function desktopQuote(value) {
  return '"' + String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/`/g, '\\`').replace(/\$/g, '\\$') + '"';
}

function installWatcher() {
  const scriptPath = path.resolve(__filename);
  const exec = desktopQuote(process.execPath) + ' ' + desktopQuote(scriptPath) + ' --no-browser';
  const content = [
    '[Desktop Entry]',
    'Type=Application',
    'Version=1.0',
    'Name=DiscPersona disc watcher',
    'Comment=Wake the persona when a DiscPersona disc is mounted',
    'Exec=' + exec,
    'Terminal=false',
    'NoDisplay=false',
    'X-GNOME-Autostart-enabled=true',
    '',
  ].join('\n');
  try {
    fs.mkdirSync(AUTOSTART_DIR, { recursive: true });
    fs.writeFileSync(AUTOSTART_FILE, content, { encoding: 'utf8', mode: 0o644 });
  } catch (e) {
    writeLog('Failed to install the autostart entry: ' + ((e && e.message) || String(e)), 'error');
    return 1;
  }
  writeLog('Installed XDG autostart entry: ' + AUTOSTART_FILE, 'install');
  writeLog('Node: ' + process.execPath, 'install');
  writeLog('Takes effect after the next sign-in; run this script once now if you want it immediately.', 'install');
  writeLog('The watcher only reacts to newly mounted discs; if the desktop mounts discs itself, insert normally.', 'install');
  return 0;
}

function uninstallWatcher() {
  let existed = false;
  try { existed = fs.existsSync(AUTOSTART_FILE); } catch (e) { existed = false; }
  if (existed) {
    try {
      fs.unlinkSync(AUTOSTART_FILE);
      writeLog('Removed the XDG autostart entry: ' + AUTOSTART_FILE, 'uninstall');
    } catch (e) {
      writeLog('Failed to remove the autostart entry: ' + ((e && e.message) || String(e)), 'error');
      return 1;
    }
  } else {
    writeLog('No autostart entry found — it may never have been installed: ' + AUTOSTART_FILE, 'uninstall');
  }
  return 0;
}

// ---------------------------------------------------------------- 主流程
function main() {
  const argError = parseArgs(process.argv.slice(2));
  if (argError) {
    process.stderr.write(usage() + '\n');
    process.stderr.write('  ' + argError + '\n');
    process.exit(2);
  }
  if (opts.help) {
    process.stdout.write(usage());
    return;
  }

  logFile = opts.logPath ? expandHome(opts.logPath) : DEFAULT_LOG_FILE;

  if (opts.install) { process.exitCode = installWatcher(); return; }
  if (opts.uninstall) { process.exitCode = uninstallWatcher(); return; }

  // --test-root 永远是 dry-run：只检查，不启动任何东西
  if (opts.testRoot) {
    const root = path.resolve(expandHome(opts.testRoot));
    writeLog('Log: ' + logFile, 'ready');
    const looksLikeDisc = inspectRoot(root, true);
    writeLog(looksLikeDisc
      ? 'DiscPersona disc detected: ' + root
      : 'Not a DiscPersona disc: ' + root, looksLikeDisc ? 'ok' : 'skip');
    process.exitCode = looksLikeDisc ? 0 : 1;
    return;
  }

  writeLog('Disc watcher started, waiting for a disc… (Ctrl+C to quit)', 'ready');
  writeLog('Log: ' + logFile, 'ready');

  tick(); // 先扫一遍：脚本启动前就已经挂好的盘也要算

  if (opts.once) {
    writeLog('Done (--once).', 'ready');
    return;
  }

  timer = setInterval(tick, POLL_INTERVAL_MS);

  const stop = () => {
    if (timer) clearInterval(timer);
    timer = null;
    writeLog('Disc watcher stopped.', 'ready');
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

main();
