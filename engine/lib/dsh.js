'use strict';
// diskLIFE launch engine (Linux) - dsh process management
// Responsible for: finding dsh, probing ports, starting the process, waiting for the ready URL,
// and the single-instance lock. Ported from engine/lib/Dsh.ps1.

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');
const {
  isDirectory,
  isFile,
  isProcessAlive,
  normalizePath,
  pathExists,
  readJsonFileSafe,
  readSharedText,
  sleepSync,
  testDirectoryWritable,
  writeTextFile,
} = require('./common');

const DSH_READY_REGEX = /http:\/\/127\.0\.0\.1:\d+\/\?token=[^\s"'<>]+/;
// Package-manager dirs: the room root goes one level up (docs/linux.md: ~/.local/bin/dsh -> ~/.local).
const MANAGER_DIRS = ['npm-global', 'node_modules', '.bin', 'bin', 'npm', 'pnpm-global', 'yarn'];

// ---------------------------------------------------------------- resolution

// Find the dsh executable. Priority:
//   explicit (--dsh-path) > DISCPERSONA_DSH > `dsh` on PATH
// Returns the full path, or null when nothing is found.
// Any regular file counts: it may be a symlink to the JS entry (shebang #!/usr/bin/env node)
// or a shell shim, and the spawn helper below adapts to either.
function resolveDshExecutable(explicit) {
  const candidates = [];
  if (explicit) {
    candidates.push(explicit);
  }
  if (process.env.DISCPERSONA_DSH) {
    candidates.push(process.env.DISCPERSONA_DSH);
  }

  const dirs = String(process.env.PATH || '').split(':');
  for (const dir of dirs) {
    if (!dir || dir.trim().length === 0) {
      continue;
    }
    candidates.push(path.join(dir, 'dsh'));
  }

  for (const candidate of candidates) {
    if (!candidate || String(candidate).trim().length === 0) {
      continue;
    }
    const full = normalizePath(candidate);
    if (!full) {
      continue;
    }
    if (isFile(full)) {
      return full;
    }
  }
  return null;
}

// Decide how to execute a dsh path: direct binary, `node <path>` for a JS entry
// (including a symlink to one), or `sh <path>` for a shell shim.
// This also copes with a shim that has no executable bit set.
function buildSpawnCommand(dshPath) {
  let firstLine = '';
  try {
    const fd = fs.openSync(dshPath, 'r');
    try {
      const buf = Buffer.alloc(256);
      const read = fs.readSync(fd, buf, 0, buf.length, 0);
      firstLine = buf.subarray(0, read).toString('utf8').split('\n')[0];
    } finally {
      fs.closeSync(fd);
    }
  } catch (err) {
    return { command: dshPath, args: [] };
  }

  const shebang = firstLine.replace(/\r$/, '').trim();
  if (!shebang.startsWith('#!')) {
    return { command: dshPath, args: [] };
  }

  const parts = shebang.slice(2).trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) {
    return { command: dshPath, args: [] };
  }

  const interpreter = parts[0];
  const interpreterLeaf = path.basename(interpreter);

  if (interpreterLeaf === 'env') {
    const name = parts.slice(1).find((part) => !part.startsWith('-')) || '';
    return commandForInterpreter(name, dshPath, null);
  }

  return commandForInterpreter(interpreterLeaf, dshPath, interpreter);
}

