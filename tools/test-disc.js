#!/usr/bin/env node
'use strict';

// Static check of a disc tree produced by tools/new-disc.js.
// Does not start DSH and does not use the network.

const fs = require('fs');
const path = require('path');
const common = require('./lib/common');

const out = common.out;

const USAGE = `
Usage:
  node tools/test-disc.js --disc <dir>

Options:
  --disc <dir>   Root of the disc tree (alias: --disc-root)
  --help         Show this help

Last line: PASS (exit 0) or FAIL (exit 1).
`.trim();

let passCount = 0;
let failCount = 0;
const failures = [];

function addCheck(label, pass, detail) {
    if (pass) {
        passCount += 1;
        out.ok(label);
    } else {
        failCount += 1;
        failures.push(detail ? label + ' - ' + detail : label);
        out.fail(label);
        if (detail) out.line('      ' + detail);
    }
}

function addNote(text) {
    out.note(text);
}

function crlfProblem(text) {
    if (/[^\r]\n/.test(text)) return 'found a bare LF line ending (expected CRLF)';
    if (/\r(?!\n)/.test(text)) return 'found a bare CR line ending (expected CRLF)';
    if (!/\r\n/.test(text)) return 'the whole file has no CRLF line endings';
    return '';
}

function main() {
    const parsed = common.parseArgs(process.argv.slice(2), {
        values: ['disc'],
        flags: [],
        aliases: { Disc: 'disc', DiscRoot: 'disc' }
    });
    if (parsed.errors.length > 0 || parsed.positionals.length > 0) {
        common.failUsage('test-disc.js', USAGE, parsed.errors.concat(
            parsed.positionals.map(function (value) { return 'unexpected argument: ' + value; })));
        return;
    }
    if (parsed.opts.help) {
        out.line(USAGE);
        return;
    }
    if (!parsed.opts.disc) {
        common.failUsage('test-disc.js', USAGE, ['--disc is required']);
        return;
    }

    let discPath = path.resolve(process.cwd(), parsed.opts.disc);
    if (discPath !== path.parse(discPath).root) discPath = discPath.replace(/[\\/]+$/, '');

    out.blank();
    out.line('DiscPersona disc static check');
    out.line('  Directory: ' + discPath);
    if (!common.isDirectory(discPath)) {
        out.blank();
        out.fail('Directory missing or not a directory: ' + discPath);
        out.blank();
        out.line('FAIL');
        process.exit(1);
    }
    runChecks(discPath);
}

