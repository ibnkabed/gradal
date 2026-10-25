@echo off
rem Double-click to start Gradal. The first run prepares Python and adds a desktop shortcut.
if not exist "%LOCALAPPDATA%\Gradal\venv\Scripts\python.exe" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Gradal.ps1" -Shortcut
) else (
  powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Gradal.ps1"
)
