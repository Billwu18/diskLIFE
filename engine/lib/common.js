'use strict';
// diskLIFE launch engine (Linux) - shared infrastructure
// paths / output / logging / error codes / process helpers.
// Ported from engine/lib/Common.ps1. Called by engine/launch.js, never run on its own.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');
const { spawn } = require('child_process');

// Error code table: code -> one-line category (the detailed text is supplied by the caller)
const ERROR_CODES = {
  E01: 'incomplete disc',
  E02: 'pad.bin cannot be read',
  E03: 'files were modified',
  E04: 'dsh not found',
  E05: 'unsupported environment',
  E06: 'home is not writable',
  E07: 'missing credentials',
  E08: 'persona file cannot be parsed',
  E09: 'startup timed out',
  E10: 'already running',
  E11: 'sealed persona cannot be unlocked',
  E12: 'wrong passphrase or damaged sealed persona',
};

// Runtime state (set by launch.js)
const state = {
  logPath: null,
  personaHome: null,
};

// ---------------------------------------------------------------- output

function writeStdout(text) {
  try {
    fs.writeSync(1, text);
  } catch (err) {
    // stdout closed (piped into a consumer that went away); never throw from output
  }
}

// Write one line to stdout, synchronously, so a process.exit() cannot drop it.
function writeLine(text) {
  writeStdout((text == null ? '' : String(text)) + '\n');
}

function pad2(value) {
  return String(value).padStart(2, '0');
}

function formatTime(value) {
  const d = value instanceof Date ? value : new Date();
  return (
    d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) +
    ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds())
  );
}

function formatStamp(value) {
  const d = value instanceof Date ? value : new Date();
  return (
    d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate()) +
    '-' + pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds())
  );
}

// UTC "yyyy-MM-ddTHH:mm:ssZ" (same shape as the PowerShell lock's startedAt)
function formatUtcStamp(value) {
  const d = value instanceof Date ? value : new Date();
  return d.toISOString().slice(0, 19) + 'Z';
}

// UTC "yyyy-MM-ddTHH:mm:ss.fffZ" (same shape as the PowerShell workspace timestamps)
function formatUtcStampMs(value) {
  const d = value instanceof Date ? value : new Date();
  return d.toISOString().slice(0, 23) + 'Z';
}

function setLogPath(logPath) {
  state.logPath = logPath || null;
}

function getLogPath() {
  return state.logPath;
}

function setPersonaHome(personaHome) {
  state.personaHome = personaHome || null;
}

function getPersonaHome() {
  return state.personaHome;
}

// Append one log line to logs/launch-*.log. Never throws.
function addLog(message, level) {
  const lvl = level || 'Info';
  const line = '[' + formatTime() + '] [' + lvl + '] ' + message;
  if (state.logPath) {
    try {
      fs.appendFileSync(state.logPath, line + '\n', 'utf8');
    } catch (err) {
      // logging must never break a launch
    }
  }
  return line;
}

// Single failure exit: one-line conclusion + one "what to do" line + error code, exit code 1.
function stop(code, message, hint) {
  const kind = ERROR_CODES[code] || 'unknown error';
  if (state.logPath) {
    try {
      fs.appendFileSync(state.logPath, '[' + formatTime() + '] [ERROR] ' + code + ' ' + message + '\n', 'utf8');
      if (hint) {
        fs.appendFileSync(state.logPath, '[' + formatTime() + '] [ERROR] What to do: ' + hint + '\n', 'utf8');
      }
    } catch (err) {
      // ignore
    }
  }
  writeLine('');
  writeLine('  ERROR ' + code + ': ' + message);
  if (hint) {
    writeLine('  What to do: ' + hint);
  }
  writeLine('  Error code: ' + code + ' (' + kind + ')');
  writeLine('');
  process.exit(1);
}

// E05: Linux only.
function assertPlatform() {
  if (process.platform === 'linux') {
    return;
  }
  stop(
    'E05',
    'diskLIFE cannot run here: it needs Linux (current system ' + process.platform + ').',
    'Use a Linux machine and run ./start.sh in the disc root, or use start.cmd on Windows.'
  );
}

// ---------------------------------------------------------------- files / paths

// Normalize a path coming from the user / start.sh: strip surrounding quotes,
// make it absolute, drop a trailing slash. Returns null on failure.
function normalizePath(value) {
  if (value == null) {
    return null;
  }
  let p = String(value).trim();
  if (p.length >= 2 && p.startsWith('"') && p.endsWith('"')) {
    p = p.slice(1, -1).trim();
  }
  if (p.length === 0) {
    return null;
  }
  try {
    let full = path.resolve(p);
    if (full.length > 1) {
      full = full.replace(/\/+$/, '');
      if (full.length === 0) {
        full = '/';
      }
    }
    return full;
  } catch (err) {
    return null;
  }
}

