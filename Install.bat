@echo off
setlocal
cd /d "%~dp0"

echo.
echo   Display Tuner
echo   =============
echo.

if not exist "dispwin.exe" (
    echo   dispwin.exe is missing.
    echo   Get ArgyllCMS from https://www.argyllcms.com/downloadwin.html
    echo   and put dispwin.exe next to this file.
    echo.
    pause
    exit /b 1
)

if not exist "DisplayTuner.exe" (
    echo   Building DisplayTuner.exe ...
    powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0Build-Exe.ps1"
    if errorlevel 1 (
        echo   Build failed.
        pause
        exit /b 1
    )
)

echo   Starting Display Tuner.
echo.
echo   Next steps:
echo     - tick "Start with Windows" in the app window
echo     - run Tests - Calibrate panel to measure your own panel
echo.
start "" "%~dp0DisplayTuner.exe"
timeout /t 3 /nobreak >nul
endlocal
