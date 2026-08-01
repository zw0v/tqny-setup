@echo off
setlocal EnableDelayedExpansion

rem ===========================================================================
rem  push-tqny.bat  -  publish changes to BOTH places at once
rem
rem   1. the private repo  github.com/zw0v/tqny-setup   (history and backup)
rem   2. the secret gist                                (what the one-liner uses)
rem
rem  Run this after editing any of the tool files, otherwise the one-liner
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
echo  Normalising the .bat to CRLF...
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
echo  [2/2] Updating the secret gist (all files)...
for %%F in (TQNY-Setup.bat tqny.ps1 scan-source.ps1 printer-scan-source.ps1) do (
    "%GH%" gist edit %GIST_ID% -f %%F %%F >nul 2>&1
    if errorlevel 1 (
        rem not in the gist yet - add it
        "%GH%" gist edit %GIST_ID% -a %%F >nul 2>&1
        if errorlevel 1 ( echo        [FAIL] %%F ) else ( echo        [OK] added %%F )
    ) else (
        echo        [OK] %%F
    )
)

echo.
echo  Done. The raw URL is cached about 5 minutes, so the one-liner may serve
echo  the previous version for a short while.
echo.
echo    irm https://gist.githubusercontent.com/zw0v/%GIST_ID%/raw/tqny.ps1 ^| iex
echo.

:done
pause
endlocal
