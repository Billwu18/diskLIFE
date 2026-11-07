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
  assert.equal(ucs2be(svd, 40, 32), 'DISCPERSONA', 'Joliet volume id must be UCS-2BE');
  assert.equal(ucs2be(svd, 574, 128), 'DISCPERSONA', 'Joliet application id must be UCS-2BE');
  assert.equal(pvd.subarray(40, 72).toString('ascii').trim(), 'DISCPERSONA', 'primary volume id');
});

test('burn-iso lists drives and fails cleanly without a writer/drive', () => {
  const list = run('tools/burn-iso.js', ['--list-drives']);
  assert.equal(list.status, 0, '--list-drives must succeed without hardware:\n' + output(list));
  assert.match(list.stdout, /BURN_OK LIST \d+ bytes /);

  const missing = run('tools/burn-iso.js', ['--iso-path', path.join(tmpRoot, 'nope.iso'), '--drive', '/dev/sr0']);
  assert.equal(missing.status, 1);
  assert.match(output(missing), /BURN_FAIL B0[15] /);
});

test('disc-watch detects a disc tree and rejects a plain directory', () => {
  const hit = run('engine/tools/disc-watch.js', ['--test-root', discDir, '--dry-run', '--once']);
  assert.equal(hit.status, 0, 'watcher should recognise the disc:\n' + output(hit));

  const plain = path.join(tmpRoot, 'plain');
  fs.mkdirSync(plain);
  const miss = run('engine/tools/disc-watch.js', ['--test-root', plain, '--dry-run', '--once']);
  assert.equal(miss.status, 1, 'watcher must ignore a non-disc directory');
});

async function startStudio() {
  const child = spawn(NODE, [path.join(REPO, 'studio', 'server.js'), '--port', '0', '--no-browser'], {
    cwd: REPO,
    stdio: ['ignore', 'pipe', 'pipe'],
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
