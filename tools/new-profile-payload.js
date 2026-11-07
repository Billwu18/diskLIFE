#!/usr/bin/env node
'use strict';

// Prepare a conversation comfort pack ("payload") for a persona disc:
// install the chosen DSH plugins into a clean temporary DSH_HOME, copy the
// generated profiles/web, strip caches, write payload.json and optionally
// verify that the payload really starts.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync, spawn } = require('child_process');
const common = require('./lib/common');

const out = common.out;
const workspaceRoot = path.resolve(__dirname, '..');
const buildDir = path.join(workspaceRoot, 'build');
const tempHome = path.join(buildDir, '_payload-home');
const verifyHome = path.join(buildDir, '_payload-verify');

const PRESETS = {
    comfort: ['dsh-soul-md', 'dsh-persona-dafeiyu'],
    token: ['dsh-context-compress', 'dsh-faster-compress', 'dsh-read-image-compress'],
    full: ['dsh-soul-md', 'dsh-persona-dafeiyu', 'dsh-context-compress', 'dsh-faster-compress', 'dsh-read-image-compress']
};

const USAGE = `
Usage:
  node tools/new-profile-payload.js [--preset <comfort|token|full|custom>] [options]

Options:
  --preset <name>     comfort (default) | token | full | custom
  --plugins <names>   npm packages for --preset custom (space/comma separated; repeatable)
  --out <dir>         Output directory; default: build/payload/<preset>/profile-web
  --force             Delete and rebuild an existing output directory
  --skip-verify       Skip the real-start verification (faster, no dsh start)
  --help              Show this help

Aliases: --Preset, --Plugins, --Out, --Force, --SkipVerify.
Last line: PAYLOAD_OK preset=<...> <MB>MB files=<n> plugins=<n> out=<path>
`.trim();

