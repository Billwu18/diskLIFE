'use strict';
// diskLIFE sealed files (passphrase encryption)
//
// A small, dependency-free container used to keep the persona pack on the disc encrypted:
//
//   "DLIFESEAL1" | version(1) | salt(16) | iv(12) | tag(16) | ciphertext
//
// The key is scrypt(passphrase, salt, N=32768, r=8, p=1, 32 bytes); the payload is
// AES-256-GCM with the magic+version as additional authenticated data. The plaintext is JSON:
//   { "format": 1, "entries": [ { "path": "persona.yml", "mode": 420, "data": "<base64>" } ] }
//
// The format is intentionally minimal (no metadata leaks, no custom primitives). It is written
// and read by Windows and Linux launchers; the Windows launcher calls this file through Node.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const MAGIC = Buffer.from('DLIFESEAL1', 'ascii');
const VERSION = 1;
const SALT_LEN = 16;
const IV_LEN = 12;
const TAG_LEN = 16;
const KEY_LEN = 32;
const HEADER_LEN = MAGIC.length + 1 + SALT_LEN + IV_LEN + TAG_LEN;
const AAD = Buffer.concat([MAGIC, Buffer.from([VERSION])]);
const SCRYPT = { N: 32768, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const MAX_FILES = 20000;
const MAX_TOTAL_BYTES = 256 * 1024 * 1024;
const SKIP_NAMES = new Set(['meta.json', 'avatar.png', 'avatar.ico', 'persona.sealed', '.DS_Store', 'Thumbs.db']);

function deriveKey(passphrase, salt) {
  if (typeof passphrase !== 'string' || passphrase.length === 0) {
    throw new Error('empty passphrase');
  }
  return crypto.scryptSync(passphrase, salt, KEY_LEN, SCRYPT);
}

function validateRelPath(rel) {
  const text = String(rel == null ? '' : rel).replace(/\\/g, '/');
  if (!text || text.length > 512 || text.indexOf('\0') >= 0) throw new Error('invalid path: ' + rel);
  if (path.posix.isAbsolute(text) || /^[A-Za-z]:/.test(text)) throw new Error('absolute path in sealed file: ' + rel);
  const parts = text.split('/');
  for (const part of parts) {
    if (part === '' || part === '.' || part === '..') throw new Error('unsafe path in sealed file: ' + rel);
  }
  return text;
}

function collectEntries(dir, options) {
  const opts = options || {};
  const skip = opts.skipNames || SKIP_NAMES;
  const entries = [];
  let total = 0;

  function walk(fullDir, prefix) {
    let names;
    try { names = fs.readdirSync(fullDir).sort(); } catch (error) {
      throw new Error('cannot read directory ' + fullDir + ': ' + error.message);
    }
    for (const name of names) {
      if (skip.has(name)) continue;
      const full = path.join(fullDir, name);
      const rel = prefix ? prefix + '/' + name : name;
      let st;
      try { st = fs.lstatSync(full); } catch (error) { continue; }
      if (st.isSymbolicLink()) continue;
      if (st.isDirectory()) { walk(full, rel); continue; }
      if (!st.isFile()) continue;
      if (entries.length >= MAX_FILES) throw new Error('too many files to seal (limit ' + MAX_FILES + ')');
      total += st.size;
      if (total > MAX_TOTAL_BYTES) throw new Error('sealed payload is too large (limit ' + MAX_TOTAL_BYTES + ' bytes)');
      entries.push({ path: validateRelPath(rel), mode: st.mode & 0o777, data: fs.readFileSync(full) });
    }
  }

  walk(dir, '');
  return entries;
}

function encodeContainer(entries, kind, passphrase) {
  const plaintext = Buffer.from(JSON.stringify({
    format: 1,
    kind: kind || 'persona',
    createdAt: new Date().toISOString(),
    entries: entries.map((entry) => ({
      path: entry.path,
      mode: entry.mode,
      data: entry.data.toString('base64'),
    })),
  }), 'utf8');

  const salt = crypto.randomBytes(SALT_LEN);
  const iv = crypto.randomBytes(IV_LEN);
  const key = deriveKey(passphrase, salt);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(AAD);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([MAGIC, Buffer.from([VERSION]), salt, iv, tag, ciphertext]);
}

function decodeContainer(blob, passphrase) {
  if (!Buffer.isBuffer(blob) || blob.length < HEADER_LEN) throw new Error('not a diskLIFE sealed file (too short)');
  if (!blob.subarray(0, MAGIC.length).equals(MAGIC)) throw new Error('not a diskLIFE sealed file (bad magic)');
  const version = blob[MAGIC.length];
  if (version !== VERSION) throw new Error('unsupported sealed file version: ' + version);
  let offset = MAGIC.length + 1;
  const salt = blob.subarray(offset, offset + SALT_LEN); offset += SALT_LEN;
  const iv = blob.subarray(offset, offset + IV_LEN); offset += IV_LEN;
  const tag = blob.subarray(offset, offset + TAG_LEN); offset += TAG_LEN;
  const ciphertext = blob.subarray(offset);

  const key = deriveKey(passphrase, salt);
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAAD(AAD);
  decipher.setAuthTag(tag);
  let plaintext;
  try {
    plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  } catch (error) {
    throw new Error('cannot decrypt (wrong passphrase or damaged sealed file)');
  }

  let doc;
  try { doc = JSON.parse(plaintext.toString('utf8')); } catch (error) { throw new Error('sealed payload is not valid JSON'); }
  if (!doc || doc.format !== 1 || !Array.isArray(doc.entries)) throw new Error('unsupported sealed payload');
  if (doc.entries.length > MAX_FILES) throw new Error('sealed payload has too many files');
  let total = 0;
  const entries = doc.entries.map((entry) => {
    const rel = validateRelPath(entry && entry.path);
    const data = Buffer.from(String(entry.data || ''), 'base64');
    total += data.length;
    if (total > MAX_TOTAL_BYTES) throw new Error('sealed payload is too large');
    const mode = Number(entry.mode);
    return { path: rel, mode: Number.isFinite(mode) ? (mode & 0o777) : 0o644, data: data };
  });
  return { kind: doc.kind || 'persona', entries: entries };
}

function writeEntries(entries, destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  const root = path.resolve(destDir);
  for (const entry of entries) {
    const rel = validateRelPath(entry.path);
    const target = path.resolve(root, rel);
    if (target !== root && !target.startsWith(root + path.sep)) {
      throw new Error('refusing to write outside the target directory: ' + rel);
    }
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, entry.data, { mode: entry.mode || 0o644 });
    try { fs.chmodSync(target, entry.mode || 0o644); } catch (error) { /* best effort */ }
  }
}

