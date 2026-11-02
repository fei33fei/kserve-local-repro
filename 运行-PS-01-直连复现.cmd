@echo off
chcp 65001 >nul
title KServe - Repro v1 (online)
cd /d "%~dp0"

echo ============================================================
echo   KServe Repro - Version 1 (online)
echo   Requires: Docker Desktop / kubectl / kind / helm
echo   Docker Desktop will be started automatically.
echo ============================================================
echo.

set SCRIPT=
for %%f in ("%~dp0PS-01-*.ps1") do set SCRIPT=%%f
if "%SCRIPT%"=="" (
  echo [ERROR] PS-01-*.ps1 not found in %~dp0
  pause >nul
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
  echo [DONE] Script finished successfully. READY=True and inference verified.
) else (
  echo [FAILED] Exit code %RC%. Scroll up and read the red error above.
)
echo.
echo Press any key to close this window...
pause >nul
exit /b %RC%