function runChecks(discPath) {
    // ------------------------------------------------------------------
    // 1. Required files
    // ------------------------------------------------------------------
    out.section('[required files]');
    const requiredFiles = [
        'autorun.inf',
        'start.sh',
        'README.txt',
        'pad.bin',
        '.discpersona/manifest.json',
        'persona/meta.json',
        'persona/persona.yml'
    ];
    for (const rel of requiredFiles) {
        addCheck('exists: ' + rel, common.isFile(path.join(discPath, rel)), 'file missing');
    }
    addCheck('at least one of start.sh / start.cmd exists',
        common.isFile(path.join(discPath, 'start.sh')) || common.isFile(path.join(discPath, 'start.cmd')),
        'the disc has no launcher entry point');

    // ------------------------------------------------------------------
    // 2. manifest.json
    // ------------------------------------------------------------------
    out.section('[manifest.json]');
    const manifestPath = path.join(discPath, '.discpersona', 'manifest.json');
    let manifest = null;
    let manifestUsable = false;

    if (common.isFile(manifestPath)) {
        const bytes = fs.readFileSync(manifestPath);
        const hasBom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
        addCheck('manifest.json is UTF-8 without BOM', !hasBom, 'found a UTF-8 BOM (the spec requires none)');

        const text = common.readTextFile(manifestPath);

        let indentProblem = '';
        for (const line of text.split(/\r?\n/)) {
            if (line.trim().length === 0) continue;
            if (/^\s*"[^"\r\n]*":\s{2}/.test(line)) {
                indentProblem = 'more than one space after a colon: ' + line.trim();
                break;
            }
            let lead = 0;
            while (lead < line.length && line[lead] === ' ') lead += 1;
            if (lead % 2 !== 0) {
                indentProblem = 'indent is not a multiple of 2: ' + line.trim();
                break;
            }
        }
        addCheck('manifest.json uses 2-space indent and one space after the colon',
            indentProblem === '', indentProblem);

        try {
            manifest = JSON.parse(text);
            manifestUsable = true;
            addCheck('manifest.json parses as JSON', true);
        } catch (error) {
            addCheck('manifest.json parses as JSON', false, error.message);
        }

        if (manifestUsable) {
            addCheck('manifest.format = 1', manifest.format === 1, 'actual: ' + manifest.format);

            const missingFields = [];
            for (const field of ['discID', 'name', 'version', 'builtAt', 'engine']) {
                const value = manifest[field];
                if (value === undefined || value === null || String(value).trim() === '') {
                    missingFields.push(field);
                }
            }
            addCheck('manifest has all required fields (discID/name/version/builtAt/engine)',
                missingFields.length === 0, 'missing: ' + missingFields.join(', '));

            const discIdText = String(manifest.discID || '');
            addCheck('manifest.discID is 16 lowercase hex chars',
                /^[0-9a-f]{16}$/.test(discIdText), 'actual: ' + discIdText);

            const files = manifest.files;
            const fileKeys = files && typeof files === 'object' && !Array.isArray(files)
                ? Object.keys(files) : [];
            addCheck('manifest.files is a non-empty object', fileKeys.length > 0,
                'files missing or empty (should at least contain the persona files)');
            addCheck('manifest.files contains pad.bin (editing pad.bin must fail this check)',
                fileKeys.indexOf('pad.bin') >= 0, 'files has no pad.bin');
        }
    } else {
        addCheck('manifest.json exists so later checks can run', false, 'file missing, skipping the manifest checks');
    }

    // ------------------------------------------------------------------
    // 3. pad.bin / discID
    // ------------------------------------------------------------------
    out.section('[pad.bin and discID]');
    const padPath = path.join(discPath, 'pad.bin');
    let discIDFromPad = null;

    if (common.isFile(padPath)) {
        const padBytes = fs.readFileSync(padPath);
        addCheck('pad.bin is exactly 512 bytes', padBytes.length === 512, 'actual: ' + padBytes.length + ' bytes');

        if (padBytes.length >= 18) {
            const magic = padBytes.subarray(0, 18).toString('ascii');
            addCheck('pad.bin magic is DISCPERSONA-PAD-V1', magic === 'DISCPERSONA-PAD-V1',
                "actual: '" + magic + "'");
        } else {
            addCheck('pad.bin magic is DISCPERSONA-PAD-V1', false, 'file too short to read the magic');
        }

        if (padBytes.length >= 96) {
            const stamp = padBytes.subarray(64, 96).toString('ascii').replace(/[\u0000 ]+$/g, '');
            addCheck('pad.bin has an ISO8601(UTC) build time',
                /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(stamp), "read: '" + stamp + "'");
        } else {
            addCheck('pad.bin has an ISO8601(UTC) build time', false, 'file too short to read the timestamp');
        }

        discIDFromPad = common.sha256File(padPath).slice(0, 16);
        addNote('discID computed from pad.bin: ' + discIDFromPad);

        if (manifestUsable) {
            addCheck('manifest.discID matches pad.bin', String(manifest.discID) === discIDFromPad,
                'manifest=' + manifest.discID + '  pad.bin=' + discIDFromPad);
        } else {
            addCheck('manifest.discID matches pad.bin', false, 'manifest unusable, cannot compare');
        }
    } else {
        addCheck('pad.bin exists so later checks can run', false, 'file missing');
    }

    // ------------------------------------------------------------------
    // 4. persona-side consistency
    // ------------------------------------------------------------------
    out.section('[persona]');
    const metaPath = path.join(discPath, 'persona', 'meta.json');
    if (common.isFile(metaPath)) {
        let meta = null;
        try {
            meta = common.readJsonFile(metaPath);
            addCheck('persona/meta.json parses as JSON', true);
        } catch (error) {
            addCheck('persona/meta.json parses as JSON', false, error.message);
        }
        if (meta) {
            const metaMissing = [];
            if (!meta.name || String(meta.name).trim() === '') metaMissing.push('name');
            const metaVersion = meta.version || meta.personaVersion;
            if (!metaVersion || String(metaVersion).trim() === '') metaMissing.push('version/personaVersion');
            addCheck('persona/meta.json has name / version', metaMissing.length === 0,
                'missing: ' + metaMissing.join(', '));

            if (manifestUsable) {
                addCheck('persona/meta.json discID matches the manifest',
                    String(meta.discID || '') === String(manifest.discID || ''),
                    'meta=' + (meta.discID || '') + '  manifest=' + (manifest.discID || ''));
            }
        }
    }

    const ymlPath = path.join(discPath, 'persona', 'persona.yml');
    if (common.isFile(ymlPath)) {
        const yml = common.readTextFile(ymlPath);
        addCheck('persona/persona.yml contains system_prompt:',
            /(?:^|\n)\s*system_prompt\s*:/.test(yml), 'system_prompt: key not found');
    } else {
        addCheck('persona/persona.yml contains system_prompt:', false, 'file missing');
    }

    // ------------------------------------------------------------------
    // 5. Hashes and extra files
    // ------------------------------------------------------------------
    out.section('[file integrity]');
    if (manifestUsable && manifest.files && typeof manifest.files === 'object') {
        const entries = Object.keys(manifest.files);
        const bad = [];
        const missing = [];
        for (const key of entries) {
            const rel = String(key).replace(/\\/g, '/');
            const full = path.resolve(discPath, rel);
            if (!common.isSubPath(discPath, full) || full === discPath) {
                bad.push(rel + ' (illegal path, skipped)');
                continue;
            }
            if (!common.isFile(full)) {
                missing.push(rel);
                continue;
            }
            const actual = common.sha256File(full);
            const expected = String(manifest.files[key]).toLowerCase();
            if (actual !== expected) bad.push(rel + ' (expected ' + expected + ', actual ' + actual + ')');
        }
        const details = [];
        if (missing.length > 0) details.push('missing: ' + missing.join('; '));
        if (bad.length > 0) details.push('hash mismatch: ' + bad.join('; '));
        addCheck('SHA-256 of all ' + entries.length + ' files in the manifest match the disc',
            missing.length === 0 && bad.length === 0, details.join(' / '));

        // Reverse direction: is there anything on the disc that the manifest does not list?
        const allowed = new Set();
        for (const key of entries) allowed.add(String(key).replace(/\\/g, '/'));
        allowed.add('pad.bin');
        allowed.add('.discpersona/manifest.json');

        const extra = [];
        const discFiles = common.walkFiles(discPath);
        for (const file of discFiles) {
            if (!allowed.has(file.rel)) extra.push(file.rel);
        }
        addCheck('no extra files beyond the manifest', extra.length === 0,
            extra.length > 0
                ? 'extra: ' + extra.join('; ') +
                    ' (system files such as Thumbs.db / desktop.ini also count as extra; delete them before checking)'
                : '');
    } else {
        addCheck('file hashes can be checked', false, 'manifest unusable or has no files');
    }

    // ------------------------------------------------------------------
    // 6. start.sh
    // ------------------------------------------------------------------
    out.section('[start.sh]');
    const startShPath = path.join(discPath, 'start.sh');
    if (common.isFile(startShPath)) {
        const bytes = fs.readFileSync(startShPath);
        addCheck('start.sh is not empty', bytes.length > 0, 'file is 0 bytes');

        const hasUtf8Bom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
        const hasUtf16Bom = bytes.length >= 2 && ((bytes[0] === 0xff && bytes[1] === 0xfe) ||
            (bytes[0] === 0xfe && bytes[1] === 0xff));
        let hasNul = false;
        let hasCr = false;
        let hasNonAscii = false;
        for (const byte of bytes) {
            if (byte === 0) hasNul = true;
            if (byte === 0x0d) hasCr = true;
            if (byte > 0x7f) hasNonAscii = true;
        }
        addCheck('start.sh has no BOM and is not UTF-16',
            !hasUtf8Bom && !hasUtf16Bom && !hasNul,
            hasUtf16Bom ? 'UTF-16 encoded; POSIX sh cannot run it' :
                (hasNul ? 'contains NUL bytes (UTF-16 without a BOM?)' : 'a UTF-8 BOM breaks the #! line'));
        addCheck('start.sh uses LF-only line endings (no CR bytes)', !hasCr,
            'contains CR bytes; convert the file to LF');
        addCheck('start.sh is ASCII-only', !hasNonAscii, 'contains non-ASCII bytes (the spec requires ASCII only)');

        const text = common.readTextFile(startShPath);
        const firstLine = text.split(/\r?\n/)[0] || '';
        addCheck('start.sh has the #!/bin/sh shebang', /^#!\/bin\/sh\b/.test(firstLine),
            "first line: '" + firstLine + "'");
        addCheck('start.sh references engine/launch.js', /engine\/launch\.js/.test(text),
            'does not call engine/launch.js');

        try {
            const mode = fs.statSync(startShPath).mode & 0o777;
            if ((mode & 0o111) === 0) addNote('start.sh is not executable (mode ' + mode.toString(8) +
                '); copied discs usually lose the exec bit anyway - run it with: sh start.sh');
        } catch (error) { /* ignore */ }
    } else {
        addCheck('start.sh exists so later checks can run', false, 'file missing');
    }

    // ------------------------------------------------------------------
    // 7. start.cmd (optional; validated only when present)
    // ------------------------------------------------------------------
    out.section('[start.cmd (optional)]');
    const startPath = path.join(discPath, 'start.cmd');
    if (common.isFile(startPath)) {
        const bytes = fs.readFileSync(startPath);
        addCheck('start.cmd is not empty', bytes.length > 0, 'file is 0 bytes');
        const bom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
        const utf16 = bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe;
        addCheck('start.cmd has no BOM (cmd.exe needs it that way)', !bom && !utf16,
            utf16 ? 'UTF-16 encoded; cmd.exe cannot run it' :
                'a UTF-8 BOM may be treated as a command by cmd.exe');

        const text = common.readTextFile(startPath);
        const problem = crlfProblem(text);
        addCheck('start.cmd uses CRLF line endings', problem === '', problem);
        if (/placeholder start\.cmd/.test(text)) {
            addNote('start.cmd is a placeholder (the workspace had no start.cmd when packing) - this disc cannot start on Windows yet.');
        }
    } else {
        addNote('no start.cmd on the disc (Windows entry point absent; start.sh is the Linux entry).');
    }

    // ------------------------------------------------------------------
    // 8. engine (optional)
    // ------------------------------------------------------------------
    out.section('[engine (optional)]');
    const engineDir = path.join(discPath, 'engine');
    if (common.isDirectory(engineDir)) {
        const engineFiles = common.walkFiles(engineDir);
        if (engineFiles.length === 0) {
            addNote('engine/ exists but is empty - no engine on the disc; starting will fail with code E01.');
        } else {
            addCheck('engine/ has ' + engineFiles.length + ' files', true);
            const hasLaunchJs = common.isFile(path.join(engineDir, 'launch.js'));
            const hasLaunchPs1 = common.isFile(path.join(engineDir, 'launch.ps1'));
            if (hasLaunchJs) addNote('engine/launch.js present (Linux launcher)');
            if (hasLaunchPs1) addNote('engine/launch.ps1 present (Windows launcher)');
            if (!hasLaunchJs && !hasLaunchPs1) {
                addNote('engine/ has neither launch.js nor launch.ps1; launching will fail.');
            }
        }
    } else {
        addNote('no engine/ on the disc (the workspace had no engine when packing) - starting will fail with code E01.');
    }

    // ------------------------------------------------------------------
    // 9. autorun.inf (optional; required-file check above already covers absence)
    // ------------------------------------------------------------------
    out.section('[autorun.inf]');
    const autorunPath = path.join(discPath, 'autorun.inf');
    if (common.isFile(autorunPath)) {
        const autorunBytes = fs.readFileSync(autorunPath);
        const isUtf16 = autorunBytes.length >= 2 && autorunBytes[0] === 0xff && autorunBytes[1] === 0xfe;
        if (isUtf16) {
            addNote('encoding UTF-16LE (label/action lines may contain non-ASCII; Windows supports this natively)');
        } else {
            addNote('encoding ASCII/UTF-8');
        }

        const autorunText = common.readTextFile(autorunPath);
        addCheck('autorun.inf contains open=start.cmd',
            /(?:^|\r?\n)\s*open=start\.cmd\s*(?:\r?\n|$)/.test(autorunText),
            'missing the open=start.cmd line');
        addCheck('autorun.inf contains label=',
            /(?:^|\r?\n)\s*label=.+(?:\r?\n|$)/.test(autorunText), 'missing the label line');

        const problem = crlfProblem(autorunText);
        addCheck('autorun.inf uses CRLF line endings', problem === '', problem);

        const iconMatch = /(?:^|\r?\n)\s*icon=(.+?)\s*(?:\r?\n|$)/.exec(autorunText);
        if (iconMatch) {
            const iconRel = iconMatch[1].trim().replace(/[\\/]+/g, path.sep);
            addCheck('autorun.inf icon points at an existing file (' + iconMatch[1].trim() + ')',
                common.isFile(path.join(discPath, iconRel)),
                'the file named on the icon line does not exist');
        } else {
            addNote('no icon line (normal when the persona pack has no avatar.ico)');
        }
    } else {
        addNote('autorun.inf is missing; the required-file check above already counts this as a failure.');
    }

    // ------------------------------------------------------------------
    // 10. README.txt
    // ------------------------------------------------------------------
    out.section('[README.txt]');
    const readmePath = path.join(discPath, 'README.txt');
    if (common.isFile(readmePath)) {
        const readmeText = common.readTextFile(readmePath);
        addCheck('README.txt is not empty', readmeText.trim().length > 0, 'file contains only whitespace');
        addCheck('README.txt mentions the Windows home directory', /LOCALAPPDATA/.test(readmeText),
            'does not say where the Windows home lives');
        addCheck('README.txt mentions the Linux room directory',
            /DiscPersona\/personas\//.test(readmeText) &&
            (/XDG_DATA_HOME/.test(readmeText) || /\.local\/share\/DiscPersona/.test(readmeText)),
            'does not say where the Linux room lives');
        const problem = crlfProblem(readmeText);
        addCheck('README.txt uses CRLF line endings', problem === '', problem);
    } else {
        addCheck('README.txt exists so later checks can run', false, 'file missing');
    }

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    const total = passCount + failCount;
    out.blank();
    out.line('------------------------------------------------------------');
    out.line('  Checks: ' + total + '    Passed: ' + passCount + '    Failed: ' + failCount);
    if (manifestUsable) {
        out.line('  discID: ' + String(manifest.discID) + '    Name: ' + String(manifest.name) +
            '    Version: ' + String(manifest.version));
    }
    if (discIDFromPad) out.line('  pad.bin computes: ' + discIDFromPad);
    out.line('------------------------------------------------------------');

    if (failCount === 0) {
        out.blank();
        out.line('PASS');
        out.blank();
        process.exit(0);
    }
    out.blank();
    out.line('Failed checks:');
    for (const failure of failures) out.fail(failure);
    out.blank();
    out.line('FAIL');
    out.blank();
    process.exit(1);
}

main();
