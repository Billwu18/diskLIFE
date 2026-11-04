@echo off
rem ============================================================
rem  DiscPersona boot loader   (ASCII only - do not add Chinese)
rem  All real work happens in engine\launch.ps1
rem ============================================================
chcp 65001 >nul 2>&1
setlocal EnableExtensions

set "DP_ROOT=%~dp0"
set "DP_ROOT=%DP_ROOT:~0,-1%"
set "DP_PS="
rem Prefer Windows PowerShell 5.1: the engine uses System.Web.Extensions (absent in PS7)
where powershell.exe >nul 2>&1 && set "DP_PS=powershell.exe"
if not defined DP_PS (
    where pwsh.exe >nul 2>&1 && set "DP_PS=pwsh.exe"
)
if not defined DP_PS goto :nops

"%DP_PS%" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%DP_ROOT%\engine\launch.ps1" -DiscRoot "%DP_ROOT%" %*
set "DP_RC=%ERRORLEVEL%"
if not "%DP_RC%"=="0" (
    echo.
    echo  [DiscPersona] boot did not complete. exit code %DP_RC%
    echo  See the message above. Logs:
    echo    %LOCALAPPDATA%\DiscPersona\personas
    echo.
    pause
)
endlocal & exit /b %DP_RC%

:nops
echo.
echo  [DiscPersona] PowerShell not found on this machine.
echo  Windows 10/11 with PowerShell enabled is required.
echo.
pause
exit /b 1
