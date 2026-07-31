@echo off
setlocal EnableDelayedExpansion
set "ALLARGS=%*"

rem ===========================================================================
rem  TQNY-Setup.bat   --   TQNY IT provisioning tool
rem
rem  Run with no arguments for the menu.
rem  Run with switches for scripted use. TQNY-Setup.bat /? lists them.
rem
rem   1. Renames the PC to PREFIX-NN and guarantees no two machines collide.
rem   2. Checks the internet - READ ONLY, never changes a network setting.
rem   3. Makes the PC visible on the network so its shares can be reached.
rem ===========================================================================

rem ---------------------------------------------------------------------------
rem  CONFIG - edit these if needed
rem ---------------------------------------------------------------------------

rem Default prefix for every assigned name, giving TQNY-01, TQNY-02, ...
rem Override for one run with /prefix:ACME, or from the menu.
rem Each prefix gets its own numbering, so ACME-01 and TQNY-01 can both exist.
set "TQNY_PREFIX=TQNY"

rem Machines that must NEVER be renamed by this tool.
rem PROTECTED_MACS : NIC MACs, no separators, uppercase, space separated.
rem PROTECTED_NAMES: current computer names, space separated.
set "PROTECTED_MACS=74563CC0AE41"
set "PROTECTED_NAMES=ZW0V"

rem How many one-second tries to wait for the registry lock.
set "LOCK_TRIES=20"

rem ---------------------------------------------------------------------------
rem  Do not edit below this line
rem ---------------------------------------------------------------------------

set "TOOL_VERSION=2.0"
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "DB_FILE=%SCRIPT_DIR%\TQNY-Names.csv"
set "LOG_DIR=%SCRIPT_DIR%\logs"
set "CSV_HEADER=Number,AssignedName,Fingerprint,FpType,OldName,Model,Serial,FirstSeenUTC,LastSeenUTC,Tech,Site"

set "WORK=%TEMP%\tqny-%RANDOM%%RANDOM%"
md "%WORK%" 2>nul
set "PSOUT=%WORK%\ps.txt"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -NonInteractive -Command"

set "PREFIX=%TQNY_PREFIX%"
set "ASK_PREFIX=0"
set "MODE=preview"
set "WANT_SHARE=1"
set "WANT_REBOOT=ask"
set "FORCE_DOMAIN=0"
set "FORCE_NUM="
set "SITE=-"
set "DO_LIST=0"
set "DO_RELEASE=0"
set "NO_RENAME=0"
set "GUARD_HIT="
set "GUARD_SHORT=protected PC"
set "REMOTE=0"
set "DB_EXPLICIT=0"
set "EXITCODE=0"
set "LOCK_HELD=0"
set "PAUSE_END=0"
set "RENAMED=0"
set "TARGET="
set "LOG="
set "MENU=0"
set "ADMIN=0"
set "EMPTYIN=0"
set "DNS_OK=?"
set "WEB_OK=?"
set "D_CAT=-"
set "D_NIC=-"

call :init_colors

rem No arguments at all means the interactive menu.
if "%~1"=="" goto menu_start

rem ---------------------------------------------------------------------------
rem  Parse arguments
rem ---------------------------------------------------------------------------
:parse
if "%~1"=="" goto parsed
set "A=%~1"
if /i "!A!"=="/apply"        ( set "MODE=apply"      & shift & goto parse )
if /i "!A!"=="/preview"      ( set "MODE=preview"    & shift & goto parse )
if /i "!A!"=="/list"         ( set "DO_LIST=1"       & shift & goto parse )
if /i "!A!"=="/release"      ( set "DO_RELEASE=1"    & shift & goto parse )
if /i "!A!"=="/no-share"     ( set "WANT_SHARE=0"    & shift & goto parse )
if /i "!A!"=="/reboot"       ( set "WANT_REBOOT=yes" & shift & goto parse )
if /i "!A!"=="/no-reboot"    ( set "WANT_REBOOT=no"  & shift & goto parse )
if /i "!A!"=="/force-domain" ( set "FORCE_DOMAIN=1"  & shift & goto parse )
if /i "!A!"=="/elevated"     ( set "PAUSE_END=1"     & shift & goto parse )
if /i "!A!"=="/ask"          ( set "ASK_PREFIX=1"    & shift & goto parse )
if /i "!A!"=="/menu"         ( goto menu_start )
if /i "!A!"=="/remote"       ( set "REMOTE=1"        & shift & goto parse )
if /i "!A!"=="/?"     goto usage
if /i "!A!"=="-h"     goto usage
if /i "!A!"=="--help" goto usage
if /i "!A:~0,6!"=="/name:" ( set "FORCE_NUM=!A:~6!" & shift & goto parse )
if /i "!A:~0,6!"=="/site:" ( set "SITE=!A:~6!"      & shift & goto parse )
if /i "!A:~0,8!"=="/prefix:" ( set "PREFIX=!A:~8!"  & shift & goto parse )
if /i "!A:~0,4!"=="/db:"   ( set "DB_FILE=!A:~4!"   & set "DB_EXPLICIT=1" & shift & goto parse )
echo [ERROR] Unknown option: !A!
echo Run  "%~nx0" /?  for help.
set "EXITCODE=1"
goto hardexit

:usage
call :show_switches
goto hardexit

:parsed

rem --- fail fast on a bad /prefix: before we bother asking for admin rights --
call :validate_prefix
if errorlevel 1 goto hardexit

rem --- validate /name: without tripping over octal or leading zeros ----------
if not defined FORCE_NUM goto num_ok
echo %FORCE_NUM%| findstr /r /c:"^[0-9][0-9]*$" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] /name: needs a positive whole number, for example /name:07
    set "EXITCODE=1"
    goto hardexit
)
set "FN=%FORCE_NUM%"
:num_strip
if "!FN:~0,1!"=="0" if not "!FN!"=="0" ( set "FN=!FN:~1!" & goto num_strip )
if "!FN!"=="0" (
    echo [ERROR] /name: must be 1 or higher.
    set "EXITCODE=1"
    goto hardexit
)
set "FORCE_NUM=!FN!"
:num_ok

call :set_db_paths

rem ---------------------------------------------------------------------------
rem  Elevate, but only when we are actually going to change something.
rem  /list and /release only read or edit the CSV, so they need no elevation.
rem ---------------------------------------------------------------------------
if not "%MODE%"=="apply" goto admin_ok
fltmc >nul 2>&1
if not errorlevel 1 goto admin_ok
echo.
echo [..] Administrator rights are needed to apply changes. Elevating...
call :relaunch_elevated
goto hardexit

:admin_ok

rem --- optional interactive prefix choice, after elevation so it is asked once
if not "%ASK_PREFIX%"=="1" goto prefix_ready
echo.
echo   Names are built as PREFIX-NN, for example %PREFIX%-01, %PREFIX%-02.
set "NEWPFX="
set /p "NEWPFX=  Prefix to use, or press Enter to keep %PREFIX%: "
if defined NEWPFX set "PREFIX=%NEWPFX%"
call :validate_prefix
if errorlevel 1 goto hardexit
:prefix_ready

call :gather_facts
if errorlevel 1 goto hardexit
call :open_log

