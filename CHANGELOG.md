# Changelog

All notable changes to this project. Format loosely follows [Keep a Changelog](https://keepachangelog.com/);
this project does not promise semantic versioning for the launcher — the **disc format** version is what
matters for compatibility.

## [0.3.0] - 2026-11-07

Linux support: a parallel Node.js implementation of the whole pipeline, sharing the disc format, the
persona room layout and all machine-readable output with the Windows side.

### Added

- **Linux launcher** — `start.sh` + `engine/launch.js` + `engine/lib/*.js` (Node.js >= 18, builtins
  only). Same boot sequence, `state.json`, lock file, patch generation, lorebook merge, persona card
  sync, workspace pinning, payload fallback and error codes E01–E10 as `launch.ps1`.
- **Linux tools** — `tools/new-disc.js`, `tools/test-disc.js`, `tools/new-iso.js`,
  `tools/burn-iso.js`, `tools/new-profile-payload.js`. The ISO builder always uses its
  dependency-free ISO9660 + Joliet writer, then verifies the written image (names, sizes and
  SHA-256). Burning uses `xorriso`/`cdrskin`/`wodim`/`cdrecord`/`growisofs` and reports the same
  B01–B08 codes.
- **Linux Studio + watcher** — `start-studio.sh` + `studio/server.js` (same web UI, same HTTP API)
  and `engine/tools/disc-watch.js`: an AutoPlay substitute that reacts to udisks2 D-Bus events
  (gdbus/busctl; slow polling fallback), auto-mounts via udisks2, shows a 启动 / 稍后 dialog
  (`--auto`/`--notify` modes), dedupes by discID, keeps a single-instance lock and installs an XDG
  autostart entry. The Studio's Linux final step detects the distro/package manager, checks
  udisks2/glib/zenity, prints the matching install command and can enable/disable autostart or
  start/stop the watcher with one click (`GET /api/linux/integration`,
  `POST /api/linux/autostart`).
- **Engine self-test on Linux** — `engine/_selftest/run-tests.js` with shell stubs, 17 assertions
  matching the PowerShell suite (T1–T14).
- **Docs and CI** — `docs/linux.md`, Linux sections in both READMEs, `engine.md`, `DISC-SPEC.md`,
  `studio.md`, `tools/README.md`; a `linux` job in `.github/workflows/checks.yml`; integration tests
  under `tests/`.
- Discs built by `new-disc.js` still carry `start.cmd` and `autorun.inf`, so one disc boots on both
  Windows and Linux; `new-disc.js` always includes `start.sh` and `engine/launch.js`.

### Changed

- `.gitattributes` now pins `*.sh`/`*.js` to LF; `.editorconfig` sets LF for `sh`/`md` too.
- `Test-Disc` (Linux) checks `start.sh` (LF, no BOM, shebang, references `engine/launch.js`) and
  treats `autorun.inf` / `start.cmd` as optional Windows extras instead of requirements.

### Fixed

- `tools/new-iso.js`: the built-in ISO9660 + Joliet writer always wins now. The external
  `xorriso`/`genisoimage` fast path was removed because its Rock Ridge entries changed the on-disc
  tree and failed the built-in verifier; the built-in image was verified by mounting and by a real burn.
- Joliet volume descriptor strings (volume id, application id) are now written as UCS-2BE, so a
  burned disc mounts with a readable label instead of a mojibake directory name. The Joliet label
  accepts Unicode (up to 16 chars, default = the persona's name); the ISO 9660 primary descriptor
  gets an ASCII fallback (`DISCPERSONA`). Verified by loop-mounting the ISO (`/run/media/.../蓝色大肥鱼`).
- `tools/burn-iso.js`: `--test-only` now really opens the drive with the writer instead of reporting
  success without touching it. `cdrskin` is detected as a writer, and failures name the real writer
  error (for example "Lost connection to drive") with USB port/cable/power advice instead of the last
  "aborting" line. B06 now also covers "writer cannot open the drive". Blank/finalized CD-R media is
  detected through `xorriso -list_formats` when `-msinfo` cannot answer, and the burn log no longer
  claims a "DISCPERSONA" label when the ISO carries its own (Unicode) label.
- 中文：`burn-iso.js` 用 `xorriso -list_formats` 识别空白/已封盘 CD-R，刻录日志不再声称卷标是
  `DISCPERSONA`（卷标来自 ISO 本身）。
- Verified against a real USB DVD writer (Slimtype eBAU108): ISO generation and drive detection work;
  burning correctly fails with B06 while the kernel reports a USB disconnect/reset loop.

### Notes

- Windows behaviour is unchanged; no `.ps1`/`.cmd` file was modified.
- The Linux launcher rejects non-Linux platforms with E05, just as the Windows launcher rejects
  non-Windows platforms.
- Linux has no AutoPlay: run `bash start.sh` from the mounted disc, or use the optional watcher.

---

## [0.3.0] - 2026-11-07（中文）

Linux 支持：整套流水线新增并行的 Node.js 实现，与 Windows 侧共用光盘格式、人格房间布局和
所有机器可读输出。

### 新增

- **Linux 启动器** — `start.sh` + `engine/launch.js` + `engine/lib/*.js`（Node.js ≥ 18，零 npm 依赖）。
  启动流程、`state.json`、锁文件、patch 生成、世界书拼接、人设卡同步、工作区钉定、插件载荷回退与
  错误码 E01–E10 均与 `launch.ps1` 对齐。
- **Linux 工具链** — `new-disc.js`、`test-disc.js`、`new-iso.js`、`burn-iso.js`、
  `new-profile-payload.js`。ISO 始终使用零依赖的 ISO9660 + Joliet 内置写入器，写出后回读校验；
  刻录走 `xorriso`/`cdrskin`/`wodim`/`cdrecord`/`growisofs`，错误码 B01–B08 不变。
- **Linux Studio 与守望者** — `start-studio.sh` + `studio/server.js`（同一网页、同一 API）、
  `engine/tools/disc-watch.js`：AutoPlay 等价物，优先用 udisks2 D-Bus 事件（gdbus/busctl，低频轮询兜底）、
  自动用 udisks2 挂载、弹「启动 / 稍后」（`--auto`/`--notify` 模式）、按 discID 去重、单实例锁、XDG autostart。
  Studio 的 Linux「07 出厂」页会识别发行版/包管理器、检查 udisks2/glib/zenity、给出对应安装命令，并可一键
  启用/关闭登录自启、立即启停守望者（`GET /api/linux/integration`、`POST /api/linux/autostart`）。
- **Linux 引擎自测** — `engine/_selftest/run-tests.js`，用 shell stub 覆盖与 PowerShell 套件相同的
  17 项断言（T1–T14）。
- **文档与 CI** — 新增 `docs/linux.md`，两份 README、`engine.md`、`DISC-SPEC.md`、`studio.md`、
  `tools/README.md` 增补 Linux 说明；`.github/workflows/checks.yml` 新增 `linux` job；
  `tests/` 下新增集成测试。
- `new-disc.js` 仍会写入 `start.cmd` 与 `autorun.inf`，并总是带上 `start.sh` 与 `engine/launch.js`，
  因此同一张盘可在 Windows / Linux 上启动。

### 变更

- `.gitattributes` 固定 `*.sh`/`*.js` 为 LF；`.editorconfig` 对 `sh`/`md` 也使用 LF。
- Linux 的 `test-disc.js` 检查 `start.sh`（LF、无 BOM、shebang、引用 `engine/launch.js`），
  `autorun.inf` / `start.cmd` 改为可选的 Windows 附加项。

### 修复

- `tools/new-iso.js`：ISO 只走内置的 ISO9660 + Joliet 写入器。外部 `xorriso`/`genisoimage` 快速路径已移除
  （它写入的 Rock Ridge 条目会改变盘上树形并让内置校验失败）；内置镜像已用挂载与真实刻录验证。
- Joliet 卷描述字符串（卷标、应用 ID）改为 UCS-2BE，烧出的盘挂载后卷标可读、不再乱码；Joliet 卷标
  支持中文等 Unicode（最多 16 字，默认取人设名），ISO 9660 主卷描述用 ASCII 回退（`DISCPERSONA`）。
  已用 loop 挂载验证（`/run/media/.../蓝色大肥鱼`）。
- `tools/burn-iso.js`：`--test-only` 现在会真正用写入器打开设备，而不是没碰设备就报成功；新增
  `cdrskin` 写入器探测；失败时给出写入器的真实原因（例如 "Lost connection to drive"）及 USB 口/线材/
  供电建议，不再只报最后一行 "aborting"。B06 也覆盖「写入器打不开设备」。
- 用真实 USB DVD 光驱（Slimtype eBAU108）验证：ISO 生成与光驱识别正常；内核持续报 USB 断连/重置时，
  刻录会正确以 B06 失败并说明原因。

### 说明

- Windows 行为不变，未修改任何 `.ps1`/`.cmd`。
- Linux 启动器对非 Linux 平台报 E05，与 Windows 启动器对非 Windows 平台的处理对称。
- Linux 没有 AutoPlay：挂载后运行 `bash start.sh`，或安装可选守望者。

---

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
