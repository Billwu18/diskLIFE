'use strict';
// diskLIFE launch engine (Linux) - credential import
// Block-level copy only: move the three LLM entries of the source home .credentials.yaml into
// the persona home as-is, without parsing, decoding, or printing any key value.
// Any browser-session grant already in the target file is kept as-is.
// Ported from engine/lib/Credentials.ps1.

const fs = require('fs');
const path = require('path');
const os = require('os');
const {
  addLog,
  isDirectory,
  isFile,
  readTextFile,
  writeTextFile,
  normalizePath,
  xdgDataHome,
} = require('./common');

const CREDENTIAL_RECORD_IDS = [
  'deepseek-account-platform/default',
  'deepseek-account-platform/device',
];
const CREDENTIAL_REF_KEYS = ['DEEPSEEK_API_KEY'];

// Split .credentials.yaml into:
//   versionLine : the original "version: ..." line
//   records     : Map record id -> original lines of that record (including the "  <id>:" header)
//   refLines    : original lines under the refs section (shaped like "  KEY: value")
function getCredentialDocument(filePath) {
  const doc = {
    versionLine: 'version: 1',
    records: new Map(),
    refLines: [],
  };
  if (!filePath || !isFile(filePath)) {
    return doc;
  }

  const text = readTextFile(filePath).replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lines = text.split('\n');

  let mode = 'other';
  let currentId = null;
  let buffer = null;

  const flush = () => {
    if (currentId && buffer) {
      doc.records.set(currentId, buffer);
    }
  };

  for (const rawLine of lines) {
    const line = rawLine.replace(/\s+$/, '');
    if (line.length === 0) {
      continue;
    }

    if (!/^[ \t]/.test(line)) {
      // Top-level key: ends the current record
      flush();
      currentId = null;
      buffer = null;
      if (/^version\s*:/.test(line)) {
        doc.versionLine = line;
        mode = 'version';
        continue;
      }
      if (/^records\s*:/.test(line)) {
        mode = 'records';
        continue;
      }
      if (/^refs\s*:/.test(line)) {
        mode = 'refs';
        continue;
      }
      mode = 'other';
      continue;
    }

    if (mode === 'records') {
      const m = /^ {2}(\S.*?):\s*$/.exec(line);
      if (m) {
        flush();
        currentId = m[1];
        buffer = [line];
        continue;
      }
      if (currentId) {
        buffer.push(line);
      }
      continue;
    }

    if (mode === 'refs') {
      if (/^ {2}\S/.test(line)) {
        doc.refLines.push(line);
      }
      continue;
    }
  }
  flush();
  return doc;
}

function writeCredentialDocument(filePath, doc) {
  let out = 'version: 1\n';
  if (doc.records.size === 0) {
    out += 'records: {}\n';
  } else {
    out += 'records:\n';
    for (const id of doc.records.keys()) {
      for (const line of doc.records.get(id)) {
        out += line + '\n';
      }
    }
  }
  if (doc.refLines.length > 0) {
    out += 'refs:\n';
    for (const line of doc.refLines) {
      out += line + '\n';
    }
  }
  writeTextFile(filePath, out);
}

