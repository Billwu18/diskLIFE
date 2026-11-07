#!/usr/bin/env node
'use strict';

// Pure-JavaScript ISO 9660 + Joliet image writer and verifier.
//
// Layout: 2048-byte sectors; LBA 16 Primary Volume Descriptor, LBA 17 Joliet
// Supplementary Volume Descriptor (escape sequence "%/E"), LBA 18 terminator,
// type L/M path tables, ISO directory tree, Joliet directory tree, file data.
//
// No external tools and no dependencies; used because xorriso/genisoimage/
// mkisofs are not installed everywhere.

const fs = require('fs');
const path = require('path');

const SECTOR = 2048;
const MAX_NAME = 31; // ISO 9660 identifier length including ";1"

// ---------------------------------------------------------------------------
// Date/time
// ---------------------------------------------------------------------------
function writeDate7(buffer, offset, date) {
    const d = date instanceof Date ? date : new Date();
    buffer[offset] = Math.max(0, Math.min(255, d.getFullYear() - 1900));
    buffer[offset + 1] = d.getMonth() + 1;
    buffer[offset + 2] = d.getDate();
    buffer[offset + 3] = d.getHours();
    buffer[offset + 4] = d.getMinutes();
    buffer[offset + 5] = d.getSeconds();
    buffer[offset + 6] = 0; // GMT
}

function writeDate17(buffer, offset, date) {
    const d = date instanceof Date ? date : new Date();
    const pad = function (n, width) { return String(n).padStart(width, '0'); };
    const text = String(d.getUTCFullYear()) + pad(d.getUTCMonth() + 1, 2) + pad(d.getUTCDate(), 2) +
        pad(d.getUTCHours(), 2) + pad(d.getUTCMinutes(), 2) + pad(d.getUTCSeconds(), 2) + '00';
    buffer.write(text, offset, 'ascii');
    buffer[offset + 16] = 0; // GMT offset in 15-minute intervals
}

function writeZeroDate17(buffer, offset) {
    buffer.write('0000000000000000', offset, 'ascii');
    buffer[offset + 16] = 0;
}

// ---------------------------------------------------------------------------
// Both-endian number helpers
// ---------------------------------------------------------------------------
function writeBoth16(buffer, offset, value) {
    buffer.writeUInt16LE(value & 0xffff, offset);
    buffer.writeUInt16BE(value & 0xffff, offset + 2);
}

function writeBoth32(buffer, offset, value) {
    buffer.writeUInt32LE(value >>> 0, offset);
    buffer.writeUInt32BE(value >>> 0, offset + 4);
}

function padToSector(size) {
    return Math.ceil(size / SECTOR) * SECTOR;
}

function sectorsFor(size) {
    return Math.ceil(size / SECTOR);
}

// ---------------------------------------------------------------------------
// Source tree
// ---------------------------------------------------------------------------
function compareOrdinal(a, b) {
    if (a === b) return 0;
    return a < b ? -1 : 1;
}

function makeDirNode(name, rel) {
    return {
        type: 'dir',
        name: name,
        rel: rel,
        children: [],
        isoName: '',
        jolietName: '',
        extent: 0,
        size: 0,
        isoSize: 0,
        jolietSize: 0,
        parent: null,
        parentNumber: 0
    };
}

function collectSource(sourceRoot, warn) {
    const root = makeDirNode('', '');
    fillDirectory(root, sourceRoot, warn, 0);
    return root;
}