// $XDG_DATA_HOME, defaulting to ~/.local/share.
function xdgDataHome() {
  const explicit = process.env.XDG_DATA_HOME;
  if (explicit && explicit.trim().length > 0) {
    return normalizePath(explicit) || explicit;
  }
  return path.join(os.homedir(), '.local', 'share');
}

function isDirectory(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch (err) {
    return false;
  }
}

function isFile(p) {
  try {
    return fs.statSync(p).isFile();
  } catch (err) {
    return false;
  }
}

function pathExists(p) {
  try {
    fs.accessSync(p);
    return true;
  } catch (err) {
    return false;
  }
}

// Create the directory and write a probe file to prove it is really writable (used by E06).
function testDirectoryWritable(dir) {
  if (!dir) {
    return false;
  }
  try {
    fs.mkdirSync(dir, { recursive: true });
    if (!isDirectory(dir)) {
      return false;
    }
    const probe = path.join(dir, '.dp-write-probe-' + crypto.randomUUID().replace(/-/g, '') + '.tmp');
    fs.writeFileSync(probe, 'ok', 'utf8');
    try {
      fs.unlinkSync(probe);
    } catch (err) {
      // ignore
    }
    return true;
  } catch (err) {
    return false;
  }
}

function sha256File(filePath) {
  const data = fs.readFileSync(filePath);
  return crypto.createHash('sha256').update(data).digest('hex');
}

// Read strictly as UTF-8, skipping a BOM automatically.
function readTextFile(filePath) {
  const buf = fs.readFileSync(filePath);
  let start = 0;
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) {
    start = 3;
  }
  return buf.subarray(start).toString('utf8');
}

// Write UTF-8 without a BOM; create the parent directory first.
function writeTextFile(filePath, text) {
  const parent = path.dirname(filePath);
  if (parent && parent !== '.' && !isDirectory(parent)) {
    fs.mkdirSync(parent, { recursive: true });
  }
  fs.writeFileSync(filePath, String(text), { encoding: 'utf8' });
}

function readJsonFileSafe(filePath) {
  try {
    return JSON.parse(readTextFile(filePath));
  } catch (err) {
    return null;
  }
}

// Copy the *contents* of a directory tree into an existing/new destination.
// Symlinks are copied as links, never followed.
function copyTreeContents(srcDir, destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  const names = fs.readdirSync(srcDir);
  for (const name of names) {
    const src = path.join(srcDir, name);
    const dest = path.join(destDir, name);
    let st;
    try {
      st = fs.lstatSync(src);
    } catch (err) {
      continue;
    }
    if (st.isSymbolicLink()) {
      let target = null;
      try {
        target = fs.readlinkSync(src);
      } catch (err) {
        continue;
      }
      try {
        fs.unlinkSync(dest);
      } catch (err) {
        // not there
      }
      fs.symlinkSync(target, dest);
    } else if (st.isDirectory()) {
      if (isFile(dest)) {
        fs.unlinkSync(dest);
      }
      copyTreeContents(src, dest);
    } else {
      try {
        if (fs.lstatSync(dest).isDirectory()) {
          fs.rmSync(dest, { recursive: true, force: true });
        }
      } catch (err) {
        // not there
      }
      fs.copyFileSync(src, dest);
      try {
        fs.chmodSync(dest, st.mode & 0o777);
      } catch (err) {
        // mode is best effort
      }
    }
  }
}

// Clear the read-only bits across a tree (or one file); returns how many were changed.
// Files copied from an ISO keep 0444/0555 and then dsh cannot rewrite settings or persona edits fail.
function clearReadOnly(targetPath) {
  if (!pathExists(targetPath)) {
    return 0;
  }
  let count = 0;
  const fix = (p) => {
    let st;
    try {
      st = fs.lstatSync(p);
    } catch (err) {
      return;
    }
    if (st.isSymbolicLink()) {
      return;
    }
    const mode = st.mode & 0o777;
    // want owner write (files) and owner write+execute (dirs)
    const wanted = st.isDirectory() ? 0o300 : 0o200;
    if ((mode & wanted) !== wanted) {
      try {
        fs.chmodSync(p, mode | wanted);
        count++;
      } catch (err) {
        // ignore
      }
    }
    if (st.isDirectory()) {
      let names = [];
      try {
        names = fs.readdirSync(p);
      } catch (err) {
        return;
      }
      for (const name of names) {
        fix(path.join(p, name));
      }
    }
  };
  fix(targetPath);
  return count;
}

