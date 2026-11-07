#!/usr/bin/env node
'use strict';
// diskLIFE launch engine self-test (Linux): build a fake disc + fake dsh and exercise
// first run / single instance / every error code. Mirrors engine/_selftest/run-tests.ps1
// (17 results: T1, T1-patch, T1-state, T1-seed, T2 .. T14).
// Usage: node engine/_selftest/run-tests.js

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const here = __dirname;
const engine = path.dirname(here);
const launch = path.join(engine, 'launch.js');
const stubDsh = path.join(here, 'stub-dsh.sh');
const stubAlive = path.join(here, 'stub-alive.sh');
const stubSilent = path.join(here, 'stub-silent.sh');
const NODE = process.execPath;

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dp-selftest-'));
const results = [];

let tempCleaned = false;
function cleanupTemp() {
  if (tempCleaned) {
    return;
  }
  tempCleaned = true;
  try {
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  } catch (err) {
    // best effort: a still-running child could hold a directory, but Linux allows removal anyway
  }
}
process.on('exit', cleanupTemp);
process.on('SIGINT', () => { cleanupTemp(); process.exit(130); });
process.on('SIGTERM', () => { cleanupTemp(); process.exit(143); });

// ---------------------------------------------------------------- tiny test harness

function writeCase(id, title) {
  process.stdout.write('\n=== ' + id + ' ' + title + ' ===\n');
}

function addResult(id, title, pass, detail) {
  results.push({ id: id, title: title, pass: !!pass, detail: detail || '' });
  if (pass) {
    process.stdout.write('  [PASS] ' + id + '\n');
  } else {
    process.stdout.write('  [FAIL] ' + id + ' :: ' + (detail || '') + '\n');
  }
}

function showOutput(text) {
  for (const line of String(text || '').split(/\r?\n/)) {
    if (line.trim().length > 0) {
      process.stdout.write('  | ' + line + '\n');
    }
  }
}

function sleep(ms) {
  try {
    const sab = new SharedArrayBuffer(4);
    Atomics.wait(new Int32Array(sab), 0, 0, ms);
  } catch (err) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) { /* busy */ }
  }
}

function saveText(filePath, text) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, text, 'utf8');
}

function isDir(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch (err) {
    return false;
  }
}

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

// ---------------------------------------------------------------- fixtures

const PERSONA_YML = [
  '# Fake persona for the self-test (diskLIFE selftest)',
  '# this comment must be ignored',
  'name: Alice',
  'version: 1.2.3',
  'system_prompt: |',
  '  You are Alice, a member of the Millennium Science School game development club.',
  '  You speak lightly, and now and then use "bonbon kabon" as a catchphrase.',
  '',
  '  You like to explain complicated things very simply.',
  '',
].join('\n');

const CRED_YAML = [
  'version: 1',
  'records:',
  '  client-connection/browser-session:',
  '    kind: grant',
  '    payload:',
  '      version: 1',
  '      secret: selftest-browser-secret',
  '  deepseek-account-platform/device:',
  '    kind: grant',
  '    payload:',
  '      id: 00000000-0000-4000-8000-000000000000',
  '  deepseek-account-platform/default:',
  '    kind: grant',
  '    payload:',
  '      version: 1',
  '      token: selftest-token-not-a-real-secret',
  '      issuer: https://platform.deepseek.com',
  'refs:',
  '  DEEPSEEK_API_KEY: selftest-api-key-not-a-real-secret',
  '',
].join('\n');

function writeManifest(discDir) {
  const files = {};
  for (const rel of ['persona/persona.yml', 'persona/meta.json', 'pad.bin']) {
    const full = path.join(discDir, rel.split('/').join(path.sep));
    if (fs.existsSync(full)) {
      files[rel] = sha256File(full);
    }
  }
  saveText(path.join(discDir, '.discpersona', 'manifest.json'),
    JSON.stringify({ format: 1, discID: '', files: files }, null, 2));
}

