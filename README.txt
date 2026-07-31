===========================================================================
 TQNY-Setup   v2.0   -   TQNY IT provisioning tool
===========================================================================

 Run it on a PC and it does three things:

   1. Renames the PC to PREFIX-01, PREFIX-02 ... and guarantees that no two
      machines ever end up with the same name.
   2. Checks whether the internet on that PC actually works. READ ONLY -
      it reports problems and never changes a network setting.
   3. Makes the PC visible on the network so you can reach its shares.


---------------------------------------------------------------------------
 THREE WAYS TO RUN IT
---------------------------------------------------------------------------

 1. THE MENU  -  double-click TQNY-Setup.bat, or the "TQNY Setup" shortcut
    on your Desktop. You get a menu and pick a number. Nothing to remember.

 2. FROM THE INTERNET  -  on any PC with internet, open PowerShell and run
    the one-liner from the GITHUB section below. No USB needed.

 3. SWITCHES  -  for scripting. Any switch on the command line skips the
    menu. See COMMAND-LINE SWITCHES below.


---------------------------------------------------------------------------
 THE MENU
---------------------------------------------------------------------------

  =====================================================================
    TQNY IT SETUP TOOL  v2.0
  =====================================================================
    Machine  : ZW0V              Model    : B650M AORUS ELITE AX
    Network  : Ethernet  192.168.100.2     Internet : OK
    Profile  : Public - NOT visible on the network
    Prefix   : TQNY              Registry : 3 names assigned
  ---------------------------------------------------------------------

    [1]  Full setup            rename + make visible, previews first
    [2]  Rename this PC        assign the next free TQNY name
    [3]  Check the internet    read only, changes nothing
    [4]  Make this PC visible on the network
    [5]  Name registry         list / prefix / release
    [6]  Troubleshooting and info

    [0]  Exit

 The top of the screen always shows the live state of the PC you are on,
 so you can see the problem before you fix it. A Public profile is the
 usual reason a PC cannot be seen on the network.

 NOTHING IS CHANGED UNTIL YOU CONFIRM. Every option that would change the
 PC shows you exactly what it plans to do, then asks Y/N. Answer anything
 other than Y and nothing happens.

 The tool asks for Administrator rights once when it starts. If you say no
 it still opens, in read-only mode, and says so in yellow - checking and
 reporting all still work, only the changes are disabled.

 [5] NAME REGISTRY
     [1] show every name handed out so far
     [2] change the prefix, so names become ACME-01 instead of TQNY-01
     [3] release this PC's number back to the pool (does NOT rename)
     [4] point at a registry file on a share, for two techs at once

 [6] TROUBLESHOOTING AND INFO
     [1] full machine detail - fingerprint, MAC, UUID, board serial
     [2] network detail - every adapter, IP, DNS
     [3] discovery service status - why a PC is not visible
     [4] open the log folder
     [5] the command-line switches


---------------------------------------------------------------------------
 CHANGING THE PREFIX - names other than TQNY-
---------------------------------------------------------------------------

 Names are always built as  PREFIX-NN. Default is TQNY, giving TQNY-01,
 TQNY-02. Change it three ways:

   * In the menu: [5] then [2].
   * On the command line, for one run:   TQNY-Setup.bat /prefix:ACME
   * Permanently: edit this line near the top of TQNY-Setup.bat
         set "TQNY_PREFIX=TQNY"

 EACH PREFIX HAS ITS OWN NUMBERING. ACME-01 and TQNY-01 are different
 machines and can both exist. A new prefix starts again at 01 and is not
 blocked by numbers used under other prefixes, so you can keep a separate
 run of numbers per customer, per site or per room.

 Rules, because Windows is strict about computer names:
   * Letters, digits and hyphens only. No spaces, no underscores.
   * Must not be all digits.
   * 12 characters maximum, since the whole name cannot exceed 15.
   * A trailing hyphen is ignored, so ACME and ACME- are the same.

 RE-BRANDING. If a PC is already registered as TQNY-07 and you switch to
 prefix ACME, the tool says so, gives it a fresh ACME number, and releases
 TQNY-07 so that number can be used again.


---------------------------------------------------------------------------
 HOW "NO TWO PCs WITH THE SAME NAME" IS GUARANTEED
