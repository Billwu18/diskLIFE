#!/usr/bin/env node
'use strict';

// Encrypt a whole persona room (or any directory) into one portable .dlseal file.
//
// The room stays plaintext on this machine; this is for backups/migration over a USB stick or
// cloud storage. The file format is the same one the launcher uses for sealed persona discs
// (scrypt + AES-256-GCM), so `engine/lib/seal.js unseal-tree` can restore it anywhere Node runs.

const fs = require('fs');
const path = require('path');
const os = require('os');
const common = require('./lib/common');
const seal = require('../engine/lib/seal');

const out = common.out;
const workspaceRoot = path.resolve(__dirname, '..');

const USAGE = `
Usage:
  node tools/backup-room.js --room <dir> [--out <file.dlseal>] [options]

Options:
  --room <dir>          Persona room to encrypt (e.g. ~/.local/DiscPersona/personas/<discID>)
  --out <file>          Output file; default: build/backups/<room>-<timestamp>.dlseal
  --passphrase-stdin    Read the passphrase from the first stdin line
  --verify              Decrypt to a temporary directory to verify the archive
  --force               Overwrite an existing output file
  --help                Show this help

Last line: ROOM_BACKUP_OK <file> <files> files
`.trim();

function fail(message) {
    out.blank();
    out.line('ROOM_BACKUP_FAIL ' + message);
    process.exit(1);
}

function stamp() {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' +
        p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
}

function main() {
    const parsed = common.parseArgs(process.argv.slice(2), {
        values: ['room', 'out'],
        flags: ['passphraseStdin', 'verify', 'force'],
        aliases: { Room: 'room', Out: 'out', PassphraseStdin: 'passphraseStdin', Verify: 'verify', Force: 'force' },
    });
    if (parsed.errors.length > 0 || parsed.positionals.length > 0) {
        common.failUsage('backup-room.js', USAGE, parsed.errors.concat(
            parsed.positionals.map((value) => 'unexpected argument: ' + value)));
        return;
    }
    if (parsed.opts.help) { out.line(USAGE); return; }
    if (!parsed.opts.room) { common.failUsage('backup-room.js', USAGE, ['--room is required']); return; }

    const room = path.resolve(process.cwd(), String(parsed.opts.room));
    if (!common.isDirectory(room)) fail('room directory not found: ' + room);
    if (!common.isFile(path.join(room, 'state.json'))) {
        out.warn('This directory has no state.json; it may not be a persona room (backing it up anyway).');
    }

    const outPath = parsed.opts.out
        ? path.resolve(process.cwd(), String(parsed.opts.out))
        : path.join(workspaceRoot, 'build', 'backups', path.basename(room) + '-' + stamp() + '.dlseal');
    if (common.exists(outPath) && !parsed.opts.force) {
        fail('output already exists: ' + outPath + ' (remove it or choose another --out)');
    }
    common.ensureDir(path.dirname(outPath));

    let passphrase;
    try {
        passphrase = parsed.opts.passphraseStdin
            ? seal.readPassphraseFromStdin()
            : seal.promptPassphrase('Passphrase for the encrypted room backup: ');
        if (!parsed.opts.passphraseStdin && !process.env.DISKLIFE_PASSPHRASE) {
            const repeat = seal.promptPassphrase('Repeat passphrase: ');
            if (repeat !== passphrase) throw new Error('the two passphrases do not match');
        }
    } catch (error) {
        fail('cannot read the passphrase: ' + (error && error.message ? error.message : String(error)));
    }
    if (!passphrase || passphrase.length < 8) fail('the passphrase must be at least 8 characters');

    out.blank();
    out.line('Room backup');
    out.line('  Room   : ' + room);
    out.line('  Output : ' + outPath);
    let count;
    try {
        count = seal.sealTreeToFile(room, outPath, passphrase);
    } catch (error) {
        fail('cannot encrypt the room: ' + (error && error.message ? error.message : String(error)));
    }
    const size = fs.statSync(outPath).size;
    out.ok('encrypted ' + count + ' files (' + size + ' bytes)');

    if (parsed.opts.verify) {
        const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'disklife-room-verify-'));
        try {
            const restored = seal.unsealTreeFromFile(outPath, tmp, passphrase);
            if (restored !== count) throw new Error('restored ' + restored + ' files, expected ' + count);
            out.ok('verify: decrypted ' + restored + ' files into a temporary directory');
        } catch (error) {
            fail('verify failed: ' + (error && error.message ? error.message : String(error)));
        } finally {
            try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (error) { /* ignore */ }
        }
    }

    out.blank();
    out.line('ROOM_BACKUP_OK ' + outPath + ' ' + count + ' files');
    process.exit(0);
}

main();