function newTestDisc(dir, options) {
  const opts = options || {};
  fs.mkdirSync(path.join(dir, 'persona', 'seed'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.discpersona'), { recursive: true });

  if (!opts.noPad) {
    fs.writeFileSync(path.join(dir, 'pad.bin'), crypto.randomBytes(4096));
  }

  let personaYml = PERSONA_YML;
  if (opts.noSystemPrompt) {
    personaYml = '# system_prompt deliberately missing\nname: Alice\nversion: 1.2.3\n';
  }
  saveText(path.join(dir, 'persona', 'persona.yml'), personaYml);
  saveText(path.join(dir, 'persona', 'meta.json'), '{"name":"Alice","personaVersion":"1.2.3","format":1}');
  saveText(path.join(dir, 'persona', 'seed', 'README.md'), 'One seed from the seed folder.');
  saveText(path.join(dir, 'persona', 'AGENTS.md'), 'This is the AGENTS.md from the disc (written once on first run).');

  if (!opts.noManifest) {
    writeManifest(dir);
  }
}

function newSourceHome(dir, noCreds) {
  fs.mkdirSync(dir, { recursive: true });
  if (noCreds) {
    saveText(path.join(dir, '.credentials.yaml'), 'version: 1\nrecords: {}\n');
    return;
  }
  saveText(path.join(dir, '.credentials.yaml'), CRED_YAML);
}

// ---------------------------------------------------------------- launching the engine

const srcHome = path.join(root, 'source-home');
newSourceHome(srcHome, false);
const srcHomeNoCred = path.join(root, 'source-home-nocred');
newSourceHome(srcHomeNoCred, true);

function makeEnv(extra) {
  const env = Object.assign({}, process.env);
  delete env.DISCPERSONA_DSH;
  delete env.DISCPERSONA_HOME;
  delete env.DSH_HOME;
  delete env.DISKLIFE_NODE;
  env.DISCPERSONA_SOURCE_HOME = srcHome;
  if (extra) {
    Object.assign(env, extra);
    for (const key of Object.keys(extra)) {
      if (extra[key] === undefined) {
        delete env[key];
      }
    }
  }
  return env;
}

function invokeLaunch(args, extraEnv) {
  const fullArgs = [launch].concat(args, ['--no-wait']);
  const r = spawnSync(NODE, fullArgs, {
    cwd: path.dirname(engine),
    encoding: 'utf8',
    timeout: 180000,
    maxBuffer: 16 * 1024 * 1024,
    env: makeEnv(extraEnv || {}),
  });
  const output = String(r.stdout || '') + String(r.stderr || '');
  return { output: output, code: r.status, error: r.error };
}

function killLock(lockPath) {
  let obj = null;
  try {
    obj = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
  } catch (err) {
    obj = null;
  }
  if (obj && obj.pid) {
    const pid = Number(obj.pid) || 0;
    if (pid > 0) {
      try {
        process.kill(-pid, 'SIGKILL');
      } catch (err) {
        // group already gone
      }
      try {
        process.kill(pid, 'SIGKILL');
      } catch (err) {
        // already gone
      }
    }
  }
  try {
    fs.unlinkSync(lockPath);
  } catch (err) {
    // ignore
  }
}

function stopLock(lockPath) {
  killLock(lockPath);
  sleep(250);
}

function firstChildDir(dir) {
  try {
    const names = fs.readdirSync(dir).filter((name) => isDir(path.join(dir, name)));
    names.sort();
    return names.length > 0 ? path.join(dir, names[0]) : null;
  } catch (err) {
    return null;
  }
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (err) {
    return null;
  }
}

const discBase = path.join(root, 'disc-base');
newTestDisc(discBase);

// ---------------------------------------------------------------- T1 first run succeeds

writeCase('T1', 'first-run success path (prints the launch text + URL + correct patch content)');
const homeRoot1 = path.join(root, 'homes-t1');
const t1 = invokeLaunch([
  '--disc-root', discBase,
  '--dsh-path', stubDsh,
  '--home-root', homeRoot1,
  '--no-browser',
  '--start-timeout-sec', '20',
]);
showOutput(t1.output);
addResult(
  'T1',
  'first run',
  t1.code === 0 && t1.output.includes('diskLIFE started') && t1.output.includes('34567'),
  'exit=' + t1.code
);

const personaRoot1 = firstChildDir(homeRoot1);
const patchPath = personaRoot1 ? path.join(personaRoot1, 'home', 'persona.patch.yml') : null;
let patchOk = false;
if (patchPath && fs.existsSync(patchPath)) {
  const patchText = fs.readFileSync(patchPath, 'utf8');
  process.stdout.write('  -- persona.patch.yml --\n');
  for (const line of patchText.split(/\r?\n/)) {
    if (line.length > 0) {
      process.stdout.write('  | ' + line + '\n');
    }
  }
  patchOk = /^- id: system-prompt/m.test(patchText) &&
    patchText.includes('personaPrefix: |') &&
    patchText.includes('You are Alice') &&
    patchText.includes('bonbon kabon') &&
    !patchText.includes('this comment must be ignored');
}
addResult('T1-patch', 'patch structure and content', patchOk,
  'checks - id: system-prompt / personaPrefix: | / both body lines present');

let stateOk = false;
const statePath1 = personaRoot1 ? path.join(personaRoot1, 'state.json') : null;
if (statePath1 && fs.existsSync(statePath1)) {
  const st = readJson(statePath1) || {};
  process.stdout.write('  state.json: ' + JSON.stringify(st) + '\n');
  stateOk = st.bootCount === 1 && !!st.discID && st.name === 'Alice' &&
    st.personaVersion === '1.2.3' && st.lastPort === 34567;
}
addResult('T1-state', 'state.json fields', stateOk,
  'discID/name/personaVersion/bootCount=1/lastPort=34567');

let seedOk = false;
let agentsOk = false;
if (personaRoot1) {
  seedOk = fs.existsSync(path.join(personaRoot1, 'workspace', 'memories', 'README.md'));
  agentsOk = fs.existsSync(path.join(personaRoot1, 'home', 'AGENTS.md'));
}
addResult('T1-seed', 'seed and AGENTS.md land on disk', seedOk && agentsOk,
  'seed=' + seedOk + ' agents=' + agentsOk);

// ---------------------------------------------------------------- T2 second run -> E10

writeCase('T2', 'launch again while the process still runs -> E10 (already running, exit code 0)');
if (statePath1) {
  stopLock(path.join(path.dirname(statePath1), 'home', '.lock'));
}
const t2a = invokeLaunch([
  '--disc-root', discBase,
  '--dsh-path', stubAlive,
  '--home-root', homeRoot1,
  '--no-browser',
  '--start-timeout-sec', '20',
]);
process.stdout.write('  -- first (long-lived stub) --\n');
showOutput(t2a.output);
const t2 = invokeLaunch([
  '--disc-root', discBase,
  '--dsh-path', stubAlive,
  '--home-root', homeRoot1,
  '--no-browser',
  '--start-timeout-sec', '20',
]);
process.stdout.write('  -- second (expect E10) --\n');
showOutput(t2.output);
const e10ok = t2a.code === 0 && t2.code === 0 &&
  t2.output.includes('already running') && t2.output.includes('E10') && t2.output.includes('34568');
addResult('T2', 'E10 already running', e10ok, 'first=' + t2a.code + ' second=' + t2.code);

if (statePath1) {
  stopLock(path.join(path.dirname(statePath1), 'home', '.lock'));
}

// ---------------------------------------------------------------- T3 missing pad.bin -> E01

writeCase('T3', 'delete pad.bin -> E01 incomplete disc');
const disc3 = path.join(root, 'disc-no-pad');
fs.cpSync(discBase, disc3, { recursive: true });
fs.rmSync(path.join(disc3, 'pad.bin'), { force: true });
const t3 = invokeLaunch([
  '--disc-root', disc3,
  '--dsh-path', stubDsh,
  '--home-root', path.join(root, 'homes-t3'),
  '--no-browser',
]);
showOutput(t3.output);
addResult('T3', 'E01 incomplete disc',
  t3.code === 1 && t3.output.includes('E01') && t3.output.includes('pad.bin'),
  'exit=' + t3.code);

// ---------------------------------------------------------------- T4 manifest mismatch -> E03

writeCase('T4', 'modify persona.yml -> E03 files were modified');
const disc4 = path.join(root, 'disc-tampered');
fs.cpSync(discBase, disc4, { recursive: true });
fs.appendFileSync(path.join(disc4, 'persona', 'persona.yml'), '# sneaky extra line\n');
const t4 = invokeLaunch([
  '--disc-root', disc4,
  '--dsh-path', stubDsh,
  '--home-root', path.join(root, 'homes-t4'),
  '--no-browser',
]);
showOutput(t4.output);
addResult('T4', 'E03 files modified',
  t4.code === 1 && t4.output.includes('E03') && t4.output.includes('persona/persona.yml'),
  'exit=' + t4.code);

// ---------------------------------------------------------------- T5 no credentials -> E07

writeCase('T5', 'source home has no LLM credentials -> E07');
const t5 = invokeLaunch([
  '--disc-root', discBase,
  '--dsh-path', stubDsh,
  '--home-root', path.join(root, 'homes-t5'),
  '--no-browser',
  '--start-timeout-sec', '20',
], { DISCPERSONA_SOURCE_HOME: srcHomeNoCred });
showOutput(t5.output);
addResult('T5', 'E07 missing credentials',
  t5.code === 1 && t5.output.includes('E07') && t5.output.includes('Sign in to DSH'),
  'exit=' + t5.code);

// ---------------------------------------------------------------- T6 missing system_prompt -> E08

writeCase('T6', 'persona.yml has no system_prompt -> E08');
const disc6 = path.join(root, 'disc-no-prompt');
newTestDisc(disc6, { noSystemPrompt: true });
const t6 = invokeLaunch([
  '--disc-root', disc6,
  '--dsh-path', stubDsh,
  '--home-root', path.join(root, 'homes-t6'),
  '--no-browser',
]);
showOutput(t6.output);
addResult('T6', 'E08 persona parse failure', t6.code === 1 && t6.output.includes('E08'), 'exit=' + t6.code);

// ---------------------------------------------------------------- T7 no dsh -> E04

writeCase('T7', 'no dsh on PATH -> E04');
const t7 = invokeLaunch([
  '--disc-root', discBase,
  '--home-root', path.join(root, 'homes-t7'),
  '--no-browser',
  '--start-timeout-sec', '5',
], { PATH: '' });
showOutput(t7.output);
addResult('T7', 'E04 dsh not found',
  t7.code === 1 && t7.output.includes('E04') && t7.output.includes('DISCPERSONA_DSH'),
  'exit=' + t7.code);

// ---------------------------------------------------------------- T8 startup timeout -> E09

writeCase('T8', 'silent dsh + 3 second timeout -> E09 (with the last 15 lines)');
// Pre-create profiles/web so this launch skips the first-run bootstrap and the 3 s
// --start-timeout-sec applies to the real launch (that is the timeout under test).
const home8 = path.join(root, 'homes-t8');
fs.mkdirSync(path.join(home8, sha256File(path.join(discBase, 'pad.bin')).slice(0, 16), 'home', 'profiles', 'web'), { recursive: true });
const t8 = invokeLaunch([
  '--disc-root', discBase,
  '--dsh-path', stubSilent,
  '--home-root', home8,
  '--no-browser',
  '--start-timeout-sec', '3',
]);
showOutput(t8.output);
addResult('T8', 'E09 startup timed out', t8.code === 1 && t8.output.includes('E09'), 'exit=' + t8.code);

// ---------------------------------------------------------------- T9 directory not writable -> E06

writeCase('T9', 'persona directory points at a file -> E06');
const blocker = path.join(root, 'blocker.txt');
saveText(blocker, 'not a directory');
const t9 = invokeLaunch([
  '--disc-root', discBase,
  '--dsh-path', stubDsh,
  '--home-root', blocker,
  '--no-browser',
]);
showOutput(t9.output);
addResult('T9', 'E06 home not writable', t9.code === 1 && t9.output.includes('E06'), 'exit=' + t9.code);

// ---------------------------------------------------------------- T10 freeze on first run

writeCase('T10', 'the first run freezes the disc persona into the room (state.personaSource=room)');
let roomPersona = null;
let solidOk = false;
if (personaRoot1) {
  roomPersona = path.join(personaRoot1, 'persona', 'persona.yml');
}
if (roomPersona && fs.existsSync(roomPersona) && statePath1) {
  const roomText = fs.readFileSync(roomPersona, 'utf8');
  const st10 = readJson(statePath1) || {};
  solidOk = roomText.includes('bonbon kabon') && st10.personaSource === 'room';
  process.stdout.write('  personaSource=' + st10.personaSource + '  personaVersion=' + st10.personaVersion + '\n');
}
addResult('T10', 'freeze on first run', solidOk,
  'room persona/persona.yml holds the body, state.personaSource=room');

// ---------------------------------------------------------------- T11 room wins + pending

writeCase('T11', 'a room persona edit takes effect; a newer disc version only records pendingPersonaUpgrade, never overwrites');
if (roomPersona && fs.existsSync(roomPersona)) {
  let roomText = fs.readFileSync(roomPersona, 'utf8');
  roomText = roomText.replace(
    'You are Alice, a member of the Millennium Science School game development club.',
    'You are the edited room persona.'
  );
  saveText(roomPersona, roomText);
}

// Another disc with the same pad.bin (same discID), persona version 1.3.0
const disc11 = path.join(root, 'disc-new-version');
fs.cpSync(discBase, disc11, { recursive: true });
const yml11 = path.join(disc11, 'persona', 'persona.yml');
let ymlText = fs.readFileSync(yml11, 'utf8');
ymlText = ymlText.replace(
  'You are Alice, a member of the Millennium Science School game development club.',
  'You are a newer persona from the disc.'
);
saveText(yml11, ymlText);
saveText(path.join(disc11, 'persona', 'meta.json'), '{"name":"Alice","personaVersion":"1.3.0","format":1}');
writeManifest(disc11);

const t11 = invokeLaunch([
  '--disc-root', disc11,
  '--dsh-path', stubDsh,
  '--home-root', homeRoot1,
  '--no-browser',
  '--start-timeout-sec', '20',
]);
showOutput(t11.output);
let pendingOk = false;
if (patchPath && fs.existsSync(patchPath) && statePath1) {
  const patch11 = fs.readFileSync(patchPath, 'utf8');
  const st11 = readJson(statePath1) || {};
  const pending11 = st11.pendingPersonaUpgrade || null;
  process.stdout.write('  pendingPersonaUpgrade=' + JSON.stringify(pending11) + '\n');
  pendingOk = patch11.includes('You are the edited room persona.') &&
    !patch11.includes('You are a newer persona from the disc.') &&
    !!pending11 && pending11.to === '1.3.0' && st11.personaVersion === '1.2.3';
}
addResult('T11', 'room wins + pending', pendingOk,
  'patch uses the room body; state records pendingPersonaUpgrade.to=1.3.0 and personaVersion stays 1.2.3');

// ---------------------------------------------------------------- T12 --upgrade-persona

writeCase('T12', '--upgrade-persona backs up, then overwrites, and clears pending');
if (statePath1) {
  stopLock(path.join(path.dirname(statePath1), 'home', '.lock'));
}
const t12 = invokeLaunch([
  '--disc-root', disc11,
  '--dsh-path', stubDsh,
  '--home-root', homeRoot1,
  '--no-browser',
  '--start-timeout-sec', '20',
  '--upgrade-persona',
]);
showOutput(t12.output);
let upgradeOk = false;
if (patchPath && fs.existsSync(patchPath) && statePath1 && personaRoot1) {
  const patch12 = fs.readFileSync(patchPath, 'utf8');
  const st12 = readJson(statePath1) || {};
  const backups = fs.readdirSync(personaRoot1)
    .filter((name) => name.startsWith('persona.bak-') && isDir(path.join(personaRoot1, name)));
  let backupHasOld = false;
  for (const backup of backups) {
    const oldYml = path.join(personaRoot1, backup, 'persona.yml');
    if (fs.existsSync(oldYml)) {
      const oldText = fs.readFileSync(oldYml, 'utf8');
      if (oldText.includes('You are the edited room persona.')) {
        backupHasOld = true;
      }
    }
  }
  process.stdout.write('  backup dirs=' + backups.length + '  personaVersion=' + st12.personaVersion + '\n');
  upgradeOk = t12.code === 0 &&
    patch12.includes('You are a newer persona from the disc.') &&
    backups.length >= 1 && backupHasOld &&
    st12.personaVersion === '1.3.0' &&
    !Object.prototype.hasOwnProperty.call(st12, 'pendingPersonaUpgrade');
}
addResult('T12', '--upgrade-persona', upgradeOk,
  'patch switches to the disc body; persona.bak-* holds the old body; state version 1.3.0 with no pending');

// ---------------------------------------------------------------- T13 recovery after a first-run E07

writeCase('T13', 'after a first-run E07 with the profile already created, a rerun fills in the credentials');
const home13 = path.join(root, 'homes-t13');
const t13a = invokeLaunch([
  '--disc-root', discBase,
  '--dsh-path', stubDsh,
  '--home-root', home13,
  '--no-browser',
  '--start-timeout-sec', '20',
], { DISCPERSONA_SOURCE_HOME: srcHomeNoCred });

// Simulate "payload copy / cold boot bootstrap already created profiles/web" --
// exactly the situation where firstBoot alone would be wrong and credentials would never be restored.
const discID = sha256File(path.join(discBase, 'pad.bin')).slice(0, 16);
const home13Home = path.join(home13, discID, 'home');
fs.mkdirSync(path.join(home13Home, 'profiles', 'web'), { recursive: true });

const t13 = invokeLaunch([
  '--disc-root', discBase,
  '--dsh-path', stubDsh,
  '--home-root', home13,
  '--no-browser',
  '--start-timeout-sec', '20',
], { DISCPERSONA_SOURCE_HOME: srcHome });
showOutput(t13.output);
let cred13Text = '';
let cred13Mode = null;
const cred13 = path.join(home13Home, '.credentials.yaml');
if (fs.existsSync(cred13)) {
  cred13Text = fs.readFileSync(cred13, 'utf8');
  cred13Mode = fs.statSync(cred13).mode & 0o777;
}
process.stdout.write('  first exit=' + t13a.code + ' / second exit=' + t13.code +
  ' / has credentials=' + (cred13Text !== '') +
  ' / credentials mode=0' + (cred13Mode === null ? '?' : cred13Mode.toString(8)) + '\n');
const ok13 = t13a.code === 1 && t13a.output.includes('E07') &&
  t13.code === 0 &&
  cred13Text.includes('DEEPSEEK_API_KEY') &&
  cred13Text.includes('deepseek-account-platform/default') &&
  cred13Mode === 0o600;
addResult('T13', 'recovery after E07', ok13,
  'with the profile already present, credentials are still imported (mode 0600) and the launch succeeds');

// ---------------------------------------------------------------- T14 the workspace survives a pin

writeCase('T14', 'a rerun keeps pinnedSessionIds / archivedSessionIds');
const wsPath = path.join(home13Home, 'storages', 'workspace.json');
let pinnedOk = false;
if (fs.existsSync(wsPath)) {
  const wsText = fs.readFileSync(wsPath, 'utf8');
  const ws = JSON.parse(wsText);
  // Add a pin by hand, relaunch, and see whether it is written back
  const json = wsText.replace('"pinnedSessionIds":[]', '"pinnedSessionIds":["sess-keep-me"]');
  saveText(wsPath, json);
  // The T13 instance is still alive; stop it so this is a real relaunch, not an E10 shortcut.
  stopLock(path.join(home13Home, '.lock'));
  // Simulate a room created by an older build that left .credentials.yaml at 0644:
  // every launch must tighten it back to 0600, or dsh refuses to start.
  const cred14 = path.join(home13Home, '.credentials.yaml');
  fs.chmodSync(cred14, 0o644);
  const t14 = invokeLaunch([
    '--disc-root', discBase,
    '--dsh-path', stubDsh,
    '--home-root', home13,
    '--no-browser',
    '--start-timeout-sec', '20',
  ]);
  showOutput(t14.output);
  const ws2Text = fs.readFileSync(wsPath, 'utf8');
  const ws2 = JSON.parse(ws2Text);
  const arraysOk = ws2 && ws2.global &&
    Array.isArray(ws2.global.workspaceIds) &&
    Array.isArray(ws2.global.archivedSessionIds) &&
    Array.isArray(ws2.global.pinnedSessionIds) &&
    Array.isArray(ws2.tables.workspaces[ws2.global.defaultWorkspaceId].sessionIds);
  const cred14Mode = fs.existsSync(cred14) ? (fs.statSync(cred14).mode & 0o777) : null;
  pinnedOk = t14.code === 0 && ws2Text.includes('sess-keep-me') && arraysOk && cred14Mode === 0o600;
  process.stdout.write('  pin kept=' + ws2Text.includes('sess-keep-me') + ' arraysOk=' + arraysOk +
    ' / credentials mode self-healed=' + (cred14Mode === 0o600) + '\n');
}
addResult('T14', 'pin is not emptied', pinnedOk,
  'a launch never resets pinnedSessionIds to an empty array and heals a 0644 credentials file to 0600');

// ---------------------------------------------------------------- cleanup

// Kill every stub this run left behind (the lock files record their pid / process group).
function walk(dir, depth) {
  if (depth > 4) {
    return;
  }
  let names = [];
  try {
    names = fs.readdirSync(dir);
  } catch (err) {
    return;
  }
  for (const name of names) {
    const full = path.join(dir, name);
    let st;
    try {
      st = fs.lstatSync(full);
    } catch (err) {
      continue;
    }
    if (st.isDirectory()) {
      walk(full, depth + 1);
    } else if (name === '.lock') {
      killLock(full);
    }
  }
}
walk(root, 0);

// ---------------------------------------------------------------- summary

process.stdout.write('\n================ self-test summary ================\n');
for (const r of results) {
  process.stdout.write('  [' + (r.pass ? 'PASS' : 'FAIL') + '] ' + r.id.padEnd(12) + ' ' + r.title + '\n');
}
const failed = results.filter((r) => !r.pass);
process.stdout.write('  passed ' + (results.length - failed.length) + '/' + results.length + '\n');
if (failed.length > 0) {
  // Keep the artifacts around for debugging when something failed.
  tempCleaned = true;
  process.stdout.write('  temp dir kept: ' + root + '\n\n');
} else {
  process.stdout.write('\n');
  cleanupTemp();
}

process.exit(failed.length > 0 ? 1 : 0);
