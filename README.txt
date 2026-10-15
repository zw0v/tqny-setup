===========================================================================
 TQNY-Setup   v4.0   -   TQNY IT Setup (Windows app)
 tqnyprofile.com   CR 7049547834   Maroof #358680
===========================================================================

 One window for everything a technician does on a PC before and after a
 format: rename, network, Wi-Fi, sharing, printers, apps, Windows Update,
 drivers, firewall, activation, backup / restore, repair and cleanup.

 No install. Windows 10 / 11. One file: TQNY-Setup.ps1


---------------------------------------------------------------------------
 RUN IT
---------------------------------------------------------------------------

 1. FROM A USB / FOLDER  -  double-click TQNY-Setup.bat

 2. FROM THE INTERNET  -  open PowerShell on the PC and run:

      irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex

 3. SCRIPTED / OLD MENU  -  every v3.2 switch still works:

      TQNY-Setup.bat /apply /site:JED
      TQNY-Setup.bat /classic          (the v3.2 cmd menu)

 Administrator is asked for ONCE at start. Say No and it opens read-only:
 checks, scans and reports work, changes are disabled.


---------------------------------------------------------------------------
 THE PAGES (left sidebar)
---------------------------------------------------------------------------

 SETUP
   Dashboard        this PC at a glance - read only
   Quick setup      the post-format checklist, run in one go, with presets
   Apps             ~50 apps by winget, update all, app lists, USB installers,
                    remove junk apps
   Windows Update   check / install all / drivers / pause / reset
   PC setup         rename, workgroup/domain, time zone, Arabic keyboard,
                    power, Explorer, users, .NET 3.5, restore point

 NETWORK
   Network          internet check, scan, static IP / DHCP, DNS presets,
                    repairs, make visible, Remote Desktop
   Wi-Fi            connect, saved passwords, back up / restore networks
   Sharing          shared folder, password-protected sharing, NAS fix
                    (Win11 24H2), SMB1, saved logins, network drives
   Printers         find, add (IPP driverless / TCP-IP / shared), test,
                    default, share, clear queue, 0x11b / 0x709 fix, drivers

 SYSTEM
   Security         firewall, ports, Defender, BitLocker recovery keys
   Activation       Windows / Office status and genuine-key activation
   Drivers          problem devices, Windows Update drivers, maker page,
                    back up / install drivers from a folder
   Backup/restore   before the format: files, bookmarks, Wi-Fi, drivers,
                    apps, printers, Outlook, keys. After: put it all back.
   Repair           DISM + SFC, chkdsk, Windows Update / network / Start
                    menu / icon / time repairs, errors, blue screens,
                    restart into BIOS / Advanced Startup / Safe Mode
   Cleanup          temp, update cache, Disk Cleanup, WinSxS, Recycle Bin

 INFO
   Reports          customer handover sheet (HTML + TXT), system info,
                    health check, battery report, installed programs
   Tools            one click to every Windows admin console, Sysinternals
   Names/settings   name registry, prefix, technician, site code


---------------------------------------------------------------------------
 RULES THE TOOL KEEPS
---------------------------------------------------------------------------

 - Nothing changes until you confirm. Dangerous buttons are red.
 - Jobs run in the background: the window never freezes, the log is live,
   and Stop cancels the job.
 - Every session is logged to logs\PCNAME-date.log.
 - Every change is listed on the handover sheet as "work carried out".
 - Renaming never hands out a number it cannot record, never collides with
   a name already on the network, and never touches a protected PC.
   The name registry TQNY-Names.csv is shared with the classic tool.
 - Backup and restore only COPY. They never delete.


---------------------------------------------------------------------------
 FILES - keep them together in one folder
---------------------------------------------------------------------------

   TQNY-Setup.bat            double-click this
   TQNY-Setup.ps1            the app
   TQNY-Classic.bat          the v3.2 console tool (scripted use)
   scan-source.ps1           scan helper for the classic tool
   printer-scan-source.ps1   scan helper for the classic tool
   tqny.ps1                  the internet launcher
   push-tqny.bat             publish to GitHub + the gist after editing

 The tool writes logs\, handover\, presets\, reports\ and TQNY-Names.csv
 next to itself (C:\ProgramData\TQNY-Setup when launched from the internet).

 Protected PCs: edit $PROTECTED_MACS / $PROTECTED_NAMES at the top of
 TQNY-Setup.ps1 AND PROTECTED_MACS / PROTECTED_NAMES in TQNY-Classic.bat.


---------------------------------------------------------------------------
 TQNY Company - Software Licenses & Hardware Solutions
 tqnyprofile.com  -  tqny.store  -  info@tqny.store  -  +966 58 032 4564
---------------------------------------------------------------------------
