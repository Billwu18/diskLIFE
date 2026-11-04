# Changelog

All notable changes to this project. Format loosely follows [Keep a Changelog](https://keepachangelog.com/);
this project does not promise semantic versioning for the launcher — the **disc format** version is what
matters for compatibility.

## [0.1.0] — first public release

First open-source snapshot of a system that had been running privately for a few days.

### Added

- **Launcher** (`engine/launch.ps1`): `discID` from `sha256(pad.bin)[0:16]`; per-disc isolated
  `DSH_HOME`; credential/seed/AGENTS import; persona → `--patch` synthesis; single-instance lock;
  Windows console that waits for a keypress (`-NoWait` to skip).
- **Persona Pack v1**: `persona.yml` + `AGENTS.md` + `meta.json` (+ optional `avatar.png`,
  `lorebook.json`, `seed/`, `card.json`). Lorebook entries are appended to the system prompt (≤ 6000 chars).
- **Persona card sync**: pins the `dsh-persona-dafeiyu` plugin's active card to the disc's persona so a
  bundled demo card cannot impersonate your character.
- **Workspace pinning**: each room gets its own workspace (`<人设名>的房间`) instead of the shared
  Documents folder.
- **Plugin payload**: `payload/profile-web/` (soul-md + persona-dafeiyu, MIT) copied into the profile on
  first run; automatic fallback to a vanilla profile if it fails to load.
- **Tools**: `New-Disc.ps1` (pack + `pad.bin` + SHA-256 manifest + `autorun.inf`), `Test-Disc.ps1`
  (36 static checks), `New-Iso.ps1` (IMAPI2, ISO 9660 + Joliet), `Burn-Iso.ps1` (IMAPI2, error codes
  B01–B08), `New-ProfilePayload.ps1` (rebuild the payload).
- **Studio**: local web wizard (7 steps, live preview, 8 checks), Character Card V2/V3 import from PNG/JSON,
  export → pack → ISO → burn, async burn jobs, optional AI drafting (off by default).
- **disc-watch.ps1**: opt-in plug-in watchdog (`-Install` / `-Uninstall`).
- **Docs**: engine internals + error codes, disc spec, Studio manual, bilingual legal notice,
  third-party notices.

### Fixed (pre-release audit)

- `New-Disc.ps1` could delete an arbitrary existing `-Out` directory; now refuses unless it is empty,
  a previous disc, or `-Force` is given.
- `/api/iso` and `/api/export` accepted paths outside the workspace; now restricted to the workspace /
  `%LOCALAPPDATA%\DiscPersona` and to the expected file types.
- Credential import happened only on "first boot"; a run that failed after creating `profiles/web` could
  never import credentials again. Assets are now re-imported idempotently on every start.
- Single-instance lock was acquired late (after payload copy + bootstrap), so two simultaneous launches
  could both start. The lock is now taken before any bootstrap work.
- Files copied from a CD carry the read-only attribute, which made `dsh` fail to save settings with
  `EPERM: rename …cordis.patch.yml.tmp`. Attributes are cleared after every copy.
- `Sync-DPWorkspace` serialized empty arrays as `{}` (`ConvertTo-Json` quirk), breaking the workspace
  schema. JSON for that file is now written by hand.
- Burn jobs blocked the single-threaded HTTP listener for 30–60 s; they now run as polled jobs.
- `start.cmd` preferred `pwsh`, where `System.Web.Extensions` is unavailable and persona-card sync silently
  failed; it now prefers `powershell.exe`.