function commandForInterpreter(name, dshPath, fullInterpreter) {
  const leaf = String(name || '').toLowerCase();
  if (leaf === 'node' || leaf === 'nodejs' || leaf === 'bun' || leaf === 'deno') {
    // dsh always ships as a Node entry point; run it with the node that runs this launcher.
    return { command: process.execPath, args: [dshPath] };
  }
  if (leaf === 'sh' || leaf === 'bash' || leaf === 'dash' || leaf === 'zsh' || leaf === 'ksh') {
    if (fullInterpreter && path.isAbsolute(fullInterpreter) && pathExists(fullInterpreter)) {
      return { command: fullInterpreter, args: [dshPath] };
    }
    const guess = '/bin/' + leaf;
    if (pathExists(guess)) {
      return { command: guess, args: [dshPath] };
    }
    return { command: '/bin/sh', args: [dshPath] };
  }
  if (fullInterpreter && path.isAbsolute(fullInterpreter) && pathExists(fullInterpreter)) {
    return { command: fullInterpreter, args: [dshPath] };
  }
  return { command: dshPath, args: [] };
}

// ---------------------------------------------------------------- port probe

// Synchronous probe: /proc/net/tcp{,6} LISTEN (state 0A) entries. Linux only by design.
function isPortListening(port) {
  const value = Number(port) || 0;
  if (value <= 0 || value > 65535) {
    return false;
  }
  const wanted = value.toString(16).toUpperCase().padStart(4, '0');
  for (const file of ['/proc/net/tcp', '/proc/net/tcp6']) {
    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch (err) {
      continue;
    }
    const lines = text.split('\n');
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i];
      if (!line || line.trim().length === 0) {
        continue;
      }
      const cols = line.trim().split(/\s+/);
      if (cols.length < 4) {
        continue;
      }
      if (cols[3] !== '0A') {
        continue;
      }
      const local = cols[1];
      const idx = local.lastIndexOf(':');
      if (idx < 0) {
        continue;
      }
      if (local.slice(idx + 1).toUpperCase() === wanted) {
        return true;
      }
    }
  }
  return false;
}

// ---------------------------------------------------------------- spawning

function buildDshArgs(port, patches) {
  const args = ['--profile', 'web'];
  for (const patchPath of patches || []) {
    if (!patchPath || String(patchPath).trim().length === 0) {
      continue;
    }
    args.push('--patch', patchPath);
  }
  args.push('--port', String(port));
  args.push('--no-open');
  return args;
}

// Start dsh web with DSH_HOME = homeDir and cwd = workingDir.
// stdout/stderr go straight to log files. The child is detached in its own process group
// and unref()ed, so it survives the launcher exiting.
function startDshInstance(options) {
  const args = buildDshArgs(options.port || 0, options.patches || []);
  const { command, args: prefixArgs } = buildSpawnCommand(options.dshPath);

  const outFd = fs.openSync(options.stdoutPath, 'w');
  let errFd;
  try {
    errFd = fs.openSync(options.stderrPath, 'w');
  } catch (err) {
    fs.closeSync(outFd);
    throw err;
  }

  let child;
  try {
    child = spawn(command, prefixArgs.concat(args), {
      cwd: options.workingDir,
      env: Object.assign({}, process.env, { DSH_HOME: options.homeDir }),
      detached: true,
      stdio: ['ignore', outFd, errFd],
    });
  } finally {
    try {
      fs.closeSync(outFd);
    } catch (err) {
      // ignore
    }
    try {
      fs.closeSync(errFd);
    } catch (err) {
      // ignore
    }
  }

  // Consume the async error event; a failed spawn is detected through pid === undefined.
  child.on('error', () => {});

  const instance = {
    child: child,
    pid: child.pid || 0,
    stdoutPath: options.stdoutPath,
    stderrPath: options.stderrPath,
    exited: false,
    exitCode: null,
  };
  if (!instance.pid) {
    instance.exited = true;
    return instance;
  }
  child.unref();
  return instance;
}

