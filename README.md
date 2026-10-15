# TQNY-Setup v4.0

A Windows app for IT technicians. One window for everything you do on a PC before and after a format: rename, network, Wi-Fi, sharing, printers, apps, Windows Update, drivers, firewall, activation, backup / restore, repair and cleanup.

No install and no dependencies beyond what ships with Windows 10 / 11. It is a single PowerShell file (`TQNY-Setup.ps1`) with a real window (WPF), a sidebar, tick-boxes and a live log.

---

## Run it

**On any PC with internet** — open PowerShell and run:

```powershell
irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex
```

**From a USB stick or local folder** — double-click `TQNY-Setup.bat`.

Administrator is asked for **once**, at start. Say No and the app still opens in read-only mode: every check, scan and report works, changes are disabled.

**Scripted / the old menu** — every v3.2 switch still works and goes to the classic console tool:

```bat
TQNY-Setup.bat /apply /site:JED
TQNY-Setup.bat /classic
```

---

## The window

```
 +--------------+--------------------------------------------------------+
 | TQNY         |  Page title                        [PC-NAME] [Restart] |
 | IT Setup 4.0 |  what this page does                                   |
 |              |--------------------------------------------------------|
 | SETUP        |  +-- card -------------------------------------------+ |
 |  Dashboard   |  | Title                                             | |
 |  Quick setup |  | [ input ] [ input ]  [x] option  [x] option       | |
 |  Apps        |  | [ Action tile ] [ Action tile ] [ Action tile ]   | |
 |  Win Update  |  +---------------------------------------------------+ |
 |  PC setup    |                                                        |
 | NETWORK      |========================================================|
 |  Network     |  * Running: Windows Update - 3/12  [====    ]  [Stop]  |
 |  Wi-Fi       |  === Install Windows updates ===                       |
 |  Sharing     |    [OK]    Installed update: 2026-10 Cumulative ...    |
 |  Printers    |    [FAIL]  ...                                         |
 | SYSTEM ...   |                                                        |
 +--------------+--------------------------------------------------------+
```

* **Every job runs in the background** — the window never freezes, the log streams live, a progress bar shows where it is, and **Stop** cancels it (and kills any tool it started).
* **Nothing changes until you confirm.** Anything that modifies the PC asks first; dangerous actions are red and say exactly what they do. Read-only checks just run.
* Every session is written to `logs\PCNAME-date.log`. **Copy log / Save log** put the whole log on the clipboard or in a file.
* Everything the tool changes is collected as **"work done"** and printed on the customer handover sheet.

---

## Pages

