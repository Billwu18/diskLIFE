#!/usr/bin/env node
/*
 * diskLIFE · disc watcher (Linux / Node.js)
 *
 * Linux has no Windows AutoPlay: a mounted CD cannot execute autorun.inf, and GNOME/udisks
 * deliberately refuse to run programs from removable media. This watcher is the equivalent:
 * it runs in the user session, notices an inserted disc, mounts it if the desktop did not,
 * and shows an AutoPlay-style dialog ("启动 / 稍后"). No root is needed.
 *
 * Usage:
 *   node engine/tools/disc-watch.js                  # foreground, prompt on disc insert
 *   node engine/tools/disc-watch.js --install        # XDG autostart entry (~/.config/autostart)
 *   node engine/tools/disc-watch.js --uninstall      # remove that autostart entry
 *   node engine/tools/disc-watch.js --auto           # never prompt, launch immediately
 *   node engine/tools/disc-watch.js --notify         # try a notification with a 启动 action first
 *   node engine/tools/disc-watch.js --no-mount       # do not auto-mount; only see desktop mounts
 *   node engine/tools/disc-watch.js --test-root build/linux-disc --dry-run
 *   node engine/tools/disc-watch.js --once --dry-run # one poll, then exit
 */
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { spawn, spawnSync } = require('child_process');

const HOME_DIR = os.homedir();
const XDG_CONFIG_HOME = process.env.XDG_CONFIG_HOME || path.join(HOME_DIR, '.config');
const XDG_STATE_HOME = process.env.XDG_STATE_HOME || path.join(HOME_DIR, '.local', 'state');
const AUTOSTART_DIR = path.join(XDG_CONFIG_HOME, 'autostart');
const AUTOSTART_FILE = path.join(AUTOSTART_DIR, 'disklife-disc-watch.desktop');
const STATE_DIR = path.join(XDG_STATE_HOME, 'disklife');
const DEFAULT_LOG_FILE = path.join(STATE_DIR, 'disc-watch.log');
const LOCK_FILE = path.join(STATE_DIR, 'disc-watch.pid');
const POLL_INTERVAL_MS = 2500;
const MOUNT_RETRY_MS = 15000;

const opts = {
  install: false,
  uninstall: false,
  dryRun: false,
  testRoot: '',
  noBrowser: false,
  noMount: false,
  logPath: '',
  once: false,
  help: false,
  mode: 'prompt', // prompt | auto | notify
  homeRoot: '',
  poll: false,
};

let logFile = '';
let mountWarned = false;
let timer = null;
let lockHeld = false;
const handled = new Map(); // mountpoint -> { action, id }
const discIdCache = new Map(); // mountpoint -> discID
const mountAttempts = new Map();
const missingLauncherReported = new Set();

// ---------------------------------------------------------------- output / log
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
  } catch (e) { /* logging must never break the watcher */ }
}

// ---------------------------------------------------------------- arguments
function usage() {
  return [
    'diskLIFE disc watcher (Linux)',
    '',
    'Linux has no AutoPlay. Run this watcher in your session (or install the autostart entry)',
    'and it will mount an inserted disc if needed and show a 启动 / 稍后 dialog.',
    '',
    'Usage:',
    '  node engine/tools/disc-watch.js [options]',
    '',
    'Options:',
    '  --install             Install an XDG autostart entry (runs at the next sign-in).',
    '  --uninstall           Remove that autostart entry.',
    '  --prompt              Ask before launching (default).',
    '  --auto                Launch without asking.',
    '  --notify              Try a desktop notification with a 启动 action first, then fall back.',
    '  --no-mount            Do not auto-mount media; only react to what the desktop mounts.',
    '  --poll                Use mount polling only (default: udisks2 D-Bus events + slow fallback).',
    '  --home-root <dir>     Pass a room root to the launcher (same as engine/launch.js --home-root).',
    '  --no-browser          Tell the launcher not to open a browser.',
    '  --dry-run             Detect and log, but start nothing (never prompts).',
    '  --test-root <dir>     One-shot check of one directory; exit 0 if it is a disc, 1 otherwise.',
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
    else if (lower === '--no-mount' || lower === '-nomount') opts.noMount = true;
    else if (lower === '--poll' || lower === '-poll') opts.poll = true;
    else if (lower === '--once' || lower === '-once') opts.once = true;
    else if (lower === '--help' || lower === '-h' || lower === '-help') opts.help = true;
    else if (lower === '--prompt' || lower === '-prompt') opts.mode = 'prompt';
    else if (lower === '--auto' || lower === '-auto') opts.mode = 'auto';
    else if (lower === '--notify' || lower === '-notify') opts.mode = 'notify';
    else if (lower === '--test-root' || lower === '-testdriveroot' || lower === '-test-root') {
      const v = takeValue();
      if (v === null) return 'Missing directory for --test-root.';
      opts.testRoot = v;
    } else if (lower === '--log' || lower === '-logpath' || lower === '-log') {
      const v = takeValue();
      if (v === null) return 'Missing path for --log.';
      opts.logPath = v;
    } else if (lower === '--home-root' || lower === '-homeroot') {
      const v = takeValue();
      if (v === null) return 'Missing directory for --home-root.';
      opts.homeRoot = v;
    } else {
      return 'Unknown option: ' + raw;
    }
  }
  return null;
}

