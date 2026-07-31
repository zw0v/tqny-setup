@echo off
setlocal EnableDelayedExpansion

rem ===========================================================================
rem  push-tqny.bat  -  publish changes to BOTH places at once
rem
rem   1. the private repo  github.com/zw0v/tqny-setup   (history and backup)
rem   2. the secret gist                                (what the one-liner uses)
rem
rem  Run this after editing TQNY-Setup.bat or tqny.ps1, otherwise the one-liner
rem  keeps serving the old version.
rem ===========================================================================

set "GIST_ID=6a91d906258ca360a88265b6dcd28ba6"
set "GH=%LOCALAPPDATA%\GitHubCLI\bin\gh.exe"
cd /d "%~dp0"

if not exist "%GH%" (
    echo [FAIL] GitHub CLI not found at:
    echo        %GH%
    goto done
)

echo.
echo  Normalising line endings to CRLF...
rem A .bat with Unix line endings makes cmd jump to the wrong lines.
powershell -NoProfile -Command "foreach($f in 'TQNY-Setup.bat','README.txt'){ if(Test-Path $f){ $t=[IO.File]::ReadAllText($f); $t=$t -replace \"`r`n\",\"`n\" -replace \"`n\",\"`r`n\"; [IO.File]::WriteAllText($f,$t,(New-Object Text.UTF8Encoding $false)) } }"

echo.
echo  [1/2] Pushing the private repo...
git add -A
git diff --cached --quiet
if errorlevel 1 (
    set /p "MSG=       Commit message: "
    if not defined MSG set "MSG=Update TQNY-Setup"
    git commit -q -m "!MSG!"
) else (
    echo        nothing new to commit
)
git push -q
if errorlevel 1 ( echo        [FAIL] push failed ) else ( echo        [OK] repo updated )

echo.
echo  [2/2] Updating the secret gist...
"%GH%" gist edit %GIST_ID% -f TQNY-Setup.bat TQNY-Setup.bat
if errorlevel 1 ( echo        [FAIL] could not update TQNY-Setup.bat ) else ( echo        [OK] TQNY-Setup.bat )
"%GH%" gist edit %GIST_ID% -f tqny.ps1 tqny.ps1
if errorlevel 1 ( echo        [FAIL] could not update tqny.ps1 ) else ( echo        [OK] tqny.ps1 )

echo.
echo  Done. Note the raw URL is cached for about 5 minutes, so the one-liner
echo  may still serve the previous version for a short while.
echo.
echo    irm https://gist.githubusercontent.com/zw0v/%GIST_ID%/raw/tqny.ps1 ^| iex
echo.

:done
pause
endlocal
