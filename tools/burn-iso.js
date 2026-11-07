#!/usr/bin/env node
'use strict';

// Burn an ISO to a CD/DVD/BD writer on Linux.
//
// Wraps whichever writer tool is installed (xorriso / cdrskin / cdrecord /
// wodim / growisofs). Drive and media information comes from /dev/sr* and /sys/block
// so --list-drives works even when no writer tool is installed.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const common = require('./lib/common');

const out = common.out;
const startedAt = Date.now();

const USAGE = `
Usage:
  node tools/burn-iso.js --list-drives
  node tools/burn-iso.js --iso <file.iso> --drive <dev> [options]

Options:
  --list-drives           List optical drives and exit
  --iso <file.iso>        ISO image to burn (alias: --iso-path)
  --drive <dev>           Device: /dev/sr0, sr0 or 0
  --volume-label <label>  Informational volume label (default: DISCPERSONA)
  --test-only             Check drive/media/link only; do not write
  --eject                 Eject the tray after a successful burn
  --help                  Show this help

Aliases: --IsoPath, --DriveLetter, --TestOnly, --ListDrives.
Last line: BURN_OK <drive> <bytes> bytes <seconds>s / BURN_FAIL <B01..B08> <reason>
`.trim();

const MEDIA_NAMES = {
    0: 'Unknown',
    1: 'CD-ROM',
    2: 'CD-R',
    3: 'CD-RW',
    4: 'DVD-ROM',
    5: 'DVD-RAM',
    6: 'DVD+R',
    7: 'DVD+RW',
    8: 'DVD-R',
    9: 'DVD-RW',
    10: 'DVD+R DL',
    11: 'DVD-R DL',
    12: 'DVD+RW DL',
    13: 'BD-ROM',
    14: 'BD-R',
    15: 'BD-R',
    16: 'BD-RE'
};

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

function writerTools() {
    const found = [];
    for (const name of ['xorriso', 'cdrskin', 'cdrecord', 'wodim', 'growisofs']) {
        const tool = which(name);
        if (tool) found.push({ name: name, path: tool });
    }
    return found;
}

function readTextIfExists(filePath) {
    try {
        return fs.readFileSync(filePath, 'utf8').trim();
    } catch (error) {
        return '';
    }
}

function sysfsPath(device, leaf) {
    const name = path.basename(device);
    for (const base of ['/sys/block/' + name, '/sys/class/block/' + name]) {
        const full = path.join(base, leaf);
        if (fs.existsSync(full)) return full;
    }
    return null;
}

function driveInfo(device) {
    const sizeText = readTextIfExists(sysfsPath(device, 'size') || '');
    const sectors512 = sizeText ? parseInt(sizeText, 10) : 0;
    const sizeBytes = Number.isFinite(sectors512) ? sectors512 * 512 : 0;
    const vendor = readTextIfExists((sysfsPath(device, 'device/vendor') || ''));
    const model = readTextIfExists((sysfsPath(device, 'device/model') || ''));
    const removable = readTextIfExists((sysfsPath(device, 'removable') || ''));
    return {
        device: device,
        model: (vendor + ' ' + model).replace(/\s+/g, ' ').trim() || '(model unknown)',
        sizeBytes: sizeBytes,
        mediaPresent: sizeBytes > 0,
        removable: removable === '1'
    };
}

function normalizeDrive(value) {
    if (!value) return null;
    let text = String(value).trim();
    if (/^\d+$/.test(text)) text = '/dev/sr' + text;
    if (/^sr\d+$/.test(text)) text = '/dev/' + text;
    return text;
}

function isBlockDevice(device) {
    try {
        return fs.statSync(device).isBlockDevice();
    } catch (error) {
        return false;
    }
}

