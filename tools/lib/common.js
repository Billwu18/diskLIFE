#!/usr/bin/env node
'use strict';

// Shared helpers for the Linux disc tools.
// CommonJS, Node builtins only. No dependencies.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const SECTOR = 2048;

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------
function sha256Buffer(buffer) {
    return crypto.createHash('sha256').update(buffer).digest('hex');
}

function sha256File(filePath) {
    const hash = crypto.createHash('sha256');
    const fd = fs.openSync(filePath, 'r');
    const chunk = Buffer.allocUnsafe(1024 * 1024);
    try {
        for (;;) {
            const read = fs.readSync(fd, chunk, 0, chunk.length, null);
            if (read <= 0) break;
            hash.update(chunk.subarray(0, read));
        }
    } finally {
        fs.closeSync(fd);
    }
    return hash.digest('hex');
}

// ---------------------------------------------------------------------------
// Text files (BOM aware)
// ---------------------------------------------------------------------------
function decodeUtf16Le(bytes) {
    let text = '';
    const end = bytes.length - (bytes.length % 2);
    for (let i = 0; i < end; i += 2) text += String.fromCharCode(bytes[i] | (bytes[i + 1] << 8));
    return text;
}

function decodeUtf16Be(bytes) {
    let text = '';
    const end = bytes.length - (bytes.length % 2);
    for (let i = 0; i < end; i += 2) text += String.fromCharCode((bytes[i] << 8) | bytes[i + 1]);
    return text;
}

function readTextFile(filePath) {
    const bytes = fs.readFileSync(filePath);
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
        return bytes.subarray(3).toString('utf8');
    }
    if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
        return decodeUtf16Le(bytes.subarray(2));
    }
    if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
        return decodeUtf16Be(bytes.subarray(2));
    }
    return bytes.toString('utf8');
}

function writeTextFile(filePath, text, encoding) {
    ensureDir(path.dirname(filePath));
    fs.writeFileSync(filePath, Buffer.from(text, encoding || 'utf8'));
}

function readJsonFile(filePath) {
    return JSON.parse(readTextFile(filePath));
}

function jsonText(value) {
    return JSON.stringify(value, null, 2) + '\n';
}

function writeJsonFile(filePath, value) {
    writeTextFile(filePath, jsonText(value), 'utf8');
}

// ---------------------------------------------------------------------------
// Filesystem helpers
// ---------------------------------------------------------------------------
function ensureDir(dir) {
    fs.mkdirSync(dir, { recursive: true });
}

function removeTree(target) {
    let st = null;
    try {
        st = fs.lstatSync(target);
    } catch (error) {
        if (error && error.code === 'ENOENT') return;
        throw error;
    }
    if (st.isDirectory()) {
        fs.rmSync(target, { recursive: true, force: true });
    } else {
        fs.unlinkSync(target);
    }
}

function exists(target) {
    try {
        fs.lstatSync(target);
        return true;
    } catch (error) {
        if (error && error.code === 'ENOENT') return false;
        throw error;
    }
}

function isDirectory(target) {
    try {
        return fs.statSync(target).isDirectory();
    } catch (error) {
        return false;
    }
}

function isFile(target) {
    try {
        return fs.statSync(target).isFile();
    } catch (error) {
        return false;
    }
}

function compareOrdinal(a, b) {
    if (a === b) return 0;
    return a < b ? -1 : 1;
}

function sortedEntries(dir) {
    return fs.readdirSync(dir).sort(compareOrdinal);
}

// Copy a tree. By default symlinks are skipped with a warning (the packer rule:
// never follow symlinks when copying external input onto the disc). Payload
// copies may pass dereferenceSymlinks: true so a pre-packaged profile keeps
// working on the disc.
function copyTree(source, destination, options) {
    const opts = options || {};
    const warn = typeof opts.warn === 'function' ? opts.warn : function () {};
    const stats = { files: 0, bytes: 0 };
    copyTreeInto(source, destination, opts, warn, stats, 0);
    return stats;
}

