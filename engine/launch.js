#!/usr/bin/env node
'use strict';
// diskLIFE launch engine (Linux)
// Usage (called by start.sh in the disc root):
//   node <disc>/engine/launch.js --disc-root <disc>
//
// Optional options (for tests and troubleshooting; not needed in normal use):
//   --dsh-path <path>        full path to the dsh executable (same as the DISCPERSONA_DSH env var)
//   --home-root <path>       parent directory of the persona rooms (default follows the dsh install)
//   --start-timeout-sec <n>  max seconds to wait for readiness (default 60)
//   --no-browser             do not open a browser automatically
//   --upgrade-persona        overwrite the room persona with the one on the disc (backed up first)
//   --no-wait                return right after launch instead of waiting for Enter
//   --help                   print this usage and exit 0

const fs = require('fs');
const path = require('path');

const common = require('./lib/common');
const {
  addLog,
  assertPlatform,
  clearReadOnly,
  copyTreeContents,
  formatStamp,
  formatTime,
  formatUtcStamp,
  getLogPath,
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
  setLogPath,
  setPersonaHome,
  sha256File,
  stop,
  testDirectoryWritable,
  writeLine,
  writeTextFile,
  xdgDataHome,
} = common;

const seal = require('./lib/seal');
const { buildPersonaPatchText, readPersonaDocument } = require('./lib/yaml');
const {
  credentialHasLlm,
  ensureCredentialPermissions,
  getSourceHome,
  importLlmCredentials,
} = require('./lib/credentials');
const { assertDiscManifest } = require('./lib/manifest');
const {
  isPortListening,
  readLock,
  resolveDshExecutable,
  startDshInstance,
  waitDshUrl,
  writeLock,
  getInstallRootFromDsh,
} = require('./lib/dsh');
const {
  compareVersionText,
  getLorebookText,
  readMetaFile,
  syncPersonaCard,
  syncWorkspace,
} = require('./lib/persona');

const USAGE = [
  'diskLIFE Linux launcher',
  '',
  'Usage: node engine/launch.js --disc-root <dir> [options]',
  '',
  'Options:',
  '  --disc-root <dir>        root of this disc (normally passed by start.sh)',
  '  --dsh-path <path>        dsh executable (default: DISCPERSONA_DSH, then dsh on PATH)',
  '  --home-root <dir>        parent directory of the persona rooms',
  '  --start-timeout-sec <n>  seconds to wait for the ready URL (default 60)',
  '  --no-browser             do not open a browser automatically',
  '  --upgrade-persona        replace the room persona with the disc persona (backed up first)',
  '  --no-wait                return right after launch instead of waiting for Enter',
  '  --help                   show this help and exit',
].join('\n');

const BOOLEAN_OPTIONS = {
  nobrowser: 'noBrowser',
  upgradepersona: 'upgradePersona',
  nowait: 'noWait',
  passphrasestdin: 'passphraseStdin',
};

const VALUE_OPTIONS = {
  discroot: 'discRoot',
  dshpath: 'dshPath',
  homeroot: 'homeRoot',
  starttimeoutsec: 'startTimeoutSec',
};

function parseArgv(argv) {
  const opts = {
    discRoot: null,
    dshPath: null,
    homeRoot: null,
    startTimeoutSec: 60,
    noBrowser: false,
    upgradePersona: false,
    passphraseStdin: false,
    noWait: false,
    help: false,
  };

  let i = 0;
  while (i < argv.length) {
    const arg = argv[i];
    if (!arg || arg === '') {
      i++;
      continue;
    }
    if (arg === '-h' || arg === '--help' || arg === '-help') {
      opts.help = true;
      i++;
      continue;
    }
    if (!arg.startsWith('-')) {
      return { error: 'Unexpected argument: ' + arg };
    }

    let body = arg.replace(/^-+/, '');
    let inlineValue = null;
    const eq = body.indexOf('=');
    if (eq >= 0) {
      inlineValue = body.slice(eq + 1);
      body = body.slice(0, eq);
    }
    const key = body.toLowerCase().replace(/[-_]/g, '');

    if (Object.prototype.hasOwnProperty.call(BOOLEAN_OPTIONS, key)) {
      const name = BOOLEAN_OPTIONS[key];
      if (inlineValue == null) {
        opts[name] = true;
      } else {
        const v = inlineValue.trim().toLowerCase();
        opts[name] = !(v === 'false' || v === '0' || v === 'no' || v === 'off');
      }
      i++;
      continue;
    }

    if (Object.prototype.hasOwnProperty.call(VALUE_OPTIONS, key)) {
      const name = VALUE_OPTIONS[key];
      let value = inlineValue;
      if (value == null) {
        if (i + 1 >= argv.length) {
          return { error: 'Missing value for option: ' + arg };
        }
        value = argv[i + 1];
        i++;
      }
      if (name === 'startTimeoutSec') {
        const n = Number(value);
        if (!Number.isFinite(n) || n < 0) {
          return { error: 'Invalid value for ' + arg + ': ' + value };
        }
        opts.startTimeoutSec = Math.floor(n);
      } else {
        opts[name] = value;
      }
      i++;
      continue;
    }

    return { error: 'Unknown option: ' + arg };
  }

  return { opts: opts };
}

