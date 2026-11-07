# Contributing · 参与开发

Thanks for looking. This is a small project with a narrow scope: **make a persona live on a disc,
reliably, offline.** Windows is the primary target; Linux has a parallel implementation that must keep
the same disc format and room layout. Most PRs that fit that sentence get merged quickly.

谢谢你有兴趣。这个项目范围很窄：**离线地、可靠地让一个人设活在光盘里**。Windows 是主目标；Linux 有一份
并行实现，必须共用同一份光盘格式与房间布局。符合这句话的 PR 通常很快就能合进去。

---

## Before you start · 动手之前

1. Read [README.md](README.md) (or [README.zh-CN.md](README.zh-CN.md)) and [docs/engine.md](docs/engine.md).
   The engine's error-code table is the contract users see.
2. For anything that changes behavior, open an issue first. Small fixes: just send the PR.
3. **Do not add dependencies to the launch path.** The Windows launcher must run with the PowerShell
   that ships with the OS; the Linux launcher must run with plain Node.js builtins. No npm install,
   no binaries, no Chocolatey / extra distro packages.

1. 先读 README 与 `docs/engine.md`；错误码表是用户看到的契约。
2. 会改变行为的改动，请先开 issue。小修直接发 PR。
3. **不要在启动路径上引入依赖**：Windows 启动器只靠系统自带的 PowerShell，Linux 启动器只靠
   Node.js 内置模块。

## Requirements · 环境

- Windows 10/11 x64 with Windows PowerShell 5.1 (`powershell.exe`), not PowerShell 7 —
  `System.Web.Extensions` is required by the persona-card sync and does not exist in PS7.
- Linux with Node.js >= 18 (`node` on `PATH`). No npm packages are needed for anything in this repo.
- DeepSeek Harness `0.2.x` on `PATH` (only needed for end-to-end runs; unit tests use stubs).

## Testing · 测试

Everything is a PowerShell script; there is no build step.

**Windows**

```powershell
# engine: 17 self-tests against stub dsh executables, no network, no real dsh needed
powershell -ExecutionPolicy Bypass -File engine\_selftest\run-tests.ps1

# tools: build a disc from the sample persona and validate it
powershell -ExecutionPolicy Bypass -File tools\New-Disc.ps1 -Persona examples\sample-persona -Out build\disc
powershell -ExecutionPolicy Bypass -File tools\Test-Disc.ps1  -Disc build\disc

# studio: syntax-check the web app (no bundler)
node --check studio\web\app.js
node --check studio\web\card-import.js
```

**Linux**

```sh
# engine: 17 self-tests (same assertions, shell stubs)
node engine/_selftest/run-tests.js

# tools: build, validate, and image a disc; the ISO is verified after writing
node tools/new-disc.js --persona examples/sample-persona --out build/disc
node tools/test-disc.js --disc build/disc
node tools/new-iso.js --source build/disc --out build/disc.iso

# integration: tools + Studio HTTP API (no network, no drive)
node --test tests/
```

CI runs both sets (the `windows` and `linux` jobs). If your change touches `engine/`, run the matching
self-tests; if it touches `tools/`, rebuild and validate a disc on both platforms when possible.

CI 会同时跑 Windows 与 Linux 两套。改 `engine/` 请跑对应自测；改 `tools/` 请重新打包并校验
（条件允许时两边都跑）。

## Style · 代码风格

- **Encoding:** `.ps1` must be **UTF-8 with BOM**; `.cmd` must be **without** a BOM; both use **CRLF**.
  `.js` and `.sh` must be **UTF-8 without BOM** and **LF only**; `start.sh` must additionally be ASCII.
  CI enforces all of this.
- **Language of user-facing strings:** English outside the Studio (launcher, tools, logs, `README`),
  plain and specific ("Cannot find dsh…"), never a stack trace. The Studio UI and the Chinese README are
  bilingual by design. Code comments and identifiers: English.
- **Errors:** add a code (`E11`, `B09`, …) only if users can act on it differently; document it in
  `docs/engine.md` in the same PR.
- **No silent failures.** Every `catch` either fixes, retries, or reports with a code.
- Prefer editing existing helpers (`engine/lib/*.ps1`) over adding new ones.

## What we will not merge · 不接受

- DRM, license checks, or anything that tries to defeat a protection mechanism.
- Bundling copyrighted characters, artwork, or voice assets. The sample persona must stay original.
- Anything that writes outside the persona's room / the workspace without asking.
- Telemetry, auto-update, or network calls from the launcher.
- Rewrites of the Windows launch path into another language/runtime (the Windows path stays PowerShell;
  the Linux path stays Node.js builtins).

## Commit messages · 提交信息

Conventional-ish, one line, imperative:

```
engine: retry credential import when the first run failed
tools: refuse to overwrite a non-empty -Out directory
studio: poll burn jobs instead of blocking the listener
linux: keep start.sh LF-only and free of a BOM
```

## Licensing · 授权

By contributing you agree your contribution is licensed under the MIT License (see [LEGAL.md](LEGAL.md) §8).
