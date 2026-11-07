#!/usr/bin/env node
'use strict';

// Package a persona pack into a disc tree that can be burned to CD-R as-is.
// Linux port of tools/New-Disc.ps1, with the Linux entry point (start.sh) and
// a README that explains both the Windows and the Linux persona home.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const common = require('./lib/common');

const out = common.out;
const PAD_SIZE = 512;
const PAD_MAGIC = 'DISCPERSONA-PAD-V1';
const PAD_TS_OFFSET = 64;
const PAD_TS_SIZE = 32;
const PAD_RANDOM_OFFSET = 96;

const workspaceRoot = path.resolve(__dirname, '..');

const USAGE = `
Usage:
  node tools/new-disc.js --persona <dir> --out <dir> [options]

Options:
  --persona <dir>          Persona pack directory (meta.json + persona.yml)
  --out <dir>              Output disc directory (written to <out>.tmp, then swapped in)
  --payload-preset <name>  none | comfort | token | full (default: comfort)
  --reuse-pad              Reuse <out>/pad.bin so the discID does not change
  --force                  Allow replacing a non-empty directory that is not a disc
  --help                   Show this help

Aliases: --Persona, --Out, --PayloadPreset, --ReusePad, --Force.
Last line: DISC_OK discID=<hex> files=<n> out=<abs path>
`.trim();

function fail(messages) {
    out.blank();
    out.line('[FAIL] Persona pack check failed; no files were written.');
    for (const message of messages) out.fail(message);
    out.blank();
    process.exit(1);
}

function fatal(message) {
    out.blank();
    out.fail(message);
    out.blank();
    process.exit(1);
}

function safeName(text, fallback) {
    const value = String(text == null ? '' : text).replace(/[\r\n]/g, ' ').trim();
    return value || fallback;
}

// ---------------------------------------------------------------------------
// pad.bin / discID
// ---------------------------------------------------------------------------
function testPadMagic(bytes) {
    if (!bytes || bytes.length < PAD_MAGIC.length) return false;
    return bytes.subarray(0, PAD_MAGIC.length).toString('ascii') === PAD_MAGIC;
}

function newPadFile(padPath) {
    const bytes = Buffer.alloc(PAD_SIZE, 0x20); // spaces: the file reads as text
    Buffer.from(PAD_MAGIC, 'ascii').copy(bytes, 0);

    const stamp = common.nowIsoUtc();
    const stampBytes = Buffer.from(stamp, 'ascii');
    if (stampBytes.length > PAD_TS_SIZE) throw new Error('timestamp exceeds the pad.bin field');
    stampBytes.copy(bytes, PAD_TS_OFFSET);
    crypto.randomBytes(PAD_SIZE - PAD_RANDOM_OFFSET).copy(bytes, PAD_RANDOM_OFFSET);

    fs.writeFileSync(padPath, bytes);
    return stamp;
}

// ---------------------------------------------------------------------------
// Text generation
// ---------------------------------------------------------------------------
function newAutorunText(displayName, label, iconRel) {
    const lines = ['[autorun]', 'open=start.cmd'];
    if (iconRel) lines.push('icon=' + iconRel.split('/').join('\\'));
    lines.push('label=' + label);
    lines.push('action=Wake ' + displayName);
    lines.push('shell\\open\\command=start.cmd');
    return lines.join('\r\n') + '\r\n';
}