// Poll the stdout log for the ready line; also tell the caller whether the process exited.
// Blocking sleep (Atomics.wait) keeps this fully synchronous and independent of PATH.
function waitDshUrl(instance, timeoutSec) {
  const seconds = Number.isFinite(Number(timeoutSec)) ? Number(timeoutSec) : 60;
  const deadline = Date.now() + Math.max(0, seconds) * 1000;
  let url = null;
  let exited = false;
  let exitCode = null;

  while (Date.now() < deadline) {
    if (instance.stdoutPath && pathExists(instance.stdoutPath)) {
      const text = readSharedText(instance.stdoutPath);
      const m = DSH_READY_REGEX.exec(text);
      if (m) {
        url = m[0];
        break;
      }
    }
    if (instance.pid > 0 && !isProcessAlive(instance.pid)) {
      exited = true;
      exitCode = instance.exitCode;
      // Read once more so a "printed then exited" case is not missed
      if (instance.stdoutPath && pathExists(instance.stdoutPath)) {
        const text = readSharedText(instance.stdoutPath);
        const m = DSH_READY_REGEX.exec(text);
        if (m) {
          url = m[0];
        }
      }
      break;
    }
    sleepSync(250);
  }

  if (!url && instance.pid > 0 && !isProcessAlive(instance.pid)) {
    exited = true;
  }
  return { url: url, exited: exited, exitCode: exitCode };
}

// ---------------------------------------------------------------- lock

// Read home/.lock (JSON). Returns null when missing or corrupt.
function readLock(lockPath) {
  if (!pathExists(lockPath)) {
    return null;
  }
  const obj = readJsonFileSafe(lockPath);
  if (!obj || typeof obj !== 'object') {
    return null;
  }
  return obj;
}

function writeLock(lockPath, options) {
  const obj = {
    pid: Number(options.pid) || 0,
    startTicks: Number(options.startTicks) || 0,
    startedAt: options.startedAt || '',
    port: Number(options.port) || 0,
    host: os.hostname(),
  };
  writeTextFile(lockPath, JSON.stringify(obj, null, 2) + '\n');
}

// ---------------------------------------------------------------- room-root inference

function isUnderOrEqual(candidate, base) {
  return candidate === base || candidate.startsWith(base + path.sep);
}

function isForbiddenInstallRoot(fullPath) {
  const bad = ['/usr', '/bin', '/sbin', '/lib', '/lib64', '/etc', '/boot', '/proc', '/sys', '/dev'];
  const home = os.homedir();
  if (home) {
    bad.push(path.join(home, '.config'));
    bad.push(path.join(home, '.cache'));
  }
  for (const base of bad) {
    if (isUnderOrEqual(fullPath, base) || isUnderOrEqual(base, fullPath)) {
      return true;
    }
  }
  return false;
}

// Tell whether a directory can anchor "where dsh is installed":
// exclude system directories and user config/cache, and require write access.
function isUsableInstallRoot(candidatePath) {
  if (!candidatePath) {
    return false;
  }
  const full = normalizePath(candidatePath);
  if (!full || !isDirectory(full)) {
    return false;
  }
  if (isForbiddenInstallRoot(full)) {
    return false;
  }
  return testDirectoryWritable(full);
}

// Infer "where dsh is installed" as the default location for persona rooms.
// 1. find the dsh executable (--dsh-path / DISCPERSONA_DSH / PATH)
// 2. if its directory leaf is a package-manager dir, go one level up
// 3. that directory must be a suitable root (not system/config/cache, and writable)
function getInstallRootFromDsh(dshPath) {
  const exe = resolveDshExecutable(dshPath);
  if (!exe) {
    return null;
  }
  const dir = path.dirname(exe);
  const leaf = path.basename(dir).toLowerCase();
  if (MANAGER_DIRS.includes(leaf)) {
    const up = path.dirname(dir);
    if (isUsableInstallRoot(up)) {
      return up;
    }
  }
  if (isUsableInstallRoot(dir)) {
    return dir;
  }
  return null;
}

module.exports = {
  DSH_READY_REGEX,
  buildDshArgs,
  buildSpawnCommand,
  getInstallRootFromDsh,
  isPortListening,
  isUsableInstallRoot,
  readLock,
  resolveDshExecutable,
  startDshInstance,
  waitDshUrl,
  writeLock,
};
