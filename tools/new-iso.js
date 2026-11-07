#!/usr/bin/env node
'use strict';

// Pack a prepared disc tree into an ISO 9660 + Joliet image.
//
// Always uses the built-in pure-JS writer in tools/lib/iso9660.js: no external
// tool is required, and the image is verified by walking it back (names, sizes
// and SHA-256). xorriso/genisoimage add Rock Ridge entries that would change
// the on-disc tree shape, so they are deliberately not used here.

const fs = require('fs');
const path = require('path');
const common = require('./lib/common');
const iso = require('./lib/iso9660');

const out = common.out;
const workspaceRoot = path.resolve(__dirname, '..');

const USAGE = `
Usage:
  node tools/new-iso.js --source <disc-dir> [--out <file.iso>] [options]

Options:
  --source <dir>          Disc tree (the --out of new-disc.js)
  --out <file.iso>        Output ISO; default: build/<disc-dir-name>.iso
  --volume-label <label>  Volume label (Joliet/Unicode, max 16 chars; default: persona name)
                          The primary descriptor gets an ASCII fallback (DISCPERSONA).
  --force                 Overwrite an existing ISO
  --help                  Show this help

Aliases: --Source, --Out, --VolumeLabel, --Force.
Last line: ISO_OK <abs path> <bytes> bytes   (errors: ISO_FAIL <I01..I05> <reason>)
`.trim();

function fail(code, message) {
    out.blank();
    out.line('ISO_FAIL ' + code + ' ' + message);
    process.exit(1);
}

function defaultLabel(sourcePath) {
    let label = 'DISCPERSONA';
    const metaPath = path.join(sourcePath, 'persona', 'meta.json');
    if (common.isFile(metaPath)) {
        try {
            const meta = common.readJsonFile(metaPath);
            if (meta.nameJp) label = String(meta.nameJp);
            else if (meta.name) label = String(meta.name);
        } catch (error) { /* fall back below */ }
    }
    return iso.sanitizeVolumeId(label);
}

function main() {
    const parsed = common.parseArgs(process.argv.slice(2), {
        values: ['source', 'out', 'volumeLabel'],
        flags: ['force'],
        aliases: {
            Source: 'source',
            Out: 'out',
            VolumeLabel: 'volumeLabel',
            Force: 'force'
        }
    });
    if (parsed.errors.length > 0 || parsed.positionals.length > 0) {
        common.failUsage('new-iso.js', USAGE, parsed.errors.concat(
            parsed.positionals.map(function (value) { return 'unexpected argument: ' + value; })));
        return;
    }
    if (parsed.opts.help) {
        out.line(USAGE);
        return;
    }
    if (!parsed.opts.source) {
        common.failUsage('new-iso.js', USAGE, ['--source is required']);
        return;
    }

    let sourcePath = path.resolve(process.cwd(), parsed.opts.source);
    if (sourcePath !== path.parse(sourcePath).root) sourcePath = sourcePath.replace(/[\\/]+$/, '');
    if (!common.isDirectory(sourcePath)) fail('I01', 'Source directory not found: ' + sourcePath);

    let outPath;
    if (parsed.opts.out) {
        outPath = path.resolve(process.cwd(), parsed.opts.out);
    } else {
        outPath = path.join(workspaceRoot, 'build', path.basename(sourcePath) + '.iso');
    }

    if (common.exists(outPath)) {
        if (!parsed.opts.force) fail('I02', 'ISO already exists: ' + outPath + ' (use --force to overwrite)');
        common.removeTree(outPath);
    }
    common.ensureDir(path.dirname(outPath));

    const label = parsed.opts.volumeLabel
        ? iso.sanitizeVolumeId(parsed.opts.volumeLabel)
        : defaultLabel(sourcePath);

    out.blank();
    out.line('==> Source: ' + sourcePath);
    out.line('==> Label: ' + label);
    out.line('==> Output: ' + outPath);

    out.line('==> Building with: builtin (pure JS ISO 9660 + Joliet writer)');
    try {
        iso.writeIso(sourcePath, outPath, {
            volumeLabel: label,
            warn: function (text) { out.warn(text); }
        });
    } catch (error) {
        try {
            common.removeTree(outPath);
        } catch (cleanupError) { /* ignore */ }
        fail('I03', 'The image was not created: ' + (error && error.message ? error.message : String(error)));
    }

    if (!common.isFile(outPath)) fail('I03', 'The image was not created: ' + outPath);
    const size = fs.statSync(outPath).size;
    if (size < 32768) fail('I04', 'Image too small (' + size + ' bytes); it is probably empty.');

    // ------------------------------------------------------------------
    // Verify by walking the volume descriptors and directory records.
    // ------------------------------------------------------------------
    out.line('==> Verifying the image...');
    const report = iso.verifyIso(outPath, sourcePath, label);
    for (const warning of report.warnings || []) out.warn(warning);
    if (!report.ok) {
        for (const error of report.errors.slice(0, 20)) out.fail(error);
        if (report.errors.length > 20) out.fail('... and ' + (report.errors.length - 20) + ' more verification errors');
        fail('I05', 'Image verification failed (' + report.errors[0] + ')');
    }
    out.ok('verified ' + report.fileCount + ' files in ' + report.dirCount + ' directories' +
        (report.joliet ? ' (Joliet names + SHA-256 all match)' : ' (ISO 9660 names + SHA-256 all match)') +
        '; volume label "' + report.volumeLabel + '"');

    out.blank();
    out.line('ISO_OK ' + path.resolve(outPath) + ' ' + size + ' bytes');
    process.exit(0);
}

main();