function failPayload(code, message) {
    out.blank();
    out.line('PAYLOAD_FAIL ' + code + ' ' + message);
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

function resolveDsh() {
    const explicit = process.env.DISCPERSONA_DSH;
    if (explicit) {
        try {
            fs.accessSync(explicit, fs.constants.X_OK);
            if (common.isFile(explicit)) return explicit;
        } catch (error) { /* fall through */ }
    }
    for (const name of ['dsh', 'dsh.js']) {
        const tool = which(name);
        if (tool) return tool;
    }
    return null;
}

function stripPlugins(values) {
    const result = [];
    for (const value of values || []) {
        for (const part of String(value).split(/[\s,]+/)) {
            const name = part.trim();
            if (name && result.indexOf(name) < 0) result.push(name);
        }
    }
    return result;
}

function removePath(target) {
    common.removeTree(target);
}

function allowedRoots() {
    const roots = [workspaceRoot];
    const xdg = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
    roots.push(path.join(xdg, 'DiscPersona'));
    return roots;
}

function isAllowedOut(outPath) {
    for (const root of allowedRoots()) {
        if (common.isStrictSubPath(root, outPath)) return true;
    }
    return false;
}

function pruneJunk(outputDir) {
    const junk = [
        path.join(outputDir, '.pnpm-store'),
        path.join(outputDir, 'node_modules', '.cache'),
        path.join(outputDir, 'node_modules', '.pnpm-store')
    ];
    for (const target of junk) {
        if (common.exists(target)) {
            removePath(target);
            out.skip('stripped ' + path.relative(outputDir, target).split(path.sep).join('/'));
        }
    }
}

function dshVersion(dshExe) {
    try {
        const result = spawnSync(dshExe, ['--version'], {
            encoding: 'utf8',
            timeout: 30000,
            env: process.env
        });
        const text = ((result.stdout || '') + '\n' + (result.stderr || '')).trim();
        const match = /(\d+\.\d+\.\d+[^\s]*)/.exec(text);
        if (match) return match[1];
    } catch (error) { /* unknown below */ }
    return 'unknown';
}

function readJsonOrNull(filePath) {
    try {
        return JSON.parse(common.readTextFile(filePath));
    } catch (error) {
        return null;
    }
}

function waitForReadyUrl(child, timeoutMs) {
    return new Promise(function (resolve, reject) {
        let stdout = '';
        let stderr = '';
        let settled = false;
        let timer = null;

        function finish(error, url) {
            if (settled) return;
            settled = true;
            if (timer) clearTimeout(timer);
            if (error) reject({ error: error, stdout: stdout, stderr: stderr });
            else resolve({ url: url, stdout: stdout, stderr: stderr });
        }

        function scan() {
            const match = /http:\/\/127\.0\.0\.1:\d+\/\?token=[^\s"'<>]+/.exec(stdout);
            if (match) finish(null, match[0]);
        }

        child.stdout.setEncoding('utf8');
        child.stderr.setEncoding('utf8');
        child.stdout.on('data', function (chunk) {
            stdout += chunk;
            scan();
        });
        child.stderr.on('data', function (chunk) {
            stderr += chunk;
        });
        child.on('error', function (error) {
            finish('cannot start dsh: ' + error.message);
        });
        child.on('exit', function (code) {
            setTimeout(function () {
                finish('dsh exited before printing a ready URL (exit code ' + code + ')');
            }, 200);
        });
        timer = setTimeout(function () {
            finish('no ready URL within ' + Math.round(timeoutMs / 1000) + ' s');
        }, timeoutMs);
    });
}

function killChild(child) {
    if (!child || child.exitCode !== null) return;
    try {
        process.kill(-child.pid, 'SIGKILL');
    } catch (error) {
        try {
            child.kill('SIGKILL');
        } catch (killError) { /* ignore */ }
    }
}

function tail(text, lines) {
    const parts = String(text || '').trim().split(/\r?\n/).filter(Boolean);
    return parts.slice(-lines).join(' / ');
}

async function main() {
    const parsed = common.parseArgs(process.argv.slice(2), {
        values: ['preset', 'out', 'plugins'],
        flags: ['force', 'skipVerify'],
        multi: ['plugins'],
        aliases: {
            Preset: 'preset',
            Out: 'out',
            Plugins: 'plugins',
            Force: 'force',
            SkipVerify: 'skipVerify'
        }
    });
    if (parsed.errors.length > 0 || parsed.positionals.length > 0) {
        common.failUsage('new-profile-payload.js', USAGE, parsed.errors.concat(
            parsed.positionals.map(function (value) { return 'unexpected argument: ' + value; })));
        return;
    }
    if (parsed.opts.help) {
        out.line(USAGE);
        return;
    }

    const preset = parsed.opts.preset || 'comfort';
    if (!PRESETS[preset] && preset !== 'custom') {
        failPayload('PL00', 'Unknown preset: ' + preset + ' (expected comfort|token|full|custom)');
    }
    let plugins;
    if (preset === 'custom') {
        plugins = stripPlugins(parsed.opts.plugins);
        if (plugins.length === 0) {
            failPayload('PL00', '--preset custom needs --plugins (one or more npm package names).');
        }
    } else {
        plugins = PRESETS[preset].slice();
    }

    let outPath;
    if (parsed.opts.out) {
        outPath = path.resolve(process.cwd(), parsed.opts.out);
    } else {
        outPath = path.join(buildDir, 'payload', preset, 'profile-web');
    }
    if (outPath !== path.parse(outPath).root) outPath = outPath.replace(/[\\/]+$/, '');

    // PL00: the output directory is wiped wholesale, so it must live under the
    // workspace or $XDG_DATA_HOME/DiscPersona (mirrors the PowerShell PL00).
    if (!isAllowedOut(outPath)) {
        failPayload('PL00', 'The output directory must live under the workspace or $XDG_DATA_HOME/DiscPersona: ' + outPath);
    }

    out.line('==> Output: ' + outPath);
    if (common.exists(outPath)) {
        if (!parsed.opts.force) {
            failPayload('PL01', 'Output directory already exists: ' + outPath + ' (use --force to overwrite)');
        }
        const looksPayload = common.isFile(path.join(outPath, 'payload.json')) ||
            common.isDirectory(path.join(outPath, 'profiles', 'web'));
        if (!looksPayload) {
            out.warn('this directory has no payload.json / profiles/web, so it does not look like a plugin payload; overwriting anyway because --force was given.');
        }
        removePath(outPath);
    }

    const dshExe = resolveDsh();
    if (!dshExe) failPayload('PL02', 'Cannot find the dsh command, so plugins cannot be installed.');
    out.ok('dsh: ' + dshExe);

    const version = dshVersion(dshExe);
    out.ok('dsh version: ' + version);

    // ------------------------------------------------------------------
    // 1. Install plugins into a temporary home
    // ------------------------------------------------------------------
    out.line('==> Installing plugins into a temporary home: ' + plugins.join(', '));
    removePath(tempHome);
    common.ensureDir(tempHome);

    const env = Object.assign({}, process.env, { DSH_HOME: tempHome });
    const install = spawnSync(dshExe, ['plugin', '--profile', 'web', 'add'].concat(plugins), {
        encoding: 'utf8',
        timeout: 15 * 60 * 1000,
        maxBuffer: 64 * 1024 * 1024,
        cwd: workspaceRoot,
        env: env
    });
    const installText = ((install.stdout || '') + (install.stderr || '')).trim();
    if (installText) out.line(installText);
    if (install.error) {
        failPayload('PL03', 'Plugin install failed: ' + install.error.message);
    }
    if (install.status !== 0) {
        const lastLines = tail(installText, 3);
        failPayload('PL03', 'Plugin install failed (exit ' + install.status + '): ' + lastLines);
    }

    const profileSrc = path.join(tempHome, 'profiles', 'web');
    if (!common.isFile(path.join(profileSrc, 'package.json'))) {
        failPayload('PL04', 'profiles/web/package.json was not created after install.');
    }

    const pkg = readJsonOrNull(path.join(profileSrc, 'package.json')) || {};
    const bundleConfig = pkg.dsh && pkg.dsh.profile && pkg.dsh.profile.bundles;
    const bundles = Array.isArray(bundleConfig) ? bundleConfig.slice() : (bundleConfig ? [bundleConfig] : []);
    out.ok('bundles: ' + bundles.join(', '));

    const pluginInfo = [];
    for (const name of plugins) {
        const dependencyRange = pkg.dependencies && pkg.dependencies[name] ? pkg.dependencies[name] : null;
        let installedVersion = null;
        const pluginPackage = path.join(profileSrc, 'node_modules', name.replace(/\//g, path.sep), 'package.json');
        if (common.isFile(pluginPackage)) {
            const pluginPkg = readJsonOrNull(pluginPackage);
            if (pluginPkg && pluginPkg.version) installedVersion = pluginPkg.version;
        }
        pluginInfo.push({ name: name, range: dependencyRange, version: installedVersion });
    }

    // ------------------------------------------------------------------
    // 2. Copy the profile into the output and strip local caches
    // ------------------------------------------------------------------
    out.line('==> Copying the profile to ' + outPath);
    common.copyTree(profileSrc, outPath, {
        dereferenceSymlinks: true,
        warn: function (text) { out.warn(text); }
    });
    common.ensureDir(outPath);
    pruneJunk(outPath);

    const stats = common.treeSize(outPath);
    out.ok('payload files: ' + stats.files + ', size: ' + (Math.round((stats.bytes / (1024 * 1024)) * 100) / 100) + ' MB');

    // ------------------------------------------------------------------
    // 3. payload.json
    // ------------------------------------------------------------------
    const manifest = {
        format: 1,
        kind: 'discpersona/profile-payload',
        preset: preset,
        builtAt: common.nowIsoLocal(),
        dshVersion: version,
        plugins: pluginInfo,
        bundles: bundles,
        fileCount: stats.files,
        bytes: stats.bytes,
        note: 'Generated by tools/new-profile-payload.js; the launcher copies it into profiles/web under the persona home.'
    };
    const manifestPath = path.join(outPath, 'payload.json');
    common.writeJsonFile(manifestPath, manifest);
    out.ok('payload.json: ' + manifestPath);

    // ------------------------------------------------------------------
    // 4. Real-start verification
    // ------------------------------------------------------------------
    if (!parsed.opts.skipVerify) {
        out.line('==> Verify: start dsh once with the payload as its profile');
        removePath(verifyHome);
        common.ensureDir(path.join(verifyHome, 'profiles'));
        common.copyTree(outPath, path.join(verifyHome, 'profiles', 'web'), {
            dereferenceSymlinks: true,
            warn: function (text) { out.warn(text); }
        });
        common.ensureDir(buildDir);
        const stdoutLog = path.join(buildDir, '_payload-verify.out.log');
        const stderrLog = path.join(buildDir, '_payload-verify.err.log');
        for (const logPath of [stdoutLog, stderrLog]) {
            try {
                fs.unlinkSync(logPath);
            } catch (error) { /* ignore */ }
        }
        const verifyEnv = Object.assign({}, process.env, { DSH_HOME: verifyHome });
        const child = spawn(dshExe, ['--profile', 'web', '--port', '0', '--no-open'], {
            cwd: workspaceRoot,
            env: verifyEnv,
            stdio: ['ignore', 'pipe', 'pipe'],
            detached: true
        });
        let verifyFailure = null;
        try {
            const result = await waitForReadyUrl(child, 90000);
            out.ok('payload started: ' + result.url);
        } catch (error) {
            verifyFailure = error;
            const detail = tail(error.stderr, 8) + (error.stderr && error.stdout ? ' | ' : '') + tail(error.stdout, 8);
            try {
                fs.writeFileSync(stdoutLog, error.stdout || '');
                fs.writeFileSync(stderrLog, error.stderr || '');
            } catch (writeError) { /* ignore */ }
        } finally {
            killChild(child);
            removePath(verifyHome);
        }
        if (verifyFailure) {
            const detail = tail(verifyFailure.stderr, 8) +
                (verifyFailure.stderr && verifyFailure.stdout ? ' | ' : '') +
                tail(verifyFailure.stdout, 8);
            failPayload('PL05', 'payload did not start (' + verifyFailure.error + '): ' + (detail || '(no output)'));
        }
    }

    out.blank();
    out.line('PAYLOAD_OK preset=' + preset + ' ' + (Math.round((stats.bytes / (1024 * 1024)) * 100) / 100) +
        'MB files=' + stats.files + ' plugins=' + plugins.length + ' out=' + outPath);
    out.line('Next: pack with tools/new-disc.js --payload-preset ' + preset +
        ', which picks up this directory automatically.');
}

main().catch(function (error) {
    out.blank();
    out.line('PAYLOAD_FAIL PL05 ' + (error && error.message ? error.message : String(error)));
    process.exit(1);
});