call :hdr "TQNY-Setup v%TOOL_VERSION%   mode: %MODE%"
call :say "Machine       : %M_NAME%      model: %M_MODEL%"
call :say "Fingerprint   : %FP%   source: %FPTYPE%   NIC: %M_NIC%"
call :say "Workgroup/dom : %M_DOMAIN%      domain-joined: %M_INDOMAIN%"
call :say "Name prefix   : %PREFIX%      names look like %PREFIX%-01"
call :say "Registry file : %DB_FILE%"
call :say ""

if "%DO_LIST%"=="1"    ( call :do_list    & goto cleanup )
if "%DO_RELEASE%"=="1" ( call :do_release & goto cleanup )

call :step_guard
call :step_domain
call :step_alloc
call :step_rename
call :step_diag
call :step_share
call :step_summary
call :offer_reboot
goto cleanup


rem ===========================================================================
rem  MENU
rem ===========================================================================
:menu_start
set "MENU=1"
title TQNY IT Setup v%TOOL_VERSION%
rem Reached directly or via /menu, so validate anything already parsed.
call :validate_prefix
if errorlevel 1 goto hardexit
call :set_db_paths
call :gather_facts
if errorlevel 1 goto hardexit

rem Ask for admin once, up front, so there is no mid-menu UAC prompt.
fltmc >nul 2>&1
if not errorlevel 1 (
    set "ADMIN=1"
) else (
    cls
    echo.
    echo   %C_C%TQNY IT Setup v%TOOL_VERSION%%C_0%
    echo.
    echo   This tool needs Administrator rights to rename a PC or change
    echo   network settings. Checking and reporting works without them.
    echo.
    set "ANS="
    set /p "ANS=  Restart as Administrator now? [Y/N]: "
    if /i "!ANS!"=="Y" (
        call :relaunch_elevated
        goto hardexit
    )
)
call :open_log

:main_menu
call :draw_header
echo.
call :menu_item 1 "Full setup" "rename + make visible, previews first"
if "%NO_RENAME%"=="1" (
    echo    %C_R%[2]%C_0%  Rename this PC                       %C_R%BLOCKED - %GUARD_SHORT%%C_0%
) else (
    call :menu_item 2 "Rename this PC" "assign the next free %PREFIX% name"
)
call :menu_item 3 "Check the internet" "read only, changes nothing"
call :menu_item 4 "Make this PC visible on the network" ""
call :menu_item 5 "Name registry" "list / prefix / release"
call :menu_item 6 "Troubleshooting and info" ""
echo.
echo    %C_G%[0]%C_0%  Exit
echo.
echo  %C_D%--------------------------------------------------------------------%C_0%
set "SEL="
set /p "SEL=   Type a number and press Enter: "
if not defined SEL goto menu_empty
set "EMPTYIN=0"
if "%SEL%"=="1" ( call :act_full     & goto main_menu )
if "%SEL%"=="2" ( call :act_rename   & goto main_menu )
if "%SEL%"=="3" ( call :act_diag     & goto main_menu )
if "%SEL%"=="4" ( call :act_share    & goto main_menu )
if "%SEL%"=="5" ( call :menu_registry& goto main_menu )
if "%SEL%"=="6" ( call :menu_tools   & goto main_menu )
if "%SEL%"=="0" goto cleanup
goto main_menu

:menu_empty
rem A closed or redirected stdin returns nothing. Do not spin forever.
set /a "EMPTYIN+=1"
if !EMPTYIN! GEQ 3 goto cleanup
goto main_menu

rem --- one green numbered menu line
:menu_item
setlocal EnableDelayedExpansion
set "L=%~2                                   "
echo    %C_G%[%~1]%C_0%  !L:~0,35! %C_D%%~3%C_0%
endlocal
exit /b 0

rem --- banner and live machine state, redrawn on every screen
:draw_header
cls
call :probe_net_fast
set "DBCOUNT=0"
if exist "%DB_FILE%" for /f %%c in ('type "%DB_FILE%" ^| find /c /v "" 2^>nul') do set /a "DBCOUNT=%%c-1"
if !DBCOUNT! LSS 0 set "DBCOUNT=0"
echo.
echo  %C_C%=====================================================================%C_0%
echo    %C_W%TQNY IT SETUP TOOL%C_0%  v%TOOL_VERSION%
echo  %C_C%=====================================================================%C_0%
echo    Machine  : %C_W%%M_NAME%%C_0%      Model    : %M_MODEL%
echo    Network  : %H_NIC%  %H_IP%      Internet : %H_NET%
echo    Profile  : %H_CAT%
echo    Prefix   : %C_W%%PREFIX%%C_0%      Registry : !DBCOUNT! names assigned
if "%ADMIN%"=="0" echo    %C_Y%RUNNING WITHOUT ADMIN - changes are disabled%C_0%
if "%NO_RENAME%"=="1" echo    %C_R%PROTECTED MACHINE - this PC will never be renamed%C_0%
echo  %C_D%--------------------------------------------------------------------%C_0%
exit /b 0

rem --- fast network probe for the header. No pings, no web test.
:probe_net_fast
set "H_NIC=-"
set "H_IP=-"
set "H_CAT=-"
set "H_NET=-"
%PS% "$ErrorActionPreference='SilentlyContinue'; $a=Get-NetAdapter -Physical | Where-Object{$_.Status -eq 'Up'} | Sort-Object ifIndex | Select-Object -First 1; if(-not $a){'H_NIC=none'; exit}; 'H_NIC='+$a.Name; $c=Get-NetIPConfiguration -InterfaceIndex $a.ifIndex; 'H_IP='+$c.IPv4Address.IPAddress; $p=Get-NetConnectionProfile -InterfaceIndex $a.ifIndex; 'H_CAT='+$p.NetworkCategory; 'H_NET='+$p.IPv4Connectivity" > "%PSOUT%" 2>nul
for /f "usebackq tokens=1,* delims==" %%A in ("%PSOUT%") do set "%%A=%%B"
if /i "%H_CAT%"=="Public"  set "H_CAT=%C_Y%Public - NOT visible on the network%C_0%"
if /i "%H_CAT%"=="Private" set "H_CAT=%C_G%Private - visible on the network%C_0%"
if /i "%H_NET%"=="Internet" set "H_NET=%C_G%OK%C_0%"
exit /b 0

rem ---------------------------------------------------------------------------
rem  Menu actions
rem ---------------------------------------------------------------------------

:act_full
call :draw_header
set "MODE=preview"
call :step_guard
call :step_domain
call :step_alloc
call :step_diag
call :step_share
if "%ADMIN%"=="0" ( call :need_admin_msg & exit /b 0 )
if not defined TARGET ( call :pause_return & exit /b 0 )
echo.
call :confirm "   Apply the rename and the network visibility fix?"
if errorlevel 1 ( call :say "  Cancelled. Nothing was changed." & call :pause_return & exit /b 0 )
set "MODE=apply"
call :step_alloc
call :step_rename
call :step_share
call :step_summary
call :offer_reboot
set "MODE=preview"
call :pause_return
exit /b 0