// Only ever write to an optical device. A typo such as --drive /dev/nvme0n1 must never be treated
// as a burner target (the kernel/udisks may deny it, but the guard is what makes that reliable).
function isOpticalDevice(device) {
    let resolved = device;
    try { resolved = fs.realpathSync(device); } catch (error) { /* keep the given path */ }
    return /^(sr\d+|cdrom\d*|dvd\d*|dvdrw\d*|cdwriter\d*)$/.test(path.basename(resolved));
}

function findDrives() {
    let names = [];
    try {
        names = fs.readdirSync('/dev').filter(function (name) { return /^sr\d+$/.test(name); });
    } catch (error) {
        names = [];
    }
    names.sort(function (a, b) {
        return parseInt(a.slice(2), 10) - parseInt(b.slice(2), 10);
    });
    const devices = names.map(function (name) { return '/dev/' + name; });
    // Keep block devices; also keep a symlinked/odd node as long as it exists.
    return devices.filter(function (device) {
        return isBlockDevice(device) || fs.existsSync(device);
    });
}

// Query the drive with a writer tool; returns {blank, raw} or null.
function mediaInfo(tools, device) {
    if (tools.length === 0) return null;
    const preferred = tools.find(function (tool) { return tool.name === 'xorriso'; }) || tools[0];
    let args;
    if (preferred.name === 'xorriso') {
        args = ['-as', 'cdrecord', '-msinfo', 'dev=' + device];
    } else {
        args = ['-msinfo', 'dev=' + device];
    }
    const result = spawnSync(preferred.path, args, { encoding: 'utf8', timeout: 20000 });
    const text = ((result.stdout || '') + '\n' + (result.stderr || '')).trim();
    const match = /(\d+)\s*,\s*(\d+)/.exec(text);
    if (result.status === 0 && match) {
        const first = parseInt(match[1], 10);
        const last = parseInt(match[2], 10);
        return { blank: first === 0 && last === 0, raw: first + ',' + last, tool: preferred.name };
    }
    if (preferred.name === 'xorriso') {
        // -msinfo only works on appendable media. For blank/finalized CD-R, ask xorriso directly.
        const info = spawnSync(preferred.path, ['-dev', device, '-list_formats'],
            { encoding: 'utf8', timeout: 20000 });
        const infoText = ((info.stdout || '') + '\n' + (info.stderr || '')).trim();
        const status = /Media status\s*:\s*([^\n]+)/i.exec(infoText);
        if (info.status === 0 && status) {
            const statusText = status[1].trim();
            const media = /Media current\s*:\s*([^\n]+)/i.exec(infoText);
            return {
                blank: /is blank/i.test(statusText),
                raw: statusText + (media ? ' (' + media[1].trim() + ')' : ''),
                tool: 'xorriso'
            };
        }
    }
    return null;
}

// Best-effort B02 probe: ask the writer whether this drive can burn at all.
// Returns true (cannot burn), false (looks fine), or null (no conclusion).
function probeBurnSupport(tools, device) {
    const tool = tools.find(function (item) { return item.name !== 'growisofs'; });
    if (!tool) return null;
    const args = tool.name === 'xorriso'
        ? ['-as', 'cdrecord', '-checkdrive', 'dev=' + device]
        : ['-checkdrive', 'dev=' + device];
    const result = spawnSync(tool.path, args, { encoding: 'utf8', timeout: 20000 });
    const text = ((result.stdout || '') + '\n' + (result.stderr || ''));
    if (/does not support|not support.{0,40}(burn|writ)|not a (cd|dvd|bd) writer|no burner/i.test(text)) {
        return true;
    }
    return null;
}