---------------------------------------------------------------------------

 Two independent checks must agree before a number is used.

 GATE 1 - the registry file (TQNY-Names.csv, next to the script)
   Every number ever handed out is recorded. The tool takes the lowest
   number not already used BY THAT PREFIX. Numbers stay reserved even when
   the PC is switched off, unplugged, or on the other side of town.

 GATE 2 - the live network
   Before committing, the tool asks the network whether that name already
   answers. If a PC named TQNY-04 replies - one you set up last year whose
   registry row got lost - it marks 04 as taken and moves to 05.

 Each machine is identified by a hardware fingerprint from the onboard
 network card. Two consequences:

   * Running the tool twice on the same PC gives the SAME name both times.
     It does not burn a new number. Safe to re-run.

   * Virtual adapters from VMware, VirtualBox, Hyper-V and Tailscale are
     deliberately ignored. Their MAC addresses are identical on every PC
     that has those products installed, so using one would hand the same
     name to two different machines - the exact thing we are preventing.

 If a PC has no usable network card the tool falls back to the system UUID,
 then the motherboard serial. If none can be read it stops and refuses to
 guess.


---------------------------------------------------------------------------
 THE REGISTRY FILE - TQNY-Names.csv
---------------------------------------------------------------------------

 Plain CSV, opens in Excel. One row per machine:

   Number,AssignedName,Fingerprint,FpType,OldName,Model,Serial,
   FirstSeenUTC,LastSeenUTC,Tech,Site

 So it doubles as your asset list: what the PC was called before, its
 model, who set it up, when, and at which site.

 A row whose Fingerprint says RESERVED-external is a number Gate 2 found
 alive on some network. It is held so it is never reused.

 BACK THIS FILE UP. Losing it does not break anything - Gate 2 still
 catches live machines - but you lose the record of PCs that are switched
 off, and numbering may restart lower.

 TWO TECHNICIANS AT ONCE: put the file on a share and point both at it,
 with menu [5] [4] or /db:. The tool takes a lock while it allocates, so
 you cannot both grab the same number. If someone else holds the lock you
 get "Another copy of this tool is using the registry" - just try again.


---------------------------------------------------------------------------
 GITHUB AND THE ONE-LINER
---------------------------------------------------------------------------

 On any PC with internet, open PowerShell and run:

   irm https://raw.githubusercontent.com/zw0v/tqny-setup/main/tqny.ps1 | iex

 That downloads the tool to a temp folder and opens the same menu. Nothing
 is installed and the temp copy is deleted afterwards.

 IMPORTANT - RENAMING IS DISABLED IN THIS MODE. Launched from the internet
 there is no registry file reachable, so the tool would be handing out a
 number it cannot record - which is exactly how two PCs end up with the
 same name. It says so plainly and still does the internet check and the
 network-visibility fix, which need no registry.

 To enable renaming, point it at a registry file you control first:

   $env:TQNY_DB = '\\server\share\TQNY-Names.csv'
   irm https://raw.githubusercontent.com/zw0v/tqny-setup/main/tqny.ps1 | iex

 The repo must be PUBLIC for the one-liner to work without a token.


---------------------------------------------------------------------------
 COMMAND-LINE SWITCHES
---------------------------------------------------------------------------

 Any switch skips the menu.

   no options       Open the menu.
   /apply           Apply the rename and the network visibility fix.
   /list            Show the name registry and exit.
   /release         Return this machine's number to the pool.

   /prefix:ACME     Use a different prefix, giving ACME-01, ACME-02, ...
   /ask             Ask for the prefix on screen before doing anything.
   /name:07         Force a specific number instead of the next free one.
   /site:JED        Tag this machine with a site code in the registry.
   /db:PATH         Use a different registry file.
   /menu            Force the menu even with other switches present.
   /remote          Used by the one-liner. Disables renaming unless /db is
                    also given.

   /no-share        Skip the network visibility step.
   /reboot          Reboot automatically after a successful rename.
   /no-reboot       Never reboot and never ask.
   /force-domain    Allow renaming a domain-joined PC. Asks for creds.

 Typical scripted job:

   TQNY-Setup.bat /apply /site:JED
   TQNY-Setup.bat /apply /prefix:WORKSHOP /db:\\srv\it$\TQNY-Names.csv

 A rename only becomes active after a reboot. The tool tells you and
 offers to reboot.