:act_rename
call :draw_header
if "%NO_RENAME%"=="1" (
    echo.
    echo    %C_R%This PC is protected. Reason: %GUARD_HIT%%C_0%
    echo.
    echo    The rename is refused here by design, so the tool can be used on
    echo    other machines without any risk to this one. To change that, edit
    echo    PROTECTED_NAMES / PROTECTED_MACS at the top of this script.
    call :pause_return
    exit /b 0
)
set "MODE=preview"
call :step_guard
call :step_domain
call :step_alloc
if "%ADMIN%"=="0" ( call :need_admin_msg & exit /b 0 )
if not defined TARGET ( call :pause_return & exit /b 0 )
if /i "%TARGET%"=="%M_NAME%" ( call :pause_return & exit /b 0 )
echo.
call :confirm "   Rename %M_NAME% to %TARGET%?"
if errorlevel 1 ( call :say "  Cancelled. Nothing was changed." & call :pause_return & exit /b 0 )
set "MODE=apply"
call :step_alloc
call :step_rename
call :offer_reboot
set "MODE=preview"
call :pause_return
exit /b 0

:act_diag
call :draw_header
call :step_diag
call :pause_return
exit /b 0

:act_share
call :draw_header
set "MODE=preview"
call :step_share
if "%ADMIN%"=="0" ( call :need_admin_msg & exit /b 0 )
echo.
call :confirm "   Apply the network visibility fix?"
if errorlevel 1 ( call :say "  Cancelled. Nothing was changed." & call :pause_return & exit /b 0 )
set "MODE=apply"
call :step_share
set "MODE=preview"
call :pause_return
exit /b 0

:need_admin_msg
echo.
echo    %C_Y%Not running as Administrator, so nothing can be applied.%C_0%
echo    Close this window and start the tool again, choosing Yes at the
echo    Administrator prompt.
call :pause_return
exit /b 0

rem ---------------------------------------------------------------------------
rem  Sub-menu: name registry
rem ---------------------------------------------------------------------------
:menu_registry
call :draw_header
echo.
call :menu_item 1 "Show all assigned names" ""
call :menu_item 2 "Change the name prefix" "currently %PREFIX%"
call :menu_item 3 "Release this PC's number" "does not rename anything"
call :menu_item 4 "Use a different registry file" ""
echo.
echo    %C_G%[0]%C_0%  Back
echo.
echo  %C_D%--------------------------------------------------------------------%C_0%
set "SEL="
set /p "SEL=   Type a number and press Enter: "
if not defined SEL ( set /a "EMPTYIN+=1" & if !EMPTYIN! GEQ 3 exit /b 0 )
if "%SEL%"=="1" ( call :draw_header & call :do_list & call :pause_return & goto menu_registry )
if "%SEL%"=="2" ( call :act_prefix  & goto menu_registry )
if "%SEL%"=="3" ( call :act_release & goto menu_registry )
if "%SEL%"=="4" ( call :act_dbpath  & goto menu_registry )
if "%SEL%"=="0" exit /b 0
goto menu_registry

:act_prefix
call :draw_header
echo.
echo    Names are built as PREFIX-NN, for example %PREFIX%-01, %PREFIX%-02.
echo    Each prefix has its own numbering, so ACME-01 and TQNY-01 can
echo    both exist. Letters, digits and hyphens only, 12 characters max.
echo.
set "NEWPFX="
set /p "NEWPFX=   New prefix, or press Enter to keep %PREFIX%: "
if not defined NEWPFX exit /b 0
set "OLDPFX=%PREFIX%"
set "PREFIX=%NEWPFX%"
call :validate_prefix
if errorlevel 1 (
    set "PREFIX=%OLDPFX%"
    set "EXITCODE=0"
    echo.
    echo    %C_Y%Keeping %OLDPFX%.%C_0%
) else (
    echo.
    echo    %C_G%Prefix is now %PREFIX%. Names will look like %PREFIX%-01.%C_0%
)
call :pause_return
exit /b 0

:act_release
call :draw_header
call :do_release
call :pause_return
exit /b 0

:act_dbpath
call :draw_header
echo.
echo    Current registry file:
echo      %DB_FILE%
echo.
echo    Point this at a file on a share when two of you work at once.
echo.
set "NEWDB="
set /p "NEWDB=   New full path, or press Enter to keep it: "
if not defined NEWDB exit /b 0
set "DB_FILE=%NEWDB%"
call :set_db_paths
echo.
echo    %C_G%Registry file is now:%C_0%
echo      %DB_FILE%
call :pause_return
exit /b 0

rem ---------------------------------------------------------------------------
rem  Sub-menu: troubleshooting and info
rem ---------------------------------------------------------------------------
:menu_tools
call :draw_header
echo.
call :menu_item 1 "Full machine detail" "fingerprint, MAC, UUID, serial"
call :menu_item 2 "Network detail" "every adapter, IP, DNS"
call :menu_item 3 "Discovery service status" ""
call :menu_item 4 "Open the log folder" ""
call :menu_item 5 "Command-line switches" "for scripted use"
echo.
echo    %C_G%[0]%C_0%  Back
echo.
echo  %C_D%--------------------------------------------------------------------%C_0%
set "SEL="
set /p "SEL=   Type a number and press Enter: "
if not defined SEL ( set /a "EMPTYIN+=1" & if !EMPTYIN! GEQ 3 exit /b 0 )
if "%SEL%"=="1" ( call :info_machine & goto menu_tools )
if "%SEL%"=="2" ( call :info_network & goto menu_tools )
if "%SEL%"=="3" ( call :info_services & goto menu_tools )
if "%SEL%"=="4" ( start "" "%LOG_DIR%" & goto menu_tools )
if "%SEL%"=="5" ( call :draw_header & call :show_switches & call :pause_return & goto menu_tools )
if "%SEL%"=="0" exit /b 0
goto menu_tools

:info_machine
call :draw_header
call :hdr "Machine detail"
call :say "  Computer name    : %M_NAME%"
call :say "  Model            : %M_MODEL%"
call :say "  Domain / group   : %M_DOMAIN%     domain-joined: %M_INDOMAIN%"
call :say ""
call :say "  Fingerprint      : %FP%"
call :say "  Taken from       : %FPTYPE%   adapter: %M_NIC%"
call :say "  Onboard NIC MAC  : %M_MAC%"
call :say "  System UUID      : %M_UUID%"
call :say "  Board serial     : %M_SERIAL%"
call :say ""
call :say "  The fingerprint is how this PC is recognised in the registry, so"
call :say "  running the tool twice never burns a second number. Virtual"
call :say "  adapters from VMware, VirtualBox and Tailscale are ignored on"
call :say "  purpose - their MACs are identical on every PC that has them."
call :pause_return
exit /b 0

:info_network
call :draw_header
call :hdr "Network detail"
%PS% "$ErrorActionPreference='SilentlyContinue'; Get-NetAdapter | Sort-Object ifIndex | Format-Table -AutoSize Name,Status,LinkSpeed,MacAddress,InterfaceDescription | Out-String -Width 200" > "%PSOUT%" 2>nul
for /f "usebackq delims=" %%L in ("%PSOUT%") do call :say "%%L"
%PS% "$ErrorActionPreference='SilentlyContinue'; Get-NetIPConfiguration | Format-List InterfaceAlias,IPv4Address,IPv4DefaultGateway,DNSServer | Out-String -Width 200" > "%PSOUT%" 2>nul
for /f "usebackq delims=" %%L in ("%PSOUT%") do call :say "%%L"
call :pause_return
exit /b 0

