'use strict';
// Integration tests for the Linux port. No network, no optical drive, no root.
// Run with: node --test tests/

const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const REPO = path.resolve(__dirname, '..');
const NODE = process.execPath;
const SAMPLE = path.join(REPO, 'examples', 'sample-persona');
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'disklife-it-'));
const discDir = path.join(tmpRoot, 'disc');
const isoPath = path.join(tmpRoot, 'disc.iso');

process.on('exit', () => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

function run(script, args = [], opts = {}) {
  return spawnSync(NODE, [path.join(REPO, script), ...args], {
    cwd: REPO,
    encoding: 'utf8',
    timeout: opts.timeout || 180000,
    input: opts.input,
    env: { ...process.env, ...(opts.env || {}) },
  });
}

function output(r) {
  return (r.stdout || '') + (r.stderr || '');
}

test('start.sh is a valid Linux boot loader', () => {
  const file = path.join(REPO, 'start.sh');
  assert.ok(fs.existsSync(file), 'start.sh must exist');
  const bytes = fs.readFileSync(file);
  assert.equal(bytes[0], 0x23, 'start.sh must start with #!');
  assert.ok(!bytes.includes(0x0d), 'start.sh must be LF only');
  assert.notEqual(bytes.subarray(0, 3).toString('hex'), 'efbbbf', 'start.sh must not have a BOM');
  assert.ok(bytes.every((b) => b < 0x80), 'start.sh must be ASCII only');
  const text = bytes.toString('utf8');
  assert.match(text, /^#!\/bin\/sh/, 'start.sh shebang');
  assert.match(text, /engine\/launch\.js/, 'start.sh must call engine/launch.js');
  if (process.platform === 'linux') {
    assert.ok(fs.statSync(file).mode & 0o111, 'start.sh should be executable');
  }
});

test('new-disc builds a disc tree with start.sh and the Linux engine', () => {
  const r = run('tools/new-disc.js', [
    '--persona', SAMPLE,
    '--out', discDir,
    '--payload-preset', 'none',
  ]);
  fs.writeFileSync(path.join(tmpRoot, 'new-disc.log'), output(r));
  assert.equal(r.status, 0, 'new-disc.js failed:\n' + output(r));
  assert.match(r.stdout, /DISC_OK discID=[0-9a-f]{16} files=\d+ out=/);

  assert.ok(fs.existsSync(path.join(discDir, 'start.sh')), 'disc has start.sh');
  assert.ok(fs.existsSync(path.join(discDir, 'engine', 'launch.js')), 'disc has engine/launch.js');
  assert.ok(fs.existsSync(path.join(discDir, 'README.txt')), 'disc has README.txt');
  assert.ok(fs.existsSync(path.join(discDir, 'persona', 'persona.yml')), 'disc has the persona');

  const pad = fs.readFileSync(path.join(discDir, 'pad.bin'));
  assert.equal(pad.length, 512, 'pad.bin is 512 bytes');
  assert.equal(pad.subarray(0, 18).toString('ascii'), 'DISCPERSONA-PAD-V1');

  const manifest = JSON.parse(fs.readFileSync(path.join(discDir, '.discpersona', 'manifest.json'), 'utf8'));
  assert.equal(manifest.format, 1);
  assert.match(manifest.discID, /^[0-9a-f]{16}$/);
  assert.ok(manifest.files['start.sh'], 'manifest covers start.sh');
  assert.ok(manifest.files['engine/launch.js'], 'manifest covers engine/launch.js');
  assert.ok(manifest.files['pad.bin'], 'manifest covers pad.bin');

  const meta = JSON.parse(fs.readFileSync(path.join(discDir, 'persona', 'meta.json'), 'utf8'));
  assert.equal(meta.discID, manifest.discID, 'meta.json discID matches the manifest');
});

test('sealed files round-trip and reject a wrong passphrase', () => {
  const seal = require(path.join(REPO, 'engine', 'lib', 'seal.js'));
  const dir = path.join(tmpRoot, 'seal-src');
  fs.cpSync(SAMPLE, dir, { recursive: true });
  seal.sealPersonaDir(dir, 'test-passphrase-123');
  assert.ok(fs.existsSync(path.join(dir, 'persona.sealed')));
  assert.ok(!fs.existsSync(path.join(dir, 'persona.yml')), 'plaintext persona.yml must be gone');
  assert.ok(fs.existsSync(path.join(dir, 'meta.json')), 'meta.json stays visible for the disc label');
  const restored = path.join(tmpRoot, 'seal-out');
  seal.unsealToDir(path.join(dir, 'persona.sealed'), 'test-passphrase-123', restored);
  assert.equal(fs.readFileSync(path.join(restored, 'persona.yml'), 'utf8'),
    fs.readFileSync(path.join(SAMPLE, 'persona.yml'), 'utf8'));
  assert.throws(() => seal.unsealToDir(path.join(dir, 'persona.sealed'), 'wrong-pass', path.join(tmpRoot, 'seal-bad')),
    /cannot decrypt/);
});

test('a sealed disc builds, verifies and launches with its passphrase', () => {
  const sealed = path.join(tmpRoot, 'sealed-disc');
  const pass = 'test-seal-pass-123';
  const build = run('tools/new-disc.js', ['--persona', SAMPLE, '--out', sealed,
    '--payload-preset', 'none', '--seal-persona', '--passphrase-stdin'], { input: pass + '\n' });
  assert.equal(build.status, 0, output(build));
  assert.match(build.stdout, /DISC_OK/);
  assert.ok(fs.existsSync(path.join(sealed, 'persona', 'persona.sealed')));
  assert.ok(!fs.existsSync(path.join(sealed, 'persona', 'persona.yml')));
  assert.ok(!fs.existsSync(path.join(sealed, 'persona', 'AGENTS.md')));

  const verify = run('tools/test-disc.js', ['--disc', sealed]);
  assert.equal(verify.status, 0, output(verify));
  assert.match(verify.stdout, /PASS/);

  const credHome = path.join(tmpRoot, 'seal-source-home');
  fs.mkdirSync(credHome, { recursive: true });
  fs.writeFileSync(path.join(credHome, '.credentials.yaml'), [
    'version: 1',
    'records:',
    '  deepseek-account-platform/device:',
    '    kind: grant',
    '    payload:',
    '      id: 00000000-0000-4000-8000-000000000000',
    '  deepseek-account-platform/default:',
    '    kind: grant',
    '    payload:',
    '      version: 1',
    '      token: test-only-token',
    'refs:',
    '  DEEPSEEK_API_KEY: sk-test-only-not-real',
    '',
  ].join('\n'));
  fs.chmodSync(path.join(credHome, '.credentials.yaml'), 0o600);

  const home = path.join(tmpRoot, 'sealed-home');
  const launch = spawnSync(NODE, [
    path.join(REPO, 'engine', 'launch.js'),
    '--disc-root', sealed,
    '--dsh-path', path.join(REPO, 'engine', '_selftest', 'stub-dsh.sh'),
    '--home-root', home,
    '--no-browser', '--no-wait', '--passphrase-stdin', '--start-timeout-sec', '20',
  ], { cwd: REPO, encoding: 'utf8', input: pass + '\n', timeout: 90000,
       env: { ...process.env, DISCPERSONA_SOURCE_HOME: credHome } });
  assert.equal(launch.status, 0, output(launch));
  const room = fs.readdirSync(home).map((name) => path.join(home, name))[0];
  assert.ok(fs.existsSync(path.join(room, 'persona', 'persona.yml')), 'room gets the decrypted persona');
  const state = JSON.parse(fs.readFileSync(path.join(room, 'state.json'), 'utf8'));
  assert.equal(state.personaVersion, '1.0.0');
  const pid = JSON.parse(fs.readFileSync(path.join(room, 'home', '.lock'), 'utf8')).pid;
  try { process.kill(-pid, 'SIGKILL'); } catch (e) { try { process.kill(pid, 'SIGKILL'); } catch (e2) { /* ignore */ } }

  const badHome = path.join(tmpRoot, 'sealed-bad-home');
  const bad = spawnSync(NODE, [
    path.join(REPO, 'engine', 'launch.js'),
    '--disc-root', sealed,
    '--dsh-path', path.join(REPO, 'engine', '_selftest', 'stub-dsh.sh'),
    '--home-root', badHome,
    '--no-browser', '--no-wait', '--passphrase-stdin',
  ], { cwd: REPO, encoding: 'utf8', input: 'wrong-passphrase\n', timeout: 60000,
       env: { ...process.env, DISCPERSONA_SOURCE_HOME: credHome } });
  assert.equal(bad.status, 1);
  assert.match(output(bad), /E12/);
});

test('backup-room encrypts a room and restores it exactly', () => {
  const seal = require(path.join(REPO, 'engine', 'lib', 'seal.js'));
  const room = path.join(tmpRoot, 'room-src');
  fs.mkdirSync(path.join(room, 'workspace'), { recursive: true });
  fs.writeFileSync(path.join(room, 'state.json'), '{"discID":"test"}\n');
  fs.writeFileSync(path.join(room, 'workspace', 'note.md'), 'remember this\n');
  const backup = path.join(tmpRoot, 'room.dlseal');
  const pass = 'room-backup-pass-123';
  const r = run('tools/backup-room.js', ['--room', room, '--out', backup, '--passphrase-stdin', '--verify'], { input: pass + '\n' });
  assert.equal(r.status, 0, output(r));
  assert.match(r.stdout, /ROOM_BACKUP_OK/);
  assert.ok(fs.existsSync(backup));
  const restored = path.join(tmpRoot, 'room-restored');
  const count = seal.unsealTreeFromFile(backup, restored, pass);
  assert.equal(count, 2);
  assert.equal(fs.readFileSync(path.join(restored, 'workspace', 'note.md'), 'utf8'), 'remember this\n');
});

test('new-disc refuses to build into the project folder or its parents', () => {
  const r = run('tools/new-disc.js', ['--persona', SAMPLE, '--out', '.', '--force']);
  assert.equal(r.status, 1, 'must refuse the project root');
  assert.match(output(r), /Refusing to build into the project folder/);
});

test('new-disc refuses to delete a non-build .tmp directory', () => {
  const out = path.join(tmpRoot, 'guarded-out');
  const tmp = out + '.tmp';
  fs.mkdirSync(tmp, { recursive: true });
  fs.writeFileSync(path.join(tmp, 'user-file.txt'), 'keep me');
  const r = run('tools/new-disc.js', ['--persona', SAMPLE, '--out', out]);
  assert.equal(r.status, 1, 'must refuse an unrelated .tmp directory');
  assert.equal(fs.readFileSync(path.join(tmp, 'user-file.txt'), 'utf8'), 'keep me');
});

test('burn-iso refuses a non-optical device', { skip: !fs.existsSync('/dev/nvme0n1') }, () => {
  const iso = path.join(tmpRoot, 'dummy.iso');
  fs.writeFileSync(iso, Buffer.alloc(4096));
  const r = run('tools/burn-iso.js', ['--iso', iso, '--drive', '/dev/nvme0n1', '--test-only']);
  assert.equal(r.status, 1);
  assert.match(output(r), /Refusing to write to a non-optical device/);
  assert.match(output(r), /BURN_FAIL B01/);
});

test('test-disc accepts the built disc', () => {
  const r = run('tools/test-disc.js', ['--disc', discDir]);
  fs.writeFileSync(path.join(tmpRoot, 'test-disc.log'), output(r));
  assert.equal(r.status, 0, 'test-disc.js reported problems:\n' + output(r));
  assert.match(r.stdout, /PASS/);
});

test('test-disc rejects a modified disc', () => {
  const tampered = path.join(tmpRoot, 'tampered');
  fs.cpSync(discDir, tampered, { recursive: true });
  fs.appendFileSync(path.join(tampered, 'persona', 'persona.yml'), '\n# sneaky extra line\n');
  const r = run('tools/test-disc.js', ['--disc', tampered]);
  assert.equal(r.status, 1, 'tampered disc must fail');
  assert.match(output(r), /FAIL/);
  assert.match(output(r), /persona\/persona\.yml/);
});

test('new-iso writes a verifiable ISO9660 + Joliet image', () => {
  const r = run('tools/new-iso.js', ['--source', discDir, '--out', isoPath]);
  fs.writeFileSync(path.join(tmpRoot, 'new-iso.log'), output(r));
  assert.equal(r.status, 0, 'new-iso.js failed:\n' + output(r));
  assert.match(r.stdout, /ISO_OK /);
  const size = fs.statSync(isoPath).size;
  assert.ok(size > 32768, 'ISO should not be trivially empty');

  const buf = fs.readFileSync(isoPath);
  const sector = (n) => buf.subarray(n * 2048, (n + 1) * 2048);
  const pvd = sector(16);
  assert.equal(pvd[0], 1, 'primary volume descriptor at LBA 16');
  assert.equal(pvd.subarray(1, 6).toString('ascii'), 'CD001');
  const svd = sector(17);
  assert.equal(svd[0], 2, 'Joliet supplementary volume descriptor at LBA 17');
  assert.equal(svd.subarray(1, 6).toString('ascii'), 'CD001');
  assert.equal(svd.subarray(88, 91).toString('ascii'), '%/E', 'Joliet escape sequence');
  assert.equal(sector(18)[0], 255, 'volume descriptor set terminator');

  // Joliet text fields are UCS-2BE (a plain ASCII label would mount as mojibake).
  function ucs2be(buf, start, length) {
    let text = '';
    for (let i = start; i < start + length; i += 2) {
      const code = (buf[i] << 8) | buf[i + 1];
      if (code) text += String.fromCharCode(code);
    }
    return text.replace(/\s+$/, '');
  }
  const meta = JSON.parse(fs.readFileSync(path.join(discDir, 'persona', 'meta.json'), 'utf8'));
  const expectedLabel = String(meta.nameJp || meta.name || 'DISCPERSONA').slice(0, 16);
  assert.equal(ucs2be(svd, 40, 32), expectedLabel, 'Joliet volume id is UCS-2BE (Unicode label)');
  assert.equal(ucs2be(svd, 574, 128), 'DISCPERSONA', 'Joliet application id is UCS-2BE');
  // The primary descriptor cannot hold non-ASCII: it must fall back to a clean ASCII label.
  assert.equal(pvd.subarray(40, 72).toString('ascii').trim(), 'DISCPERSONA', 'primary volume id fallback');
});

test('burn-iso lists drives and fails cleanly without a writer/drive', () => {
  const list = run('tools/burn-iso.js', ['--list-drives']);
  assert.equal(list.status, 0, '--list-drives must succeed without hardware:\n' + output(list));
  assert.match(list.stdout, /BURN_OK LIST \d+ bytes /);

  const missing = run('tools/burn-iso.js', ['--iso-path', path.join(tmpRoot, 'nope.iso'), '--drive', '/dev/sr0']);
  assert.equal(missing.status, 1);
  assert.match(output(missing), /BURN_FAIL B0[15] /);
});

test('disc-watch installs a prompt-mode autostart entry and removes it', () => {
  const xdg = path.join(tmpRoot, 'watch-xdg');
  const env = {
    XDG_CONFIG_HOME: path.join(xdg, 'config'),
    XDG_STATE_HOME: path.join(xdg, 'state'),
  };
  const desktop = path.join(xdg, 'config', 'autostart', 'disklife-disc-watch.desktop');

  const install = run('engine/tools/disc-watch.js', ['--install'], { env });
  assert.equal(install.status, 0, output(install));
  const text = fs.readFileSync(desktop, 'utf8');
  assert.match(text, /^\[Desktop Entry\]/m);
  assert.match(text, /--prompt/);
  assert.match(text, /^X-GNOME-Autostart-enabled=true$/m);

  const remove = run('engine/tools/disc-watch.js', ['--uninstall'], { env });
  assert.equal(remove.status, 0, output(remove));
  assert.ok(!fs.existsSync(desktop));
});

test('disc-watch detects a disc tree and rejects a plain directory', () => {
  const hit = run('engine/tools/disc-watch.js', ['--test-root', discDir, '--dry-run', '--once']);
  assert.equal(hit.status, 0, 'watcher should recognise the disc:\n' + output(hit));

  const plain = path.join(tmpRoot, 'plain');
  fs.mkdirSync(plain);
  const miss = run('engine/tools/disc-watch.js', ['--test-root', plain, '--dry-run', '--once']);
  assert.equal(miss.status, 1, 'watcher must ignore a non-disc directory');
});

async function startStudio(extraEnv) {
  const child = spawn(NODE, [path.join(REPO, 'studio', 'server.js'), '--port', '0', '--no-browser'], {
    cwd: REPO,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: Object.assign({}, process.env, extraEnv || {}),
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (d) => { stdout += d; });
  child.stderr.on('data', (d) => { stderr += d; });
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const m = stdout.match(/http:\/\/127\.0\.0\.1:(\d+)\//);
    if (m) {
      const url = m[0];
      for (let i = 0; i < 50; i++) {
        try {
          const res = await fetch(url + 'api/env');
          if (res.ok) return { child, url, getLogs: () => stdout + stderr };
        } catch { /* not ready yet */ }
        await new Promise((r) => setTimeout(r, 200));
      }
    }
    if (child.exitCode !== null) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  child.kill('SIGTERM');
  throw new Error('Studio did not start.\nstdout:\n' + stdout + '\nstderr:\n' + stderr);
}

async function stopStudio(child) {
  if (child.exitCode !== null) return;
  child.kill('SIGTERM');
  await new Promise((resolve) => {
    const timer = setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 3000);
    child.once('exit', () => { clearTimeout(timer); resolve(); });
  });
}

test('Studio serves /api/env and /api/personas', async () => {
  const studio = await startStudio();
  try {
    const env = await (await fetch(studio.url + 'api/env')).json();
    assert.equal(env.ok, true);
    assert.equal(path.resolve(env.workspace), REPO);
    assert.ok(Array.isArray(env.payloadPresets) && env.payloadPresets.length >= 4);
    assert.equal(typeof env.hasKey, 'boolean');
    assert.ok(!JSON.stringify(env).includes('sk-'), 'the API key must never be returned');

    const personas = await (await fetch(studio.url + 'api/personas')).json();
    assert.equal(personas.ok, true);
    assert.ok(Array.isArray(personas.items));
  } finally {
    await stopStudio(studio.child);
  }
});

test('credentials import accepts a browser-session login (no account records)', () => {
  const cred = require(path.join(REPO, 'engine', 'lib', 'credentials.js'));
  const dir = fs.mkdtempSync(path.join(tmpRoot, 'cred-'));
  const source = path.join(dir, 'source.yaml');
  const target = path.join(dir, 'target.yaml');
  fs.writeFileSync(source, [
    'version: 1',
    'records:',
    '  client-connection/browser-session:',
    '    kind: grant',
    '    payload:',
    '      version: 1',
    '      secret: test-only-not-a-real-secret',
    'refs:',
    '  DEEPSEEK_API_KEY: sk-test-only-not-real',
    '  UNRELATED_SECRET: do-not-copy',
    '',
  ].join('\n'));
  fs.chmodSync(source, 0o600);
  assert.equal(cred.credentialHasLlm(source), true);
  const result = cred.importLlmCredentials(source, target);
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.equal(cred.credentialHasLlm(target), true);
  assert.equal(fs.statSync(target).mode & 0o777, 0o600);
  const text = fs.readFileSync(target, 'utf8');
  assert.match(text, /client-connection\/browser-session/);
  assert.match(text, /DEEPSEEK_API_KEY/);
  assert.doesNotMatch(text, /UNRELATED_SECRET/);
});

test('Studio exposes Linux integration and toggles the autostart entry', async () => {
  const xdg = path.join(tmpRoot, 'studio-xdg');
  const studio = await startStudio({
    XDG_CONFIG_HOME: path.join(xdg, 'config'),
    XDG_STATE_HOME: path.join(xdg, 'state'),
  });
  const desktop = path.join(xdg, 'config', 'autostart', 'disklife-disc-watch.desktop');
  try {
    const info = await (await fetch(studio.url + 'api/linux/integration')).json();
    assert.equal(info.ok, true);
    assert.equal(info.platform, 'linux');
    assert.ok(info.distro && info.distro.id, 'distro must be detected');
    assert.match(info.distro.packageUrl || '', /^https?:\/\//, 'distro package page URL');
    assert.equal(info.autostart.installed, false);

    const install = await (await fetch(studio.url + 'api/linux/autostart', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'install' }),
    })).json();
    assert.equal(install.ok, true, JSON.stringify(install).slice(0, 1000));
    assert.equal(install.info.autostart.installed, true);
    assert.match(fs.readFileSync(desktop, 'utf8'), /--prompt/);

    const uninstall = await (await fetch(studio.url + 'api/linux/autostart', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'uninstall' }),
    })).json();
    assert.equal(uninstall.ok, true);
    assert.equal(uninstall.info.autostart.installed, false);
    assert.ok(!fs.existsSync(desktop));
  } finally {
    await stopStudio(studio.child);
  }
});