function copyTreeInto(source, destination, opts, warn, stats, depth) {
    if (depth > 64) {
        warn('Skipping a directory tree deeper than 64 levels: ' + source);
        return;
    }
    const st = fs.lstatSync(source);
    if (st.isSymbolicLink()) {
        if (!opts.dereferenceSymlinks) {
            warn('Skipping symlink (not copied): ' + source);
            return;
        }
        let targetStat = null;
        try {
            targetStat = fs.statSync(source);
        } catch (error) {
            warn('Skipping broken symlink: ' + source);
            return;
        }
        if (targetStat.isDirectory()) {
            ensureDir(destination);
            for (const name of sortedEntries(source)) {
                copyTreeInto(path.join(source, name), path.join(destination, name), opts, warn, stats, depth + 1);
            }
        } else if (targetStat.isFile()) {
            ensureDir(path.dirname(destination));
            fs.copyFileSync(source, destination);
            stats.files += 1;
            stats.bytes += targetStat.size;
        } else {
            warn('Skipping special file (not copied): ' + source);
        }
        return;
    }
    if (st.isDirectory()) {
        ensureDir(destination);
        try {
            fs.chmodSync(destination, st.mode & 0o777);
        } catch (error) { /* best effort */ }
        for (const name of sortedEntries(source)) {
            copyTreeInto(path.join(source, name), path.join(destination, name), opts, warn, stats, depth + 1);
        }
        return;
    }
    if (st.isFile()) {
        ensureDir(path.dirname(destination));
        fs.copyFileSync(source, destination);
        try {
            fs.chmodSync(destination, st.mode & 0o777);
        } catch (error) { /* best effort */ }
        stats.files += 1;
        stats.bytes += st.size;
        return;
    }
    warn('Skipping special file (not copied): ' + source);
}

// Walk every regular file under root. Returns [{ rel, full, size, mode }].
// Symlinks are reported through warn and skipped.
function walkFiles(root, options) {
    const opts = options || {};
    const warn = typeof opts.warn === 'function' ? opts.warn : function () {};
    const out = [];
    walkFilesInto(root, '', out, warn, 0);
    return out;
}

function walkFilesInto(root, prefix, out, warn, depth) {
    if (depth > 64) {
        warn('Skipping a directory tree deeper than 64 levels: ' + root);
        return;
    }
    for (const name of sortedEntries(root)) {
        const full = path.join(root, name);
        const rel = prefix ? prefix + '/' + name : name;
        const st = fs.lstatSync(full);
        if (st.isSymbolicLink()) {
            warn('Skipping symlink (not counted): ' + full);
            continue;
        }
        if (st.isDirectory()) {
            walkFilesInto(full, rel, out, warn, depth + 1);
        } else if (st.isFile()) {
            out.push({ rel: rel, full: full, size: st.size, mode: st.mode & 0o777 });
        } else {
            warn('Skipping special file (not counted): ' + full);
        }
    }
}

function countFiles(root) {
    return walkFiles(root).length;
}

function treeSize(root) {
    let files = 0;
    let bytes = 0;
    for (const item of walkFiles(root)) {
        files += 1;
        bytes += item.size;
    }
    return { files: files, bytes: bytes };
}

