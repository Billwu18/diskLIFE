## What this changes

<!-- One or two sentences. Link the issue if there is one: "Fixes #12". -->

## How I tested it

- [ ] `engine\_selftest\run-tests.ps1` → all pass (if `engine/` changed)
- [ ] `tools\New-Disc.ps1` + `tools\Test-Disc.ps1` → `PASS` (if `tools/` changed)
- [ ] `node --check studio\web\app.js` (if `studio/` changed)
- [ ] Ran it for real (please say how: mounted ISO / burned disc / plain folder / Studio)

## Checklist

- [ ] `.ps1` / `.cmd` files are **UTF-8 with BOM**, CRLF line endings
- [ ] No new dependency on the launch path (system PowerShell 5.1 only)
- [ ] User-facing messages are Chinese, specific, and carry an error code when actionable
- [ ] No credentials, personal paths, or third-party copyrighted content added
- [ ] Docs updated (`docs/engine.md` for error codes, `docs/studio.md` for API changes)