---------------------------------------------------------------------------
 THE INTERNET CHECK NEVER CHANGES ANYTHING
---------------------------------------------------------------------------

 It reports adapter, link speed, IPv4, DHCP on/off, gateway, DNS servers
 and network profile, then tests four things separately so you can tell
 what is actually broken:

   gateway replies      - is the local network alive
   1.1.1.1 replies      - is routing to the internet alive, no DNS involved
   DNS resolves a name  - is DNS working
   web page loads       - is there real, usable internet

 It deliberately does NOT run flushdns, does NOT renew DHCP and does NOT
 reset the network stack. It tells you what is wrong and stops.

 It also flags a 169.254.x.x address, which means DHCP never answered.


---------------------------------------------------------------------------
 NETWORK VISIBILITY - WHAT IT ACTUALLY CHANGES
---------------------------------------------------------------------------

   * Sets the connected physical adapter to the Private profile. This is
     almost always the real reason a PC cannot be seen. On Public, Windows
     blocks discovery no matter how the shares are set up.
   * Enables the Network Discovery and File and Printer Sharing firewall
     groups for the Private profile. Public stays locked down.
   * Sets the discovery services to start automatically so the PC is still
     visible after a reboot: FDResPub, fdPHost, SSDPSRV, upnphost,
     LanmanServer, LanmanWorkstation.

 It does NOT create, remove or change any shared folder. It does NOT
 enable SMB1. Existing shares are left exactly as they are.


---------------------------------------------------------------------------
 PROTECTED MACHINES
---------------------------------------------------------------------------

 Some PCs must never be renamed. They are listed at the top of
 TQNY-Setup.bat:

     set "PROTECTED_MACS=74563CC0AE41"
     set "PROTECTED_NAMES=ZW0V"

 On such a machine the menu shows option [2] in red as BLOCKED, and the
 rename is refused even with /apply. It also does not consume a number.

 Add more by appending to either list, separated by spaces. MACs go in
 without colons or dashes, in uppercase.


---------------------------------------------------------------------------
 DOMAIN-JOINED PCs
---------------------------------------------------------------------------

 The tool refuses to rename a domain-joined PC by default, because doing
 it without domain credentials breaks the computer account in AD. It says
 so and carries on with the other steps.

 To rename one anyway use /force-domain. It prompts for a domain account
 with permission to rename computer objects.


---------------------------------------------------------------------------
 LOGS
---------------------------------------------------------------------------

 Every run writes logs\<PCNAME>-<date>-<time>.log. It contains what was
 printed on screen, so you have a record of which machine got which name
 and what its network looked like at the time.


---------------------------------------------------------------------------
 EXIT CODES - for scripting
---------------------------------------------------------------------------

   0   success
   1   bad command line, or elevation refused
   2   could not read a hardware ID, refused to guess a name
   3   name allocation failed, e.g. the forced number was taken
   4   the rename itself failed
   5   could not get the registry lock, or the registry folder is missing


---------------------------------------------------------------------------
 IF SOMETHING LOOKS WRONG
---------------------------------------------------------------------------

 "Another copy of this tool is using the registry"
     Someone else is allocating a number, or a previous run was killed.
     Run it again. A lock older than 10 minutes is broken automatically.

 "Cannot write the registry file. The location is read-only."
     The USB stick or share is write protected. Numbers cannot be recorded,
     so only Gate 2 protects you. Fix write access before going on.

 "Could not read a stable hardware ID"
     No network card, no system UUID, no board serial. Nothing was changed.
     Name that PC by hand.

 The PC still is not visible after applying
     Reboot it. Then check the PC you are browsing from is also on Private
     and that both are on the same subnet.

 The menu looks like garbage, with [92m symbols everywhere
     The console does not support colour. Rare on Windows 10 and 11. The
     tool still works; only the colours are wrong.

 EDITING THE SCRIPT
     Keep it saved with Windows line endings (CRLF). A .bat saved with Unix
     line endings misbehaves badly - cmd jumps to the wrong lines.