// Take the last lines of a log, used by the E09 report.
function logTail(filePath, lines) {
  const count = lines || 15;
  if (!filePath || !pathExists(filePath)) {
    return [];
  }
  try {
    const text = readTextFile(filePath);
    const all = text.split(/\r?\n/);
    if (all.length > 0 && all[all.length - 1] === '') {
      all.pop();
    }
    if (all.length <= count) {
      return all;
    }
    return all.slice(all.length - count);
  } catch (err) {
    return [];
  }
}

// Read a file another process is appending to; returns '' on any error.
function readSharedText(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    return '';
  }
}

// ---------------------------------------------------------------- sleeping

// Synchronous sleep without touching PATH (the self-test clears PATH on purpose).
function sleepSync(ms) {
  const waitMs = Math.max(0, Number(ms) || 0);
  if (waitMs === 0) {
    return;
  }
  try {
    const sab = new SharedArrayBuffer(4);
    Atomics.wait(new Int32Array(sab), 0, 0, waitMs);
  } catch (err) {
    const deadline = Date.now() + waitMs;
    while (Date.now() < deadline) {
      // last resort busy wait
    }
  }
}

// ---------------------------------------------------------------- processes

// Read /proc/<pid>/stat. Parsing starts after the LAST ')' because the comm
// field may itself contain spaces or parentheses.
// Returns { state, startTicks } or null when the process does not exist.
function readProcStat(pid) {
  if (!pid || pid <= 0) {
    return null;
  }
  let text;
  try {
    text = fs.readFileSync('/proc/' + pid + '/stat', 'utf8');
  } catch (err) {
    return null;
  }
  const idx = text.lastIndexOf(')');
  if (idx < 0) {
    return null;
  }
  const fields = text.slice(idx + 1).trim().split(/\s+/);
  // fields[0] is stat field 3 (state); starttime is stat field 22 -> fields[19]
  if (fields.length < 20) {
    return null;
  }
  return { state: fields[0], startTicks: Number(fields[19]) };
}

// Linux USER_HZ is 100 on every mainstream architecture; used only for the 2 s tolerance.
const CLOCK_TICKS_PER_SEC = 100;

function getProcessStartTicks(pid) {
  const st = readProcStat(pid);
  if (!st) {
    return 0;
  }
  return Number.isFinite(st.startTicks) ? st.startTicks : 0;
}

function isProcessAlive(pid) {
  const st = readProcStat(pid);
  if (!st) {
    return false;
  }
  return st.state !== 'Z';
}

// Tell whether pid (with its recorded /proc starttime) is still alive.
// PIDs get reused, so a start time that does not match counts as exited.
function isProcessIdentity(pid, startTicks) {
  const id = Number(pid) || 0;
  if (id <= 0) {
    return false;
  }
  const st = readProcStat(id);
  if (!st || st.state === 'Z') {
    return false;
  }
  const recorded = Number(startTicks) || 0;
  if (recorded > 0) {
    const delta = Math.abs(Number(st.startTicks) - recorded);
    if (delta > 2 * CLOCK_TICKS_PER_SEC) {
      return false;
    }
  }
  return true;
}

// Kill the whole process group started with detached: true (and the pid itself as a fallback).
function killProcessGroup(pid) {
  const id = Number(pid) || 0;
  if (id <= 0) {
    return;
  }
  try {
    process.kill(-id, 'SIGKILL');
  } catch (err) {
    // group already gone
  }
  try {
    process.kill(id, 'SIGKILL');
  } catch (err) {
    // already gone
  }
}

// Open a URL with xdg-open, detached and non-blocking; failures never block a launch.
function openUrl(url) {
  if (!url) {
    return false;
  }
  try {
    const child = spawn('xdg-open', [url], { detached: true, stdio: 'ignore' });
    child.on('error', () => {});
    child.unref();
    return true;
  } catch (err) {
    return false;
  }
}

module.exports = {
  ERROR_CODES,
  addLog,
  assertPlatform,
  clearReadOnly,
  copyTreeContents,
  formatStamp,
  formatTime,
  formatUtcStamp,
  formatUtcStampMs,
  getLogPath,
  getPersonaHome,
  getProcessStartTicks,
  isDirectory,
  isFile,
  isProcessAlive,
  isProcessIdentity,
  killProcessGroup,
  logTail,
  normalizePath,
  openUrl,
  pathExists,
  readJsonFileSafe,
  readProcStat,
  readSharedText,
  readTextFile,
  setLogPath,
  setPersonaHome,
  sha256File,
  sleepSync,
  stop,
  testDirectoryWritable,
  writeLine,
  writeStdout,
  writeTextFile,
  xdgDataHome,
};
