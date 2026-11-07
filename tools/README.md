# tools/ - disc build pipeline

Five scripts; on Windows they rely only on commands that ship with Windows PowerShell 5.1 (no Node, no npm
packages). On Linux the same pipeline exists in `tools/*.js` (Node.js builtins only, no npm packages); it
builds the same disc format, so a disc made by either side works on both.

> Linux quick reference: `node tools/new-disc.js --persona <pack> --out <dir>`,
> `node tools/test-disc.js --disc <dir>`, `node tools/new-iso.js --source <dir> --out <file>.iso`,
> `node tools/burn-iso.js --iso-path <file>.iso --drive /dev/sr0`, and
> `node tools/new-profile-payload.js --preset comfort`. Full Linux manual: [../docs/linux.md](../docs/linux.md).

```
New-ProfilePayload.ps1  install plugins -> pre-pack a profile (optional, one-off)
        |
New-Disc.ps1            persona pack + engine + payload -> disc tree
        |
Test-Disc.ps1           static check (36 items)
        |
New-Iso.ps1             disc tree -> ISO (ISO9660 + Joliet)
        |
Burn-Iso.ps1            ISO -> blank CD-R
```

## Packing: `New-Disc.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-Disc.ps1 `
  -Persona persona\aris `
  -Out D:\build\aris-disc
```

- `-Persona`: Persona Pack directory (holds meta.json / persona.yml / AGENTS.md / seed\...)
- `-Out`: where the disc tree goes; an existing tree is replaced wholesale (written to `<Out>.tmp` first, then swapped in atomically)
- `-ReusePad`: reuse `<Out>\pad.bin` so a rebuild keeps the same discID

The result is the directory tree of a **data disc**, ready to be written to a CD-R as data:

```
<Out>\
  autorun.inf           label / action / icon (avatar.ico when present, otherwise avatar.png)
  start.cmd             verbatim copy of the workspace start.cmd
  README.txt            notes for humans (home location, error codes, not a boot disc)
  pad.bin               512 bytes; discID = first 16 lowercase hex chars of its SHA-256
  engine\...            copy of the workspace engine\
  persona\...           copy of the Persona Pack (meta.json discID is synced to this disc)
  .discpersona\manifest.json   file hash manifest (pad.bin included, files sorted by path)
  .discpersona\payload\        pre-installed plugin payload (when build\payload exists)
```

A failed check (meta without name/version, yml without `system_prompt:`) prints the reasons,
exits with code 1, and never leaves a half-written directory behind.

Example output:

```
DiscPersona builder
  Persona     : E:\dshdocument\disklife\tools\_selftest\fake-persona
  Out         : E:\dshdocument\disklife\build\en-check
  ReusePad    : no
  Workspace   : E:\dshdocument\disklife

[1/7] Checking the persona pack
  ✓ Persona pack is valid (name=Fake Persona, version=1.0.0)
...
[7/7] Hashing files and writing manifest.json
  ✓ manifest.json written (112 files, including pad.bin; 113 files on the disc in total)

------------------------------------------------------------
DiscPersona disc created
  Name        : Fake Persona
  Version     : 1.0.0
  discID      : cf76f969dc2c043c
  Engine      : dev
  Output      : E:\dshdocument\disklife\build\en-check
  Files       : 113 (including pad.bin and manifest.json)
  home        : %LOCALAPPDATA%\DiscPersona\personas\cf76f969dc2c043c
  pad.bin     : newly generated
------------------------------------------------------------

DISC_OK discID=cf76f969dc2c043c files=113 out=E:\dshdocument\disklife\build\en-check
```

## Static check: `Test-Disc.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File tools\Test-Disc.ps1 -Disc D:\build\aris-disc
```

Does not start DSH and does not use the network; it only reads files on the disc: required files
present, manifest shape and indentation, every hash matching the disc, no extra files beyond the
manifest, pad.bin exactly 512 bytes with the right magic, start.cmd CRLF without BOM, autorun.inf
carrying `open=start.cmd` with an icon that points at a real file. Each item prints a green check or
a red cross, and the run ends with `PASS` (exit code 0) or `FAIL` (exit code 1).

```
------------------------------------------------------------
  Checks: 36    Passed: 36    Failed: 0
  discID: cf76f969dc2c043c    Name: Fake Persona    Version: 1.0.0
  pad.bin computes: cf76f969dc2c043c
------------------------------------------------------------