function fillDirectory(node, fullPath, warn, depth) {
    if (depth > 64) {
        warn('Skipping a directory tree deeper than 64 levels (not in ISO): ' + fullPath);
        return;
    }
    let names;
    try {
        names = fs.readdirSync(fullPath).sort(compareOrdinal);
    } catch (error) {
        warn('Cannot read directory (not in ISO): ' + fullPath + ' (' + error.message + ')');
        return;
    }
    for (const name of names) {
        const full = path.join(fullPath, name);
        let st;
        try {
            st = fs.lstatSync(full);
        } catch (error) {
            warn('Cannot stat (not in ISO): ' + full + ' (' + error.message + ')');
            continue;
        }
        if (st.isSymbolicLink()) {
            warn('Skipping symlink (not in ISO): ' + full);
            continue;
        }
        const rel = node.rel ? node.rel + '/' + name : name;
        if (st.isDirectory()) {
            const child = makeDirNode(name, rel);
            child.parent = node;
            node.children.push(child);
            fillDirectory(child, full, warn, depth + 1);
        } else if (st.isFile()) {
            node.children.push({
                type: 'file',
                name: name,
                rel: rel,
                full: full,
                size: st.size,
                mtime: st.mtime,
                extent: 0
            });
        } else {
            warn('Skipping special file (not in ISO): ' + full);
        }
    }
}

// ---------------------------------------------------------------------------
// Name mapping (unique ISO 9660 level-2-ish names; exact names in Joliet)
// ---------------------------------------------------------------------------
function cleanIsoPart(text) {
    return text
        .toUpperCase()
        .replace(/[^A-Z0-9_]/g, '_')
        .replace(/_+/g, '_')
        .replace(/^_+|_+$/g, '');
}

function buildIsoBase(node) {
    const isDir = node.type === 'dir';
    const upper = String(node.name).toUpperCase();
    let base = upper;
    let ext = '';
    if (!isDir) {
        const dot = upper.lastIndexOf('.');
        if (dot > 0 && dot < upper.length - 1) {
            base = upper.slice(0, dot);
            ext = upper.slice(dot + 1);
        }
    }
    base = cleanIsoPart(base);
    ext = cleanIsoPart(ext).slice(0, 8);
    return { base: base, ext: ext };
}

function joinIsoName(base, ext, isDir) {
    let text = base;
    if (ext) text += '.' + ext;
    if (!isDir) text += ';1';
    return text;
}

function assignIsoName(node, used, nextId) {
    const isDir = node.type === 'dir';
    const parts = buildIsoBase(node);
    let base = parts.base;
    let ext = parts.ext;

    let maxBase = MAX_NAME - (ext ? ext.length + 1 : 0) - (isDir ? 0 : 2);
    if (maxBase < 1) {
        ext = '';
        maxBase = MAX_NAME - (isDir ? 0 : 2);
    }
    if (!base) {
        nextId.value += 1;
        base = (isDir ? 'D' : 'F') + String(nextId.value).padStart(6, '0');
        while (base.length > maxBase) base = base.slice(0, maxBase);
    } else if (base.length > maxBase) {
        base = base.slice(0, maxBase);
    }
    if (!base) base = isDir ? 'D' : 'F';

    let candidate = joinIsoName(base, ext, isDir);
    if (used.has(candidate)) {
        let n = 2;
        for (;;) {
            const suffix = '_' + n;
            const keep = Math.max(1, maxBase - suffix.length);
            const candidateBase = base.slice(0, keep) + suffix;
            const next = joinIsoName(candidateBase, ext, isDir);
            if (!used.has(next)) {
                candidate = next;
                break;
            }
            n += 1;
        }
    }
    used.add(candidate);
    return candidate;
}

function truncateUtf16(text, max) {
    if (text.length <= max) return text;
    let n = max;
    const code = text.charCodeAt(n - 1);
    if (code >= 0xd800 && code <= 0xdbff) n -= 1;
    return text.slice(0, n);
}

function assignJolietName(node, used) {
    const isDir = node.type === 'dir';
    let base = String(node.name || '');
    if (!base) base = '_';
    base = truncateUtf16(base, 64);
    const key = base.toLowerCase();
    if (!used.has(key)) {
        used.add(key);
        return base;
    }
    // Long/different names can only collide after truncation: append ~N before the extension.
    const dot = isDir ? -1 : base.lastIndexOf('.');
    const stem = dot > 0 ? base.slice(0, dot) : base;
    const ext = dot > 0 ? base.slice(dot) : '';
    let n = 2;
    for (;;) {
        const suffix = '~' + n;
        const keep = Math.max(1, 64 - suffix.length - ext.length);
        const candidate = truncateUtf16(stem, keep) + suffix + ext;
        if (!used.has(candidate.toLowerCase())) {
            used.add(candidate.toLowerCase());
            return candidate;
        }
        n += 1;
    }
}