// ---------------------------------------------------------------- disc detection
function isFile(p) {
  try { return fs.statSync(p).isFile(); } catch (e) { return false; }
}

function isDiscPersonaRoot(root) {
  if (!root) return false;
  const root2 = String(root).replace(/\/+$/, '') || '/';
  return isFile(path.join(root2, 'pad.bin')) && isFile(path.join(root2, 'persona', 'persona.yml'));
}

// discID = sha256(pad.bin)[0:16]; the same disc mounted twice (e.g. loop + drive) must wake only once.
function discIdOf(root) {
  if (discIdCache.has(root)) return discIdCache.get(root);
  let id = '';
  try {
    id = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, 'pad.bin'))).digest('hex').slice(0, 16);
  } catch (e) {
    id = '';
  }
  discIdCache.set(root, id);
  return id;
}

function decodeMountField(text) {
  return String(text).replace(/\\([0-7]{3})/g, (m, oct) => String.fromCharCode(parseInt(oct, 8)));
}

function readMounts() {
  let text;
  try {
    text = fs.readFileSync('/proc/mounts', 'utf8');
  } catch (e) {
    return { error: e.message, discs: [], mountpoints: new Set(), byDevice: new Map() };
  }
  const discs = [];
  const mountpoints = new Set();
  const byDevice = new Map();
  for (const line of text.split(/\r?\n/)) {
    if (!line) continue;
    const parts = line.split(' ');
    if (parts.length < 3) continue;
    const source = decodeMountField(parts[0]);
    const mountpoint = decodeMountField(parts[1]);
    const fsType = parts[2].toLowerCase();
    mountpoints.add(mountpoint);
    byDevice.set(source, mountpoint);
    if (fsType === 'iso9660' || fsType === 'udf') discs.push(mountpoint);
  }
  return { error: null, discs, mountpoints, byDevice };
}

function readSys(dev, leaf) {
  try { return fs.readFileSync('/sys/block/' + path.basename(dev) + '/' + leaf, 'utf8').trim(); }
  catch (e) { return ''; }
}

// Optical devices that currently hold media (size 4 sectors is the kernel's "no media" placeholder).
function findOpticalDevices() {
  let names = [];
  try { names = fs.readdirSync('/sys/block').filter((n) => /^sr\d+$/.test(n)); }
  catch (e) { return []; }
  const devices = [];
  for (const name of names) {
    const dev = '/dev/' + name;
    const size = parseInt(readSys(dev, 'size'), 10) || 0;
    if (size > 4) devices.push({ device: dev, size: size, model: readSys(dev, 'device/model') });
  }
  return devices;
}

function commandExists(name) {
  const paths = (process.env.PATH || '').split(path.delimiter);
  for (const dir of paths) {
    if (!dir) continue;
    try {
      fs.accessSync(path.join(dir, name), fs.constants.X_OK);
      return true;
    } catch (e) { /* keep looking */ }
  }
  return false;
}