:info_services
call :draw_header
call :hdr "Discovery services"
call :say "  These must run for this PC to appear under Network on other PCs."
call :say ""
%PS% "$ErrorActionPreference='SilentlyContinue'; Get-Service FDResPub,fdPHost,SSDPSRV,upnphost,LanmanServer,LanmanWorkstation | Format-Table -AutoSize Name,Status,StartType,DisplayName | Out-String -Width 200" > "%PSOUT%" 2>nul
for /f "usebackq delims=" %%L in ("%PSOUT%") do call :say "%%L"
call :pause_return
exit /b 0

:show_switches
echo.
echo   %C_C%TQNY-Setup.bat  v%TOOL_VERSION%   command-line switches%C_0%
echo.
echo     no options       Open the menu.
echo     /apply           Apply the rename and the network visibility fix.
echo     /list            Show the name registry and exit.
echo     /release         Return this machine's number to the pool.
echo.
echo     /prefix:ACME     Use a different name prefix, giving ACME-01, ACME-02.
echo                      Default is %TQNY_PREFIX%. Each prefix numbers separately.
echo     /ask             Ask for the prefix on screen before doing anything.
echo     /name:07         Force a specific number instead of the next free one.
echo     /site:JED        Tag this machine with a site code in the registry.
echo     /db:PATH         Use a different registry file, e.g. on a shared drive.
echo.
echo     /no-share        Skip the network visibility step.
echo     /reboot          Reboot automatically after a successful rename.
echo     /no-reboot       Never reboot and never ask.
echo     /force-domain    Allow renaming a domain-joined PC. Asks for creds.
echo     /menu            Force the menu even with other switches present.
echo.
echo   Anything passed on the command line runs without the menu, so existing
echo   scripts and shortcuts keep working. The internet check is ALWAYS read
echo   only. It never changes network configuration.
echo.
exit /b 0


rem ===========================================================================
rem  STEPS - shared by the menu and the command line
rem ===========================================================================

rem --- STEP 1  Protection guard
:step_guard
call :hdr "1. Protection check"
for %%P in (%PROTECTED_MACS%)  do if /i "%%P"=="%M_MAC%"  ( set "NO_RENAME=1" & set "GUARD_HIT=protected MAC %%P" )
for %%P in (%PROTECTED_NAMES%) do if /i "%%P"=="%M_NAME%" ( set "NO_RENAME=1" & set "GUARD_HIT=protected name %%P" )
if not "%NO_RENAME%"=="1" goto g_clear
call :say "  ***********************************************************"
call :say "  *  PROTECTED MACHINE - THE RENAME IS BLOCKED"
call :say "  *  matched on: %GUARD_HIT%"
call :say "  *  This PC will NOT be renamed, even with /apply."
call :say "  ***********************************************************"
goto g_done
:g_clear
call :say "  [OK] Not a protected machine. Rename is permitted."
:g_done
call :say ""
exit /b 0

rem --- STEP 2  Domain check
:step_domain
call :hdr "2. Domain check"
if /i not "%M_INDOMAIN%"=="True" goto d_workgroup
if "%FORCE_DOMAIN%"=="1" (
    call :say "  [WARN] Domain-joined. /force-domain given, will ask for domain credentials."
    goto d_done
)
set "NO_RENAME=1"
if not defined GUARD_HIT set "GUARD_HIT=domain-joined"
call :say "  [SKIP] This PC is joined to domain %M_DOMAIN%."
call :say "         Renaming without domain credentials breaks the computer account."
call :say "         Re-run with /force-domain if you really want to rename it."
goto d_done
:d_workgroup
call :say "  [OK] Workgroup machine. Rename is safe."
:d_done
call :say ""
exit /b 0

rem --- STEP 3  Allocate the name
:step_alloc
call :hdr "3. Name allocation"
set "TARGET="
call :db_lock
if errorlevel 1 goto a_after
call :db_init
call :db_scan

if defined FOUND_OTHER (
    call :say "  [WARN] This PC is already registered as %FOUND_OTHER%, under another prefix."
    call :say "         It will be given a new %PREFIX% name and the old entry released."
)
if not defined FOUND_NAME goto a_new
set "TARGET=%FOUND_NAME%"
call :say "  [OK] Already in the registry as %TARGET%, number %FOUND_NUM%."
call :say "       Reusing that name. No new number is consumed."
goto a_done

:a_new
if not defined FORCE_NUM goto a_auto
set "N=%FORCE_NUM%"
call :pad %N%
call :check_len "%PADDED_NAME%"
if errorlevel 1 goto a_done
if defined NUM_%N% goto a_forcetaken
call :name_free "%PADDED_NAME%"
if errorlevel 1 goto a_forceonlan
set "TARGET=%PADDED_NAME%"
call :say "  [OK] Forced number %N% gives %TARGET%."
goto a_done
:a_forcetaken
call :say "  [FAIL] Number %N% is already used in the registry. Pick another."
set "EXITCODE=3"
goto a_done
:a_forceonlan
call :say "  [FAIL] %PADDED_NAME% already answers on this network. Pick another."
set "EXITCODE=3"
goto a_done

:a_auto
set "N=0"
:a_next
set /a "N+=1"
if !N! GTR 500 (
    call :say "  [FAIL] No free number below 500. Check the registry file."
    set "EXITCODE=3"
    goto a_done
)
if defined NUM_!N! goto a_next
call :pad !N!
call :check_len "!PADDED_NAME!"
if errorlevel 1 goto a_done
rem Gate 2: is that name already alive on this network?
call :name_free "!PADDED_NAME!"
if not errorlevel 1 goto a_got
call :say "  [BUSY] !PADDED_NAME! already answers on this network. Reserving it and moving on."
if "%MODE%"=="apply" >>"%DB_FILE%" echo !N!,!PADDED_NAME!,RESERVED-external,LAN,-,-,-,%NOW%,%NOW%,%TECH%,%SITE%
set "NUM_!N!=1"
goto a_next
:a_got
set "TARGET=!PADDED_NAME!"
call :say "  [OK] Next free number is !N!, giving !TARGET!."

:a_done
if not defined TARGET goto a_claim
if /i "%TARGET%"=="%M_NAME%" (
    call :say "  [OK] The name is already correct. Nothing to rename."
) else (
    call :say "  Proposed rename: %M_NAME%  ->  %TARGET%"
)

:a_claim
if not "%MODE%"=="apply" goto a_preview
if not defined TARGET goto a_end
if "%NO_RENAME%"=="1" goto a_blocked
if defined FOUND_NUM goto a_touch
if defined FOUND_OTHER call :db_drop_fp
>>"%DB_FILE%" echo %N%,%TARGET%,%FP%,%FPTYPE%,%M_NAME%,%M_MODEL%,%M_SERIAL%,%NOW%,%NOW%,%TECH%,%SITE%
call :say "  [OK] Claimed %TARGET% in the registry."
goto a_end
:a_touch
call :db_touch
call :say "  [OK] Registry row refreshed for %TARGET%."
goto a_end
:a_blocked
call :say "  [SKIP] Not claiming a number. This machine is protected from rename."
goto a_end
:a_preview
if defined TARGET call :say "  [PREVIEW] Would claim %TARGET%. The registry file is NOT modified."
:a_end
call :db_unlock