test('Studio builds a sealed persona disc through /api/build', async () => {
  const studio = await startStudio();
  const outDir = path.join(REPO, 'build', 'it-studio-sealed');
  const pass = 'studio-seal-test-pass-123';
  try {
    const res = await fetch(studio.url + 'api/build', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        persona: 'examples/sample-persona',
        out: 'build/it-studio-sealed',
        payload: 'none',
        force: true,
        seal: true,
        sealPassphrase: pass,
      }),
    });
    const body = await res.json();
    assert.equal(body.ok, true, JSON.stringify(body).slice(0, 2000));
    assert.equal(body.sealed, true);
    assert.equal(body.testOk, true);
    assert.ok(fs.existsSync(path.join(outDir, 'persona', 'persona.sealed')));
    assert.ok(!fs.existsSync(path.join(outDir, 'persona', 'persona.yml')));
    const seal = require(path.join(REPO, 'engine', 'lib', 'seal.js'));
    const restored = path.join(tmpRoot, 'studio-sealed-out');
    seal.unsealToDir(path.join(outDir, 'persona', 'persona.sealed'), pass, restored);
    assert.ok(fs.existsSync(path.join(restored, 'persona.yml')));
  } finally {
    await stopStudio(studio.child);
    fs.rmSync(outDir, { recursive: true, force: true });
  }
});

