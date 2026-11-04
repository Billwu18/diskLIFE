# Changelog

All notable changes to this project. Format loosely follows [Keep a Changelog](https://keepachangelog.com/);
this project does not promise semantic versioning for the launcher — the **disc format** version is what
matters for compatibility.

## [0.2.3] - 2026-11-05

Everything a user sees while running the project is now English. The Studio's own bilingual UI is
unchanged; the personas, the docs and the disc format are untouched.

### Changed

- **The launcher, the packer and their messages are English-only.** `engine/launch.ps1`,
  `engine/lib/*.ps1`, `tools/New-Disc.ps1`, `tools/Test-Disc.ps1`, `tools/New-Iso.ps1`,
  `tools/Burn-Iso.ps1`, `tools/New-ProfilePayload.ps1` and `engine/tools/disc-watch.ps1` no longer print
  Chinese. Error codes (`E01`–`E10`, `B01`–`B08`, `I01`–`I04`, `PL00`–`PL05`) and the machine-readable
  lines (`DISC_OK`, `ISO_OK`, `BURN_OK`, `BURN_FAIL`, `PAYLOAD_OK`) are byte-identical to 0.2.2.
- The log file (`logs\launch-*.log`), `state.json` values and the disc watcher's log are English too.
  `engine/_selftest` fixtures, the stub `dsh` scripts and `tools/_selftest/fake-persona` were translated
  with their assertions retargeted, so the suite still runs 17/17.
- Docs: `docs/engine.md` quotes the new output lines. `README`/`README.zh-CN` state plainly that only the
  Studio is bilingual.

### Fixed

- `engine/launch.ps1` leaked three stray `0` lines before the summary: `Clear-DPReadOnly` returns a
  count and three call sites printed it. They are `[void]`-suppressed now.
- `tools/New-ProfilePayload.ps1`'s closing hint pointed at the pre-0.2.0 `build\payload\profile-web`
  directory; it now names `-PayloadPreset` and the actual output path.

---

## [0.2.3] - 2026-11-05（中文）

跑起来看到的每个字都是英文了。Studio 自己的双语界面不变；人设、文档与光盘格式都没动。

### Changed

- **启动器、打包器与它们的输出改为纯英文。** 上列 9 个脚本不再打印中文。错误码（`E01`–`E10`、
  `B01`–`B08`、`I01`–`I04`、`PL00`–`PL05`）与机器可读行（`DISC_OK`、`ISO_OK`、`BURN_OK`、`BURN_FAIL`、
  `PAYLOAD_OK`）与 0.2.2 逐字节一致。
- 日志文件、`state.json` 的值、守望者日志同样是英文。自测夹具、假 `dsh` 脚本与假人设包一并翻译，
  断言随之改指英文，自测仍是 17/17。
- 文档：`docs/engine.md` 里引用的输出行已更新；两份 README 都写明「只有 Studio 是双语的」。

### Fixed

- `engine/launch.ps1` 在摘要前多打三行 `0`：`Clear-DPReadOnly` 有返回值，三处调用没抑制。现已 `[void]`。
- `tools/New-ProfilePayload.ps1` 结尾提示仍指向 0.2.0 之前的 `build\payload\profile-web`，
  改为提示 `-PayloadPreset` 与实际输出路径。

## [0.2.2] - 2026-11-05

### Added

- **The Studio now speaks English.** It follows the browser: a Chinese browser gets Chinese, anything else
  gets English. Override with `?lang=zh` / `?lang=en`, or the switch in the top-right corner — the choice is
  remembered in `localStorage`.
- `studio/web/i18n.js`: a ~240-entry dictionary plus a DOM applier. Chinese stays the source language in the
  markup and scripts; anything without a translation falls back to Chinese instead of showing a key.
- The plugin-pack cards are localised too — `/api/env` now returns `label_en` / `desc_en` alongside the
  Chinese labels.

### Fixed

- Preview and footer counters (`chars`, `lines`) stayed Chinese in the English UI.

---

### 新增

- **Studio 有英文界面了。** 跟随浏览器：中文环境显示中文，其它语言环境显示英文。可用 `?lang=zh` /
  `?lang=en` 或右上角切换按钮覆盖，选择记在 `localStorage` 里。
- `studio/web/i18n.js`：约 240 条词条 + 一个 DOM 替换器。源码里中文仍是源语言，缺译文时回退中文而不是显示 key。
- 插件包卡片也本地化了：`/api/env` 现在同时返回 `label_en` / `desc_en`。

### 修复

- 英文界面下预览区与页脚的「字 / 行」计数残留中文。

## [0.2.1] - 2026-11-05

### Fixed

- **Credential lookup is no longer hard-coded.** `Get-DPSourceHome` used to carry the developer machine's
  `E:\dsh\dsh-data` as a candidate; on a machine without an `E:` drive `Join-Path` threw `Cannot find drive`
  and the very first launch failed. The order is now `-SourceHome` > `DISCPERSONA_SOURCE_HOME` > `DSH_HOME` >
  `%USERPROFILE%\.dsh` > `%LOCALAPPDATA%\dsh`, joined with `[System.IO.Path]::Combine` (which does not validate
  the drive letter), skipping missing candidates instead of throwing.
- **The self-test no longer depends on the machine's real DSH home.** `engine/_selftest/run-tests.ps1` now sets
  `DISCPERSONA_SOURCE_HOME` to its own fixture, so 17/17 passes on a clean CI runner that never logged in to DSH.
- `README.zh-CN.md` had a bare `## 运行要求` heading with no content; the section is back.

### Changed

- The project name is **diskLIFE** throughout both READMEs. The runtime folder stays
  `DiscPersona\personas\<discID>` (it is part of the on-disk contract); both READMEs explain the mismatch.

---

### 修复

- **凭据来源不再硬编码**：`Get-DPSourceHome` 之前把开发机的 `E:\dsh\dsh-data` 写死成候选，在没有 `E:` 盘符的
  机器上 `Join-Path` 会抛 `Cannot find drive`，首次启动直接失败。现在的顺序是 `-SourceHome` >
  `DISCPERSONA_SOURCE_HOME` > `DSH_HOME` > `%USERPROFILE%\.dsh` > `%LOCALAPPDATA%\dsh`，拼接改用
  `[System.IO.Path]::Combine`，找不到就跳过。
- **自测不再依赖本机主 home**：`engine/_selftest/run-tests.ps1` 自己设置 `DISCPERSONA_SOURCE_HOME` 指向测试夹具，
  在没登录过 DSH 的干净 CI 上也能跑出 17/17。
- `README.zh-CN.md` 的「运行要求」之前只剩标题，已补回内容。

### 变更

- 项目名在两份 README 中统一为 **diskLIFE**；运行时目录仍叫 `DiscPersona\personas\<discID>`（属于磁盘契约），
  两份 README 都加了说明。

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