function newReadmeText(info) {
    const lines = [];
    lines.push('DiscPersona disc notes');
    lines.push('====================');
    lines.push('');
    lines.push('What this disc is');
    lines.push('-----------------');
    lines.push('Name: ' + info.displayName);
    lines.push('Version: ' + info.personaVersion);
    lines.push('Disc ID (discID): ' + info.discID);
    lines.push('Built at (UTC): ' + info.builtAt);
    lines.push('Engine version: ' + info.engineVersion);
    lines.push('');
    lines.push('This is a persona disc with its own launcher: the disc holds the persona pack (persona/),');
    lines.push('the runtime engine (engine/) and the launch scripts (start.cmd on Windows, start.sh on Linux).');
    lines.push('The engine only reads from the disc and never writes to it - CD-R is read-only anyway.');
    lines.push('');
    lines.push('How to use');
    lines.push('----------');
    lines.push('Windows:');
    lines.push('  1. Insert the disc into the drive.');
    lines.push('  2. Double-click start.cmd in the disc root; if autoplay appears, choose Run start.cmd.');
    lines.push('Linux:');
    lines.push('  1. Mount the disc (most desktops mount it automatically).');
    lines.push('  2. Run start.sh from the disc root: sh ./start.sh');
    lines.push('  3. The browser opens the local page automatically. If it does not, copy the address');
    lines.push('     printed in the launch window into your browser.');
    lines.push('');
    lines.push('Where data lives (important)');
    lines.push('----------------------------');
    lines.push('On the disc: read-only persona and engine; normally never modified, and it cannot be modified.');
    lines.push('Windows home: %LOCALAPPDATA%\\DiscPersona\\personas\\' + info.discID);
    lines.push('Linux room:   ~/.local/share/DiscPersona/personas/' + info.discID);
    lines.push('              ($XDG_DATA_HOME/DiscPersona/personas/' + info.discID + ' when XDG_DATA_HOME is set)');
    lines.push('      This is the home for this disc: sessions, memory, settings - all writable state lives here.');
    lines.push('      - a different discID = a different home, so discs do not interfere with each other;');
    lines.push('      - the same disc in another computer = a separate home there, with no automatic sync;');
    lines.push('      - to back up or migrate, copy the whole home directory.');
    lines.push('');
    lines.push('What happens if the home is deleted');
    lines.push('-----------------------------------');
    lines.push('It is the same as factory-resetting this disc on this machine: the next launch recreates an');
    lines.push('empty home and all conversations, memory and settings are lost. The persona on the disc is');
    lines.push('unaffected (it is read-only).');
    lines.push('');
    lines.push('What happens if the disc is removed');
    lines.push('-----------------------------------');
    lines.push('- The run is interrupted: the engine cannot read disc resources, in-flight requests fail,');
    lines.push('  the page may show errors.');
    lines.push('- Data already written to the home is kept (it is on the hard drive, unrelated to the disc).');
    lines.push('- Reinsert the disc and run the launcher again to continue; the interrupted request is not');
    lines.push('  retried automatically.');
    lines.push('');
    lines.push('The disc is read-only');
    lines.push('---------------------');
    lines.push('A CD-R cannot be written once it is finalized. Everything that needs writing goes to the home.');
    lines.push('If you see a read-only file system style error, check that the home is writable instead of');
    lines.push('trying to fix the disc.');
    lines.push('');
    lines.push('Burning notes (do not burn it as a boot disc)');
    lines.push('--------------------------------------------');
    lines.push('This is a data disc, not a system boot disc:');
    lines.push('  - do not tick Make bootable disc / Bootable, and do not write a boot record;');
    lines.push('  - burn this directory as a data disc / files and folders disc;');
    lines.push('  - if start.cmd (or start.sh), persona/ and this file are visible in the disc root after');
    lines.push('    burning, the burn is correct.');
    lines.push('');
    lines.push('Error code quick reference (launcher)');
    lines.push('-------------------------------------');
    lines.push('  E01 incomplete disc');
    lines.push('  E02 pad.bin cannot be read');
    lines.push('  E03 files were modified');
    lines.push('  E04 dsh not found');
    lines.push('  E05 unsupported environment');
    lines.push('  E06 home is not writable');
    lines.push('  E07 missing credentials');
    lines.push('  E08 persona file cannot be parsed');
    lines.push('  E09 startup timed out');
    lines.push('  E10 already running (exit code 0)');
    lines.push('');
    lines.push('What is on the disc');
    lines.push('-------------------');
    lines.push('  autorun.inf                  autoplay description (Windows; optional for Linux)');
    lines.push('  start.cmd                    Windows launch script');
    lines.push('  start.sh                     Linux launch script');
    lines.push('  README.txt                   this file');
    lines.push('  pad.bin                      512-byte identity file; discID is derived from it');
    lines.push('  persona/...                  persona pack (meta.json / persona.yml / AGENTS.md ...)');
    if (info.hasEngine) {
        lines.push('  engine/...                   runtime engine (PowerShell and/or Node.js)');
    } else {
        lines.push('  engine/                      not included on this disc (the workspace had no engine/ at');
        lines.push('                               build time)');
    }
    lines.push('  .discpersona/manifest.json   file hash manifest (contains discID; use it to verify integrity)');
    if (info.hasPayload) {
        lines.push('  .discpersona/payload/...     pre-installed plugin payload');
    }
    lines.push('');
    lines.push('Checking that this disc is complete');
    lines.push('-----------------------------------');
    lines.push('Copy the whole disc to a hard drive and run this on the build machine (tools is not on the disc):');
    lines.push('  node tools/test-disc.js --disc <copied directory>');
    lines.push('Every check marked OK means PASS; a hash mismatch means files were damaged during burn or copy.');
    lines.push('');
    lines.push('-- Generated by tools/new-disc.js; do not edit by hand.');
    return lines.join('\r\n') + '\r\n';
}