// ---------------------------------------------------------------- helpers used by the boot sequence

function failUsage(message) {
  try {
    fs.writeSync(2, USAGE + '\n\n');
    if (message) {
      fs.writeSync(2, '  ' + message + '\n\n');
    }
  } catch (err) {
    // ignore
  }
  process.exit(2);
}

// First-run bootstrap: let dsh drop its shipped web profile into DSH_HOME/profiles/web itself.
// Cold-start once with --port 0, grab the ready URL (after the profile is written), then kill it.
function bootstrapProfile(dshExe, homeDir, workspaceDir, logsDir, stamp) {
  const stdout = path.join(logsDir, 'bootstrap-' + stamp + '.log');
  const stderr = path.join(logsDir, 'bootstrap-' + stamp + '.err.log');
  let inst;
  try {
    inst = startDshInstance({
      dshPath: dshExe,
      homeDir: homeDir,
      workingDir: workspaceDir,
      port: 0,
      patches: [],
      stdoutPath: stdout,
      stderrPath: stderr,
    });
  } catch (err) {
    addLog('Bootstrap: could not start dsh: ' + err.message, 'Warn');
    return false;
  }
  if (!inst.pid) {
    addLog('Bootstrap: could not start dsh (no process).', 'Warn');
    return false;
  }
  addLog('Bootstrap: cold-starting dsh to generate the shipped web profile (PID ' + inst.pid + ').');
  const ready = waitDshUrl(inst, 45);
  if (inst.pid > 0 && isProcessAlive(inst.pid)) {
    killProcessGroup(inst.pid);
  }
  if (!ready.url) {
    addLog('Bootstrap cold start never reported a ready URL.', 'Warn');
    for (const line of logTail(stdout, 15)) {
      addLog('  | ' + line, 'Warn');
    }
    return false;
  }
  // A printed ready URL is enough to call this step a success; profiles/web is filled in by the real launch.
  return true;
}

// Idempotent catch-up for credentials / seed / AGENTS.md, run on every launch.
function initializePersonaAssets(homeDir, personaDir, workspaceDir) {
  // 1) credentials: copy the three LLM records only, never parse or print them
  const targetCred = path.join(homeDir, '.credentials.yaml');
  if (!credentialHasLlm(targetCred)) {
    const sourceHome = getSourceHome();
    if (!sourceHome) {
      stop(
        'E07',
        'Cannot find the DeepSeek Harness credentials directory on this machine.',
        'Sign in to DSH once on this machine first, or point DISCPERSONA_SOURCE_HOME at the source home.'
      );
    }
    const sourceCred = path.join(sourceHome, '.credentials.yaml');
    if (!credentialHasLlm(sourceCred)) {
      stop(
        'E07',
        'No usable DeepSeek credentials in the source home (' + sourceHome + ').',
        'Sign in to DSH once on this machine first (open DSH and sign in with your DeepSeek account), then insert this disc.'
      );
    }
    const imported = importLlmCredentials(sourceCred, targetCred);
    if (!imported.ok) {
      if (imported.reason === 'write-failed') {
        stop(
          'E06',
          'Cannot write credentials into this room: ' + targetCred,
          'Check free disk space and folder permissions, then retry.'
        );
      }
      stop(
        'E07',
        'Credentials import failed (' + imported.reason + '): ' + sourceCred,
        'Sign in to DSH once on this machine, then retry.'
      );
    }
    addLog('DeepSeek credentials imported (records copied, key values never read).');
  }

  // dsh refuses to start unless .credentials.yaml is owner-only (0600).
  // This also self-heals a room created by an older build that left it at 0644.
  ensureCredentialPermissions(targetCred);

  // 2) seed: lay it down once while the room is still empty, so a user-edited memory is never overwritten
  const seedSrc = path.join(personaDir, 'seed');
  const seedDst = path.join(workspaceDir, 'memories');
  let seedMissing = !isDirectory(seedDst);
  if (!seedMissing) {
    try {
      seedMissing = fs.readdirSync(seedDst).length === 0;
    } catch (err) {
      seedMissing = true;
    }
  }
  if (isDirectory(seedSrc) && seedMissing) {
    try {
      fs.mkdirSync(seedDst, { recursive: true });
      copyTreeContents(seedSrc, seedDst);
      clearReadOnly(seedDst);
      addLog('persona/seed copied to: ' + seedDst);
    } catch (err) {
      addLog('persona/seed copy failed (launch continues): ' + err.message, 'Warn');
    }
  }

  // 3) AGENTS.md: write only when missing, never overwrite (protects user edits)
  const agentsSrc = path.join(personaDir, 'AGENTS.md');
  const agentsDst = path.join(homeDir, 'AGENTS.md');
  if (isFile(agentsSrc) && !pathExists(agentsDst)) {
    try {
      fs.mkdirSync(path.dirname(agentsDst), { recursive: true });
      fs.copyFileSync(agentsSrc, agentsDst);
      clearReadOnly(agentsDst);
      addLog('AGENTS.md written: ' + agentsDst);
    } catch (err) {
      addLog('AGENTS.md copy failed (launch continues): ' + err.message, 'Warn');
    }
  }
}

