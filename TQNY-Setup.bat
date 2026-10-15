@echo off
rem ===========================================================================
rem  TQNY-Setup.bat   --   TQNY IT Setup v4.0 launcher
rem
rem   Double-click          opens the TQNY IT Setup app window (TQNY-Setup.ps1)
rem   TQNY-Setup.bat /classic   opens the v3.2 console menu (TQNY-Classic.bat)
rem   Any v3.2 switch       e.g.  TQNY-Setup.bat /apply /site:JED
rem                         is handed to TQNY-Classic.bat, so existing scripts
rem                         and shortcuts keep working exactly as before.
rem
rem  Keep these together in one folder:
rem    TQNY-Setup.bat  TQNY-Setup.ps1  TQNY-Classic.bat
rem    scan-source.ps1  printer-scan-source.ps1   (used by the classic menu)
rem
rem  Keep this file saved with CRLF line endings (see README).
rem ===========================================================================
setlocal
set "TQNY_A1=%~1"
if not defined TQNY_A1 goto gui

rem A switch value like /db:"\\srv\my share\n.csv" keeps its quotes, so strip
rem them before comparing (paths and switches never contain a quote).
setlocal EnableDelayedExpansion
set "TQNY_A1=!TQNY_A1:"=!"
set "TQNY_CLASSIC=0"
if /i "!TQNY_A1!"=="/classic" set "TQNY_CLASSIC=1"
endlocal & set "TQNY_CLASSIC=%TQNY_CLASSIC%"

if not exist "%~dp0TQNY-Classic.bat" (
    echo [FAIL] TQNY-Classic.bat must sit next to this file.
    exit /b 1
)
if "%TQNY_CLASSIC%"=="1" (
    call "%~dp0TQNY-Classic.bat" /menu
) else (
    call "%~dp0TQNY-Classic.bat" %*
)
exit /b %errorlevel%

:gui
if not exist "%~dp0TQNY-Setup.ps1" (
    echo.
    echo  [FAIL] TQNY-Setup.ps1 must sit next to this file:
    echo         %~dp0
    echo.
    pause
    exit /b 1
)
rem The app asks for Administrator itself (once, at start), then opens its window.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0TQNY-Setup.ps1"
exit /b 0
