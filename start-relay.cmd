@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

if not exist "frpc.exe" (
  echo [ERROR] frpc.exe not found in %~dp0
  echo Run download-frpc.ps1 or copy frpc.exe from the kit first.
  pause
  exit /b 1
)
if not exist "frpc.toml" (
  echo [ERROR] frpc.toml not found. Run setup-relay.cmd first.
  pause
  exit /b 1
)

echo ============================================
echo Public SSH port is chosen randomly on each start.
echo The actual SSH command is printed after the proxy is online.
echo ============================================
echo Starting frpc... Press Ctrl+C to stop.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-relay.ps1"
set EC=%ERRORLEVEL%
echo.
echo frpc exited with code %EC%.
pause
exit /b %EC%
