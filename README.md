# TQNY-Setup

A single-file Windows provisioning tool for IT technicians. Run it on a PC and it:

1. **Renames** the machine to `TQNY-01`, `TQNY-02`, … and guarantees no two machines ever get the same name.
2. **Checks the internet** — strictly read-only. It reports what is broken and changes nothing.
3. **Makes the PC visible on the network** so its shares can be reached.

Menu-driven, no install, no dependencies beyond what ships with Windows.

---

## Run it

**On any PC with internet** — open PowerShell and run:

```powershell
irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex
```

**From a USB stick or local folder** — double-click `TQNY-Setup.bat`.

**Scripted** — any switch skips the menu:

```bat
TQNY-Setup.bat /apply /site:JED
```

---

## The menu

```
 =====================================================================
   TQNY IT SETUP TOOL  v3.0
   tqnyprofile.com   CR 7049547834   Maroof #358680
 =====================================================================

   [1]  Full setup                  rename + make visible
   [2]  Rename this PC              next number, or type a name
   [3]  Network                     internet / visibility / remote access
   [4]  Standard PC setup           power, time, drives, printer
   [5]  Health check                disk, updates, antivirus, BitLocker
   [6]  System info + handover report
   [7]  Name registry               list / prefix / release
   [8]  Troubleshooting and info

   [0]  Exit
```

The banner deliberately shows **no machine, network or registry detail** — nothing identifying appears on screen. That information is available on demand under `[8] Troubleshooting`.

**Nothing changes until you confirm.** Every option that would modify the PC previews exactly what it plans to do, then asks Y/N.

Administrator rights are requested once at startup. Decline and it still opens in read-only mode — checking and reporting work, changes are disabled.

### What each section does

**[3] Network** — the read-only internet check; the visibility fix; enable Remote Desktop (warns first, and refuses to pretend a Public network is safe); and connection details showing the hostname, every IP, RDP state and who is logged on.

**[4] Standard PC setup** — the repetitive jobs on a new office PC, each confirmed separately: never-sleep power plan, time zone + clock resync, computer description, map a network drive, add a network printer.

**[5] Health check** — entirely read-only. Windows build and uptime, activation status, disk SMART health, free space with a low-space flag, antivirus, BitLocker, pending-reboot detection, battery, and a count of critical events in the last 7 days.

**[6] System info + handover report** — full specification, then writes a customer handover sheet to `handover\` carrying your CR, Maroof number, site and contact details, what the PC was called before and after, its specs and the network as handed over. Proof of work to leave behind.

---

## How name collisions are prevented

Two independent gates must agree before a number is used.

**Gate 1 — the registry file.** `TQNY-Names.csv` sits next to the script and records every number ever handed out. The tool takes the lowest number not already used *by that prefix*. Numbers stay reserved even when the PC is powered off or at another site.

**Gate 2 — the live network.** Before committing, the tool asks the network whether the name already answers. If a `TQNY-04` replies — a machine whose registry row was lost — that number is marked taken and it moves on.

Machines are identified by a hardware fingerprint from the onboard NIC, so:

- Re-running on the same PC returns the **same name**. It never burns a second number.
- **Virtual adapters are deliberately ignored.** VMware, VirtualBox, Hyper-V and Tailscale adapters report as physical to WMI, and their MACs are *identical on every machine* with those products installed. Fingerprinting one would hand the same name to two different PCs — precisely the failure this tool exists to prevent. Detection uses `Get-NetAdapter -Physical`.

Fallback order if there is no usable NIC: system UUID, then motherboard serial. If none can be read it stops rather than guess.

### Numbered or free-form names

`[2] Rename this PC` offers both:

```
   [1]  Take the next free number    prefix TQNY, e.g. TQNY-04
   [2]  Type a name myself           e.g. RECEPTION-PC