function escapeRegExp(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Tell whether a .credentials.yaml holds usable LLM credentials (checks that the keys exist, never reads values).
function credentialHasLlm(filePath) {
  if (!filePath || !isFile(filePath)) {
    return false;
  }
  const doc = getCredentialDocument(filePath);
  for (const id of CREDENTIAL_RECORD_IDS) {
    if (!doc.records.has(id)) {
      return false;
    }
  }
  for (const line of doc.refLines) {
    if (/^\s*DEEPSEEK_API_KEY\s*:/.test(line)) {
      return true;
    }
  }
  return false;
}

// Copy the LLM credentials of the source home into the persona home.
// Returns { ok, reason: 'ok'|'missing-source'|'no-llm'|'write-failed', count }.
function importLlmCredentials(sourcePath, targetPath) {
  if (!isFile(sourcePath)) {
    return { ok: false, reason: 'missing-source', count: 0 };
  }
  let src;
  try {
    src = getCredentialDocument(sourcePath);
  } catch (err) {
    return { ok: false, reason: 'missing-source', count: 0 };
  }

  const imported = [];
  for (const id of CREDENTIAL_RECORD_IDS) {
    if (src.records.has(id)) {
      imported.push(id);
    }
  }
  const srcRefLines = src.refLines.filter((line) => /^\s*DEEPSEEK_API_KEY\s*:/.test(line));
  if (imported.length < CREDENTIAL_RECORD_IDS.length || srcRefLines.length === 0) {
    return { ok: false, reason: 'no-llm', count: 0 };
  }

  try {
    const dst = getCredentialDocument(targetPath);
    for (const id of imported) {
      dst.records.set(id, src.records.get(id).slice());
    }
    // refs: replace a key with the same name, otherwise append
    const refs = [];
    const replaced = new Set();
    for (const line of dst.refLines) {
      let isTarget = false;
      for (const key of CREDENTIAL_REF_KEYS) {
        const re = new RegExp('^\\s*' + escapeRegExp(key) + '\\s*:');
        if (re.test(line)) {
          isTarget = true;
          if (!replaced.has(key)) {
            refs.push(srcRefLines[0]);
            replaced.add(key);
          }
        }
      }
      if (!isTarget) {
        refs.push(line);
      }
    }
    for (const key of CREDENTIAL_REF_KEYS) {
      if (!replaced.has(key)) {
        for (const line of srcRefLines) {
          refs.push(line);
        }
        replaced.add(key);
      }
    }
    dst.refLines = refs;

    const parent = path.dirname(targetPath);
    if (parent && parent !== '.' && !isDirectory(parent)) {
      fs.mkdirSync(parent, { recursive: true });
    }
    writeCredentialDocument(targetPath, dst);
    // dsh requires .credentials.yaml to be owner-only (0600); a default 0644 file makes
    // the credentials plugin abort startup with a required-plugin failure.
    tightenCredentialMode(targetPath);
  } catch (err) {
    return { ok: false, reason: 'write-failed', count: 0 };
  }

  return { ok: true, reason: 'ok', count: imported.length + srcRefLines.length };
}

// Make .credentials.yaml owner-only (0600). dsh refuses to start when the file is
// readable beyond its owner. Returns true when the mode is 0600 afterwards.
function tightenCredentialMode(filePath) {
  if (!isFile(filePath)) {
    return false;
  }
  try {
    const mode = fs.statSync(filePath).mode & 0o777;
    if (mode !== 0o600) {
      fs.chmodSync(filePath, 0o600);
    }
    return true;
  } catch (err) {
    addLog('Cannot tighten permissions on ' + filePath + ' (launch continues): ' + err.message, 'Warn');
    return false;
  }
}

// Self-heal a room created by an older build (or by a copy that kept 0644).
function ensureCredentialPermissions(filePath) {
  return tightenCredentialMode(filePath);
}

// Source home resolution:
//   DISCPERSONA_SOURCE_HOME > DSH_HOME > ~/.dsh > $XDG_DATA_HOME/dsh
// Returns the first candidate directory that has .credentials.yaml; null when none does.
function getSourceHome() {
  const candidates = [];
  if (process.env.DISCPERSONA_SOURCE_HOME) {
    candidates.push(process.env.DISCPERSONA_SOURCE_HOME);
  }
  if (process.env.DSH_HOME) {
    candidates.push(process.env.DSH_HOME);
  }
  if (os.homedir()) {
    candidates.push(path.join(os.homedir(), '.dsh'));
  }
  candidates.push(path.join(xdgDataHome(), 'dsh'));

  for (const candidate of candidates) {
    if (!candidate || String(candidate).trim().length === 0) {
      continue;
    }
    const full = normalizePath(candidate);
    if (!full) {
      continue;
    }
    if (isFile(path.join(full, '.credentials.yaml'))) {
      return full;
    }
  }
  return null;
}

module.exports = {
  CREDENTIAL_RECORD_IDS,
  CREDENTIAL_REF_KEYS,
  credentialHasLlm,
  ensureCredentialPermissions,
  getCredentialDocument,
  getSourceHome,
  importLlmCredentials,
  writeCredentialDocument,
};
