@echo off
rem Starts the APIS-K0 bridge (keep this window open while playing).
cd /d "%~dp0"
chcp 65001 >nul
rem Uses the virtual environment with the voice packages when it exists (see requirements.txt).
if exist .venv\Scripts\python.exe (
    .venv\Scripts\python.exe apiko_bridge.py
) else (
    python apiko_bridge.py
)
pause