| Page | What it does |
|---|---|
| **Dashboard** | Name, model, serial, Windows + build, activation, CPU, RAM, storage, IP, internet, antivirus/firewall, driver problems, UEFI / Secure Boot / TPM, uptime and pending restart — read only. |
| **Quick setup** | The post-format checklist. Tick what this PC needs and run it all in one go: restore a backup, rename, time zone, never-sleep, network visibility, allow ping, Remote Desktop, Explorer settings, Fast Startup off, Arabic keyboard, .NET 3.5, remove junk apps, shared folder, install apps, activate Windows, all Windows updates, driver updates, cleanup, restore point, handover sheet. **Presets** save the ticks + app choices ("Office PC", "Reception") for the next PC. |
| **Apps** | ~50 popular apps by category (browsers, Office/PDF, 7-Zip/WinRAR, VLC, WhatsApp/Zoom/Teams, AnyDesk/RustDesk, VC++/.NET/Java runtimes, IT tools…) installed silently with **winget**. Install / repair winget itself, update all apps, search and install any winget ID, save the app list on the old PC and install the same list on the new one, run every installer in a USB folder, remove built-in junk apps. Add your own apps with `tqny-apps.csv`. |
| **Windows Update** | Check, install all (one by one, with progress), drivers from Windows Update, optional Office/Microsoft Update, history, pause 7 days, resume, off, reset Windows Update components. Uses the built-in Windows Update Agent — no module to install. |
| **PC setup** | Rename (registry-checked, below), description, workgroup / domain join, time zone + clock sync, regional format, Arabic keyboard, power (never sleep, high performance, Fast Startup, hibernation, lid), Explorer (extensions, hidden files, This PC, desktop icons, Win11 classic right-click menu, taskbar left), local users (create, password, admin, built-in Administrator), .NET 3.5, restore point. |
| **Network** | The read-only internet check, connection details, adapters, public IP, ping / trace / DNS / port test, **network scan**, static IP or DHCP, DNS presets (Google, Cloudflare, Quad9, OpenDNS, AdGuard), repairs (flush DNS, renew, proxy reset, restart adapters, Winsock/TCP-IP reset), make visible, Private/Public, Remote Desktop, hosts file. |
| **Wi-Fi** | Status, networks in range, connect (WPA2/WPA3/open/hidden), **saved Wi-Fi passwords**, back up every network to a folder and restore after the format, forget, Wi-Fi report. |
| **Sharing** | Create a shared folder (Everyone RW, Everyone read-only, or one user with a password — also the scan-to-folder setup for MFPs), list / stop shares, password-protected sharing ON/OFF, the **Windows 11 24H2 "cannot access NAS / old share" fix** (guest + SMB signing), SMB1 on/off, saved logins for servers, map / disconnect network drives. |
| **Printers** | Find printers & scanners (ports 9100/515/631, SNMP model, eSCL), add by **IPP driverless**, TCP/IP + driver, or `\\PC\Printer`, test page, default printer (and stop Windows changing it), share, remove, clear stuck jobs, restart spooler, **fix 0x0000011b / 0x00000709 / 0x00000bcb**, vendor driver pages (HP/Samsung, Kyocera, Develop, Konica Minolta, Canon, Epson, Brother, Ricoh, Xerox, Sharp, Lexmark), install a driver from a folder, Windows Fax and Scan. |
| **Security** | Firewall status / on / off per profile, allow ping, open ports, allow a program, TQNY rules (all rules this tool adds are in group `TQNY`), reset; Defender status, quick / full scan, signature update, real-time on/off (Tamper-aware), exclusions; BitLocker status, **recovery keys**, suspend, turn off. |
| **Activation** | Windows status, the OEM key stored in the BIOS, activate with a key or with the BIOS key; Office status and activation. Genuine keys only. |
| **Drivers** | Devices with problems (code 28 etc.), installed third-party drivers, rescan, drivers from Windows Update, the manufacturer's support page for this exact model, Intel / AMD / NVIDIA pages, **back up all drivers and install them from a folder after the format**. |
| **Backup and restore** | Before the format: user folders (follows OneDrive redirection), browser bookmarks, Wi-Fi + passwords, drivers, the app list, printers with ports and drivers (PrintBrm), Outlook signatures / PST / Sticky Notes, and a PC-info file with the OEM key, BitLocker keys, mapped drives and IP settings. After the format: put it all back. Copies only — never deletes. |
| **Repair** | DISM + SFC, check disk / schedule full repair, optimise drives, reset Windows Update, reset network, restart Explorer, rebuild icon cache, repair Start menu, reset Store, repair Windows Time, recent errors, blue screens, reliability history; restart now / **into BIOS** / into Advanced Startup / Safe Mode, memory test. |
| **Cleanup** | Temp, Windows Update cache, Prefetch / thumbnails / delivery cache, Disk Cleanup (all safe options — never Downloads), WinSxS, Recycle Bin; shows MB freed. Biggest files, startup apps. |
| **Reports** | **Customer handover sheet** — printable HTML (+ .txt) with your company details, customer, spec, network as handed over, and every change made this session. System info, health check, battery report, installed programs CSV. |
| **Tools** | One click to Device Manager, Disk Management, Services, Event Viewer, Registry, Group Policy, Credential Manager, admin CMD / PowerShell and more; Sysinternals Autoruns / Process Explorer / TCPView on demand; the classic console menu. |
| **Names and settings** | The name registry (list, release, open), name prefix, registry file (local or on a share), technician name and site code (remembered), data folder. |

---

## How name collisions are prevented

Unchanged from v3.x, and shared with the classic tool:

* **Gate 1 — the registry file.** `TQNY-Names.csv` next to the tool records every number ever handed out, per prefix. Numbers stay reserved while the PC is off or at another site.
* **Gate 2 — the live network.** Before committing, the name is looked up on the network. If it already answers, that number is reserved and the next one is tried.
* Machines are recognised by a **hardware fingerprint** (onboard NIC MAC, then system UUID, then board serial). Virtual adapters (VMware, VirtualBox, Hyper-V, Tailscale) are ignored — their MACs are identical on every PC. Re-running on the same PC returns the same name.
* **Typed names** (e.g. `RECEPTION-PC`) get the same checks: Windows naming rules, not already in the registry, not answering on the network. They are stored with Number `0`.
* An atomic lock (`.tqny.lock`) stops two technicians claiming the same number when the registry sits on a share.
* **Protected PCs** (`$PROTECTED_MACS` / `$PROTECTED_NAMES` at the top of `TQNY-Setup.ps1`, and `PROTECTED_MACS` / `PROTECTED_NAMES` in `TQNY-Classic.bat` — keep both lists the same) are never renamed. **Domain PCs** need the "Domain PC" tick and domain credentials.
* **Internet launch** has no registry, so renaming is off until you set one (Names and settings, or `$env:TQNY_DB` before the one-liner).

---

## Files

| File | |
|---|---|
| `TQNY-Setup.ps1` | **The app.** Everything is in this one file. |
| `TQNY-Setup.bat` | Double-click launcher. Passes v3.2 switches to the classic tool. |
| `TQNY-Classic.bat` | The v3.2 console menu, kept for scripted use. |
| `scan-source.ps1`, `printer-scan-source.ps1` | Network / printer scan helpers for the classic tool (the app has its own copy built in). |
| `tqny.ps1` | The internet one-liner launcher. `$env:TQNY_CLASSIC='1'` opens the classic menu instead. |
| `push-tqny.bat` | Publishes to the repo **and** the secret gist in one go. Run it after any edit. In a folder that is not a git clone yet, it connects the folder to the repo first. Results go to `push-tqny.log`. |

Data the app writes, next to the tool (or in `C:\ProgramData\TQNY-Setup` when launched from the internet): `logs\`, `handover\`, `presets\`, `reports\`, `tools\`, `tqny-settings.json`, and the registry `TQNY-Names.csv`. Customer data is `.gitignore`d.

Your own apps for the Apps page: `tqny-apps.csv` next to the tool:

```
Category,Name,Id,Source
Engineering,FreeCAD,FreeCAD.FreeCAD,
Chat,Discord,Discord.Discord,
```

---

## Safety

* The internet check, network scan, printer scan, health check and every "show / list / status" button are **read only**.
* No piracy: activation uses genuine product keys only.
* Firewall rules the tool adds are all in group `TQNY`, so "Remove TQNY rules" takes away exactly what it added.
* Backup and restore **copy**; they never delete. Disk Cleanup never touches the Downloads folder or the Recycle Bin (that is a separate, confirmed, red option).
* Hosting is a **secret gist**: not listed, not indexed, reachable only by its link — hidden, not secure. There are no credentials or customer data in the files.

## Notes when editing

* `TQNY-Setup.ps1` is **pure ASCII** on purpose: Windows PowerShell 5.1 reads BOM-less files as ANSI, so any fancy character (— ’ ✓) would turn into garbage.
* Keep the `.bat` files with **CRLF** line endings — `cmd.exe` seeks labels by byte offset. `.gitattributes` enforces this, `push-tqny.bat` re-normalises, and the launcher fixes downloads.
* Inside the app, background jobs only see `$sync`, `$Cfg`, `$Facts` and their parameters (`$P`). Add new worker functions inside `$WorkerLib`; add buttons with `Add-Tiles` on a page.

---

## What's new in v4.0

* A real Windows app window instead of the cmd menu, with background jobs, live log, progress and Stop.
* New pages: Quick setup (with presets), Apps (winget), Windows Update, Wi-Fi, Sharing, Security, Activation, Drivers, Backup and restore, Repair, Cleanup, Tools.
* Fixes over v3.2: driverless printers now really use IPP (`Add-Printer -IppURL`); shares work on Arabic Windows (the Everyone group is resolved from its SID); the rename fallback uses CIM instead of `wmic` (removed in Windows 11 24H2); handover sheets are no longer lost when launched from the internet; mapped drives made from the elevated tool show up in Explorer.
* v3.2 is preserved as `TQNY-Classic.bat`, and all its switches still work through `TQNY-Setup.bat`.