function isSubPath(parent, child) {
    const rel = path.relative(path.resolve(parent), path.resolve(child));
    return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

function isStrictSubPath(parent, child) {
    const rel = path.relative(path.resolve(parent), path.resolve(child));
    return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

// ---------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------
function nowIsoUtc() {
    return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function localOffsetSuffix(date) {
    const total = -date.getTimezoneOffset(); // minutes east of UTC
    const sign = total >= 0 ? '+' : '-';
    const abs = Math.abs(total);
    const hh = String(Math.floor(abs / 60)).padStart(2, '0');
    const mm = String(abs % 60).padStart(2, '0');
    return sign + hh + ':' + mm;
}

function nowIsoLocal() {
    const date = new Date();
    const pad = function (n) { return String(n).padStart(2, '0'); };
    return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) +
        'T' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds()) +
        localOffsetSuffix(date);
}

// Keep at most `max` UTF-16 code units, never splitting a surrogate pair.
function limitLabel(text, max) {
    if (text.length <= max) return text;
    let n = max;
    if (n > 0) {
        const code = text.charCodeAt(n - 1);
        if (code >= 0xd800 && code <= 0xdbff) n -= 1;
    }
    return text.slice(0, n);
}

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------
function normalizeOptionName(name) {
    return String(name).replace(/^-+/, '').replace(/[-_]/g, '').toLowerCase();
}

// spec = { values: ['persona', ...], flags: ['reusePad', ...], aliases: { Persona: 'persona' }, multi: ['plugins'] }
// Returns { opts, errors, positionals }. --help sets opts.help.
function parseArgs(argv, spec) {
    const values = new Map();
    const flags = new Map();
    const aliases = new Map();
    const multi = new Set(spec.multi || []);
    for (const key of spec.values || []) values.set(normalizeOptionName(key), key);
    for (const key of spec.flags || []) flags.set(normalizeOptionName(key), key);
    for (const alias of Object.keys(spec.aliases || {})) {
        aliases.set(normalizeOptionName(alias), normalizeOptionName(spec.aliases[alias]));
    }

    const opts = {};
    const errors = [];
    const positionals = [];

    function resolve(name) {
        const norm = normalizeOptionName(name);
        const target = aliases.has(norm) ? aliases.get(norm) : norm;
        if (values.has(target)) return { kind: 'value', key: values.get(target) };
        if (flags.has(target)) return { kind: 'flag', key: flags.get(target) };
        return null;
    }

    for (let i = 0; i < argv.length; i += 1) {
        const raw = argv[i];
        if (raw === '--help' || raw === '-h' || raw === '-?') {
            opts.help = true;
            continue;
        }
        if (raw === '--') {
            for (let j = i + 1; j < argv.length; j += 1) positionals.push(argv[j]);
            break;
        }
        if (raw.length < 2 || raw[0] !== '-') {
            positionals.push(raw);
            continue;
        }
        let name = raw;
        let inline = null;
        const eq = raw.indexOf('=');
        if (eq > 0) {
            name = raw.slice(0, eq);
            inline = raw.slice(eq + 1);
        }
        const found = resolve(name);
        if (!found) {
            errors.push('unknown option: ' + name);
            continue;
        }
        if (found.kind === 'flag') {
            if (inline !== null) {
                errors.push(name + ' does not take a value');
                continue;
            }
            opts[found.key] = true;
            continue;
        }
        let value = inline;
        if (value === null) {
            if (i + 1 >= argv.length) {
                errors.push('missing value for ' + name);
                continue;
            }
            value = argv[i + 1];
            i += 1;
        }
        if (multi.has(found.key)) {
            if (!Array.isArray(opts[found.key])) opts[found.key] = [];
            opts[found.key].push(value);
        } else {
            opts[found.key] = value;
        }
    }
    return { opts: opts, errors: errors, positionals: positionals };
}

function failUsage(scriptName, usage, errors) {
    for (const error of errors || []) process.stderr.write('error: ' + error + '\n');
    process.stderr.write('\n' + usage.trimEnd() + '\n');
    process.exitCode = 2;
}

// ---------------------------------------------------------------------------
// Console helpers (plain text; the machine markers are the stable contract)
// ---------------------------------------------------------------------------
const out = {
    line: function (text) { process.stdout.write((text === undefined ? '' : text) + '\n'); },
    ok: function (text) { process.stdout.write('  \u2713 ' + text + '\n'); },
    fail: function (text) { process.stdout.write('  \u2717 ' + text + '\n'); },
    skip: function (text) { process.stdout.write('  - ' + text + '\n'); },
    note: function (text) { process.stdout.write('  \u00b7 ' + text + '\n'); },
    warn: function (text) { process.stdout.write('  ! ' + text + '\n'); },
    section: function (text) { process.stdout.write('\n' + text + '\n'); },
    step: function (text) { process.stdout.write('\n' + text + '\n'); },
    blank: function () { process.stdout.write('\n'); }
};

module.exports = {
    SECTOR: SECTOR,
    sha256Buffer: sha256Buffer,
    sha256File: sha256File,
    readTextFile: readTextFile,
    writeTextFile: writeTextFile,
    readJsonFile: readJsonFile,
    jsonText: jsonText,
    writeJsonFile: writeJsonFile,
    ensureDir: ensureDir,
    removeTree: removeTree,
    exists: exists,
    isDirectory: isDirectory,
    isFile: isFile,
    compareOrdinal: compareOrdinal,
    sortedEntries: sortedEntries,
    copyTree: copyTree,
    walkFiles: walkFiles,
    countFiles: countFiles,
    treeSize: treeSize,
    isSubPath: isSubPath,
    isStrictSubPath: isStrictSubPath,
    nowIsoUtc: nowIsoUtc,
    nowIsoLocal: nowIsoLocal,
    limitLabel: limitLabel,
    parseArgs: parseArgs,
    failUsage: failUsage,
    out: out
};
