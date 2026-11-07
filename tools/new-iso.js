#!/usr/bin/env node
'use strict';

// Pack a prepared disc tree into an ISO 9660 + Joliet image.
//
// Uses xorriso / genisoimage / mkisofs as an optional accelerator when one is
// installed; otherwise writes the image with the built-in pure-JS writer in
// tools/lib/iso9660.js. Both paths are verified by walking the image.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
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
  --volume-label <label>  Volume label; default from persona/meta.json, else DISCPERSONA
  --force                 Overwrite an existing ISO
  --engine <name>         auto (default) | builtin | xorriso | genisoimage | mkisofs
  --help                  Show this help

Aliases: --Source, --Out, --VolumeLabel, --Force.
Last line: ISO_OK <abs path> <bytes> bytes   (errors: ISO_FAIL <I01..I05> <reason>)
`.trim();

function fail(code, message) {
    out.blank();
    out.line('ISO_FAIL ' + code + ' ' + message);
    process.exit(1);
}

function which(name) {
    const paths = (process.env.PATH || '').split(path.delimiter);
    for (const dir of paths) {
        if (!dir) continue;
        const candidate = path.join(dir, name);
        try {
            fs.accessSync(candidate, fs.constants.X_OK);
            return candidate;
        } catch (error) { /* keep looking */ }
    }
    return null;
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
        values: ['source', 'out', 'volumeLabel', 'engine'],
        flags: ['force'],
        aliases: {
            Source: 'source',
            Out: 'out',
            VolumeLabel: 'volumeLabel',
            Force: 'force',
            Engine: 'engine'
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

    const engine = parsed.opts.engine || 'auto';
    let usedEngine = 'builtin';
    let builtinFallback = false;
    const builders = ['xorriso', 'genisoimage', 'mkisofs'];

    if (engine !== 'builtin') {
        let tool = null;
        if (engine === 'auto') {
            for (const name of builders) {
                tool = which(name);
                if (tool) break;
            }
        } else {
            if (builders.indexOf(engine) < 0) {
                fail('I03', 'Unknown engine: ' + engine + ' (expected auto|builtin|xorriso|genisoimage|mkisofs)');
            }
            tool = which(engine);
            if (!tool) {
                out.warn('Requested engine not found on PATH: ' + engine);
                if (engine !== 'builtin') fail('I03', 'Engine not found: ' + engine);
            }
        }

        if (tool) {
            out.line('==> Building with: ' + path.basename(tool));
            let args;
            if (path.basename(tool) === 'xorriso') {
                args = ['-as', 'mkisofs', '-R', '-J', '-joliet-long', '-V', label, '-o', outPath, sourcePath];
            } else {
                args = ['-R', '-J', '-joliet-long', '-V', label, '-o', outPath, sourcePath];
            }
            const result = spawnSync(tool, args, { encoding: 'utf8', timeout: 10 * 60 * 1000, maxBuffer: 32 * 1024 * 1024 });
            if (result.error) {
                out.warn('External ISO tool failed: ' + result.error.message);
            }
            if (result.status !== 0) {
                if (result.stdout) out.line(String(result.stdout).trimEnd());
                if (result.stderr) out.line(String(result.stderr).trimEnd());
                out.warn('External ISO tool exited with code ' + result.status);
            } else {
                usedEngine = path.basename(tool);
            }
            if (usedEngine === 'builtin') {
                // Fall back to the built-in writer (auto mode) instead of leaving no image.
                builtinFallback = true;
                try {
                    common.removeTree(outPath);
                } catch (error) { /* ignore */ }
            }
        }
    }

    if (usedEngine === 'builtin') {
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
    if (builtinFallback) out.warn('Fell back to the built-in ISO writer after the external tool failed.');

    out.blank();
    out.line('ISO_OK ' + path.resolve(outPath) + ' ' + size + ' bytes');
    process.exit(0);
}

main();