// Open the drive with the writer tool and report whether it is usable.
// This is what --test-only means: the writer really opened the device (not just stat'ed /dev/sr0).
function checkDrive(tools, device) {
    const tool = tools.find(function (item) { return item.name === 'xorriso'; }) ||
        tools.find(function (item) { return item.name === 'cdrskin'; }) ||
        tools.find(function (item) { return item.name !== 'growisofs'; });
    if (!tool) return { ok: null, text: '', tool: null };
    const args = tool.name === 'xorriso'
        ? ['-as', 'cdrecord', '-checkdrive', 'dev=' + device]
        : ['-checkdrive', 'dev=' + device];
    const result = spawnSync(tool.path, args, { encoding: 'utf8', timeout: 30000 });
    const text = ((result.stdout || '') + '\n' + (result.stderr || '')).trim();
    return { ok: result.status === 0, text: text, tool: tool.name };
}

// Pick the most useful lines out of a writer tool's output (last line alone is often just "aborting").
function summarizeWriterError(text) {
    const lines = String(text || '').split(/\r?\n/).map(function (line) { return line.trim(); }).filter(Boolean);
    const interesting = lines.filter(function (line) {
        return /FAILURE|FATAL|Lost connection|Permission denied|cannot access|Cannot acquire|cannot open|Cannot open|No media|no media|not blank|already|host problem|SCSI command/i.test(line);
    });
    const chosen = (interesting.length > 0 ? interesting : lines).slice(0, 2);
    return chosen.join(' / ').replace(/^xorriso\s*:\s*/i, '').replace(/^cdrskin\s*:\s*/i, '');
}

function connectionProblemHint() {
    return 'The kernel log shows repeated USB disconnects/resets for this drive. ' +
        'Replug it into another USB port (prefer a rear/motherboard port, no hub), use another cable, ' +
        'and check the drive on a machine with enough USB power. Then run --list-drives again.';
}

function failBurn(code, reason, hint) {
    out.blank();
    out.fail(reason);
    if (hint) out.line('  How to fix: ' + hint);
    out.blank();
    out.line('BURN_FAIL ' + code + ' ' + reason);
    process.exit(1);
}

function completeBurn(drive, bytes) {
    const seconds = Math.round(((Date.now() - startedAt) / 1000) * 10) / 10;
    out.blank();
    out.line('BURN_OK ' + drive + ' ' + bytes + ' bytes ' + seconds + 's');
    process.exit(0);
}