```

A typed name goes through exactly the same safety as a numbered one — Windows naming rules (1–15 chars, letters/digits/hyphens, not all digits, no trailing hyphen), rejected if it is already in the registry, and rejected if it already answers on the network. It is then recorded so it is collision-checked forever after.

Free-form rows are stored with `Number` = `0`, meaning they belong to no numbered sequence: they never consume a number, and the machine is still recognised by fingerprint whatever the current prefix is. Scripted equivalent: `/setname:RECEPTION-PC`.

### Prefixes

Names are `PREFIX-NN`. Change the prefix in the menu (`[7]` → `[2]`), per run with `/prefix:ACME`, or permanently by editing `TQNY_PREFIX` at the top of the script.

**Each prefix numbers independently** — `ACME-01` and `TQNY-01` are different machines and can coexist, so you can keep a separate run of numbers per customer or site.

Prefix rules, because Windows is strict about computer names: letters, digits and hyphens only; not all digits; 12 characters max (the full name cannot exceed 15). A trailing hyphen is ignored.

---

## Renaming is disabled in one-liner mode

Launched over the internet there is no registry file reachable, so the tool would be handing out a number it cannot record — exactly how two PCs end up sharing a name. It says so and refuses the rename. The internet check and the visibility fix need no registry and work normally.

To enable renaming, point it at a registry file you control:

```powershell
$env:TQNY_DB = '\\server\share\TQNY-Names.csv'
irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex
```

---

## Switches

| Switch | Effect |
|---|---|
| *(none)* | Open the menu |
| `/apply` | Apply the rename and the visibility fix |
| `/list` | Show the name registry |
| `/release` | Return this machine's number to the pool |
| `/prefix:ACME` | Use a different prefix |
| `/ask` | Ask for the prefix on screen |
| `/name:07` | Force a specific number |
| `/setname:NAME` | Use this exact computer name instead of numbering |
| `/site:JED` | Tag the machine with a site code |
| `/db:PATH` | Use a different registry file |
| `/menu` | Force the menu even with other switches |
| `/remote` | Used by the launcher; disables renaming unless `/db` is given |
| `/no-share` | Skip the visibility step |
| `/reboot` / `/no-reboot` | Reboot handling after a rename |
| `/force-domain` | Allow renaming a domain-joined PC (prompts for credentials) |

Exit codes: `0` ok · `1` bad command line or elevation refused · `2` no readable hardware ID · `3` allocation failed · `4` rename failed · `5` registry lock unavailable.

---

## What the visibility fix actually changes

- Sets the connected **physical** adapter to the Private profile. Virtual adapters are left alone.
- Enables the Network Discovery and File and Printer Sharing firewall groups **for Private only**. Public stays locked down. Uses language-independent group IDs (`@FirewallAPI.dll,-32752` / `-28502`) so it works on non-English Windows.
- Sets discovery services to start automatically so visibility survives a reboot: `FDResPub`, `fdPHost`, `SSDPSRV`, `upnphost`, `LanmanServer`, `LanmanWorkstation`.

It does **not** create, remove or alter any shared folder, and does **not** enable SMB1.

## What the internet check does

Reports adapter, link speed, IPv4, DHCP state, gateway, DNS servers and profile, then tests four things separately so you can tell which layer is broken: gateway reply, `1.1.1.1` reply (routing, no DNS), DNS resolution, and a real web fetch. A `169.254.x.x` address is flagged as DHCP not answering.

It never runs `flushdns`, never renews DHCP, and never resets the network stack.

---

## Safety

- **Protected machines.** `PROTECTED_NAMES` / `PROTECTED_MACS` at the top of the script list PCs that must never be renamed. On those the menu shows the rename option in red as blocked, the rename is refused even with `/apply`, and no number is consumed.
- **Domain-joined PCs** are refused by default — renaming without domain credentials breaks the AD computer account. `/force-domain` overrides and prompts for credentials.
- **Concurrent technicians.** Put the registry on a share and point both copies at it. An atomic lock is held during allocation, so two people cannot claim the same number.
- The registry CSV, the logs and the handover sheets are `.gitignore`d — they hold customer machine data and are never published.
- **Hosting.** The repo is private. Distribution is a **secret gist**: not listed on the profile, not indexed by search, reachable only by its link. That is *hidden, not secure* — anyone given the link can read it and pass it on. There are no credentials or customer data in the script, so this is an acceptable trade, but it is not access control.
- Run `push-tqny.bat` after editing, so the private repo and the gist cannot drift apart. The raw URL is cached for roughly 5 minutes.

## Note when editing

Keep the `.bat` saved with **CRLF** line endings. `cmd.exe` seeks labels by byte offset, so a `.bat` with Unix line endings jumps to the wrong lines and misbehaves in ways that look like logic bugs. `.gitattributes` enforces this, and the launcher re-normalises after download.