function readLastUrl(statePath) {
  const prev = readJsonFileSafe(statePath);
  if (prev && prev.lastUrl) {
    return String(prev.lastUrl);
  }
  return '';
}

function readLastPort(statePath) {
  const prev = readJsonFileSafe(statePath);
  if (prev && prev.lastPort) {
    const n = Number(prev.lastPort);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

// Interactive wait: read one line from a TTY. Automation never reaches here (guarded by isTTY / --no-wait).
function waitForEnter() {
  try {
    const buf = Buffer.alloc(1);
    for (;;) {
      const n = fs.readSync(0, buf, 0, 1, null);
      if (n <= 0) {
        break;
      }
      if (buf[0] === 0x0a || buf[0] === 0x0d) {
        break;
      }
    }
  } catch (err) {
    // stdin closed / not readable: just return
  }
}

// ---------------------------------------------------------------- main

function main() {
  const parsed = parseArgv(process.argv.slice(2));
  if (parsed.error) {
    failUsage(parsed.error);
  }
  const opts = parsed.opts;
  if (opts.help) {
    writeLine(USAGE);
    process.exit(0);
  }
  if (!opts.discRoot) {
    failUsage('Missing required option: --disc-root <dir>');
  }

  assertPlatform();

  // ---------------------------------------------------------------- 1. disc integrity
  const disc = normalizePath(opts.discRoot);
  if (!disc || !isDirectory(disc)) {
    stop(
      'E01',
      'Cannot find the root of this disc: ' + opts.discRoot,
      'Run ./start.sh in the disc root instead of copying the engine folder elsewhere.'
    );
  }

  const required = [
    { rel: 'persona/meta.json', label: 'persona metadata' },
    { rel: 'pad.bin', label: 'disc fingerprint file' },
  ];
  const missing = [];
  for (const item of required) {
    if (!isFile(path.join(disc, item.rel))) {
      missing.push(item.rel + ' (' + item.label + ')');
    }
  }
  if (!isFile(path.join(disc, 'persona', 'persona.yml')) &&
      !isFile(path.join(disc, 'persona', 'persona.sealed'))) {
    missing.push('persona/persona.yml or persona/persona.sealed (persona file)');
  }
  if (missing.length > 0) {
    stop(
      'E01',
      'This disc is incomplete, missing: ' + missing.join(', '),
      'Use another disc, or rebuild one with tools/new-disc.js.'
    );
  }

  // ---------------------------------------------------------------- 2. discID + manifest
  const padPath = path.join(disc, 'pad.bin');
  let padHash;
  try {
    padHash = sha256File(padPath);
  } catch (err) {
    stop(
      'E02',
      'Cannot read pad.bin, so this disc cannot be identified.',
      'The disc may be worn or the drive may be failing: clean the disc, try another drive, or rebuild the disc.'
    );
  }
  const discID = padHash.slice(0, 16);

  const manifestPath = path.join(disc, '.discpersona', 'manifest.json');
  let manifestChecked = 0;
  if (isFile(manifestPath)) {
    const result = assertDiscManifest(disc, manifestPath);
    manifestChecked = result.checked;
  }

  // ---------------------------------------------------------------- 3. home / logs
  // Where the room lives: prefer the dsh install location; fall back to the user data dir only if that fails.
  let baseRoot = null;
  let baseRootSource = '';
  if (opts.homeRoot) {
    baseRoot = normalizePath(opts.homeRoot) || opts.homeRoot;
    baseRootSource = 'command line --home-root';
  } else if (process.env.DISCPERSONA_HOME) {
    baseRoot = normalizePath(process.env.DISCPERSONA_HOME) || process.env.DISCPERSONA_HOME;
    baseRootSource = 'env var DISCPERSONA_HOME';
  } else {
    const installRoot = getInstallRootFromDsh(opts.dshPath);
    if (installRoot) {
      const candidate = path.join(installRoot, 'DiscPersona', 'personas');
      if (testDirectoryWritable(candidate)) {
        baseRoot = candidate;
        baseRootSource = 'next to the dsh install (' + installRoot + ')';
      }
    }
    if (!baseRoot) {
      baseRoot = path.join(xdgDataHome(), 'DiscPersona', 'personas');
      baseRootSource = 'no usable dsh install location, falling back to the user data directory';
    }
  }

  const personaRoot = path.join(baseRoot, discID);
  const homeDir = path.join(personaRoot, 'home');
  const logsDir = path.join(personaRoot, 'logs');
  const workspaceDir = path.join(personaRoot, 'workspace');
  const statePath = path.join(personaRoot, 'state.json');
  const lockPath = path.join(homeDir, '.lock');

  if (!testDirectoryWritable(personaRoot)) {
    stop(
      'E06',
      'Cannot write to this persona room: ' + personaRoot,
      'Check free disk space and folder permissions, or point DISCPERSONA_HOME at a writable directory and retry.'
    );
  }
  for (const dir of [homeDir, logsDir, workspaceDir]) {
    if (!testDirectoryWritable(dir)) {
      stop(
        'E06',
        'Cannot write to this persona room: ' + dir,
        'Check free disk space and folder permissions, then retry.'
      );
    }
  }

  const stamp = formatStamp();
  const logPath = path.join(logsDir, 'launch-' + stamp + '.log');
  setLogPath(logPath);
  setPersonaHome(personaRoot);

  addLog('diskLIFE launch: disc ' + disc + ', discID ' + discID);
  addLog('Persona directory: ' + personaRoot);
  addLog('Room root: ' + baseRoot + ' (' + baseRootSource + ')');
  if (manifestChecked > 0) {
    addLog('Integrity check: ' + manifestChecked + ' files verified.');
  } else {
    addLog('No .discpersona/manifest.json, skipping the per-file check (only the three required files were confirmed).', 'Warn');
  }

  // Keep only the 10 most recent launch logs
  try {
    const files = fs.readdirSync(logsDir)
      .filter((name) => /^launch-.*\.log$/.test(name))
      .sort()
      .reverse();
    for (const old of files.slice(10)) {
      try {
        fs.unlinkSync(path.join(logsDir, old));
      } catch (err) {
        // ignore
      }
    }
  } catch (err) {
    // ignore
  }

  // ---------------------------------------------------------------- 4. load the persona (room first, disc as fallback)
  function getSealPassphrase() {
    if (opts.passphraseStdin) {
      return seal.readPassphraseFromStdin();
    }
    if (process.env.DISKLIFE_PASSPHRASE) {
      return process.env.DISKLIFE_PASSPHRASE;
    }
    return seal.promptPassphrase('Passphrase for this persona disc: ');
  }

  const discPersonaDir = path.join(disc, 'persona');
  const roomPersonaDir = path.join(personaRoot, 'persona');
  const discPersonaYml = path.join(discPersonaDir, 'persona.yml');
  const roomPersonaYml = path.join(roomPersonaDir, 'persona.yml');
  const discMeta = readMetaFile(path.join(discPersonaDir, 'meta.json'));

  // --upgrade-persona: back up the room persona, then let the freeze below rebuild it from the disc version
  let backupDir = null;
  if (opts.upgradePersona && isDirectory(roomPersonaDir)) {
    backupDir = path.join(personaRoot, 'persona.bak-' + stamp);
    try {
      if (isDirectory(backupDir)) {
        fs.rmSync(backupDir, { recursive: true, force: true });
      }
      copyTreeContents(roomPersonaDir, backupDir);
      fs.rmSync(roomPersonaDir, { recursive: true, force: true });
      addLog('--upgrade-persona: room persona backed up to ' + backupDir + ', using the disc version.', 'Notice');
    } catch (err) {
      addLog('--upgrade-persona backup failed, not overwriting: ' + err.message, 'Error');
      backupDir = null;
      try {
        if (isDirectory(backupDir)) {
          fs.rmSync(backupDir, { recursive: true, force: true });
        }
      } catch (inner) {
        // ignore
      }
    }
  }

  let roomHadPersona = isFile(roomPersonaYml);
  const discSealed = path.join(discPersonaDir, 'persona.sealed');
  if (!roomHadPersona && isFile(discSealed)) {
    // Sealed disc: the persona files are ciphertext until the correct passphrase is entered.
    let passphrase;
    try {
      passphrase = getSealPassphrase();
    } catch (err) {
      stop('E11',
        'This disc has an encrypted persona, but no passphrase could be read: ' + (err.message || err),
        'Run start.sh/start.cmd in a terminal, or pass the passphrase via DISKLIFE_PASSPHRASE.');
    }
    if (!passphrase) {
      stop('E11', 'This disc has an encrypted persona, but the passphrase is empty.',
        'Run start.sh/start.cmd again and enter the passphrase that was used when the disc was built.');
    }
    const unlockDir = roomPersonaDir + '.unlock-' + stamp;
    try {
      if (isDirectory(unlockDir)) {
        fs.rmSync(unlockDir, { recursive: true, force: true });
      }
      seal.unsealToDir(discSealed, passphrase, unlockDir);
      if (isDirectory(roomPersonaDir)) {
        fs.rmSync(roomPersonaDir, { recursive: true, force: true });
      }
      fs.renameSync(unlockDir, roomPersonaDir);
      // meta.json / avatar stay unencrypted on the disc for the label/icon; copy them into the
      // room too, otherwise the room persona would lose its name/version metadata.
      for (const visible of ['meta.json', 'avatar.png', 'avatar.ico']) {
        const source = path.join(discPersonaDir, visible);
        if (isFile(source)) {
          fs.copyFileSync(source, path.join(roomPersonaDir, visible));
        }
      }
      clearReadOnly(roomPersonaDir);
      addLog('Sealed persona unlocked into the room: ' + roomPersonaDir, 'Notice');
      roomHadPersona = true;
    } catch (err) {
      try {
        if (isDirectory(unlockDir)) {
          fs.rmSync(unlockDir, { recursive: true, force: true });
        }
      } catch (cleanupErr) { /* ignore */ }
      stop('E12',
        'Cannot unlock the encrypted persona: ' + (err.message || err),
        'Check the passphrase. If it is correct, the sealed file on the disc may be damaged.');
    }
  } else if (!roomHadPersona) {
    // First run: freeze the whole disc persona into the room; the room wins from then on
    try {
      if (isDirectory(roomPersonaDir)) {
        fs.rmSync(roomPersonaDir, { recursive: true, force: true });
      }
      copyTreeContents(discPersonaDir, roomPersonaDir);
      clearReadOnly(roomPersonaDir);
      addLog('Disc persona frozen into the room: ' + roomPersonaDir, 'Notice');
    } catch (err) {
      addLog('Freeze failed, using the disc persona for this launch: ' + err.message, 'Warn');
    }
    roomHadPersona = isFile(roomPersonaYml);
  }

  const personaDir = roomHadPersona ? roomPersonaDir : discPersonaDir;
  const personaSource = roomHadPersona ? 'room' : 'disc';
  const personaYml = path.join(personaDir, 'persona.yml');

  const meta = readMetaFile(path.join(personaDir, 'meta.json'));
  if (!meta.name) {
    addLog('persona meta.json has no name field, using the default name.', 'Warn');
  }

  // When the disc persona is newer than the room one: never overwrite silently, only record a pending upgrade
  let pendingUpgrade = null;
  if (personaSource === 'room') {
    const roomVersion = meta.version;
    const discVersion = discMeta.version;
    if (discVersion && compareVersionText(discVersion, roomVersion) > 0) {
      pendingUpgrade = { from: roomVersion, to: discVersion };
      addLog(
        'The persona on this disc is newer than the room one (' + discVersion + ' > ' + roomVersion +
        '); the room version was kept. Add --upgrade-persona to update.',
        'Notice'
      );
    }
  }

  let personaDoc;
  try {
    personaDoc = readPersonaDocument(personaYml);
  } catch (err) {
    stop(
      'E08',
      'Cannot read the persona file, or its format is wrong: ' + personaYml,
      'Make sure persona.yml is UTF-8 text and system_prompt uses the | block scalar form.'
    );
  }
  if (!personaDoc.hasSystemPrompt || personaDoc.systemPrompt == null || String(personaDoc.systemPrompt).trim().length === 0) {
    stop(
      'E08',
      'No system_prompt found in the persona file: ' + personaYml,
      'Add a persona text starting with system_prompt: | to the persona file, or use another disc.'
    );
  }
  if (personaDoc.systemPrompt == null) {
    personaDoc.systemPrompt = '';
  }

  // Lorebook: always-on entries are appended to system_prompt (lorebook.json on the disc / in the room)
  const lorebookPath = path.join(personaDir, 'lorebook.json');
  const lorebookText = getLorebookText(lorebookPath);
  if (lorebookText !== '') {
    personaDoc.systemPrompt = String(personaDoc.systemPrompt).replace(/\s+$/, '') + '\n\n' + lorebookText;
  }

  let personaName = 'Unnamed';
  if (meta.name) {
    personaName = meta.name;
  } else if (personaDoc.name) {
    personaName = personaDoc.name;
  }

  let personaVersion = '1.0.0';
  if (meta.version) {
    personaVersion = meta.version;
  } else if (personaDoc.version) {
    personaVersion = personaDoc.version;
  }

  addLog('Persona source: ' + personaSource + ' (' + personaYml + '), version ' + personaVersion);

  // ---------------------------------------------------------------- 5. single-instance lock
  const lock = readLock(lockPath);
  let lockAlive = false;
  let lockPid = 0;
  if (lock) {
    lockPid = Number(lock.pid) || 0;
    const lockTicks = Number(lock.startTicks) || 0;
    lockAlive = isProcessIdentity(lockPid, lockTicks);
  }

  if (lockAlive) {
    const lastUrl = readLastUrl(statePath);
    addLog('An instance is already running (PID ' + lockPid + '), not starting another.', 'Notice');
    writeLine('');
    if (lastUrl) {
      writeLine('  This persona is already running: ' + lastUrl);
      if (!opts.noBrowser) {
        openUrl(lastUrl);
      }
    } else {
      writeLine('  This persona is already running, but no URL was recorded.');
    }
    writeLine('  Error code: E10 (already running)');
    writeLine('');
    process.exit(0);
  }
  if (lock) {
    addLog('Found a lock left by a previous run (process exited), continuing.', 'Warn');
    try {
      fs.unlinkSync(lockPath);
    } catch (err) {
      // ignore
    }
  }

  // Take the single-instance lock early: payload copy + cold boot bootstrap take tens of seconds,
  // and a second double-click in that window would start another instance.
  try {
    writeLock(lockPath, {
      pid: process.pid,
      startTicks: 0,
      startedAt: formatUtcStamp(),
      port: 0,
    });
  } catch (err) {
    addLog('Early lock write failed (launch continues): ' + err.message, 'Warn');
  }

  // ---------------------------------------------------------------- 6. first-run preparation
  const profileDir = path.join(homeDir, 'profiles', 'web');
  const firstBoot = !isDirectory(profileDir);
  let payloadUsedNow = false;
  let payloadPluginNames = null;
  let payloadPresetName = 'none';

  if (firstBoot) {
    addLog('First run: preparing profile, credentials, seed.', 'Notice');

    const payloadCandidates = [
      path.join(disc, '.discpersona', 'payload', 'profile-web'),
      path.join(disc, '.discpersona', 'payload', 'profile-persona'),
      path.join(disc, '.discpersona', 'payload'),
    ];
    let payloadDir = null;
    for (const candidate of payloadCandidates) {
      if (isDirectory(candidate)) {
        payloadDir = candidate;
        break;
      }
    }

    if (payloadDir) {
      addLog('Using the pre-packaged profile from the disc: ' + payloadDir);
      try {
        const parent = path.dirname(profileDir);
        fs.mkdirSync(parent, { recursive: true });
        if (isDirectory(profileDir)) {
          fs.rmSync(profileDir, { recursive: true, force: true });
        }
        copyTreeContents(payloadDir, profileDir);
      } catch (err) {
        stop(
          'E06',
          'Pre-packaged profile copy failed: ' + profileDir,
          'Check free disk space and folder permissions, then retry.'
        );
      }
      // Files on the disc may be read-only; copied over they make dsh hit EPERM when writing settings.
      addLog('Cleared the read-only attribute on the pre-packaged profile: ' + clearReadOnly(profileDir) + ' files');
      payloadUsedNow = true;

      // payload.json: records which plugins are installed and which dsh version packaged them
      const payloadManifest = path.join(payloadDir, 'payload.json');
      if (isFile(payloadManifest)) {
        try {
          const pm = JSON.parse(common.readTextFile(payloadManifest));
          const names = [];
          for (const plugin of Array.isArray(pm.plugins) ? pm.plugins : []) {
            if (plugin) {
              names.push(String(plugin.name) + ' ' + String(plugin.version));
            }
          }
          payloadPluginNames = names;
          if (pm.preset) {
            payloadPresetName = String(pm.preset);
          }
          addLog(
            'Plugin payload: ' + names.join(', ') + ' (packaged with dsh ' + String(pm.dshVersion) +
            ', preset ' + payloadPresetName + ')'
          );
        } catch (err) {
          addLog('Cannot parse payload.json (launch continues): ' + err.message, 'Warn');
        }
      }
    }

    const dshExe = resolveDshExecutable(opts.dshPath);
    if (!dshExe) {
      stop(
        'E04',
        'Cannot find dsh (DeepSeek Harness) on this machine.',
        'Install DeepSeek Harness first, or set DISCPERSONA_DSH to the full path of the dsh executable.'
      );
    }
    addLog('dsh: ' + dshExe);

    if (!payloadDir) {
      const ok = bootstrapProfile(dshExe, homeDir, workspaceDir, logsDir, stamp);
      if (!ok) {
        stop(
          'E09',
          'The dsh web profile could not be generated on the first run.',
          'Make sure dsh runs on its own (dsh --profile web --port 0 --no-open in a terminal), or use a disc with a pre-packaged profile.'
        );
      }
    }

    initializePersonaAssets(homeDir, personaDir, workspaceDir);
  } else {
    addLog('Profile already exists, skipping first-run preparation.');
    // Credentials / seed / AGENTS may still be missing (a first run that failed midway), so catch up here.
    initializePersonaAssets(homeDir, personaDir, workspaceDir);
  }

  // Persona card: synced on every launch (if the room persona.yml changes, the card follows)
  syncPersonaCard(homeDir, personaName, personaDoc.systemPrompt);

  // Workspace: pin the default workspace inside the room so it never shares the one under Documents
  syncWorkspace(homeDir, workspaceDir, personaName + "'s room");

  // ---------------------------------------------------------------- 7. generate the patch
  const personaPatch = path.join(homeDir, 'persona.patch.yml');
  try {
    writeTextFile(personaPatch, buildPersonaPatchText(personaDoc.systemPrompt));
  } catch (err) {
    stop(
      'E06',
      'Cannot write the persona patch: ' + personaPatch,
      'Check free disk space and folder permissions, then retry.'
    );
  }
  addLog('Patch generated: ' + personaPatch);

  const patchArgs = [];
  const userPatch = path.join(homeDir, 'user.patch.yml');
  if (isFile(userPatch)) {
    patchArgs.push(userPatch);
    addLog('Found user.patch.yml; it is applied before the persona: ' + userPatch);
  }
  patchArgs.push(personaPatch);

  // ---------------------------------------------------------------- 8. launch
  const dshExecutable = resolveDshExecutable(opts.dshPath);
  if (!dshExecutable) {
    stop(
      'E04',
      'Cannot find dsh (DeepSeek Harness) on this machine.',
      'Install DeepSeek Harness first, or set DISCPERSONA_DSH to the full path of the dsh executable.'
    );
  }

  const lastPort = readLastPort(statePath);

  let started = null;
  let lastStarted = null;
  let readyUrl = null;

  // If the plugin payload fails to start, delete it, fall back to persona only, and retry once.
  let payloadRetryLeft = payloadUsedNow ? 1 : 0;

  for (let pass = 1; pass <= 2; pass++) {
    const portsToTry = [];
    if (lastPort > 0 && !isPortListening(lastPort)) {
      portsToTry.push(lastPort);
      addLog('Reusing the previous port ' + lastPort + '.');
    } else if (lastPort > 0) {
      addLog('The previous port ' + lastPort + ' is in use, switching to automatic assignment.', 'Warn');
    }
    portsToTry.push(0);

    for (const port of portsToTry) {
      const runStamp = formatStamp();
      const stdout = path.join(logsDir, 'stdout-' + runStamp + '.log');
      const stderr = path.join(logsDir, 'stderr-' + runStamp + '.log');
      try {
        started = startDshInstance({
          dshPath: dshExecutable,
          homeDir: homeDir,
          workingDir: workspaceDir,
          port: port,
          patches: patchArgs,
          stdoutPath: stdout,
          stderrPath: stderr,
        });
      } catch (err) {
        addLog('Failed to start dsh (port ' + port + '): ' + err.message, 'Error');
        continue;
      }
      lastStarted = started;
      if (!started.pid) {
        addLog('Failed to start dsh (port ' + port + '): the process could not be spawned.', 'Error');
        continue;
      }
      addLog(
        'dsh started (port ' + port + ', wrapper PID ' + started.pid +
        ', waiting up to ' + opts.startTimeoutSec + ' s).'
      );
      const ready = waitDshUrl(started, opts.startTimeoutSec);
      if (ready.url) {
        readyUrl = ready.url;
        break;
      }
      addLog('Not ready this time (port ' + port + ', process exited=' + ready.exited + ').', 'Warn');
      if (started.pid > 0 && isProcessAlive(started.pid)) {
        killProcessGroup(started.pid);
      }
      if (port !== 0) {
        addLog('Retrying once with an automatically assigned port.', 'Warn');
      } else {
        break;
      }
    }

    if (readyUrl) {
      break;
    }
    if (payloadRetryLeft <= 0) {
      break;
    }

    // Reaching here means it did not start with the plugin payload: drop the payload and retry with the persona only
    payloadRetryLeft = 0;
    addLog('Start failed with the plugin payload; discarding the pre-packaged profile and retrying with the persona only.', 'Warn');
    writeLine('');
    writeLine('  The plugin payload did not start; retrying with the persona only...');
    try {
      if (isDirectory(profileDir)) {
        fs.rmSync(profileDir, { recursive: true, force: true });
      }
    } catch (err) {
      addLog('Failed to delete the pre-packaged profile: ' + err.message, 'Error');
      break;
    }
    payloadUsedNow = false;
    const okFallback = bootstrapProfile(dshExecutable, homeDir, workspaceDir, logsDir, formatStamp());
    if (!okFallback) {
      addLog('The fallback cold start could not generate a profile either.', 'Error');
      break;
    }
  }

  if (!readyUrl) {
    writeLine('');
    writeLine('  ERROR E09: dsh did not finish starting within the time limit.');
    writeLine('  What to do: retry once; if it still fails, send the log to the maintainer: ' + getLogPath());
    const tail = lastStarted ? logTail(lastStarted.stdoutPath, 15) : [];
    if (tail.length > 0) {
      writeLine('  -- last 15 lines of dsh output --');
      for (const line of tail) {
        writeLine('  | ' + line);
      }
    }
    const errTail = lastStarted ? logTail(lastStarted.stderrPath, 15) : [];
    if (errTail.length > 0) {
      writeLine('  -- last lines of stderr --');
      for (const line of errTail) {
        writeLine('  | ' + line);
      }
    }
    writeLine('  Error code: E09 (startup timed out)');
    writeLine('');
    addLog('Startup timed out; the process was terminated.', 'Error');
    process.exit(1);
  }

  // ---------------------------------------------------------------- 9. record state / lock
  const now = formatTime();
  const stateObj = {
    discID: discID,
    name: personaName,
    personaSource: personaSource,
    personaVersion: personaVersion,
    bootCount: 1,
    firstBootAt: now,
    lastBootAt: now,
    lastPort: 0,
    lastUrl: readyUrl,
  };
  const prevState = readJsonFileSafe(statePath);
  if (prevState) {
    if (prevState.bootCount) {
      const n = Number(prevState.bootCount);
      stateObj.bootCount = Number.isFinite(n) ? n + 1 : 1;
    }
    if (prevState.firstBootAt) {
      stateObj.firstBootAt = String(prevState.firstBootAt);
    }
  }
  if (pendingUpgrade) {
    stateObj.pendingPersonaUpgrade = pendingUpgrade;
  }
  if (payloadPluginNames) {
    stateObj.payloadPlugins = payloadPluginNames;
  }
  if (payloadPresetName) {
    stateObj.payloadPreset = payloadPresetName;
  }
  const portMatch = /127\.0\.0\.1:(\d+)\//.exec(readyUrl);
  if (portMatch) {
    stateObj.lastPort = parseInt(portMatch[1], 10);
  }

  try {
    writeTextFile(statePath, JSON.stringify(stateObj, null, 2) + '\n');
  } catch (err) {
    addLog('Failed to write state.json (launch continues): ' + err.message, 'Warn');
  }

  const dshPid = started ? started.pid : 0;
  const startTicks = getProcessStartTicks(dshPid);
  try {
    writeLock(lockPath, {
      pid: dshPid,
      startTicks: startTicks,
      startedAt: now,
      port: stateObj.lastPort,
    });
  } catch (err) {
    addLog('Failed to write the final lock (launch continues): ' + err.message, 'Warn');
  }
  addLog('Lock recorded: PID ' + dshPid + ', port ' + stateObj.lastPort);

  // ---------------------------------------------------------------- 10. final output
  if (!opts.noBrowser) {
    openUrl(readyUrl);
  }

  writeLine('');
  writeLine('  diskLIFE started');
  // Parity with launch.ps1: the "- run #N" suffix only appears after the first boot.
  const runNote = firstBoot ? '' : ' - run #' + stateObj.bootCount;
  writeLine('  Persona: ' + personaName + ' (v' + personaVersion + ')' + runNote);
  writeLine('  URL: ' + readyUrl);
  writeLine('  Room: ' + personaRoot);
  writeLine('  Log: ' + getLogPath());
  writeLine('');
  addLog('Launch complete: ' + readyUrl + ' (run #' + stateObj.bootCount + ')');

  // In an interactive window wait for Enter; when output is redirected (script / automation) return at once.
  if (!opts.noWait) {
    const interactive = !!(process.stdin && process.stdin.isTTY && process.stdout && process.stdout.isTTY);
    if (interactive) {
      writeLine('  Press Enter to close this window; closing it does not stop the instance.');
      waitForEnter();
    }
  }
  process.exit(0);
}

main();
