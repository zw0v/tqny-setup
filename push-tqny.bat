@echo off
setlocal EnableDelayedExpansion

rem ===========================================================================
rem  push-tqny.bat  -  publish changes to BOTH places at once
rem
rem   1. the repo        github.com/zw0v/tqny-setup   (history and backup)
rem   2. the secret gist                              (what the one-liner uses)
rem
rem  Run this after editing any of the tool files, otherwise the one-liner
rem  keeps serving the old version. Results are also written to push-tqny.log.
rem
rem  First run in a folder that is not a git clone yet: it connects the folder
rem  to the GitHub repo by itself (init, fetch, keep these files) and commits
rem  them on top of the current version.
rem  If COMMIT-MESSAGE.txt exists it is used as the commit message, then deleted.
rem ===========================================================================

set "GIST_ID=6a91d906258ca360a88265b6dcd28ba6"
set "REPO_URL=https://github.com/zw0v/tqny-setup"
cd /d "%~dp0"
set "LOGF=%~dp0push-tqny.log"
> "%LOGF%" echo push-tqny %date% %time%

rem ---- tools: git and the GitHub CLI, installed once with winget if missing ----
where git >nul 2>&1
if errorlevel 1 if exist "%ProgramFiles%\Git\cmd\git.exe" set "PATH=%ProgramFiles%\Git\cmd;%PATH%"
where git >nul 2>&1
if errorlevel 1 (
    call :say "  git is not installed - installing it with winget. Approve the Windows prompt."
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    if exist "%ProgramFiles%\Git\cmd\git.exe" set "PATH=%ProgramFiles%\Git\cmd;%PATH%"
)
where git >nul 2>&1
if errorlevel 1 (
    call :say "[FAIL] git is still not available. Install Git for Windows, then run this again."
    goto done
)

call :find_gh
if not defined GH (
    call :say "  GitHub CLI is not installed - installing it with winget. Approve the Windows prompt."
    winget install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
    call :find_gh
)
if defined GH (
    "!GH!" auth status >nul 2>&1
    if errorlevel 1 (
        echo.
        call :say "  Sign in to GitHub once: press Enter, a browser opens - log in as zw0v and paste the code shown here."
        "!GH!" auth login --hostname github.com --git-protocol https --web
    )
    rem Let git use the same GitHub login for the repo push.
    "!GH!" auth setup-git >> "%LOGF%" 2>&1
)

echo.
echo  Normalising .bat / .txt files to CRLF...
rem A .bat with Unix line endings makes cmd jump to the wrong lines.
powershell -NoProfile -Command "foreach($f in 'TQNY-Setup.bat','TQNY-Classic.bat','push-tqny.bat','README.txt'){ if(Test-Path $f){ $t=[IO.File]::ReadAllText($f); $t=$t -replace \"`r`n\",\"`n\" -replace \"`n\",\"`r`n\"; [IO.File]::WriteAllText($f,$t,(New-Object Text.UTF8Encoding $false)) } }"

rem ---- first run: connect this folder to the repo -----------------------------
if not exist ".git\" (
    echo.
    call :say "  This folder is not a git clone yet - connecting it to %REPO_URL% ..."
    git init -q >> "%LOGF%" 2>&1
    git symbolic-ref HEAD refs/heads/main >> "%LOGF%" 2>&1
    git remote add origin %REPO_URL% >> "%LOGF%" 2>&1
    git fetch -q origin >> "%LOGF%" 2>&1
    if errorlevel 1 (
        call :say "[FAIL] Could not fetch %REPO_URL% - check the internet / GitHub login. See push-tqny.log"
        goto done
    )
    rem Point main at the current GitHub version without touching these files.
    git reset -q --mixed origin/main >> "%LOGF%" 2>&1
    git branch -q -u origin/main >> "%LOGF%" 2>&1
    call :say "  [OK] connected"
)

rem Commits need a name. Use the repo owner's GitHub identity if none is set.
for /f "delims=" %%E in ('git config user.email 2^>nul') do set "HAVEMAIL=%%E"
if not defined HAVEMAIL (
    git config user.name "zw0v"
    git config user.email "zw0v@users.noreply.github.com"
)

rem Tag the new version ($TOOL_VERSION in TQNY-Setup.ps1) so it is easy to go back to.
for /f "tokens=2 delims='" %%V in ('findstr /b /c:"$TOOL_VERSION = " TQNY-Setup.ps1 2^>nul') do set "NEWVER=%%V"

echo.
echo  [1/2] Pushing the repo...
git add -A
git diff --cached --quiet
if errorlevel 1 (
    if exist "COMMIT-MESSAGE.txt" (
        git commit -q -F "COMMIT-MESSAGE.txt" >> "%LOGF%" 2>&1
        if not errorlevel 1 del "COMMIT-MESSAGE.txt"
    ) else (
        set "MSG="
        set /p "MSG=       Commit message: "
        if not defined MSG set "MSG=Update TQNY-Setup"
        git commit -q -m "!MSG!" >> "%LOGF%" 2>&1
    )
    if defined NEWVER (
        git rev-parse -q --verify "refs/tags/v!NEWVER!" >nul 2>&1
        if errorlevel 1 git tag -a "v!NEWVER!" -m "v!NEWVER!" >> "%LOGF%" 2>&1
    )
) else (
    echo        nothing new to commit
)
git push -q -u origin main --follow-tags >> "%LOGF%" 2>&1
if errorlevel 1 ( call :say "       [FAIL] repo push failed - see push-tqny.log" ) else ( call :say "       [OK] repo updated" )

echo.
echo  [2/2] Updating the secret gist (all files)...
if not defined GH (
    call :say "       [FAIL] GitHub CLI not found - the gist was NOT updated."
    goto done
)
for %%F in (tqny.ps1 TQNY-Setup.ps1 TQNY-Setup.bat TQNY-Classic.bat scan-source.ps1 printer-scan-source.ps1) do (
    "!GH!" gist edit %GIST_ID% -f %%F %%F >> "%LOGF%" 2>&1
    if errorlevel 1 (
        rem not in the gist yet - add it
        "!GH!" gist edit %GIST_ID% -a %%F >> "%LOGF%" 2>&1
        if errorlevel 1 ( call :say "       [FAIL] %%F" ) else ( call :say "       [OK] added %%F" )
    ) else (
        call :say "       [OK] %%F"
    )
)

echo.
echo  Done. The raw URL is cached about 5 minutes, so the one-liner may serve
echo  the previous version for a short while.
echo.
echo    irm https://gist.githubusercontent.com/zw0v/%GIST_ID%/raw/tqny.ps1 ^| iex
echo.
call :say "finished"

:done
pause
endlocal
exit /b 0

:say
echo %~1
>> "%LOGF%" echo %~1
exit /b 0

rem ---- locate gh.exe: the old portable path, PATH, or the default install ----
:find_gh
set "GH="
if exist "%LOCALAPPDATA%\GitHubCLI\bin\gh.exe" set "GH=%LOCALAPPDATA%\GitHubCLI\bin\gh.exe"
if not defined GH for /f "delims=" %%G in ('where gh 2^>nul') do if not defined GH set "GH=%%G"
if not defined GH if exist "%ProgramFiles%\GitHub CLI\gh.exe" set "GH=%ProgramFiles%\GitHub CLI\gh.exe"
exit /b 0