function assignNames(node) {
    const usedIso = new Set();
    const usedJoliet = new Set();
    const nextId = { value: 0 };
    for (const child of node.children) {
        child.isoName = assignIsoName(child, usedIso, nextId);
        child.jolietName = assignJolietName(child, usedJoliet);
        if (child.type === 'dir') assignNames(child);
    }
}

function jolietBytes(text) {
    const buffer = Buffer.alloc(text.length * 2);
    for (let i = 0; i < text.length; i += 1) {
        const code = text.charCodeAt(i);
        buffer[i * 2] = (code >> 8) & 0xff;
        buffer[i * 2 + 1] = code & 0xff;
    }
    return buffer;
}

// ---------------------------------------------------------------------------
// Directory records and sizes
// ---------------------------------------------------------------------------
function recordLength(idLength) {
    let length = 33 + idLength;
    if (length % 2 !== 0) length += 1;
    return length;
}

function makeRecord(idBytes, isDir, extent, size, date) {
    const length = recordLength(idBytes.length);
    const record = Buffer.alloc(length);
    record[0] = length;
    record[1] = 0;
    writeBoth32(record, 2, extent);
    writeBoth32(record, 10, size);
    writeDate7(record, 18, date);
    record[25] = isDir ? 0x02 : 0x00;
    record[26] = 0;
    record[27] = 0;
    writeBoth16(record, 28, 1);
    record[32] = idBytes.length;
    idBytes.copy(record, 33);
    return record;
}

function directoryLayoutSize(idLengths) {
    let offset = 0;
    for (const idLength of idLengths) {
        const length = recordLength(idLength);
        if ((offset % SECTOR) + length > SECTOR) {
            offset = Math.ceil(offset / SECTOR) * SECTOR;
        }
        offset += length;
    }
    return padToSector(offset);
}

function sortedChildRecords(node, mode) {
    const items = node.children.map(function (child) {
        const isDir = child.type === 'dir';
        const idBytes = mode === 'iso'
            ? Buffer.from(child.isoName, 'ascii')
            : jolietBytes(child.jolietName);
        return { child: child, isDir: isDir, idBytes: idBytes };
    });
    items.sort(function (a, b) { return Buffer.compare(a.idBytes, b.idBytes); });
    return items;
}

function computeDirectorySizes(node) {
    const isoIds = [1, 1];
    const jolietIds = [1, 1];
    for (const item of sortedChildRecords(node, 'iso')) isoIds.push(item.idBytes.length);
    for (const item of sortedChildRecords(node, 'joliet')) jolietIds.push(item.idBytes.length);
    node.isoSize = directoryLayoutSize(isoIds);
    node.jolietSize = directoryLayoutSize(jolietIds);
    for (const child of node.children) {
        if (child.type === 'dir') computeDirectorySizes(child);
    }
}

function buildDirectory(node, mode, date) {
    const selfExtent = mode === 'iso' ? node.isoExtent : node.jolietExtent;
    const selfSize = mode === 'iso' ? node.isoSize : node.jolietSize;
    const parent = node.parent || node;
    const parentExtent = mode === 'iso' ? parent.isoExtent : parent.jolietExtent;
    const parentSize = mode === 'iso' ? parent.isoSize : parent.jolietSize;
    const selfRecord = makeRecord(Buffer.from([0]), true, selfExtent, selfSize, date);
    const parentRecord = makeRecord(Buffer.from([1]), true, parentExtent, parentSize, date);
    const chunks = [];
    let offset = 0;
    function push(record) {
        if ((offset % SECTOR) + record.length > SECTOR) {
            const pad = SECTOR - (offset % SECTOR);
            chunks.push(Buffer.alloc(pad));
            offset += pad;
        }
        chunks.push(record);
        offset += record.length;
    }
    push(selfRecord);
    push(parentRecord);
    for (const item of sortedChildRecords(node, mode)) {
        const child = item.child;
        let childExtent;
        let childSize;
        if (child.type === 'dir') {
            childExtent = mode === 'iso' ? child.isoExtent : child.jolietExtent;
            childSize = mode === 'iso' ? child.isoSize : child.jolietSize;
        } else {
            childExtent = child.extent;
            childSize = child.size;
        }
        push(makeRecord(item.idBytes, item.isDir, childExtent, childSize, date));
    }
    const padded = padToSector(offset);
    if (padded > offset) chunks.push(Buffer.alloc(padded - offset));
    return Buffer.concat(chunks);
}