:a_after
call :say ""
exit /b 0

rem --- STEP 4  Rename
:step_rename
call :hdr "4. Rename"
if not defined TARGET (
    call :say "  [SKIP] No name was allocated, so there is nothing to rename."
    goto r_after
)
if /i "%TARGET%"=="%M_NAME%" (
    call :say "  [SKIP] This PC is already named %TARGET%."
    goto r_after
)
if "%NO_RENAME%"=="1" (
    call :say "  [BLOCKED] Rename refused. Reason: %GUARD_HIT%"
    call :say "            %M_NAME% keeps its current name."
    goto r_after
)
if not "%MODE%"=="apply" (
    call :say "  [PREVIEW] Would rename %M_NAME% to %TARGET%."
    goto r_after
)
if "%FORCE_DOMAIN%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try{Rename-Computer -NewName '%TARGET%' -DomainCredential (Get-Credential -Message 'Domain account allowed to rename this computer') -Force -ErrorAction Stop; 'RC=OK'}catch{'RC=FAIL'; $_.Exception.Message}" > "%PSOUT%" 2>&1
) else (
    %PS% "try{Rename-Computer -NewName '%TARGET%' -Force -ErrorAction Stop; 'RC=OK'}catch{'RC=FAIL'; $_.Exception.Message}" > "%PSOUT%" 2>&1
)
findstr /b /c:"RC=OK" "%PSOUT%" >nul 2>&1
if not errorlevel 1 (
    set "RENAMED=1"
    call :say "  [OK] Renamed to %TARGET%. It takes effect after a reboot."
    goto r_after
)
call :say "  [WARN] Rename-Computer failed. Trying the wmic fallback..."
wmic computersystem where "name='%M_NAME%'" call rename name="%TARGET%" >nul 2>&1
if not errorlevel 1 (
    set "RENAMED=1"
    call :say "  [OK] Renamed to %TARGET% via wmic. It takes effect after a reboot."
    goto r_after
)
call :say "  [FAIL] Could not rename this PC. Details follow."
for /f "usebackq delims=" %%L in ("%PSOUT%") do call :say "         %%L"
set "EXITCODE=4"
:r_after
call :say ""
exit /b 0

rem --- STEP 5  Internet check, READ ONLY
:step_diag
call :hdr "5. Internet check - read only, nothing is changed"
%PS% "$ErrorActionPreference='SilentlyContinue'; function E($v){$s=[string]$v; if($s.Trim()){($s -replace '[^A-Za-z0-9 ._:,/-]','').Trim()}else{'-'}}; $a=Get-NetAdapter -Physical | Where-Object{$_.Status -eq 'Up'} | Sort-Object ifIndex | Select-Object -First 1; if(-not $a){'D_NIC=NONE'; exit}; 'D_NIC='+(E $a.Name); 'D_DESC='+(E $a.InterfaceDescription); 'D_SPEED='+(E $a.LinkSpeed); $c=Get-NetIPConfiguration -InterfaceIndex $a.ifIndex; 'D_IPV4='+(E $c.IPv4Address.IPAddress); 'D_GW='+(E $c.IPv4DefaultGateway.NextHop); 'D_DNS='+(E ((($c.DNSServer | Where-Object{$_.AddressFamily -eq 2}).ServerAddresses) -join ' ')); 'D_DHCP='+(E (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4).Dhcp); 'D_CAT='+(E (Get-NetConnectionProfile -InterfaceIndex $a.ifIndex).NetworkCategory)" > "%PSOUT%" 2>nul
set "D_NIC=-"
set "D_DESC=-"
set "D_SPEED=-"
set "D_IPV4=-"
set "D_GW=-"
set "D_DNS=-"
set "D_DHCP=-"
set "D_CAT=-"
for /f "usebackq tokens=1,* delims==" %%A in ("%PSOUT%") do set "%%A=%%B"

if not "%D_NIC%"=="NONE" goto x_havenic
call :say "  [FAIL] No physical network adapter is connected."
call :say "         Check the cable or connect Wi-Fi, then run this again."
set "DNS_OK=NO"
set "WEB_OK=NO"
goto x_after

:x_havenic
call :say "  Adapter    : %D_NIC%   %D_DESC%"
call :say "  Link speed : %D_SPEED%"
call :say "  IPv4       : %D_IPV4%      DHCP: %D_DHCP%"
call :say "  Gateway    : %D_GW%"
call :say "  DNS        : %D_DNS%"
call :say "  Profile    : %D_CAT%"
if "%D_IPV4%"=="-" goto x_noip
echo %D_IPV4%| findstr /b /c:"169.254." >nul 2>&1
if not errorlevel 1 (
    call :say "  [FAIL] %D_IPV4% is a self-assigned address. DHCP is not answering."
) else (
    call :say "  [OK]   Has a real IPv4 address."
)
goto x_gw
:x_noip
call :say "  [FAIL] No IPv4 address. This PC got nothing from DHCP."

:x_gw
if "%D_GW%"=="-" goto x_nogw
ping -n 2 -w 1000 %D_GW% >nul 2>&1
if not errorlevel 1 (
    call :say "  [OK]   Gateway %D_GW% replies."
) else (
    call :say "  [FAIL] Gateway %D_GW% does not reply."
)
goto x_route
:x_nogw
call :say "  [FAIL] No default gateway. This PC cannot leave the local network."

:x_route
ping -n 2 -w 1500 1.1.1.1 >nul 2>&1
if not errorlevel 1 (
    call :say "  [OK]   Internet routing works. 1.1.1.1 replies."
) else (
    call :say "  [FAIL] Cannot reach 1.1.1.1. Routing is broken or the line is down."
)
%PS% "$ErrorActionPreference='SilentlyContinue'; try{[void][System.Net.Dns]::GetHostEntry('www.microsoft.com'); 'DNS_OK=YES'}catch{'DNS_OK=NO'}; $r=$null; try{$r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Uri 'http://www.msftconnecttest.com/connecttest.txt'}catch{}; if($r -and $r.Content -match 'Microsoft Connect Test'){'WEB_OK=YES'}else{'WEB_OK=NO'}" > "%PSOUT%" 2>nul
set "DNS_OK=NO"
set "WEB_OK=NO"
for /f "usebackq tokens=1,* delims==" %%A in ("%PSOUT%") do set "%%A=%%B"
if "%DNS_OK%"=="YES" (
    call :say "  [OK]   DNS resolution works."
) else (
    call :say "  [FAIL] DNS is not resolving names. Check the DNS servers listed above."
)
if "%WEB_OK%"=="YES" (
    call :say "  [OK]   Real internet access confirmed."
) else (
    call :say "  [FAIL] No usable internet access. The web test failed."
)
if "%DNS_OK%%WEB_OK%"=="YESYES" (
    call :say "  INTERNET STATUS: GOOD"
) else (
    call :say "  INTERNET STATUS: PROBLEM. See the FAIL lines above. Nothing was changed."
)
:x_after
call :say ""
exit /b 0

