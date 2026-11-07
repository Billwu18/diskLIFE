'use strict';
// diskLIFE launch engine (Linux) - persona helpers
// meta.json reading, lorebook merge, version compare, dafeiyu persona-card sync,
// and the storage v2 workspace pin. Ported from engine/launch.ps1 helper functions.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const {
  addLog,
  formatUtcStampMs,
  isDirectory,
  isFile,
  readJsonFileSafe,
  readTextFile,
  writeTextFile,
} = require('./common');

// Read persona/meta.json. Field aliases mirror the PowerShell port.
function readMetaFile(filePath) {
  const result = { name: null, version: null, raw: null };
  if (!isFile(filePath)) {
    return result;
  }
  let json;
  try {
    json = JSON.parse(readTextFile(filePath));
  } catch (err) {
    return result;
  }
  result.raw = json;
  if (json && typeof json === 'object') {
    for (const name of ['name', 'personaName', 'title']) {
      if (json[name]) {
        result.name = String(json[name]);
        break;
      }
    }
    for (const name of ['version', 'personaVersion']) {
      if (json[name]) {
        result.version = String(json[name]);
        break;
      }
    }
  }
  return result;
}

// Join the entries in lorebook.json into a "lorebook" appendix.
// diskLIFE uses the --patch channel, which has no keyword retrieval, so everything is always on:
// sort by constant=true first, then insertion_order, and stop at maxChars.
function getLorebookText(filePath, maxChars) {
  const limit = Number.isFinite(Number(maxChars)) ? Number(maxChars) : 6000;
  if (!isFile(filePath)) {
    return '';
  }
  let doc;
  try {
    doc = JSON.parse(readTextFile(filePath));
  } catch (err) {
    addLog('Cannot parse lorebook.json, ignoring it: ' + err.message, 'Warn');
    return '';
  }
  if (!doc || typeof doc !== 'object') {
    return '';
  }

  let entries = [];
  if (Array.isArray(doc.entries)) {
    entries = doc.entries;
  }
  if (entries.length === 0) {
    return '';
  }

  const rows = [];
  let idx = 0;
  for (const entry of entries) {
    if (!entry || typeof entry !== 'object') {
      idx++;
      continue;
    }
    const body = entry.content == null ? '' : String(entry.content);
    if (body.trim().length === 0) {
      idx++;
      continue;
    }
    const isConst = Boolean(entry.constant);
    let order = idx;
    if (entry.insertion_order !== undefined && entry.insertion_order !== null) {
      const raw = String(entry.insertion_order);
      if (/^-?\d+$/.test(raw)) {
        order = parseInt(raw, 10);
      }
    }
    let title = entry.comment == null ? '' : String(entry.comment);
    if (title.trim().length === 0 && Array.isArray(entry.keys)) {
      title = entry.keys.join(' / ');
    }
    rows.push({ title: title, body: body.trim(), order: order, constant: isConst });
    idx++;
  }
  if (rows.length === 0) {
    return '';
  }

  rows.sort((a, b) => {
    if (a.constant !== b.constant) {
      return a.constant ? -1 : 1;
    }
    return a.order - b.order;
  });

  let out = '## Lorebook (setting, not dialogue)\n';
  out += 'These are facts about the world you live in. They always hold, but do not recite them unprompted or repeat them entry by entry.\n';
  let used = 0;
  let kept = 0;
  let skipped = 0;
  for (const row of rows) {
    const need = row.body.length + 8;
    if (used + need > limit) {
      skipped++;
      continue;
    }
    out += '\n';
    if (row.title.trim().length > 0) {
      out += '### ' + row.title.trim() + '\n';
    }
    out += row.body.replace(/\r\n/g, '\n').replace(/\r/g, '\n') + '\n';
    used += need;
    kept++;
  }
  if (kept === 0) {
    return '';
  }
  addLog(
    'Lorebook: ' + kept + ' entries merged (~' + used + ' chars), limit ' + limit + ' chars' +
    (skipped > 0 ? ', skipped ' + skipped : '')
  );
  return out;
}

// Semantic compare: returns -1 / 0 / 1; non-numeric parts compare as strings, missing parts as 0.
function compareVersionText(left, right) {
  const aText = left == null || String(left).trim().length === 0 ? '0.0.0' : String(left).trim().replace(/^v/, '');
  const bText = right == null || String(right).trim().length === 0 ? '0.0.0' : String(right).trim().replace(/^v/, '');
  const a = aText.split(/[.\-_+]/).filter((part) => part !== '');
  const b = bText.split(/[.\-_+]/).filter((part) => part !== '');
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const x = i < a.length ? a[i] : '0';
    const y = i < b.length ? b[i] : '0';
    const xIsNum = /^-?\d+$/.test(x);
    const yIsNum = /^-?\d+$/.test(y);
    if (xIsNum && yIsNum) {
      const nx = parseInt(x, 10);
      const ny = parseInt(y, 10);
      if (nx < ny) {
        return -1;
      }
      if (nx > ny) {
        return 1;
      }
    } else {
      if (x < y) {
        return -1;
      }
      if (x > y) {
        return 1;
      }
    }
  }
  return 0;
}