function removeEmptyDirs(root) {
  let entries;
  try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch (error) { return; }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const full = path.join(root, entry.name);
    removeEmptyDirs(full);
    try { if (fs.readdirSync(full).length === 0) fs.rmdirSync(full); } catch (error) { /* ignore */ }
  }
}

// Encrypt a persona directory in place: writes <dir>/persona.sealed and removes the plaintext
// files, while keeping meta.json / avatar.png / avatar.ico visible for the disc label & icon.
function sealPersonaDir(dir, passphrase) {
  if (!fs.existsSync(path.join(dir, 'persona.yml'))) {
    throw new Error('persona.yml is missing (nothing to seal)');
  }
  const entries = collectEntries(dir);
  const blob = encodeContainer(entries, 'persona', passphrase);
  const sealedPath = path.join(dir, 'persona.sealed');
  const tmpPath = sealedPath + '.tmp';
  fs.writeFileSync(tmpPath, blob, { mode: 0o600 });
  fs.renameSync(tmpPath, sealedPath);
  for (const entry of entries) {
    try { fs.unlinkSync(path.join(dir, entry.path)); } catch (error) { /* best effort */ }
  }
  removeEmptyDirs(dir);
  return sealedPath;
}

// Decrypt a sealed persona to destDir. destDir must not exist or be empty; the caller usually
// decrypts into a temp directory and renames it into place.
function unsealToDir(sealedPath, passphrase, destDir) {
  const blob = fs.readFileSync(sealedPath);
  const doc = decodeContainer(blob, passphrase);
  writeEntries(doc.entries, destDir);
  return doc.entries.length;
}

// Generic tree encryption for room backups (all files, no exclusions).
function sealTreeToFile(rootDir, outPath, passphrase) {
  const entries = collectEntries(rootDir, { skipNames: new Set() });
  const blob = encodeContainer(entries, 'tree', passphrase);
  const tmpPath = outPath + '.tmp';
  fs.writeFileSync(tmpPath, blob, { mode: 0o600 });
  fs.renameSync(tmpPath, outPath);
  return entries.length;
}

function unsealTreeFromFile(inPath, outDir, passphrase) {
  const doc = decodeContainer(fs.readFileSync(inPath), passphrase);
  writeEntries(doc.entries, outDir);
  return doc.entries.length;
}

function looksSealed(buffer) {
  return Buffer.isBuffer(buffer) && buffer.length >= HEADER_LEN && buffer.subarray(0, MAGIC.length).equals(MAGIC);
}