rem --- STEP 6  Network visibility
:step_share
call :hdr "6. Network visibility - be seen on the network"
if "%WANT_SHARE%"=="1" goto s_go
call :say "  [SKIP] /no-share was given."
goto s_after
:s_go
if "%MODE%"=="apply" goto s_apply
call :say "  [PREVIEW] Would do all of the following:"
call :say "     - set the connected physical adapter to the Private profile"
call :say "       it is currently %D_CAT% on %D_NIC%"
call :say "     - enable the Network Discovery firewall group for Private"
call :say "     - enable the File and Printer Sharing firewall group for Private"
call :say "     - set the discovery services to start automatically"
call :say "  Existing shared folders are never touched."
goto s_after

:s_apply
%PS% "try{Get-NetAdapter -Physical | Where-Object{$_.Status -eq 'Up'} | ForEach-Object{Set-NetConnectionProfile -InterfaceIndex $_.ifIndex -NetworkCategory Private -ErrorAction Stop}; 'SP=OK'}catch{'SP=FAIL'}" > "%PSOUT%" 2>nul
findstr /b /c:"SP=OK" "%PSOUT%" >nul 2>&1
if not errorlevel 1 (
    call :say "  [OK] Connected adapter set to the Private profile."
) else (
    call :say "  [FAIL] Could not set the network profile to Private."
)
rem Group IDs, not display names. Display names are translated on localised Windows.
%PS% "$ok=$true; foreach($g in '@FirewallAPI.dll,-32752','@FirewallAPI.dll,-28502'){try{Get-NetFirewallRule -Group $g -ErrorAction Stop | Where-Object{$_.Profile -match 'Private'} | Set-NetFirewallRule -Enabled True -ErrorAction Stop}catch{$ok=$false}}; if($ok){'FW=OK'}else{'FW=FAIL'}" > "%PSOUT%" 2>nul
findstr /b /c:"FW=OK" "%PSOUT%" >nul 2>&1
if not errorlevel 1 (
    call :say "  [OK] Network Discovery and File and Printer Sharing enabled for Private."
    goto s_svc
)
call :say "  [WARN] Group IDs failed. Falling back to English rule-group names..."
netsh advfirewall firewall set rule group="Network Discovery" new enable=Yes >nul 2>&1
netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes >nul 2>&1
if not errorlevel 1 (
    call :say "  [OK] Enabled via the netsh fallback."
) else (
    call :say "  [FAIL] Could not enable the discovery firewall rules."
)
:s_svc
set "SVC_BAD=0"
for %%S in (FDResPub fdPHost SSDPSRV upnphost LanmanServer LanmanWorkstation) do (
    sc config %%S start= auto >nul 2>&1
    if errorlevel 1 set "SVC_BAD=1"
    sc start %%S >nul 2>&1
)
if "%SVC_BAD%"=="0" (
    call :say "  [OK] Discovery services set to Automatic and started."
) else (
    call :say "  [WARN] One or more discovery services could not be reconfigured."
)
call :say "  [OK] Existing shared folders left untouched."
:s_after
call :say ""
exit /b 0

rem --- STEP 7  Summary
:step_summary
call :hdr "7. Summary"
call :say "  Mode          : %MODE%"
call :say "  Prefix used   : %PREFIX%"
call :say "  Name before   : %M_NAME%"
if defined TARGET (
    call :say "  Name after    : %TARGET%"
) else (
    call :say "  Name after    : unchanged"
)
if "%NO_RENAME%"=="1" call :say "  Rename        : BLOCKED - %GUARD_HIT%"
call :say "  Internet      : DNS=%DNS_OK%  WEB=%WEB_OK%"
call :say "  Log file      : %LOG%"
call :say ""
exit /b 0

:offer_reboot
if not "%RENAMED%"=="1" exit /b 0
call :say "  A REBOOT IS REQUIRED before the new name becomes active."
if "%WANT_REBOOT%"=="yes" (
    call :say "  Rebooting in 10 seconds..."
    shutdown /r /t 10 /c "TQNY-Setup: applying the new computer name"
    exit /b 0
)
if not "%WANT_REBOOT%"=="ask" exit /b 0
call :confirm "  Reboot now?"
if not errorlevel 1 shutdown /r /t 5 /c "TQNY-Setup: applying the new computer name"
exit /b 0

rem ---------------------------------------------------------------------------
rem  /list  and  /release
rem ---------------------------------------------------------------------------
:do_list
call :hdr "Name registry"
if not exist "%DB_FILE%" (
    call :say "  The registry file does not exist yet:"
    call :say "  %DB_FILE%"
    exit /b 0
)
call :say "  Num  Name          Fingerprint       Old name    First seen           Site"
call :say "  ---- ------------- ----------------- ----------- -------------------- ------"
for /f "usebackq skip=1 tokens=1-11 delims=," %%a in ("%DB_FILE%") do call :listrow "%%a" "%%b" "%%c" "%%e" "%%h" "%%k"
call :say ""
exit /b 0

:do_release
call :hdr "Release this machine's number"
call :db_lock
if errorlevel 1 exit /b 0
call :db_init
call :db_scan
if not defined FOUND_NAME (
    call :say "  [SKIP] This machine is not in the registry. Nothing to release."
    call :db_unlock
    exit /b 0
)
> "%DB_TMP%" echo %CSV_HEADER%
for /f "usebackq skip=1 tokens=1-11 delims=," %%a in ("%DB_FILE%") do (
    if /i not "%%c"=="%FP%" >>"%DB_TMP%" echo %%a,%%b,%%c,%%d,%%e,%%f,%%g,%%h,%%i,%%j,%%k
)
move /y "%DB_TMP%" "%DB_FILE%" >nul
call :say "  [OK] Released %FOUND_NAME%, number %FOUND_NUM%. That number is free again."
call :say "       The computer name itself was NOT changed."
call :db_unlock
exit /b 0


rem ===========================================================================
rem  Helpers
rem ===========================================================================

rem --- ANSI colour. Falls back to empty strings if the console cannot do it.
:init_colors
set "ESC="
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
if not defined ESC (
    set "C_R=" & set "C_G=" & set "C_Y=" & set "C_C=" & set "C_W=" & set "C_D=" & set "C_0="
    exit /b 0
)
set "C_R=%ESC%[91m"
set "C_G=%ESC%[92m"
set "C_Y=%ESC%[93m"
set "C_C=%ESC%[96m"
set "C_W=%ESC%[97m"
set "C_D=%ESC%[90m"
set "C_0=%ESC%[0m"
exit /b 0

rem --- derive the registry folder, lock and temp file from DB_FILE
:set_db_paths
for %%I in ("%DB_FILE%") do set "DB_DIR=%%~dpI"
if "%DB_DIR:~-1%"=="\" set "DB_DIR=%DB_DIR:~0,-1%"
set "LOCK_DIR=%DB_DIR%\.tqny.lock"
set "DB_TMP=%WORK%\db.csv"
exit /b 0

