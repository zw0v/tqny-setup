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
irm https://raw.githubusercontent.com/zw0v/tqny-setup/main/tqny.ps1 | iex
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
```

The header shows the live state of the PC you are on, so you see the problem before fixing it. A `Public` profile is the usual reason a PC cannot be seen on the network.

**Nothing changes until you confirm.** Every option that would modify the PC previews exactly what it plans to do, then asks Y/N.

Administrator rights are requested once at startup. Decline and it still opens in read-only mode — checking and reporting work, changes are disabled.

---

## How name collisions are prevented

Two independent gates must agree before a number is used.

**Gate 1 — the registry file.** `TQNY-Names.csv` sits next to the script and records every number ever handed out. The tool takes the lowest number not already used *by that prefix*. Numbers stay reserved even when the PC is powered off or at another site.

**Gate 2 — the live network.** Before committing, the tool asks the network whether the name already answers. If a `TQNY-04` replies — a machine whose registry row was lost — that number is marked taken and it moves on.

Machines are identified by a hardware fingerprint from the onboard NIC, so:

- Re-running on the same PC returns the **same name**. It never burns a second number.
- **Virtual adapters are deliberately ignored.** VMware, VirtualBox, Hyper-V and Tailscale adapters report as physical to WMI, and their MACs are *identical on every machine* with those products installed. Fingerprinting one would hand the same name to two different PCs — precisely the failure this tool exists to prevent. Detection uses `Get-NetAdapter -Physical`.

Fallback order if there is no usable NIC: system UUID, then motherboard serial. If none can be read it stops rather than guess.

### Prefixes

Names are `PREFIX-NN`. Change the prefix in the menu (`[5]` → `[2]`), per run with `/prefix:ACME`, or permanently by editing `TQNY_PREFIX` at the top of the script.

**Each prefix numbers independently** — `ACME-01` and `TQNY-01` are different machines and can coexist, so you can keep a separate run of numbers per customer or site.

Prefix rules, because Windows is strict about computer names: letters, digits and hyphens only; not all digits; 12 characters max (the full name cannot exceed 15). A trailing hyphen is ignored.

---

## Renaming is disabled in one-liner mode

Launched over the internet there is no registry file reachable, so the tool would be handing out a number it cannot record — exactly how two PCs end up sharing a name. It says so and refuses the rename. The internet check and the visibility fix need no registry and work normally.

To enable renaming, point it at a registry file you control:

```powershell
$env:TQNY_DB = '\\server\share\TQNY-Names.csv'
irm https://raw.githubusercontent.com/zw0v/tqny-setup/main/tqny.ps1 | iex
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
- The registry CSV and logs are `.gitignore`d — they hold customer machine data and are never published.

## Note when editing

Keep the `.bat` saved with **CRLF** line endings. `cmd.exe` seeks labels by byte offset, so a `.bat` with Unix line endings jumps to the wrong lines and misbehaves in ways that look like logic bugs. `.gitattributes` enforces this, and the launcher re-normalises after download.
