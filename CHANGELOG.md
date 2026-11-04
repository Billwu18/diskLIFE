# Changelog

All notable changes to this project. Format loosely follows [Keep a Changelog](https://keepachangelog.com/);
this project does not promise semantic versioning for the launcher — the **disc format** version is what
matters for compatibility.

## [0.2.1] - 2026-11-05

### Fixed

- **凭据来源不再硬编码**。`Get-DPSourceHome` 之前把 `E:\dsh\dsh-data`（开发机的主 home）写死成候选，
  在**没有 E: 盘符的机器上** `Join-Path` 会抛 `Cannot find drive`，导致首次启动直接失败。
  现在的顺序是：`-SourceHome` 参数 > `DISCPERSONA_SOURCE_HOME` > `DSH_HOME` > `%USERPROFILE%\.dsh` >
  `%LOCALAPPDATA%\dsh`，路径拼接改用不校验盘符的 `[System.IO.Path]::Combine`，找不到就跳过并继续。
- **自测不再依赖本机主 home**。`engine/_selftest/run-tests.ps1` 现在自己设置 `DISCPERSONA_SOURCE_HOME`
  指向测试夹具，在没登录过 DSH 的干净机器（CI）上也能跑出 17/17。
- `README.zh-CN.md` 的「运行要求」一节之前只剩标题，已补回内容。

### Changed

- 项目名在 README 中统一为 **diskLIFE**（运行时目录 `DiscPersona\personas\<discID>` 保持不变，属于磁盘契约，
  两份 README 都加了「关于名字 / Naming」说明）。

## [0.2.0] - 2026-11-05

### Added

- **四组插件包预设**（打包时 `-PayloadPreset`，Studio「07 出厂」页可选），全部随盘离线：
  - `none` —— 不带插件，首次启动最快；
  - `comfort` —— `dsh-soul-md` + `dsh-persona-dafeiyu`；
  - `token` —— `dsh-context-compress`（历史软压缩）+ `dsh-faster-compress`（后台预备摘要）+
    `dsh-read-image-compress`（图片进上下文前先压小），长对话更省 token、不容易顶到上下文上限；
  - `full` —— 五个都要。
- Studio 插件包卡片：体积、具体插件、是否已构建；选择写进 `persona\meta.json` 的 `payload.preset` / `payload.plugins`。
- `/api/env` 新增 `payloadPresets[]`；`/api/build` 接受 `payload`；`state.json` 新增 `payloadPreset`（日志也会打印预设）。
- `tools/New-ProfilePayload.ps1` 新增 `-Preset comfort|token|full|custom`，输出默认按预设分目录。

### Changed

- `payload\` 改成按预设分库 `payload\<preset>\profile-web`（旧 `payload\profile-web` 仍识别）。
- `tools/New-Disc.ps1` 默认 `-PayloadPreset comfort`（与旧行为一致）；`none` 可打纯人设盘。
- Studio 调子脚本的输出改走临时文件再解码，日志中文不再乱码。

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