function main() {
    const parsed = common.parseArgs(process.argv.slice(2), {
        values: ['iso', 'drive', 'volumeLabel'],
        flags: ['listDrives', 'testOnly', 'eject'],
        aliases: {
            IsoPath: 'iso',
            Iso: 'iso',
            DriveLetter: 'drive',
            VolumeLabel: 'volumeLabel',
            ListDrives: 'listDrives',
            TestOnly: 'testOnly',
            Eject: 'eject'
        }
    });
    if (parsed.errors.length > 0 || parsed.positionals.length > 0) {
        common.failUsage('burn-iso.js', USAGE, parsed.errors.concat(
            parsed.positionals.map(function (value) { return 'unexpected argument: ' + value; })));
        return;
    }
    if (parsed.opts.help) {
        out.line(USAGE);
        return;
    }
    const opts = parsed.opts;

    // ---------------------------------------------------------------- list
    if (opts.listDrives) {
        const tools = writerTools();
        out.blank();
        out.line('  Drives on this machine:');
        const drives = findDrives();
        for (const device of drives) {
            const info = driveInfo(device);
            let blank = 'unknown';
            if (info.mediaPresent) {
                const media = mediaInfo(tools, device);
                if (media) blank = media.blank ? 'yes' : 'no';
            }
            const capacity = info.mediaPresent
                ? 'media size=' + info.sizeBytes + ' bytes (' +
                    (Math.round((info.sizeBytes / (1024 * 1024)) * 100) / 100) + ' MiB)'
                : 'media size=0 bytes (no media or tray open)';
            out.line('  ' + device + '  ' + info.model + '  media=' +
                (info.mediaPresent ? 'present' : 'none') + '  blank=' + blank + '  ' + capacity +
                '  removable=' + (info.removable ? 'yes' : 'no'));
        }
        if (drives.length === 0) out.line('  (no drives found)');
        if (tools.length === 0) {
            out.line('  (no writer tool found: install xorriso, cdrskin, cdrecord/wodim or growisofs to burn)');
        } else {
            out.line('  Writer tool(s): ' + tools.map(function (tool) { return tool.name; }).join(', '));
        }
        out.line('');
        out.line('BURN_OK LIST 0 bytes 0s');
        process.exit(0);
    }

    // ---------------------------------------------------------------- checks
    if (!opts.iso) {
        failBurn('B05', 'No ISO file given (--iso).', 'Usage: --iso build/disc.iso --drive /dev/sr0');
    }
    const isoPath = path.resolve(process.cwd(), opts.iso);
    if (!common.isFile(isoPath)) {
        failBurn('B05', 'ISO file not found: ' + isoPath,
            'Run tools/new-iso.js first, or check the path.');
    }
    const isoSize = fs.statSync(isoPath).size;
    if (isoSize <= 0) {
        failBurn('B05', 'ISO file is 0 bytes: ' + isoPath, 'Rebuild the ISO, then burn again.');
    }

    if (!opts.drive) {
        failBurn('B01', 'No drive given (--drive).', 'Usage: --drive /dev/sr0 (or sr0, or 0).');
    }
    const device = normalizeDrive(opts.drive);
    if (!device || !isBlockDevice(device)) {
        failBurn('B01', 'Drive not found: ' + (device || opts.drive),
            'Run --list-drives to see the optical drives on this machine.');
    }
    if (!isOpticalDevice(device)) {
        failBurn('B01', 'Refusing to write to a non-optical device: ' + device,
            'Use an optical drive such as /dev/sr0 (run --list-drives to list them).');
    }

    const tools = writerTools();
    if (tools.length === 0) {
        failBurn('B06',
            'No CD/DVD writer tool found (looked for xorriso, cdrskin, cdrecord, wodim, growisofs).',
            'Install one, for example: sudo apt install xorriso   (or wodim, or dvd+rw-tools for growisofs).');
    }

    const info = driveInfo(device);
    out.line('  Target drive: ' + device + '  model: ' + info.model);
    if (!info.mediaPresent) {
        failBurn('B03', 'No media in the drive: ' + device, 'Insert a blank CD-R / DVD-R and try again.');
    }

    const burnSupport = probeBurnSupport(tools, device);
    if (burnSupport === true) {
        failBurn('B02', 'This drive cannot burn: ' + device,
            'Use a recordable CD/DVD writer, or check the drive and its driver.');
    }

    const media = mediaInfo(tools, device);
    const blankText = media ? (media.blank ? 'yes' : 'no') : 'unknown';
    out.line('  Media: ' + (media ? media.raw : 'unknown') + '  blank: ' + blankText);
    out.line('  ISO: ' + isoPath + ' (' + isoSize + ' bytes)');

    if (media && !media.blank && !opts.testOnly) {
        failBurn('B04', 'This disc already has content (media position ' + media.raw + '): ' + device,
            'Insert a blank disc; add --test-only to check the drive/link only.');
    }
    if (media && !media.blank && opts.testOnly) {
        out.warn('Note: the media is not blank (' + media.raw + '); --test-only only checks the link and does not write.');
    }

    // A writer that cannot open the drive usually means a cable/power problem or a stuck medium.
    // --test-only promises "the link works", so it must actually open the drive, like the PS burner does.
    const probe = (opts.testOnly || !media) ? checkDrive(tools, device) : null;
    if (probe && probe.ok === false) {
        const summary = summarizeWriterError(probe.text) || 'the writer could not open the drive';
        if (/no media|not ready|medium not present/i.test(probe.text) && !info.mediaPresent) {
            failBurn('B03', 'No media in the drive: ' + device, 'Insert a blank CD-R / DVD-R and try again.');
        }
        failBurn('B06', 'Cannot open the drive for writing: ' + device + ' (' + summary + ')',
            connectionProblemHint());
    }

    // ---------------------------------------------------------------- burn
    if (opts.testOnly) {
        out.line('  Test-only: the writer opened the drive (' + (probe && probe.tool ? probe.tool : 'writer') +
            '); skipping the actual write.');
        completeBurn(device, 0);
    }

    const preferred = tools.find(function (tool) { return tool.name === 'xorriso'; }) ||
        tools.find(function (tool) { return tool.name === 'cdrskin'; }) ||
        tools.find(function (tool) { return tool.name === 'cdrecord'; }) ||
        tools.find(function (tool) { return tool.name === 'wodim'; }) ||
        tools[0];

    let args;
    if (preferred.name === 'xorriso') {
        args = ['-as', 'cdrecord', '-v'];
        if (opts.eject) args.push('-eject');
        args.push('dev=' + device, isoPath);
    } else if (preferred.name === 'growisofs') {
        args = ['-Z', device + '=' + isoPath];
        if (opts.eject) args.push('-eject');
    } else {
        args = ['-v'];
        if (opts.eject) args.push('-eject');
        args.push('dev=' + device, isoPath);
    }

    out.line('  Writing with ' + preferred.name +
        (opts.volumeLabel ? ' (volume label ' + opts.volumeLabel + ')' : '') +
        ' (the volume label comes from the ISO itself)...');
    const result = spawnSync(preferred.path, args, {
        encoding: 'utf8',
        timeout: 60 * 60 * 1000,
        maxBuffer: 64 * 1024 * 1024
    });
    if (result.status !== 0) {
        const combined = ((result.stderr || '') + '\n' + (result.stdout || '')).trim();
        const reasonLine = summarizeWriterError(combined) || ('writer exited with code ' + result.status);
        if (/Lost connection|Cannot acquire|cannot access|Permission denied|host problem|SCSI command/i.test(combined)) {
            failBurn('B06', 'Lost the drive while writing: ' + reasonLine, connectionProblemHint());
        }
        if (/No media|no media|not ready|medium not present/i.test(combined)) {
            failBurn('B03', 'No media in the drive: ' + reasonLine, 'Insert a blank CD-R / DVD-R and try again.');
        }
        if (/not blank|already (has|contains)|has already been written/i.test(combined)) {
            failBurn('B04', 'This disc already has content: ' + reasonLine,
                'Insert a blank disc; add --test-only to check the drive/link only.');
        }
        failBurn('B07', 'Write failed: ' + reasonLine,
            'Try another blank disc; if it keeps failing, check the drive and the media for wear.');
    }

    out.line('  Write complete in ' + (Math.round(((Date.now() - startedAt) / 1000) * 10) / 10) +
        ' s; reading back for a check...');
    const readback = mediaInfo(tools, device);
    if (readback && readback.blank) {
        failBurn('B08', 'The disc still looks blank after writing (media position ' + readback.raw + ').',
            'Try another disc; if it still fails, do not use this one.');
    }
    if (readback) {
        out.ok('Read-back check: the media is no longer blank (media position ' + readback.raw + ')');
    } else {
        out.note('Read-back check could not query the media; the writer reported success.');
    }

    if (opts.eject) {
        if (preferred.name === 'growisofs' || preferred.name === 'xorriso' || preferred.name === 'cdrecord' || preferred.name === 'wodim') {
            // -eject was passed to the writer; nothing more to do.
            out.line('  Disc ejected.');
        } else {
            const eject = which('eject');
            if (eject) {
                const ejected = spawnSync(eject, [device], { encoding: 'utf8', timeout: 20000 });
                if (ejected.status === 0) out.line('  Disc ejected.');
                else out.warn('Eject failed (does not affect the burn result).');
            } else {
                out.warn('Eject requested, but no eject command was found.');
            }
        }
    }

    completeBurn(device, isoSize);
}

main();