rem --- relaunch this script with admin rights, keeping the arguments
:relaunch_elevated
if defined ALLARGS (
    %PS% "Start-Process -FilePath '%~f0' -ArgumentList '%ALLARGS% /elevated' -WorkingDirectory '%SCRIPT_DIR%' -Verb RunAs"
) else (
    %PS% "Start-Process -FilePath '%~f0' -ArgumentList '/elevated' -WorkingDirectory '%SCRIPT_DIR%' -Verb RunAs"
)
if errorlevel 1 (
    echo [FAIL] Elevation was cancelled or failed. Nothing was changed.
    set "EXITCODE=1"
    exit /b 1
)
echo [OK] Continuing in the elevated window.
exit /b 0

rem --- read machine facts and build the hardware fingerprint
:gather_facts
md "%LOG_DIR%" 2>nul
%PS% "$ErrorActionPreference='SilentlyContinue'; function E($v){$s=[string]$v; if($s.Trim()){($s -replace '[^A-Za-z0-9 ._:-]','').Trim()}else{'-'}}; $cs=Get-CimInstance Win32_ComputerSystem; 'NAME='+(E $cs.Name); 'INDOMAIN='+(E $cs.PartOfDomain); 'DOMAIN='+(E $cs.Domain); 'MODEL='+(E $cs.Model); $bs=[string](Get-CimInstance Win32_BaseBoard).SerialNumber; if($bs -match 'Default string|To be filled|None'){$bs=''}; 'SERIAL='+(E $bs); 'UUID='+(E (Get-CimInstance Win32_ComputerSystemProduct).UUID); $a=Get-NetAdapter -Physical | Where-Object{$_.MacAddress} | Sort-Object @{e={if($_.MediaType -eq '802.3'){0}else{1}}},ifIndex | Select-Object -First 1; 'MAC='+(E ($a.MacAddress -replace '[^A-Fa-f0-9]','')); 'NIC='+(E $a.Name)" > "%PSOUT%" 2>nul
set "M_NAME=-"
set "M_INDOMAIN=False"
set "M_DOMAIN=-"
set "M_MODEL=-"
set "M_SERIAL=-"
set "M_UUID=-"
set "M_MAC=-"
set "M_NIC=-"
for /f "usebackq tokens=1,* delims==" %%A in ("%PSOUT%") do set "M_%%A=%%B"
if "%M_NAME%"=="-" set "M_NAME=%COMPUTERNAME%"
rem Fingerprint: onboard NIC MAC first, then system UUID, then board serial.
set "FP="
set "FPTYPE="
if not "%M_MAC%"=="-" ( set "FP=%M_MAC%" & set "FPTYPE=MAC" )
if not defined FP if not "%M_UUID%"=="-"   ( set "FP=%M_UUID%"   & set "FPTYPE=UUID" )
if not defined FP if not "%M_SERIAL%"=="-" ( set "FP=%M_SERIAL%" & set "FPTYPE=SERIAL" )
if not defined FP (
    echo.
    echo [FAIL] Could not read a stable hardware ID from this machine.
    echo        No physical NIC MAC, no system UUID, no usable board serial.
    echo        Refusing to guess a name. Nothing was changed.
    set "EXITCODE=2"
    exit /b 1
)
rem Protection guard is evaluated here too so the menu can grey out the option.
for %%P in (%PROTECTED_MACS%)  do if /i "%%P"=="%M_MAC%"  ( set "NO_RENAME=1" & set "GUARD_SHORT=protected PC" & set "GUARD_HIT=protected MAC %%P" )
for %%P in (%PROTECTED_NAMES%) do if /i "%%P"=="%M_NAME%" ( set "NO_RENAME=1" & set "GUARD_SHORT=protected PC" & set "GUARD_HIT=protected name %%P" )
rem A domain rename needs domain credentials, so block it unless /force-domain.
if /i "%M_INDOMAIN%"=="True" if not "%FORCE_DOMAIN%"=="1" (
    set "NO_RENAME=1"
    set "GUARD_SHORT=domain-joined"
    if not defined GUARD_HIT set "GUARD_HIT=domain-joined"
)
rem Launched from the internet with no registry reachable: renaming would hand
rem out a number we cannot record, so refuse it until /db:PATH is supplied.
if "%REMOTE%"=="1" if not "%DB_EXPLICIT%"=="1" (
    rem Do not mask an earlier, more important reason such as a protected PC.
    if "!NO_RENAME!"=="0" (
        set "GUARD_SHORT=no registry"
        set "GUARD_HIT=launched from the internet with no name registry reachable - pass /db:PATH to enable renaming"
    )
    set "NO_RENAME=1"
)
%PS% "'U='+(Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'); 'S='+(Get-Date).ToString('yyyyMMdd-HHmmss')" > "%PSOUT%" 2>nul
for /f "usebackq tokens=1,* delims==" %%A in ("%PSOUT%") do (
    if "%%A"=="U" set "NOW=%%B"
    if "%%A"=="S" set "STAMP=%%B"
)
set "TECH=%USERNAME%"
exit /b 0

:open_log
set "LOG=%LOG_DIR%\%M_NAME%-%STAMP%.log"
>"%LOG%" echo TQNY-Setup v%TOOL_VERSION%  run %NOW% UTC  by %TECH%  mode=%MODE%
exit /b 0

rem --- Y/N question. errorlevel 0 means yes.
:confirm
set "ANS="
set /p "ANS=%~1 [Y/N]: "
if /i "!ANS!"=="Y" exit /b 0
exit /b 1

:pause_return
echo.
echo  %C_D%--------------------------------------------------------------------%C_0%
set "ANS="
set /p "ANS=   Press Enter to return to the menu: "
exit /b 0

rem --- zero-padded candidate name for a number -> PADDED_NAME
:pad
set "P=0%~1"
if %~1 GEQ 100 (
    set "PADDED_NAME=%PREFIX%-%~1"
) else (
    set "PADDED_NAME=%PREFIX%-!P:~-2!"
)
exit /b 0

rem --- length of %1 into the variable named by %2
:strlen
setlocal EnableDelayedExpansion
set "s=%~1"
set "len=0"
:strlen_loop
if defined s ( set "s=!s:~1!" & set /a "len+=1" & goto strlen_loop )
endlocal & set "%~2=%len%"
exit /b 0

rem --- check the prefix is usable as the start of a Windows computer name
:validate_prefix
:vp_strip
if "%PREFIX:~-1%"=="-" ( set "PREFIX=%PREFIX:~0,-1%" & goto vp_strip )
if not defined PREFIX (
    call :say "[ERROR] The name prefix is empty. Use something like /prefix:ACME"
    set "EXITCODE=1"
    exit /b 1
)
echo %PREFIX%| findstr /r /c:"^[A-Za-z0-9][A-Za-z0-9-]*$" >nul 2>&1
if errorlevel 1 (
    call :say "[ERROR] Prefix %PREFIX% is not valid. Use only letters, digits and hyphens,"
    call :say "        and start with a letter or digit. Example: /prefix:ACME"
    set "EXITCODE=1"
    exit /b 1
)
echo %PREFIX%| findstr /r /c:"^[0-9][0-9]*$" >nul 2>&1
if not errorlevel 1 (
    call :say "[ERROR] Prefix %PREFIX% is all digits. Windows rejects all-numeric names."
    set "EXITCODE=1"
    exit /b 1
)
call :strlen "%PREFIX%" PLEN
if %PLEN% GTR 12 (
    call :say "[ERROR] Prefix %PREFIX% is %PLEN% characters. Maximum is 12, because a"
    call :say "        Windows computer name cannot exceed 15 characters."
    set "EXITCODE=1"
    exit /b 1
)
exit /b 0