// Sync the room persona into a card of dsh-persona-dafeiyu and make it the selected one.
// Skipped silently when the plugin is absent. Never blocks a launch.
function syncPersonaCard(homeDir, name, text) {
  const pluginDir = path.join(homeDir, 'profiles', 'web', 'node_modules', 'dsh-persona-dafeiyu');
  if (!isDirectory(pluginDir)) {
    return false;
  }
  try {
    const storeDir = path.join(homeDir, 'storages', 'dsh-persona-dafeiyu');
    if (!isDirectory(storeDir)) {
      fs.mkdirSync(storeDir, { recursive: true });
    }
    const storeFile = path.join(storeDir, 'personas.json');

    const kept = [];
    if (isFile(storeFile)) {
      try {
        const old = JSON.parse(readTextFile(storeFile));
        if (old && Array.isArray(old.personas)) {
          for (const item of old.personas) {
            if (item && String(item.id) !== 'discpersona') {
              kept.push(item);
            }
          }
        }
      } catch (err) {
        addLog('Cannot read the existing persona library, starting fresh: ' + err.message, 'Warn');
      }
    }

    const card = {
      id: 'discpersona',
      name: name,
      source: 'imported',
      description: 'The persona on this disc, synced by the launcher on every launch',
      text: text == null ? '' : String(text),
    };
    const store = {
      version: 1,
      mode: 'global',
      current: 'discpersona',
      disabled: ['dafeiyu', 'acha'],
      personas: kept.concat([card]),
      workspaces: [],
    };

    writeTextFile(storeFile, JSON.stringify(store));
    addLog('Persona card synced: ' + name + ' (built-in Big Fatty Fish / Acha disabled)');
    return true;
  } catch (err) {
    addLog('Persona card sync failed (launch continues): ' + err.message, 'Warn');
    return false;
  }
}

function stringArray(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((item) => item != null && item !== '').map((item) => String(item));
}

// Pin the dsh default workspace inside this persona room instead of <Documents>/deepseek-harness.
// storage v2 file: arrays stay arrays (JSON.stringify, never hand serialization).
function syncWorkspace(homeDir, workspaceDir, title) {
  const file = path.join(homeDir, 'storages', 'workspace.json');
  try {
    let id = null;
    let sessions = [];
    let archived = [];
    let pinned = [];
    if (isFile(file)) {
      try {
        const old = JSON.parse(readTextFile(file));
        if (old && old.global) {
          if (old.global.defaultWorkspaceId) {
            id = String(old.global.defaultWorkspaceId);
          }
          archived = stringArray(old.global.archivedSessionIds);
          pinned = stringArray(old.global.pinnedSessionIds);
        }
        if (old && old.tables && old.tables.workspaces && typeof old.tables.workspaces === 'object') {
          for (const key of Object.keys(old.tables.workspaces)) {
            const value = old.tables.workspaces[key];
            if (value && String(value.path) === workspaceDir) {
              id = key;
              sessions = stringArray(value.sessionIds);
            }
          }
        }
      } catch (err) {
        addLog('Cannot read the existing workspace record, starting fresh: ' + err.message, 'Warn');
      }
    }
    if (!id) {
      id = crypto.randomUUID();
    }
    const now = formatUtcStampMs();

    const record = {};
    record[id] = {
      path: workspaceDir,
      title: title,
      sessionIds: sessions,
      createdAt: now,
      updatedAt: now,
    };
    const doc = {
      unit: { name: 'workspace', version: 2 },
      global: {
        initialized: true,
        defaultWorkspaceId: id,
        workspaceIds: [id],
        archivedSessionIds: archived,
        pinnedSessionIds: pinned,
      },
      tables: { workspaces: record },
    };
    writeTextFile(file, JSON.stringify(doc));
    addLog('Default workspace: ' + workspaceDir);
    return true;
  } catch (err) {
    addLog('Workspace record fix failed (launch continues): ' + err.message, 'Warn');
    return false;
  }
}

module.exports = {
  compareVersionText,
  getLorebookText,
  readMetaFile,
  syncPersonaCard,
  syncWorkspace,
};