// ---------------------------------------------------------------------------
// Path tables
// ---------------------------------------------------------------------------
function collectDirectoriesBfs(root) {
    const dirs = [];
    const queue = [root];
    while (queue.length > 0) {
        const dir = queue.shift();
        dir.number = dirs.length + 1;
        dirs.push(dir);
        for (const child of dir.children) {
            if (child.type === 'dir') {
                child.parentNumber = dir.number;
                queue.push(child);
            }
        }
    }
    return dirs;
}

function pathTableIdentifier(dir, mode) {
    if (dir.parent === null) return Buffer.from([0]);
    return mode === 'iso' ? Buffer.from(dir.isoName, 'ascii') : jolietBytes(dir.jolietName);
}

function pathTableSize(dirs, mode) {
    let size = 0;
    for (const dir of dirs) {
        const idLength = pathTableIdentifier(dir, mode).length;
        size += 8 + idLength + (idLength % 2);
    }
    return size;
}

function buildPathTable(dirs, mode, endian) {
    const parts = [];
    for (const dir of dirs) {
        const identifier = pathTableIdentifier(dir, mode);
        const idLength = identifier.length;
        const entryLength = 8 + idLength + (idLength % 2);
        const entry = Buffer.alloc(entryLength);
        entry[0] = idLength;
        entry[1] = 0;
        const extent = mode === 'iso' ? dir.isoExtent : dir.jolietExtent;
        if (endian === 'le') {
            entry.writeUInt32LE(extent, 2);
            entry.writeUInt16LE(dir.parentNumber || 1, 6);
        } else {
            entry.writeUInt32BE(extent, 2);
            entry.writeUInt16BE(dir.parentNumber || 1, 6);
        }
        identifier.copy(entry, 8);
        parts.push(entry);
    }
    const combined = Buffer.concat(parts);
    const padded = padToSector(combined.length);
    if (padded === combined.length) return combined;
    return Buffer.concat([combined, Buffer.alloc(padded - combined.length)]);
}

// ---------------------------------------------------------------------------
// Volume descriptors
// ---------------------------------------------------------------------------
function asciiField(buffer, offset, length, text) {
    buffer.fill(0x20, offset, offset + length);
    if (!text) return;
    const safe = String(text).replace(/[^\x20-\x7e]/g, ' ').slice(0, length);
    buffer.write(safe, offset, 'ascii');
}

function sanitizeVolumeId(label) {
    let text = String(label || '').trim();
    if (!/^[\x20-\x7E]+$/.test(text)) text = 'DISCPERSONA';
    if (!text) text = 'DISCPERSONA';
    text = text.toUpperCase();
    if (text.length > 32) text = text.slice(0, 32);
    return text;
}

