'use strict';
// diskLIFE launch engine (Linux) - disc integrity (manifest check)
// Canonical shape (produced by the packer):
//   { "format": 1, "discID": "....", "files": { "persona/persona.yml": "<sha256>" } }
// For compatibility with other packers, these are accepted too:
//   { "files": [ { "path": "...", "sha256": "..." } ] }
//   { "entries": [ ... ] } / top-level array / values written as { "sha256": "..." }
// Ported from engine/lib/Manifest.ps1.

const path = require('path');
const {
  addLog,
  isFile,
  readTextFile,
  sha256File,
  stop,
} = require('./common');

function entryHashValue(hashValue) {
  if (hashValue == null) {
    return '';
  }
  if (typeof hashValue === 'string') {
    return hashValue;
  }
  if (typeof hashValue === 'object') {
    for (const name of ['sha256', 'hash', 'digest', 'checksum']) {
      if (hashValue[name]) {
        return String(hashValue[name]);
      }
    }
  }
  return '';
}

function normalizeEntryPath(relPath) {
  if (relPath == null) {
    return null;
  }
  const rel = String(relPath).trim();
  if (rel.length === 0) {
    return null;
  }
  return rel;
}

// Normalize the manifest to [{ path, hash }].
// Returns null on a parse failure (the caller decides between a warning and an error).
function getManifestEntries(manifestPath) {
  let json;
  try {
    json = JSON.parse(readTextFile(manifestPath));
  } catch (err) {
    return null;
  }

  const entries = [];
  const addEntry = (relPath, hashValue) => {
    const rel = normalizeEntryPath(relPath);
    let hash = entryHashValue(hashValue);
    hash = String(hash).trim();
    if (!rel || hash.length === 0) {
      return;
    }
    if (/^sha256:/i.test(hash)) {
      hash = hash.slice(7);
    }
    entries.push({ path: rel, hash: hash.toLowerCase() });
  };

  const collections = [];
  if (Array.isArray(json)) {
    collections.push(json);
  } else if (json && typeof json === 'object') {
    if (json.files !== undefined) {
      collections.push(json.files);
    } else if (json.entries !== undefined) {
      collections.push(json.entries);
    } else if (json.manifest !== undefined) {
      collections.push(json.manifest);
    }
  }

  for (const collection of collections) {
    if (collection == null) {
      continue;
    }
    if (Array.isArray(collection)) {
      for (const item of collection) {
        if (item == null || typeof item === 'string') {
          continue;
        }
        let rel = null;
        let hash = null;
        for (const name of ['path', 'file', 'name', 'relativePath']) {
          if (item[name]) {
            rel = item[name];
            break;
          }
        }
        for (const name of ['sha256', 'hash', 'digest', 'checksum']) {
          if (item[name]) {
            hash = item[name];
            break;
          }
        }
        addEntry(rel, hash);
      }
    } else if (typeof collection === 'object') {
      // Mapping shape: { "rel/path": "hash" }
      for (const rel of Object.keys(collection)) {
        addEntry(rel, collection[rel]);
      }
    }
  }

  return entries;
}

// Compare SHA-256 file by file. Any mismatch/missing file -> E03 (with the relative path).
// Returns { checked: n }; not called when the manifest is absent (the caller only warns).
function assertDiscManifest(discRoot, manifestPath) {
  const entries = getManifestEntries(manifestPath);
  if (entries === null) {
    stop(
      'E03',
      'Cannot read the check manifest of this disc (.discpersona/manifest.json), so file integrity cannot be confirmed.',
      'Use another disc, or rebuild one with tools/new-disc.js.'
    );
  }
  if (entries.length === 0) {
    addLog('The check manifest has no file entries; skipping the per-file check.', 'Warn');
    return { checked: 0 };
  }

  const root = path.resolve(discRoot);
  let checked = 0;
  for (const entry of entries) {
    const rel = entry.path.replace(/\\/g, '/');

    // Reject anything that escapes the disc root: absolute paths and any ".." segment.
    const segments = rel.split('/');
    if (rel.startsWith('/') || segments.includes('..') || /^[A-Za-z]:/.test(rel)) {
      stop(
        'E03',
        'Files on this disc were modified: ' + entry.path + ' (path escapes the manifest root)',
        'Use another disc, or rebuild one with tools/new-disc.js.'
      );
    }
    const full = path.resolve(root, rel);
    if (full !== root && !full.startsWith(root + path.sep)) {
      stop(
        'E03',
        'Files on this disc were modified: ' + entry.path + ' (path escapes the manifest root)',
        'Use another disc, or rebuild one with tools/new-disc.js.'
      );
    }
    if (!isFile(full)) {
      stop(
        'E03',
        'Files on this disc were modified: ' + entry.path + ' (file is missing)',
        'Use another disc, or rebuild one with tools/new-disc.js.'
      );
    }
    let actual;
    try {
      actual = sha256File(full);
    } catch (err) {
      stop(
        'E03',
        'Files on this disc were modified: ' + entry.path + ' (cannot be read; it may be damaged)',
        'Use another disc, or rebuild one with tools/new-disc.js.'
      );
    }
    if (actual !== entry.hash) {
      stop(
        'E03',
        'Files on this disc were modified: ' + entry.path,
        'Use another disc, or rebuild one with tools/new-disc.js.'
      );
    }
    checked++;
  }
  addLog('Check manifest passed: all ' + checked + ' files match their SHA-256.');
  return { checked };
}

module.exports = {
  assertDiscManifest,
  getManifestEntries,
};
