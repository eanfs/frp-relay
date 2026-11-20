@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

if not exist "frpc.exe" (
  echo [ERROR] frpc.exe not found. Copy it from the relay kit's visitor folder.
  pause
  exit /b 1
)
if not exist "visitor.toml" (
  echo [ERROR] visitor.toml not found. Run setup-relay.cmd on the relay PC and copy the visitor folder.
  pause
  exit /b 1
)

echo ============================================
if exist "connection-info.txt" type "connection-info.txt"
echo ============================================
echo Starting STCP visitor... Press Ctrl+C to stop.
echo.

"%~dp0frpc.exe" -c "%~dp0visitor.toml"
set EC=%ERRORLEVEL%
echo.
echo frpc exited with code %EC%.
pause
exit /b %EC%