function buildDescriptor(type, root, layout, volumeId, date, joliet) {
    const buffer = Buffer.alloc(SECTOR);
    buffer[0] = type;
    buffer.write('CD001', 1, 'ascii');
    buffer[6] = 1;
    buffer[7] = 0;
    asciiField(buffer, 8, 32, '');
    asciiField(buffer, 40, 32, volumeId);
    writeBoth32(buffer, 80, layout.totalSectors);
    if (joliet) {
        // Escape sequence for Joliet level 3: "%/E"
        buffer[88] = 0x25;
        buffer[89] = 0x2f;
        buffer[90] = 0x45;
    }
    writeBoth16(buffer, 120, 1);
    writeBoth16(buffer, 124, 1);
    writeBoth16(buffer, 128, SECTOR);
    const pathTable = joliet ? layout.jolietPathTable : layout.isoPathTable;
    writeBoth32(buffer, 132, pathTable.size);
    buffer.writeUInt32LE(pathTable.lpt, 140);
    buffer.writeUInt32LE(0, 144);
    buffer.writeUInt32BE(pathTable.mpt, 148);
    buffer.writeUInt32BE(0, 152);
    const rootExtent = joliet ? root.jolietExtent : root.isoExtent;
    const rootSize = joliet ? root.jolietSize : root.isoSize;
    const rootRecord = makeRecord(Buffer.from([0]), true, rootExtent, rootSize, date);
    rootRecord.copy(buffer, 156);
    asciiField(buffer, 190, 128, '');
    asciiField(buffer, 318, 128, '');
    asciiField(buffer, 446, 128, '');
    asciiField(buffer, 574, 128, 'DISKPERSONA');
    asciiField(buffer, 702, 37, '');
    asciiField(buffer, 739, 37, '');
    asciiField(buffer, 776, 37, '');
    writeDate17(buffer, 813, date);
    writeDate17(buffer, 830, date);
    writeZeroDate17(buffer, 847);
    writeZeroDate17(buffer, 864);
    buffer[881] = 1;
    return buffer;
}

