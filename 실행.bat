@echo off
chcp 65001 >nul
cd /d "%~dp0"
where python >nul 2>nul
if errorlevel 1 (
  echo Python이 설치되어 있지 않습니다. https://www.python.org 에서 설치하세요 ^(Add Python to PATH 체크^)
  pause
  exit /b
)
python -m pip install -q -r requirements.txt
python app.py
pause
