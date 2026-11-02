@echo off
chcp 65001 >nul
title KServe - Repro v2 (offline)
cd /d "%~dp0"

echo ============================================================
echo   KServe Repro - Version 2 (offline, uses local artifacts)
echo   Requires: Docker Desktop / kubectl / kind
echo   Prereq: kind cluster + KServe already installed (run v1 once).
echo   Artifacts dir: subfolder next to this script (see README.md)
echo ============================================================
echo.

set SCRIPT=
for %%f in ("%~dp0PS-02-*.ps1") do set SCRIPT=%%f
if "%SCRIPT%"=="" (
  echo [ERROR] PS-02-*.ps1 not found in %~dp0
  pause >nul
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
  echo [DONE] Script finished successfully. No container image was pulled.
) else (
  echo [FAILED] Exit code %RC%. Scroll up and read the red error above.
)
echo.
echo Press any key to close this window...
pause >nul
exit /b %RC%