function buildTerminator() {
    const buffer = Buffer.alloc(SECTOR);
    buffer[0] = 255;
    buffer.write('CD001', 1, 'ascii');
    buffer[6] = 1;
    return buffer;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------
function buildLayout(root) {
    computeDirectorySizes(root);
    const dirs = collectDirectoriesBfs(root);
    const isoSize = pathTableSize(dirs, 'iso');
    const jolietSize = pathTableSize(dirs, 'joliet');

    let lba = 19; // 16 PVD, 17 SVD, 18 terminator
    const isoPathTable = { size: isoSize, lpt: lba, mpt: 0 };
    lba += sectorsFor(isoSize);
    isoPathTable.mpt = lba;
    lba += sectorsFor(isoSize);

    const jolietPathTable = { size: jolietSize, lpt: lba, mpt: 0 };
    lba += sectorsFor(jolietSize);
    jolietPathTable.mpt = lba;
    lba += sectorsFor(jolietSize);

    for (const dir of dirs) {
        dir.isoExtent = lba;
        lba += sectorsFor(dir.isoSize);
    }
    for (const dir of dirs) {
        dir.jolietExtent = lba;
        lba += sectorsFor(dir.jolietSize);
    }

    const files = [];
    for (const dir of dirs) {
        for (const child of dir.children) {
            if (child.type === 'file') files.push(child);
        }
    }
    for (const file of files) {
        file.extent = file.size > 0 ? lba : lba;
        lba += sectorsFor(file.size);
    }

    return {
        dirs: dirs,
        files: files,
        totalSectors: Math.max(lba, 20),
        isoPathTable: isoPathTable,
        jolietPathTable: jolietPathTable
    };
}

// ---------------------------------------------------------------------------
// Image writer
// ---------------------------------------------------------------------------
function writeBufferAt(fd, buffer, position) {
    let written = 0;
    while (written < buffer.length) {
        written += fs.writeSync(fd, buffer, written, buffer.length - written, position + written);
    }
}

function copyFileAt(fd, file, position) {
    const inFd = fs.openSync(file.full, 'r');
    const chunk = Buffer.allocUnsafe(1024 * 1024);
    let offset = 0;
    try {
        for (;;) {
            const read = fs.readSync(inFd, chunk, 0, chunk.length, null);
            if (read <= 0) break;
            writeBufferAt(fd, chunk.subarray(0, read), position + offset);
            offset += read;
        }
    } finally {
        fs.closeSync(inFd);
    }
    if (offset !== file.size) {
        throw new Error('File size changed while building the ISO: ' + file.full +
            ' (expected ' + file.size + ', copied ' + offset + ')');
    }
}

function writeIso(sourceRoot, outPath, options) {
    const opts = options || {};
    const warn = typeof opts.warn === 'function' ? opts.warn : function () {};
    const date = opts.date instanceof Date ? opts.date : new Date();
    const volumeId = sanitizeVolumeId(opts.volumeLabel);

    const root = collectSource(sourceRoot, warn);
    assignNames(root);
    const layout = buildLayout(root);

    const isoLpt = buildPathTable(layout.dirs, 'iso', 'le');
    const isoMpt = buildPathTable(layout.dirs, 'iso', 'be');
    const jolietLpt = buildPathTable(layout.dirs, 'joliet', 'le');
    const jolietMpt = buildPathTable(layout.dirs, 'joliet', 'be');

    const fd = fs.openSync(outPath, 'w');
    try {
        const totalBytes = layout.totalSectors * SECTOR;
        fs.ftruncateSync(fd, totalBytes);
        const descriptorDate = date;

        writeBufferAt(fd, buildDescriptor(1, root, layout, volumeId, descriptorDate, false), 16 * SECTOR);
        writeBufferAt(fd, buildDescriptor(2, root, layout, volumeId, descriptorDate, true), 17 * SECTOR);
        writeBufferAt(fd, buildTerminator(), 18 * SECTOR);

        writeBufferAt(fd, isoLpt, layout.isoPathTable.lpt * SECTOR);
        writeBufferAt(fd, isoMpt, layout.isoPathTable.mpt * SECTOR);
        writeBufferAt(fd, jolietLpt, layout.jolietPathTable.lpt * SECTOR);
        writeBufferAt(fd, jolietMpt, layout.jolietPathTable.mpt * SECTOR);

        for (const dir of layout.dirs) {
            writeBufferAt(fd, buildDirectory(dir, 'iso', descriptorDate), dir.isoExtent * SECTOR);
        }
        for (const dir of layout.dirs) {
            writeBufferAt(fd, buildDirectory(dir, 'joliet', descriptorDate), dir.jolietExtent * SECTOR);
        }
        for (const file of layout.files) {
            if (file.size > 0) copyFileAt(fd, file, file.extent * SECTOR);
        }
    } finally {
        fs.closeSync(fd);
    }

    return {
        totalSectors: layout.totalSectors,
        totalBytes: layout.totalSectors * SECTOR,
        fileCount: layout.files.length,
        dirCount: layout.dirs.length,
        volumeLabel: volumeId
    };
}

// ---------------------------------------------------------------------------
// Image verifier
// ---------------------------------------------------------------------------
function readBoth32LE(buffer, offset) {
    return buffer.readUInt32LE(offset);
}

function parseRecord(image, offset) {
    const length = image[offset];
    return {
        length: length,
        extent: image.readUInt32LE(offset + 2),
        size: image.readUInt32LE(offset + 10),
        isDir: (image[offset + 25] & 0x02) !== 0,
        nameLength: image[offset + 32],
        name: image.subarray(offset + 33, offset + 33 + image[offset + 32])
    };
}

function descriptorRoot(image, descriptorOffset) {
    const offset = descriptorOffset + 156;
    return {
        extent: readBoth32LE(image, offset + 2),
        size: readBoth32LE(image, offset + 10)
    };
}

function decodeIsoName(bytes) {
    let text = bytes.toString('latin1');
    text = text.replace(/;1$/, '');
    return text;
}

function decodeJolietName(bytes) {
    let text = '';
    const end = bytes.length - (bytes.length % 2);
    for (let i = 0; i < end; i += 2) text += String.fromCharCode((bytes[i] << 8) | bytes[i + 1]);
    return text;
}

function walkTree(image, root, decodeName) {
    const files = [];
    const dirs = [];
    const errors = [];
    const visited = new Set();
    const stack = [{ extent: root.extent, size: root.size, prefix: '' }];

    while (stack.length > 0) {
        const directory = stack.pop();
        const key = directory.extent + ':' + directory.size;
        if (visited.has(key)) {
            errors.push('directory cycle or duplicate extent at LBA ' + directory.extent);
            continue;
        }
        visited.add(key);

        const start = directory.extent * SECTOR;
        const end = start + directory.size;
        if (start < 0 || end > image.length || end < start) {
            errors.push('directory extent out of bounds at LBA ' + directory.extent);
            continue;
        }
        let pos = start;
        while (pos < end) {
            const length = image[pos];
            if (length === 0) {
                pos = Math.ceil((pos + 1) / SECTOR) * SECTOR;
                continue;
            }
            if (length < 34 || pos + length > end) {
                errors.push('invalid directory record at offset ' + pos);
                break;
            }
            const record = parseRecord(image, pos);
            const isSelfOrParent = record.nameLength === 1 &&
                (record.name[0] === 0 || record.name[0] === 1);
            if (!isSelfOrParent) {
                const name = decodeName(record.name);
                if (!name || name === '.' || name === '..' || name.includes('/') || name.includes('\\')) {
                    errors.push('invalid file name in directory at LBA ' + directory.extent);
                } else {
                    const rel = directory.prefix ? directory.prefix + '/' + name : name;
                    if (record.isDir) {
                        dirs.push(rel);
                        stack.push({ extent: record.extent, size: record.size, prefix: rel });
                    } else {
                        files.push({ path: rel, extent: record.extent, size: record.size });
                    }
                }
            }
            pos += length;
        }
    }
    return { files: files, dirs: dirs, errors: errors };
}

function sha256OfExtent(image, record) {
    const start = record.extent * SECTOR;
    const end = start + record.size;
    if (start < 0 || end > image.length) return null;
    const crypto = require('crypto');
    return crypto.createHash('sha256').update(image.subarray(start, end)).digest('hex');
}

function verifyIso(imagePath, sourceRoot, expectedVolumeLabel) {
    const errors = [];
    const warnings = [];
    let image;
    try {
        image = fs.readFileSync(imagePath);
    } catch (error) {
        return { ok: false, errors: ['cannot read the image: ' + error.message], warnings: [] };
    }
    if (image.length < 16 * SECTOR) {
        errors.push('image is smaller than the 16 reserved sectors (' + image.length + ' bytes)');
        return { ok: false, errors: errors, warnings: warnings };
    }

    let pvd = null;
    let svd = null;
    const maxDescriptors = Math.min(Math.floor(image.length / SECTOR), 512);
    for (let lba = 16; lba < maxDescriptors; lba += 1) {
        const offset = lba * SECTOR;
        if (image.toString('ascii', offset + 1, offset + 6) !== 'CD001') continue;
        const type = image[offset];
        if (type === 1 && !pvd) pvd = offset;
        else if (type === 2 && !svd) svd = offset;
        else if (type === 255) break;
    }
    if (pvd === null) {
        errors.push('no primary volume descriptor at LBA 16');
        return { ok: false, errors: errors, warnings: warnings };
    }

    const pvdLabel = image.toString('ascii', pvd + 40, pvd + 72).replace(/[ ]+$/, '');
    if (expectedVolumeLabel) {
        const expected = sanitizeVolumeId(expectedVolumeLabel);
        if (pvdLabel !== expected) {
            errors.push('volume label mismatch: image="' + pvdLabel + '" expected="' + expected + '"');
        }
    }

    if (svd === null) {
        errors.push('no Joliet supplementary volume descriptor');
    } else if (image[svd + 88] !== 0x25 || image[svd + 89] !== 0x2f || image[svd + 90] !== 0x45) {
        errors.push('Joliet supplementary volume descriptor has no "%/E" escape sequence');
    }

    const useJoliet = svd !== null;
    const descriptorOffset = useJoliet ? svd : pvd;
    const tree = walkTree(image, descriptorRoot(image, descriptorOffset),
        useJoliet ? decodeJolietName : decodeIsoName);
    for (const error of tree.errors) errors.push(error);

    const sourceFiles = require('./common').walkFiles(sourceRoot, { warn: function (text) { warnings.push(text); } });
    const sourceMap = new Map();
    for (const file of sourceFiles) sourceMap.set(file.rel, file);

    const imageMap = new Map();
    for (const record of tree.files) {
        if (imageMap.has(record.path)) {
            errors.push('duplicate file in image: ' + record.path);
        } else {
            imageMap.set(record.path, record);
        }
    }

    const missing = [];
    for (const rel of sourceMap.keys()) {
        if (!imageMap.has(rel)) missing.push(rel);
    }
    if (missing.length > 0) {
        errors.push('missing from image: ' + missing.slice(0, 10).join(', ') +
            (missing.length > 10 ? ' ... (' + missing.length + ' total)' : ''));
    }

    const extra = [];
    for (const rel of imageMap.keys()) {
        if (!sourceMap.has(rel)) extra.push(rel);
    }
    if (extra.length > 0) {
        errors.push('extra in image: ' + extra.slice(0, 10).join(', ') +
            (extra.length > 10 ? ' ... (' + extra.length + ' total)' : ''));
    }

    let sizeMismatches = 0;
    let hashMismatches = 0;
    for (const [rel, source] of sourceMap) {
        const record = imageMap.get(rel);
        if (!record) continue;
        if (record.size !== source.size) {
            sizeMismatches += 1;
            errors.push('size mismatch: ' + rel + ' (image ' + record.size + ', source ' + source.size + ')');
            continue;
        }
        const actual = sha256OfExtent(image, record);
        if (actual === null) {
            errors.push('file extent out of bounds: ' + rel);
            continue;
        }
        const crypto = require('crypto');
        const expected = crypto.createHash('sha256').update(fs.readFileSync(source.full)).digest('hex');
        if (actual !== expected) {
            hashMismatches += 1;
            errors.push('SHA-256 mismatch: ' + rel);
        }
    }

    // Cross-check the primary ISO tree too: same file count and total bytes.
    const primaryTree = walkTree(image, descriptorRoot(image, pvd), decodeIsoName);
    for (const error of primaryTree.errors) errors.push('primary tree: ' + error);
    if (primaryTree.files.length !== sourceFiles.length) {
        errors.push('primary ISO tree has ' + primaryTree.files.length + ' files, source has ' +
            sourceFiles.length);
    }
    const primaryBytes = primaryTree.files.reduce(function (sum, file) { return sum + file.size; }, 0);
    const sourceBytes = sourceFiles.reduce(function (sum, file) { return sum + file.size; }, 0);
    if (primaryBytes !== sourceBytes) {
        errors.push('primary ISO tree holds ' + primaryBytes + ' bytes, source has ' + sourceBytes);
    }

    return {
        ok: errors.length === 0,
        errors: errors,
        warnings: warnings,
        volumeLabel: pvdLabel,
        fileCount: tree.files.length,
        dirCount: tree.dirs.length,
        joliet: useJoliet,
        sizeMismatches: sizeMismatches,
        hashMismatches: hashMismatches
    };
}

// ---------------------------------------------------------------------------
// List an image (human/debug output; used by the tools and for sanity checks)
// ---------------------------------------------------------------------------
function listIso(imagePath) {
    const image = fs.readFileSync(imagePath);
    let pvd = null;
    let svd = null;
    const maxDescriptors = Math.min(Math.floor(image.length / SECTOR), 512);
    for (let lba = 16; lba < maxDescriptors; lba += 1) {
        const offset = lba * SECTOR;
        if (image.toString('ascii', offset + 1, offset + 6) !== 'CD001') continue;
        const type = image[offset];
        if (type === 1 && !pvd) pvd = offset;
        else if (type === 2 && !svd) svd = offset;
        else if (type === 255) break;
    }
    if (pvd === null) return { ok: false, entries: [] };
    const useJoliet = svd !== null;
    const tree = walkTree(image, descriptorRoot(image, useJoliet ? svd : pvd),
        useJoliet ? decodeJolietName : decodeIsoName);
    return {
        ok: tree.errors.length === 0,
        entries: tree.files.map(function (file) {
            return { path: file.path, size: file.size };
        }).sort(function (a, b) { return compareOrdinal(a.path, b.path); }),
        errors: tree.errors
    };
}

module.exports = {
    SECTOR: SECTOR,
    sanitizeVolumeId: sanitizeVolumeId,
    writeIso: writeIso,
    verifyIso: verifyIso,
    listIso: listIso
};