function getEngineVersion(engineDir) {
    if (!common.isDirectory(engineDir)) return 'dev';
    const versionFile = path.join(engineDir, 'version.txt');
    if (common.isFile(versionFile)) {
        const value = common.readTextFile(versionFile).split(/\r?\n/)[0].trim();
        if (value) return value;
    }
    const packageFile = path.join(engineDir, 'package.json');
    if (common.isFile(packageFile)) {
        try {
            const pkg = common.readJsonFile(packageFile);
            if (pkg && pkg.version) return String(pkg.version);
        } catch (error) {
            warnings.push('Cannot parse engine/package.json; engine version recorded as dev (' + error.message + ')');
        }
    }
    return 'dev';
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------
const warnings = [];
const notes = [];

function main() {
    const parsed = common.parseArgs(process.argv.slice(2), {
        values: ['persona', 'out', 'payloadPreset'],
        flags: ['reusePad', 'force'],
        aliases: {
            Persona: 'persona',
            Out: 'out',
            PayloadPreset: 'payloadPreset',
            ReusePad: 'reusePad',
            Force: 'force'
        }
    });
    if (parsed.errors.length > 0 || parsed.positionals.length > 0) {
        common.failUsage('new-disc.js', USAGE, parsed.errors.concat(
            parsed.positionals.map(function (value) { return 'unexpected argument: ' + value; })));
        return;
    }
    if (parsed.opts.help) {
        out.line(USAGE);
        return;
    }
    const personaArg = parsed.opts.persona;
    const outArg = parsed.opts.out;
    if (!personaArg || !outArg) {
        common.failUsage('new-disc.js', USAGE, ['--persona and --out are required']);
        return;
    }
    buildDisc(personaArg, outArg, parsed.opts);
}

function buildDisc(personaArg, outArg, opts) {
    const personaPath = path.resolve(process.cwd(), personaArg).replace(/[\\/]+$/, '');
    const outPath = path.resolve(process.cwd(), outArg).replace(/[\\/]+$/, '');
    const preset = opts.payloadPreset || 'comfort';
    const reusePad = !!opts.reusePad;
    const force = !!opts.force;

    out.blank();
    out.line('DiscPersona builder');
    out.line('  Persona     : ' + personaPath);
    out.line('  Out         : ' + outPath);
    out.line('  ReusePad    : ' + (reusePad ? 'yes' : 'no'));
    out.line('  Workspace   : ' + workspaceRoot);

    if (!common.isDirectory(personaPath)) {
        fatal('Persona pack directory does not exist: ' + personaPath);
    }
    if (outPath === path.parse(outPath).root) {
        fatal('Refusing to write the disc tree to a filesystem root: ' + outPath);
    }
    if (outPath === personaPath) {
        fatal('The output directory cannot be the persona pack directory.');
    }
    if (common.isStrictSubPath(personaPath, outPath)) {
        fatal('The output directory cannot be inside the persona pack.');
    }
    if (common.isStrictSubPath(outPath, personaPath)) {
        fatal('The persona pack cannot be inside the output directory (it would be deleted on rebuild).');
    }

    // Guard before overwriting: only an empty directory or a previous disc may be replaced.
    if (common.exists(outPath)) {
        const looksLikeDisc = common.isFile(path.join(outPath, '.discpersona', 'manifest.json'));
        let isEmpty = false;
        if (common.isDirectory(outPath)) {
            try {
                isEmpty = fs.readdirSync(outPath).length === 0;
            } catch (error) {
                isEmpty = false;
            }
        }
        if (!looksLikeDisc && !isEmpty && !force) {
            fail([
                'The output directory already contains something else and does not look like a DiscPersona disc: ' + outPath,
                'Nothing was changed, so your files are safe.',
                'Use an empty directory (--out), or add --force to confirm overwriting.'
            ]);
        }
        if (!looksLikeDisc && !isEmpty && force) {
            warnings.push('The output directory is not a DiscPersona disc, but --force was given; its contents will be replaced: ' + outPath);
            out.warn(warnings[warnings.length - 1]);
        }
    }

    const tmpPath = outPath + '.tmp';
    if (common.exists(tmpPath)) {
        warnings.push('Found a leftover temp directory from a previous run; cleaned up: ' + tmpPath);
        out.warn(warnings[warnings.length - 1]);
        common.removeTree(tmpPath);
    }

    // ------------------------------------------------------------------
    // [1/7] Persona pack
    // ------------------------------------------------------------------
    out.step('[1/7] Checking the persona pack');
    const metaPath = path.join(personaPath, 'meta.json');
    const ymlPath = path.join(personaPath, 'persona.yml');
    const problems = [];

    let meta = null;
    if (!common.isFile(metaPath)) {
        problems.push('meta.json: file is missing');
    } else {
        try {
            meta = common.readJsonFile(metaPath);
        } catch (error) {
            problems.push('meta.json: not valid JSON (' + error.message + ')');
        }
        if (meta) {
            const version = meta.version || meta.personaVersion;
            if (!version) problems.push('meta.json: version / personaVersion is missing (or empty)');
            if (!meta.name) problems.push('meta.json: name is missing (or empty)');
            if (!meta.discID) {
                notes.push('meta.json has no discID; one will be derived from pad.bin and written into the output copy (source untouched).');
                out.note(notes[notes.length - 1]);
            }
        }
    }

    if (!common.isFile(ymlPath)) {
        problems.push('persona.yml: file is missing');
    } else {
        const ymlText = common.readTextFile(ymlPath);
        if (!/(?:^|\n)\s*system_prompt\s*:/.test(ymlText)) {
            problems.push('persona.yml: system_prompt: is missing');
        }
    }
    if (problems.length > 0) fail(problems);

    if (!meta.version && meta.personaVersion) {
        notes.push('meta.json has no version; using personaVersion');
        out.note(notes[notes.length - 1]);
    }
    let personaName = String(meta.name).trim();
    let personaVersion = String(meta.version || meta.personaVersion).trim();
    out.ok('Persona pack is valid (name=' + personaName + ', version=' + personaVersion + ')');

    for (const optional of ['AGENTS.md', 'card.json', 'avatar.png', 'avatar.ico', 'lorebook.json', 'seed']) {
        if (!common.exists(path.join(personaPath, optional))) {
            notes.push('persona pack has no ' + optional + ' (optional; not an error)');
            out.note(notes[notes.length - 1]);
        }
    }

    // ------------------------------------------------------------------
    // [2/7] pad.bin
    // ------------------------------------------------------------------
    out.step('[2/7] Preparing pad.bin (disc identity)');
    common.ensureDir(tmpPath);
    const padPath = path.join(tmpPath, 'pad.bin');
    let padReused = false;
    let padStamp = '';

    if (reusePad) {
        const oldPad = path.join(outPath, 'pad.bin');
        if (common.isFile(oldPad)) {
            const oldBytes = fs.readFileSync(oldPad);
            if (oldBytes.length === PAD_SIZE && testPadMagic(oldBytes)) {
                fs.writeFileSync(padPath, oldBytes);
                padReused = true;
            } else {
                warnings.push('--reuse-pad was requested, but the old pad.bin has the wrong size or magic; regenerating (discID will change).');
                out.warn(warnings[warnings.length - 1]);
            }
        } else {
            warnings.push('--reuse-pad was requested, but the output directory has no pad.bin; regenerating.');
            out.warn(warnings[warnings.length - 1]);
        }
    }
    if (!padReused) padStamp = newPadFile(padPath);
    else padStamp = common.nowIsoUtc();

    const discID = common.sha256File(padPath).slice(0, 16);
    if (padReused) out.ok('Reused the existing pad.bin, discID=' + discID);
    else out.ok('Generated 512-byte pad.bin, discID=' + discID);

    try {
        // --------------------------------------------------------------
        // [3/7] persona/
        // --------------------------------------------------------------
        out.step('[3/7] Copying persona/');
        const personaDst = path.join(tmpPath, 'persona');
        const personaStats = common.copyTree(personaPath, personaDst, { warn: recordWarning });
        out.ok('persona/ copied (' + personaStats.files + ' files)');

        const dstMetaPath = path.join(personaDst, 'meta.json');
        if (!common.isFile(dstMetaPath)) throw new Error('persona/meta.json disappeared during the copy');
        const dstMeta = common.readJsonFile(dstMetaPath);
        const metaDiscID = String(dstMeta.discID || '').trim();
        if (!metaDiscID) {
            dstMeta.discID = discID;
            common.writeJsonFile(dstMetaPath, dstMeta);
            out.ok('Added discID to the persona pack meta.json (output copy)');
        } else if (metaDiscID !== discID) {
            dstMeta.discID = discID;
            common.writeJsonFile(dstMetaPath, dstMeta);
            recordWarning('The discID in the persona pack meta.json (' + metaDiscID +
                ') does not match the one from pad.bin; overwrote the output copy.');
        } else {
            out.skip('meta.json discID already matches pad.bin');
        }

        // --------------------------------------------------------------
        // [4/7] engine/
        // --------------------------------------------------------------
        out.step('[4/7] Copying engine/');
        const engineSrc = path.join(workspaceRoot, 'engine');
        let hasEngine = false;
        if (common.isDirectory(engineSrc)) {
            const engineDst = path.join(tmpPath, 'engine');
            const engineStats = common.copyTree(engineSrc, engineDst, { warn: recordWarning });
            hasEngine = true;
            if (engineStats.files === 0) {
                recordWarning('The workspace engine/ exists but has no files (' + engineSrc +
                    '); the disc has no runnable engine and launch will fail with code E01.');
            } else {
                out.ok('engine/ copied (' + engineStats.files + ' files)');
            }
        } else {
            recordWarning('The workspace has no engine/ (' + engineSrc +
                '), so the disc will not carry an engine; this disc can only be used as a data disc.');
        }
        const engineVersion = getEngineVersion(path.join(tmpPath, 'engine'));

        // --------------------------------------------------------------
        // [5/7] start.cmd / start.sh
        // --------------------------------------------------------------
        out.step('[5/7] Copying start.cmd / start.sh');

        let hasStartCmd = false;
        const startCmdSrc = path.join(workspaceRoot, 'start.cmd');
        const startCmdDst = path.join(tmpPath, 'start.cmd');
        if (common.isFile(startCmdSrc)) {
            const bytes = fs.readFileSync(startCmdSrc);
            const isUtf16 = bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe;
            const hasBom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
            if (isUtf16) {
                recordWarning('start.cmd is UTF-16 encoded, which cmd.exe cannot run; copied as-is, so change the source file back to ANSI/UTF-8 without BOM.');
                fs.writeFileSync(startCmdDst, bytes);
            } else if (hasBom) {
                recordWarning('start.cmd has a UTF-8 BOM, which cmd.exe may treat as part of the command; copied as-is.');
                fs.writeFileSync(startCmdDst, bytes);
            } else {
                let loneLf = false;
                for (let i = 0; i < bytes.length; i += 1) {
                    if (bytes[i] === 0x0a && (i === 0 || bytes[i - 1] !== 0x0d)) {
                        loneLf = true;
                        break;
                    }
                }
                if (loneLf) {
                    let text = common.readTextFile(startCmdSrc);
                    text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\n/g, '\r\n');
                    common.writeTextFile(startCmdDst, text, 'utf8');
                    recordWarning('start.cmd contains bare LF line endings; normalized to CRLF.');
                } else {
                    fs.copyFileSync(startCmdSrc, startCmdDst);
                }
            }
            hasStartCmd = true;
            out.ok('start.cmd copied from the workspace (' + fs.statSync(startCmdDst).size + ' bytes)');
        } else {
            recordWarning('No start.cmd in the workspace (' + startCmdSrc +
                '); the disc will not have the Windows entry point.');
        }

        let hasStartSh = false;
        const startShSrc = path.join(workspaceRoot, 'start.sh');
        const startShDst = path.join(tmpPath, 'start.sh');
        if (common.isFile(startShSrc)) {
            const bytes = fs.readFileSync(startShSrc);
            const hasUtf8Bom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
            const hasUtf16Bom = bytes.length >= 2 && ((bytes[0] === 0xff && bytes[1] === 0xfe) ||
                (bytes[0] === 0xfe && bytes[1] === 0xff));
            if (hasUtf8Bom || hasUtf16Bom) {
                recordWarning('start.sh has a byte-order mark, which POSIX sh cannot run; copied as-is, so fix the source file.');
            }
            if (bytes.includes(0x0d)) {
                recordWarning('start.sh contains CR bytes; POSIX sh cannot run it reliably. Fix the source file to use LF.');
            }
            let nonAscii = false;
            for (const byte of bytes) {
                if (byte > 0x7f) {
                    nonAscii = true;
                    break;
                }
            }
            if (nonAscii) recordWarning('start.sh contains non-ASCII bytes; the spec requires ASCII only.');
            fs.writeFileSync(startShDst, bytes);
            try {
                fs.chmodSync(startShDst, 0o755);
            } catch (error) { /* best effort on odd filesystems */ }
            hasStartSh = true;
            out.ok('start.sh copied from the workspace (' + bytes.length + ' bytes, mode 0755)');
        } else {
            recordWarning('No start.sh in the workspace (' + startShSrc +
                '); the disc will not have the Linux entry point. Rebuild after start.sh exists.');
        }

        if (!hasStartSh && !hasStartCmd) {
            recordWarning('The disc has neither start.sh nor start.cmd; it cannot be launched on either OS.');
        }

        // Cross-check: the launchers reference engine files that must exist on the disc.
        if (hasStartCmd) {
            const startText = common.readTextFile(startCmdDst);
            if (/engine\\launch\.ps1/.test(startText) && !common.isFile(path.join(tmpPath, 'engine', 'launch.ps1'))) {
                recordWarning('start.cmd calls engine\\launch.ps1, but the disc does not have it; launch will fail (error code E01).');
            }
        }
        if (hasStartSh) {
            const startText = common.readTextFile(startShDst);
            if (!/engine\/launch\.js/.test(startText)) {
                recordWarning('start.sh does not reference engine/launch.js; check the launcher.');
            } else if (!common.isFile(path.join(tmpPath, 'engine', 'launch.js'))) {
                recordWarning('start.sh calls engine/launch.js, but the disc does not have it; launch will fail (error code E04).');
            }
        }

        // A disc built from this repo is meant to boot on both Windows and Linux.
        // Fail early instead of producing a disc that only works on one of them.
        const dualBootMissing = [];
        if (!hasStartSh) dualBootMissing.push('start.sh (Linux entry)');
        if (!hasStartCmd) dualBootMissing.push('start.cmd (Windows entry)');
        if (!common.isFile(path.join(tmpPath, 'engine', 'launch.js'))) dualBootMissing.push('engine/launch.js (Linux launcher)');
        if (!common.isFile(path.join(tmpPath, 'engine', 'launch.ps1'))) dualBootMissing.push('engine/launch.ps1 (Windows launcher)');
        if (dualBootMissing.length > 0) {
            throw new Error('A dual-boot disc needs both launchers; missing from this build: ' +
                dualBootMissing.join(', ') + '. Restore those files in the workspace and rebuild.');
        }
        out.ok('dual-boot entries present: start.sh + start.cmd, engine/launch.js + engine/launch.ps1');

        // --------------------------------------------------------------
        // [6/7] payload / autorun.inf / README.txt
        // --------------------------------------------------------------
        out.step('[6/7] Writing payload, autorun.inf and README.txt');

        let payloadSrc = null;
        if (preset !== 'none') {
            const candidates = [
                path.join(workspaceRoot, 'payload', preset, 'profile-web'),
                path.join(workspaceRoot, 'build', 'payload', preset, 'profile-web'),
                path.join(workspaceRoot, 'payload', 'profile-web'),
                path.join(workspaceRoot, 'build', 'payload', 'profile-web')
            ];
            for (const candidate of candidates) {
                if (common.isDirectory(candidate)) {
                    payloadSrc = candidate;
                    break;
                }
            }
        }
        let hasPayload = false;
        let payloadPresetUsed = 'none';
        if (payloadSrc) {
            const payloadDst = path.join(tmpPath, '.discpersona', 'payload', 'profile-web');
            const payloadStats = common.copyTree(payloadSrc, payloadDst, { warn: recordWarning });
            hasPayload = true;
            payloadPresetUsed = preset;
            out.ok('payload copied (' + payloadStats.files + ' files, preset ' + preset + ')');
        } else if (preset === 'none') {
            out.skip('Packaging a pure persona disc (--payload-preset none): no preinstalled plugins');
        } else {
            out.skip('No payload found for preset ' + preset +
                ': packaging a pure persona disc. Run tools/new-profile-payload.js --preset ' + preset);
        }

        // Record which plugin payload was used in meta.json (output copy).
        try {
            const metaOutPath = path.join(tmpPath, 'persona', 'meta.json');
            if (common.isFile(metaOutPath)) {
                const metaObj = common.readJsonFile(metaOutPath);
                const pluginNames = [];
                if (hasPayload) {
                    const payloadJsonPath = path.join(tmpPath, '.discpersona', 'payload', 'profile-web', 'payload.json');
                    if (common.isFile(payloadJsonPath)) {
                        try {
                            const payloadJson = common.readJsonFile(payloadJsonPath);
                            for (const item of payloadJson.plugins || []) {
                                if (item && item.name) pluginNames.push(String(item.name));
                            }
                        } catch (error) {
                            recordWarning('Cannot parse payload.json: ' + error.message);
                        }
                    }
                }
                metaObj.payload = { preset: payloadPresetUsed, plugins: pluginNames };
                common.writeJsonFile(metaOutPath, metaObj);
                out.ok('meta.json records plugin payload: ' + payloadPresetUsed +
                    ' (' + pluginNames.length + ' plugins)');
            }
        } catch (error) {
            recordWarning('Failed to write the plugin payload info into meta.json: ' + error.message);
        }

        // autorun.inf
        const avatarIco = path.join(tmpPath, 'persona', 'avatar.ico');
        const avatarPng = path.join(tmpPath, 'persona', 'avatar.png');
        let iconRel = '';
        if (common.isFile(avatarIco)) {
            iconRel = 'persona/avatar.ico';
        } else if (common.isFile(avatarPng)) {
            iconRel = 'persona/avatar.png';
            notes.push('persona pack has no avatar.ico; the icon falls back to avatar.png (some systems show no icon; converting to .ico helps)');
            out.note(notes[notes.length - 1]);
        }
        const displayName = safeName(personaName, discID);
        const label = common.limitLabel(displayName, 32);
        if (label.length < displayName.length) {
            notes.push('Display name exceeds 32 characters; autorun label truncated to: ' + label);
            out.note(notes[notes.length - 1]);
        }
        const autorunText = newAutorunText(displayName, label, iconRel);
        const autorunPath = path.join(tmpPath, 'autorun.inf');
        const ascii = /^[\x00-\x7f]*$/.test(autorunText);
        if (ascii) {
            fs.writeFileSync(autorunPath, Buffer.from(autorunText, 'ascii'));
        } else {
            fs.writeFileSync(autorunPath, Buffer.concat([
                Buffer.from([0xff, 0xfe]),
                Buffer.from(autorunText, 'utf16le')
            ]));
            notes.push('autorun.inf written as UTF-16LE with BOM: the content is not ASCII, which plain ASCII cannot hold (native Windows form).');
            out.note(notes[notes.length - 1]);
        }
        if (iconRel) out.ok('autorun.inf written (icon=' + iconRel + ')');
        else out.ok('autorun.inf written (no persona avatar; icon line omitted)');

        const builtAt = common.nowIsoUtc();
        const readmeText = newReadmeText({
            displayName: displayName,
            personaVersion: personaVersion,
            discID: discID,
            builtAt: builtAt,
            engineVersion: engineVersion,
            hasPayload: hasPayload,
            hasEngine: hasEngine
        });
        fs.writeFileSync(path.join(tmpPath, 'README.txt'), Buffer.concat([
            Buffer.from([0xef, 0xbb, 0xbf]),
            Buffer.from(readmeText, 'utf8')
        ]));
        out.ok('README.txt written (UTF-8 with BOM, CRLF, mentions both Windows and Linux homes)');

        // --------------------------------------------------------------
        // [7/7] manifest
        // ------------------------------------------------------------------
        out.step('[7/7] Hashing files and writing manifest.json');
        const allFiles = common.walkFiles(tmpPath, { warn: recordWarning });
        const entries = [];
        for (const file of allFiles) {
            if (file.rel === '.discpersona/manifest.json') continue;
            entries.push(file);
        }
        entries.sort(function (a, b) { return common.compareOrdinal(a.rel, b.rel); });
        const filesObject = {};
        for (const entry of entries) filesObject[entry.rel] = common.sha256File(entry.full);
        const manifest = {
            format: 1,
            discID: discID,
            name: personaName,
            version: personaVersion,
            builtAt: builtAt,
            engine: engineVersion,
            files: filesObject
        };
        const manifestPath = path.join(tmpPath, '.discpersona', 'manifest.json');
        common.writeJsonFile(manifestPath, manifest);
        out.ok('manifest.json written (' + entries.length + ' files, including pad.bin; ' +
            (entries.length + 1) + ' files on the disc in total)');

        // --------------------------------------------------------------
        // Commit atomically
        // --------------------------------------------------------------
        out.step('Committing to the output directory');
        let backupPath = null;
        if (common.exists(outPath)) {
            backupPath = outPath + '.old-' + crypto.randomBytes(4).toString('hex');
            fs.renameSync(outPath, backupPath);
            out.note('Existing output directory moved to: ' + backupPath);
        }
        try {
            fs.renameSync(tmpPath, outPath);
        } catch (error) {
            if (backupPath && common.exists(backupPath) && !common.exists(outPath)) {
                try {
                    fs.renameSync(backupPath, outPath);
                } catch (rollbackError) { /* keep original error */ }
                out.warn('Commit failed; rolled back to the previous output directory.');
            }
            throw error;
        }
        if (backupPath) common.removeTree(backupPath);
        out.ok('Committed atomically: ' + outPath);

        const totalFiles = common.countFiles(outPath);
        out.blank();
        out.line('------------------------------------------------------------');
        out.line('DiscPersona disc created');
        out.line('  Name        : ' + personaName);
        out.line('  Version     : ' + personaVersion);
        out.line('  discID      : ' + discID);
        out.line('  Engine      : ' + engineVersion);
        out.line('  Output      : ' + outPath);
        out.line('  Files       : ' + totalFiles + ' (including pad.bin and manifest.json)');
        out.line('  Windows home: %LOCALAPPDATA%\\DiscPersona\\personas\\' + discID);
        out.line('  Linux room  : ~/.local/share/DiscPersona/personas/' + discID);
        out.line('  pad.bin     : ' + (padReused ? 'reused' : 'newly generated'));
        out.line('------------------------------------------------------------');

        if (warnings.length > 0) {
            out.blank();
            out.line('Warnings (' + warnings.length + '; disc integrity may be affected):');
            for (const warning of warnings) out.warn(warning);
        }
        if (notes.length > 0) {
            out.blank();
            out.line('Notes (' + notes.length + '; informational):');
            for (const note of notes) out.note(note);
        }

        out.blank();
        out.line('DISC_OK discID=' + discID + ' files=' + totalFiles + ' out=' + outPath);
        process.exit(0);
    } catch (error) {
        try {
            common.removeTree(tmpPath);
        } catch (cleanupError) { /* best effort */ }
        out.blank();
        out.fail(error && error.message ? error.message : String(error));
        out.blank();
        process.exit(1);
    }
}

function recordWarning(text) {
    warnings.push(text);
    out.warn(text);
}

main();