test('Studio rejects a foreign Host header (127.0.0.1 only)', async () => {
  const studio = await startStudio();
  try {
    const http = require('node:http');
    const port = new URL(studio.url).port;
    const status = await new Promise((resolve, reject) => {
      const req = http.request(
        { host: '127.0.0.1', port, path: '/api/env', method: 'GET', headers: { Host: 'evil.example' } },
        (res) => { res.resume(); resolve(res.statusCode); },
      );
      req.on('error', reject);
      req.end();
    });
    assert.equal(status, 403);
  } finally {
    await stopStudio(studio.child);
  }
});

test('Studio builds a disc through /api/build', async () => {
  const studio = await startStudio();
  const outDir = path.join(REPO, 'build', 'it-studio-disc');
  try {
    const res = await fetch(studio.url + 'api/build', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        persona: 'examples/sample-persona',
        out: 'build/it-studio-disc',
        payload: 'none',
        force: true,
      }),
    });
    const body = await res.json();
    assert.equal(body.ok, true, JSON.stringify(body).slice(0, 2000));
    assert.match(body.discID, /^[0-9a-f]{16}$/);
    assert.equal(body.testOk, true);
    assert.ok(fs.existsSync(path.join(outDir, 'start.sh')));
  } finally {
    await stopStudio(studio.child);
    fs.rmSync(outDir, { recursive: true, force: true });
  }
});