rem --- refuse a candidate that breaks the 15 character computer name limit
:check_len
call :strlen "%~1" NLEN
if %NLEN% GTR 15 (
    call :say "  [FAIL] %~1 is %NLEN% characters. A Windows computer name cannot exceed 15."
    call :say "         Use a shorter prefix."
    set "EXITCODE=3"
    exit /b 1
)
exit /b 0

rem --- is a name unused on this network?  errorlevel 1 means it is taken
:name_free
if /i "%~1"=="%M_NAME%" exit /b 0
%PS% "$ErrorActionPreference='SilentlyContinue'; try{[void][System.Net.Dns]::GetHostEntry('%~1'); 'R=TAKEN'}catch{'R=FREE'}" > "%WORK%\nf.txt" 2>nul
findstr /b /c:"R=TAKEN" "%WORK%\nf.txt" >nul 2>&1
if not errorlevel 1 exit /b 1
exit /b 0

rem --- acquire the registry lock. md is atomic: it fails if the dir exists.
:db_lock
if not exist "%DB_DIR%\" (
    call :say "  [FAIL] The registry folder does not exist:"
    call :say "  %DB_DIR%"
    set "EXITCODE=5"
    exit /b 1
)
set "T=0"
:db_lock_try
md "%LOCK_DIR%" 2>nul
if not errorlevel 1 (
    set "LOCK_HELD=1"
    exit /b 0
)
set /a "T+=1"
if !T!==1 (
    %PS% "$ErrorActionPreference='SilentlyContinue'; if(((Get-Date)-(Get-Item '%LOCK_DIR%').CreationTime).TotalMinutes -gt 10){'STALE=1'}" > "%WORK%\lk.txt" 2>nul
    findstr /b /c:"STALE=1" "%WORK%\lk.txt" >nul 2>&1
    if not errorlevel 1 (
        call :say "  [WARN] Breaking a stale lock older than 10 minutes."
        rd /s /q "%LOCK_DIR%" 2>nul
        goto db_lock_try
    )
)
if !T! GEQ %LOCK_TRIES% (
    call :say "  [FAIL] Another copy of this tool is using the registry. Try again shortly."
    set "EXITCODE=5"
    exit /b 1
)
ping -n 2 127.0.0.1 >nul 2>&1
goto db_lock_try

:db_unlock
if "%LOCK_HELD%"=="1" rd /s /q "%LOCK_DIR%" 2>nul
set "LOCK_HELD=0"
exit /b 0

rem --- create the registry file if missing. Only when we may write.
:db_init
if exist "%DB_FILE%" exit /b 0
if "%MODE%"=="apply" goto db_init_go
if "%DO_RELEASE%"=="1" goto db_init_go
exit /b 0
:db_init_go
> "%DB_FILE%" echo %CSV_HEADER%
if errorlevel 1 (
    call :say "  [WARN] Cannot write the registry file. The location is read-only."
    call :say "         Falling back to network-scan-only allocation, which is NOT durable."
) else (
    call :say "  [OK] Created a new registry file."
)
exit /b 0

rem Numbering is per prefix: only rows whose name starts with PREFIX- occupy a
rem number, so ACME-01 and TQNY-01 are independent and can both exist.
:db_scan
set "FOUND_NUM="
set "FOUND_NAME="
set "FOUND_OTHER="
rem Clear any NUM_ flags left by an earlier scan, e.g. after a prefix change.
for /f "delims==" %%v in ('set NUM_ 2^>nul') do set "%%v="
if not exist "%DB_FILE%" exit /b 0
set "PFX=%PREFIX%-"
call :strlen "%PFX%" PFXLEN
for /f "usebackq skip=1 tokens=1-11 delims=," %%a in ("%DB_FILE%") do (
    set "RN=%%b"
    set "SAMEPFX=0"
    if /i "!RN:~0,%PFXLEN%!"=="%PFX%" set "SAMEPFX=1"
    if "!SAMEPFX!"=="1" if not "%%a"=="" set "NUM_%%a=1"
    if /i "%%c"=="%FP%" (
        if "!SAMEPFX!"=="1" (
            set "FOUND_NUM=%%a"
            set "FOUND_NAME=%%b"
        ) else (
            set "FOUND_OTHER=%%b"
        )
    )
)
exit /b 0

rem --- drop every row belonging to this machine, used when re-branding
:db_drop_fp
if not exist "%DB_FILE%" exit /b 0
> "%DB_TMP%" echo %CSV_HEADER%
for /f "usebackq skip=1 tokens=1-11 delims=," %%a in ("%DB_FILE%") do (
    if /i not "%%c"=="%FP%" >>"%DB_TMP%" echo %%a,%%b,%%c,%%d,%%e,%%f,%%g,%%h,%%i,%%j,%%k
)
move /y "%DB_TMP%" "%DB_FILE%" >nul
exit /b 0

rem --- refresh LastSeen / Tech / Site on this machine's own row
:db_touch
if not exist "%DB_FILE%" exit /b 0
> "%DB_TMP%" echo %CSV_HEADER%
for /f "usebackq skip=1 tokens=1-11 delims=," %%a in ("%DB_FILE%") do (
    if /i "%%c"=="%FP%" (
        >>"%DB_TMP%" echo %%a,%%b,%%c,%%d,%%e,%%f,%%g,%%h,%NOW%,%TECH%,%SITE%
    ) else (
        >>"%DB_TMP%" echo %%a,%%b,%%c,%%d,%%e,%%f,%%g,%%h,%%i,%%j,%%k
    )
)
move /y "%DB_TMP%" "%DB_FILE%" >nul
exit /b 0

rem --- one padded row of /list output
:listrow
setlocal EnableDelayedExpansion
set "L1=%~1    "
set "L2=%~2             "
set "L3=%~3                 "
set "L4=%~4           "
set "L5=%~5                    "
call :say "  !L1:~0,4! !L2:~0,13! !L3:~0,17! !L4:~0,11! !L5:~0,20! %~6"
endlocal
exit /b 0

rem --- output helpers. Delayed expansion keeps brackets and parens safe.
:hdr
setlocal EnableDelayedExpansion
set "MSG=%~1"
echo(
echo(%C_C%=== !MSG! ===%C_0%
if defined LOG (
    >>"%LOG%" echo(
    >>"%LOG%" echo(=== !MSG! ===
)
endlocal
exit /b 0

:say
setlocal EnableDelayedExpansion
set "MSG=%~1"
echo(!MSG!
if defined LOG >>"%LOG%" echo(!MSG!
endlocal
exit /b 0

rem ===========================================================================
:cleanup
call :db_unlock
:hardexit
if exist "%WORK%" rd /s /q "%WORK%" 2>nul
if "%PAUSE_END%"=="1" (
    echo.
    pause
)
endlocal & exit /b %EXITCODE%