function promptPassphrase(promptText) {
  if (process.env.DISKLIFE_PASSPHRASE) return process.env.DISKLIFE_PASSPHRASE;
  if (process.platform === 'win32') {
    throw new Error('no passphrase input (use the launcher, DISKLIFE_PASSPHRASE, or --passphrase-stdin)');
  }
  if (!process.stdin.isTTY) {
    throw new Error('no passphrase input (stdin is not a terminal; use --passphrase-stdin or DISKLIFE_PASSPHRASE)');
  }
  const script = 'stty -echo 2>/dev/null || true; trap "stty echo 2>/dev/null || true" EXIT INT TERM; ' +
    'printf "%s" "$1" >&2; IFS= read -r p; printf "\\n" >&2; printf "%s" "$p"';
  const result = spawnSync('sh', ['-c', script, 'sh', promptText || 'Passphrase: '], {
    stdio: ['inherit', 'pipe', 'inherit'],
    encoding: 'utf8',
  });
  if (result.error) throw new Error('cannot read the passphrase: ' + result.error.message);
  if (!result.stdout) throw new Error('empty passphrase');
  return result.stdout;
}

function readPassphraseFromStdin() {
  let text = '';
  try { text = fs.readFileSync(0, 'utf8'); } catch (error) { text = ''; }
  const line = text.split(/\r?\n/)[0];
  if (!line) throw new Error('empty passphrase on stdin');
  return line;
}

function usage() {
  return [
    'diskLIFE sealed files',
    '',
    'Usage:',
    '  node engine/lib/seal.js seal --dir <persona-dir> [--passphrase-stdin]',
    '  node engine/lib/seal.js decrypt --in <persona.sealed> --out <dir> [--passphrase-stdin]',
    '  node engine/lib/seal.js seal-tree --dir <room-dir> --out <backup.dlseal> [--passphrase-stdin]',
    '  node engine/lib/seal.js unseal-tree --in <backup.dlseal> --out <dir> [--passphrase-stdin]',
    '',
    'Passphrase sources: --passphrase-stdin, DISKLIFE_PASSPHRASE, or an interactive prompt.',
  ].join('\n');
}

function parseCli(argv) {
  const opts = { command: '', dir: '', out: '', in: '', passphraseStdin: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') opts.help = true;
    else if (arg === '--passphrase-stdin') opts.passphraseStdin = true;
    else if (arg === '--dir') opts.dir = argv[++i] || '';
    else if (arg === '--out') opts.out = argv[++i] || '';
    else if (arg === '--in') opts.in = argv[++i] || '';
    else if (!opts.command && !arg.startsWith('-')) opts.command = arg;
    else throw new Error('unknown argument: ' + arg);
  }
  return opts;
}

function readCliPassphrase(opts) {
  if (opts.passphraseStdin) return readPassphraseFromStdin();
  return promptPassphrase('Passphrase: ');
}

function main(argv) {
  let opts;
  try { opts = parseCli(argv); } catch (error) { process.stderr.write(error.message + '\n'); process.exit(2); }
  if (opts.help || !opts.command) { process.stdout.write(usage() + '\n'); return; }
  try {
    const pass = readCliPassphrase(opts);
    if (opts.command === 'seal') {
      if (!opts.dir) throw new Error('--dir is required');
      const out = sealPersonaDir(path.resolve(opts.dir), pass);
      process.stdout.write('SEALED_OK ' + out + '\n');
    } else if (opts.command === 'decrypt') {
      if (!opts.in || !opts.out) throw new Error('--in and --out are required');
      const count = unsealToDir(path.resolve(opts.in), pass, path.resolve(opts.out));
      process.stdout.write('UNSEALED_OK ' + count + ' files\n');
    } else if (opts.command === 'seal-tree') {
      if (!opts.dir || !opts.out) throw new Error('--dir and --out are required');
      const count = sealTreeToFile(path.resolve(opts.dir), path.resolve(opts.out), pass);
      process.stdout.write('SEALED_TREE_OK ' + count + ' files\n');
    } else if (opts.command === 'unseal-tree') {
      if (!opts.in || !opts.out) throw new Error('--in and --out are required');
      const count = unsealTreeFromFile(path.resolve(opts.in), path.resolve(opts.out), pass);
      process.stdout.write('UNSEALED_TREE_OK ' + count + ' files\n');
    } else {
      throw new Error('unknown command: ' + opts.command);
    }
  } catch (error) {
    process.stderr.write('SEAL_FAIL ' + (error && error.message ? error.message : String(error)) + '\n');
    process.exit(1);
  }
}

module.exports = {
  MAGIC,
  VERSION,
  HEADER_LEN,
  collectEntries,
  decodeContainer,
  encodeContainer,
  looksSealed,
  promptPassphrase,
  readPassphraseFromStdin,
  sealPersonaDir,
  sealTreeToFile,
  unsealToDir,
  unsealTreeFromFile,
  validateRelPath,
};

if (require.main === module) {
  main(process.argv.slice(2));
}