PASS
```

## Self-test

`_selftest\fake-persona\` is a minimal fake persona pack; `_selftest\out-disc\` is its output;
`_selftest\out-disc-broken\` is a copy with one extra line appended to `persona/persona.yml`, used to
confirm that the check reports FAIL.

## Plugin payload: `New-ProfilePayload.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-ProfilePayload.ps1 -Force
```

- `-Plugins`: packages to install; defaults to `dsh-soul-md,dsh-persona-dafeiyu`
- `-Out`: output directory; defaults to `build\payload\profile-web`
- `-SkipVerify`: skip the "really start it once" verification (on by default; a dozen seconds slower but worth it)

Flow: create a temporary home (`build\_payload-home`) -> `dsh plugin --profile web add ...` -> copy
`profiles\web` -> delete `.cache` / `.pnpm-store` -> write `payload.json` -> start once to confirm it
comes up. The artifact is roughly 0.5-0.6 MB in 70-90 files (the exact count follows the preset).

If it fails, look at the `PAYLOAD_FAIL` line first: usually a plugin peerDependency does not match the
current dsh version.

## Building an ISO: `New-Iso.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-Iso.ps1 -Source examples\demo-aris -Out build\aris.iso
```

- `-Source`: the disc tree (output of `New-Disc.ps1`)
- `-VolumeLabel`: volume label; defaults to `meta.json.nameJp`, falling back to `DISCPERSONA` when non-ASCII
- `-Force`: overwrite an existing ISO

Uses IMAPI2 (`MsftFileSystemImage`) with `FileSystemsToCreate=3`, i.e. **ISO9660 + Joliet** - Joliet is
what keeps long non-ASCII file names from being truncated. No oscdimg / mkisofs / xorriso needed.

## Burning: `Burn-Iso.ps1`

```powershell
powershell -File tools\Burn-Iso.ps1 -ListDrives                 # see the drives and whether the media is blank
powershell -File tools\Burn-Iso.ps1 -IsoPath build\aris.iso -DriveLetter F
```

- `-TestOnly`: check the link only, no actual write (works on a disc that already has content)
- `-Eject`: eject the tray when done

The final line is always `BURN_OK <drive> <bytes> bytes <seconds>s` or `BURN_FAIL <Bxx> <reason>`:

| Code | Meaning |
| --- | --- |
| B01 | Drive not found (`-DriveLetter` names a letter that does not exist) |
| B02 | The drive cannot burn |
| B03 | No media, or the media cannot be written (read-only disc, or not a CD-R/RW) |
| B04 | The disc already has content (**protection**: never overwrites a burned disc) |
| B05 | ISO file missing or empty |
| B06 | Failed to load the file stream component / open the ISO |
| B07 | Write failed (COM-level error; usually the drive or the media) |
| B08 | Written, but the disc still looks blank (rare; usually the drive does not recognise it) |

Burning **closes** the disc (`ForceMediaToBeClosed`), so nothing can be appended afterwards - one disc,
one persona.


---

# Linux pipeline (`tools/*.js`)

Same seven-step artefact, Node.js implementation. All scripts are CommonJS with no dependencies, take
GNU-style options (`--persona`, `--out`, ...), and print the same machine-readable last line as the
PowerShell versions (`DISC_OK`, `PASS`/`FAIL`, `ISO_OK`/`ISO_FAIL`, `BURN_OK`/`BURN_FAIL`,
`PAYLOAD_OK`/`PAYLOAD_FAIL`).

```sh
# 1) build a dual-boot disc tree (Linux start.sh + Windows start.cmd/autorun.inf)
node tools/new-disc.js --persona examples/sample-persona --out build/linux-disc
node tools/new-disc.js --persona examples/sample-persona --out build/linux-disc --reuse-pad
node tools/new-disc.js --persona examples/sample-persona --out build/linux-disc --payload-preset token --force

# optional: encrypt the persona files on the disc (passphrase asked on first boot)
node tools/new-disc.js --persona examples/sample-persona --out build/locked-disc \
  --seal-persona --passphrase-stdin < passphrase.txt

# optional: passphrase-encrypted room backup / restore
node tools/backup-room.js --room ~/.local/DiscPersona/personas/<discID> \
  --out build/backups/room.dlseal --passphrase-stdin --verify < passphrase.txt
node engine/lib/seal.js unseal-tree --in build/backups/room.dlseal --out /tmp/room --passphrase-stdin < passphrase.txt

# 2) verify it (required files, manifest shape + hashes, pad.bin, start.sh, autorun when present)
node tools/test-disc.js --disc build/linux-disc

# 3) ISO 9660 + Joliet; built-in writer, no external tools, verifies the image after writing
node tools/new-iso.js --source build/linux-disc --out build/linux-disc.iso
node tools/new-iso.js --source build/linux-disc --out build/disc.iso --volume-label ARIS --force
# Volume label: Joliet UCS-2BE (Unicode, max 16 chars, default = persona name);
# the ISO 9660 primary descriptor gets an ASCII fallback (DISCPERSONA).

# 4) burn (optional; needs xorriso/cdrskin/wodim/cdrecord/growisofs and a real drive)
node tools/burn-iso.js --list-drives
node tools/burn-iso.js --iso-path build/linux-disc.iso --drive /dev/sr0 --test-only
node tools/burn-iso.js --iso-path build/linux-disc.iso --drive /dev/sr0 --eject

# 5) optional: rebuild a plugin payload from npm
node tools/new-profile-payload.js --preset comfort
node tools/new-profile-payload.js --preset custom --plugins dsh-soul-md --out build/payload/profile-web --force
```

Differences from the PowerShell side:

| | Windows | Linux |
| --- | --- | --- |
| ISO writer | IMAPI2 | built-in pure-JS ISO9660 + Joliet writer (no external tools) |
| Burner | IMAPI2 | `xorriso` / `cdrskin` / `wodim` / `cdrecord` / `growisofs` |
| Drive selector | `-DriveLetter F` | `--drive /dev/sr0` (or bare `sr0`) |
| Executable bits on the disc | n/a | Joliet does not store them; start with `bash start.sh` |
| Launch entry | `start.cmd` + `autorun.inf` | `start.sh` |
| One disc, both OSes | yes — the packer requires both entries and both engines (`launch.ps1`, `launch.js`) |

Error codes are shared: `I01`–`I05` (ISO; `I05` is the post-write verification), `B01`–`B08` (burn),
`PL00`–`PL05` (payload), `E11`/`E12` (sealed persona unlock). `B06` also covers "no burning tool installed" and "writer cannot open the drive"
(e.g. a USB drive that keeps disconnecting, or a permissions problem). `--test-only` really opens the
drive with the writer, so it fails loudly instead of reporting a false success.