// If udisks did not auto-mount the inserted disc, do it ourselves (no root needed).
function autoMountDevices(mounts) {
  if (opts.noMount || opts.dryRun) return false;
  let mountedAny = false;
  for (const item of findOpticalDevices()) {
    if (mounts.byDevice.has(item.device)) continue;
    const last = mountAttempts.get(item.device) || 0;
    if (Date.now() - last < MOUNT_RETRY_MS) continue;
    mountAttempts.set(item.device, Date.now());
    writeLog('Mounting ' + item.device + (item.model ? ' (' + item.model + ')' : '') + ' via udisksctl…', 'mount');
    const result = spawnSync('udisksctl', ['mount', '-b', item.device], { encoding: 'utf8', timeout: 25000 });
    const text = ((result.stdout || '') + ' ' + (result.stderr || '')).trim();
    if (result.status === 0) {
      writeLog('Mounted: ' + text, 'mount');
      mountedAny = true;
    } else {
      writeLog('Could not mount ' + item.device + ': ' + (text || 'udisksctl exited ' + result.status), 'warn');
    }
  }
  return mountedAny;
}

function readPersonaInfo(root) {
  const info = { name: '', version: '' };
  try {
    const meta = JSON.parse(fs.readFileSync(path.join(root, 'persona', 'meta.json'), 'utf8'));
    info.name = String(meta.nameJp || meta.name || meta.personaName || '').trim();
    info.version = String(meta.version || meta.personaVersion || '').trim();
  } catch (e) { /* fall back to persona.yml below */ }
  if (!info.name) {
    try {
      const yml = fs.readFileSync(path.join(root, 'persona', 'persona.yml'), 'utf8');
      const m = /^name\s*:\s*(.+?)\s*$/m.exec(yml);
      if (m) info.name = m[1].replace(/^["']|["']$/g, '').trim();
    } catch (e) { /* ignore */ }
  }
  if (!info.name) info.name = 'diskLIFE persona';
  return info;
}

// ---------------------------------------------------------------- AutoPlay-style prompt
function graphicalSession() {
  return Boolean(process.env.DISPLAY || process.env.WAYLAND_DISPLAY);
}

function promptText(root) {
  const info = readPersonaInfo(root);
  const version = info.version ? ' (v' + info.version + ')' : '';
  return '检测到 diskLIFE 光盘：' + info.name + version + '\n\n要现在唤醒这个房间吗？';
}

function tryNotification(root) {
  if (!commandExists('notify-send')) return null;
  const result = spawnSync('notify-send', [
    '--app-name=diskLIFE',
    '--icon=media-optical',
    '--action=default=启动',
    '--wait',
    'diskLIFE',
    promptText(root),
  ], { encoding: 'utf8' });
  if (result.error) return null;
  if (result.status === 0 && /(^|\n)default(\n|$)/.test(result.stdout || '')) return true;
  if (result.status === 0) return false; // notification closed without choosing 启动
  return null; // action support missing (older libnotify) -> caller falls back to a dialog
}

function askBeforeLaunch(root) {
  if (opts.mode === 'auto') return true;
  if (opts.dryRun) return false;
  if (!graphicalSession()) {
    writeLog('No graphical session (DISPLAY/WAYLAND_DISPLAY): starting without a prompt.', 'warn');
    return true;
  }
  if (opts.mode === 'notify') {
    const answer = tryNotification(root);
    if (answer !== null) return answer;
    writeLog('notify-send has no action support here; falling back to a dialog.', 'warn');
  }
  const text = promptText(root);
  const zenity = spawnSync('zenity', [
    '--question',
    '--title=diskLIFE',
    '--text=' + text,
    '--ok-label=启动',
    '--cancel-label=稍后',
    '--width=420',
  ], { encoding: 'utf8' });
  if (!zenity.error) return zenity.status === 0;
  const kdialog = spawnSync('kdialog', ['--title', 'diskLIFE', '--yesno', text], { encoding: 'utf8' });
  if (!kdialog.error) return kdialog.status === 0;
  writeLog('No dialog tool (zenity/kdialog) found: starting automatically.', 'warn');
  return true;
}

// ---------------------------------------------------------------- launching
function startLauncher(root, launchScript) {
  const args = [launchScript, '--disc-root', root, '--no-wait'];
  if (opts.noBrowser) args.push('--no-browser');
  if (opts.homeRoot) args.push('--home-root', path.resolve(opts.homeRoot));
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

// Returns true when the root looks like a disc (--test-root uses this for its exit code).
function inspectRoot(root, dryRun) {
  if (!isDiscPersonaRoot(root)) {
    writeLog('Not a diskLIFE disc, ignoring: ' + root, 'skip');
    return false;
  }
  if (handled.has(root)) return true;

  const discID = discIdOf(root);
  if (discID) {
    for (const entry of handled.values()) {
      if (entry.id === discID) {
        handled.set(root, { action: 'duplicate', id: discID });
        writeLog('Same disc is already mounted elsewhere (discID ' + discID + '); not waking it twice: ' + root, 'dup');
        return true;
      }
    }
  }

  const launchScript = path.join(root, 'engine', 'launch.js');
  if (!dryRun && !isFile(launchScript)) {
    if (!missingLauncherReported.has(root)) {
      writeLog('No engine/launch.js on the disc: ' + root, 'error');
      missingLauncherReported.add(root);
    }
    return false;
  }

  writeLog('Disc mounted: ' + root + ' (entry: engine/launch.js)', 'wake');

  if (dryRun) {
    handled.set(root, { action: 'dry', id: discID });
    writeLog('(--dry-run: detection only, nothing is started)', 'dry-run');
    return true;
  }

  if (!askBeforeLaunch(root)) {
    handled.set(root, { action: 'declined', id: discID });
    writeLog('User chose 稍后; this disc will not prompt again until it is reinserted.', 'skip');
    return true;
  }

  if (!startLauncher(root, launchScript)) return false;
  handled.set(root, { action: 'launched', id: discID });
  writeLog('Launcher started (it reports the result in its own log).', 'ok');
  return true;
}

// ---------------------------------------------------------------- polling
function tick() {
  let mounts = readMounts();
  if (mounts.error) {
    if (!mountWarned) {
      writeLog('Cannot read /proc/mounts (will retry): ' + mounts.error, 'warn');
      mountWarned = true;
    }
    return;
  }
  mountWarned = false;

  // Forget handled discs that are no longer mounted, so reinserting prompts again.
  for (const root of Array.from(handled.keys())) {
    if (!mounts.mountpoints.has(root)) {
      handled.delete(root);
      discIdCache.delete(root);
    }
  }

  if (autoMountDevices(mounts)) mounts = readMounts();

  for (const root of mounts.discs) {
    if (isDiscPersonaRoot(root)) inspectRoot(root, opts.dryRun);
  }
}

// ---------------------------------------------------------------- single instance
function isProcessAlive(pid) {
  if (!pid || pid === process.pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

function acquireLock() {
  try {
    if (fs.existsSync(LOCK_FILE)) {
      const pid = parseInt(fs.readFileSync(LOCK_FILE, 'utf8').trim(), 10);
      if (isProcessAlive(pid)) {
        writeLog('Another diskLIFE watcher is already running (PID ' + pid + '); exiting.', 'warn');
        return false;
      }
    }
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(LOCK_FILE, String(process.pid), 'utf8');
    lockHeld = true;
    return true;
  } catch (e) {
    writeLog('Cannot create the watcher lock ' + LOCK_FILE + ': ' + ((e && e.message) || String(e)), 'warn');
    return true; // do not block the watcher just because the lock file failed
  }
}

function releaseLock() {
  if (!lockHeld) return;
  lockHeld = false;
  try {
    const pid = parseInt(fs.readFileSync(LOCK_FILE, 'utf8').trim(), 10);
    if (pid === process.pid) fs.unlinkSync(LOCK_FILE);
  } catch (e) { /* ignore */ }
}

// ---------------------------------------------------------------- install / uninstall
function desktopQuote(value) {
  return '"' + String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/`/g, '\\`').replace(/\$/g, '\\$') + '"';
}

function installWatcher() {
  const scriptPath = path.resolve(__filename);
  const exec = desktopQuote(process.execPath) + ' ' + desktopQuote(scriptPath) + ' --prompt';
  const content = [
    '[Desktop Entry]',
    'Type=Application',
    'Version=1.0',
    'Name=diskLIFE disc watcher',
    'Comment=Mount discs and ask before waking the persona (Linux AutoPlay substitute)',
    'Exec=' + exec,
    'Terminal=false',
    'NoDisplay=true',
    'X-GNOME-Autostart-enabled=true',
    'X-GNOME-Autostart-Delay=2',
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
  writeLog('Linux has no AutoPlay: from the next sign-in the watcher runs in your session, mounts inserted discs if needed and asks 启动 / 稍后.', 'install');
  writeLog('Takes effect after the next sign-in; run this script once now if you want it immediately.', 'install');
  writeLog('Remove it again with: node ' + scriptPath + ' --uninstall', 'install');
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

// ---------------------------------------------------------------- udisks2 events
// The watcher reacts to udisks2 D-Bus signals (any UDisks2 activity -> debounced scan)
// instead of relying on a 2.5 s poll. A slow poll stays as a safety net for systems
// without gdbus/busctl and for events that arrive while the helper restarts.
let eventChild = null;
let eventDebounce = null;

function stopEventSource() {
  if (eventDebounce) { clearTimeout(eventDebounce); eventDebounce = null; }
  if (eventChild) {
    try { eventChild.kill('SIGTERM'); } catch (e) { /* ignore */ }
    eventChild = null;
  }
}

function noteUdisksActivity(source) {
  if (eventDebounce) return;
  eventDebounce = setTimeout(() => {
    eventDebounce = null;
    tick();
  }, 400);
}

function startEventSource() {
  if (opts.poll) {
    writeLog('Event source: disabled (--poll), using mount polling only.', 'ready');
    return false;
  }
  const monitors = [
    { name: 'gdbus', args: ['monitor', '--system', '--dest', 'org.freedesktop.UDisks2'] },
    { name: 'busctl', args: ['monitor', 'org.freedesktop.UDisks2'] },
  ];
  for (const monitor of monitors) {
    if (!commandExists(monitor.name)) continue;
    let child;
    try {
      child = spawn(monitor.name, monitor.args, { stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      continue;
    }
    child.on('error', (err) => {
      writeLog('udisks2 event source (' + monitor.name + ') failed: ' + ((err && err.message) || String(err)), 'warn');
    });
    child.stdout.on('data', (chunk) => {
      // Any UDisks2 signal (property change on a drive/block device) is enough to scan.
      if (String(chunk).trim().length > 0) noteUdisksActivity(monitor.name);
    });
    child.stderr.on('data', (chunk) => {
      const text = String(chunk).trim();
      if (text) writeLog('udisks2 event source (' + monitor.name + '): ' + text, 'warn');
    });
    child.on('exit', (code, signal) => {
      if (signal === 'SIGTERM' || signal === 'SIGKILL') return;
      writeLog('udisks2 event source (' + monitor.name + ') exited (' + (signal || code) + '); polling continues.', 'warn');
    });
    eventChild = child;
    writeLog('Event source: ' + monitor.name + ' (org.freedesktop.UDisks2) + slow polling fallback.', 'ready');
    return true;
  }
  writeLog('No udisks2 event source (gdbus/busctl) found; using mount polling only.', 'warn');
  return false;
}

// ---------------------------------------------------------------- main
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

  // --test-root is always a dry run: check only, never start or prompt.
  if (opts.testRoot) {
    const root = path.resolve(expandHome(opts.testRoot));
    writeLog('Log: ' + logFile, 'ready');
    const looksLikeDisc = inspectRoot(root, true);
    writeLog(looksLikeDisc
      ? 'diskLIFE disc detected: ' + root
      : 'Not a diskLIFE disc: ' + root, looksLikeDisc ? 'ok' : 'skip');
    process.exitCode = looksLikeDisc ? 0 : 1;
    return;
  }

  if (!acquireLock()) {
    process.exitCode = 0;
    return;
  }
  process.on('exit', releaseLock);
  process.on('SIGINT', () => { stopEventSource(); releaseLock(); process.exit(0); });
  process.on('SIGTERM', () => { stopEventSource(); releaseLock(); process.exit(0); });

  writeLog('diskLIFE disc watcher started (' + opts.mode + ' mode), waiting for a disc… (Ctrl+C to quit)', 'ready');
  writeLog('Log: ' + logFile, 'ready');

  tick(); // catch a disc that was already mounted before the watcher started

  if (opts.once) {
    writeLog('Done (--once).', 'ready');
    releaseLock();
    return;
  }

  const eventsActive = startEventSource();
  timer = setInterval(tick, eventsActive ? 10000 : POLL_INTERVAL_MS);

  process.on('exit', stopEventSource);
}

main();
