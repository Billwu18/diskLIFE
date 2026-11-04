@echo off
rem DiscPersona Studio -- local web workbench for creating persona packs.
rem Requires: Windows PowerShell 5.1 (built in). No node, no python.
setlocal
chcp 65001 >nul 2>nul
set "HERE=%~dp0"
if not exist "%HERE%studio\server.ps1" (
  echo [ERROR] studio\server.ps1 not found next to this script.
  echo         Keep this folder layout: start-studio.cmd + studio + tools + engine + persona
  pause
  exit /b 1
)
echo.
echo   DiscPersona Studio
echo   A local page will open. Close this window to stop the server.
echo.
rem Default port is 4791 (set inside server.ps1). If it is taken, the server picks
rem the next free one, or points the browser at an already-running Studio.
rem Extra arguments are passed through, e.g.  start-studio.cmd -Port 4800
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%studio\server.ps1" %*
if errorlevel 1 (
  echo.
  echo [ERROR] Studio did not start. The reason is printed above.
  echo         Common causes: port already in use, PowerShell blocked by policy,
  echo         or studio\server.ps1 was edited and no longer parses.
  pause
)
endlocal
